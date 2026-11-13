defmodule SymphonyElixir.Claude.CLI do
  @moduledoc "Runs a non-interactive Claude Code turn in a workspace."

  alias SymphonyElixir.Claude.MCPBridge
  alias SymphonyElixir.{Config, Tracker}

  @mcp_bridge_script "import socket,sys,json,os\ns=socket.create_connection(('127.0.0.1',int(sys.argv[1])))\nf=s.makefile('rb')\nfor line in sys.stdin.buffer:\n m=None\n try:\n  m=json.loads(line)\n  if isinstance(m,dict): m['symphonyAuth']=os.environ['SYMPHONY_MCP_NONCE']; line=(json.dumps(m,separators=(',',':'))+'\\n').encode()\n except Exception: pass\n s.sendall(line)\n if isinstance(m,dict) and isinstance(m.get('method'),str) and m['method'].startswith('notifications/'): continue\n reply=f.readline()\n if not reply: break\n sys.stdout.buffer.write(reply);sys.stdout.buffer.flush()\n"
  @spec run(Path.t(), String.t(), String.t() | nil, keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def run(workspace, prompt, worker_host \\ nil, opts \\ [])
      when is_binary(workspace) and is_binary(prompt) do
    if is_binary(worker_host) do
      {:error, :claude_tracker_mcp_bridge_remote_unsupported}
    else
      issue = Keyword.fetch!(opts, :issue)
      binding = Tracker.bind_agent_tools()

      with {:ok, bridge, port, token} <-
             MCPBridge.start_link(issue, binding, on_review_label_removal: Keyword.get(opts, :on_review_label_removal)) do
        run_with_bridge(workspace, prompt, opts, binding, bridge, port, token)
      end
    end
  end

  @doc false
  @spec parse_stream_event(String.t()) ::
          {:text, String.t()} | {:result, String.t()} | :ignore | {:error, term()}
  def parse_stream_event(line) when is_binary(line) do
    with {:ok, %{"type" => "stream_event", "event" => event}} <- Jason.decode(line),
         %{"type" => "content_block_delta", "delta" => %{"type" => "text_delta", "text" => text}} <- event do
      {:text, text}
    else
      {:ok, %{"type" => "result", "result" => result}} when is_binary(result) -> {:result, result}
      {:ok, _other} -> :ignore
      {:error, reason} -> {:error, reason}
      _other -> :ignore
    end
  end

  defp run_with_bridge(workspace, prompt, opts, binding, bridge, port, token) do
    config_writer = Keyword.get(opts, :mcp_config_writer, &write_mcp_config/2)

    case config_writer.(port, token) do
      {:ok, config_path} ->
        stderr_path = temp_path("stderr")

        try do
          command = claude_command(prompt, config_path, stderr_path)
          run_local(workspace, command, binding.secret_environment_names, stderr_path, opts)
        after
          File.rm_rf(Path.dirname(config_path))
          File.rm(stderr_path)
          if Process.alive?(bridge), do: GenServer.stop(bridge)
        end

      {:error, reason} ->
        if Process.alive?(bridge), do: GenServer.stop(bridge)
        {:error, reason}
    end
  end

  defp claude_command(prompt, config_path, stderr_path) do
    Config.settings!().claude.command <>
      " --strict-mcp-config --mcp-config " <>
      shell_escape(config_path) <>
      " " <>
      shell_escape(prompt) <>
      " 2> " <>
      shell_escape(stderr_path)
  end

  defp run_local(workspace, command, secret_names, stderr_path, opts) do
    with {:ok, bash} <- find_bash() do
      env = Enum.map(secret_names, fn name -> {String.to_charlist(name), false} end)

      port_open = Keyword.get(opts, :port_open_fun, &Port.open/2)

      port =
        port_open.(
          {:spawn_executable, String.to_charlist(bash)},
          [
            :binary,
            :exit_status,
            :use_stdio,
            {:args, [~c"-lc", String.to_charlist(command)]},
            {:cd, String.to_charlist(workspace)},
            {:env, env}
          ]
        )

      timeout_ms = Config.settings!().codex.turn_timeout_ms
      on_message = Keyword.get(opts, :on_message, fn _message -> :ok end)

      try do
        result =
          collect_output(port, on_message, timeout_ms, System.monotonic_time(:millisecond), %{
            carry: "",
            output: "",
            result: nil
          })

        case result do
          {:ok, _output} ->
            result

          {:error, {:claude_cli_failed, status, output}} ->
            {:error, {:claude_cli_failed, status, output <> read_stderr(stderr_path)}}

          {:error, reason} ->
            {:error, {reason, read_stderr(stderr_path)}}
        end
      after
        if Port.info(port), do: Port.close(port)
      end
    end
  rescue
    error in [ErlangError, File.Error] -> {:error, {:claude_cli_start_failed, error}}
  end

  defp read_stderr(path) do
    case File.read(path) do
      {:ok, contents} -> contents
      _ -> ""
    end
  end

  defp collect_output(port, on_message, timeout_ms, started_at, state) do
    remaining = max(0, timeout_ms - (System.monotonic_time(:millisecond) - started_at))

    receive do
      {^port, {:data, chunk}} ->
        updated = process_chunk(chunk, on_message, state)
        collect_output(port, on_message, timeout_ms, started_at, updated)

      {^port, {:exit_status, 0}} ->
        final_state = if state.carry == "", do: state, else: process_line(state.carry, on_message, state)
        {:ok, final_state.result || final_state.output}

      {^port, {:exit_status, status}} ->
        {:error, {:claude_cli_failed, status, state.output <> state.carry}}
    after
      remaining ->
        {:error, :claude_cli_timeout}
    end
  end

  defp process_chunk(chunk, on_message, state) do
    case String.split(state.carry <> chunk, "\n") do
      [partial] ->
        %{state | carry: partial}

      lines ->
        {complete, [partial]} = Enum.split(lines, length(lines) - 1)
        updated = Enum.reduce(complete, state, &process_line(&1, on_message, &2))
        %{updated | carry: partial}
    end
  end

  defp process_line(line, on_message, state) do
    case parse_stream_event(line) do
      {:text, text} when is_binary(text) ->
        if text != "" do
          on_message.(%{event: :claude_message_delta, timestamp: DateTime.utc_now(), text: text})
        end

        %{state | output: state.output <> text}

      {:result, text} ->
        if state.output == "" and text != "" do
          on_message.(%{event: :claude_message_delta, timestamp: DateTime.utc_now(), text: text})
        end

        %{state | result: text}

      :ignore ->
        state

      {:error, _reason} ->
        on_message.(%{event: :claude_message_delta, timestamp: DateTime.utc_now(), text: line})
        %{state | output: state.output <> line}
    end
  end

  defp find_bash do
    case System.find_executable("bash") do
      nil -> {:error, :bash_not_found}
      executable -> {:ok, executable}
    end
  end

  defp write_mcp_config(port, token) do
    write_mcp_config_at(temp_path("mcp"), port, token)
  end

  defp write_mcp_config_at(directory, port, token) do
    write_mcp_config_at(directory, port, token, &File.open/2)
  end

  defp write_mcp_config_at(directory, port, token, file_open) do
    path = Path.join(directory, "config.json")

    config = %{
      "mcpServers" => %{
        "symphony-tracker" => %{
          "command" => System.find_executable("python3") || "python3",
          "args" => ["-c", @mcp_bridge_script, Integer.to_string(port)],
          "env" => %{"SYMPHONY_MCP_NONCE" => token}
        }
      }
    }

    case File.mkdir(directory) do
      :ok -> write_mcp_config_file(directory, path, config, file_open)
      {:error, reason} -> {:error, {:claude_mcp_config_failed, reason}}
    end
  end

  defp write_mcp_config_file(directory, path, config, file_open) do
    with :ok <- File.chmod(directory, 0o700),
         {:ok, file} <- file_open.(path, [:write, :exclusive]),
         :ok <- File.chmod(path, 0o600),
         :ok <- IO.binwrite(file, Jason.encode!(config)),
         :ok <- File.close(file) do
      {:ok, path}
    else
      {:error, reason} ->
        File.rm_rf(directory)
        {:error, {:claude_mcp_config_failed, reason}}
    end
  end

  @doc false
  @spec write_mcp_config_for_test(non_neg_integer(), String.t()) :: {:ok, Path.t()} | {:error, term()}
  def write_mcp_config_for_test(port, token), do: write_mcp_config(port, token)

  @doc false
  @spec write_mcp_config_in_directory_for_test(Path.t(), non_neg_integer(), String.t()) ::
          {:ok, Path.t()} | {:error, term()}
  def write_mcp_config_in_directory_for_test(directory, port, token),
    do: write_mcp_config_at(directory, port, token)

  @doc false
  @spec write_mcp_config_with_file_open_for_test(Path.t(), non_neg_integer(), String.t(), function()) ::
          {:ok, Path.t()} | {:error, term()}
  def write_mcp_config_with_file_open_for_test(directory, port, token, file_open),
    do: write_mcp_config_at(directory, port, token, file_open)

  defp temp_path(kind) do
    Path.join(System.tmp_dir!(), "symphony-claude-#{kind}-#{System.unique_integer([:positive])}")
  end

  defp shell_escape(value) do
    "'" <> String.replace(value, "'", "'\\''") <> "'"
  end
end

defmodule SymphonyElixir.Claude.CLITest do
  use SymphonyElixir.TestSupport
  import Bitwise

  alias SymphonyElixir.Claude.CLI

  test "runs the configured Claude command in the issue workspace" do
    workspace = Path.join(System.tmp_dir!(), "symphony-claude-cli-#{System.unique_integer([:positive])}")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(workspace) end)

    write_workflow_file!(Workflow.workflow_file_path(), claude_command: "printf 'claude-result'")

    assert {:ok, "claude-result"} = CLI.run(workspace, "review this", nil, issue: %Issue{})
  end

  test "returns command failures with their status and output" do
    workspace = Path.join(System.tmp_dir!(), "symphony-claude-cli-#{System.unique_integer([:positive])}")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(workspace) end)

    write_workflow_file!(Workflow.workflow_file_path(), claude_command: "printf 'failed'; false")

    assert {:error, {:claude_cli_failed, 1, output}} =
             CLI.run(workspace, "review this", nil, issue: %Issue{})

    assert output =~ "failed"
  end

  test "parses Claude stream events and tolerates unrelated or malformed lines" do
    assert {:text, "partial"} =
             CLI.parse_stream_event(
               Jason.encode!(%{
                 "type" => "stream_event",
                 "event" => %{
                   "type" => "content_block_delta",
                   "delta" => %{"type" => "text_delta", "text" => "partial"}
                 }
               })
             )

    assert {:result, "complete"} = CLI.parse_stream_event(Jason.encode!(%{"type" => "result", "result" => "complete"}))
    assert :ignore = CLI.parse_stream_event(Jason.encode!(%{"type" => "system", "subtype" => "ready"}))
    assert :ignore = CLI.parse_stream_event(Jason.encode!(%{"type" => "stream_event", "event" => %{"type" => "message_start"}}))
    assert {:error, _reason} = CLI.parse_stream_event("not-json")
    assert {:error, _reason} = CLI.parse_stream_event("{")
  end

  test "streams Claude JSON events and returns the final result" do
    workspace = Path.join(System.tmp_dir!(), "symphony-claude-stream-#{System.unique_integer([:positive])}")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(workspace) end)

    delta = Jason.encode!(%{"type" => "stream_event", "event" => %{"type" => "content_block_delta", "delta" => %{"type" => "text_delta", "text" => "draft"}}})
    result = Jason.encode!(%{"type" => "result", "result" => "finished"})
    command = "printf '%s\\n' '#{delta}' '#{result}'"
    write_workflow_file!(Workflow.workflow_file_path(), claude_command: command)

    on_message = fn message -> send(self(), {:claude_message, message}) end

    assert {:ok, "finished"} =
             CLI.run(workspace, "review this", nil, issue: %Issue{}, on_message: on_message)

    assert_receive {:claude_message, %{event: :claude_message_delta, text: "draft"}}
  end

  test "streams a result without preceding deltas and reports a turn timeout" do
    workspace = Path.join(System.tmp_dir!(), "symphony-claude-result-#{System.unique_integer([:positive])}")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(workspace) end)

    ignored_line = Jason.encode!(%{"type" => "system", "subtype" => "ready"})
    result_line = Jason.encode!(%{"type" => "result", "result" => "only-result"})

    write_workflow_file!(
      Workflow.workflow_file_path(),
      claude_command: "printf '%s\\n' '#{ignored_line}' '#{result_line}'"
    )

    on_message = fn message -> send(self(), {:claude_message, message}) end
    assert {:ok, "only-result"} = CLI.run(workspace, "review", nil, issue: %Issue{}, on_message: on_message)
    assert_receive {:claude_message, %{event: :claude_message_delta, text: "only-result"}}

    write_workflow_file!(Workflow.workflow_file_path(), claude_command: "sleep 1 #", codex_turn_timeout_ms: 20)
    assert {:error, {:claude_cli_timeout, _stderr}} = CLI.run(workspace, "review", nil, issue: %Issue{})
  end

  test "reports when bash is unavailable" do
    workspace = Path.join(System.tmp_dir!(), "symphony-claude-no-bash-#{System.unique_integer([:positive])}")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(workspace) end)

    previous_path = System.get_env("PATH")
    on_exit(fn -> if previous_path, do: System.put_env("PATH", previous_path), else: System.delete_env("PATH") end)
    System.put_env("PATH", "")

    assert {:error, :bash_not_found} = CLI.run(workspace, "review", nil, issue: %Issue{})
  end

  test "preserves an existing directory when creating the MCP config fails" do
    directory = Path.join(System.tmp_dir!(), "symphony-claude-existing-#{System.unique_integer([:positive])}")
    File.mkdir_p!(directory)
    marker = Path.join(directory, "keep-me")
    File.write!(marker, "user data")
    on_exit(fn -> File.rm_rf(directory) end)

    assert {:error, {:claude_mcp_config_failed, :eexist}} =
             CLI.write_mcp_config_in_directory_for_test(directory, 12_345, "private-nonce")

    assert File.read!(marker) == "user data"
  end

  test "removes the private directory when creating the MCP config file fails" do
    directory = Path.join(System.tmp_dir!(), "symphony-claude-file-failure-#{System.unique_integer([:positive])}")
    file_open = fn _path, _modes -> {:error, :eacces} end

    assert {:error, {:claude_mcp_config_failed, :eacces}} =
             CLI.write_mcp_config_with_file_open_for_test(directory, 12_345, "private-nonce", file_open)

    refute File.exists?(directory)
  end

  test "stops the tracker bridge when MCP config setup fails" do
    workspace = Path.join(System.tmp_dir!(), "symphony-claude-config-failure-#{System.unique_integer([:positive])}")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(workspace) end)

    write_workflow_file!(Workflow.workflow_file_path(), claude_command: "true")
    writer = fn _port, _token -> {:error, {:claude_mcp_config_failed, :eacces}} end

    assert {:error, {:claude_mcp_config_failed, :eacces}} =
             CLI.run(workspace, "review", nil, issue: %Issue{}, mcp_config_writer: writer)
  end

  test "converts errors while starting the local command into startup failures" do
    workspace = Path.join(System.tmp_dir!(), "symphony-claude-port-failure-#{System.unique_integer([:positive])}")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(workspace) end)

    write_workflow_file!(Workflow.workflow_file_path(), claude_command: "true")
    port_open = fn _executable, _options -> raise ErlangError, original: :badarg end

    assert {:error, {:claude_cli_start_failed, %ErlangError{}}} =
             CLI.run(workspace, "review", nil, issue: %Issue{}, port_open_fun: port_open)
  end

  test "returns a startup error for a missing workspace" do
    missing_workspace = Path.join(System.tmp_dir!(), "symphony-claude-missing-#{System.unique_integer([:positive])}")
    write_workflow_file!(Workflow.workflow_file_path(), claude_command: "true")

    assert {:error, {:claude_cli_failed, 2, _output}} =
             CLI.run(missing_workspace, "review", nil, issue: %Issue{})
  end

  test "rejects remote workers before reading local configuration" do
    assert {:error, :claude_tracker_mcp_bridge_remote_unsupported} = CLI.run("/workspace", "review", "worker-a")
  end

  test "keeps the temporary MCP config in a private directory and file" do
    assert {:ok, path} = CLI.write_mcp_config_for_test(12_345, "private-nonce")
    on_exit(fn -> File.rm_rf(Path.dirname(path)) end)

    assert band(File.stat!(Path.dirname(path)).mode, 0o777) == 0o700
    assert band(File.stat!(path).mode, 0o777) == 0o600
    assert Jason.decode!(File.read!(path))["mcpServers"]["symphony-tracker"]["env"]["SYMPHONY_MCP_NONCE"] == "private-nonce"
  end
end

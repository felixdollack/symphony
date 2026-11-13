defmodule SymphonyElixir.Claude.MCPBridge do
  @moduledoc false

  use GenServer

  alias SymphonyElixir.Tracker

  @protocol_version "2024-11-05"

  @spec start_link(SymphonyElixir.Tracker.Issue.t(), map()) ::
          {:ok, pid(), non_neg_integer(), String.t()} | {:error, term()}
  @spec start_link(SymphonyElixir.Tracker.Issue.t(), map(), keyword()) ::
          {:ok, pid(), non_neg_integer(), String.t()} | {:error, term()}
  def start_link(issue, binding, opts \\ []) do
    server_opts = Keyword.take(opts, [:name])

    case GenServer.start_link(__MODULE__, {issue, binding, opts}, server_opts) do
      {:ok, pid} ->
        {:ok, port, token} = GenServer.call(pid, :port)
        {:ok, pid, port, token}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def init({issue, binding, opts}) do
    listen = Keyword.get(opts, :listen_fun, &:gen_tcp.listen/2)
    sockname = Keyword.get(opts, :sockname_fun, &:inet.sockname/1)
    accept = Keyword.get(opts, :accept_fun, &:gen_tcp.accept/1)

    with {:ok, socket} <- listen.(0, [:binary, packet: :line, active: false, reuseaddr: true, ip: {127, 0, 0, 1}]),
         {:ok, {_address, port}} <- sockname.(socket) do
      token = :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)
      server = self()
      acceptor = spawn(fn -> accept_connections(socket, server, accept) end)

      {:ok,
       %{
         socket: socket,
         acceptor: acceptor,
         port: port,
         token: token,
         issue: issue,
         binding: binding,
         on_review_label_removal: Keyword.get(opts, :on_review_label_removal)
       }}
    else
      {:error, reason} -> {:stop, {:mcp_bridge_start_failed, reason}}
    end
  end

  @impl true
  def handle_call(:port, _from, %{port: port, token: token} = state),
    do: {:reply, {:ok, port, token}, state}

  @impl true
  def handle_call({:mcp_request, request, token}, _from, state) do
    if token == state.token do
      {:reply, handle_request(request, state.binding, state.issue, state.on_review_label_removal), state}
    else
      id = request["id"]
      {:reply, %{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => -32_001, "message" => "Unauthorized MCP bridge request"}}, state}
    end
  end

  @impl true
  def terminate(_reason, %{socket: socket, acceptor: acceptor}) do
    Process.exit(acceptor, :shutdown)
    :gen_tcp.close(socket)
    :ok
  end

  defp accept_connections(listener, server, accept) do
    case accept.(listener) do
      {:ok, socket} ->
        serve_connection(socket, server)
        accept_connections(listener, server, accept)

      {:error, :closed} ->
        :ok

      {:error, _reason} ->
        accept_connections(listener, server, accept)
    end
  end

  defp serve_connection(socket, server) do
    case :gen_tcp.recv(socket, 0) do
      {:ok, line} ->
        serve_line(socket, server, line)
        serve_connection(socket, server)

      {:error, _reason} ->
        :gen_tcp.close(socket)
    end
  end

  defp serve_line(socket, server, line) do
    case decode_request(line) do
      {:ok, request} -> send_request_response(socket, server, request)
      {:error, reason} -> send_parse_error(socket, reason)
    end
  end

  defp send_request_response(socket, server, request) do
    case GenServer.call(server, {:mcp_request, request, request["symphonyAuth"]}, :infinity) do
      :notification -> :ok
      response -> :gen_tcp.send(socket, Jason.encode!(response) <> "\n")
    end
  end

  defp send_parse_error(socket, reason) do
    response = %{"jsonrpc" => "2.0", "id" => nil, "error" => %{"code" => -32_700, "message" => inspect(reason)}}
    :gen_tcp.send(socket, Jason.encode!(response) <> "\n")
  end

  defp decode_request(line) do
    case Jason.decode(line) do
      {:ok, %{"jsonrpc" => "2.0"} = request} -> {:ok, request}
      {:ok, _request} -> {:error, :invalid_json_rpc_request}
      {:error, reason} -> {:error, reason}
    end
  end

  defp handle_request(%{"method" => "notifications/initialized"}, _binding, _issue, _callback), do: :notification

  defp handle_request(%{"id" => id, "method" => "initialize", "params" => params}, _binding, _issue, _callback) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => %{
        "protocolVersion" => params["protocolVersion"] || @protocol_version,
        "capabilities" => %{"tools" => %{}},
        "serverInfo" => %{"name" => "symphony-tracker", "version" => "1.0.0"}
      }
    }
  end

  defp handle_request(%{"id" => id, "method" => "tools/list"}, binding, _issue, _callback) do
    %{"jsonrpc" => "2.0", "id" => id, "result" => %{"tools" => binding.tool_specs}}
  end

  defp handle_request(%{"id" => id, "method" => "tools/call", "params" => params}, binding, issue, callback) do
    tool_result =
      Tracker.execute_bound_agent_tool(
        binding,
        params["name"],
        params["arguments"],
        issue: issue,
        on_review_label_removal: callback
      )

    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => %{
        "content" => [%{"type" => "text", "text" => tool_result["output"] || ""}],
        "isError" => tool_result["success"] != true
      }
    }
  end

  defp handle_request(%{"id" => id, "method" => "ping"}, _binding, _issue, _callback) do
    %{"jsonrpc" => "2.0", "id" => id, "result" => %{}}
  end

  defp handle_request(%{"id" => id, "method" => method}, _binding, _issue, _callback) do
    %{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => -32_601, "message" => "Method not found: #{method}"}}
  end

  defp handle_request(_request, _binding, _issue, _callback), do: :notification
end

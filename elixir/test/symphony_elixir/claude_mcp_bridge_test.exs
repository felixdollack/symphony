defmodule SymphonyElixir.Claude.MCPBridgeTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Claude.MCPBridge

  test "authenticates MCP requests before exposing tracker tools" do
    {:ok, bridge, port, token} = MCPBridge.start_link(%Issue{}, %{tool_specs: []})
    on_exit(fn -> if Process.alive?(bridge), do: GenServer.stop(bridge) end)

    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])

    :ok =
      :gen_tcp.send(
        socket,
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "initialize",
          "params" => %{"protocolVersion" => "2024-11-05"},
          "symphonyAuth" => "wrong"
        }) <> "\n"
      )

    :ok =
      :gen_tcp.send(
        socket,
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "method" => "notifications/progress",
          "symphonyAuth" => token
        }) <> "\n"
      )

    assert {:ok, unauthorized} = :gen_tcp.recv(socket, 0, 1_000)
    assert Jason.decode!(unauthorized)["error"]["code"] == -32_001

    :ok =
      :gen_tcp.send(
        socket,
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 2,
          "method" => "initialize",
          "params" => %{"protocolVersion" => "2024-11-05"},
          "symphonyAuth" => token
        }) <> "\n"
      )

    assert {:ok, authorized} = :gen_tcp.recv(socket, 0, 1_000)
    assert Jason.decode!(authorized)["result"]["capabilities"] == %{"tools" => %{}}
    :gen_tcp.close(socket)
  end

  test "reports a server start error when its registered name is already in use" do
    name = Module.concat(__MODULE__, :NamedBridge)
    {:ok, bridge, _port, _token} = MCPBridge.start_link(%Issue{}, %{tool_specs: []}, name: name)
    on_exit(fn -> if Process.alive?(bridge), do: GenServer.stop(bridge) end)

    assert {:error, {:already_started, ^bridge}} = MCPBridge.start_link(%Issue{}, %{tool_specs: []}, name: name)
  end

  test "returns listener startup errors to the caller" do
    previous_trap_exit = Process.flag(:trap_exit, true)

    assert {:error, {:mcp_bridge_start_failed, :eaddrinuse}} =
             MCPBridge.start_link(%Issue{}, %{tool_specs: []}, listen_fun: fn _port, _opts -> {:error, :eaddrinuse} end)

    Process.flag(:trap_exit, previous_trap_exit)
  end

  test "retries a transient accept error before the listener closes" do
    test_process = self()
    attempts = Agent.start_link(fn -> 0 end) |> elem(1)

    accept_fun = fn _listener ->
      attempt = Agent.get_and_update(attempts, fn attempt -> {attempt, attempt + 1} end)
      send(test_process, {:accept_attempt, attempt})
      if attempt == 0, do: {:error, :eagain}, else: {:error, :closed}
    end

    {:ok, bridge, _port, _token} =
      MCPBridge.start_link(%Issue{}, %{tool_specs: []}, accept_fun: accept_fun)

    assert_receive {:accept_attempt, 0}
    assert_receive {:accept_attempt, 1}
    GenServer.stop(bridge)
    Agent.stop(attempts)
  end

  test "serves MCP notifications, tools, ping, and protocol errors" do
    binding = %{
      adapter: SymphonyElixir.Tracker.Memory,
      tracker_settings: %{},
      tool_specs: [%{"name" => "memory_search"}]
    }

    {:ok, bridge, port, token} = MCPBridge.start_link(%Issue{}, binding)
    on_exit(fn -> if Process.alive?(bridge), do: GenServer.stop(bridge) end)

    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, packet: :line, active: false])

    :ok =
      :gen_tcp.send(
        socket,
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "method" => "notifications/initialized",
          "symphonyAuth" => token
        }) <> "\n"
      )

    assert %{"id" => 1, "result" => %{"tools" => [%{"name" => "memory_search"}]}} =
             socket
             |> send_request(token, %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"})
             |> Jason.decode!()

    assert %{"id" => 2, "result" => %{"content" => [%{"type" => "text"}], "isError" => true}} =
             socket
             |> send_request(token, %{
               "jsonrpc" => "2.0",
               "id" => 2,
               "method" => "tools/call",
               "params" => %{"name" => "unknown", "arguments" => %{}}
             })
             |> Jason.decode!()

    assert %{"id" => 3, "result" => %{}} =
             socket
             |> send_request(token, %{"jsonrpc" => "2.0", "id" => 3, "method" => "ping"})
             |> Jason.decode!()

    assert %{"id" => 4, "error" => %{"code" => -32_601}} =
             socket
             |> send_request(token, %{"jsonrpc" => "2.0", "id" => 4, "method" => "unknown/method"})
             |> Jason.decode!()

    :ok = :gen_tcp.send(socket, "not-json\n")
    assert {:ok, parse_error} = :gen_tcp.recv(socket, 0, 1_000)
    assert Jason.decode!(parse_error)["error"]["code"] == -32_700

    :ok = :gen_tcp.send(socket, Jason.encode!(%{"method" => "missing-version"}) <> "\n")
    assert {:ok, invalid_request} = :gen_tcp.recv(socket, 0, 1_000)
    assert Jason.decode!(invalid_request)["error"]["message"] =~ "invalid_json_rpc_request"

    :gen_tcp.close(socket)

    {:ok, second_socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, packet: :line, active: false])

    assert %{"id" => 5, "result" => %{}} =
             second_socket
             |> send_request(token, %{"jsonrpc" => "2.0", "id" => 5, "method" => "ping"})
             |> Jason.decode!()

    :gen_tcp.close(second_socket)
  end

  defp send_request(socket, token, request) do
    request = Map.put(request, "symphonyAuth", token)
    :ok = :gen_tcp.send(socket, Jason.encode!(request) <> "\n")

    case :gen_tcp.recv(socket, 0, 1_000) do
      {:ok, response} -> response
      other -> flunk("expected MCP response, got #{inspect(other)}")
    end
  end
end

defmodule CodexPoolerWeb.CodexResponsesSocketFirstOutputWriteBoundaryTest do
  use ExUnit.Case, async: false
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPoolerWeb.CodexResponsesSocket
  alias CodexPoolerWeb.WebsocketDownstreamWriteWatch, as: Watch

  defmodule Endpoint do
    @moduledoc false
    import Plug.Conn
    def init(opts), do: opts
    def call(conn, opts), do: conn |> WebSockAdapter.upgrade(CodexPoolerWeb.CodexResponsesSocketFirstOutputWriteBoundaryTest.Socket, Map.new(opts), compress: false) |> halt()
  end

  defmodule Socket do
    @moduledoc false
    @behaviour WebSock
    @impl true
    def init(%{parent: parent}) do
      Watch.watch()
      Process.put(:first_output_write_boundary_parent, parent)
      send(parent, {:ready, self()})
      {:ok, %{opts: RequestOptions.for_websocket(%{}), tasks: MapSet.new([self()]), task_monitors: %{}, native_turn_output_task_pids: MapSet.new()}}
    end

    @impl true
    def handle_in(_, state), do: {:ok, state}
    @impl true
    def handle_info(:deliver, state) do
      frame = ~s({"type":"response.incomplete","response":{"id":"resp_fixture","status":"incomplete","incomplete_details":{"reason":"content_filter"}}})
      {:push, {:text, ^frame}, next} = CodexResponsesSocket.handle_info({:codex_response_chunk, self(), frame}, state)
      send(Process.get(:first_output_write_boundary_parent), {:staged_terminal, next.downstream_delivery_evidence[self()].terminal_class})
      {:push, {:text, frame}, next}
    end

    def handle_info(message, state), do: CodexResponsesSocket.handle_info(message, state)
    @impl true
    def terminate(_, state) do
      # Reconfirm after Bandit's actual Ping error: the previously confirmed terminal must survive.
      CodexResponsesSocket.handle_info(:confirm_content_filter_terminal_write, state)
      send(Process.get(:first_output_write_boundary_parent), {:final_watch, Watch.failure(), Watch.confirmed()})
      :ok
    end
  end

  # A GenServer debug boundary runs after Bandit wrote the data and every
  # synchronous send-telemetry handler returned, regardless of handler order.
  @doc false
  @spec hold_after_text_write(map(), term(), term()) :: map() | :done
  def hold_after_text_write(config, {:noreply, {_transport, handler}}, _name) do
    case Map.get(handler.connection.websock_state, :downstream_delivery_evidence, %{})[self()] do
      %{frames: 1, terminal_class: "response.incomplete"} ->
        monitor = Process.monitor(config.parent)
        send(config.parent, {:text_written, self()})

        receive do
          :allow_ping -> :ok
          {:DOWN, ^monitor, :process, _parent, _reason} -> :ok
        after
          15_000 -> raise "write-boundary release missing"
        end

        Process.demonitor(monitor, [:flush])
        :done

      _none ->
        config
    end
  end

  def hold_after_text_write(config, _event, _name), do: config

  @doc false
  @spec observe(list(atom()), map(), map(), term()) :: term()
  def observe([:thousand_island, :connection, :send_error], %{error: error}, _, _) do
    if parent = Process.get(:first_output_write_boundary_parent), do: send(parent, {:ping_failed, error})
  end

  test "successful first terminal text stays confirmed when the queued Ping write fails" do
    id = {__MODULE__, make_ref()}
    on_exit(fn -> :telemetry.detach(id) end)
    :ok = :telemetry.attach(id, [:thousand_island, :connection, :send_error], &__MODULE__.observe/4, nil)
    {:ok, server} = start_supervised({Bandit, plug: {Endpoint, parent: self()}, port: 0, ip: {127, 0, 0, 1}})
    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    {:ok, conn} = Mint.HTTP.connect(:http, "127.0.0.1", port, protocols: [:http1], mode: :passive)
    on_exit(fn -> Mint.HTTP.close(conn) end)
    {:ok, conn, ref} = Mint.WebSocket.upgrade(:ws, conn, "/", [])
    {:ok, conn, responses} = Mint.HTTP.recv(conn, 0, 15_000)
    {:headers, ^ref, headers} = Enum.find(responses, &match?({:headers, _, _}, &1))
    {:ok, conn, ws} = Mint.WebSocket.new(conn, ref, 101, headers, mode: :passive)
    assert_receive {:ready, socket}, 15_000
    :ok = :sys.install(socket, {&__MODULE__.hold_after_text_write/3, %{parent: self()}})
    send(socket, :deliver)
    assert_receive {:staged_terminal, "response.incomplete"}, 15_000
    assert_receive {:text_written, ^socket}, 15_000
    {:ok, conn, [{:data, ^ref, data}]} = Mint.WebSocket.recv(conn, 0, 15_000)
    {:ok, _ws, [{:text, terminal}]} = Mint.WebSocket.decode(ws, data)
    assert CodexPooler.JSON.decode!(terminal)["type"] == "response.incomplete"
    # Monitor the real accepted port before closing the client. The first
    # write succeeded; only the queued Ping runs after the port has exited.
    {:links, links} = Process.info(socket, :links)
    [accepted_port] = Enum.filter(links, &is_port/1)
    monitor = :erlang.monitor(:port, accepted_port)
    {:ok, _conn} = Mint.HTTP.close(conn)
    assert_receive {:DOWN, ^monitor, :port, ^accepted_port, _}, 15_000
    send(socket, :allow_ping)
    assert_receive {:ping_failed, :closed}, 15_000
    assert_receive {:final_watch, "closed", confirmed}, 15_000
    assert %{terminal_class: "response.incomplete", frames: 1} = confirmed[socket]
  end
end

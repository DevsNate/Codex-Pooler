defmodule CodexPoolerWeb.CodexResponsesSocketFirstOutputKeepaliveTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Transports.Websocket.DownstreamProgress
  alias CodexPoolerWeb.CodexResponsesSocket
  alias CodexPoolerWeb.WebsocketDownstreamWriteWatch

  @frame ~s({"type":"response.output_text.delta","delta":"fixture"})
  @tick {CodexResponsesSocket, :downstream_keepalive, 60_000, %{}}

  test "first native output queues an immediate ping after its write; a single frame buys no periodic extension" do
    state = native_state()
    assert {:ok, ^state} = CodexResponsesSocket.handle_info(@tick, state)
    assert {:push, {:text, @frame}, first} = chunk(state)
    assert first.downstream_delivery_evidence[self()].frames == 1
    assert {:push, {:ping, ""}, ^first} = first_ping(first)
    assert {:ok, ^first} = CodexResponsesSocket.handle_info(@tick, first)
    assert {:ok, ^first} = tick(first, %{self() => 1})

    assert {:push, {:text, @frame}, second} = chunk(first)
    refute_received {CodexResponsesSocket, :first_downstream_keepalive, _}
    assert {:push, {:ping, ""}, ^second} = tick(second, %{self() => 1})
    assert {:ok, ^second} = tick(second, %{self() => 2})
    refute Map.get(second, :downstream_pong_observed?, false)
    assert {:ok, ^second} = tick(second, %{self() => 2})
  end

  test "the first-frame periodic tick still notifies a remote-owner waiter without another ping" do
    assert {:push, {:text, @frame}, first} = chunk(native_state())
    assert {:push, {:ping, ""}, ^first} = first_ping(first)
    first = Map.put(first, :websocket_owner_downstream, %{})
    assert {:ok, ^first} = CodexResponsesSocket.handle_info(@tick, first)
    assert DownstreamProgress.drain()
    assert {:ok, ^first} = tick(first, %{self() => 1})
    refute DownstreamProgress.drain()
  end

  test "internal controls and stale tasks never purchase a first-output ping" do
    state = native_state()
    metadata = ~s({"type":"codex.response.metadata"})
    assert {:push, {:text, ^metadata}, controls} = chunk(state, metadata)
    assert {:ok, ^controls} = CodexResponsesSocket.handle_info(@tick, controls)
    assert {:ok, _state} = chunk(state, ~s({"type":"codex.rate_limits"}))
    stale = %{state | tasks: MapSet.new()}
    assert {:ok, ^stale} = chunk(stale)
    refute_received {CodexResponsesSocket, :first_downstream_keepalive, _}
  end

  test "queued first pings drop after task removal, a failed data write, or socket stop" do
    assert {:push, {:text, @frame}, first} = chunk(native_state())
    assert_receive {CodexResponsesSocket, :first_downstream_keepalive, _} = ping
    removed = %{first | tasks: MapSet.new()}
    assert {:ok, ^removed} = CodexResponsesSocket.handle_info(ping, removed)
    stopped = Map.put(first, :socket_stopped?, true)
    assert {:ok, ^stopped} = CodexResponsesSocket.handle_info(ping, stopped)
    assert {:ok, ^stopped} = chunk(stopped)
    assert {:ok, ^stopped} = CodexResponsesSocket.handle_info(@tick, stopped)
    assert {:ok, ^stopped} = CodexResponsesSocket.handle_in({@frame, [opcode: :text]}, stopped)
    :ok = WebsocketDownstreamWriteWatch.watch()
    :telemetry.execute([:thousand_island, :connection, :send_error], %{error: :closed}, %{})
    assert {:ok, ^first} = CodexResponsesSocket.handle_info(ping, first)
  end

  test "public normalization precedes the queued first-output ping without changing JSON semantics" do
    opts = RequestOptions.put_openai_compatibility(native_state().opts, public_openai_responses_stream: true)
    state = Map.merge(native_state(), %{opts: opts, public_response_task_pid: self(), public_response_stream_id: nil, public_responses_websocket_state: nil, public_turn_task_done?: false, public_turn_owner_complete?: false, public_turn_aborted?: false, public_turn_output_committed?: false})
    assert {:push, {:text, frame}, next} = chunk(state)
    assert %{"type" => "response.output_text.delta", "sequence_number" => 0, "delta" => "fixture"} = CodexPooler.JSON.decode!(frame)
    assert next.public_turn_output_committed?
    assert {:push, {:ping, ""}, ^next} = first_ping(next)
    assert {:ok, ^next} = CodexResponsesSocket.handle_info(@tick, next)
  end

  test "a reused steering lane fences queued pings by the full attempt identity" do
    lane = self()
    state = Map.put(native_state(), :native_response_steering, lane)
    first_identity = %{request_id: Ecto.UUID.generate(), attempt_id: Ecto.UUID.generate(), replay_generation: 0}
    second_identity = %{first_identity | attempt_id: Ecto.UUID.generate(), replay_generation: 1}
    assert {:ok, opened} = CodexResponsesSocket.handle_info({:native_response_steering_open, lane, first_identity}, state)
    assert {:push, {:text, @frame}, first} = CodexResponsesSocket.handle_info({:native_response_steering_frame, lane, first_identity, @frame}, opened)
    assert_receive {CodexResponsesSocket, :first_downstream_keepalive, _} = old_ping
    assert {:ok, reopened} = CodexResponsesSocket.handle_info({:native_response_steering_open, lane, second_identity}, first)
    assert {:ok, ^reopened} = CodexResponsesSocket.handle_info({:native_response_steering_frame, lane, first_identity, @frame}, reopened)
    assert {:push, {:text, @frame}, second} = CodexResponsesSocket.handle_info({:native_response_steering_frame, lane, second_identity, @frame}, reopened)
    assert {:ok, ^second} = CodexResponsesSocket.handle_info(old_ping, second)
    assert {:push, {:ping, ""}, ^second} = first_ping(second)
    assert {:ok, ^second} = tick(second, %{lane => 1})
  end

  test "a port lost before the post-write queue read suppresses both first and periodic pings" do
    parent = self()
    {:ok, listener} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false])
    on_exit(fn -> :gen_tcp.close(listener) end)
    {:ok, port} = :inet.port(listener)
    {:ok, client} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])
    on_exit(fn -> :gen_tcp.close(client) end)

    task =
      Task.async(fn ->
        {:ok, server} = :gen_tcp.accept(listener, 15_000)
        :ok = :inet.setopts(server, active: :once)

        try do
          :ok = WebsocketDownstreamWriteWatch.watch()
          assert {:push, {:text, @frame}, first} = chunk(native_state())
          :ok = :gen_tcp.send(server, "first")
          :telemetry.execute([:thousand_island, :connection, :send], %{}, %{})
          assert {:push, {:text, @frame}, second} = chunk(first)
          :ok = :gen_tcp.send(server, "second")
          send(parent, {:second_write_completed, server})
          assert_receive :read_closed_port, 15_000
          :telemetry.execute([:thousand_island, :connection, :send], %{}, %{})
          assert WebsocketDownstreamWriteWatch.closed_before_latest_write_read?()
          assert is_nil(WebsocketDownstreamWriteWatch.failure())
          assert {:ok, ^second} = first_ping(second)
          assert {:ok, ^second} = tick(second, %{})
          assert WebsocketDownstreamWriteWatch.closed_before_latest_write_read?()
          assert is_nil(WebsocketDownstreamWriteWatch.failure())
        after
          :gen_tcp.close(server)
        end
      end)

    on_exit(fn -> if Process.alive?(task.pid), do: Process.exit(task.pid, :kill) end)
    assert_receive {:second_write_completed, server}, 15_000
    assert {:ok, "firstsecond"} = :gen_tcp.recv(client, 11, 15_000)
    monitor = Port.monitor(server)
    :ok = :gen_tcp.close(client)
    assert_receive {:DOWN, ^monitor, :port, ^server, _reason}, 15_000
    send(task.pid, :read_closed_port)
    assert Task.await(task, 15_000)
  end

  defp first_ping(state) do
    assert_receive {CodexResponsesSocket, :first_downstream_keepalive, _} = message
    CodexResponsesSocket.handle_info(message, state)
  end

  defp chunk(state, frame \\ @frame), do: CodexResponsesSocket.handle_info({:codex_response_chunk, self(), frame}, state)
  defp tick(state, previous), do: CodexResponsesSocket.handle_info({CodexResponsesSocket, :downstream_keepalive, 60_000, previous}, state)
  defp native_state, do: %{opts: RequestOptions.for_websocket(%{}), tasks: MapSet.new([self()]), task_monitors: %{}, native_turn_output_task_pids: MapSet.new()}
end

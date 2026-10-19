defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwarding.ReconnectDeliveryBoundaryTest do
  use CodexPoolerWeb.ConnCase, async: false

  @moduletag capture_log: true
  @moduletag slow: "boots a second BEAM node and exercises two real websocket turns with committed cleanup"

  import Ecto.Query
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketSupport, only: [await_socket_connection_state!: 2]
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwardingSupport, only: [enter_peer_owner_topology!: 0, start_peer_window_owner!: 2, request_logs: 1]

  alias CodexPooler.Accounting.{Attempt, LedgerEntry}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Persistence.CodexSession
  alias CodexPooler.Repo

  @timeout 15_000
  @thread "019a0000-0000-7000-8000-00000000e511"
  @window "#{@thread}:0"

  setup do
    CodexPooler.TestAppEnv.restore_on_exit(:websocket_owner_forwarding_enabled, nil)
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, true)
    :ok
  end

  # This isolates transport delivery after a manually cut socket. The target
  # has its own turn id: it does not simulate a released client's mailbox
  # preemption or establish admission of a same-turn retained-prefix resend.
  for reconnect <- [false, true] do
    @tag reconnect: reconnect
    test "Full remote owner delivers the target to an active reader after reconnect=#{reconnect}", %{reconnect: reconnect} do
      run_boundary!(reconnect)
    end
  end

  defp run_boundary!(reconnect) do
    enter_peer_owner_topology!()
    old_ref = make_ref()
    target_ref = make_ref()
    old_frames = frames("old")
    target_frames = frames("target")

    upstream = start_upstream(FakeUpstream.strict_sequence([expectation(old_frames, old_ref), expectation(target_frames, target_ref)]))
    setup = gateway_setup(upstream)
    peer = start_peer_window_owner!(setup, @window)
    port = start_public_endpoint!()
    writes = watch_writes!()
    parent = self()
    old = start_client!(fn -> old_client(parent, port, setup) end)

    assert_receive {:fake_upstream_frame_barrier, 0, _handler, ^old_ref}, @timeout
    old_owner = owner_snapshot!(peer)
    :ok = FakeUpstream.release_frame(upstream, old_ref)
    assert_receive {:fake_upstream_frame_barrier, 1, _handler, ^old_ref}, @timeout
    :ok = FakeUpstream.release_frame(upstream, old_ref)
    assert_receive {:fake_upstream_frame_barrier, 2, _handler, ^old_ref}, @timeout
    assert_receive {:old_item_read, old_pid, ["response.created", "response.output_item.done"]}, @timeout
    assert old_pid == old.pid

    client =
      if reconnect do
        send(old.pid, :close)
        finish_client!(old)
        :ok = FakeUpstream.release_remaining_frames(upstream, old_ref)
        assert_receive {:fake_upstream_frame_barrier, 3, _handler, ^old_ref}, @timeout
        await_rows!(setup.pool.id, 1)
        start_client!(fn -> target_client(parent, port, setup) end)
      else
        send(old.pid, :finish_old)
        :ok = FakeUpstream.release_remaining_frames(upstream, old_ref)
        assert_receive {:fake_upstream_frame_barrier, 3, _handler, ^old_ref}, @timeout
        assert_receive {:old_terminal_read, old_pid, "response.completed"}, @timeout
        assert old_pid == old.pid
        await_rows!(setup.pool.id, 1)
        send(old.pid, :target)
        old
      end

    assert_receive {:fake_upstream_frame_barrier, 0, _handler, ^target_ref}, @timeout
    target_owner = owner_snapshot!(peer)
    assert target_owner.owner_node == old_owner.owner_node
    assert target_owner.owner_generation == old_owner.owner_generation
    assert target_owner.socket != old_owner.socket == reconnect
    assert target_owner.epoch > old_owner.epoch == reconnect
    [old_request, target_request] = request_logs(setup.pool.id)

    target_write_floor =
      case :ets.last(writes) do
        :"$end_of_table" -> 0
        key -> key
      end

    # Release one frame only after the reader decoded the previous one. Each
    # arm uses exactly the same synthetic target response and no injected loss.
    for {type, index} <- Enum.with_index(["response.created", "response.output_item.done", "response.completed"]) do
      :ok = FakeUpstream.release_frame(upstream, target_ref)
      next = index + 1
      assert_receive {:fake_upstream_frame_barrier, ^next, _handler, ^target_ref}, @timeout
      assert_receive {:target_frame_read, client_pid, ^index, ^type, "target"}, @timeout
      assert client_pid == client.pid
    end

    :ok = FakeUpstream.release_frame(upstream, target_ref)
    rows = await_rows!(setup.pool.id, 2)
    target = Enum.find(rows, &(&1.id == target_request.id))
    assert target.status == "succeeded"
    assert target.request_metadata["routing"]["model_serving_mode"] == "full"
    receipt = await_receipt!(target.id)
    assert receipt["outcome"] == "delivered"
    assert receipt["terminal_class"] == "response.completed"
    assert receipt["completed_items"] == 1
    assert receipt["frames_after_visible"] > 0
    refute Map.has_key?(receipt, "write_failure")
    assert Repo.aggregate(from(entry in LedgerEntry, where: entry.request_id == ^target.id and entry.entry_kind == "settlement"), :count) == 1
    assert FakeUpstream.count(upstream) == 2
    assert :ok = FakeUpstream.verify!(upstream)
    _state = await_socket_connection_state!(target_owner.socket, &(MapSet.size(&1.tasks) == 0))
    observed = :ets.tab2list(writes) |> Enum.filter(fn {key, pid, _kind, _queue} -> pid == target_owner.socket and key > target_write_floor end)
    assert Enum.count(observed, fn {_key, _pid, kind, _queue} -> kind == :send end) >= 3
    refute Enum.any?(observed, fn {_key, _pid, kind, _queue} -> kind == :send_error end)

    record_evidence!(%{reconnect: reconnect, mode: "full", remote_owner: true, old_request_id: old_request.id, target_request_id: target.id, old_socket: inspect(old_owner.socket), target_socket: inspect(target_owner.socket), old_epoch: old_owner.epoch, target_epoch: target_owner.epoch, owner_pid: inspect(peer.owner_pid), owner_generation: target_owner.owner_generation, old_upstream_pid: inspect(old_owner.upstream), target_upstream_pid: inspect(target_owner.upstream), owner_node: Atom.to_string(peer.node), proxy_node: Atom.to_string(node()), target_client_types: ["response.created", "response.output_item.done", "response.completed"], target_receipt: Map.take(receipt, ["outcome", "terminal_class", "frames_after_visible", "completed_items"]), target_send_count: length(observed), target_send_error_count: 0, driver_queue_samples: Enum.map(observed, &elem(&1, 3)), target_status: target.status, old_status: Enum.find(rows, &(&1.id == old_request.id)).status, upstream_dispatches: 2, result: "not_reproduced_in_this_topology"})
    send(client.pid, :close)
    finish_client!(client)
  end

  defp expectation(frames, ref), do: FakeUpstream.expect_request(method: "WEBSOCKET", path: "/backend-api/codex/responses", json: [valid: true, equals: %{"type" => "response.create"}], respond: FakeUpstream.barrier_websocket_frames(frames, notify: self(), release_ref: ref))

  defp old_client(parent, port, setup) do
    client = connect!(port, setup)
    client = send_payload!(client, payload(setup, "old"))
    {client, first} = read!(client)
    {client, item} = read!(client)
    send(parent, {:old_item_read, self(), [first["type"], item["type"]]})

    receive do
      :close ->
        Mint.HTTP.close(client.conn)

      :finish_old ->
        {client, terminal} = read!(client)
        send(parent, {:old_terminal_read, self(), terminal["type"]})

        receive do
          :target -> client |> send_payload!(payload(setup, "target")) |> read_target!(parent)
        after
          @timeout -> flunk("control client did not receive the target command")
        end
    after
      @timeout -> flunk("old client did not receive its cut or finish command")
    end
  end

  defp target_client(parent, port, setup), do: connect!(port, setup) |> send_payload!(payload(setup, "target")) |> read_target!(parent)

  defp read_target!(client, parent) do
    client =
      Enum.reduce(0..2, client, fn index, current ->
        {next, frame} = read!(current)
        marker = get_in(frame, ["response", "id"]) || get_in(frame, ["item", "id"])
        assert marker in ["resp_target", "msg_target"]
        send(parent, {:target_frame_read, self(), index, frame["type"], "target"})
        next
      end)

    receive do
      :close -> Mint.HTTP.close(client.conn)
    after
      @timeout -> flunk("target client did not receive its close command")
    end
  end

  defp connect!(port, setup) do
    {conn, ws, ref, _headers} = public_websocket_connect_with_request_headers!(port, setup, Ecto.UUID.generate(), "/backend-api/codex/responses", [{"x-codex-window-id", @window}])
    %{conn: conn, ws: ws, ref: ref}
  end

  defp send_payload!(client, payload) do
    {conn, ws} = public_websocket_send_text!(client.conn, client.ws, client.ref, CodexPooler.JSON.encode!(payload))
    %{client | conn: conn, ws: ws}
  end

  defp read!(client) do
    {conn, ws, text} = public_websocket_receive_text!(client.conn, client.ws, client.ref)
    {%{client | conn: conn, ws: ws}, CodexPooler.JSON.decode!(text)}
  end

  defp start_client!(fun) do
    task = Task.async(fun)
    monitor = Process.monitor(task.pid)
    on_exit(fn -> if Process.alive?(task.pid), do: Process.exit(task.pid, :kill) end)
    %{task: task, pid: task.pid, monitor: monitor}
  end

  defp finish_client!(%{task: task, pid: pid, monitor: monitor}) do
    Task.await(task, @timeout)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, @timeout
  end

  defp owner_snapshot!(peer) do
    state = :sys.get_state(peer.owner_pid)
    assert %{downstream: %{pid: socket, epoch: epoch}, upstream_pid: upstream_pid} = state
    assert node(socket) == node()
    assert node(upstream_pid) == peer.node
    assert peer.node != node()
    assert Repo.get!(CodexSession, peer.session.id).owner_instance_id == Atom.to_string(peer.node)
    %{socket: socket, epoch: epoch, owner_node: peer.node, owner_generation: state.process_generation, upstream: upstream_pid}
  end

  defp await_rows!(pool, count),
    do:
      await!(
        fn ->
          rows = request_logs(pool)
          if length(rows) == count and Enum.all?(rows, &(&1.status not in ["accepted", "in_progress"])), do: rows
        end,
        "requests did not settle"
      )

  defp await_receipt!(request), do: await!(fn -> Repo.one(from(a in Attempt, where: a.request_id == ^request, select: a.response_metadata))["downstream_delivery"] end, "target receipt absent")

  defp await!(fun, reason, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + @timeout

    case fun.() do
      value when value not in [nil, false] ->
        value

      _ ->
        assert System.monotonic_time(:millisecond) < deadline, reason

        receive do
        after
          10 -> await!(fun, reason, deadline)
        end
    end
  end

  defp watch_writes! do
    table = :ets.new(:delivery_boundary_writes, [:public, :ordered_set])
    id = {__MODULE__, make_ref()}
    on_exit(fn -> :telemetry.detach(id) end)

    :ok =
      :telemetry.attach_many(
        id,
        [[:thousand_island, :connection, :send], [:thousand_island, :connection, :send_error]],
        fn event, _measurements, _metadata, table -> record_write(table, event) end,
        table
      )

    table
  end

  defp record_write(table, event) do
    if :ets.info(table, :size) in 0..999, do: :ets.insert(table, {System.unique_integer([:monotonic, :positive]), self(), List.last(event), driver_queue()})
  end

  defp driver_queue do
    case Process.info(self(), :links) do
      {:links, links} -> Enum.find_value(links, &tcp_port_queue/1)
      _ -> nil
    end
  end

  defp tcp_port_queue(port) when is_port(port) do
    with {:name, ~c"tcp_inet"} <- Port.info(port, :name), {:queue_size, size} <- Port.info(port, :queue_size), do: size, else: (_ -> nil)
  end

  defp tcp_port_queue(_), do: nil

  defp record_evidence!(evidence) do
    if path = System.get_env("RECONNECT_BOUNDARY_EVIDENCE"), do: File.write!(path, CodexPooler.JSON.encode!(evidence) <> "\n", [:append])
  end

  defp payload(setup, marker) do
    %{"type" => "response.create", "model" => setup.model.exposed_model_id, "instructions" => "synthetic instructions", "tools" => [%{"type" => "function", "name" => "sample_tool", "parameters" => %{"type" => "object", "properties" => %{}}}], "stream" => true, "store" => false, "input" => [%{"type" => "message", "role" => "user", "content" => [%{"type" => "input_text", "text" => "synthetic input"}]}], "client_metadata" => %{"session_id" => @thread, "thread_id" => @thread, "turn_id" => "turn-#{marker}", "x-codex-window-id" => @window, "x-codex-turn-metadata" => CodexPooler.JSON.encode!(%{"session_id" => @thread, "thread_id" => @thread, "turn_id" => "turn-#{marker}", "request_kind" => "turn"})}}
  end

  defp frames(marker) do
    item = %{"id" => "msg_#{marker}", "type" => "message", "role" => "assistant", "status" => "completed", "content" => [%{"type" => "output_text", "text" => "synthetic output"}]}
    [%{"type" => "response.created", "response" => %{"id" => "resp_#{marker}", "status" => "in_progress", "output" => []}}, %{"type" => "response.output_item.done", "output_index" => 0, "item" => item}, %{"type" => "response.completed", "response" => %{"id" => "resp_#{marker}", "status" => "completed", "output" => [item], "usage" => %{"input_tokens" => 3, "output_tokens" => 2, "total_tokens" => 5}}}] |> Enum.map(&CodexPooler.JSON.encode!/1)
  end
end

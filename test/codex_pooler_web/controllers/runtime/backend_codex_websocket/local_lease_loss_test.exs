defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocket.LocalLeaseLossTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [gateway_setup: 1, public_websocket_connect!: 4, public_websocket_send_text!: 4, public_websocket_receive_close!: 4, register_unboxed_pool_cleanup!: 1, start_public_endpoint!: 0, start_upstream: 1]

  import CodexPoolerWeb.Runtime.BackendCodexWebsocketSupport,
    only: [socket_connection_state!: 1]

  alias CodexPooler.Accounting.Request
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Persistence.{BridgeOwnerLease, CodexSession, SessionContinuity}
  alias CodexPooler.Repo
  alias CodexPoolerWeb.Runtime.{MailboxLeaseLifecycleSupport, OwnerCrashAfterSendScenario, WebsocketCleanupFence}

  @moduletag capture_log: true
  @detection_timeout_ms 15_000

  setup do
    CodexPooler.TestAppEnv.restore_on_exit(:websocket_owner_forwarding_enabled)
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, false)
    :ok
  end

  for route <- ["/backend-api/codex/responses", "/v1/responses"] do
    test "#{route}: disconnect stops the direct socket heartbeat", do: assert_disconnect_stops_heartbeat!(unquote(route))

    for loss <- [:released, :replaced, :expired] do
      if loss == :expired do
        @tag slow: "waits for the real lease deadline on the PostgreSQL clock"
      end

      test "#{route}: #{loss} lease closes the direct socket without reviving its ownership", do: assert_lease_loss!(unquote(route), unquote(loss), :idle)
    end

    test "#{route}: replaced lease closes a direct socket with a held active turn", do: assert_lease_loss!(unquote(route), :replaced, :active)
  end

  defp assert_disconnect_stops_heartbeat!(route) do
    upstream = start_upstream(upstream_script(:idle, nil))
    setup = gateway_setup(upstream)
    client = connect!(setup, route)
    state = socket_connection_state!(client.socket)
    heartbeat = state.session_lease_heartbeat
    assert is_pid(heartbeat)
    monitor = Process.monitor(heartbeat)

    assert {:ok, _conn} = Mint.HTTP.close(client.conn)
    assert :ok = WebsocketCleanupFence.await_listener_socket_cleanup!(client.socket)
    assert_receive {:DOWN, ^monitor, :process, ^heartbeat, :normal}, @detection_timeout_ms
    assert FakeUpstream.count(upstream) == 0
    assert :ok = FakeUpstream.verify!(upstream)
  end

  defp assert_lease_loss!(route, loss, phase) do
    if phase == :active, do: OwnerCrashAfterSendScenario.per_process_connections!()
    release_ref = make_ref()
    upstream = start_upstream(upstream_script(phase, release_ref))
    setup = gateway_setup(upstream)
    register_fixture_cleanup!(setup, phase)
    client = connect!(setup, route)

    try do
      client = hold_turn!(client, setup, upstream, release_ref, phase)
      state = socket_connection_state!(client.socket)
      heartbeat = state.session_lease_heartbeat
      assert is_pid(heartbeat)
      assert is_nil(Map.get(state, :websocket_owner_pid))
      heartbeat_monitor = Process.monitor(heartbeat)
      task_monitors = Enum.map(state.tasks, &{&1, Process.monitor(&1)})

      if phase == :active do
        assert task_monitors != []
        assert map_size(state.direct_cleanup_contexts) > 0
      end

      renewal_token = hold_periodic_tick!(heartbeat)
      session = Repo.get!(CodexSession, state.codex_session.id)
      assert :ok = invalidate_lease!(loss, session, state.opts)
      before = ownership_snapshot!(session.id)

      {_result, log} =
        ExUnit.CaptureLog.with_log(fn ->
          send(heartbeat, {:session_lease_heartbeat_renew, renewal_token})
          assert_receive {:DOWN, ^heartbeat_monitor, :process, ^heartbeat, :normal}, @detection_timeout_ms
          {_conn, _websocket, code, reason} = public_websocket_receive_close!(client.conn, client.websocket, client.ref, @detection_timeout_ms)
          assert code == 1011
          assert reason == "websocket session lease unavailable"
          assert {:ok, _conn} = Mint.HTTP.close(client.conn)
          assert :ok = WebsocketCleanupFence.await_listener_socket_cleanup!(client.socket)

          for {task, monitor} <- task_monitors do
            assert_receive {:DOWN, ^monitor, :process, ^task, _reason}, @detection_timeout_ms
          end
        end)

      assert log =~ "session lease renewal failed phase=scheduled"
      assert log =~ "reason=#{if(loss == :replaced, do: "stale_owner", else: "owner_unavailable")}"
      after_close = ownership_snapshot!(session.id)
      assert after_close.session == before.session
      assert Enum.map(after_close.leases, &Map.take(&1, [:lease_token, :expires_at, :renewed_at])) == Enum.map(before.leases, &Map.take(&1, [:lease_token, :expires_at, :renewed_at]))

      if loss == :replaced do
        replacement = Enum.find(before.leases, &(&1.status == "active"))
        assert replacement
        assert Enum.find(after_close.leases, &(&1.lease_token == replacement.lease_token)) == replacement
      end

      if phase == :active do
        request = Repo.one!(from request in Request, where: request.pool_id == ^setup.pool.id)
        assert request.status == "failed"
        assert request.last_error_code == "client_disconnected"
        assert :ok = FakeUpstream.release_frame(upstream, release_ref)
        %{upstream_handler: handler, upstream_monitor: monitor} = client
        assert_receive {:DOWN, ^monitor, :process, ^handler, _reason}, @detection_timeout_ms
      end

      assert :ok = FakeUpstream.verify!(upstream)
      assert FakeUpstream.count(upstream) == if(phase == :active, do: 1, else: 0)
    after
      Mint.HTTP.close(client.conn)
    end
  end

  defp register_fixture_cleanup!(setup, :active), do: register_unboxed_pool_cleanup!(setup)
  defp register_fixture_cleanup!(_setup, :idle), do: :ok

  defp connect!(setup, route) do
    port = start_public_endpoint!()
    before = WebsocketCleanupFence.listener_sockets()
    {conn, websocket, ref} = public_websocket_connect!(port, setup, Ecto.UUID.generate(), route)
    socket = WebsocketCleanupFence.await_new_listener_socket!(before)
    %{conn: conn, websocket: websocket, ref: ref, socket: socket}
  end

  defp hold_turn!(client, _setup, _upstream, _release_ref, :idle), do: client

  defp hold_turn!(client, setup, _upstream, release_ref, :active) do
    frame = CodexPooler.JSON.encode!(%{"type" => "response.create", "model" => setup.model.exposed_model_id, "input" => [%{"role" => "user", "content" => "synthetic held turn"}], "stream" => true})
    {conn, websocket} = public_websocket_send_text!(client.conn, client.websocket, client.ref, frame)
    assert_receive {:fake_upstream_frame_barrier, 0, handler, ^release_ref}, @detection_timeout_ms
    Map.merge(client, %{conn: conn, websocket: websocket, upstream_handler: handler, upstream_monitor: Process.monitor(handler)})
  end

  defp upstream_script(:idle, _release_ref), do: FakeUpstream.json_response(%{"error" => "unexpected synthetic request"}, 500)

  defp upstream_script(:active, release_ref) do
    # provenance: synthetic_adversarial (lease replacement while a direct response is held before any provider output)
    FakeUpstream.strict_sequence([
      FakeUpstream.expect_request(method: "WEBSOCKET", path: "/backend-api/codex/responses", json: [valid: true], respond: FakeUpstream.barrier_websocket_frames([], notify: self(), release_ref: release_ref))
    ])
  end

  defp hold_periodic_tick!(heartbeat) do
    state =
      :sys.replace_state(heartbeat, fn state ->
        Process.cancel_timer(state.renewal_ref)
        token = state.renewal_token

        receive do
          {:session_lease_heartbeat_renew, ^token} -> :ok
        after
          0 -> :ok
        end

        state
      end)

    assert is_reference(state.renewal_token)
    state.renewal_token
  end

  defp invalidate_lease!(:released, session, _opts), do: SessionContinuity.release_owner_lease(session, session.owner_lease_token, "synthetic_lease_release")

  defp invalidate_lease!(:replaced, session, opts) do
    assert {:ok, replacement} = SessionContinuity.replace_unavailable_owner_lease(session, opts)
    refute replacement.owner_lease_token == session.owner_lease_token
    :ok
  end

  defp invalidate_lease!(:expired, session, _opts) do
    observation = MailboxLeaseLifecycleSupport.renew_and_observe_expiry!(session)
    assert observation.genuine_expiry
    :ok
  end

  defp ownership_snapshot!(session_id) do
    session = Repo.get!(CodexSession, session_id)
    leases = Repo.all(from lease in BridgeOwnerLease, where: lease.codex_session_id == ^session_id, order_by: [asc: lease.created_at])

    %{
      session: Map.take(session, [:owner_lease_token, :owner_instance_id, :owner_instance_boot_id, :owner_lease_expires_at, :status, :disconnected_at, :closed_at, :close_reason, :last_heartbeat_at]),
      leases: Enum.map(leases, &Map.take(&1, [:lease_token, :owner_instance_id, :owner_instance_boot_id, :status, :expires_at, :renewed_at, :released_at, :metadata]))
    }
  end
end

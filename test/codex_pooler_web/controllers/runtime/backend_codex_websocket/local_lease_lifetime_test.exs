defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocket.LocalLeaseLifetimeTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport, only: [gateway_setup: 1, native_text_input: 1, public_websocket_connect!: 4, public_websocket_send_text!: 4, start_public_endpoint!: 0, start_upstream: 1]
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketSupport, only: [await_socket_connection_state!: 2, await_succeeded_pool_requests!: 2, completed_response_frames: 4, model_serving_scope: 0, receive_native_terminal!: 3, set_model_serving_mode!: 3, socket_connection_state!: 1]

  alias CodexPooler.Access
  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPooler.Gateway.Persistence.{CodexTurn, RuntimeCleanup, SessionContinuity}
  alias CodexPooler.Repo
  alias CodexPoolerWeb.Runtime.{MailboxLeaseLifecycleSupport, WebsocketCleanupFence}

  @moduletag capture_log: true
  @detection_timeout_ms 15_000

  setup do
    CodexPooler.TestAppEnv.restore_on_exit(:websocket_owner_forwarding_enabled)
    CodexPooler.TestAppEnv.restore_on_exit(OperationalSettings)
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, false)
    settings = %{OperationalSettings.current() | bridge_owner_lease_ttl_seconds: 30, bridge_owner_lease_renewal_seconds: 1}
    Application.put_env(:codex_pooler, OperationalSettings, settings: settings)
    :ok
  end

  for mode <- ["full", "lite"], route <- ["/backend-api/codex/responses", "/v1/responses"] do
    @tag slow: "observes two real PostgreSQL lease deadlines, while streaming and while idle"
    test "#{mode} #{route}: periodic renewal survives streaming cleanup and an idle next turn" do
      assert_lifetime!(unquote(mode), unquote(route))
    end
  end

  defp assert_lifetime!(mode, route) do
    hold = make_ref()
    response_id = "resp_local_lease_first_#{mode}"
    frames = [CodexPooler.JSON.encode!(%{"type" => "response.created", "response" => %{"id" => response_id, "status" => "in_progress"}}), CodexPooler.JSON.encode!(%{"type" => "response.completed", "response" => %{"id" => response_id, "status" => "completed", "output" => [], "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}}})]

    upstream =
      start_upstream(
        # provenance: synthetic_adversarial (held success and independent next turn on one real connection)
        FakeUpstream.strict_sequence([
          FakeUpstream.expect_request(method: "WEBSOCKET", websocket_connection_ordinal: 1, json: [valid: true], respond: FakeUpstream.barrier_websocket_frames(frames, notify: self(), release_ref: hold)),
          FakeUpstream.expect_request(method: "WEBSOCKET", websocket_connection_ordinal: 1, json: [valid: true], respond: completed_response_frames("resp_local_lease_second_#{mode}", [], 4, 3))
        ])
      )

    setup = gateway_setup(upstream)
    set_model_serving_mode!(model_serving_scope(), setup, mode)
    port = start_public_endpoint!()
    before = WebsocketCleanupFence.listener_sockets()
    {conn, websocket, ref} = public_websocket_connect!(port, setup, Ecto.UUID.generate(), route)
    socket = WebsocketCleanupFence.await_new_listener_socket!(before)
    session = socket_connection_state!(socket).codex_session

    try do
      {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, frame(setup, "first"))
      assert_receive {:fake_upstream_frame_barrier, 0, _handler, ^hold}, @detection_timeout_ms
      :ok = FakeUpstream.release_frame(upstream, hold)
      assert_receive {:fake_upstream_frame_barrier, 1, _handler, ^hold}, @detection_timeout_ms

      assert_periodic_renewal_across_deadline!(session.id)
      assert {:ok, %{expired_owner_sessions_recovered: 0}} = RuntimeCleanup.cleanup_expired_runtime_state()
      assert Repo.one!(from r in Request, where: r.pool_id == ^setup.pool.id).status == "in_progress"

      :ok = FakeUpstream.release_remaining_frames(upstream, hold)
      {conn, websocket, terminal} = receive_native_terminal!(conn, websocket, ref)
      assert terminal["type"] == "response.completed"
      assert_receive {:fake_upstream_frame_barrier, 2, _handler, ^hold}, @detection_timeout_ms
      [_first] = await_succeeded_pool_requests!(setup.pool.id, 1)
      await_socket_connection_state!(socket, &(MapSet.size(&1.tasks) == 0))
      assert {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
      assert SessionContinuity.previous_response_session_id(auth, response_id) == session.id

      assert_periodic_renewal_across_deadline!(session.id)
      {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, frame(setup, "second"))
      {_conn, _websocket, terminal} = receive_native_terminal!(conn, websocket, ref)
      assert terminal["type"] == "response.completed"
      requests = await_succeeded_pool_requests!(setup.pool.id, 2)
      request_ids = Enum.map(requests, & &1.id)
      assert Enum.all?(requests, &(&1.usage_status == "usage_known" and &1.request_metadata["routing"]["model_serving_mode"] == mode))
      assert Repo.all(from t in CodexTurn, where: t.codex_session_id == ^session.id, select: t.status) == ["succeeded", "succeeded"]
      assert Repo.all(from a in Attempt, where: a.request_id in ^request_ids, select: {a.status, a.usage_status}) == [{"succeeded", "usage_known"}, {"succeeded", "usage_known"}]
      assert :ok = FakeUpstream.verify!(upstream)
    after
      _released_if_held = FakeUpstream.release_remaining_frames(upstream, hold)
      Mint.HTTP.close(conn)
      WebsocketCleanupFence.await_listener_socket_cleanup!(socket)
    end
  end

  defp frame(setup, text), do: CodexPooler.JSON.encode!(%{"type" => "response.create", "model" => setup.model.exposed_model_id, "input" => native_text_input("synthetic lease #{text}"), "stream" => true})

  defp assert_periodic_renewal_across_deadline!(session_id) do
    initial = MailboxLeaseLifecycleSupport.shorten_lease!(session_id, 2, suppressed?: false)
    observation = await_original_deadline!(session_id, initial.session_deadline, System.monotonic_time(:millisecond) + @detection_timeout_ms)
    assert observation.session_deadline == observation.lease_deadline
    assert DateTime.compare(observation.session_deadline, initial.session_deadline) == :gt
    assert DateTime.compare(observation.session_deadline, observation.clock) == :gt
  end

  defp await_original_deadline!(session_id, original_deadline, budget) do
    observation = MailboxLeaseLifecycleSupport.observe!(session_id)

    cond do
      DateTime.compare(observation.clock, original_deadline) == :gt ->
        observation

      System.monotonic_time(:millisecond) >= budget ->
        flunk("database clock did not cross the original lease deadline")

      true ->
        receive do
        after
          10 -> await_original_deadline!(session_id, original_deadline, budget)
        end
    end
  end
end

defmodule CodexPoolerWeb.Runtime.DownstreamKeepaliveScenarioTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.AccountingTestSupport
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport, only: [gateway_setup: 1, register_unboxed_pool_cleanup!: 1, start_upstream: 1]
  import CodexPoolerWeb.Runtime.DownstreamKeepaliveScenario

  alias CodexPooler.Accounting
  alias CodexPooler.Events
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Runtime.Finalization.Interruption
  alias CodexPooler.Gateway.Transports.Websocket.NativeCompactionTrace
  alias CodexPooler.Gateway.Websocket, as: Gateway
  alias Ecto.Adapters.SQL.Sandbox

  test "the dispatch hold restores absent and explicit trace modes without cancelling its in-flight callback" do
    previous = dispatch_trace_mode_state()
    supervisor = start_supervised!(Task.Supervisor)

    for mode_state <- [:absent, {:present, :configured}, {:present, :off}, {:present, :safe}, {:present, :full}] do
      hold = make_ref()
      on_exit({__MODULE__, hold}, fn -> restore_dispatch_trace(hold, previous) end)
      :ok = restore_dispatch_trace(hold, mode_state)

      task =
        Task.Supervisor.async_nolink(supervisor, fn ->
          receive do
            {^hold, :emit} -> NativeCompactionTrace.emit_full(:upstream_websocket_frame_sent, %{upstream_pid: self()})
          after
            15_000 -> flunk("the dispatch hold contract was never started")
          end
        end)

      target = task.pid

      try do
        :ok = install_dispatch_hold!(target, hold, self())
        send(target, {hold, :emit})
        assert_receive {^hold, :write_ready, ^target}, 15_000
        :ok = restore_dispatch_trace(hold, mode_state)
        assert dispatch_trace_mode_state() == mode_state
        refute Enum.any?(:telemetry.list_handlers(NativeCompactionTrace.event()), &(&1.id == {CodexPoolerWeb.Runtime.DownstreamKeepaliveScenario, hold}))
        assert Task.yield(task, 0) == nil
        send(target, {hold, :release})
        assert Task.await(task, 15_000) == :ok
      after
        try do
          restore_dispatch_trace(hold, previous)
        after
          send(target, {hold, :release})
          Task.shutdown(task, :brutal_kill)
        end
      end
    end
  end

  @tag capture_log: true
  @tag slow: "the real driver acknowledges two empty keepalive ticks before the owned initial dispatch releases"
  @tag late_first_progress: true
  test "the late-start fixture proves its phase on the real driver and its client Pong reaches that driver", context do
    CodexPooler.DataCase.stop_sandbox(context.sandbox_owner, context.sandbox_settings_cache)
    on_exit(fn -> Sandbox.mode(Repo, :manual) end)
    :ok = Sandbox.mode(Repo, :auto)
    put_settings!([websocket_idle_timeout_ms: 1_500, upstream_receive_timeout_ms: 1_000], false)
    upstream = start_upstream(FakeUpstream.delayed_sse_stream(stream_events("resp_late_start_fixture", 3), interval_ms: 100))
    setup = gateway_setup(upstream)
    register_unboxed_pool_cleanup!(setup)
    %{turn: turn, phase: phase} = assert_late_start_completed!(setup)

    assert phase.write_ready_at <= phase.first_tick_at
    assert phase.first_tick_at < phase.second_tick_at
    assert phase.second_tick_at <= phase.released_at
    assert phase.released_at < phase.initial_deadline
    assert phase.first_pong_received_at < phase.initial_deadline
    assert phase.renewed_deadline > phase.initial_deadline
    assert turn.pongs == turn.pings
    assert turn.client.sent_at + turn.first_event_ms > phase.released_at
    assert FakeUpstream.count(upstream) == 1
  end

  test "idle attribution reloads the settled snapshot after its metadata has committed" do
    fixture = settled_fixture()
    assert {:ok, :ok} = Interruption.record_settled_downstream_idle_timeout(fixture.receipt, "pong_observed")
    assert fixture.request.request_metadata["downstream_interruption"] == nil

    assert_idle_attribution!(fixture.request, "pong_observed")
  end

  test "idle attribution waits for its request's metadata after settlement" do
    fixture = settled_fixture()
    test = self()
    hold = make_ref()
    handler_id = {__MODULE__, hold}
    on_exit(fn -> :telemetry.detach(handler_id) end)
    supervisor = start_supervised!(Task.Supervisor)

    task =
      Task.Supervisor.async_nolink(supervisor, fn ->
        :ok = Events.subscribe_pool(fixture.setup.pool)
        send(test, {hold, :subscribed, self()})

        receive do
          {^hold, :start} ->
            assert_idle_attribution!(fixture.request, "pong_observed")
            Process.info(self(), :messages)
        after
          15_000 -> flunk("attribution waiter was never started")
        end
      end)

    waiter = task.pid
    assert_receive {^hold, :subscribed, ^waiter}, detection_timeout_ms()
    request_id = fixture.request.id
    dumped_request_id = Ecto.UUID.dump!(request_id)
    config = %{waiter: waiter, test: test, hold: hold, request_id: dumped_request_id}
    :ok = :telemetry.attach(handler_id, [:codex_pooler, :repo, :query], &__MODULE__.observe_request_read/4, config)

    send(waiter, {hold, :start})
    assert_receive {^hold, :request_read, ^waiter}, detection_timeout_ms()
    assert Repo.reload!(fixture.request).request_metadata["downstream_interruption"] == nil

    # An unrelated request's update is not this request's attribution fence.
    other_event = {Events, %{reason: "request_metadata_updated", payload: %{"request_id" => Ecto.UUID.generate(), "status" => "failed"}}}
    send(waiter, other_event)
    assert {:ok, :ok} = Interruption.record_settled_downstream_idle_timeout(fixture.receipt, "pong_observed")
    assert {:messages, messages} = Task.await(task, detection_timeout_ms())
    assert other_event in messages
  end

  @doc false
  def observe_request_read(_event, _measurements, %{query: query, params: params}, config) do
    if self() == config.waiter and String.starts_with?(query, "SELECT") and String.contains?(query, ~s(FROM "requests")) and config.request_id in List.flatten(params),
      do: send(config.test, {config.hold, :request_read, self()})
  end

  defp settled_fixture do
    setup = accounting_setup()
    assert :ok = Events.subscribe_pool(setup.pool)
    {:ok, session} = Gateway.start_codex_session(setup.auth, %{accepted_turn_state: Ecto.UUID.generate()})
    {:ok, reserved} = Accounting.reserve(setup.auth, setup.model, %{}, %{transport: "websocket", requested_model: setup.model.exposed_model_id, correlation_id: Ecto.UUID.generate()})
    {:ok, attempt} = Accounting.create_attempt(reserved.request, setup.assignment, %{transport: "websocket"})
    {:ok, _turn} = Gateway.start_codex_turn(session, reserved.request)
    request = Repo.reload!(reserved.request)
    receipt = %{session_id: session.id, request_id: request.id, correlation_id: request.correlation_id, api_key_id: setup.api_key.id, owner_binding: nil, attempt_id: attempt.id, replay_generation: attempt.replay_generation}
    assert :ok = Interruption.interrupt_direct_request(receipt, "client_disconnected")
    request = Repo.reload!(request)
    assert request.status == "failed"
    assert request.last_error_code == "client_disconnected"
    %{request: request, receipt: receipt, setup: setup}
  end
end

defmodule CodexPooler.Gateway.Transports.Websocket.SettlementCancellationTest do
  use ExUnit.Case, async: false

  alias CodexPooler.Gateway.Transports.RolloutDrainFailureSupport
  alias CodexPooler.Gateway.Transports.Websocket.{ActivityDrain, ActivityRegistry}

  @detection_timeout_ms 10_000

  setup do
    name = :"websocket-settlement-cancellation-#{System.unique_integer([:positive])}"
    registry = start_supervised!({ActivityRegistry, name: name})
    supervisor = start_supervised!({Task.Supervisor, []})
    {:ok, registry: registry, supervisor: supervisor}
  end

  test "cancellation queued before protection prevents the executor entering settlement", %{registry: registry, supervisor: supervisor} do
    parent = self()

    {:ok, actor} =
      Task.Supervisor.start_child(supervisor, fn ->
        {:ok, token} = ActivityRegistry.register(:proxy, self(), name: registry)
        :ok = ActivityRegistry.admit(token, name: registry)
        send(parent, {:ready, self(), token})

        receive do
          :enter_settlement ->
            :ok = ActivityRegistry.protect_response_settlement(token, 60_000, name: registry)
            send(parent, {:settlement_entered, self()})
        end
      end)

    monitor = Process.monitor(actor)
    assert_receive {:ready, ^actor, token}, @detection_timeout_ms
    {barrier, ^registry} = RolloutDrainFailureSupport.hold_call!(registry, :other)
    cancellation = Task.Supervisor.async_nolink(supervisor, fn -> ActivityRegistry.cancel_unless_settling(actor, :websocket_terminated, name: registry) end)
    assert_receive {^barrier, :call_held, ^registry, _caller}, @detection_timeout_ms

    # Observe the real API call queued behind cancellation, so this exercises
    # the mailbox race rather than sending work to an already dead executor.
    assert 1 = :erlang.trace(actor, true, [:send, {:tracer, self()}])
    send(actor, :enter_settlement)
    assert_receive {:trace, ^actor, :send, {:"$gen_call", _from, {:protect_response_settlement, ^token, 60_000}}, ^registry}, @detection_timeout_ms
    assert 1 = :erlang.trace(actor, false, [:send])
    send(registry, {barrier, :release})

    assert Task.await(cancellation, @detection_timeout_ms) == :cancelled
    assert_receive {:DOWN, ^monitor, :process, ^actor, {:shutdown, :websocket_terminated}}, @detection_timeout_ms
    refute_received {:settlement_entered, ^actor}
  end

  test "rollout drain forces a protected executor to stop after its settlement cutoff", %{registry: registry, supervisor: supervisor} do
    parent = self()

    {:ok, actor} =
      Task.Supervisor.start_child(supervisor, fn ->
        {:ok, token} = ActivityRegistry.register(:direct, self(), name: registry)
        :ok = ActivityRegistry.admit(token, name: registry)
        :ok = ActivityRegistry.protect_response_settlement(token, 60_000, name: registry)
        send(parent, {:ready, self(), token})

        receive do
          {:websocket_activity_cancel, ^token, :owner_drained} ->
            send(parent, {:rollout_cancel_received, self()})
            receive do: (:never -> :ok)
        end
      end)

    monitor = Process.monitor(actor)
    assert_receive {:ready, ^actor, token}, @detection_timeout_ms
    assert {:settling, _deadline} = ActivityRegistry.cancel_unless_settling(actor, :websocket_terminated, name: registry)
    assert :ok = ActivityRegistry.mark_terminal_delivered(actor, name: registry)
    assert {epoch, [%{token: ^token} = entry]} = ActivityRegistry.begin_drain(name: registry)

    policy = %{
      now_ms: fn -> System.monotonic_time(:millisecond) end,
      schedule_wait: fn recipient, ref, ms -> Process.send_after(recipient, {:rollout_drain_wait_elapsed, ref}, ms) end,
      cancel_wait: fn timer, _ref ->
        Process.cancel_timer(timer)
        :ok
      end,
      owner_post_deadline_call_budget_ms: 100
    }

    drain = Task.Supervisor.async_nolink(supervisor, fn -> ActivityDrain.drain(entry, System.monotonic_time(:millisecond) - 1, policy, registry) end)
    assert_receive {:rollout_cancel_received, ^actor}, @detection_timeout_ms
    assert Task.await(drain, @detection_timeout_ms) == :aborted
    assert_receive {:DOWN, ^monitor, :process, ^actor, :killed}, @detection_timeout_ms
    assert :ok = ActivityRegistry.complete_drain(epoch, name: registry)
  end
end

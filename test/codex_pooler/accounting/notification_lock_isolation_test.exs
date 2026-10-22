defmodule CodexPooler.Accounting.NotificationLockIsolationTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Accounting
  alias CodexPooler.Events
  alias CodexPooler.Events.{Outbox, OutboxEntry}
  alias CodexPooler.Gateway.Persistence.CodexTurn
  alias CodexPooler.Gateway.Runtime.Finalization.Interruption
  alias CodexPooler.Gateway.Websocket
  alias CodexPooler.Pools.Pool
  alias CodexPooler.Upstreams.Schemas.{PoolUpstreamAssignment, UpstreamIdentity}
  alias Ecto.Adapters.SQL.Sandbox

  import CodexPooler.PoolerFixtures
  import CodexPooler.UnboxedFixture

  @detection_timeout_ms 15_000

  setup do
    slug = "notification-lock-#{System.unique_integer([:positive])}"

    register_unboxed_cleanup!(fn ->
      pool_ids = Repo.all(from pool in Pool, where: pool.slug == ^slug, select: pool.id)
      identity_ids = Repo.all(from assignment in PoolUpstreamAssignment, where: assignment.pool_id in ^pool_ids, select: assignment.upstream_identity_id)
      Repo.delete_all(from event in OutboxEntry, where: fragment("?::jsonb->>'pool_id'", event.payload) in ^pool_ids)
      delete_committed_pools!(pool_ids)
      Repo.delete_all(from identity in UpstreamIdentity, where: identity.id in ^identity_ids)
    end)

    fixture = run_unboxed(fn -> disconnect_fixture(slug) end)
    assert {:ok, _} = run_unboxed(fn -> Outbox.drain() end)
    %{fixture: fixture}
  end

  test "a stalled disconnect notification owns no settlement bucket or session locks", %{fixture: fixture} do
    parent = self()
    token = make_ref()
    handler_id = {__MODULE__, token}
    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok = :telemetry.attach(handler_id, [:codex_pooler, :repo, :query], &__MODULE__.observe_notification/4, {parent, token})
    assert :ok = Events.subscribe_pool(fixture.pool.id)
    config = Keyword.take(Repo.config(), [:hostname, :port, :database, :username, :password, :ssl])
    observer = start_supervised!({Postgrex, config}, id: :observer)
    contender = start_supervised!({Postgrex, config}, id: :contender)
    [[contender_backend]] = Postgrex.query!(contender, "SELECT pg_backend_pid()", []).rows

    finalizer =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Process.put({__MODULE__, :observer}, {parent, token, :finalizer})
          Interruption.interrupt_direct_request(receipt(fixture), "client_disconnected")
        end)
      end)

    finalizer_monitor = Process.monitor(finalizer.pid)
    result = Task.await(finalizer, @detection_timeout_ms)
    assert_receive {:DOWN, ^finalizer_monitor, :process, _, :normal}, @detection_timeout_ms
    assert result == :ok or match?({:ok, _}, result)
    # The handler and completion run in one producer: completion orders every
    # notification query it could have emitted, without a negative timeout.
    refute_received {:notification_from_finalizer, ^token, _in_transaction}
    assert [["failed", "client_disconnected"]] = Postgrex.query!(observer, "SELECT status, last_error_code FROM requests WHERE id = $1", [Ecto.UUID.dump!(fixture.request.id)]).rows
    assert [[pending]] = Postgrex.query!(observer, "SELECT count(*) FROM accounting_event_outbox WHERE payload::jsonb->>'pool_id' = $1", [fixture.pool.id]).rows
    assert pending >= 2

    sender =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Process.put({__MODULE__, :observer}, {parent, token, :sender})
          Outbox.drain(timeout: @detection_timeout_ms)
        end)
      end)

    sender_monitor = Process.monitor(sender.pid)
    on_exit(fn -> send(sender.pid, token) end)
    assert_receive {:notification_paused, ^token, sender_backend, sender_txid}, @detection_timeout_ms
    assert sender_backend != contender_backend
    refute_received {Events, %{reason: "request_finalized"}}

    waiter =
      Task.async(fn ->
        Postgrex.transaction(contender, fn connection ->
          Postgrex.query!(connection, "SET LOCAL lock_timeout = '3s'", [])
          buckets = Postgrex.query!(connection, "SELECT api_key_id FROM api_key_usage_buckets WHERE api_key_id = $1 FOR UPDATE", [Ecto.UUID.dump!(fixture.request.api_key_id)])
          session = Postgrex.query!(connection, "SELECT id FROM codex_sessions WHERE id = $1 FOR UPDATE", [Ecto.UUID.dump!(fixture.session.id)])
          {buckets.num_rows, session.num_rows}
        end)
      end)

    waiter_monitor = Process.monitor(waiter.pid)
    assert {:ok, {bucket_count, 1}} = Task.await(waiter, @detection_timeout_ms)
    assert_receive {:DOWN, ^waiter_monitor, :process, _, :normal}, @detection_timeout_ms
    assert bucket_count > 0
    assert [[[]]] = Postgrex.query!(observer, "SELECT pg_blocking_pids($1)", [contender_backend]).rows
    ledger = Postgrex.query!(observer, "SELECT entry_kind, xmin::text FROM ledger_entries WHERE request_id = $1 ORDER BY entry_kind", [Ecto.UUID.dump!(fixture.request.id)]).rows
    assert [["release", settlement_txid], ["reservation", _], ["settlement", settlement_txid]] = ledger
    assert settlement_txid != sender_txid
    send(sender.pid, token)
    assert {:ok, ^pending} = Task.await(sender, @detection_timeout_ms)
    assert_receive {:DOWN, ^sender_monitor, :process, _, :normal}, @detection_timeout_ms
    assert_receive {Events, %{reason: "request_finalized"}}, @detection_timeout_ms
    assert_receive {Events, %{reason: "usage_updated"}}, @detection_timeout_ms
    assert [[0]] = Postgrex.query!(observer, "SELECT count(*) FROM accounting_event_outbox WHERE payload::jsonb->>'pool_id' = $1", [fixture.pool.id]).rows
  end

  @doc false
  def observe_notification(_event, _measurements, metadata, {parent, token}) do
    if String.contains?(metadata.query, "pg_notify") do
      case Process.get({__MODULE__, :observer}) do
        {^parent, ^token, :finalizer} ->
          send(parent, {:notification_from_finalizer, token, Repo.in_transaction?()})

        {^parent, ^token, :sender} ->
          Process.delete({__MODULE__, :observer})
          [[backend, txid]] = Repo.query!("SELECT pg_backend_pid(), pg_current_xact_id()::text").rows
          send(parent, {:notification_paused, token, backend, txid})

          receive do
            ^token -> :ok
          after
            @detection_timeout_ms -> raise "notification barrier expired"
          end

        _other ->
          :ok
      end
    end
  end

  defp disconnect_fixture(slug) do
    pool = pool_fixture(%{slug: slug})
    key = active_api_key_fixture(pool)
    model = model_fixture(pool)
    %{assignment: assignment} = upstream_assignment_fixture(pool)
    now = DateTime.utc_now()
    {:ok, session} = Websocket.start_codex_session(key, %{accepted_turn_state: Ecto.UUID.generate()})
    {:ok, %{request: request}} = Accounting.reserve(key, model, %{"model" => model.exposed_model_id}, %{transport: "websocket", endpoint: "/backend-api/codex/responses", codex_session: session, correlation_id: Ecto.UUID.generate()})
    {:ok, attempt} = Accounting.create_attempt(request, assignment)
    Repo.insert!(%CodexTurn{codex_session_id: session.id, request_id: request.id, turn_sequence: 1, transport_kind: "websocket", semantic_turn_digest: :crypto.strong_rand_bytes(32), status: "in_progress", final_attempt_id: attempt.id, started_at: now, created_at: now, updated_at: now})
    %{pool: pool, session: session, request: request, attempt: attempt}
  end

  defp receipt(fixture) do
    %{session_id: fixture.session.id, request_id: fixture.request.id, correlation_id: fixture.request.correlation_id, api_key_id: fixture.request.api_key_id, attempt_id: fixture.attempt.id, replay_generation: fixture.attempt.replay_generation}
  end
end

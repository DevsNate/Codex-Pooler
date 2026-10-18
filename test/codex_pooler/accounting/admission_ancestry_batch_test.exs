defmodule CodexPooler.Accounting.AdmissionAncestryBatchTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures

  alias CodexPooler.Accounting.{ClientRetry, LedgerEntry, NativeContentFilterRetry, Request, RequestClientRetryLink}
  alias CodexPooler.Accounting.RequestLifecycle.{FailedPredecessorResend, Reservation, TurnClaimRelease}
  alias CodexPooler.Gateway.Persistence.{CodexSession, CodexTurn}
  alias CodexPooler.Gateway.Persistence.SessionContinuity.MailboxAdmissionLocks
  alias Ecto.Adapters.SQL.Sandbox

  @endpoint "/backend-api/codex/responses"
  @budget 15_000

  @tag admission_ancestry_query_cost: true
  test "discovery from the original claim retains seventeen sessions with bounded SELECT and WITH reads" do
    fixture = fixture()
    original = node!(fixture)
    nodes = Enum.scan(1..16, original, fn _, previous -> successor!(fixture, previous) end)
    expected = session_set([original | nodes])

    {ids, reads} = count_reads(fn -> FailedPredecessorResend.admission_session_ids(original.request.correlation_id, fixture.scope) end)

    assert MapSet.new(ids) == expected
    assert MapSet.size(expected) == 17
    assert reads > 0
    assert reads <= 90
  end

  test "root, one edge, sixteen edges and depth-truncated seventeen edges preserve exact sessions" do
    fixture = fixture()
    original = node!(fixture)
    assert sessions(original, fixture) == session_set([original])
    nodes = Enum.scan(1..17, original, fn _, previous -> successor!(fixture, previous) end)
    assert sessions(hd(nodes), fixture) == session_set([original, hd(nodes)])
    assert sessions(Enum.at(nodes, 15), fixture) == session_set([original | Enum.take(nodes, 16)])
    assert sessions(List.last(nodes), fixture) == session_set(nodes)
  end

  test "mixed claims use the validated root and an invalid middle edge resets that root" do
    fixture = fixture()
    original = node!(fixture)
    first = successor!(fixture, original, {:client, original.request})
    second = successor!(fixture, first)
    third = successor!(fixture, second, {:client, original.request})
    assert sessions(third, fixture) == session_set([original, first, second, third])

    second = update_request(second, correlation_id: "client-retry-v1:forged")
    assert sessions(third, fixture) == session_set([third])
    {:ok, claim} = ClientRetry.deterministic_successor_claim(second.request, second.request.id)
    third = update_request(third, correlation_id: claim)
    assert sessions(third, fixture) == session_set([second, third])
  end

  test "compaction edges retain the fresh turn and replay digest checks" do
    fixture = fixture()
    original = node!(fixture)
    replay = :crypto.strong_rand_bytes(32)
    {:ok, claim} = ClientRetry.deterministic_compaction_successor_claim(original.request, original.turn, replay)
    next = node!(fixture, claim)
    link!(original, next)
    scope = Map.put(fixture.scope, :replay_claim_digest, replay)
    assert MapSet.new(ClientRetry.admission_linked_session_ids(next.request, scope)) == session_set([original, next])
    assert sessions(next, fixture) == session_set([next])
    Repo.update_all(from(t in CodexTurn, where: t.id == ^original.turn.id), set: [semantic_turn_digest: :crypto.strong_rand_bytes(32)])
    assert MapSet.new(ClientRetry.admission_linked_session_ids(next.request, scope)) == session_set([next])
  end

  test "missing incoming links and cyclic historical links retain bounded invalid-edge behavior" do
    fixture = fixture()
    original = node!(fixture)
    first = successor!(fixture, original)
    second = successor!(fixture, first)
    link!(second, original)
    assert sessions(second, fixture) == session_set([original, first, second])
    Repo.delete_all(from l in RequestClientRetryLink, where: l.successor_request_id == ^second.request.id)
    assert sessions(second, fixture) == session_set([second])
  end

  test "each recursive edge is scoped without rejecting the caller's supplied seed" do
    fixture = fixture()
    foreign = fixture()

    for {field, value} <- [pool_id: foreign.scope.pool_id, api_key_id: foreign.scope.api_key_id, model_id: foreign.scope.model_id, endpoint: "/backend-api/codex/responses/compact"] do
      original = node!(fixture)
      first = successor!(fixture, original)
      second = successor!(fixture, first)
      original = update_request(original, [{field, value}])
      assert sessions(second, fixture) == session_set([first, second])
      assert sessions(original, fixture) == session_set([original])
    end
  end

  test "the supplied seed is not reloaded before validating its incoming edge or outgoing witness" do
    fixture = fixture()
    original = node!(fixture)
    next = successor!(fixture, original)
    _changed = update_request(next, correlation_id: "client-retry-v1:changed-after-read")
    assert sessions(next, fixture) == session_set([original, next])

    root = node!(fixture)
    child = successor!(fixture, root, {:client, root.request})
    _changed = update_request(root, native_client_retry_digest: :crypto.strong_rand_bytes(32))
    assert sessions(root, fixture) == session_set([root, child])
  end

  test "a committed incoming edge after discovery forces fresh locked rediscovery" do
    fixture = committed_fixture()

    {original, next} =
      Sandbox.unboxed_run(Repo, fn ->
        original = node!(fixture)
        {:ok, claim} = ClientRetry.deterministic_failed_predecessor_claim(original.request.correlation_id, original.request.id)
        {original, node!(fixture, claim)}
      end)

    run_race(fixture, next, :after_discovery, fn -> link!(original, next) end, fn holder ->
      assert holder.id == next.request.id
    end)
  end

  for release <- [:claim_only, :content_filter], phase <- [:after_discovery, :locked_ancestry] do
    if phase == :locked_ancestry do
      @tag ancestry_cte_barrier: true
    end

    test "#{release} release and replacement after #{phase} cannot reuse stale claim authority" do
      run_release_race(unquote(release), unquote(phase))
    end
  end

  defp run_release_race(release, phase) do
    fixture = committed_fixture()

    {original, old, ledger} =
      Sandbox.unboxed_run(Repo, fn ->
        original = node!(fixture)
        {:ok, claim} = ClientRetry.deterministic_failed_predecessor_claim(original.request.correlation_id, original.request.id)
        old = node!(fixture, claim, release != :claim_only)
        link!(original, old)
        old = update_request(old, status: "failed", response_status_code: 503, last_error_code: "no_eligible_backend", request_metadata: %{"client_resend" => %{"predecessor_request_id" => original.request.id}, "native_content_filter_pin" => %{"version" => 1, "assignment_id" => fixture.assignment.id, "identity_id" => fixture.assignment.upstream_identity_id}})
        ledger = if release == :content_filter, do: ledger_entry_fixture(old.request) |> then(&Repo.get!(LedgerEntry, &1.id))
        {original, old, ledger}
      end)

    run_race(
      fixture,
      old,
      phase,
      fn ->
        release_request!(release, old.request)

        released = Repo.get!(Request, old.request.id)
        refute released.correlation_id == old.request.correlation_id
        assert released.request_metadata["released_turn_claim"] == old.request.correlation_id
        replacement = node!(fixture, old.request.correlation_id)
        link!(original, replacement)
        replacement.request.id
      end,
      fn holder ->
        refute holder.id == old.request.id
        assert holder.correlation_id == old.request.correlation_id
        assert Repo.aggregate(from(r in Request, where: r.correlation_id == ^holder.correlation_id), :count) == 1
        assert Repo.aggregate(from(l in RequestClientRetryLink, where: l.predecessor_request_id == ^original.request.id), :count) == 1
        refute Repo.exists?(from l in RequestClientRetryLink, where: l.successor_request_id == ^old.request.id)
        if ledger, do: assert(Repo.get!(LedgerEntry, ledger.id) == ledger)
      end
    )
  end

  defp run_race(fixture, seed, phase, writer, verify) do
    parent = self()
    ref = make_ref()
    handler = {__MODULE__, ref}
    calls = :atomics.new(2, [])
    on_exit(fn -> :telemetry.detach(handler) end)

    gate = %{parent: parent, ref: ref, handler: handler, calls: calls}
    actor = Task.async(fn -> Sandbox.unboxed_run(Repo, fn -> run_actor(fixture, seed, phase, verify, gate) end) end)

    on_exit(fn ->
      monitor = Process.monitor(actor.pid)
      if Process.alive?(actor.pid), do: Process.exit(actor.pid, :kill)
      assert_receive {:DOWN, ^monitor, :process, _, _}, @budget
    end)

    monitor = Process.monitor(actor.pid)
    assert_receive {:actor_backend, ^ref, actor_backend}, @budget
    assert_receive {:discovery_paused, ^ref, actor_pid}, @budget

    writer_backend =
      Sandbox.unboxed_run(Repo, fn ->
        writer_backend = backend_pid()
        refute writer_backend == actor_backend
        writer.()
        writer_backend
      end)

    refute writer_backend == actor_backend
    send(actor_pid, {:resume, ref})
    assert {:ok, id} = Task.await(actor, @budget)
    assert is_binary(id)
    assert_receive {:DOWN, ^monitor, :process, _, :normal}, @budget
    assert :atomics.get(calls, 1) == 2
    :telemetry.detach(handler)
  end

  defp release_request!(:claim_only, request) do
    assert {:ok, %Request{}} =
             Repo.transaction(fn ->
               held = Repo.one!(from r in Request, where: r.id == ^request.id, lock: "FOR UPDATE")
               TurnClaimRelease.close!(held, %{status: "rejected"}, :reservation_refused)
             end)
  end

  defp release_request!(:content_filter, request), do: assert(:ok = NativeContentFilterRetry.release_refused_retry(request))

  defp run_actor(fixture, seed, phase, verify, gate) do
    send(gate.parent, {:actor_backend, gate.ref, backend_pid()})
    opts = %{endpoint: @endpoint, correlation_id: seed.request.correlation_id}
    attach_locked_barrier(phase, gate)

    discover = fn ->
      ids = Reservation.mailbox_admission_session_ids(fixture.auth, fixture.model, opts)
      if phase == :after_discovery, do: pause_once(gate)
      ids
    end

    MailboxAdmissionLocks.transaction(
      discover,
      fn ->
        :atomics.add(gate.calls, 1, 1)
        :ok = Reservation.revalidate_mailbox_admission_sessions!(fixture.auth, fixture.model, opts)
        current = Repo.get_by!(Request, correlation_id: seed.request.correlation_id)
        ClientRetry.require_admission_request_sessions!(current, fixture.scope)
        held = Repo.one!(from r in Request, where: r.id == ^current.id, lock: "FOR UPDATE")
        ClientRetry.require_admission_request_sessions!(held, fixture.scope)
        verify.(held)
        held.id
      end,
      :rediscovery_exhausted
    )
  end

  defp attach_locked_barrier(:locked_ancestry, gate), do: assert(:ok = :telemetry.attach(gate.handler, [:codex_pooler, :repo, :query], &pause_on_locked_read/4, {self(), gate}))
  defp attach_locked_barrier(:after_discovery, _gate), do: :ok

  defp pause_on_locked_read(_event, _measurements, metadata, {actor, gate}) do
    if self() == actor and Repo.in_transaction?() and String.starts_with?(metadata[:query] || "", "WITH RECURSIVE"), do: pause_once(gate)
  end

  defp pause_once(%{ref: ref} = gate) do
    if :atomics.compare_exchange(gate.calls, 2, 0, 1) == :ok do
      send(gate.parent, {:discovery_paused, ref, self()})
      receive do: ({:resume, ^ref} -> :ok)
    end
  end

  defp fixture(owner \\ nil) do
    pool = pool_fixture(if(owner, do: %{created_by_user_id: owner.id}, else: %{}))
    %{api_key: key} = active_api_key_fixture(pool, if(owner, do: %{created_by_user_id: owner.id}, else: %{}))
    model = model_fixture(pool)
    %{assignment: assignment} = upstream_assignment_fixture(pool)
    %{auth: %{pool: pool, api_key: key}, pool: pool, api_key: key, model: model, assignment: assignment, scope: %{pool_id: pool.id, api_key_id: key.id, model_id: model.id, endpoint: @endpoint}}
  end

  defp committed_fixture do
    %{user: owner} = committed_bootstrap_owner_fixture!()
    Sandbox.unboxed_run(Repo, fn -> fixture(owner) end)
  end

  defp node!(fixture, claim \\ "codex-request:#{Ecto.UUID.generate()}", with_turn \\ true) do
    now = DateTime.utc_now()
    session = Repo.insert!(%CodexSession{pool_id: fixture.pool.id, api_key_id: fixture.api_key.id, session_key: Ecto.UUID.generate(), status: "active", created_at: now, updated_at: now})
    request = request_fixture(fixture, %{model_id: fixture.model.id, correlation_id: claim, transport: "websocket", status: "failed"})
    request = request |> Ecto.Changeset.change(native_client_retry_version: 1, native_client_retry_digest: :crypto.strong_rand_bytes(32), native_client_retry_auth_epoch: 0) |> Repo.update!()
    turn = if with_turn, do: Repo.insert!(%CodexTurn{codex_session_id: session.id, request_id: request.id, turn_sequence: 1, transport_kind: "websocket", semantic_turn_digest: :crypto.strong_rand_bytes(32), status: "failed", started_at: now, completed_at: now, created_at: now, updated_at: now})
    %{request: request, session: session, turn: turn}
  end

  defp successor!(fixture, previous, kind \\ :failed) do
    {:ok, claim} =
      case kind do
        :failed -> ClientRetry.deterministic_failed_predecessor_claim(previous.request.correlation_id, previous.request.id)
        {:client, original} -> ClientRetry.deterministic_successor_claim(original, previous.request.id)
      end

    next = node!(fixture, claim)
    link!(previous, next)
    next
  end

  defp link!(previous, next), do: Repo.insert!(%RequestClientRetryLink{predecessor_request_id: previous.request.id, successor_request_id: next.request.id, created_at: DateTime.utc_now()})
  defp update_request(node, attrs), do: %{node | request: node.request |> Ecto.Changeset.change(attrs) |> Repo.update!()}
  defp sessions(node, fixture), do: MapSet.new(ClientRetry.admission_linked_session_ids(node.request, fixture.scope))
  defp session_set(nodes), do: MapSet.new(nodes, & &1.session.id)
  defp backend_pid, do: Repo.query!("SELECT pg_backend_pid()").rows |> hd() |> hd()

  defp count_reads(operation) do
    handler = {__MODULE__, make_ref()}
    counter = :atomics.new(1, [])
    actor = self()
    on_exit(fn -> :telemetry.detach(handler) end)

    :ok =
      :telemetry.attach(
        handler,
        [:codex_pooler, :repo, :query],
        fn _, _, metadata, _ ->
          if self() == actor and metadata[:repo] == Repo and String.starts_with?(metadata[:query] || "", ["SELECT", "WITH"]), do: :atomics.add(counter, 1, 1)
        end,
        nil
      )

    try do
      {operation.(), :atomics.get(counter, 1)}
    after
      :telemetry.detach(handler)
    end
  end
end

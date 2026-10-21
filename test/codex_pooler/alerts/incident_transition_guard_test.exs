defmodule CodexPooler.Alerts.IncidentTransitionGuardTest do
  use CodexPooler.DataCase, async: false

  import Ecto.Query
  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures
  import CodexPooler.UnboxedFixture

  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Alerts
  alias CodexPooler.Alerts.Schemas.AlertIncident
  alias CodexPooler.Audit.AuditEvent
  alias CodexPooler.Repo
  alias Ecto.Adapters.SQL.Sandbox

  test "re-reads the persisted incident and rejects stale and duplicate transitions" do
    %{user: owner} = bootstrap_owner_fixture(%{"email" => unique_user_email()})
    scope = Scope.for_user(owner)
    pool = pool_fixture()
    incident = alert_incident_fixture(pool: pool)

    assert {:ok, resolved} = Alerts.resolve_incident(scope, incident.id)
    assert resolved.state == "resolved"
    resolved_at = resolved.resolved_at

    assert {:error, %{code: :invalid_transition}} =
             Alerts.acknowledge_incident(scope, incident.id)

    assert {:error, %{code: :invalid_transition}} =
             Alerts.acknowledge_incident(scope, incident)

    persisted = Repo.get!(AlertIncident, incident.id)
    assert persisted.state == "resolved"
    assert persisted.resolved_at == resolved_at

    assert Repo.aggregate(
             from(event in AuditEvent,
               where: event.target_type == "alert_incident" and event.target_id == ^incident.id and event.action == "alert_incident.acknowledge"
             ),
             :count
           ) == 0
  end

  test "allows only open acknowledge and open or acknowledged resolve transitions" do
    %{user: owner} = bootstrap_owner_fixture(%{"email" => unique_user_email()})
    scope = Scope.for_user(owner)
    pool = pool_fixture()

    open_incident = alert_incident_fixture(pool: pool)
    assert {:ok, acknowledged} = Alerts.acknowledge_incident(scope, open_incident.id)
    assert acknowledged.state == "acknowledged"
    assert {:ok, resolved} = Alerts.resolve_incident(scope, acknowledged.id)
    assert resolved.state == "resolved"

    assert {:error, %{code: :invalid_transition}} =
             Alerts.resolve_incident(scope, resolved.id)
  end

  test "resolver commit wins over a blocked acknowledge on independent connections" do
    %{user: owner} = committed_bootstrap_owner_fixture!()
    scope = Scope.for_user(owner)
    fixture = committed_incident_fixture!(owner.id)
    tasks = start_supervised!(Task.Supervisor)

    holder = hold_incident_lock!(tasks, fixture.incident_id, :resolve, scope)

    try do
      waiter = start_transition_task(tasks, scope, fixture.incident_id, :acknowledge, :acknowledger)
      await_lock_waiter!(waiter.backend, holder.backend)
      send(holder.pid, {:release, holder.ref})

      assert {:error, %{code: :invalid_transition}} = await_transition(waiter.task)
      assert Repo.get!(AlertIncident, fixture.incident_id).state == "resolved"
      assert audit_previous_state(fixture.incident_id, "alert_incident.resolve") == "open"
      refute audit_event_exists?(fixture.incident_id, "alert_incident.acknowledge")
    after
      release_holder(holder)
    end
  end

  test "blocked resolver observes an acknowledgement committed first" do
    %{user: owner} = committed_bootstrap_owner_fixture!()
    scope = Scope.for_user(owner)
    fixture = committed_incident_fixture!(owner.id)
    tasks = start_supervised!(Task.Supervisor)

    holder = hold_incident_lock!(tasks, fixture.incident_id, :acknowledge, scope)

    try do
      waiter = start_transition_task(tasks, scope, fixture.incident_id, :resolve, :resolver)
      await_lock_waiter!(waiter.backend, holder.backend)
      send(holder.pid, {:release, holder.ref})

      assert {:ok, %{state: "resolved"}} = await_transition(waiter.task)
      assert Repo.get!(AlertIncident, fixture.incident_id).state == "resolved"
      assert audit_previous_state(fixture.incident_id, "alert_incident.acknowledge") == "open"
      assert audit_previous_state(fixture.incident_id, "alert_incident.resolve") == "acknowledged"
    after
      release_holder(holder)
    end
  end

  defp committed_incident_fixture!(owner_id) do
    slug = "incident-transition-#{System.unique_integer([:positive])}"
    dedupe_key = "alert:incident-transition:#{System.unique_integer([:positive])}"

    register_unboxed_cleanup!(fn ->
      pool_ids = Repo.all(from pool in CodexPooler.Pools.Pool, where: pool.slug == ^slug, select: pool.id)
      incident_ids = Repo.all(from incident in AlertIncident, where: incident.dedupe_key == ^dedupe_key, select: incident.id)

      Repo.delete_all(from event in AuditEvent, where: event.target_id in ^incident_ids)
      Repo.delete_all(from incident in AlertIncident, where: incident.id in ^incident_ids)
      delete_committed_pools!(pool_ids)
    end)

    fixture =
      run_unboxed(fn ->
        pool = pool_fixture(%{created_by_user_id: owner_id, slug: slug})
        incident = alert_incident_fixture(pool: pool, dedupe_key: dedupe_key)
        %{pool_id: pool.id, incident_id: incident.id}
      end)

    fixture
  end

  defp hold_incident_lock!(tasks, incident_id, action, scope) do
    parent = self()
    ref = make_ref()

    task =
      Task.Supervisor.async_nolink(tasks, fn ->
        Sandbox.unboxed_run(Repo, fn ->
          hold_lock_transaction(incident_id, action, scope, parent, ref)
        end)
      end)

    assert_receive {:held, ^ref, backend}, 15_000
    %{pid: task.pid, task: task, backend: backend, ref: ref}
  end

  defp start_transition_task(tasks, scope, incident_id, action, role) do
    parent = self()
    ref = make_ref()

    task =
      Task.Supervisor.async_nolink(tasks, fn ->
        Sandbox.unboxed_run(Repo, fn ->
          backend = backend_pid()
          send(parent, {:waiter, ref, backend, role})
          apply(Alerts, "#{action}_incident" |> String.to_existing_atom(), [scope, incident_id])
        end)
      end)

    assert_receive {:waiter, ^ref, backend, ^role}, 15_000
    %{task: task, backend: backend}
  end

  defp hold_lock_transaction(incident_id, action, scope, parent, ref) do
    Repo.transaction(fn ->
      Repo.one!(from incident in AlertIncident, where: incident.id == ^incident_id, lock: "FOR UPDATE")
      assert {:ok, _} = apply(Alerts, "#{action}_incident" |> String.to_existing_atom(), [scope, incident_id])
      send(parent, {:held, ref, backend_pid()})

      receive do
        {:release, ^ref} -> :released
      end
    end)
  end

  defp await_lock_waiter!(waiter, blocker, deadline \\ System.monotonic_time(:millisecond) + 15_000) do
    blocked? =
      run_unboxed(fn ->
        Repo.query!("SELECT 1 FROM pg_stat_activity WHERE pid = $1 AND $2 = ANY(pg_blocking_pids(pid))", [waiter, blocker]).num_rows == 1
      end)

    if blocked? do
      :ok
    else
      assert System.monotonic_time(:millisecond) < deadline, "transition did not wait on the incident row lock"

      receive do
      after
        10 -> await_lock_waiter!(waiter, blocker, deadline)
      end
    end
  end

  defp await_transition(task), do: Task.await(task, 15_000)

  defp release_holder(holder) do
    send(holder.pid, {:release, holder.ref})
    Task.await(holder.task, 15_000)
  end

  defp backend_pid, do: Repo.query!("SELECT pg_backend_pid()").rows |> hd() |> hd()

  defp audit_previous_state(incident_id, action) do
    Repo.one!(from event in AuditEvent, where: event.target_id == ^incident_id and event.action == ^action, select: event.details["previous_state"])
  end

  defp audit_event_exists?(incident_id, action), do: Repo.exists?(from event in AuditEvent, where: event.target_id == ^incident_id and event.action == ^action)
end

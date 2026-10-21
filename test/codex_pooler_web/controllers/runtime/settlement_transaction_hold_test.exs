defmodule CodexPoolerWeb.Runtime.SettlementTransactionHoldTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Repo
  alias CodexPoolerWeb.Runtime.SettlementTransactionHold

  @detection_timeout_ms 15_000
  @observation_timeout_ms 2_000

  test "a session lookup queued behind another waiter is observed before the settlement releases" do
    schema = "settlement_hold_#{System.unique_integer([:positive])}"

    # Registered before the committed DDL. Test-supervised connections stop
    # first, rolling back any transaction left open by a failed assertion.
    on_exit(fn ->
      {:ok, connection} = Postgrex.start_link(connection_options())

      try do
        Postgrex.query!(connection, ~s(DROP SCHEMA IF EXISTS "#{schema}" CASCADE))
      after
        GenServer.stop(connection)
      end
    end)

    observer = start_connection!()
    Postgrex.query!(observer, ~s(CREATE SCHEMA "#{schema}"))
    Postgrex.query!(observer, ~s(SET search_path TO "#{schema}"))
    Postgrex.query!(observer, "CREATE TABLE codex_sessions (id integer PRIMARY KEY)")
    Postgrex.query!(observer, "CREATE TABLE bridge_session_aliases (codex_session_id integer)")
    Postgrex.query!(observer, "INSERT INTO codex_sessions VALUES (1)")
    Postgrex.query!(observer, "INSERT INTO bridge_session_aliases VALUES (1)")

    settler = start_connection!(schema)
    preceding = start_connection!(schema)
    lookup = start_connection!(schema)
    settler_backend = backend!(settler)
    preceding_backend = backend!(preceding)
    lookup_backend = backend!(lookup)
    assert length(Enum.uniq([settler_backend, preceding_backend, lookup_backend])) == 3

    Postgrex.query!(settler, "BEGIN")
    Postgrex.query!(settler, "SELECT id FROM codex_sessions WHERE id = 1 FOR UPDATE")

    preceding_task = Task.async(fn -> Postgrex.query!(preceding, "SELECT id FROM codex_sessions WHERE id = 1 FOR UPDATE") end)

    await_blocked_by!(observer, preceding_backend, settler_backend)

    lookup_task =
      Task.async(fn ->
        Postgrex.query!(lookup, ~s(SELECT c0.id FROM "codex_sessions" AS c0 INNER JOIN "bridge_session_aliases" AS b1 ON b1.codex_session_id = c0.id WHERE c0.id = 1 FOR UPDATE OF c0))
      end)

    supervisor = start_supervised!({Task.Supervisor, []}, id: make_ref())
    parent = self()
    observation = make_ref()

    try do
      await_blocked_by!(observer, lookup_backend, preceding_backend)
      assert Postgrex.query!(observer, "SELECT $1 = ANY(pg_blocking_pids($2))", [settler_backend, lookup_backend]).rows == [[false]]

      watch =
        Task.Supervisor.async_nolink(supervisor, fn ->
          relation = SettlementTransactionHold.await_session_lookup_wait!(observer, settler_backend)
          send(parent, {observation, :observed_relation, relation})
        end)

      try do
        # The real waiters have already reached their exact blocker. Require
        # the helper's receipt while both remain blocked, before their query
        # timeouts can mask a missing observation.
        assert_receive {^observation, :observed_relation, "codex_sessions"}, @observation_timeout_ms
      after
        Task.shutdown(watch, :brutal_kill)
      end
    after
      Postgrex.query!(settler, "ROLLBACK")
      assert %Postgrex.Result{num_rows: 1} = Task.await(preceding_task, @detection_timeout_ms)
      assert %Postgrex.Result{rows: [[1]]} = Task.await(lookup_task, @detection_timeout_ms)
    end
  end

  defp start_connection!(schema \\ nil) do
    options =
      case schema do
        nil -> connection_options()
        schema -> Keyword.put(connection_options(), :parameters, search_path: schema)
      end

    start_supervised!({Postgrex, options}, id: make_ref())
  end

  defp connection_options, do: Repo.config() |> Keyword.take([:hostname, :port, :username, :password, :database, :socket_dir])

  defp backend!(connection) do
    %{rows: [[backend]]} = Postgrex.query!(connection, "SELECT pg_backend_pid()")
    backend
  end

  defp await_blocked_by!(observer, waiter, blocker),
    do: await_blocked_by!(observer, waiter, blocker, System.monotonic_time(:millisecond) + @detection_timeout_ms)

  defp await_blocked_by!(observer, waiter, blocker, deadline) do
    case Postgrex.query!(observer, "SELECT $1 = ANY(pg_blocking_pids($2))", [blocker, waiter]).rows do
      [[true]] ->
        :ok

      [[false]] ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk("the owned PostgreSQL waiter never reached its expected blocker")
        else
          Process.sleep(10)
          await_blocked_by!(observer, waiter, blocker, deadline)
        end
    end
  end
end

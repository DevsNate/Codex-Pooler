defmodule CodexPoolerWeb.Admin.PoolsAsyncPauseLiveTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures

  alias CodexPooler.Accounts
  alias CodexPooler.Pools
  alias CodexPooler.Repo

  setup :register_and_log_in_user

  for outcome <- [:success, :stale_owner] do
    @tag outcome: outcome
    test "automatic #{outcome} completion holds traffic while paused and resume catches up once", %{conn: conn, scope: scope, outcome: outcome} do
      {:ok, pool} = Pools.create_pool(scope, %{name: "Pause sample", slug: "pause-sample"})
      %{api_key: key} = api_key_fixture(pool)
      request_fixture(%{pool: pool, api_key: key})
      {:ok, view, _} = live(conn, ~p"/admin/pools")
      render_async(view)
      expire_cooldown(view)
      before = view |> element("#pool-row-#{pool.id}-request-count") |> render()
      request_fixture(%{pool: pool, api_key: key})

      with_barrier(view, fn barrier ->
        send(view.pid, :fallback_refresh_pool_traffic)
        assert_receive {^barrier, task}, 5_000
        completion = if outcome == :success, do: :release, else: {:stale_owner, scope.user.id}
        release_after_events(view, task, barrier, [fn -> render_hook(view, "set_live_updates", %{"paused" => true}) end], completion)
        render_async(view)
        assert view |> element("#pool-row-#{pool.id}-request-count") |> render() == before
        refute state(view).pool_traffic_loading?
        refute state(view).pool_traffic_rerun?
        assert state(view).live_updates_page_held?
      end)

      expire_cooldown(view)
      render_hook(view, "set_live_updates", %{"paused" => false})
      render_async(view)
      assert has_element?(view, "#pool-row-#{pool.id}-request-count", "2")
      refute state(view).pool_traffic_rerun?
    end
  end

  test "cooldown holds an automatic rerun but permits an explicit paused viewport request", %{conn: conn, scope: scope} do
    {:ok, pool} = Pools.create_pool(scope, %{name: "Cooldown sample", slug: "cooldown-sample"})
    {:ok, view, _} = live(conn, ~p"/admin/pools")
    render_async(view)
    send(view.pid, :fallback_refresh_pool_traffic)
    assert state(view).pool_traffic_rerun?
    render_hook(view, "set_live_updates", %{"paused" => true})
    old_token = expire_cooldown(view)
    refute state(view).pool_traffic_running?
    assert state(view).live_updates_page_held?

    with_barrier(view, fn barrier ->
      render_hook(view, "set_pool_traffic_visibility", %{"pool_id" => pool.id, "visible" => true})
      assert_receive {^barrier, task}, 5_000
      send(task, {barrier, :release})
      render_async(view)
      assert state(view).live_updates_paused?
      token = state(view).pool_traffic_cooldown_token
      send(view.pid, {:pool_traffic_cooldown_elapsed, old_token})
      assert state(view).pool_traffic_cooldown_token == token
      refute state(view).pool_traffic_running?
    end)
  end

  test "an explicit window queued behind automatic work is not demoted by another event", %{conn: conn, scope: scope} do
    {:ok, _pool} = Pools.create_pool(scope, %{name: "Window sample", slug: "window-sample"})
    {:ok, view, _} = live(conn, ~p"/admin/pools")
    render_async(view)
    expire_cooldown(view)

    with_barrier(view, fn barrier ->
      send(view.pid, :fallback_refresh_pool_traffic)
      assert_receive {^barrier, task}, 5_000

      release_after_events(view, task, barrier, [
        fn -> render_patch(view, ~p"/admin/pools?traffic_window=1h") end
      ])

      render_async(view)
      render_hook(view, "set_live_updates", %{"paused" => true})
      :atomics.put(Process.get(barrier), 1, 1)
      expire_cooldown(view)
      assert_receive {^barrier, explicit_task}, 5_000
      send(explicit_task, {barrier, :release})
      render_async(view)
      assert state(view).pool_filters["traffic_window"] == "1h"
      refute state(view).pool_traffic_loading?
      assert state(view).live_updates_paused?
    end)
  end

  # PoolTrafficGate owns a checkout across the read. Queue real UI events
  # before releasing it instead of deadlocking the shared sandbox connection.
  defp release_after_events(view, task, barrier, actions, completion \\ :release) do
    {_ref, _topic, proxy} = view.proxy
    view_pid = view.pid
    :erlang.trace(proxy, true, [:send])

    try do
      calls =
        Enum.map(actions, fn action ->
          call = Task.async(action)
          assert_receive {:trace, ^proxy, :send, %Phoenix.Socket.Message{event: event}, ^view_pid}, 5_000
          assert event in ["event", "live_patch"]
          send(view.pid, :fallback_refresh_pool_traffic)
          call
        end)

      send(task, {barrier, completion})
      Enum.each(calls, &Task.await(&1, 5_000))
    after
      :erlang.trace(proxy, false, [:send])
      send(task, {barrier, :release})
    end
  end

  test "initial and permission refreshes load while the session is paused", %{scope: scope} do
    {:ok, first} = Pools.create_pool(scope, %{name: "Visible sample", slug: "visible-sample"})
    {:ok, second} = Pools.create_pool(scope, %{name: "Granted sample", slug: "granted-sample"})
    %{user: operator} = operator_fixture(scope, %{"role" => "instance_admin", "password_change_required" => "false"})
    operator_pool_assignment_fixture(operator, first, created_by_user_id: scope.user.id)
    {:ok, %{token: token}} = Accounts.login_user(%{"email" => operator.email, "password" => valid_user_password()})
    conn = build_conn() |> log_in_user(operator, token) |> put_connect_params(%{"live_updates_paused" => true})
    {:ok, view, _} = live(conn, ~p"/admin/pools")
    render_async(view)
    assert state(view).live_updates_paused?
    assert has_element?(view, "#pool-row-#{first.id}")
    {:ok, _} = Accounts.update_operator(scope, operator, %{"pool_ids" => [second.id]})
    state(view)
    state(view)
    refute has_element?(view, "#pool-row-#{first.id}")
    assert has_element?(view, "#pool-row-#{second.id}")
    expire_cooldown(view)
    render_async(view)
    assert state(view).live_updates_paused?
    refute state(view).pool_traffic_loading?
  end

  defp state(view), do: :sys.get_state(view.pid).socket.assigns

  defp expire_cooldown(view) do
    assigns = state(view)
    Repo.query!("UPDATE admin_pool_traffic_gates SET cooldown_until = statement_timestamp(), updated_at = statement_timestamp() WHERE operator_id = $1::text::uuid AND owner_token IS NULL", [assigns.current_scope.user.id])
    if is_reference(assigns.pool_traffic_cooldown_timer), do: Process.cancel_timer(assigns.pool_traffic_cooldown_timer, async: false, info: false)
    send(view.pid, {:pool_traffic_cooldown_elapsed, assigns.pool_traffic_cooldown_token})
    state(view)
    assigns.pool_traffic_cooldown_token
  end

  defp with_barrier(view, fun) do
    barrier = make_ref()
    parent = self()
    handler = {__MODULE__, barrier}
    gate = :atomics.new(1, [])
    :atomics.put(gate, 1, 1)
    Process.put(barrier, gate)
    tasks = :ets.new(:held_queries, [:public])

    :ok =
      :telemetry.attach(
        handler,
        [:codex_pooler, :repo, :query],
        fn _, _, metadata, _ ->
          if traffic_query?(metadata, view.pid) and :atomics.compare_exchange(gate, 1, 1, 0) == :ok do
            :ets.insert(tasks, {self()})
            monitor = Process.monitor(parent)
            send(parent, {barrier, self()})

            receive do
              {^barrier, :release} ->
                :ok

              {^barrier, {:stale_owner, operator_id}} ->
                Repo.query!("UPDATE admin_pool_traffic_gates SET owner_token = NULL, lease_expires_at = NULL WHERE operator_id = $1::text::uuid", [operator_id])

              {^barrier, :exit} ->
                Process.unlink(view.pid)
                Process.exit(self(), :kill)

              {:DOWN, ^monitor, :process, ^parent, _} ->
                :ok
            end

            Process.demonitor(monitor, [:flush])
          end
        end,
        nil
      )

    try do
      fun.(barrier)
    after
      :telemetry.detach(handler)
      for {pid} <- :ets.tab2list(tasks), do: send(pid, {barrier, :release})
      :ets.delete(tasks)
      Process.delete(barrier)

      if Process.alive?(view.pid) do
        for {_name, {_ref, pid, _kind}} <- :sys.get_state(view.pid).socket.private.live_async, do: send(pid, {barrier, :release})
        render_async(view)
      end
    end
  end

  defp traffic_query?(metadata, view_pid) do
    query = to_string(metadata[:query] || "")
    metadata[:repo] == Repo and view_pid in Process.get(:"$callers", []) and not String.contains?(query, ["admin_pool_traffic", "pg_advisory"])
  end
end

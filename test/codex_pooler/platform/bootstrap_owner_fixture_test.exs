defmodule CodexPooler.BootstrapOwnerFixtureTest do
  @moduledoc """
  Locks when `CodexPooler.AccountsFixtures.bootstrap_owner_fixture/1` may hand back an owner that
  already exists.

  The bootstrap singleton admits one owner, so a second call in the same test gets the first owner
  back. The fixture used to hand back any existing owner, including one another test had committed
  and never removed, so a later test asking for its own email passed with the leaked owner and the
  leak stayed invisible.
  """
  use CodexPooler.DataCase, async: false

  import CodexPooler.AccountsFixtures
  import CodexPooler.UnboxedFixture

  alias CodexPooler.Accounts
  alias CodexPooler.Accounts.User
  alias CodexPooler.Events
  alias CodexPooler.Events.OutboxEntry
  alias CodexPooler.PoolerFixtures
  alias CodexPooler.Pools.Pool

  test "raises instead of handing out a committed owner this test did not create",
       %{sandbox_owner: owner, sandbox_settings_cache: cache} do
    leaked_email = unique_user_email()
    register_unboxed_cleanup!(fn -> delete_users_by_email!(leaked_email) end)

    # Registered after the cleanup so that it runs first: bootstrapping inside the sandbox locks the
    # committed singleton, and the cleanup would wait on that lock until the sandbox ends.
    on_exit(fn -> stop_sandbox(owner, cache) end)

    {:ok, _committed} =
      run_unboxed(fn ->
        Accounts.bootstrap_owner(valid_bootstrap_attributes(%{"email" => leaked_email}))
      end)

    assert_raise RuntimeError, ~r/which this test did not create/, fn ->
      bootstrap_owner_fixture(%{"email" => unique_user_email()})
    end
  end

  test "raises when a later call names another email than the owner this test created" do
    %{user: _owner} = bootstrap_owner_fixture()

    assert_raise RuntimeError, ~r/another email than the one requested/, fn ->
      bootstrap_owner_fixture(%{"email" => unique_user_email()})
    end
  end

  test "hands the owner this test created back to a later call" do
    email = unique_user_email()
    %{user: %User{id: id}} = bootstrap_owner_fixture(%{"email" => email})

    assert %{user: %User{id: ^id}} = bootstrap_owner_fixture()
    assert %{user: %User{id: ^id}} = bootstrap_owner_fixture(%{"email" => email})
  end

  test "hands back the owner committed_bootstrap_owner_fixture!/1 committed for this test",
       %{sandbox_owner: owner, sandbox_settings_cache: cache} do
    %{user: %User{id: id}} = committed_bootstrap_owner_fixture!()

    # Logging in inside the sandbox locks the committed owner's row; stop the sandbox before its
    # registered removal runs.
    on_exit(fn -> stop_sandbox(owner, cache) end)

    assert %{user: %User{id: ^id}} = bootstrap_owner_fixture()
  end

  test "deleting an owner graph removes only its Pools' pending invalidations" do
    %{user: owner} = bootstrap_owner_fixture()
    deleted = PoolerFixtures.pool_fixture(%{created_by_user_id: owner.id})
    kept = PoolerFixtures.pool_fixture()

    assert {:ok, {:ok, deleted_event}} =
             Repo.transaction(fn -> Events.broadcast_request_logs(deleted.id, "request_reserved") end)

    assert {:ok, {:ok, kept_event}} =
             Repo.transaction(fn -> Events.broadcast_request_logs(kept.id, "request_reserved") end)

    delete_user_graph!([owner.id])

    refute Repo.get(User, owner.id)
    refute Repo.get(Pool, deleted.id)
    refute Repo.get(OutboxEntry, deleted_event.id)
    assert Repo.get!(Pool, kept.id)
    assert Repo.get!(OutboxEntry, kept_event.id)
  end

  defp delete_users_by_email!(email) do
    User
    |> where([user], user.email == ^email)
    |> select([user], user.id)
    |> Repo.all()
    |> delete_user_graph!()
  end
end

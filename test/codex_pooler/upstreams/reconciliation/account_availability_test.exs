defmodule CodexPooler.Upstreams.Reconciliation.AccountAvailabilityTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures

  alias CodexPooler.FakeUpstream
  alias CodexPooler.Upstreams.Quota.{AccountAvailabilityStore, AccountQuotaWindow, RoutingQuotaSnapshot}
  alias CodexPooler.Upstreams.Quota.Windows.Routing
  alias CodexPooler.Upstreams.Reconciliation.PoolReconciliation

  @paths ["/backend-api/wham/usage", "/backend-api/codex/usage"]

  for receipt <- [:conflicting, :legacy] do
    test "#{receipt} windowed HTTP receipt preserves a current blocked observation" do
      at = now()
      {fake, identity, assignment, prior} = setup_upstream(unquote(receipt), :blocked, at)

      assert {:ok, refreshed, probe} = PoolReconciliation.refresh_quota_and_probe_from_usage(identity, assignment, observed_at: at)
      assert_neutral_observation(probe, unquote(receipt))
      persisted = Repo.reload!(refreshed)
      assert persisted.metadata[AccountAvailabilityStore.metadata_key()] == prior
      assert persisted.metadata["unrelated"] == "kept"
      assert %{eligible?: false, routing_state: :blocked} = physical_eligibility(persisted, at)
      assert_usage_requested(fake)
    end

    for prior_state <- [:available, :unknown] do
      test "#{receipt} windowed HTTP receipt retires prior #{prior_state} observation" do
        at = now()
        {fake, identity, assignment, _prior} = setup_upstream(unquote(receipt), unquote(prior_state), at)

        assert {:ok, refreshed, probe} = PoolReconciliation.refresh_quota_and_probe_from_usage(identity, assignment, observed_at: at)
        assert_neutral_observation(probe, unquote(receipt))
        persisted = Repo.reload!(refreshed)
        refute Map.has_key?(persisted.metadata, AccountAvailabilityStore.metadata_key())
        assert persisted.metadata["unrelated"] == "kept"
        assert %{eligible?: true, routing_state: :precise} = physical_eligibility(persisted, at)
        assert_usage_requested(fake)
      end
    end

    test "#{receipt} windowed HTTP receipt does not retain another credential epoch's denial" do
      at = now()
      {fake, identity, assignment, _prior} = setup_upstream(unquote(receipt), :blocked, at, 2)

      assert {:ok, refreshed, probe} = PoolReconciliation.refresh_quota_and_probe_from_usage(identity, assignment, observed_at: at)
      assert_neutral_observation(probe, unquote(receipt))
      persisted = Repo.reload!(refreshed)
      refute Map.has_key?(persisted.metadata, AccountAvailabilityStore.metadata_key())
      assert %{eligible?: true, routing_state: :precise} = physical_eligibility(persisted, at)
      assert_usage_requested(fake)
    end
  end

  test "explicit affirmative HTTP receipt replaces blocked observation and restores ordinary routing" do
    at = now()
    {fake, identity, assignment, prior} = setup_upstream(:affirmative, :blocked, at)

    assert {:ok, refreshed, probe} = PoolReconciliation.refresh_quota_and_probe_from_usage(identity, assignment, observed_at: at)
    assert probe.account_availability.state == :available
    persisted = Repo.reload!(refreshed)
    assert persisted.metadata[AccountAvailabilityStore.metadata_key()] == AccountAvailabilityStore.encode!(:available, at, 1)
    refute persisted.metadata[AccountAvailabilityStore.metadata_key()] == prior
    assert %{eligible?: true, routing_state: :precise} = physical_eligibility(persisted, at)
    assert_usage_requested(fake)
  end

  defp setup_upstream(receipt, prior_state, at, prior_epoch \\ 1) do
    name = :"account_availability_fake_#{System.unique_integer([:positive])}"

    on_exit(fn ->
      if pid = Process.whereis(name) do
        FakeUpstream.stop(%FakeUpstream{supervisor: pid})
        refute Process.alive?(pid)
      end

      assert Process.whereis(name) == nil
    end)

    routes = Map.new(@paths, &{&1, {200, usage_payload(receipt, at)}})
    assert {:ok, fake} = FakeUpstream.start_link({:path_json, routes}, supervisor_name: name)
    Process.unlink(fake.supervisor)
    metadata = %{"usage_base_url" => FakeUpstream.url(fake), "unrelated" => "kept"}
    %{identity: identity, assignment: assignment} = active_upstream_assignment_fixture(pool_fixture(), %{metadata: metadata})
    prior = AccountAvailabilityStore.encode!(prior_state, DateTime.add(at, -1, :day), prior_epoch)
    identity = Repo.update!(Ecto.Changeset.change(identity, metadata: Map.put(identity.metadata, AccountAvailabilityStore.metadata_key(), prior)))
    {fake, identity, assignment, prior}
  end

  defp usage_payload(receipt, at) do
    window = %{"used_percent" => 40, "limit_window_seconds" => 18_000, "reset_after_seconds" => 3600, "reset_at" => DateTime.to_unix(DateTime.add(at, 3600))}
    payload = %{"rate_limit" => %{"primary_window" => window}}

    if receipt == :legacy do
      update_in(payload, ["rate_limit", "primary_window"], &Map.delete(&1, "reset_after_seconds"))
    else
      payload
      |> Map.put("plan_type", "sample_plan")
      |> put_in(["rate_limit", "allowed"], true)
      |> put_in(["rate_limit", "limit_reached"], receipt == :conflicting)
    end
  end

  defp assert_neutral_observation(probe, :conflicting) do
    assert %{state: :unknown, basis: :conflict, account_windows: :present} = probe.account_availability
  end

  defp assert_neutral_observation(probe, :legacy), do: assert(is_nil(probe.account_availability))

  defp physical_eligibility(identity, at) do
    windows = Repo.all(from window in AccountQuotaWindow, where: window.upstream_identity_id == ^identity.id)
    assert [%{quota_scope: "account", quota_family: "account", quota_key: "account"}] = windows
    identity |> RoutingQuotaSnapshot.from_identity(windows, at) |> Routing.eligibility_from_snapshot()
  end

  defp assert_usage_requested(fake) do
    requests = FakeUpstream.requests(fake)
    assert requests != []
    assert Enum.all?(requests, &(&1.path in @paths))
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end

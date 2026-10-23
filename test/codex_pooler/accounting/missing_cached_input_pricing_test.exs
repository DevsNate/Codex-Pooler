defmodule CodexPooler.Accounting.MissingCachedInputPricingTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Accounting
  alias CodexPooler.Accounting.{LedgerEntry, Request}
  alias CodexPooler.Accounting.PricingResolution.Costing
  alias CodexPooler.Accounting.PricingResolution.Generations
  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Catalog.{ContextPricing, OpenAIPricingFormat, OpenAIPricingImporter, PricingSnapshot}

  import CodexPooler.AccountingTestSupport, only: [accounting_setup: 0]
  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures

  @generated_at "2026-07-28T00:00:00Z"
  @unpriced "unpriced_missing_cached_input_rate"

  test "absent cached rates remain nil through classification and persisted settlement projections" do
    for {rate, cached, expected} <- [{nil, 400, nil}, {nil, 0, 30_000}, {nil, nil, 30_000}, {0, 400, 18_000}, {3, 400, 19_200}] do
      setup = accounting_setup()
      Repo.delete!(setup.pricing)
      rates = rates(rate)
      payload = catalog(setup.model.pricing_ref, %{"standard" => %{"default" => rates}})
      assert %{compatible?: true, rows: [row]} = OpenAIPricingFormat.classify(payload)
      assert_rate(row.cached_input, rate)
      assert {:ok, %{inserted: 1}} = import!(payload)
      assert {:ok, %{inserted: 0}} = import!(payload)

      snapshot = Repo.one!(from p in PricingSnapshot, where: p.model_identifier == ^setup.model.pricing_ref)
      assert_rate(snapshot.cached_input_token_micros, rate)
      assert snapshot.config["importer_format_revision"] == "5"

      {reserved, result} = settle!(setup, cached)
      assert reserved.pricing_status == "priced"
      assert result.settlement.pricing_snapshot_id == snapshot.id
      assert_projection!(setup, result, cached, expected, rate)
    end
  end

  test "the shipped feed's omitted cached rate produces unavailable cost without denying the request" do
    assert {:ok, %{price_version: version}} = CodexPooler.Catalog.import_openai_pricing_from_priv()
    setup = accounting_setup()
    model = model_fixture(setup.pool, %{exposed_model_id: "gpt-5.5-pro", upstream_model_id: "gpt-5.5-pro", pricing_ref: "gpt-5.5-pro"})
    setup = %{setup | model: model}
    {reserved, result} = settle!(setup, 400)
    assert reserved.pricing_status == "priced"
    snapshot = Repo.get!(PricingSnapshot, result.settlement.pricing_snapshot_id)
    assert snapshot.price_version == version
    assert is_nil(snapshot.cached_input_token_micros)
    assert_projection!(setup, result, 400, nil, nil)
  end

  test "revision 5 reimport corrects new settlements without rewriting revision 3 history" do
    setup = accounting_setup()

    old =
      setup.pricing
      |> Ecto.Changeset.change(
        price_version: @generated_at <> ":importer-format-3",
        effective_at: ~U[2026-07-28 00:00:00.000000Z],
        input_token_micros: Decimal.new(30),
        cached_input_token_micros: Decimal.new(0),
        output_token_micros: Decimal.new(180),
        config: Map.merge(setup.pricing.config, %{"importer_format_revision" => "3", "catalog_schema_version" => 1, "context_pricing" => ContextPricing.legacy()})
      )
      |> Repo.update!()

    old = Repo.get!(PricingSnapshot, old.id)

    {_reserved, historical} = settle!(setup, 400)
    historical_ledger = Repo.get!(LedgerEntry, historical.settlement.id)
    assert historical_ledger.details["pricing_status"] == "priced", inspect(historical_ledger.details)
    assert historical_ledger.usage_status == "usage_known"
    assert Decimal.equal?(historical_ledger.settled_cost_micros, 18_000)
    assert historical_ledger.pricing_snapshot_id == old.id
    payload = catalog(setup.model.pricing_ref, %{"standard" => %{"default" => rates(nil)}})
    assert {:ok, %{inserted: 1, price_version: version}} = import!(payload)
    assert version == @generated_at <> ":importer-format-5"
    assert {:ok, %{inserted: 0}} = import!(payload)
    {_reserved, corrected} = settle!(setup, 400)
    assert corrected.settlement.pricing_snapshot_id != old.id
    assert corrected.settlement.details["pricing_status"] == @unpriced
    assert is_nil(corrected.settlement.details["cached_input_cost_micros"])
    assert Repo.get!(PricingSnapshot, old.id) == old
    assert Repo.get!(LedgerEntry, historical_ledger.id) == historical_ledger
    record("revision_upgrade", %{revision: "5", idempotent_reimport: true, old_snapshot_unchanged: true, old_settlement_unchanged: true, corrected_status: corrected.settlement.details["pricing_status"]})
  end

  test "final served tier and context bucket cannot borrow an older generation's cached rate" do
    setup = accounting_setup()
    Repo.delete!(setup.pricing)
    tiers = Map.new(~w(standard priority), &{&1, %{"default" => rates(3), "long_context" => rates(3)}})
    payload = catalog(setup.model.pricing_ref, tiers)
    assert {:ok, _} = import!(payload)
    missing = payload |> Map.put("generated_at", "2026-07-29T00:00:00Z") |> put_in(["models", setup.model.pricing_ref, "timestamp"], "2026-07-29T00:00:00Z") |> update_in(["models", setup.model.pricing_ref, "prices", "priority", "long_context"], &Map.delete(&1, "cached_input"))
    assert {:ok, _} = import!(missing)

    {reserved, result} = settle!(setup, 400, input: 272_001, tier: "priority")
    assert reserved.pricing_status == "priced"
    assert reserved.pricing_snapshot.config["service_tier"] == "standard"
    assert reserved.pricing_snapshot.config["price_bucket"] == "default"
    selected = Repo.get!(PricingSnapshot, result.settlement.pricing_snapshot_id)
    assert selected.price_version == "2026-07-29T00:00:00Z:importer-format-5"
    assert selected.config["service_tier"] == "priority"
    assert selected.config["price_bucket"] == "long_context"
    assert result.settlement.details["pricing_status"] == @unpriced
    assert is_nil(result.settlement.details["settled_cost_micros"])
    assert is_nil(result.settlement.details["cached_input_cost_micros"])
    record("final_tier_and_context", %{reserved_tier: "standard", reserved_bucket: "default", served_tier: selected.config["service_tier"], selected_bucket: selected.config["price_bucket"], status: result.settlement.details["pricing_status"], total_unavailable: true, cached_component_unavailable: true})
  end

  test "missing cache-write status retains precedence when both component rates are absent" do
    setup = accounting_setup()
    Repo.delete!(setup.pricing)
    assert {:ok, _} = import!(catalog(setup.model.pricing_ref, %{"standard" => %{"default" => rates(nil)}}))
    {_reserved, result} = settle!(setup, 400, writes: 100)
    assert result.settlement.details["pricing_status"] == "unpriced_missing_cache_write_rate"
    assert is_nil(result.settlement.details["settled_cost_micros"])
    assert is_nil(result.settlement.details["cached_input_cost_micros"])
    record("both_rates_missing", %{status: result.settlement.details["pricing_status"], total_unavailable: true, cached_component_unavailable: true})
  end

  test "revision 5 still fences generations and rejects an absent context rule" do
    setup = accounting_setup()
    Repo.delete!(setup.pricing)
    identifier = setup.model.pricing_ref
    assert {:ok, _} = import!(catalog(identifier, %{"standard" => %{"default" => rates(3), "long_context" => rates(3)}}))
    newer = catalog(identifier, %{"standard" => %{"default" => rates(nil)}}) |> Map.put("generated_at", "2026-07-29T00:00:00Z") |> put_in(["models", identifier, "timestamp"], "2026-07-29T00:00:00Z")
    assert {:ok, %{price_version: version}} = import!(newer)
    snapshot = Repo.one!(from p in PricingSnapshot, where: p.model_identifier == ^identifier and p.price_version == ^version)
    Repo.update!(Ecto.Changeset.change(snapshot, config: Map.delete(snapshot.config, "context_pricing")))

    family = Generations.load([identifier], "standard", DateTime.utc_now())[identifier]
    refute Map.has_key?(family.buckets, "long_context")
    {_reserved, result} = settle!(setup, 400)
    assert result.settlement.details["pricing_status"] == "unpriced_context_boundary_invalid"
    assert is_nil(result.settlement.details["settled_cost_micros"])
    record("revision_generation_fence", %{old_long_bucket_absent: true, status: result.settlement.details["pricing_status"]})
  end

  test "direct costing requires a cached rate only for billable cached input" do
    snapshot = %PricingSnapshot{input_token_micros: Decimal.new(30), output_token_micros: Decimal.new(180)}
    assert is_nil(Costing.cost_micros(snapshot, %{input_tokens: 1000, cached_input_tokens: 400}))
    assert is_nil(Costing.cost_micros(snapshot, %{"input_tokens" => 1000, "cached_input_tokens" => 400}))
    assert Decimal.equal?(Costing.cost_micros(snapshot, %{input_tokens: 1000, cached_input_tokens: 0}), 30_000)
    assert Decimal.equal?(Costing.cost_micros(snapshot, %{input_tokens: 1000, cached_input_tokens: nil}), 30_000)
    assert Decimal.equal?(Costing.cost_micros(snapshot, %{input_tokens: 0, cached_input_tokens: 400}), 0)
    assert Decimal.equal?(Costing.cost_micros(%{snapshot | cached_input_token_micros: Decimal.new(0)}, %{input_tokens: 1000, cached_input_tokens: 400}), 18_000)
    record("direct_costing", %{missing_rate_unavailable: true, zero_billable_cached_priced: true, published_zero_priced: true})
  end

  defp settle!(setup, cached, opts \\ []) do
    assert {:ok, reserved} = Accounting.reserve(setup.auth, setup.model, %{"model" => setup.model.exposed_model_id, "max_output_tokens" => 10}, %{correlation_id: "cached-rate-#{System.unique_integer([:positive])}"})
    assert {:ok, attempt} = Accounting.create_attempt(reserved.request, setup.assignment)
    input = Keyword.get(opts, :input, 1000)
    usage = %{status: "usage_known", input_tokens: input, output_tokens: 0, total_tokens: input, service_tier: Keyword.get(opts, :tier, "default")}
    usage = if is_nil(cached), do: usage, else: Map.put(usage, :cached_input_tokens, cached)
    usage = if is_nil(opts[:writes]), do: usage, else: Map.put(usage, :cache_write_tokens, opts[:writes])
    assert {:ok, result} = Accounting.finalize_success(reserved.request, attempt, usage, %{response_status_code: 200})
    {reserved, result}
  end

  defp assert_projection!(setup, result, cached, expected, rate) do
    entry = Repo.get!(LedgerEntry, result.settlement.id)
    request = Repo.get!(Request, entry.request_id)
    pricing_status = if is_nil(expected), do: @unpriced, else: "priced"
    assert request.status == "succeeded"
    assert request.request_metadata["pricing"]["status"] == pricing_status
    assert entry.usage_status == "usage_known"
    assert entry.details["pricing_status"] == pricing_status
    if is_nil(expected), do: assert(is_nil(entry.details["settled_cost_micros"])), else: assert(Decimal.equal?(entry.settled_cost_micros, expected))
    if is_nil(rate), do: assert(is_nil(entry.details["cached_input_cost_micros"])), else: assert(Decimal.equal?(Decimal.new(entry.details["cached_input_cost_micros"]), (cached || 0) * rate))

    assert %{items: logs} = Accounting.list_request_logs(setup.pool)
    log = Enum.find(logs, &(&1.id == request.id))
    reset_bootstrap_state_fixture!()
    %{user: owner} = bootstrap_owner_fixture(%{"email" => unique_user_email()})
    detail = Accounting.get_request_log_for_scope(Scope.for_user(owner, []), request.id)

    for projection <- [log, detail] do
      assert projection.cost.status == pricing_status
      assert projection.token_counts.cached_input_tokens == cached
      if is_nil(expected), do: assert(is_nil(projection.cost.usd)), else: assert(Decimal.equal?(projection.cost.usd, Decimal.div(Decimal.new(expected), 1_000_000)))
      if is_nil(rate), do: assert(is_nil(projection.token_counts.cached_input_cost_usd)), else: assert(Decimal.equal?(projection.token_counts.cached_input_cost_usd, Decimal.div(Decimal.new((cached || 0) * rate), 1_000_000)))
    end

    record("persisted_projection", %{rate: rate, cached_tokens: cached, expected_cost_micros: expected, status: entry.details["pricing_status"], settled_cost_micros: entry.details["settled_cost_micros"], cached_cost_micros: entry.details["cached_input_cost_micros"], list_status: log.cost.status, detail_status: detail.cost.status, cached_component_unavailable: is_nil(detail.token_counts.cached_input_cost_usd), revision: entry.details["pricing_importer_revision"]})
  end

  defp rates(nil), do: %{"input" => 30, "output" => 180}
  defp rates(cached), do: Map.put(rates(nil), "cached_input", cached)
  defp assert_rate(actual, nil), do: assert(is_nil(actual))
  defp assert_rate(actual, expected), do: assert(Decimal.equal?(actual, expected))

  defp catalog(identifier, tiers) do
    %{
      "generated_at" => @generated_at,
      "models" => %{identifier => %{"model" => identifier, "category" => "language_model", "categories" => ["language_model"], "pricing_type" => "per_1m_tokens", "pricing_types" => ["per_1m_tokens"], "prices" => tiers, "timestamp" => @generated_at}},
      "models_count" => 1,
      "source" => "synthetic",
      "source_url" => "https://example.com/pricing.json",
      "tools" => %{"sample" => %{"tool" => "Sample", "details" => "Synthetic", "price" => 0, "pricing" => "$0"}},
      "tools_count" => 1
    }
  end

  defp import!(payload) do
    path = Path.join(System.tmp_dir!(), "cached-rate-#{System.unique_integer([:positive])}.json")
    on_exit(fn -> File.rm(path) end)
    File.write!(path, CodexPooler.JSON.encode!(payload))
    OpenAIPricingImporter.import_file(path)
  end

  defp record(scenario, observations) do
    if path = System.get_env("PRICING_MISSING_RATE_RECEIPT") do
      File.write!(path, CodexPooler.JSON.encode!(%{scenario: scenario, observations: observations}) <> "\n", [:append])
    end
  end
end

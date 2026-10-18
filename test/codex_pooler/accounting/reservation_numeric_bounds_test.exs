defmodule CodexPooler.Accounting.ReservationNumericBoundsTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Accounting
  alias CodexPooler.Accounting.{LedgerEntry, PricingResolution, Request}

  import CodexPooler.AccountingTestSupport

  @max_tokens 9_223_372_036_854_775_807

  for priced? <- [true, false], field <- ["max_output_tokens", "max_tokens"], string? <- [true, false] do
    test "#{field} beyond storage range refuses priced=#{priced?} string=#{string?}" do
      fixture = unlimited_fixture(unquote(priced?))
      cap = @max_tokens + 1
      cap = if unquote(string?), do: Integer.to_string(cap), else: cap
      payload = %{"model" => fixture.model.exposed_model_id, unquote(field) => cap}
      assert_refused(fixture, payload)
    end
  end

  test "positive input plus individually representable output is refused when total overflows" do
    fixture = unlimited_fixture(false)
    payload = %{"model" => fixture.model.exposed_model_id, "input" => "synthetic input", "max_output_tokens" => @max_tokens}
    {:ok, estimate} = PricingResolution.reservation_estimate(payload, nil, nil)
    assert estimate.input_tokens > 0
    assert estimate.output_tokens == @max_tokens
    assert estimate.total_tokens > @max_tokens
    assert_refused(fixture, payload)
  end

  test "precomputed input overflow is refused" do
    fixture = unlimited_fixture(false)
    assert_refused(fixture, %{"model" => fixture.model.exposed_model_id}, %{reservation_estimate: %{input_tokens: @max_tokens + 1, output_tokens: 0}})
  end

  test "inclusive bigint boundary with no input remains representable" do
    fixture = unlimited_fixture(false)
    payload = %{"model" => fixture.model.exposed_model_id, "max_output_tokens" => @max_tokens}
    assert {:ok, reserved} = Accounting.reserve(fixture.auth, fixture.model, payload, %{})
    assert reserved.estimate.input_tokens == 0
    assert reserved.reservation.output_tokens == @max_tokens
    assert reserved.reservation.total_tokens == @max_tokens
  end

  test "ordinary priced reservation preserves conservative output and cost" do
    fixture = unlimited_fixture(true)
    payload = %{"model" => fixture.model.exposed_model_id, "input" => "synthetic input", "max_output_tokens" => 5}
    assert {:ok, reserved} = Accounting.reserve(fixture.auth, fixture.model, payload, %{})
    assert reserved.estimate.output_tokens == 512
    assert reserved.reservation.total_tokens == reserved.estimate.input_tokens + 512
    assert Decimal.positive?(reserved.reservation.estimated_cost_micros)
  end

  defp unlimited_fixture(priced?) do
    fixture = accounting_setup()
    update_default_policy!(fixture.api_key, %{max_tokens_per_day: nil, max_tokens_per_week: nil, max_input_tokens_per_request: nil, max_output_tokens_per_request: nil})
    unless priced?, do: Repo.delete!(fixture.pricing)
    fixture
  end

  defp assert_refused(fixture, payload, opts \\ %{}) do
    requests_before = Repo.aggregate(Request, :count)
    ledger_before = Repo.aggregate(LedgerEntry, :count)
    result = Accounting.reserve(fixture.auth, fixture.model, payload, opts)
    assert {:error, %{code: :invalid_request, status: 400, message: message}} = result
    assert message == "request token estimate exceeds the supported accounting range"
    assert Repo.aggregate(Request, :count) == requests_before
    assert Repo.aggregate(LedgerEntry, :count) == ledger_before
  end
end

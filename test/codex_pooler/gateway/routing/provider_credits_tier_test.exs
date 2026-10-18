defmodule CodexPooler.Gateway.Routing.ProviderCreditsTierTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.Routing.ProviderCredits

  test "ordinary capacity preserves strategy and demotion ordering in one group" do
    ordinary_tier = ProviderCredits.tier(%{capacity_basis: :included_window, routing_state: :precise})

    for basis <- [:included_window, :recovered_included, :ordinary_provider_permission, :model_allowance],
        state <- [:precise, :weekly_only_probe, :reset_probe, :provider_available] do
      assert ProviderCredits.tier(%{capacity_basis: basis, routing_state: state}) == ordinary_tier
    end
  end

  test "windowless, credit and legacy capacity follow ordinary in stable outer groups" do
    for state <- [:precise, :weekly_only_probe, :reset_probe, :provider_available] do
      ordinary_tier = ProviderCredits.tier(%{capacity_basis: :included_window, routing_state: state})
      windowless_tier = ProviderCredits.tier(%{capacity_basis: :windowless_provider_permission, routing_state: state})
      credit_tier = ProviderCredits.tier(%{capacity_basis: :provider_credits, routing_state: state})
      legacy_tier = ProviderCredits.tier(%{capacity_basis: :unknown_legacy, routing_state: state})

      assert ordinary_tier < windowless_tier
      assert windowless_tier < credit_tier
      assert credit_tier < legacy_tier
    end
  end
end

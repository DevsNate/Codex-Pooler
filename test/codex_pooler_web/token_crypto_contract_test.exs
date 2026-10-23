defmodule CodexPoolerWeb.TokenCryptoContractTest do
  use ExUnit.Case, async: true

  @secret "synthetic-key-base-" <> String.duplicate("x", 48)
  @salt "synthetic-token-salt"

  test "signed and encrypted Phoenix tokens still round trip" do
    data = %{scope: "synthetic-scope"}
    signed = Phoenix.Token.sign(@secret, @salt, data)
    encrypted = Phoenix.Token.encrypt(@secret, @salt, data)

    assert Phoenix.Token.verify(@secret, @salt, signed) == {:ok, data}
    assert Phoenix.Token.decrypt(@secret, @salt, encrypted) == {:ok, data}
    assert Plug.Crypto.secure_compare("synthetic-value", "synthetic-value")
    refute Plug.Crypto.secure_compare("synthetic-value", "different-value")
  end

  test "malformed request tokens are rejected without raising" do
    for token <- [["synthetic-token"], 123, %{}, :invalid] do
      assert call_result(fn -> Phoenix.Token.verify(@secret, @salt, token) end) == {:returned, {:error, :invalid}}
      assert call_result(fn -> Phoenix.Token.decrypt(@secret, @salt, token) end) == {:returned, {:error, :invalid}}
    end

    assert Phoenix.Token.verify(@secret, @salt, nil) == {:error, :missing}
    assert Phoenix.Token.decrypt(@secret, @salt, nil) == {:error, :missing}
  end

  test "bad crypto arguments do not put the key base in formatted exceptions" do
    for operation <- [:sign, :encrypt, :verify, :decrypt] do
      assert call_result(fn -> apply(Plug.Crypto, operation, [@secret, nil, "synthetic-data", []]) end) == {:raised, ArgumentError, false}
    end

    assert call_result(fn -> Plug.Crypto.secure_compare(nil, @secret) end) == {:raised, ArgumentError, false}
  end

  defp call_result(call) do
    {:returned, call.()}
  rescue
    error ->
      contains_key? = String.contains?(Exception.format(:error, error, __STACKTRACE__), @secret)
      {:raised, error.__struct__, contains_key?}
  end
end

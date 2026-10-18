defmodule CodexPoolerWeb.V1.ChatUsageDetailsTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport, only: [curl_json_request!: 4, gateway_setup: 1, start_public_endpoint!: 0, start_upstream: 1]

  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Pools.ModelServingOverride
  alias CodexPooler.Repo

  for mode <- ~w(full lite), surface <- ~w(chat responses), stream? <- [false, true], status <- ~w(completed incomplete) do
    test "real HTTP #{surface} usage in #{mode}, stream=#{stream?}, status=#{status}" do
      assert_http_usage(unquote(mode), unquote(surface), unquote(stream?), unquote(status), true)
    end
  end

  for mode <- ~w(full lite) do
    test "real HTTP Chat omits unrequested stream usage in #{mode}" do
      assert_http_usage(unquote(mode), "chat", true, "completed", false)
    end
  end

  defp assert_http_usage(mode, surface, stream?, status, include_usage?) do
    usage = %{
      "input_tokens" => 5,
      "input_tokens_details" => %{"cached_tokens" => 4, "cache_write_tokens" => 1, "unknown_tokens" => 99},
      "output_tokens" => 3,
      "output_tokens_details" => %{"reasoning_tokens" => 2, "unknown_tokens" => 99},
      "total_tokens" => 8,
      "compute_units" => 7
    }

    terminal = %{"type" => "response.#{status}", "response" => %{"id" => "resp_usage_fixture", "status" => status, "output" => [], "usage" => usage}}
    upstream = start_upstream(FakeUpstream.sse_stream([terminal]))
    setup = gateway_setup(upstream)
    timestamp = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    Repo.insert!(%ModelServingOverride{pool_id: setup.pool.id, exposed_model_id: setup.model.exposed_model_id, mode: mode, created_at: timestamp, updated_at: timestamp})
    port = start_public_endpoint!()
    {route, payload} = request(surface, setup.model.exposed_model_id, stream?, include_usage?)
    {headers, body} = curl_json_request!(port, setup.authorization, payload, route)
    assert String.starts_with?(headers, "HTTP/1.1 200")
    assert_wire_usage(surface, body, usage, stream?, status, include_usage?)
    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.path == "/backend-api/codex/responses"
    assert captured.json["stream"] == true
    assert_accounting(setup, mode)
  end

  defp request("chat", model, stream?, include_usage?) do
    payload = %{"model" => model, "messages" => [%{"role" => "user", "content" => "synthetic input"}], "stream" => stream?}
    payload = if stream?, do: Map.put(payload, "stream_options", %{"include_usage" => include_usage?}), else: payload
    {"/v1/chat/completions", payload}
  end

  defp request("responses", model, stream?, _include_usage?), do: {"/v1/responses", %{"model" => model, "input" => "synthetic input", "stream" => stream?}}

  defp assert_wire_usage("chat", body, _usage, stream?, status, include_usage?) do
    expected = %{"prompt_tokens" => 5, "prompt_tokens_details" => %{"cached_tokens" => 4, "cache_write_tokens" => 1}, "completion_tokens" => 3, "completion_tokens_details" => %{"reasoning_tokens" => 2}, "total_tokens" => 8, "compute_units" => 7}
    finish_reason = if status == "incomplete", do: "length", else: "stop"

    if stream? do
      chunks = sse_payloads(body)
      usage_chunks = Enum.filter(chunks, &Map.has_key?(&1, "usage"))
      if include_usage?, do: assert([%{"choices" => [], "usage" => ^expected}] = usage_chunks), else: assert(usage_chunks == [])
      assert Enum.any?(chunks, &(get_in(&1, ["choices", Access.at(0), "finish_reason"]) == finish_reason))
      if include_usage?, do: assert(List.last(chunks)["usage"] == expected)
      assert String.ends_with?(body, "data: [DONE]\n\n")
    else
      decoded = CodexPooler.JSON.decode!(body)
      assert decoded["usage"] == expected
      assert get_in(decoded, ["choices", Access.at(0), "finish_reason"]) == finish_reason
    end
  end

  defp assert_wire_usage("responses", body, usage, stream?, status, _include_usage?) do
    response = if stream?, do: Enum.find_value(sse_payloads(body), &if(&1["type"] == "response.#{status}", do: &1["response"])), else: CodexPooler.JSON.decode!(body)
    assert response["status"] == status
    assert response["usage"] == usage
  end

  defp sse_payloads(body) do
    body
    |> String.split("\n", trim: true)
    |> Enum.filter(&String.starts_with?(&1, "data: {"))
    |> Enum.map(&(&1 |> String.replace_prefix("data: ", "") |> CodexPooler.JSON.decode!()))
  end

  defp assert_accounting(setup, mode) do
    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "succeeded"
    assert request.transport == "http_sse"
    assert get_in(request.request_metadata, ["routing", "model_serving_mode"]) == mode
    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    assert attempt.status == "succeeded"
    assert get_in(attempt.response_metadata, ["routing", "model_serving_mode"]) == mode
    assert [settlement] = Repo.all(from(l in LedgerEntry, where: l.request_id == ^request.id and l.entry_kind == "settlement"))
    assert settlement.usage_status == "usage_known"
    assert settlement.input_tokens == 5
    assert settlement.cached_input_tokens == 4
    assert settlement.cache_write_tokens == 1
    assert settlement.output_tokens == 3
    assert settlement.reasoning_tokens == 2
    assert settlement.total_tokens == 8
    refute Map.has_key?(settlement.details, "input_tokens_details")
    refute Map.has_key?(settlement.details, "output_tokens_details")
  end
end

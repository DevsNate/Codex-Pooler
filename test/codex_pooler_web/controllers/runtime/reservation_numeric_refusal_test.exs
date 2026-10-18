defmodule CodexPoolerWeb.Runtime.ReservationNumericRefusalTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport

  alias CodexPooler.Access.APIKeyPolicyBinding
  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Repo

  @moduletag capture_log: true
  @oversized 9_223_372_036_854_775_808
  @turn_endpoint "/backend-api/codex/responses"

  for {endpoint, cap_field} <- [{@turn_endpoint, "max_output_tokens"}, {"/v1/responses", "max_output_tokens"}, {"/v1/chat/completions", "max_tokens"}, {"/v1/chat/completions", "max_completion_tokens"}] do
    test "#{endpoint} #{cap_field} refuses before dispatch", %{conn: conn} do
      upstream = start_upstream(FakeUpstream.json_response(%{"output" => []}))
      setup = gateway_setup(upstream)
      unlimited_policy!(setup)
      payload = request_body(setup) |> Map.put(unquote(cap_field), @oversized)
      payload = if unquote(endpoint) == "/v1/chat/completions", do: payload |> Map.delete("input") |> Map.put("messages", [%{"role" => "user", "content" => "synthetic input"}]), else: payload

      response = conn |> put_req_header("authorization", setup.authorization) |> post(unquote(endpoint), payload)
      assert %{"error" => %{"code" => "invalid_request", "type" => "invalid_request_error"}} = json_response(response, 400)
      assert FakeUpstream.count(upstream) == 0
      assert Repo.aggregate(Attempt, :count) == 0
      assert Repo.aggregate(LedgerEntry, :count) == 0
      assert [row] = pool_requests(setup.pool.id)
      assert row.status == "rejected"
      assert row.response_status_code == 400
    end
  end

  for forwarding? <- [false, true] do
    test "native websocket forwarding=#{forwarding?} refuses without stranded claim and next valid turn serves" do
      CodexPooler.TestAppEnv.restore_on_exit(:websocket_owner_forwarding_enabled, nil)
      Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, unquote(forwarding?))
      upstream = start_upstream(completed_frames())
      setup = gateway_setup(upstream, compact?: true)
      unlimited_policy!(setup)
      {_server, port} = start_public_endpoint_with_server!()
      thread_id = Ecto.UUID.generate()
      headers = [{"session-id", thread_id}, {"thread-id", thread_id}, {"x-client-request-id", thread_id}]
      {conn, websocket, ref, _headers} = public_websocket_connect_with_request_headers!(port, setup, "numeric-boundary", @turn_endpoint, headers)

      try do
        frame = request_body(setup) |> Map.put("type", "response.create") |> Map.put("max_output_tokens", @oversized)
        {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, CodexPooler.JSON.encode!(frame))
        {conn, websocket, terminal} = receive_terminal(conn, websocket, ref)
        assert terminal["type"] == "error"
        assert terminal["status"] == 400
        assert get_in(terminal, ["error", "code"]) == "invalid_request"
        assert FakeUpstream.count(upstream) == 0
        assert Repo.aggregate(Attempt, :count) == 0
        assert Repo.aggregate(LedgerEntry, :count) == 0
        assert [row] = await_terminal_rows(setup.pool.id, 1)
        assert row.status == "rejected"
        refute String.starts_with?(row.correlation_id, "codex-turn:")

        valid_frame = Map.put(frame, "max_output_tokens", 512)
        {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, CodexPooler.JSON.encode!(valid_frame))
        {_conn, _websocket, terminal} = receive_terminal(conn, websocket, ref)
        assert terminal["type"] == "response.completed"
        rows = await_terminal_rows(setup.pool.id, 2)
        assert Enum.count(rows, &(&1.status == "succeeded")) == 1
        assert Enum.count(rows, &(&1.status == "rejected")) == 1
        assert FakeUpstream.count(upstream) == 1
      after
        Mint.HTTP.close(conn)
      end
    end
  end

  defp unlimited_policy!(setup) do
    Repo.update_all(from(binding in APIKeyPolicyBinding, where: binding.api_key_id == ^setup.api_key.id), set: [max_tokens_per_day: nil, max_tokens_per_week: nil, max_input_tokens_per_request: nil, max_output_tokens_per_request: nil])
  end

  defp request_body(setup) do
    %{"model" => setup.model.exposed_model_id, "input" => [%{"role" => "user", "content" => "synthetic input"}], "stream" => true}
  end

  defp completed_frames do
    FakeUpstream.websocket_text_frames([
      CodexPooler.JSON.encode!(%{"type" => "response.created", "response" => %{"id" => "resp_numeric_boundary", "status" => "in_progress"}}),
      CodexPooler.JSON.encode!(%{"type" => "response.completed", "response" => %{"id" => "resp_numeric_boundary", "status" => "completed", "output" => [], "usage" => %{"input_tokens" => 5, "output_tokens" => 1, "total_tokens" => 6}}})
    ])
  end

  defp receive_terminal(conn, websocket, ref) do
    {conn, websocket, text} = public_websocket_receive_text!(conn, websocket, ref)
    terminal = CodexPooler.JSON.decode!(text)
    if terminal["type"] in ["error", "response.completed", "response.failed"], do: {conn, websocket, terminal}, else: receive_terminal(conn, websocket, ref)
  end

  defp pool_requests(pool_id), do: Repo.all(from(request in Request, where: request.pool_id == ^pool_id))

  defp await_terminal_rows(pool_id, count) do
    deadline = System.monotonic_time(:millisecond) + 5_000
    await_terminal_rows(pool_id, count, deadline)
  end

  defp await_terminal_rows(pool_id, count, deadline) do
    rows = pool_requests(pool_id)

    if length(rows) == count and Enum.all?(rows, &(&1.status not in ["accepted", "in_progress"])) do
      rows
    else
      assert System.monotonic_time(:millisecond) < deadline, "request rows did not reach terminal state"

      receive do
      after
        10 -> await_terminal_rows(pool_id, count, deadline)
      end
    end
  end
end

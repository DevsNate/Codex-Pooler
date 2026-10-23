defmodule CodexPoolerWeb.V1.ResponsesFunctionNameTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [auth: 2, gateway_setup: 1, public_websocket_connect!: 4, public_websocket_receive_text!: 3, public_websocket_send_text!: 4, start_public_endpoint!: 0, start_upstream: 1]

  import CodexPoolerWeb.Runtime.BackendCodexWebsocketSupport,
    only: [model_serving_scope: 0, set_model_serving_mode!: 3]

  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Repo

  @moduletag capture_log: true
  @user %{"type" => "message", "role" => "user", "content" => [%{"type" => "input_text", "text" => "synthetic function-name request"}]}
  @name_error %{"type" => "invalid_request_error", "code" => "invalid_request", "param" => "tools", "message" => "function tool names must contain 1 to 128 ASCII letters, digits, underscores or hyphens"}

  setup do
    CodexPooler.TestAppEnv.restore_on_exit(:websocket_owner_forwarding_enabled)
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, false)
    :ok
  end

  for mode <- ~w(full lite), transport <- [:http, :websocket], layout <- [:flat, :namespace], {label, name} <- [{"dotted", "catalog.lookup"}, {"overlong", String.duplicate("a", 129)}] do
    @tag mode: mode, transport: transport, layout: layout, name: name
    test "#{mode} #{transport} #{layout}: #{label} function names fail before dispatch or accounting", context do
      assert_rejection!(context.mode, context.transport, context.layout, context.name)
    end
  end

  for mode <- ~w(full lite), transport <- [:json, :sse, :websocket], layout <- [:flat, :namespace], length <- [65, 128] do
    @tag mode: mode, transport: transport, layout: layout, name_length: length
    test "#{mode} #{transport} #{layout}: a #{length}-character function keeps its declaration, choice, replay and returned name", context do
      assert_preservation!(context.mode, context.transport, context.layout, String.duplicate("a", context.name_length))
    end
  end

  defp assert_rejection!(mode, transport, layout, name) do
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "resp_synthetic_unexpected_dispatch", "status" => "completed", "output" => []}))
    setup = serving_setup!(upstream, mode)
    body = payload(setup, layout, name)

    if transport == :http do
      conn = build_conn() |> auth(setup) |> post("/v1/responses", body)
      assert json_response(conn, 400)["error"] == @name_error
    else
      assert [%{"type" => "error", "status" => 400, "error" => @name_error}] = websocket_events!(setup, body)
    end

    assert FakeUpstream.count(upstream) == 0
    assert Repo.aggregate(from(r in Request, where: r.pool_id == ^setup.pool.id), :count) == 0
    assert Repo.aggregate(Attempt, :count) == 0
    assert Repo.aggregate(LedgerEntry, :count) == 0
  end

  defp assert_preservation!(mode, transport, layout, name) do
    item = call(layout, name)
    events = events(item)
    reply = if transport == :websocket, do: FakeUpstream.websocket_text_frames(Enum.map(events, &CodexPooler.JSON.encode!/1)), else: FakeUpstream.sse_stream(Enum.map(events, &{&1["type"], &1}))
    # provenance: synthetic_adversarial; provider-observed 65/128 name lengths, invented complete response and call/replay values.
    upstream = start_upstream(FakeUpstream.strict_sequence([FakeUpstream.expect_request(method: if(transport == :websocket, do: "WEBSOCKET", else: "POST"), path: "/backend-api/codex/responses", json: [valid: true], respond: reply)]))
    setup = serving_setup!(upstream, mode)
    replay = Map.drop(item, ["id", "status"])
    input = [@user, replay, %{"type" => "function_call_output", "call_id" => replay["call_id"], "output" => "synthetic result"}]
    body = payload(setup, layout, name) |> Map.put("stream", transport != :json) |> Map.put("input", input)

    case transport do
      :json ->
        conn = build_conn() |> auth(setup) |> post("/v1/responses", body)
        assert json_response(conn, 200)["output"] == [item]

      :sse ->
        conn = build_conn() |> auth(setup) |> post("/v1/responses", body)
        decoded = for block <- String.split(response(conn, 200), "\n\n", trim: true), "data: " <> data <- String.split(block, "\n"), data != "[DONE]", do: CodexPooler.JSON.decode!(data)
        assert_call_events!(decoded, item)

      :websocket ->
        assert_call_events!(websocket_events!(setup, body), item)
    end

    assert [captured] = FakeUpstream.requests(upstream)
    tools = body["tools"]
    assert captured.json["tool_choice"] == body["tool_choice"]

    if mode == "full" do
      assert captured.json["tools"] == tools
      assert captured.json["input"] == input
    else
      refute Map.has_key?(captured.json, "tools")
      assert captured.json["input"] == [%{"type" => "additional_tools", "role" => "developer", "tools" => tools} | input]
    end

    assert :ok = FakeUpstream.verify!(upstream)
  end

  defp serving_setup!(upstream, mode) do
    setup = gateway_setup(upstream)
    set_model_serving_mode!(model_serving_scope(), setup, mode)
    setup
  end

  defp payload(setup, layout, name) do
    function = %{"type" => "function", "name" => name, "strict" => true, "parameters" => %{"type" => "object", "properties" => %{}, "required" => [], "additionalProperties" => false}}
    tools = if layout == :flat, do: [function], else: [%{"type" => "namespace", "name" => "catalog", "description" => "Synthetic functions", "tools" => [function]}]
    %{"model" => setup.model.exposed_model_id, "input" => [@user], "tools" => tools, "tool_choice" => if(layout == :flat, do: %{"type" => "function", "name" => name}, else: "required"), "stream" => true}
  end

  defp call(layout, name) do
    item = %{"type" => "function_call", "id" => "fc_synthetic_function_name", "call_id" => "call_synthetic_function_name", "name" => name, "arguments" => "{}", "status" => "completed"}
    if layout == :flat, do: item, else: Map.put(item, "namespace", "catalog")
  end

  defp events(item) do
    response = %{"id" => "resp_synthetic_function_name", "object" => "response", "created_at" => 1_790_000_000, "model" => "provider-gpt-test-model", "status" => "completed", "output" => [item], "usage" => %{"input_tokens" => 5, "output_tokens" => 3, "total_tokens" => 8}}
    [%{"type" => "response.created", "response" => %{response | "status" => "in_progress", "output" => [], "usage" => nil}}, %{"type" => "response.output_item.added", "output_index" => 0, "item" => item}, %{"type" => "response.output_item.done", "output_index" => 0, "item" => item}, %{"type" => "response.completed", "response" => response}]
  end

  defp assert_call_events!(events, item) do
    assert List.last(events)["type"] == "response.completed"
    assert List.last(events)["response"]["output"] == [item]
    assert for(%{"type" => "response.output_item.added", "item" => returned} <- events, do: returned) == [item]
    assert for(%{"type" => "response.output_item.done", "item" => returned} <- events, do: returned) == [item]
  end

  defp websocket_events!(setup, body) do
    port = start_public_endpoint!()
    {conn, websocket, ref} = public_websocket_connect!(port, setup, "function-name-#{System.unique_integer([:positive])}", "/v1/responses")

    try do
      {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, CodexPooler.JSON.encode!(Map.put(body, "type", "response.create")))
      receive_events!(conn, websocket, ref, [])
    after
      Mint.HTTP.close(conn)
    end
  end

  defp receive_events!(conn, websocket, ref, events) do
    {conn, websocket, text} = public_websocket_receive_text!(conn, websocket, ref)
    event = CodexPooler.JSON.decode!(text)
    events = [event | events]

    if event["type"] in ~w(response.completed response.failed response.incomplete error), do: Enum.reverse(events), else: receive_events!(conn, websocket, ref, events)
  end
end

defmodule CodexPoolerWeb.Runtime.WebsocketPostReplyVisibilityTest do
  use CodexPoolerWeb.ConnCase, async: false

  @moduletag capture_log: true
  import Ecto.Query
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwardingSupport, only: [enter_peer_owner_topology!: 0, start_peer_window_owner!: 2, request_logs: 1]
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketSupport, only: [model_serving_scope: 0, set_model_serving_mode!: 3, with_info_log: 1]

  alias CodexPooler.Accounting.{Attempt, LedgerEntry}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Runtime.Finalization.SettlementRetry
  alias CodexPooler.Gateway.Transports.UpstreamDispatch
  alias CodexPooler.Gateway.Transports.Websocket.ActivityRegistry
  alias CodexPooler.Repo

  @detection_timeout 15_000

  setup do
    CodexPooler.TestAppEnv.restore_on_exit(:websocket_owner_forwarding_enabled)
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, true)
    CodexPooler.TestAppEnv.restore_on_exit(SettlementRetry)
    :ok
  end

  for topology <- [:direct, :local, :peer], mode <- ["full", "lite"] do
    @tag slow: "cancels real post-terminal visibility with committed rows and optional peer owner"
    test "post-reply visibility retries and serves the same-turn tool continuation (#{topology}, #{mode})" do
      {_result, logs} = with_info_log(fn -> run_scenario(unquote(topology), unquote(mode), false) end)
      assert logs =~ "visible output mark met a transient database failure; retrying stage=completed_response_visibility"
      assert logs =~ "visible output mark completed after a transient database failure stage=completed_response_visibility"
      refute logs =~ "websocket response task failed"
    end
  end

  @tag slow: "crosses the socket drain while the completed remote result retries visibility"
  test "disconnect preserves completed reply visibility, usage and receipt before a new socket continues" do
    {_result, logs} = with_info_log(fn -> run_scenario(:peer, "full", true) end)
    assert logs =~ "visible output mark completed after a transient database failure stage=completed_response_visibility"
    refute logs =~ "websocket response task failed"
  end

  test "post-reply visibility exhaustion keeps exception finalization rather than skipping the fence" do
    Application.put_env(:codex_pooler, SettlementRetry, window_ms: 0)
    {_result, logs} = with_info_log(fn -> run_scenario(:local, "full", false, true) end)
    assert logs =~ "visible output mark abandoned after transient database failures stage=completed_response_visibility"
    assert logs =~ "websocket response task failed"
    refute logs =~ "visible output mark completed after a transient database failure"
  end

  defp run_scenario(topology, mode, disconnect?, exhausted? \\ false) do
    enter_peer_owner_topology!()
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, topology != :direct)
    upstream = start_upstream(FakeUpstream.strict_sequence([FakeUpstream.websocket_text_frames(frames("resp_synthetic_postreply", true)), FakeUpstream.websocket_text_frames(frames("resp_synthetic_successor", false))]))
    setup = gateway_setup(upstream)
    register_unboxed_pool_cleanup!(setup)
    set_model_serving_mode!(model_serving_scope(), setup, mode)
    window = Ecto.UUID.generate()
    owner = if topology == :peer, do: start_peer_window_owner!(setup, window).owner_pid
    ref = hold_post_reply_mark!()
    port = start_public_endpoint!()
    {conn, ws, request_ref} = connect!(port, setup, window, mode)
    on_exit(fn -> Mint.HTTP.close(conn) end)
    {conn, ws} = public_websocket_send_text!(conn, ws, request_ref, payload(setup, window, "first"))
    {conn, ws} = receive_completed!(conn, ws, request_ref)
    assert_receive {^ref, :post_reply, executor, stack, executor_backend}, @detection_timeout
    assert {UpstreamDispatch, :mark_upstream_websocket_body_visible, 3} in stack
    assert node(executor) == node()
    if topology == :peer, do: assert(node(owner) != node())
    [original] = request_logs(setup.pool.id)
    assert original.status == "in_progress"
    holder = start_supervised!({Postgrex, connection_options()}, id: :holder)
    observer = start_supervised!({Postgrex, connection_options()}, id: :observer)
    Postgrex.query!(holder, "BEGIN", [])
    %{rows: [[backend]]} = Postgrex.query!(holder, "SELECT pg_backend_pid()", [])
    Postgrex.query!(holder, "SELECT id FROM codex_turns WHERE request_id=$1 FOR UPDATE", [Ecto.UUID.dump!(original.id)])

    try do
      send(executor, {ref, :release})
      waiter = await_waiter!(observer, backend, System.monotonic_time(:millisecond) + @detection_timeout)
      assert waiter == executor_backend
      {conn, ws} = if disconnect?, do: {conn, ws}, else: public_websocket_send_text!(conn, ws, request_ref, payload(setup, window, "second"))
      assert %{rows: [[true]]} = Postgrex.query!(observer, "SELECT pg_cancel_backend($1)", [waiter])
      if disconnect?, do: close_during_protected_visibility!(conn, executor)
      Postgrex.query!(holder, "COMMIT", [])

      {conn, ws, request_ref} =
        if disconnect? do
          await_original_receipt!(original.id, System.monotonic_time(:millisecond) + @detection_timeout)
          {next_conn, next_ws, next_ref} = connect!(port, setup, window, mode)
          next_payload = payload(setup, window, "second") |> CodexPooler.JSON.decode!() |> Map.delete("previous_response_id") |> CodexPooler.JSON.encode!()
          {next_conn, next_ws} = public_websocket_send_text!(next_conn, next_ws, next_ref, next_payload)
          {next_conn, next_ws, next_ref}
        else
          {conn, ws, request_ref}
        end

      {conn, _ws} = receive_completed!(conn, ws, request_ref)
      Mint.HTTP.close(conn)
      assert_accounting_and_receipt!(setup.pool.id, original.id, mode, exhausted?)
      assert FakeUpstream.count(upstream) == 2
    after
      Postgrex.query!(holder, "ROLLBACK", [])
      send(executor, {ref, :release})
    end
  end

  defp assert_accounting_and_receipt!(pool_id, original_id, mode, exhausted?) do
    requests = await_requests!(pool_id, System.monotonic_time(:millisecond) + @detection_timeout)
    assert length(requests) == 2
    expected_original = if exhausted?, do: {"failed", "usage_unknown", "owner_task_exception"}, else: {"succeeded", "usage_known", nil}
    assert Enum.map(requests, &{&1.status, &1.usage_status, &1.last_error_code}) == [expected_original, {"succeeded", "usage_known", nil}]

    for request <- requests do
      assert request.request_metadata["routing"]["model_serving_mode"] == mode
      assert Repo.aggregate(from(a in Attempt, where: a.request_id == ^request.id), :count) == 1
      assert Repo.all(from(e in LedgerEntry, where: e.request_id == ^request.id, select: e.entry_kind)) |> Enum.frequencies() == %{"reservation" => 1, "release" => 1, "settlement" => 1}
      settlements = Repo.all(from(e in LedgerEntry, where: e.request_id == ^request.id and e.entry_kind == "settlement", select: {e.usage_status, e.total_tokens}))
      if exhausted? and request.id == original_id, do: assert(length(settlements) == 1), else: assert(settlements == [{"usage_known", 5}])
    end

    attempt = await_original_receipt!(original_id, System.monotonic_time(:millisecond) + @detection_timeout)
    assert attempt.response_metadata["downstream_delivery"]["terminal_class"] == "response.completed"
    assert attempt.response_metadata["downstream_delivery"]["outcome"] == "delivered"
  end

  defp connect!(port, setup, window, mode) do
    headers = [{"x-codex-window-id", window}]
    headers = if mode == "lite", do: [{"x-openai-internal-codex-responses-lite", "true"} | headers], else: headers
    {conn, ws, ref, _headers} = public_websocket_connect_with_request_headers!(port, setup, Ecto.UUID.generate(), "/backend-api/codex/responses", headers)
    on_exit(fn -> Mint.HTTP.close(conn) end)
    {conn, ws, ref}
  end

  defp close_during_protected_visibility!(conn, executor) do
    registry = Process.whereis(ActivityRegistry)
    {_token, %{direct_parent: socket}} = Enum.find(:sys.get_state(registry).activities, fn {_token, entry} -> entry.pid == executor end)

    :sys.replace_state(socket, fn {name, data} ->
      state = data.connection.websock_state
      opts = %{state.opts | transport: Map.merge(state.opts.transport, %{websocket_owner_response_task_drain_ms: 100, websocket_response_task_drain_ms: 50})}
      {name, %{data | connection: %{data.connection | websock_state: %{state | opts: opts}}}}
    end)

    ref = make_ref()
    on_exit(fn -> :sys.remove(registry, ref) end)
    :ok = :sys.install(registry, {ref, &observe_cancellation/3, %{test: self(), ref: ref, socket: socket, pending: nil}})
    Mint.HTTP.close(conn)
    assert_receive {^ref, {:settling, _deadline}}, @detection_timeout
    assert Process.alive?(executor)
  end

  defp observe_cancellation(%{socket: socket} = observer, {:in, {:"$gen_call", {socket, _reply} = from, {:cancel_unless_settling, _task, :websocket_terminated}}}, _name), do: %{observer | pending: from}

  defp observe_cancellation(%{pending: from} = observer, {:out, result, from, _state}, _name) when not is_nil(from) do
    send(observer.test, {observer.ref, result})
    :done
  end

  defp observe_cancellation(observer, _event, _name), do: observer

  defp await_original_receipt!(request_id, deadline) do
    [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request_id))

    if attempt.status in ["succeeded", "failed"] and is_map(attempt.response_metadata["downstream_delivery"]) do
      attempt
    else
      assert System.monotonic_time(:millisecond) < deadline, "original result or delivery receipt was not retained"
      Process.sleep(10)
      await_original_receipt!(request_id, deadline)
    end
  end

  defp hold_post_reply_mark! do
    ref = make_ref()
    handler = {__MODULE__, ref}
    on_exit(fn -> :telemetry.detach(handler) end)
    :ok = :telemetry.attach(handler, [:codex_pooler, :repo, :query], &__MODULE__.hold_post_reply_query/4, %{test: self(), ref: ref, claimed: :atomics.new(1, [])})
    ref
  end

  @doc false
  def hold_post_reply_query(_event, _measurements, %{query: "begin", result: {:ok, %{connection_id: backend}}}, %{test: test, ref: ref, claimed: claimed}) do
    {:current_stacktrace, trace} = Process.info(self(), :current_stacktrace)
    stack = Enum.map(trace, fn {module, function, arity, _location} -> {module, function, arity} end)

    if {UpstreamDispatch, :mark_upstream_websocket_body_visible, 3} in stack and :atomics.compare_exchange(claimed, 1, 0, 1) == :ok do
      monitor = Process.monitor(test)
      send(test, {ref, :post_reply, self(), stack, backend})

      receive do
        {^ref, :release} -> :ok
        {:DOWN, ^monitor, :process, ^test, _reason} -> :ok
      after
        @detection_timeout -> :ok
      end

      Process.demonitor(monitor, [:flush])
    end

    :ok
  end

  def hold_post_reply_query(_event, _measurements, _metadata, _config), do: :ok

  defp await_waiter!(observer, holder, deadline) do
    case Postgrex.query!(observer, "SELECT pid FROM pg_stat_activity WHERE $1=ANY(pg_blocking_pids(pid))", [holder]).rows do
      [[pid] | _] ->
        pid

      [] ->
        assert System.monotonic_time(:millisecond) < deadline
        Process.sleep(10)
        await_waiter!(observer, holder, deadline)
    end
  end

  defp await_requests!(pool, deadline) do
    requests = request_logs(pool)

    if length(requests) == 2 and Enum.all?(requests, &(&1.status not in ["accepted", "in_progress"])) do
      requests
    else
      assert System.monotonic_time(:millisecond) < deadline
      Process.sleep(10)
      await_requests!(pool, deadline)
    end
  end

  defp receive_completed!(conn, ws, ref) do
    {conn, ws, text} = public_websocket_receive_text!(conn, ws, ref)
    event = CodexPooler.JSON.decode!(text)
    refute event["type"] == "error"
    if event["type"] == "response.completed", do: {conn, ws}, else: receive_completed!(conn, ws, ref)
  end

  defp connection_options, do: Repo.config() |> Keyword.take([:hostname, :port, :username, :password, :database, :socket_dir])

  defp payload(setup, window, turn) do
    input = native_text_input("synthetic visibility turn")
    input = if turn == "second", do: input ++ [tool_call(), %{"type" => "function_call_output", "call_id" => "call_visibility", "output" => "synthetic result"}], else: input
    payload = %{"type" => "response.create", "model" => setup.model.exposed_model_id, "input" => input, "stream" => true, "tools" => [], "client_metadata" => %{"x-codex-window-id" => window, "x-codex-turn-metadata" => CodexPooler.JSON.encode!(%{"session_id" => window, "thread_id" => window, "turn_id" => "same-turn", "request_kind" => "turn"})}}
    payload = if turn == "second", do: Map.put(payload, "previous_response_id", "resp_synthetic_postreply"), else: payload
    CodexPooler.JSON.encode!(payload)
  end

  defp tool_call, do: %{"type" => "function_call", "id" => "fc_visibility", "call_id" => "call_visibility", "name" => "shell", "arguments" => "{}", "status" => "completed"}

  defp frames(id, tool?) do
    item = if tool?, do: tool_call(), else: %{"type" => "reasoning", "id" => "rs_visibility", "status" => "completed", "summary" => []}

    [%{"type" => "response.created", "response" => %{"id" => id, "status" => "in_progress"}}, %{"type" => "response.output_item.done", "item" => item, "output_index" => 0}, %{"type" => "response.completed", "response" => %{"id" => id, "status" => "completed", "output" => [item], "usage" => %{"input_tokens" => 2, "output_tokens" => 3, "total_tokens" => 5}}}]
    |> Enum.map(&CodexPooler.JSON.encode!/1)
  end
end

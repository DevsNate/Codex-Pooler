defmodule CodexPoolerWeb.Runtime.BackendCodexPreAttemptDisconnectResendTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport

  alias CodexPooler.Access
  alias CodexPooler.Accounting
  alias CodexPooler.Accounting.{Attempt, ClientRetry, LedgerEntry, Request, RequestReplayEntitlement}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Persistence.CodexTurn
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol
  alias CodexPooler.Repo
  alias CodexPoolerWeb.CodexResponsesSocket
  alias CodexPoolerWeb.Runtime.WebsocketCleanupFence

  @moduletag capture_log: true
  @budget 15_000
  @socket_messages [:native_response_steering_prepare, :websocket_response_activity, :direct_request_cleanup, :codex_response_chunk, :codex_response_done, :websocket_owner_cleanup_witness, :websocket_owner_frame, :websocket_owner_output_commit_probe, :websocket_response_delivery_complete]

  for forwarding <- [false, true], transport <- [:websocket, :http] do
    @tag forwarding: forwarding, transport: transport
    test "forwarding=#{forwarding}: an ordinary pre-attempt disconnect admits the identical #{transport} resend", context do
      assert_disconnect_resend(context.forwarding, context.transport)
    end
  end

  defp assert_disconnect_resend(forwarding, transport) do
    CodexPooler.TestAppEnv.restore_on_exit(:websocket_owner_forwarding_enabled)
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, forwarding)
    upstream_response = if transport == :websocket, do: FakeUpstream.websocket_text_frames([completed_frame()]), else: FakeUpstream.sse_stream([CodexPooler.JSON.decode!(completed_frame())])
    upstream = start_upstream(upstream_response)
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    session_state = Ecto.UUID.generate()
    {:ok, state} = open_socket(auth, session_state)
    parent = self()

    state =
      Map.put(state, :response_task_start_options,
        before_direct_cleanup_ready: fn ->
          send(parent, {:reservation_committed, self()})

          receive do
            :resume -> :ok
          end
        end
      )

    frame = payload(setup)
    assert {:ok, state} = CodexResponsesSocket.handle_in({frame, [opcode: :text]}, state)
    assert_receive {:reservation_committed, task}, @budget
    on_exit(fn -> if Process.alive?(task), do: Process.exit(task, :kill) end)
    assert [request] = pool_requests(setup.pool.id)
    assert request.status == "in_progress"
    refute Repo.exists?(from a in Attempt, where: a.request_id == ^request.id)
    assert Accounting.reservation_outstanding?(request)

    monitor = Process.monitor(task)
    Process.exit(task, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^task, :killed}, @budget
    assert :ok = WebsocketCleanupFence.terminate_and_await!(:closed, state)

    request = Repo.reload!(request)
    turn = Repo.get_by!(CodexTurn, request_id: request.id)
    assert request.status == "failed"
    assert request.last_error_code == "client_disconnected"
    assert request.response_status_code == 499
    refute request.request_metadata["websocket_pre_attempt_drain"]
    assert turn.status == "interrupted"
    assert turn.error_code == "client_disconnected"
    assert is_nil(turn.final_attempt_id)
    assert is_nil(turn.first_visible_output_at)
    assert ClientRetry.original_witness_eligible?(request)
    refute Repo.exists?(from a in Attempt, where: a.request_id == ^request.id)
    refute Repo.exists?(from e in RequestReplayEntitlement, where: e.request_id == ^request.id)
    refute Accounting.reservation_outstanding?(request)
    assert ["release", "reservation"] == Repo.all(from e in LedgerEntry, where: e.request_id == ^request.id, order_by: e.entry_kind, select: e.entry_kind)
    release = Repo.one!(from e in LedgerEntry, where: e.request_id == ^request.id and e.entry_kind == "release")
    assert release.details["release_reason"] == "client_disconnected"
    assert release.details["pre_attempt_phase"] == "turn_interrupted"
    assert FakeUpstream.count(upstream) == 0

    assert_resend(transport, setup, auth, session_state, frame)
    assert [_, _] = pool_requests(setup.pool.id)
    assert FakeUpstream.count(upstream) == 1
    assert Repo.aggregate(from(a in Attempt, join: r in Request, on: a.request_id == r.id, where: r.pool_id == ^setup.pool.id), :count) == 1
    assert Repo.aggregate(from(e in LedgerEntry, join: r in Request, on: e.request_id == r.id, where: r.pool_id == ^setup.pool.id and e.entry_kind == "settlement" and e.amount_status == "recorded"), :count) == 1
  end

  defp assert_resend(:websocket, _setup, auth, session_state, frame) do
    assert {:ok, retry} = open_socket(auth, session_state)
    {received, retry} = next_frame(CodexResponsesSocket.handle_in({frame, [opcode: :text]}, retry))
    event = CodexPooler.JSON.decode!(received)
    assert event["type"] == "response.completed", inspect(Map.take(event, ["type", "error", "status"]))
    retry = settle_socket(retry)
    assert_socket_response_tasks_released!()
    assert :ok = WebsocketCleanupFence.terminate_and_await!(:closed, retry)
  end

  defp assert_resend(:http, setup, _auth, session_state, frame) do
    body = frame |> CodexPooler.JSON.decode!() |> Map.delete("type") |> CodexPooler.JSON.encode!()

    conn =
      build_conn()
      |> put_req_header("authorization", setup.authorization)
      |> put_req_header("x-codex-turn-state", session_state)
      |> put_req_header("content-type", "application/json")
      |> post("/backend-api/codex/responses", body)

    assert conn.status == 200
    assert conn.resp_body =~ "response.completed"
  end

  defp next_frame({:push, {:text, frame}, state}) do
    if StreamProtocol.internal_control_event?(frame),
      do: next_frame({:ok, state}),
      else: {frame, state}
  end

  defp next_frame({:ok, state}) do
    receive do
      message when is_tuple(message) and elem(message, 0) in @socket_messages ->
        next_frame(CodexResponsesSocket.handle_info(message, state))
    after
      @budget -> flunk("expected websocket frame")
    end
  end

  defp settle_socket(state) do
    if MapSet.size(state.tasks) == 0 and MapSet.size(state.response_task_delivery_scheduled) == 0 do
      state
    else
      receive do
        message when is_tuple(message) and elem(message, 0) in @socket_messages ->
          case CodexResponsesSocket.handle_info(message, state) do
            {:ok, state} -> settle_socket(state)
            {:push, _frame, state} -> settle_socket(state)
          end
      after
        @budget -> flunk("expected socket bookkeeping to settle")
      end
    end
  end

  defp open_socket(auth, session_state),
    do: CodexResponsesSocket.init(%{auth: auth, opts: %{request_id: Ecto.UUID.generate(), accepted_turn_state: session_state, client_ip: "127.0.0.1"}})

  defp pool_requests(pool_id), do: Repo.all(from r in Request, where: r.pool_id == ^pool_id, order_by: r.admitted_at)

  defp payload(setup) do
    id = Ecto.UUID.generate()

    CodexPooler.JSON.encode!(%{
      "type" => "response.create",
      "model" => setup.model.exposed_model_id,
      "stream" => true,
      "store" => false,
      "instructions" => "synthetic instructions",
      "input" => [%{"role" => "user", "content" => [%{"type" => "input_text", "text" => "synthetic turn"}]}],
      "client_metadata" => %{"x-codex-turn-metadata" => CodexPooler.JSON.encode!(%{"session_id" => id, "thread_id" => id, "turn_id" => id, "request_kind" => "turn"})}
    })
  end

  defp completed_frame,
    do: CodexPooler.JSON.encode!(%{"type" => "response.completed", "response" => %{"id" => "resp_synthetic_retry", "status" => "completed", "output" => [], "usage" => %{"input_tokens" => 3, "output_tokens" => 2, "total_tokens" => 5}}})
end

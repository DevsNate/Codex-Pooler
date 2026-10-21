defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocket.StalledReaderReceiptTest do
  # A native websocket client that stops reading in the middle of a large turn
  # (findings#232 row 232-256, measured by P42 on a real listener: 70 of 4005
  # frames reached the peer, the connection closed after the 30 s send timeout,
  # yet the receipt read `delivered response.completed frames_after_visible=4005`
  # because Bandit discards the result of every pushed frame's write). The resend
  # of that turn was then refused as a delivered one. The receipt now records
  # only what was written before the first failed write: `aborted`, no terminal,
  # the frames and class written before it and a fixed-vocabulary
  # `write_failure`, so the released client's identical resend is admitted as
  # one successor. A client that did read the terminal keeps its `delivered`
  # receipt, even when its connection then dies abruptly, and its resend stays a
  # duplicate.
  #
  # Real listener and real owner (forwarding on) or direct task (forwarding
  # off). The listener's own send timeout and send buffer are shortened
  # (production keeps ThousandIsland's 30 s default) and the client's receive
  # buffer is shrunk, so the stall shows within a second.
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [gateway_setup: 1, public_websocket_connect!: 3, public_websocket_send_text!: 4, start_upstream: 1]

  import CodexPoolerWeb.Runtime.BackendCodexWebsocketSupport, only: [model_serving_scope: 0, set_model_serving_mode!: 3]

  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request, RequestClientRetryLink}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol
  alias CodexPooler.Repo
  alias CodexPoolerWeb.Runtime.WebsocketCleanupFence

  @timeout_ms 15_000
  @poll_ms 100
  # A stalled write fails after this long on the test listener instead of
  # ThousandIsland's 30 s default.
  @send_timeout_ms 300
  @buffer_bytes 4_096
  # About 1 MB of deltas: far more than the shrunk socket buffers hold, so the
  # listener's write blocks once the client stops reading.
  @deltas 128
  @delta_bytes 8_192
  # created, in_progress, output_item.added, content_part.added, deltas,
  # output_text.done, content_part.done, output_item.done, completed
  @total_frames @deltas + 8

  for forwarding <- [true, false] do
    @tag forwarding: forwarding, content_filter_write_failure: true
    @tag slow: "actual socket buffer exhaustion and write timeout before content-filter terminal"
    test "owner forwarding #{forwarding}: a failed CF terminal write cannot authorize guidance", %{forwarding: forwarding} do
      %{setup: setup, upstream: upstream, port: port, turn_state: turn_state, raw_payload: raw_payload} = scenario!(forwarding, content_filter?: true)
      %{request_id: request_id, receipt: receipt} = stall_until_write_failure!(port, setup, turn_state, raw_payload)
      assert %{"outcome" => "aborted", "terminal_class" => "none", "write_failure" => "timeout"} = receipt
      attempt = Repo.get_by!(Attempt, request_id: request_id)
      assert attempt.response_metadata["native_content_filter_terminal"]["reason"] == "content_filter"
      refute Map.has_key?(receipt, "completed_items")
      guidance = %{"type" => "message", "role" => "developer", "content" => [%{"type" => "input_text", "text" => "<content_filter_guidance>\nsynthetic guidance\n</content_filter_guidance>"}]}
      retained = stream_frames("resp_stalled_original") |> Enum.map(&CodexPooler.JSON.decode!/1) |> Enum.find(&(&1["type"] == "response.output_item.done")) |> Map.fetch!("item")
      candidate = raw_payload |> CodexPooler.JSON.decode!() |> Map.update!("input", &(&1 ++ [retained, guidance])) |> CodexPooler.JSON.encode!()
      refused = send_and_receive_terminal!(port, setup, turn_state, candidate)
      assert refused["type"] == "error"
      assert refused["error"]["code"] == "duplicate_turn"
      assert FakeUpstream.count(upstream) == 1
      assert length(pool_requests(setup.pool.id)) == 1
      assert_one_settlement_each!([request_id])
    end

    @tag forwarding: forwarding
    @tag slow: "a real listener write that has to time out after the client stopped reading, the recorded receipt and a second socket's resend"
    test "owner forwarding #{forwarding}: a client that stopped reading mid-turn gets an aborted receipt and its identical resend is served", %{forwarding: forwarding} do
      %{setup: setup, upstream: upstream, port: port, turn_state: turn_state, raw_payload: raw_payload} = scenario!(forwarding)
      # The client sends its turn and never reads again, without closing (a
      # frozen client, or a proxy whose own client stopped reading).
      {conn, websocket, ref} = public_websocket_connect!(port, setup, turn_state)
      :ok = :inet.setopts(Mint.HTTP.get_socket(conn), recbuf: @buffer_bytes)
      {:ok, conn} = Mint.HTTP.set_mode(conn, :passive)
      {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, raw_payload)

      %Request{id: request_id} = await_request!(setup.pool.id, System.monotonic_time(:millisecond) + @timeout_ms)
      receipt = await_receipt!(request_id, System.monotonic_time(:millisecond) + @timeout_ms)
      # Everything the listener managed to write is still in the connection:
      # the client reads it all now, up to the close that followed the failure.
      {_conn, received} = read_text_frames!(conn, websocket, ref, :close)
      _settled = await_settled!(request_id, System.monotonic_time(:millisecond) + @timeout_ms)

      assert %{"outcome" => "aborted", "terminal_class" => "none", "highest_frame_class" => "delta", "write_failure" => "timeout", "pushed_at" => nil} = receipt
      refute Map.has_key?(receipt, "completed_items")
      # The receipt counts exactly the frames the client could read.
      counted = Enum.reject(received, &StreamProtocol.internal_control_event?/1)
      assert receipt["frames_after_visible"] == length(counted)
      assert length(counted) < @total_frames
      assert counted |> List.last() |> CodexPooler.JSON.decode!() |> Map.fetch!("type") == "response.output_text.delta"

      resend = send_and_receive_terminal!(port, setup, turn_state, raw_payload)
      await_all_settled!(setup.pool.id, System.monotonic_time(:millisecond) + @timeout_ms)

      assert resend["type"] == "response.completed"
      assert [%Request{id: ^request_id, status: "succeeded"}, %Request{id: successor_id, status: "succeeded"}] = pool_requests(setup.pool.id)
      assert [%RequestClientRetryLink{predecessor_request_id: ^request_id, successor_request_id: ^successor_id}] = Repo.all(RequestClientRetryLink)
      assert_one_settlement_each!([request_id, successor_id])
      assert FakeUpstream.count(upstream) == 2
    end

    # A frozen client (findings#232 row 232-261): it stops reading without
    # closing, so the listener notices it only when a write times out, 30 s
    # later with the default send timeout, long after the provider finished;
    # the released client resends once its connection is gone. The window of
    # that resend starts at the failed write the receipt names, not at the
    # provider's completion. The stall and the send error are real (short send
    # timeout); the provider's completion is then moved 35 s into the past,
    # the distance a 30 s send timeout puts between it and the resend.
    @tag forwarding: forwarding
    test "owner forwarding #{forwarding}: a frozen client's resend is served within the window of its failed write although the provider finished longer ago", %{forwarding: forwarding} do
      %{setup: setup, upstream: upstream, port: port, turn_state: turn_state, raw_payload: raw_payload} = scenario!(forwarding)
      %{request_id: request_id, receipt: receipt} = stall_until_write_failure!(port, setup, turn_state, raw_payload)
      assert %{"outcome" => "aborted", "highest_frame_class" => "delta", "write_failure" => "timeout"} = receipt

      completed_at = move_completion_back!(request_id, 35)

      resend = send_and_receive_terminal!(port, setup, turn_state, raw_payload)
      await_all_settled!(setup.pool.id, System.monotonic_time(:millisecond) + @timeout_ms)

      assert resend["type"] == "response.completed"
      assert [%Request{id: ^request_id, status: "succeeded"}, %Request{id: successor_id, status: "succeeded"}] = pool_requests(setup.pool.id)
      assert [%RequestClientRetryLink{predecessor_request_id: ^request_id, successor_request_id: ^successor_id}] = Repo.all(RequestClientRetryLink)
      assert_one_settlement_each!([request_id, successor_id])
      assert FakeUpstream.count(upstream) == 2

      # The failure's time, to the millisecond, after the moved completion.
      assert {:ok, failed_at, 0} = DateTime.from_iso8601(receipt["write_failed_at"])
      assert receipt["write_failed_at"] =~ ~r/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z\z/
      assert DateTime.diff(failed_at, completed_at, :second) in 30..45
    end

    # The window from the failed write still closes after 30 s: a resend that
    # comes later stays a duplicate.
    @tag forwarding: forwarding
    test "owner forwarding #{forwarding}: a frozen client's resend after the window of its failed write stays a duplicate", %{forwarding: forwarding} do
      %{setup: setup, upstream: upstream, port: port, turn_state: turn_state, raw_payload: raw_payload} = scenario!(forwarding)
      %{request_id: request_id, receipt: receipt} = stall_until_write_failure!(port, setup, turn_state, raw_payload)
      assert %{"outcome" => "aborted", "write_failure" => "timeout"} = receipt

      _completed_at = move_completion_back!(request_id, 70)
      :ok = move_write_failure_back!(request_id, 35)

      resend = send_and_receive_terminal!(port, setup, turn_state, raw_payload)
      await_all_settled!(setup.pool.id, System.monotonic_time(:millisecond) + @timeout_ms)

      assert %{"type" => "error", "error" => %{"code" => "duplicate_turn"}} = resend
      assert [%Request{id: ^request_id, status: "succeeded"}] = pool_requests(setup.pool.id)
      assert Repo.all(RequestClientRetryLink) == []
      assert FakeUpstream.count(upstream) == 1
    end

    # The client stops reading, leaving bytes in the listener's driver queue,
    # then resets the connection. The receipt names only the confirmed prefix:
    # with a large first delta, that prefix ends at content_part.added. Keep
    # the default 30 s send timeout, so the reset causes the actual failure and
    # the identical resend arrives inside its 30 s client-retry window.
    for {first_delta_bytes, queued_output, boundary} <- [
          {@delta_bytes, "queued output", :incomplete_prefix},
          {1_048_576, "the first delta queued", :before_first_delta}
        ] do
      @tag forwarding: forwarding
      test "owner forwarding #{forwarding}: a client dropped with #{queued_output} gets an aborted receipt and its identical resend is served", %{forwarding: forwarding} do
        assert_resend_after_queued_write_drop!(forwarding, unquote(first_delta_bytes), unquote(boundary))
      end
    end

    # The other direction: the client read the whole turn, terminal included,
    # and its connection then died without a close handshake. The receipt stays
    # `delivered` and names no write failure, so the resend (which the released
    # client would not send, having seen the terminal) is still a duplicate:
    # no second generation for a turn the client received.
    @tag forwarding: forwarding
    test "owner forwarding #{forwarding}: a client that read the terminal and then dropped its connection keeps a delivered receipt", %{forwarding: forwarding} do
      %{setup: setup, upstream: upstream, port: port, turn_state: turn_state, raw_payload: raw_payload} = scenario!(forwarding)
      {conn, websocket, ref} = public_websocket_connect!(port, setup, turn_state)
      {:ok, conn} = Mint.HTTP.set_mode(conn, :passive)
      {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, raw_payload)
      {conn, received} = read_text_frames!(conn, websocket, ref, :terminal)
      assert received |> List.last() |> CodexPooler.JSON.decode!() |> Map.fetch!("type") == "response.completed"
      # A reset, not a close handshake: the connection just dies.
      :ok = :inet.setopts(Mint.HTTP.get_socket(conn), linger: {true, 0})
      _closed = Mint.HTTP.close(conn)

      assert [%Request{id: request_id}] = pool_requests(setup.pool.id)
      receipt = await_receipt!(request_id, System.monotonic_time(:millisecond) + @timeout_ms)
      _settled = await_settled!(request_id, System.monotonic_time(:millisecond) + @timeout_ms)

      assert %{"outcome" => "delivered", "terminal_class" => "response.completed", "highest_frame_class" => "terminal", "frames_after_visible" => @total_frames} = receipt
      refute Map.has_key?(receipt, "write_failure")

      resend = send_and_receive_terminal!(port, setup, turn_state, raw_payload)
      await_all_settled!(setup.pool.id, System.monotonic_time(:millisecond) + @timeout_ms)

      assert %{"type" => "response.completed"} = resend
      assert [%Request{id: ^request_id, status: "succeeded"}, %Request{id: successor_id, status: "succeeded"}] = pool_requests(setup.pool.id)
      assert [%RequestClientRetryLink{predecessor_request_id: ^request_id, successor_request_id: ^successor_id}] = Repo.all(RequestClientRetryLink)
      assert_one_settlement_each!([request_id, successor_id])
      assert FakeUpstream.count(upstream) == 2
    end
  end

  # A small turn fits the connection buffers and receives a delivered receipt
  # before the passive client decodes it. Reading afterwards proves those
  # bytes remain available. Backdating completion then exercises the retry
  # window independently; this does not reproduce a client watchdog or loss.
  @tag repro: :retry_window
  @tag slow: "a real refused resend plus the receipt wait"
  test "a small turn records delivery before the client reads and rejects an identical resend after expiry" do
    %{setup: setup, upstream: upstream, port: port, turn_state: turn_state, raw_payload: raw_payload} = small_scenario!(:one)

    # Delay application reads until after the receipt without closing or
    # filling the socket buffers.
    {conn, websocket, ref} = public_websocket_connect!(port, setup, turn_state)
    {:ok, conn} = Mint.HTTP.set_mode(conn, :passive)
    {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, raw_payload)

    %Request{id: request_id} = await_request!(setup.pool.id, System.monotonic_time(:millisecond) + @timeout_ms)
    receipt = await_receipt!(request_id, System.monotonic_time(:millisecond) + @timeout_ms)
    _settled = await_settled!(request_id, System.monotonic_time(:millisecond) + @timeout_ms)

    # The boundary: a delivered terminal while this client decoded no frame.
    assert %{"outcome" => "delivered", "terminal_class" => "response.completed", "highest_frame_class" => "terminal", "frames_after_visible" => frames} = receipt
    assert frames > 0
    refute Map.has_key?(receipt, "write_failure")

    # The frames were written into the connection the whole time: reading only
    # now still yields exactly the push the receipt counted.
    {_conn, received} = read_text_frames!(conn, websocket, ref, :terminal)
    assert received |> Enum.reject(&StreamProtocol.internal_control_event?/1) |> length() == frames

    # Move completion outside the ordinary retry window without running a
    # real client timeout. The identical resend must remain a duplicate.
    _completed_at = move_completion_back!(request_id, 305)
    refused = send_and_receive_terminal!(port, setup, turn_state, raw_payload)

    assert %{"type" => "error", "error" => %{"code" => "duplicate_turn"}} = refused
    assert [%Request{id: ^request_id, status: "succeeded"}] = pool_requests(setup.pool.id)
    assert FakeUpstream.count(upstream) == 1
    assert Repo.all(RequestClientRetryLink) == []
  end

  # With an unread delivered predecessor still inside the ordinary window,
  # the identical resend is admitted as a successor and dispatched again.
  # This compares retry admission, not recovery of the previous response.
  @tag repro: :retry_window
  @tag slow: "two provider dispatches and a successor settlement"
  test "the identical resend of a delivered-but-unread turn is served inside the ordinary retry window" do
    %{setup: setup, upstream: upstream, port: port, turn_state: turn_state, raw_payload: raw_payload} = small_scenario!(:two)

    {conn, websocket, ref} = public_websocket_connect!(port, setup, turn_state)
    {:ok, conn} = Mint.HTTP.set_mode(conn, :passive)
    {_conn, _websocket} = public_websocket_send_text!(conn, websocket, ref, raw_payload)

    %Request{id: request_id} = await_request!(setup.pool.id, System.monotonic_time(:millisecond) + @timeout_ms)
    receipt = await_receipt!(request_id, System.monotonic_time(:millisecond) + @timeout_ms)
    _settled = await_settled!(request_id, System.monotonic_time(:millisecond) + @timeout_ms)
    assert %{"outcome" => "delivered", "terminal_class" => "response.completed"} = receipt

    served = send_and_receive_terminal!(port, setup, turn_state, raw_payload)
    await_all_settled!(setup.pool.id, System.monotonic_time(:millisecond) + @timeout_ms)

    assert %{"type" => "response.completed"} = served
    assert [%Request{id: ^request_id, status: "succeeded"}, %Request{status: "succeeded"}] = pool_requests(setup.pool.id)
    assert FakeUpstream.count(upstream) == 2
  end

  defp assert_resend_after_queued_write_drop!(forwarding, first_delta_bytes, boundary) do
    %{setup: setup, upstream: upstream, port: port, turn_state: turn_state, raw_payload: raw_payload} = scenario!(forwarding, send_timeout: :default, first_delta_bytes: first_delta_bytes)
    {conn, websocket, ref} = public_websocket_connect!(port, setup, turn_state)
    :ok = :inet.setopts(Mint.HTTP.get_socket(conn), recbuf: @buffer_bytes)
    {:ok, conn} = Mint.HTTP.set_mode(conn, :passive)
    {conn, _websocket} = public_websocket_send_text!(conn, websocket, ref, raw_payload)

    %Request{id: request_id} = await_request!(setup.pool.id, System.monotonic_time(:millisecond) + @timeout_ms)
    :ok = await_queued_listener_bytes!(conn, System.monotonic_time(:millisecond) + @timeout_ms)
    # A reset, not a close handshake.
    :ok = :inet.setopts(Mint.HTTP.get_socket(conn), linger: {true, 0})
    _closed = Mint.HTTP.close(conn)

    receipt = await_receipt!(request_id, System.monotonic_time(:millisecond) + @timeout_ms)
    _settled = await_settled!(request_id, System.monotonic_time(:millisecond) + @timeout_ms)

    assert %{"outcome" => "aborted", "terminal_class" => "none", "pushed_at" => nil, "frames_after_visible" => frame_count} = receipt
    assert receipt["write_failure"] in ["closed", "other"]
    assert frame_count in 4..(@deltas + 4)
    assert receipt["highest_frame_class"] == if(frame_count == 4, do: "part_added", else: "delta")
    refute Map.has_key?(receipt, "completed_items")

    if boundary == :before_first_delta do
      assert %{"frames_after_visible" => 4, "highest_frame_class" => "part_added"} = receipt
    end

    resend = send_and_receive_terminal!(port, setup, turn_state, raw_payload)
    await_all_settled!(setup.pool.id, System.monotonic_time(:millisecond) + @timeout_ms)

    assert resend["type"] == "response.completed"
    assert [%Request{id: ^request_id, status: "succeeded"}, %Request{id: successor_id, status: "succeeded"}] = pool_requests(setup.pool.id)
    assert [%RequestClientRetryLink{predecessor_request_id: ^request_id, successor_request_id: ^successor_id}] = Repo.all(RequestClientRetryLink)
    assert_one_settlement_each!([request_id, successor_id])
    assert FakeUpstream.count(upstream) == 2
  end

  defp scenario!(forwarding, opts \\ []) do
    CodexPooler.TestAppEnv.restore_on_exit(:websocket_owner_forwarding_enabled, false)
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, forwarding)

    upstream =
      start_upstream(
        FakeUpstream.strict_sequence([
          native_request(FakeUpstream.websocket_text_frames(maybe_content_filter(stream_frames("resp_stalled_original", opts), opts))),
          native_request(FakeUpstream.websocket_text_frames(stream_frames("resp_stalled_successor")))
        ])
      )

    setup = gateway_setup(upstream)
    _revision = set_model_serving_mode!(model_serving_scope(), setup, "lite")
    raw_payload = CodexPooler.JSON.encode!(native_turn_payload(Ecto.UUID.generate(), setup.model.exposed_model_id))
    port = start_stalling_endpoint!(Keyword.get(opts, :send_timeout, @send_timeout_ms))
    %{setup: setup, upstream: upstream, port: port, turn_state: Ecto.UUID.generate(), raw_payload: raw_payload}
  end

  defp maybe_content_filter(frames, opts) do
    if Keyword.get(opts, :content_filter?, false) do
      List.update_at(frames, -1, fn frame ->
        frame |> CodexPooler.JSON.decode!() |> Map.put("type", "response.incomplete") |> put_in(["response", "status"], "incomplete") |> put_in(["response", "incomplete_details"], %{"reason" => "content_filter"}) |> CodexPooler.JSON.encode!()
      end)
    else
      frames
    end
  end

  # The shared helper's listener with a small send buffer and, unless
  # `:default`, a short send timeout; the client side's receive buffer is
  # shrunk after the connect.
  defp start_stalling_endpoint!(send_timeout) do
    :ok = WebsocketCleanupFence.install!()
    transport_options = if send_timeout == :default, do: [sndbuf: @buffer_bytes], else: [send_timeout: send_timeout, sndbuf: @buffer_bytes]

    {:ok, server} =
      Bandit.start_link(
        plug: CodexPoolerWeb.Endpoint,
        port: 0,
        ip: {127, 0, 0, 1},
        startup_log: false,
        thousand_island_options: [transport_options: transport_options]
      )

    on_exit(fn ->
      try do
        ThousandIsland.stop(server)
      catch
        :exit, _reason -> :ok
      end
    end)

    :ok = WebsocketCleanupFence.install!(server: server)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    port
  end

  # The first test's stall: the client sends its turn and never reads again,
  # the listener's write times out; then the client reads what was written up
  # to the close, and the turn settles.
  defp stall_until_write_failure!(port, setup, turn_state, raw_payload) do
    {conn, websocket, ref} = public_websocket_connect!(port, setup, turn_state)
    :ok = :inet.setopts(Mint.HTTP.get_socket(conn), recbuf: @buffer_bytes)
    {:ok, conn} = Mint.HTTP.set_mode(conn, :passive)
    {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, raw_payload)

    %Request{id: request_id} = await_request!(setup.pool.id, System.monotonic_time(:millisecond) + @timeout_ms)
    receipt = await_receipt!(request_id, System.monotonic_time(:millisecond) + @timeout_ms)
    {_conn, _received} = read_text_frames!(conn, websocket, ref, :close)
    _settled = await_settled!(request_id, System.monotonic_time(:millisecond) + @timeout_ms)
    %{request_id: request_id, receipt: receipt}
  end

  # The injected time: the predecessor completed `seconds` earlier than it did.
  defp move_completion_back!(request_id, seconds) do
    %Request{completed_at: %DateTime{} = completed_at} = Repo.get!(Request, request_id)
    moved = DateTime.add(completed_at, -seconds, :second)
    {1, _rows} = Repo.update_all(from(r in Request, where: r.id == ^request_id), set: [completed_at: moved])
    moved
  end

  # The injected time: the receipt's write failed `seconds` earlier than it did.
  defp move_write_failure_back!(request_id, seconds) do
    [%Attempt{id: attempt_id, response_metadata: %{"downstream_delivery" => %{"write_failed_at" => failed_at} = receipt} = metadata}] =
      Repo.all(from(a in Attempt, where: a.request_id == ^request_id))

    {:ok, failed_at, 0} = DateTime.from_iso8601(failed_at)
    moved = failed_at |> DateTime.add(-seconds, :second) |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()
    metadata = Map.put(metadata, "downstream_delivery", Map.put(receipt, "write_failed_at", moved))
    {1, _rows} = Repo.update_all(from(a in Attempt, where: a.id == ^attempt_id), set: [response_metadata: metadata])
    :ok
  end

  # The unread connection has unsent bytes in its listener-side driver queue.
  # The inet backend can return from send while those bytes remain queued.
  defp await_queued_listener_bytes!(conn, deadline_ms) do
    {:ok, client_address} = :inet.sockname(Mint.HTTP.get_socket(conn))
    await_queued_port_bytes!(client_address, deadline_ms)
  end

  defp await_queued_port_bytes!(client_address, deadline_ms) do
    queued? =
      Enum.any?(Port.list(), fn port ->
        Port.info(port, :name) == {:name, ~c"tcp_inet"} and :inet.peername(port) == {:ok, client_address} and
          match?({:queue_size, size} when size > 0, :erlang.port_info(port, :queue_size))
      end)

    cond do
      queued? -> :ok
      System.monotonic_time(:millisecond) >= deadline_ms -> flunk("the listener never queued unsent bytes")
      true -> Process.sleep(10) && await_queued_port_bytes!(client_address, deadline_ms)
    end
  end

  defp assert_one_settlement_each!(request_ids) do
    for id <- request_ids do
      assert Repo.all(from(l in LedgerEntry, where: l.request_id == ^id and l.amount_status == "recorded", select: l.entry_kind)) |> Enum.frequencies() ==
               %{"reservation" => 1, "settlement" => 1, "release" => 1}
    end
  end

  # Keep the response small enough for the passive loopback client's buffers.
  defp small_scenario!(responses) do
    CodexPooler.TestAppEnv.restore_on_exit(:websocket_owner_forwarding_enabled, false)
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, true)

    upstream =
      start_upstream(
        FakeUpstream.strict_sequence(
          for response_id <- Enum.take(["resp_small_delivered_1", "resp_small_delivered_2"], if(responses == :one, do: 1, else: 2)),
              do: native_request(FakeUpstream.websocket_text_frames(small_stream_frames(response_id)))
        )
      )

    setup = gateway_setup(upstream)
    _revision = set_model_serving_mode!(model_serving_scope(), setup, "lite")
    raw_payload = CodexPooler.JSON.encode!(native_turn_payload(Ecto.UUID.generate(), setup.model.exposed_model_id))
    port = start_plain_endpoint!()
    %{setup: setup, upstream: upstream, port: port, turn_state: Ecto.UUID.generate(), raw_payload: raw_payload}
  end

  # The shared helper's listener with production buffers and the production send
  # timeout: nothing here is shortened for a failure, because the turn is small
  # enough that no write has to fail.
  defp start_plain_endpoint! do
    :ok = WebsocketCleanupFence.install!()

    {:ok, server} =
      Bandit.start_link(
        plug: CodexPoolerWeb.Endpoint,
        port: 0,
        ip: {127, 0, 0, 1},
        startup_log: false
      )

    on_exit(fn ->
      try do
        ThousandIsland.stop(server)
      catch
        :exit, _reason -> :ok
      end
    end)

    :ok = WebsocketCleanupFence.install!(server: server)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    port
  end

  defp small_stream_frames(response_id) do
    item_id = "msg_" <> response_id
    text = "small delivered text"
    item = %{"id" => item_id, "type" => "message", "role" => "assistant", "status" => "completed", "content" => [%{"type" => "output_text", "text" => text, "annotations" => []}]}

    Enum.map(
      [
        %{"type" => "response.created", "response" => %{"id" => response_id, "status" => "in_progress", "output" => []}},
        %{"type" => "response.in_progress", "response" => %{"id" => response_id, "status" => "in_progress", "output" => []}},
        %{"type" => "response.output_item.added", "output_index" => 0, "item" => %{"id" => item_id, "type" => "message", "role" => "assistant", "status" => "in_progress", "content" => []}},
        %{"type" => "response.content_part.added", "item_id" => item_id, "output_index" => 0, "content_index" => 0, "part" => %{"type" => "output_text", "text" => "", "annotations" => []}},
        %{"type" => "response.output_text.delta", "item_id" => item_id, "output_index" => 0, "content_index" => 0, "delta" => text},
        %{"type" => "response.output_text.done", "item_id" => item_id, "output_index" => 0, "content_index" => 0, "text" => text},
        %{"type" => "response.content_part.done", "item_id" => item_id, "output_index" => 0, "content_index" => 0, "part" => %{"type" => "output_text", "text" => text, "annotations" => []}},
        %{"type" => "response.output_item.done", "output_index" => 0, "item" => item},
        %{"type" => "response.completed", "response" => %{"id" => response_id, "status" => "completed", "output" => [item], "usage" => %{"input_tokens" => 3, "output_tokens" => 2, "total_tokens" => 5}}}
      ],
      &CodexPooler.JSON.encode!/1
    )
  end

  defp native_request(respond) do
    FakeUpstream.expect_request(method: "WEBSOCKET", path: "/backend-api/codex/responses", json: [valid: true, equals: %{"type" => "response.create"}], respond: respond)
  end

  defp stream_frames(response_id, opts \\ []) do
    item_id = "msg_" <> response_id
    chunk = String.duplicate("a", @delta_bytes)
    first_chunk = String.duplicate("a", Keyword.get(opts, :first_delta_bytes, @delta_bytes))
    text = String.duplicate(chunk, 2)
    item = %{"id" => item_id, "type" => "message", "role" => "assistant", "status" => "completed", "content" => [%{"type" => "output_text", "text" => text, "annotations" => []}]}

    Enum.map(
      [
        %{"type" => "response.created", "response" => %{"id" => response_id, "status" => "in_progress", "output" => []}},
        %{"type" => "response.in_progress", "response" => %{"id" => response_id, "status" => "in_progress", "output" => []}},
        %{"type" => "response.output_item.added", "output_index" => 0, "item" => %{"id" => item_id, "type" => "message", "role" => "assistant", "status" => "in_progress", "content" => []}},
        %{"type" => "response.content_part.added", "item_id" => item_id, "output_index" => 0, "content_index" => 0, "part" => %{"type" => "output_text", "text" => "", "annotations" => []}}
      ] ++
        for(delta <- 1..@deltas, do: %{"type" => "response.output_text.delta", "item_id" => item_id, "output_index" => 0, "content_index" => 0, "delta" => if(delta == 1, do: first_chunk, else: chunk)}) ++
        [
          %{"type" => "response.output_text.done", "item_id" => item_id, "output_index" => 0, "content_index" => 0, "text" => text},
          %{"type" => "response.content_part.done", "item_id" => item_id, "output_index" => 0, "content_index" => 0, "part" => %{"type" => "output_text", "text" => text, "annotations" => []}},
          %{"type" => "response.output_item.done", "output_index" => 0, "item" => item},
          %{"type" => "response.completed", "response" => %{"id" => response_id, "status" => "completed", "output" => [item], "usage" => %{"input_tokens" => 3, "output_tokens" => 2, "total_tokens" => 5}}}
        ],
      &CodexPooler.JSON.encode!/1
    )
  end

  defp native_turn_payload(thread_id, model) do
    %{
      "type" => "response.create",
      "model" => model,
      "instructions" => "synthetic base instructions",
      "stream" => true,
      "store" => false,
      "client_metadata" => %{
        "session_id" => thread_id,
        "thread_id" => thread_id,
        "turn_id" => "stalled-reader-turn",
        "x-codex-window-id" => thread_id <> ":0",
        "x-codex-turn-metadata" => CodexPooler.JSON.encode!(%{"session_id" => thread_id, "thread_id" => thread_id, "turn_id" => "stalled-reader-turn", "request_kind" => "turn"}),
        "x-codex-ws-stream-request-start-ms" => 100,
        "ws_request_header_x_openai_internal_codex_responses_lite" => "true"
      },
      "input" => [%{"type" => "message", "role" => "user", "content" => [%{"type" => "input_text", "text" => "synthetic stalled reader turn"}]}]
    }
  end

  defp send_and_receive_terminal!(port, setup, turn_state, raw_payload) do
    {conn, websocket, ref} = public_websocket_connect!(port, setup, turn_state)
    {:ok, conn} = Mint.HTTP.set_mode(conn, :passive)
    {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, raw_payload)
    {conn, received} = read_text_frames!(conn, websocket, ref, :terminal)
    _closed = Mint.HTTP.close(conn)
    received |> Enum.find(&terminal_text?/1) |> CodexPooler.JSON.decode!()
  end

  # Reads the passive connection's complete text frames, in order, up to the
  # turn's terminal or up to the listener's close (a partly written frame at
  # the end stays undecoded). The large frames of this turn are decoded here
  # rather than through the shared receive helper.
  defp read_text_frames!(conn, websocket, ref, until, acc \\ []) do
    case Mint.WebSocket.recv(conn, 0, @timeout_ms) do
      {:ok, conn, responses} ->
        {websocket, texts} = decode_texts!(websocket, ref, responses)
        acc = acc ++ texts

        if until == :terminal and Enum.any?(texts, &terminal_text?/1),
          do: {conn, acc},
          else: read_text_frames!(conn, websocket, ref, until, acc)

      {:error, conn, closed, responses} when until == :close and closed in [:closed, %Mint.TransportError{reason: :closed}] ->
        {_websocket, texts} = decode_texts!(websocket, ref, responses)
        _closed = Mint.HTTP.close(conn)
        {conn, acc ++ texts}
    end
  end

  defp terminal_text?(text), do: CodexPooler.JSON.decode!(text)["type"] in ["response.completed", "response.failed", "response.incomplete", "error"]

  defp decode_texts!(websocket, ref, responses) do
    Enum.reduce(responses, {websocket, []}, fn
      {:data, ^ref, data}, {websocket, texts} ->
        {:ok, websocket, frames} = Mint.WebSocket.decode(websocket, data)
        {websocket, texts ++ for({:text, text} <- frames, do: text)}

      _other, acc ->
        acc
    end)
  end

  defp pool_requests(pool_id), do: Repo.all(from(r in Request, where: r.pool_id == ^pool_id, order_by: [asc: r.admitted_at]))

  defp await_receipt!(request_id, deadline_ms) do
    case safe_all(from(a in Attempt, where: a.request_id == ^request_id)) do
      [%Attempt{response_metadata: %{"downstream_delivery" => %{} = receipt}}] ->
        receipt

      _pending ->
        if System.monotonic_time(:millisecond) >= deadline_ms,
          do: flunk("no delivery receipt for #{request_id} within the budget"),
          else: Process.sleep(@poll_ms) && await_receipt!(request_id, deadline_ms)
    end
  end

  defp await_request!(pool_id, deadline_ms) do
    case safe_all(from(r in Request, where: r.pool_id == ^pool_id)) do
      [%Request{} = request] ->
        request

      _pending ->
        if System.monotonic_time(:millisecond) >= deadline_ms,
          do: flunk("the turn was never admitted"),
          else: Process.sleep(@poll_ms) && await_request!(pool_id, deadline_ms)
    end
  end

  defp await_settled!(request_id, deadline_ms) do
    case safe_all(from(r in Request, where: r.id == ^request_id and r.status != "in_progress")) do
      [%Request{} = request] ->
        request

      _pending ->
        if System.monotonic_time(:millisecond) >= deadline_ms,
          do: flunk("request never settled"),
          else: Process.sleep(@poll_ms) && await_settled!(request_id, deadline_ms)
    end
  end

  defp await_all_settled!(pool_id, deadline_ms) do
    requests = safe_all(from(r in Request, where: r.pool_id == ^pool_id))

    cond do
      requests != [] and Enum.all?(requests, &(&1.status != "in_progress")) -> :ok
      System.monotonic_time(:millisecond) >= deadline_ms -> flunk("requests never settled")
      true -> Process.sleep(@poll_ms) && await_all_settled!(pool_id, deadline_ms)
    end
  end

  defp safe_all(query) do
    Repo.all(query)
  rescue
    DBConnection.ConnectionError -> []
  end
end

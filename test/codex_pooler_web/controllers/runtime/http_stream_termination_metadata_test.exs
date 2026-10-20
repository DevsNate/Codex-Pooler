defmodule CodexPoolerWeb.Runtime.HttpStreamTerminationMetadataTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport

  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPooler.Pools.ModelServingOverride
  alias CodexPooler.Repo

  @budget 15_000
  @moduletag capture_log: true

  for surface <- [:native, :public], mode <- ["full", "lite"], ending <- [:body_done, :transport_close, :receive_timeout, :completed] do
    test "#{surface} #{mode} #{ending} preserves wire and settlement while recording observed termination" do
      run_scenario(unquote(surface), unquote(mode), unquote(ending))
    end
  end

  test "observed upstream timeout survives a subsequent real downstream terminal write failure" do
    previous = CodexPooler.TestAppEnv.restore_on_exit(OperationalSettings)
    Application.put_env(:codex_pooler, OperationalSettings, previous |> Keyword.put(:settings, %OperationalSettings{upstream_receive_timeout_ms: 500}) |> Keyword.put(:use_instance_settings?, false))
    release_ref = make_ref()
    upstream = start_upstream(FakeUpstream.timeout_mid_stream(delta(), notify: self(), release_ref: release_ref))
    setup = gateway_setup(upstream)
    {listener, port} = start_public_endpoint_with_server!()
    ownership = capture_public_endpoint_ownership!(listener)
    {:ok, conn} = Mint.HTTP.connect(:http, "127.0.0.1", port, mode: :passive)
    on_exit(fn -> Mint.HTTP.close(conn) end)
    {:ok, {_address, client_port}} = :inet.sockname(Mint.HTTP.get_socket(conn))
    hold_ref = make_ref()
    id = {__MODULE__, hold_ref}
    on_exit(fn -> :telemetry.detach(id) end)
    :ok = :telemetry.attach_many(id, [[:thousand_island, :connection, :send], [:thousand_island, :connection, :send_error]], &__MODULE__.observe_terminal_write/4, %{test: self(), public_port: port, client_port: client_port, ref: hold_ref})
    watch = {CodexPoolerWeb.WebsocketDownstreamWriteWatch, :send}
    assert [^watch, ^id] = for(%{id: handler} <- :telemetry.list_handlers([:thousand_island, :connection, :send]), handler in [watch, id], do: handler)
    {route, payload, headers} = request(:public, "full", setup)
    {:ok, conn, _request_ref} = Mint.HTTP.request(conn, "POST", route, [{"content-type", "application/json"} | headers], CodexPooler.JSON.encode!(payload))
    assert_receive {:fake_upstream_timeout_barrier, :mid_stream, handler, ^release_ref}, @budget
    on_exit(fn -> send(handler, {:fake_upstream_release_timeout, release_ref}) end)
    assert_receive {:termination_prefix_held, ^hold_ref, writer}, @budget
    writer_monitor = Process.monitor(writer)
    :ok = :inet.setopts(Mint.HTTP.get_socket(conn), linger: {true, 0})
    Mint.HTTP.close(conn)
    assert_receive {:termination_peer_closed, ^hold_ref, peer_reason}, @budget
    assert peer_reason in [:closed, :econnreset]
    assert_receive {:termination_terminal_send_error, ^hold_ref, write_reason}, @budget
    assert write_reason in [:closed, :econnreset, :einval]
    assert_receive {:DOWN, ^writer_monitor, :process, ^writer, _reason}, @budget
    send(handler, {:fake_upstream_release_timeout, release_ref})
    assert [request] = Repo.all(from r in Request, where: r.pool_id == ^setup.pool.id)
    assert [attempt] = Repo.all(from a in Attempt, where: a.request_id == ^request.id)
    assert_failure_metadata(:receive_timeout, attempt.response_metadata)
    assert request.retry_count == 0
    assert FakeUpstream.http_request_count(upstream) == 1
    assert Repo.aggregate(from(l in LedgerEntry, where: l.request_id == ^request.id and l.entry_kind == "settlement"), :count) == 1
    assert Repo.aggregate(from(l in LedgerEntry, where: l.request_id == ^request.id and l.entry_kind == "release"), :count) == 1
    listener_monitor = Process.monitor(listener)
    :ok = ThousandIsland.stop(listener)
    assert_receive {:DOWN, ^listener_monitor, :process, ^listener, _}, @budget
    assert_public_endpoint_released!(ownership)
  end

  # Hold after the real prefix send, and resume only once this exact socket has
  # observed the peer reset. The relay next observes its upstream timeout and
  # attempts the public error terminal through the now-closed real socket.
  @doc false
  def observe_terminal_write(event, %{data: data} = measurements, _metadata, config) do
    {:links, links} = Process.info(self(), :links)
    socket = Enum.find(links, fn link -> is_port(link) and Port.info(link, :name) == {:name, ~c"tcp_inet"} and match?({:ok, {_, port}} when port == config.public_port, :inet.sockname(link)) end)
    key = {__MODULE__, config.ref}
    owned? = Process.get(key, false) or (is_port(socket) and match?({:ok, {_, port}} when port == config.client_port, :inet.peername(socket)))

    if owned? do
      Process.put(key, true)
      bytes = IO.iodata_to_binary(data)

      case {List.last(event), String.contains?(bytes, "visible-termination-sentinel"), String.contains?(bytes, "event: error")} do
        {:send, true, _} ->
          monitor = Process.monitor(config.test)
          :ok = :inet.setopts(socket, active: :once)
          send(config.test, {:termination_prefix_held, config.ref, self()})

          receive do
            {:tcp_error, ^socket, reason} = closed ->
              send(config.test, {:termination_peer_closed, config.ref, reason})
              send(self(), closed)

            {:tcp_closed, ^socket} = closed ->
              send(config.test, {:termination_peer_closed, config.ref, :closed})
              send(self(), closed)

            {:DOWN, ^monitor, :process, _test, _reason} ->
              :ok
          after
            @budget -> send(config.test, {:termination_peer_closed, config.ref, :not_observed})
          end

          Process.demonitor(monitor, [:flush])

        {:send_error, _, true} ->
          send(config.test, {:termination_terminal_send_error, config.ref, measurements[:error]})

        _other ->
          :ok
      end
    end

    :ok
  end

  defp run_scenario(surface, mode, ending) do
    previous = CodexPooler.TestAppEnv.restore_on_exit(OperationalSettings)
    settings = if ending == :receive_timeout, do: %OperationalSettings{upstream_receive_timeout_ms: 500}, else: %OperationalSettings{}
    Application.put_env(:codex_pooler, OperationalSettings, previous |> Keyword.put(:settings, settings) |> Keyword.put(:use_instance_settings?, false))
    prefix = if surface == :native, do: tool_event() <> delta(), else: delta()
    release_ref = make_ref()
    upstream = start_upstream(source(ending, prefix, release_ref))
    setup = gateway_setup(upstream)
    now = DateTime.utc_now()
    Repo.insert!(%ModelServingOverride{pool_id: setup.pool.id, exposed_model_id: setup.model.exposed_model_id, mode: mode, created_at: now, updated_at: now})
    {listener, port} = start_public_endpoint_with_server!()
    ownership = capture_public_endpoint_ownership!(listener)
    supervisor = start_supervised!(Task.Supervisor)
    {route, payload, headers} = request(surface, mode, setup)
    task = Task.Supervisor.async_nolink(supervisor, fn -> Req.post!("http://127.0.0.1:#{port}#{route}", json: payload, headers: headers, retry: false, receive_timeout: @budget) end)
    monitor = Process.monitor(task.pid)

    handler =
      if ending == :receive_timeout do
        assert_receive {:fake_upstream_timeout_barrier, :mid_stream, handler, ^release_ref}, @budget
        on_exit(fn -> send(handler, {:fake_upstream_release_timeout, release_ref}) end)
        handler
      end

    response = Task.await(task, @budget)
    assert_receive {:DOWN, ^monitor, :process, _, :normal}, @budget
    if handler, do: send(handler, {:fake_upstream_release_timeout, release_ref})
    assert response.status == 200
    assert_wire(surface, ending, response.body, prefix)
    assert [request] = Repo.all(from r in Request, where: r.pool_id == ^setup.pool.id)
    assert [attempt] = Repo.all(from a in Attempt, where: a.request_id == ^request.id)
    assert request.status == if(ending == :completed, do: "succeeded", else: "failed")
    assert attempt.status == request.status
    assert request.last_error_code == expected_error(ending)
    assert attempt.network_error_code == expected_error(ending)
    assert request.retry_count == 0
    assert FakeUpstream.http_request_count(upstream) == 1
    assert attempt.response_metadata["routing"]["model_serving_mode"] == mode
    assert Repo.aggregate(from(l in LedgerEntry, where: l.request_id == ^request.id and l.entry_kind == "settlement"), :count) == 1
    assert Repo.aggregate(from(l in LedgerEntry, where: l.request_id == ^request.id and l.entry_kind == "release"), :count) == 1
    assert_failure_metadata(ending, attempt.response_metadata)
    persisted = inspect({request.request_metadata, attempt.response_metadata})
    refute persisted =~ "synthetic termination sentinel"
    refute persisted =~ "visible-termination-sentinel"
    listener_monitor = Process.monitor(listener)
    :ok = ThousandIsland.stop(listener)
    assert_receive {:DOWN, ^listener_monitor, :process, ^listener, _}, @budget
    assert_public_endpoint_released!(ownership)
  end

  defp source(:body_done, prefix, _ref), do: FakeUpstream.sse_stream([prefix], done: false)
  defp source(:transport_close, prefix, _ref), do: FakeUpstream.abrupt_close_mid_stream([prefix])
  defp source(:receive_timeout, prefix, ref), do: FakeUpstream.timeout_mid_stream(prefix, notify: self(), release_ref: ref)
  defp source(:completed, prefix, _ref), do: FakeUpstream.sse_stream([prefix, completion()], done: false)

  defp request(surface, mode, setup) do
    payload = %{"model" => setup.model.exposed_model_id, "instructions" => "synthetic", "input" => native_text_input("synthetic termination sentinel"), "stream" => true, "store" => false}
    thread = Ecto.UUID.generate()
    turn_metadata = CodexPooler.JSON.encode!(%{"session_id" => thread, "thread_id" => thread, "turn_id" => "synthetic-termination-turn", "request_kind" => "turn"})
    payload = if surface == :native, do: Map.put(payload, "client_metadata", %{"x-codex-turn-metadata" => turn_metadata}), else: payload
    headers = [{"authorization", setup.authorization}, {"originator", "codex_cli_rs"}, {"session-id", thread}]
    headers = if surface == :native and mode == "lite", do: [{"x-openai-internal-codex-responses-lite", "true"} | headers], else: headers
    route = if surface == :native, do: "/backend-api/codex/responses", else: "/v1/responses"
    {route, payload, headers}
  end

  defp assert_wire(:native, :completed, body, prefix), do: assert(body == prefix <> completion())
  defp assert_wire(:native, _ending, body, prefix), do: assert(body == prefix)

  defp assert_wire(:public, ending, body, _prefix) do
    assert body =~ "visible-termination-sentinel"

    if ending == :completed do
      assert body =~ "response.completed"
      refute body =~ "event: error"
    else
      assert body =~ "event: error"
      refute body =~ "response.completed"
      refute body =~ "termination_source"
      refute body =~ "Finch.TransportError"
    end
  end

  defp assert_failure_metadata(:completed, metadata), do: refute(Map.has_key?(metadata, "transport_failure"))

  defp assert_failure_metadata(ending, metadata) do
    assert failure = metadata["transport_failure"]
    assert failure["evidence_source"] == "observed"
    assert failure["termination_source"] == %{body_done: "http_body_done", transport_close: "http_transport_error", receive_timeout: "http_receive_timeout"}[ending]

    case ending do
      :body_done ->
        assert failure["reason"] == "done"

      :transport_close ->
        assert failure["reason"] == "closed"
        assert failure["exception"] == "Finch.TransportError"

      :receive_timeout ->
        assert failure["reason"] == "timeout"
    end
  end

  defp expected_error(:completed), do: nil
  defp expected_error(:receive_timeout), do: "stream_idle_timeout"
  defp expected_error(_ending), do: "upstream_stream_error"
  defp tool_event, do: "event: response.output_item.added\ndata: " <> CodexPooler.JSON.encode!(%{"type" => "response.output_item.added", "output_index" => 0, "item" => %{"type" => "function_call", "id" => "fc_synthetic", "call_id" => "call_synthetic", "name" => "sample_tool", "arguments" => "", "status" => "in_progress"}}) <> "\n\n"
  defp delta, do: "event: response.output_text.delta\ndata: {\"type\":\"response.output_text.delta\",\"delta\":\"visible-termination-sentinel\"}\n\n"
  defp completion, do: "event: response.completed\ndata: " <> CodexPooler.JSON.encode!(%{"type" => "response.completed", "response" => %{"id" => "resp_synthetic_completion", "status" => "completed", "output" => [], "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}}}) <> "\n\n"
end

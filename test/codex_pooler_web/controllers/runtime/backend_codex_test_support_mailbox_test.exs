defmodule CodexPoolerWeb.Runtime.BackendCodexTestSupportMailboxTest do
  @moduledoc """
  The public websocket receive helpers take only the messages Mint delivers for
  their own connection's socket. They used to take any message and drop what
  Mint called `:unknown`, which ate a fake upstream's ping notices and, in
  Drone 1513, the `:DOWN` of the Bandit connection a test monitored while it
  waited for the close frame (`handshake_test.exs`, fragmented message above
  the body cap). Each test puts a foreign message in the mailbox before the
  helper runs; the helper must leave it there.
  """

  use CodexPoolerWeb.ConnCase, async: false

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport

  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPoolerWeb.Runtime.BackendCodexWebsocketSupport

  @detection_timeout_ms 15_000

  test "the upgrade and text helpers leave the test's other messages in its mailbox" do
    completed = %{
      "type" => "response.completed",
      "response" => %{"id" => "resp_mailbox_helper", "usage" => %{"input_tokens" => 1, "output_tokens" => 1, "total_tokens" => 2}}
    }

    upstream = start_upstream(FakeUpstream.sse_stream([{"response.completed", completed}]))
    setup = gateway_setup(upstream)
    port = start_public_endpoint!()
    marker = make_ref()

    send(self(), {:foreign_before_upgrade, marker})
    {conn, websocket, ref} = public_websocket_connect!(port, setup, "mailbox-helper-#{System.unique_integer([:positive])}")

    try do
      payload =
        CodexPooler.JSON.encode!(%{
          "type" => "response.create",
          "model" => setup.model.exposed_model_id,
          "input" => native_text_input("mailbox helper"),
          "stream" => true,
          "generate" => true
        })

      send(self(), {:foreign_before_frame, marker})
      {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, payload)
      {_conn, _websocket, frame} = public_websocket_receive_text!(conn, websocket, ref)

      assert %{"type" => "response.completed"} = CodexPooler.JSON.decode!(frame)
      assert_received {:foreign_before_upgrade, ^marker}
      assert_received {:foreign_before_frame, ^marker}
    after
      Mint.HTTP.close(conn)
    end
  end

  test "the close helper leaves the monitored connection's DOWN in the mailbox" do
    previous = CodexPooler.TestAppEnv.restore_on_exit(OperationalSettings)

    Application.put_env(
      :codex_pooler,
      OperationalSettings,
      previous
      |> Keyword.put(:settings, %OperationalSettings{max_decompressed_body_bytes: 700, websocket_idle_timeout_ms: 60_000})
      |> Keyword.put(:use_instance_settings?, false)
    )

    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "unused_mailbox_helper"}))
    setup = gateway_setup(upstream)
    {server, port} = start_public_endpoint_with_server!()
    {conn, websocket, ref} = public_websocket_connect!(port, setup, "mailbox-close-#{System.unique_integer([:positive])}")

    try do
      assert {:ok, [connection_pid]} = ThousandIsland.connection_pids(server)
      monitor_ref = Process.monitor(connection_pid)
      marker = make_ref()

      {{_conn, _websocket, code, _reason}, _logs} =
        ExUnit.CaptureLog.with_log(fn ->
          send(self(), {:foreign_before_close, marker})
          {conn, websocket} = public_websocket_send_fragmented_text!(conn, websocket, ref, String.duplicate("x", 400), String.duplicate("x", 400))
          result = public_websocket_receive_close!(conn, websocket, ref)
          assert_receive {:DOWN, ^monitor_ref, :process, ^connection_pid, _reason}, @detection_timeout_ms
          result
        end)

      assert code == 1009
      assert_received {:foreign_before_close, ^marker}
    after
      Mint.HTTP.close(conn)
    end
  end

  test "server Pings receive matching wire Pongs while mixed text, binary and Close frames stay ordered" do
    payload = "mixed-control-payload"
    %{conn: conn, websocket: websocket, ref: ref, transport: transport, observer: observer} = control_socket!(payload)
    first = ~s({"type":"fixture.first"})
    last = ~s({"type":"fixture.last"})
    close = {:close, 1000, "fixture complete"}
    bytes = [server_frame(1, first), server_frame(9, payload), server_frame(2, "fixture binary"), server_frame(1, last), server_frame(8, <<1000::16, "fixture complete">>)]
    :ok = ThousandIsland.Socket.send(transport, bytes)
    {conn, websocket, frames} = receive_control_frames!(conn, websocket, ref, 5)
    assert {conn, websocket, [{:text, ^first}, {:binary, "fixture binary"}, {:text, ^last}, ^close]} = answer_server_pings!(conn, websocket, ref, frames)
    assert_receive {^observer, :matching_pong, true}, @detection_timeout_ms

    assert_raise ExUnit.AssertionError, ~r/\A\s*server Ping followed its Close frame\s*\z/, fn ->
      answer_server_pings!(conn, websocket, ref, [close, {:ping, payload}])
    end
  end

  test "the conn-aware decoder answers later data chunks and queues their additional text" do
    payload = "later-data-payload"
    %{conn: conn, websocket: websocket, ref: ref, observer: observer} = control_socket!(payload)
    first = ~s({"type":"fixture.first"})
    second = ~s({"type":"fixture.second"})
    responses = [{:data, ref, server_frame(1, first)}, {:data, ref, server_frame(9, payload) <> server_frame(1, second)}]
    assert {:ok, conn, websocket, ^first} = decode_public_websocket_text_with_control!(conn, websocket, ref, responses)
    assert_receive {^observer, :matching_pong, true}, @detection_timeout_ms
    assert {_conn, _websocket, ^second} = public_websocket_receive_text!(conn, websocket, ref)
  end

  for {kind, opcode, extra} <- [{:json, 1, ~s({"type":"fixture.unexpected"})}, {:binary, 2, "unexpected binary"}] do
    test "the strict transport barrier answers a server Ping but rejects extra #{kind}" do
      payload = "strict-barrier-payload"
      %{conn: conn, websocket: websocket, ref: ref, transport: transport, observer: observer} = control_socket!(payload)
      :ok = ThousandIsland.Socket.send(transport, [server_frame(9, payload), server_frame(unquote(opcode), unquote(extra))])

      assert_raise ExUnit.AssertionError, fn ->
        BackendCodexWebsocketSupport.socket_transport_barrier!(conn, websocket, ref)
      end

      assert_receive {^observer, :matching_pong, true}, @detection_timeout_ms
    end
  end

  defp control_socket!(payload) do
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "unused_control_contract"}))
    setup = gateway_setup(upstream)
    {server, port} = start_public_endpoint_with_server!()
    {conn, websocket, ref} = public_websocket_connect!(port, setup, "control-contract-#{System.unique_integer([:positive])}")
    on_exit(fn -> Mint.HTTP.close(conn) end)
    assert {:ok, [socket]} = ThousandIsland.connection_pids(server)
    {transport, _handler} = :sys.get_state(socket)
    observer = make_ref()
    :ok = :sys.install(socket, {&__MODULE__.observe_client_control/3, %{parent: self(), observer: observer, payload: payload, decoder: %Mint.WebSocket{}}})
    %{conn: conn, websocket: websocket, ref: ref, transport: transport, observer: observer}
  end

  @doc false
  @spec observe_client_control(map(), term(), term()) :: map()
  def observe_client_control(config, {:in, {tag, _socket, data}}, _name) when tag in [:tcp, :ssl] do
    {:ok, decoder, frames} = Mint.WebSocket.decode(config.decoder, data)

    for {:pong, payload} <- frames do
      send(config.parent, {config.observer, :matching_pong, payload == config.payload})
    end

    %{config | decoder: decoder}
  end

  def observe_client_control(config, _event, _name), do: config

  defp receive_control_frames!(conn, websocket, ref, count, frames \\ []) do
    message = receive_mint_socket_message!(conn, @detection_timeout_ms, "control contract received no frame")
    {:ok, conn, responses} = Mint.WebSocket.stream(conn, message)

    {websocket, frames} =
      Enum.reduce(responses, {websocket, frames}, fn
        {:data, ^ref, data}, {websocket, frames} ->
          {:ok, websocket, decoded} = Mint.WebSocket.decode(websocket, data)
          {websocket, frames ++ decoded}

        _response, acc ->
          acc
      end)

    if length(frames) >= count, do: {conn, websocket, frames}, else: receive_control_frames!(conn, websocket, ref, count, frames)
  end

  defp server_frame(opcode, payload) when byte_size(payload) < 126,
    do: <<1::1, 0::3, opcode::4, 0::1, byte_size(payload)::7, payload::binary>>
end

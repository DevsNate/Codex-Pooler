defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocketAPIKeyRevocationTest do
  use ExUnit.Case, async: false
  use CodexPooler.CommittedWriteGuard

  import Ecto.Query
  import ExUnit.Assertions
  import ExUnit.Callbacks
  import Phoenix.ConnTest
  import Plug.Conn
  import CodexPooler.PoolerFixtures, only: [active_api_key_fixture: 2, pool_fixture: 1]
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport

  alias CodexPooler.Access
  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.Accounts.{Scope, User}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Persistence.CodexSession
  alias CodexPooler.Repo
  alias Ecto.Adapters.SQL.Sandbox

  @endpoint CodexPoolerWeb.Endpoint
  @api_key_close_frame {:close, 1008, "api key is no longer active"}
  @detection_timeout_ms 15_000
  @transport_barrier_payload "api-key-revocation-barrier"
  @backend_websocket_routes [
    {:backend_responses, "/backend-api/codex/responses"},
    {:backend_v1_responses, "/backend-api/codex/v1/responses"}
  ]

  setup do
    assert :ok = Sandbox.mode(Repo, :auto)
    on_exit(fn -> assert :ok = Sandbox.mode(Repo, :manual) end)
  end

  for {route_label, path} <- @backend_websocket_routes do
    test "#{path} rejects a newly paused HTTP request and websocket upgrade without side effects" do
      route_label = unquote(route_label)
      path = unquote(path)
      upstream = start_upstream(FakeUpstream.json_response(%{"data" => []}))
      setup = gateway_setup(upstream)
      register_committed_setup_cleanup!(setup)

      assert {:ok, paused_key} = pause_from_task!(setup)
      assert paused_key.status == "paused"
      expected_error = paused_error()

      payload = response_payload(setup, "initial-denial-#{route_label}")

      conn =
        build_conn()
        |> auth(setup)
        |> put_req_header("content-type", "application/json")
        |> post(path, payload)

      assert ^expected_error = json_response(conn, 401)

      {mint_conn, 401, websocket_body} =
        websocket_upgrade_response!(start_public_endpoint!(), setup, path)

      try do
        assert ^expected_error = CodexPooler.JSON.decode!(websocket_body)
      after
        Mint.HTTP.close(mint_conn)
      end

      assert FakeUpstream.count(upstream) == 0
      assert request_count(setup) == 0
      assert attempt_count(setup) == 0
      assert session_count(setup) == 0
    end

    test "#{path} closes an idle pre-pause websocket once without dispatching work" do
      route_label = unquote(route_label)
      path = unquote(path)
      upstream = start_upstream(FakeUpstream.json_response(%{"data" => []}))
      setup = gateway_setup(upstream)
      register_committed_setup_cleanup!(setup)
      port = start_public_endpoint!()

      {conn, websocket, ref} =
        public_websocket_connect!(port, setup, "idle-pause-#{route_label}", path)

      try do
        {conn, websocket} = websocket_transport_barrier!(conn, websocket, ref)
        assert {:ok, paused_key} = pause_from_task!(setup)
        assert paused_key.runtime_revocation_epoch == 1

        {_conn, _websocket, frames} =
          receive_websocket_frames_until_close!(conn, websocket, ref)

        assert frames == [@api_key_close_frame]
        assert FakeUpstream.count(upstream) == 0
        assert request_count(setup) == 0
        assert attempt_count(setup) == 0
        assert session_count(setup) == 1
      after
        Mint.HTTP.close(conn)
      end
    end

    # Rotation keeps the key active and only advances its runtime epoch, so the
    # `api_key_rotated` event carries no disabling status the socket could
    # latch on. The idle old-secret socket must still close from that event
    # alone, without a client frame, while a sibling key on the same Pool and a
    # fresh upgrade with the rotated secret keep working (findings#204).
    test "#{path} closes an idle websocket on rotation, keeps a sibling key open, and admits the rotated secret" do
      route_label = unquote(route_label)
      path = unquote(path)
      upstream = start_upstream(FakeUpstream.json_response(%{"data" => []}))
      setup = gateway_setup(upstream)
      register_committed_setup_cleanup!(setup)
      sibling = sibling_key_setup(setup)
      port = start_public_endpoint!()

      {conn, websocket, ref} =
        public_websocket_connect!(port, setup, "idle-rotate-#{route_label}", path)

      {sibling_conn, sibling_websocket, sibling_ref} =
        public_websocket_connect!(port, sibling, "idle-rotate-sibling-#{route_label}", path)

      try do
        {conn, websocket} = websocket_transport_barrier!(conn, websocket, ref)

        {sibling_conn, sibling_websocket} =
          websocket_transport_barrier!(sibling_conn, sibling_websocket, sibling_ref)

        epoch_before = setup.api_key.runtime_revocation_epoch

        assert {:ok, %{api_key: rotated_key, raw_key: rotated_secret}} =
                 rotate_from_task!(setup)

        assert rotated_key.status == "active"
        assert rotated_key.runtime_revocation_epoch == epoch_before + 1

        assert Repo.get!(CodexPooler.Access.APIKey, setup.api_key.id).runtime_revocation_epoch ==
                 epoch_before + 1

        # No client frame is sent on the old-secret socket: the rotation event
        # alone must prompt the reread that closes it.
        {_conn, _websocket, frames} =
          receive_websocket_frames_until_close!(conn, websocket, ref)

        assert frames == [@api_key_close_frame]

        # The sibling socket received the same Pool event before this ping and
        # answers it with a pong and nothing else, so it was not revoked.
        {_sibling_conn, _sibling_websocket} =
          websocket_transport_barrier!(sibling_conn, sibling_websocket, sibling_ref)

        {old_conn, 401, _body} = websocket_upgrade_response!(port, setup, path)
        Mint.HTTP.close(old_conn)

        rotated_setup = %{setup | authorization: "Bearer #{rotated_secret}"}

        {fresh_conn, fresh_websocket, fresh_ref} =
          public_websocket_connect!(port, rotated_setup, "fresh-rotated-#{route_label}", path)

        {fresh_conn, _fresh_websocket} =
          websocket_transport_barrier!(fresh_conn, fresh_websocket, fresh_ref)

        Mint.HTTP.close(fresh_conn)

        assert FakeUpstream.count(upstream) == 0
        assert request_count(setup) == 0
        assert attempt_count(setup) == 0
        assert session_count(setup) == 3
      after
        Mint.HTTP.close(conn)
        Mint.HTTP.close(sibling_conn)
      end
    end

    # A Pool move advances the runtime epoch and its `api_key_updated` event
    # reaches both Pools, so the socket authorized under the previous Pool
    # closes on the move itself, delivered here over the same-node local
    # PubSub (the peer relay path is covered by the lifecycle revocation
    # file). The socket gate compares the event's topic Pool with the Pool it
    # captured at init, not the payload's `pool_id` (which is the new Pool on
    # both broadcasts); this test is what would catch that gate moving to the
    # payload. The key itself stays usable on its new Pool (findings#204).
    test "#{path} closes an idle websocket when its key moves to another Pool, before any pause" do
      route_label = unquote(route_label)
      path = unquote(path)
      upstream = start_upstream(FakeUpstream.json_response(%{"data" => []}))
      setup = gateway_setup(upstream)
      register_committed_setup_cleanup!(setup)
      target_pool = move_target_pool!()
      port = start_public_endpoint!()

      {conn, websocket, ref} =
        public_websocket_connect!(port, setup, "idle-move-#{route_label}", path)

      try do
        {conn, websocket} = websocket_transport_barrier!(conn, websocket, ref)
        epoch_before = setup.api_key.runtime_revocation_epoch

        assert {:ok, moved_key} = move_from_task!(setup, target_pool)
        assert moved_key.pool_id == target_pool.id
        assert moved_key.status == "active"

        # No client frame is sent: the move event alone prompts the reread that
        # refuses the stale epoch and closes the socket.
        {_conn, _websocket, frames} =
          receive_websocket_frames_until_close!(conn, websocket, ref)

        assert frames == [@api_key_close_frame]
        assert moved_key.runtime_revocation_epoch == epoch_before + 1

        # The move revoked the captured epoch, not the key: the same secret
        # still upgrades, now under the target Pool.
        {moved_conn, 101, _headers} = websocket_upgrade_response!(port, setup, path)
        Mint.HTTP.close(moved_conn)

        # A pause after the move has nothing left to close under the previous
        # Pool; the 401 below is the pause's own durable refusal.
        assert {:ok, _paused} = pause_from_task!(setup)
        {old_conn, 401, _body} = websocket_upgrade_response!(port, setup, path)
        Mint.HTTP.close(old_conn)

        assert FakeUpstream.count(upstream) == 0
        assert request_count(setup) == 0
        assert attempt_count(setup) == 0
        assert session_count(setup) == 1
      after
        Mint.HTTP.close(conn)
      end
    end

    @tag :replay_race
    @tag slow: "coordinates an admitted real websocket turn, queued-frame revocation, and terminal close through socket barriers"
    test "#{path} drains one admitted turn then drops queued and later frames after pause" do
      route_label = unquote(route_label)
      path = unquote(path)
      release_ref = make_ref()

      upstream =
        start_upstream(
          FakeUpstream.barrier_sse_stream(
            [
              {"response.completed",
               %{
                 "type" => "response.completed",
                 "response" => %{
                   "id" => "resp_api_key_revocation_#{route_label}",
                   "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
                 }
               }}
            ],
            barrier_after: 0,
            notify: self(),
            release_ref: release_ref
          )
        )

      setup = gateway_setup(upstream)
      register_committed_setup_cleanup!(setup)
      {server, port} = start_public_endpoint_with_server!()

      {conn, websocket, ref} =
        public_websocket_connect!(port, setup, "busy-pause-#{route_label}", path)

      try do
        first_payload =
          CodexPooler.JSON.encode!(response_payload(setup, "admitted-#{route_label}"))

        {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, first_payload)
        assert_receive {:fake_upstream_chunk_barrier, 0, upstream_pid, ^release_ref}, 5_000

        queued_payload =
          CodexPooler.JSON.encode!(%{
            "type" => "response.create",
            "model" => setup.model.exposed_model_id,
            "input" => [
              %{
                "type" => "function_call_output",
                "call_id" => "call_api_key_revocation_#{route_label}",
                "output" => "queued"
              }
            ],
            "stream" => true,
            "generate" => true,
            "previous_response_id" => "resp_api_key_revocation_#{route_label}"
          })

        {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, queued_payload)
        {conn, websocket} = websocket_transport_barrier!(conn, websocket, ref)
        assert_socket_queue_length!(server, 1)

        assert {:ok, paused_key} = pause_from_task!(setup)
        assert paused_key.runtime_revocation_epoch == 1
        assert_socket_api_key_revoked!(server)
        assert_socket_queue_length!(server, 0)

        later_payload = CodexPooler.JSON.encode!(response_payload(setup, "later-#{route_label}"))
        {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, later_payload)
        {conn, websocket} = websocket_transport_barrier!(conn, websocket, ref)
        assert_socket_queue_length!(server, 0)
        assert FakeUpstream.count(upstream) == 1

        send(upstream_pid, {:fake_upstream_release_chunk, release_ref})

        {_conn, _websocket, frames} =
          receive_websocket_frames_until_close!(conn, websocket, ref)

        assert [{:text, final_frame}, @api_key_close_frame] = frames
        assert %{"type" => "response.completed"} = CodexPooler.JSON.decode!(final_frame)
        assert FakeUpstream.count(upstream) == 1

        assert [%Request{status: "succeeded"} = request] =
                 Repo.all(from(request in Request, where: request.pool_id == ^setup.pool.id))

        assert [%Attempt{status: "succeeded", request_id: request_id}] =
                 Repo.all(from(attempt in Attempt, where: attempt.request_id == ^request.id))

        assert request_id == request.id
        assert session_count(setup) == 1
      after
        Mint.HTTP.close(conn)
      end
    end
  end

  defp response_payload(setup, marker) do
    %{
      "type" => "response.create",
      "model" => setup.model.exposed_model_id,
      "input" => native_text_input(marker),
      "stream" => true,
      "generate" => true
    }
  end

  defp paused_error do
    %{
      "error" => %{
        "code" => "api_key_paused",
        "message" => "api key is paused",
        "param" => nil,
        "type" => "invalid_request_error"
      }
    }
  end

  defp pause_from_task!(setup) do
    scope = owner_scope!(setup)

    fn -> Access.pause_api_key(scope, setup.api_key.id) end
    |> Task.async()
    |> Task.await(@detection_timeout_ms)
  end

  defp move_from_task!(setup, target_pool) do
    scope = owner_scope!(setup)

    fn -> Access.update_api_key(scope, setup.api_key.id, %{pool_id: target_pool.id}) end
    |> Task.async()
    |> Task.await(@detection_timeout_ms)
  end

  # A committed Pool the key can be moved to. The fixture cleanup is scoped to
  # `setup.pool`, so the moved key, its owner and the audit events written
  # under the target Pool are removed here, before that cleanup runs (ExUnit
  # runs `on_exit` callbacks last-registered first). The slug is chosen up
  # front so the cleanup is registered before the committed insert. Deleting
  # the owner graph this early is safe only because fixture Pools record no
  # creator, so the graph delete cannot cascade into `setup.pool`'s
  # assignments; and the narrow delete set is enough only because no traffic
  # is served under the target Pool (ledger and rollup rows would need the
  # full `cleanup_unboxed_pool!/1` set).
  defp move_target_pool! do
    slug = "move-target-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      case Repo.get_by(CodexPooler.Pools.Pool, slug: slug) do
        nil ->
          :ok

        pool ->
          owner_ids = CodexPooler.PoolerFixtures.api_key_creator_ids([pool.id])

          Repo.delete_all(
            from(binding in Access.APIKeyPolicyBinding,
              where: binding.api_key_id in subquery(from(key in Access.APIKey, where: key.pool_id == ^pool.id, select: key.id))
            )
          )

          Repo.delete_all(from(key in Access.APIKey, where: key.pool_id == ^pool.id))
          CodexPooler.PoolerFixtures.delete_committed_pools!([pool.id], owner_ids)
      end
    end)

    pool_fixture(%{slug: slug})
  end

  defp rotate_from_task!(setup) do
    scope = owner_scope!(setup)

    fn -> Access.rotate_api_key(scope, setup.api_key.id) end
    |> Task.async()
    |> Task.await(@detection_timeout_ms)
  end

  # A second active key on the same Pool and owner, so the Pool cleanup removes
  # it with the fixture; only the credential fields differ from `setup`.
  defp sibling_key_setup(setup) do
    Map.merge(
      setup,
      active_api_key_fixture(setup.pool, %{created_by_user_id: setup.api_key.created_by_user_id})
    )
  end

  defp owner_scope!(setup) do
    setup.api_key.created_by_user_id
    |> then(&Repo.get!(User, &1))
    |> Scope.for_user(["instance_owner"])
  end

  defp register_committed_setup_cleanup!(setup) do
    on_exit(fn -> cleanup_unboxed_pool!(setup) end)
  end

  defp request_count(setup) do
    Repo.aggregate(from(request in Request, where: request.pool_id == ^setup.pool.id), :count)
  end

  defp attempt_count(setup) do
    Repo.aggregate(
      from(attempt in Attempt,
        join: request in Request,
        on: request.id == attempt.request_id,
        where: request.pool_id == ^setup.pool.id
      ),
      :count
    )
  end

  defp session_count(setup) do
    Repo.aggregate(
      from(session in CodexSession, where: session.pool_id == ^setup.pool.id),
      :count
    )
  end

  defp websocket_upgrade_response!(port, setup, path) do
    {:ok, conn} = Mint.HTTP.connect(:http, "127.0.0.1", port, protocols: [:http1])

    {:ok, conn, ref} =
      Mint.WebSocket.upgrade(:ws, conn, path, [
        {"authorization", setup.authorization},
        {"x-codex-turn-state", "initial-paused-upgrade"}
      ])

    await_websocket_upgrade_response!(
      conn,
      ref,
      nil,
      [],
      System.monotonic_time(:millisecond) + @detection_timeout_ms
    )
  end

  defp await_websocket_upgrade_response!(conn, ref, status, body, deadline) do
    timeout = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      message ->
        case Mint.WebSocket.stream(conn, message) do
          :unknown ->
            await_websocket_upgrade_response!(conn, ref, status, body, deadline)

          {:ok, conn, responses} ->
            {status, body, done?} =
              Enum.reduce(responses, {status, body, false}, fn
                {:status, ^ref, response_status}, {_status, body, done?} ->
                  {response_status, body, done?}

                {:data, ^ref, data}, {status, body, done?} ->
                  {status, [body, data], done?}

                {:done, ^ref}, {status, body, _done?} ->
                  {status, body, true}

                _response, acc ->
                  acc
              end)

            if done? do
              {conn, status, IO.iodata_to_binary(body)}
            else
              await_websocket_upgrade_response!(conn, ref, status, body, deadline)
            end

          {:error, conn, reason, _responses} ->
            Mint.HTTP.close(conn)
            flunk("websocket upgrade response failed: #{inspect(reason)}")
        end
    after
      timeout -> flunk("timed out waiting for websocket upgrade response")
    end
  end

  defp assert_socket_queue_length!(server, expected_length) do
    state = websocket_state!(server)
    assert :queue.len(state.queued_response_payloads) == expected_length
  end

  defp assert_socket_api_key_revoked!(server) do
    await_socket_state!(
      server,
      &Map.get(&1, :api_key_revoked?, false),
      System.monotonic_time(:millisecond) + @detection_timeout_ms
    )
  end

  defp await_socket_state!(server, predicate, deadline) do
    state = websocket_state!(server)

    cond do
      predicate.(state) ->
        state

      System.monotonic_time(:millisecond) < deadline ->
        receive do
        after
          10 -> await_socket_state!(server, predicate, deadline)
        end

      true ->
        flunk("websocket state did not reach the expected condition")
    end
  end

  defp websocket_state!(server) do
    assert {:ok, [connection_pid]} = ThousandIsland.connection_pids(server)
    {_socket, handler_state} = :sys.get_state(connection_pid)
    handler_state.connection.websock_state
  end

  defp websocket_transport_barrier!(conn, websocket, ref) do
    {:ok, websocket, data} =
      Mint.WebSocket.encode(websocket, {:ping, @transport_barrier_payload})

    {:ok, conn} = Mint.WebSocket.stream_request_body(conn, ref, data)

    await_transport_barrier!(
      conn,
      websocket,
      ref,
      System.monotonic_time(:millisecond) + @detection_timeout_ms
    )
  end

  defp await_transport_barrier!(conn, websocket, ref, deadline) do
    timeout = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      message ->
        case Mint.WebSocket.stream(conn, message) do
          :unknown ->
            await_transport_barrier!(conn, websocket, ref, deadline)

          {:ok, conn, responses} ->
            {conn, websocket, pong?} = decode_transport_barrier!(conn, websocket, ref, responses)

            if pong?,
              do: {conn, websocket},
              else: await_transport_barrier!(conn, websocket, ref, deadline)
        end
    after
      timeout -> flunk("timed out waiting for websocket transport barrier")
    end
  end

  defp decode_transport_barrier!(conn, websocket, ref, responses) do
    Enum.reduce(responses, {conn, websocket, false}, fn
      {:data, ^ref, data}, {conn, websocket, pong?} ->
        assert {:ok, websocket, frames} = Mint.WebSocket.decode(websocket, data)
        {conn, websocket, frames} = answer_server_pings!(conn, websocket, ref, frames)

        unexpected_frames =
          Enum.reject(frames, fn
            {:pong, @transport_barrier_payload} -> true
            frame -> metadata_control_frame?(frame)
          end)

        assert unexpected_frames == []
        {conn, websocket, pong? or {:pong, @transport_barrier_payload} in frames}

      _response, acc ->
        acc
    end)
  end

  defp receive_websocket_frames_until_close!(conn, websocket, ref, frames \\ []) do
    receive do
      message ->
        case Mint.WebSocket.stream(conn, message) do
          :unknown ->
            receive_websocket_frames_until_close!(conn, websocket, ref, frames)

          {:ok, conn, responses} ->
            {conn, websocket, frames, closed?} =
              Enum.reduce(responses, {conn, websocket, frames, false}, fn
                {:data, ^ref, data}, {conn, websocket, frames, closed?} ->
                  assert {:ok, websocket, decoded} = Mint.WebSocket.decode(websocket, data)
                  {conn, websocket, decoded} = answer_server_pings!(conn, websocket, ref, decoded)
                  decoded = Enum.reject(decoded, &metadata_control_frame?/1)

                  {conn, websocket, frames ++ decoded, closed? or Enum.any?(decoded, &match?({:close, _, _}, &1))}

                _response, acc ->
                  acc
              end)

            if closed?,
              do: {conn, websocket, frames},
              else: receive_websocket_frames_until_close!(conn, websocket, ref, frames)

          {:error, conn, reason, _responses} ->
            Mint.HTTP.close(conn)
            flunk("websocket frame receive failed: #{inspect(reason)}")
        end
    after
      @detection_timeout_ms -> flunk("timed out waiting for websocket close")
    end
  end

  defp metadata_control_frame?({:text, frame}) when is_binary(frame),
    do: metadata_control_frame?(frame)

  defp metadata_control_frame?(frame) when is_binary(frame) do
    match?({:ok, %{"type" => "codex.response.metadata"}}, CodexPooler.JSON.decode(frame))
  end

  defp metadata_control_frame?(_frame), do: false
end

defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocketAPIKeyRevocationDistributedTest do
  use ExUnit.Case, async: false
  use CodexPooler.CommittedWriteGuard

  import ExUnit.Assertions
  import ExUnit.Callbacks
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport

  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.Accounts.{Scope, User}
  alias CodexPooler.Events.PostgresBridge
  alias CodexPooler.FakeUpstream
  alias CodexPooler.PeerRegistry
  alias CodexPooler.Repo
  alias Ecto.Adapters.SQL.Sandbox

  @api_key_close {1008, "api key is no longer active"}
  @detection_timeout_ms 15_000
  @backend_websocket_routes [
    {:backend_responses, "/backend-api/codex/responses"},
    {:backend_v1_responses, "/backend-api/codex/v1/responses"}
  ]

  setup do
    assert :ok = Sandbox.mode(Repo, :auto)
    on_exit(fn -> assert :ok = Sandbox.mode(Repo, :manual) end)
  end

  for {route_label, path} <- @backend_websocket_routes do
    @tag :distributed
    @tag slow: "boots a real peer and observes API-key pause through the PostgreSQL relay on an open socket"
    test "#{path} receives a prompt pause through the peer PostgreSQL relay" do
      route_label = unquote(route_label)
      path = unquote(path)
      upstream = start_upstream(FakeUpstream.json_response(%{"data" => []}))
      setup = gateway_setup(upstream)
      register_committed_setup_cleanup!(setup)
      peer = start_api_key_pause_peer!()
      register_peer_cleanup!(peer)
      {server, port} = start_public_endpoint_with_server!()

      {conn, websocket, ref} =
        public_websocket_connect!(port, setup, "peer-pause-#{route_label}", path)

      try do
        assert_socket_ready!(server, setup.api_key.id)
        assert {:ok, paused_key} = pause_from_peer!(peer, setup)
        assert paused_key.runtime_revocation_epoch == 1

        {_conn, _websocket, code, reason} =
          public_websocket_receive_close!(conn, websocket, ref)

        assert {code, reason} == @api_key_close
        assert FakeUpstream.count(upstream) == 0
        assert Repo.aggregate(Request, :count, :id) == 0
        assert Repo.aggregate(Attempt, :count, :id) == 0
      after
        Mint.HTTP.close(conn)
      end
    end

    @tag :distributed
    @tag slow: "boots a real peer, delays relay delivery and verifies the durable key fence rejects the next frame"
    test "#{path} rejects the next frame from the durable fence while relay delivery is delayed" do
      route_label = unquote(route_label)
      path = unquote(path)
      upstream = start_upstream(FakeUpstream.json_response(%{"data" => []}))
      setup = gateway_setup(upstream)
      register_committed_setup_cleanup!(setup)
      peer = start_api_key_pause_peer!()
      register_peer_cleanup!(peer)
      {server, port} = start_public_endpoint_with_server!()

      {conn, websocket, ref} =
        public_websocket_connect!(port, setup, "durable-fence-#{route_label}", path)

      :sys.suspend(PostgresBridge)
      on_exit(fn -> resume_if_suspended(PostgresBridge) end)

      try do
        assert_socket_ready!(server, setup.api_key.id)
        assert {:ok, paused_key} = pause_from_peer!(peer, setup)
        assert paused_key.runtime_revocation_epoch == 1

        payload =
          CodexPooler.JSON.encode!(%{
            "type" => "response.create",
            "model" => setup.model.exposed_model_id,
            "input" => native_text_input("durable-fence-#{route_label}"),
            "stream" => true,
            "generate" => true
          })

        {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, payload)

        {_conn, _websocket, code, reason} =
          public_websocket_receive_close!(conn, websocket, ref)

        assert {code, reason} == @api_key_close
        assert FakeUpstream.count(upstream) == 0
        assert Repo.aggregate(Request, :count, :id) == 0
        assert Repo.aggregate(Attempt, :count, :id) == 0

        :sys.resume(PostgresBridge)

        assert %{listen_ref: listen_ref} = :sys.get_state(PostgresBridge)
        assert is_reference(listen_ref)
      after
        resume_if_suspended(PostgresBridge)
        Mint.HTTP.close(conn)
      end
    end
  end

  defp pause_from_peer!(peer, setup) do
    :erpc.call(
      peer.node,
      CodexPoolerWeb.Runtime.BackendCodexWebsocketAPIKeyPausePeer,
      :pause,
      [owner_scope!(setup), setup.api_key.id],
      @detection_timeout_ms
    )
  end

  defp owner_scope!(setup) do
    setup.api_key.created_by_user_id
    |> then(&Repo.get!(User, &1))
    |> Scope.for_user(["instance_owner"])
  end

  defp register_committed_setup_cleanup!(setup) do
    on_exit(fn -> cleanup_unboxed_pool!(setup) end)
  end

  defp start_api_key_pause_peer! do
    distribution = ensure_test_distribution_started!()

    try do
      peer_name = String.to_atom("api_key_pause_peer_#{System.unique_integer([:positive])}")

      assert {:ok, peer_pid, peer_node} =
               :peer.start_link(%{
                 name: peer_name,
                 args: [~c"-kernel", ~c"prevent_overlapping_partitions", ~c"false"]
               })

      peer = %{distribution: distribution, node: peer_node, pid: peer_pid}

      try do
        Process.unlink(peer_pid)
        assert :ok = :erpc.call(peer_node, :code, :add_paths, [:code.get_path()])

        assert {:ok, _applications} =
                 :erpc.call(peer_node, Application, :ensure_all_started, [:elixir])

        assert [{CodexPoolerWeb.Runtime.BackendCodexWebsocketAPIKeyPausePeer, _beam}] =
                 :erpc.call(peer_node, Code, :compile_string, [peer_source()])

        repo_config =
          :codex_pooler
          |> Application.fetch_env!(Repo)
          |> Keyword.merge(pool: DBConnection.ConnectionPool, pool_size: 2)

        repo_pid =
          :erpc.call(
            peer_node,
            CodexPoolerWeb.Runtime.BackendCodexWebsocketAPIKeyPausePeer,
            :start,
            [repo_config],
            @detection_timeout_ms
          )

        assert is_pid(repo_pid)
        assert node(repo_pid) == peer_node
        peer
      catch
        kind, reason ->
          stop_api_key_pause_peer!(peer)
          :erlang.raise(kind, reason, __STACKTRACE__)
      end
    catch
      kind, reason ->
        stop_test_distribution!(distribution)
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  defp register_peer_cleanup!(peer) do
    on_exit(fn -> stop_api_key_pause_peer!(peer) end)
  end

  defp stop_api_key_pause_peer!(peer) do
    if Process.alive?(peer.pid) do
      monitor = Process.monitor(peer.pid)
      :peer.stop(peer.pid)
      assert_receive {:DOWN, ^monitor, :process, _, _}, @detection_timeout_ms
    end

    refute peer.node in Node.list(:connected)

    stop_test_distribution!(peer.distribution)
  end

  defp assert_socket_ready!(server, api_key_id) do
    await_socket_state!(
      server,
      &(Map.get(&1, :api_key_id) == api_key_id),
      System.monotonic_time(:millisecond) + @detection_timeout_ms
    )
  end

  defp await_socket_state!(server, predicate, deadline) do
    assert {:ok, [connection_pid]} = ThousandIsland.connection_pids(server)
    {_socket, handler_state} = :sys.get_state(connection_pid)
    state = handler_state.connection.websock_state

    cond do
      predicate.(state) ->
        state

      System.monotonic_time(:millisecond) < deadline ->
        receive do
        after
          10 -> await_socket_state!(server, predicate, deadline)
        end

      true ->
        flunk("websocket state did not become ready")
    end
  end

  defp ensure_test_distribution_started! do
    case Node.alive?() do
      true ->
        %{node_started?: false, previous_partition_guard: :unchanged}

      false ->
        ensure_epmd_started!()
        previous_partition_guard = Application.fetch_env(:kernel, :prevent_overlapping_partitions)
        # Also on_exit: the ExUnit timeout kills the test before its peer cleanup is registered.
        on_exit(fn -> restore_partition_guard(previous_partition_guard) end)
        Application.put_env(:kernel, :prevent_overlapping_partitions, false)

        node_name =
          String.to_atom("api_key_revocation_test_#{System.unique_integer([:positive])}")

        assert {:ok, _pid} = :net_kernel.start([node_name, :shortnames])

        %{node_started?: true, previous_partition_guard: previous_partition_guard}
    end
  end

  defp ensure_epmd_started! do
    case :erl_epmd.names() do
      {:ok, _names} ->
        :ok

      {:error, _reason} ->
        assert {_output, 0} = System.cmd("epmd", ["-daemon"])
        PeerRegistry.assert_epmd_ready!()
    end
  end

  defp restore_partition_guard({:ok, value}) do
    Application.put_env(:kernel, :prevent_overlapping_partitions, value)
  end

  defp restore_partition_guard(:error) do
    Application.delete_env(:kernel, :prevent_overlapping_partitions)
  end

  defp restore_partition_guard(:unchanged), do: :ok

  defp stop_test_distribution!(distribution) do
    if distribution.node_started? and Node.alive?() do
      assert :ok = :net_kernel.stop()
    end

    restore_partition_guard(distribution.previous_partition_guard)
  end

  defp resume_if_suspended(process) do
    case Process.whereis(process) do
      pid when is_pid(pid) ->
        try do
          :sys.resume(process)
        catch
          :exit, _reason -> :ok
        end

      nil ->
        :ok
    end
  end

  defp peer_source do
    """
    defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocketAPIKeyPausePeer do
      def start(repo_config) do
        Application.put_env(:codex_pooler, CodexPooler.Repo, repo_config)
        {:ok, _applications} = Application.ensure_all_started(:ecto_sql)
        {:ok, repo_pid} = CodexPooler.Repo.start_link()
        Process.unlink(repo_pid)
        repo_pid
      end

      def pause(scope, api_key_id) do
        CodexPooler.Repo.transact(fn ->
          CodexPooler.Access.pause_api_key(scope, api_key_id)
        end)
      end
    end
    """
  end
end

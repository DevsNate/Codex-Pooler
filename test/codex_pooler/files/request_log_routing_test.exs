defmodule CodexPooler.Files.RequestLogRoutingTest do
  use CodexPooler.DataCase, async: true

  import CodexPooler.PoolerFixtures

  alias CodexPooler.Accounting.Request
  alias CodexPooler.Files
  alias CodexPooler.Files.{FileRecord, RequestLog, RequestMetadata}

  for operation <- [:create, :finalize] do
    test "#{operation} failures retain safe bridge routing with the trusted route class" do
      auth = active_api_key_fixture()
      selected = upstream_assignment_fixture(auth.pool)
      now = DateTime.utc_now()

      routing = %{
        "selected_bridge_candidate_id" => selected.assignment.id,
        "strategy" => "bridge_ring",
        "route_class" => "proxy_http",
        :route_class => "proxy_control",
        "access_token" => "synthetic-private-token",
        "upload_url" => "https://example.com/upload?signature=synthetic-private-signature",
        "body" => "synthetic-private-body"
      }

      exclusions = [%{"pool_upstream_assignment_id" => Ecto.UUID.generate(), "reason" => "inactive"}]
      error = %{status: 503, code: :upstream_credential_unavailable, message: "upstream credentials are unavailable", param: nil, upstream: %{"routing" => routing, "candidate_exclusions" => exclusions, "body" => "synthetic-unrelated-body"}}
      endpoint = if unquote(operation) == :create, do: "/backend-api/files", else: "/backend-api/files/uploaded"
      opts = %{request_metadata(now) | endpoint: endpoint}

      case unquote(operation) do
        :create ->
          assert {:error, %{status: 503}} = Files.record_create_bridge_failure(auth, error, opts)
          assert Repo.aggregate(FileRecord, :count) == 0

        :finalize ->
          file = pending_file(auth, selected.assignment, now)
          assert {:error, %{status: 503}} = Files.record_finalize_result(auth, file.file_id, opts, {:error, error})
          assert Repo.reload!(file).status == "abandoned"
          assert Repo.reload!(file).finalize_status == "failed"
      end

      request = Repo.get_by!(Request, api_key_id: auth.api_key.id)
      assert request.endpoint == endpoint
      assert request.status == "failed"
      assert request.response_status_code == 503
      assert request.request_metadata["error_code"] == "upstream_credential_unavailable"
      assert request.request_metadata["routing"]["selected_bridge_candidate_id"] == selected.assignment.id
      assert request.request_metadata["routing"]["strategy"] == "bridge_ring"
      assert request.request_metadata["routing"]["route_class"] == "file_upload"
      assert request.request_metadata["candidate_exclusions"] == exclusions
      assert request.request_metadata["client_request_id"] == "sample-client"
      assert request.request_metadata["request"] == %{"request_bytes" => 12, "upload_bytes" => 8, "request_content_type" => "application/json"}

      for secret <- ["synthetic-private-token", "synthetic-private-signature", "synthetic-private-body", "synthetic-unrelated-body", "synthetic-idempotency-key"] do
        refute inspect(request.request_metadata) =~ secret
      end
    end
  end

  test "malformed routing is ignored while trusted request metadata survives" do
    auth = active_api_key_fixture()
    opts = request_metadata(DateTime.utc_now())

    for routing <- [nil, "synthetic-private-routing", 12, false, [], [{"route_class", "proxy_http"}]] do
      assert {:ok, request} = RequestLog.record_file_request(auth, "failed", 503, opts, %{"routing" => routing, "operation" => "create"})
      metadata = Repo.reload!(request).request_metadata
      assert metadata["routing"] == %{"route_class" => "file_upload"}
      assert metadata["operation"] == "create"
      assert metadata["client_request_id"] == "sample-client"
      refute inspect(metadata) =~ "synthetic-private-routing"
    end
  end

  test "successful finalize still merges its sanitized bridge routing" do
    auth = active_api_key_fixture()
    selected = upstream_assignment_fixture(auth.pool)
    now = DateTime.utc_now()
    file = pending_file(auth, selected.assignment, now)
    result = %{body: %{"status" => "success", "download_url" => "https://example.com/file"}, route_metadata: %{"routing" => %{"route_class" => "file_upload", "selected_bridge_candidate_id" => selected.assignment.id}}}

    assert {:ok, %{request: request, file: completed}} = Files.record_finalize_result(auth, file.file_id, request_metadata(now), {:ok, result})
    request = Repo.reload!(request)
    assert request.status == "succeeded"
    assert request.response_status_code == 200
    assert request.request_metadata["routing"]["route_class"] == "file_upload"
    assert request.request_metadata["routing"]["selected_bridge_candidate_id"] == selected.assignment.id
    assert request.request_metadata["client_request_id"] == "sample-client"
    assert completed.status == "uploaded"
  end

  defp request_metadata(now) do
    RequestMetadata.build(%{now: now, transport: "http_json", route_class: "file_upload", client_request_id: " sample-client ", request_bytes: 12, upload_bytes: 8, request_content_type: "application/json", idempotency_key: "synthetic-idempotency-key"}, "/backend-api/files/uploaded")
  end

  defp pending_file(auth, assignment, now) do
    %FileRecord{}
    |> FileRecord.changeset(%{pool_id: auth.pool.id, api_key_id: auth.api_key.id, pool_upstream_assignment_id: assignment.id, file_id: "file-#{System.unique_integer([:positive])}", purpose: "user_data", filename: "sample.txt", byte_size: 1, status: "pending_upload", finalize_status: "pending", expires_at: DateTime.add(now, 60), metadata: %{}, created_at: now, updated_at: now})
    |> Repo.insert!()
  end
end

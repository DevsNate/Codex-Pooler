defmodule CodexPoolerWeb.Operations.MetricsAcceptTest do
  use CodexPoolerWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  alias CodexPooler.InstanceSettings
  alias CodexPooler.InstanceSettings.Settings
  alias CodexPooler.Repo
  alias CodexPoolerWeb.Telemetry.PrometheusReporter

  @token "synthetic-metrics-accept-token"

  defmodule UnavailableRepo do
    def insert(_struct, _opts), do: raise(DBConnection.ConnectionError, message: "settings db unavailable")
    def get!(_schema, _id), do: raise(DBConnection.ConnectionError, message: "settings db unavailable")
  end

  setup %{conn: conn} = context do
    previous = CodexPooler.TestAppEnv.restore_on_exit(InstanceSettings)
    on_exit(fn -> InstanceSettings.reset_cache_for_test() end)
    Application.put_env(:codex_pooler, InstanceSettings, Keyword.delete(previous, :repo))
    Repo.delete_all(Settings)
    InstanceSettings.reset_cache_for_test()

    auth = Map.get(context, :metrics_auth, :unset)

    if auth in [:correct, :missing, :wrong] do
      assert {:ok, _settings} =
               InstanceSettings.update_system_settings(
                 InstanceSettings.ensure_singleton!(),
                 InstanceSettings.put_metrics_bearer_token(%{}, @token)
               )
    end

    if auth == :unavailable do
      Application.put_env(:codex_pooler, InstanceSettings, repo: UnavailableRepo)
      InstanceSettings.reset_cache_for_test()
    end

    conn =
      case auth do
        :correct -> put_req_header(conn, "authorization", "Bearer " <> @token)
        :wrong -> put_req_header(conn, "authorization", "Bearer synthetic-wrong-token")
        _auth -> conn
      end

    :ok = PrometheusReporter.fold()
    %{conn: conn}
  end

  for {name, accept} <- [
        {"no Accept header", nil},
        {"wildcard", "*/*"},
        {"JSON", "application/json"},
        {"plain text", "text/plain"},
        {"versioned Prometheus text", "text/plain;version=0.0.4"},
        {"mixed Prometheus formats", "application/openmetrics-text;version=1.0.0;q=0.9,text/plain;version=0.0.4;q=0.8,*/*;q=0.1"}
      ],
      auth <- [:unset, :correct, :missing, :wrong, :unavailable] do
    @tag metrics_auth: auth, metrics_accept: accept
    test "GET /metrics with #{name} preserves #{auth} bearer authorization", %{conn: conn, metrics_auth: auth, metrics_accept: accept} do
      conn = if accept, do: put_req_header(conn, "accept", accept), else: conn
      {conn, log} = with_log(fn -> get(conn, ~p"/metrics") end)

      if auth in [:unset, :correct] do
        assert conn.status == 200
        assert [content_type] = get_resp_header(conn, "content-type")
        assert String.starts_with?(content_type, "text/plain; version=0.0.4")
        assert String.contains?(conn.resp_body, "# TYPE ")
      else
        assert conn.status == 401
        assert %{"error" => %{"code" => "metrics_unauthorized", "message" => message}} = json_response(conn, 401)

        if auth == :unavailable do
          assert message == "metrics bearer token is unavailable"
          assert log =~ "instance settings db load failed warm_cache=false"
        else
          assert message == "metrics bearer token is required"
        end
      end
    end
  end

  for route <- ["/healthz", "/readyz", "/api/codex/usage"],
      accept <- ["text/plain", "text/plain;version=0.0.4"] do
    test "GET #{route} retains its JSON API refusal for #{accept}", %{conn: conn} do
      conn = put_req_header(conn, "accept", unquote(accept))
      assert_error_sent 406, fn -> get(conn, unquote(route)) end
    end
  end
end

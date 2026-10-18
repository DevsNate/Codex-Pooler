defmodule CodexPoolerWeb.McpOperatorTimestampsTest do
  use CodexPoolerWeb.ConnCase, async: false

  import CodexPooler.AccountsFixtures
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport, only: [capture_public_endpoint_identity!: 1, assert_public_endpoint_identity_released!: 1]

  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPooler.InstanceSettings
  alias CodexPooler.MCP
  alias CodexPooler.MCP.Redaction
  alias CodexPooler.Repo

  setup do
    reset_bootstrap_state_fixture!()
    previous_settings = CodexPooler.TestAppEnv.restore_on_exit(OperationalSettings)
    on_exit(fn -> InstanceSettings.reset_cache_for_test() end)

    Application.put_env(:codex_pooler, OperationalSettings, previous_settings |> Keyword.put(:settings, %OperationalSettings{}) |> Keyword.put(:use_instance_settings?, false))
    Repo.delete_all(CodexPooler.InstanceSettings.Settings)
    InstanceSettings.reset_cache_for_test()

    %{user: owner} = bootstrap_owner_fixture(%{"email" => unique_user_email()})
    owner = owner |> Ecto.Changeset.change(password_change_required: false, last_login_at: ~U[2026-10-01 12:00:00.123456Z]) |> Repo.update!()
    {:ok, _settings} = InstanceSettings.update_system_settings(InstanceSettings.ensure_singleton!(), %{"mcp" => %{"enabled" => true}})
    {:ok, _settings} = MCP.set_operator_mcp_enabled(owner, true)
    {:ok, %{raw_token: token}} = MCP.create_operator_token(owner, %{label: "Timestamp contract"})

    listener = start_supervised!({Bandit, plug: @endpoint, port: 0, ip: {127, 0, 0, 1}, startup_log: false})
    ownership = capture_public_endpoint_identity!(listener)
    on_exit(fn -> assert_public_endpoint_identity_released!(ownership) end)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(listener)

    %{owner: owner, token: token, port: port}
  end

  test "authenticated HTTP list and get return exact login timestamps", ctx do
    for {tool, arguments, field} <- [
          {"codex_pooler_list_operators", %{}, "operators"},
          {"codex_pooler_get_operator", %{"selector" => ctx.owner.id}, "item"}
        ] do
      response =
        Req.post!("http://127.0.0.1:#{ctx.port}/mcp",
          headers: [
            {"authorization", "Bearer #{ctx.token}"},
            {"accept", "application/json, text/event-stream"},
            {"mcp-protocol-version", "2025-11-25"}
          ],
          json: %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/call", "params" => %{"name" => tool, "arguments" => arguments}},
          retry: false
        )

      assert response.status == 200
      result = response.body["result"]
      assert result["isError"] == false
      presented = result["structuredContent"][field]
      presented = if is_list(presented), do: hd(presented), else: presented
      assert presented["last_login_at"] == "2026-10-01T12:00:00.123456Z"
      assert presented["mcp_enabled"] == true
      assert presented["mcp_key_count"] == 1
      assert :ok = Redaction.assert_mcp_output_safe!(result)
    end
  end
end

defmodule CodexPoolerWeb.Admin.AlertsStaleTransitionLiveTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import CodexPooler.PoolerFixtures

  alias CodexPooler.Alerts
  alias CodexPooler.Alerts.Schemas.AlertIncident
  alias CodexPooler.Repo

  setup :register_and_log_in_user

  test "stale acknowledge control reports an error after another operator resolves", %{
    conn: conn,
    scope: scope
  } do
    pool = pool_fixture()
    incident = alert_incident_fixture(pool: pool)
    {:ok, view, _html} = live(conn, ~p"/admin/alerts?tab=incidents")

    assert has_element?(view, "#alert-incident-acknowledge-#{incident.id}")
    assert {:ok, _resolved} = Alerts.resolve_incident(scope, incident.id)

    view
    |> element("#alert-incident-acknowledge-#{incident.id}")
    |> render_click()

    assert has_element?(view, "#flash-error", "Alert incident could not be acknowledged")
    assert Repo.get!(AlertIncident, incident.id).state == "resolved"
    refute has_element?(view, "#alert-incident-acknowledge-#{incident.id}")
  end
end

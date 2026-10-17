defmodule CodexPoolerWeb.Admin.UpstreamCockpitLifecycleTest do
  use CodexPoolerWeb.ConnCase, async: false

  import CodexPooler.PoolerFixtures
  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest

  alias CodexPooler.{Accounts, Pools, Repo}
  alias CodexPoolerWeb.Admin.UpstreamCockpitLive
  alias Phoenix.LiveView.Socket

  @moduletag capture_log: false
  @detection_timeout_ms 5_000

  setup :register_and_log_in_user

  for {transition, destination} <- [revoked: "/login", password_change: "/password/change-required"] do
    test "#{transition} between static render and connected mount redirects without a cleanup exception", %{conn: conn, scope: scope, user: user} do
      {:ok, pool} = Pools.create_pool(scope, %{slug: "cockpit-lifecycle", name: "Sample Pool"})
      %{identity: identity} = upstream_assignment_fixture(pool, %{account_label: "Sample upstream"})
      conn = get(conn, ~p"/admin/upstreams/#{identity.id}")
      assert html_response(conn, 200) =~ "Sample upstream"
      invalidate_session(unquote(transition), conn, user)

      owner = self()
      observer = start_supervised!({Task, fn -> observe_channel_exit(owner) end})
      handler = {__MODULE__, make_ref()}
      on_exit(fn -> :telemetry.detach(handler) end)
      :ok = :telemetry.attach(handler, [:phoenix, :live_view, :mount, :start], &__MODULE__.observe_mount/4, %{observer: observer, identity_id: identity.id})

      {result, private_log} =
        with_log(fn ->
          redirected? =
            case live(conn) do
              {:error, {:redirect, %{to: destination}}} -> destination == unquote(destination)
              _other -> false
            end

          shutdown? =
            receive do
              {:channel_terminated, ^observer, orderly?} -> orderly?
            after
              @detection_timeout_ms -> false
            end

          %{redirected?: redirected?, shutdown?: shutdown?}
        end)

      cleanup_exception? = String.contains?(private_log, "KeyError") or String.contains?(private_log, "terminating")
      assert result.redirected?, "the connected mount must keep its authentication redirect"
      refute cleanup_exception?, "the halted mount must not log a cleanup exception"
      assert result.shutdown?, "the halted channel must exit with an orderly shutdown"
    end
  end

  test "termination accepts a socket whose page mount never initialized the timer" do
    assert :ok = UpstreamCockpitLive.terminate(:shutdown, %Socket{assigns: %{current_scope: nil}})
  end

  test "termination accepts an initialized socket without an active timer" do
    for timer <- [nil, false] do
      assert :ok = UpstreamCockpitLive.terminate(:shutdown, %Socket{assigns: %{saved_reset_status_timer: timer}})
    end
  end

  test "termination cancels an active saved reset status timer" do
    timer = Process.send_after(self(), :synthetic_saved_reset_status_tick, 60_000)
    on_exit(fn -> Process.cancel_timer(timer) end)
    assert is_integer(Process.read_timer(timer))

    assert :ok = UpstreamCockpitLive.terminate(:shutdown, %Socket{assigns: %{saved_reset_status_timer: timer}})
    assert Process.read_timer(timer) == false
    assert :ok = UpstreamCockpitLive.terminate(:shutdown, %Socket{assigns: %{saved_reset_status_timer: timer}})
  end

  @doc false
  def observe_mount(_event, _measurements, %{socket: %Socket{view: UpstreamCockpitLive} = socket, params: %{"id" => identity_id}}, %{observer: observer, identity_id: identity_id}) do
    if Phoenix.LiveView.connected?(socket) do
      ref = make_ref()
      send(observer, {:observe_channel, self(), ref})

      receive do
        {:channel_observed, ^ref} -> :ok
      after
        @detection_timeout_ms -> raise "channel observer did not acknowledge the connected mount"
      end
    end
  end

  def observe_mount(_event, _measurements, _metadata, _config), do: :ok

  defp observe_channel_exit(owner) do
    receive do
      {:observe_channel, channel, ref} ->
        monitor = Process.monitor(channel)
        send(channel, {:channel_observed, ref})

        receive do
          {:DOWN, ^monitor, :process, ^channel, reason} ->
            orderly? = reason in [:normal, :shutdown] or match?({:shutdown, _}, reason)
            send(owner, {:channel_terminated, self(), orderly?})
        end
    end
  end

  defp invalidate_session(:revoked, conn, _user), do: Accounts.delete_user_session_token(get_session(conn, :user_token))

  defp invalidate_session(:password_change, _conn, user) do
    user |> Ecto.Changeset.change(password_change_required: true) |> Repo.update!()
  end
end

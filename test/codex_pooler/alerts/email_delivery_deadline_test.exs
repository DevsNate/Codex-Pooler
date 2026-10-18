defmodule CodexPooler.Alerts.EmailDeliveryDeadlineTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures
  import CodexPooler.UnboxedFixture

  alias CodexPooler.Alerts.Delivery.{AttemptLifecycle, EmailDelivery, Execution, PendingRecovery}
  alias CodexPooler.Alerts.Schemas.{AlertChannel, AlertDeliveryAttempt}
  alias CodexPooler.Jobs.AlertDeliveryWorker
  alias CodexPooler.Mailer
  alias CodexPooler.Pools.Pool
  alias CodexPooler.TestAppEnv
  alias CodexPooler.TestDiagnostics
  alias Oban.Engines.Basic

  @moduletag capture_log: true
  @wait 15_000

  setup do
    TestAppEnv.restore_on_exit(Mailer)
    :ok
  end

  for stage <- [:banner, :data] do
    @stage stage
    test "real SMTP #{@stage} stall leaves a durable pending receipt then a bounded unknown outcome" do
      fixture = fixture!()
      smtp = smtp!(@stage)
      execution = %{Execution.new(fixture.job) | deadline: System.monotonic_time(:millisecond) + 600}
      caller = delivery_task(fixture, execution)
      assert_receive {:smtp_stalled, peer}, @wait
      pending = database(fixture, fn -> attempt!(fixture) end)
      assert pending.status == "pending"
      assert pending.response_metadata["delivery_execution"]["job_id"] == fixture.job.id
      assert {:error, %{code: "alert_email_delivery_timeout", retryable: true}} = Task.await(caller, @wait)
      assert Task.await(smtp.task, @wait) == {:error, :closed}
      assert_receive {:smtp_closed, ^peer}, @wait
      assert Execution.remaining(execution) == 0
      attempt = database(fixture, fn -> attempt!(fixture) end)
      assert attempt.id == pending.id
      assert attempt.status == "retryable"
      assert attempt.response_metadata["delivery_outcome"] == "unknown"
      assert attempt.response_metadata["delivery_adapter"] == "email"
      assert DateTime.diff(attempt.next_retry_at, attempt.completed_at, :second) == 60
      TestDiagnostics.puts("email-deadline stage=#{@stage} pending_before_send=true caller_returned=true peer_closed=true receipt=retryable outcome=unknown")
    end
  end

  test "actual worker carries its entry budget through pending creation SMTP and finalization" do
    fixture = fixture!()
    smtp = smtp!(:hold)
    tasks = start_supervised!(Supervisor.child_spec({Task.Supervisor, []}, id: make_ref()))
    patterns = [{Execution, :new, 1}, {Execution, :run, 2}, {Execution, :storage, 2}]
    on_exit(fn -> Enum.each(patterns, &:erlang.trace_pattern(&1, false, [:local])) end)
    Code.ensure_loaded!(Execution)
    :erlang.trace_pattern({Execution, :new, 1}, [{:_, [], [{:return_trace}]}], [:local])
    for function <- [:run, :storage], do: :erlang.trace_pattern({Execution, function, 2}, [{[:"$1", :_], [], [{:message, {:map_get, :deadline, :"$1"}}]}], [:local])

    caller =
      Task.Supervisor.async_nolink(tasks, fn ->
        receive do
          :begin -> database(fixture, fn -> AlertDeliveryWorker.perform(fixture.job) end)
        end
      end)

    :erlang.trace(caller.pid, true, [:call, :arity, {:tracer, self()}])
    started = System.monotonic_time(:millisecond)
    send(caller.pid, :begin)
    assert_receive {:smtp_stalled, peer}, @wait
    assert database(fixture, fn -> attempt!(fixture).status end) == "pending"
    assert_receive {:trace, _, :return_from, {Execution, :new, 1}, %Execution{} = execution}, @wait
    assert execution.deadline >= started + 10_000
    assert execution.deadline <= System.monotonic_time(:millisecond) + 10_000
    assert execution.completion_deadline - execution.deadline == 2_000
    deadline = execution.deadline
    assert_receive {:trace, _, :call, {Execution, :storage, 2}, ^deadline}, @wait
    assert_receive {:trace, _, :call, {Execution, :run, 2}, ^deadline}, @wait
    send(peer, :accept)
    assert :ok = Task.await(caller, @wait)
    assert Task.await(smtp.task, @wait) == :accepted
    assert database(fixture, fn -> attempt!(fixture).status end) == "sent"
    TestDiagnostics.puts("email-worker network_budget_ms=10000 completion_budget_ms=12000 worker_cutoff_ms=15000 same_execution_through_smtp=true receipt=sent")
  end

  test "worker death closes SMTP and recovery waits for durable execution revocation" do
    fixture = fixture!()
    smtp = smtp!(:data)
    caller = delivery_task(fixture, Execution.new(fixture.job))
    monitor = Process.monitor(caller.pid)
    assert_receive {:smtp_stalled, _}, @wait
    pending = database(fixture, fn -> attempt!(fixture) end)
    assert pending.status == "pending"
    Process.exit(caller.pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, _, :killed}, @wait
    assert Task.await(smtp.task, @wait) == {:error, :closed}

    database(fixture, fn ->
      assert {:ok, :unchanged} = PendingRecovery.recover_one(pending, DateTime.utc_now())
      assert attempt!(fixture).status == "pending"
      fixture.job |> Ecto.Changeset.change(state: "retryable", scheduled_at: DateTime.add(DateTime.utc_now(), 60)) |> Repo.update!()
      assert {:ok, recovered} = PendingRecovery.recover_one(pending, DateTime.utc_now())
      assert recovered.id == pending.id
      assert recovered.status == "retryable"
      assert recovered.failure_code == "alert_email_execution_interrupted"
      assert recovered.failure_metadata["delivery_adapter"] == "email"
      assert recovered.response_metadata["delivery_outcome"] == "unknown"
      assert {:ok, :unchanged} = PendingRecovery.recover_one(pending, DateTime.utc_now())
      assert {:error, %{code: "alert_delivery_execution_superseded"}} = AttemptLifecycle.mark_sent_attempt(pending, DateTime.utc_now(), %{})
    end)

    TestDiagnostics.puts("email-recovery caller_killed=true peer_closed=true executing_pending=true revoked_retryable=true adapter=email stale_callback_rejected=true")
  end

  test "same-claim duplicate cannot send and a successful receipt suppresses delivery inside cooldown" do
    fixture = fixture!()
    smtp = smtp!(:hold)
    caller = delivery_task(fixture, Execution.new(fixture.job))
    assert_receive {:smtp_stalled, peer}, @wait
    pending = database(fixture, fn -> attempt!(fixture) end)
    assert pending.status == "pending"

    database(fixture, fn ->
      assert {:error, %Ecto.Changeset{} = changeset} = EmailDelivery.deliver_incident_to_channel(fixture.incident.id, fixture.channel.id, 1, delivery_execution: Execution.new(fixture.job))
      assert Keyword.has_key?(changeset.errors, :attempt_number)
    end)

    send(peer, :accept)
    assert {:ok, sent} = Task.await(caller, @wait)
    assert sent.id == pending.id
    assert sent.status == "sent"
    assert Task.await(smtp.task, @wait) == :accepted
    assert {:ok, %{status: "discarded", failure_code: "alert_delivery_cooldown_suppressed"}} = database(fixture, fn -> EmailDelivery.deliver_incident_to_channel(fixture.incident.id, fixture.channel.id, 2) end)
    assert {:error, :timeout} = :gen_tcp.accept(smtp.listener, 0)
    TestDiagnostics.puts("email-cooldown same_claim_rejected=true smtp_connections=1 sent_then_suppressed=true")
  end

  test "an exhausted job retry budget records a terminal unknown receipt" do
    fixture = fixture!()
    smtp = smtp!(:data)
    execution = %{Execution.new(fixture.job) | deadline: System.monotonic_time(:millisecond) + 600}
    caller = delivery_task(fixture, execution, retry_attempt: 5)
    assert_receive {:smtp_stalled, _}, @wait
    assert {:ok, %{status: "failed", retryable: false, next_retry_at: nil} = attempt} = Task.await(caller, @wait)
    assert attempt.response_metadata["delivery_outcome"] == "unknown"
    assert Task.await(smtp.task, @wait) == {:error, :closed}
  end

  test "unknown SMTP outcomes retain at-least-once retry and a successor can complete" do
    fixture = fixture!()
    first_smtp = smtp!(:data)
    execution = %{Execution.new(fixture.job) | deadline: System.monotonic_time(:millisecond) + 600}
    first = delivery_task(fixture, execution)
    assert_receive {:smtp_stalled, _}, @wait
    assert {:error, %{retryable: true}} = Task.await(first, @wait)
    assert Task.await(first_smtp.task, @wait) == {:error, :closed}
    unknown = database(fixture, fn -> attempt!(fixture) end)
    assert unknown.response_metadata["delivery_outcome"] == "unknown"

    successor =
      database(fixture, fn ->
        fixture.job |> Ecto.Changeset.change(state: "available", scheduled_at: DateTime.utc_now()) |> Repo.update!()
        conf = Oban.config()
        {:ok, meta} = Basic.init(conf, queue: fixture.job.queue, limit: 1)
        {:ok, {_meta, [claimed]}} = Basic.fetch_jobs(conf, meta, %{})
        claimed
      end)

    assert successor.attempt == 2
    second_smtp = smtp!(:hold)
    tasks = start_supervised!(Supervisor.child_spec({Task.Supervisor, []}, id: make_ref()))
    second = Task.Supervisor.async_nolink(tasks, fn -> database(fixture, fn -> AlertDeliveryWorker.perform(successor) end) end)
    assert_receive {:smtp_stalled, peer}, @wait
    send(peer, :accept)
    assert :ok = Task.await(second, @wait)
    assert Task.await(second_smtp.task, @wait) == :accepted

    database(fixture, fn ->
      assert Repo.get!(AlertDeliveryAttempt, unknown.id) == unknown
      assert %{status: "sent", attempt_number: 2, response_metadata: metadata} = Repo.one!(from a in AlertDeliveryAttempt, where: a.incident_id == ^fixture.incident.id and a.attempt_number == 2)
      assert metadata["delivery_execution"]["job_attempt"] == 2
    end)

    TestDiagnostics.puts("email-retry unknown_then_success=true smtp_data_accepted_twice=true at_least_once=true job_attempt=2")
  end

  defp delivery_task(fixture, execution, opts \\ []) do
    tasks = start_supervised!(Supervisor.child_spec({Task.Supervisor, []}, id: make_ref()))
    Task.Supervisor.async_nolink(tasks, fn -> database(fixture, fn -> EmailDelivery.deliver_incident_to_channel(fixture.incident.id, fixture.channel.id, 1, Keyword.put(opts, :delivery_execution, execution)) end) end)
  end

  defp fixture! do
    suffix = System.unique_integer([:positive])
    slug = "email-deadline-#{suffix}"
    label = "email-deadline-channel-#{suffix}"
    queue = "email_deadline_#{suffix}"

    register_unboxed_cleanup!(fn ->
      if pool = Repo.get_by(Pool, slug: slug), do: delete_committed_pools!([pool.id])
      Repo.delete_all(from j in Oban.Job, where: j.queue == ^queue)
      Repo.delete_all(from c in AlertChannel, where: c.display_name == ^label)
      refute Repo.exists?(from p in Pool, where: p.slug == ^slug)
      refute Repo.exists?(from c in AlertChannel, where: c.display_name == ^label)
      refute Repo.exists?(from j in Oban.Job, where: j.queue == ^queue)
      TestDiagnostics.puts("email-deadline cleanup owned_rows_absent=true")
    end)

    fixture =
      run_unboxed(fn ->
        pool = pool_fixture(%{slug: slug})
        channel = alert_channel_fixture(display_name: label)
        incident = alert_incident_fixture(pool: pool)
        rule = alert_rule_fixture(pool)
        alert_incident_target_fixture(incident, rule, pool)
        job = %{"alert_incident_id" => incident.id, "alert_channel_id" => channel.id} |> AlertDeliveryWorker.new(queue: queue) |> Repo.insert!()
        conf = Oban.config()
        {:ok, meta} = Basic.init(conf, queue: queue, limit: 1)
        {:ok, {_meta, [claimed]}} = Basic.fetch_jobs(conf, meta, %{})
        assert claimed.id == job.id
        %{incident: incident, channel: channel, job: claimed}
      end)

    name = String.to_atom("email_deadline_repo_#{suffix}")
    opts = Repo.config() |> Keyword.put(:name, name) |> Keyword.put(:pool, DBConnection.ConnectionPool) |> Keyword.put(:pool_size, 4)
    repo = start_supervised!(Supervisor.child_spec({Repo, opts}, id: name))
    Map.put(fixture, :repo, repo)
  end

  defp database(fixture, fun) do
    previous = Repo.put_dynamic_repo(fixture.repo)

    try do
      fun.()
    after
      Repo.put_dynamic_repo(previous)
    end
  end

  defp attempt!(fixture), do: Repo.one!(from a in AlertDeliveryAttempt, where: a.incident_id == ^fixture.incident.id and a.channel_id == ^fixture.channel.id)

  defp smtp!(stage) do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, packet: :line, ip: {127, 0, 0, 1}])
    on_exit(fn -> :gen_tcp.close(listener) end)
    {:ok, port} = :inet.port(listener)
    Application.put_env(:codex_pooler, Mailer, adapter: Swoosh.Adapters.SMTP, use_instance_settings?: false, relay: "127.0.0.1", port: port, ssl: false, tls: :never, auth: :never, retries: 0, no_mx_lookups: true)
    tasks = start_supervised!(Supervisor.child_spec({Task.Supervisor, []}, id: make_ref()))
    parent = self()

    task =
      Task.Supervisor.async_nolink(tasks, fn ->
        {:ok, socket} = :gen_tcp.accept(listener, @wait)

        try do
          if stage != :banner, do: smtp_data(socket)
          send(parent, {:smtp_stalled, self()})

          if stage == :hold do
            receive do
              :accept -> :ok
            after
              @wait -> raise "SMTP acceptance barrier not released"
            end

            :ok = :gen_tcp.send(socket, "250 accepted\r\n")
            assert {:ok, "QUIT\r\n"} = :gen_tcp.recv(socket, 0, @wait)
            :gen_tcp.send(socket, "221 bye\r\n")
            :accepted
          else
            result = :gen_tcp.recv(socket, 0, @wait)
            send(parent, {:smtp_closed, self()})
            result
          end
        after
          :gen_tcp.close(socket)
        end
      end)

    %{listener: listener, task: task}
  end

  defp smtp_data(socket) do
    :ok = :gen_tcp.send(socket, "220 example.com synthetic SMTP\r\n")
    assert {:ok, "EHLO " <> _} = :gen_tcp.recv(socket, 0, @wait)
    :ok = :gen_tcp.send(socket, "250 example.com\r\n")
    assert {:ok, "MAIL FROM:" <> _} = :gen_tcp.recv(socket, 0, @wait)
    :ok = :gen_tcp.send(socket, "250 ok\r\n")
    assert {:ok, "RCPT TO:" <> _} = :gen_tcp.recv(socket, 0, @wait)
    :ok = :gen_tcp.send(socket, "250 ok\r\n")
    assert {:ok, "DATA\r\n"} = :gen_tcp.recv(socket, 0, @wait)
    :ok = :gen_tcp.send(socket, "354 proceed\r\n")
    consume_data(socket)
  end

  defp consume_data(socket) do
    case :gen_tcp.recv(socket, 0, @wait) do
      {:ok, ".\r\n"} -> :ok
      {:ok, _line} -> consume_data(socket)
    end
  end
end

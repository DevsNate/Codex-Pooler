defmodule CodexPooler.Events.Outbox do
  @moduledoc """
  Committed accounting invalidations waiting for the PostgreSQL relay.

  Each event has its own row, without references to accounting or session rows.
  The relay transaction owns only outbox rows while PostgreSQL commits NOTIFY.
  Successful notification and deletion commit together; listeners still have
  PostgreSQL's ordinary live-listener delivery contract.
  """

  import Ecto.Query

  alias CodexPooler.Events
  alias CodexPooler.Events.Event
  alias CodexPooler.Events.OutboxEntry
  alias CodexPooler.Repo

  @batch_size 100
  @timeout_ms 5_000
  @request_reasons ~w(request_reserved request_rejected request_log_created request_finalized request_metadata_updated)
  @statuses ~w(accepted in_progress succeeded failed rejected cancelled)
  @usage_statuses ~w(usage_pending usage_known usage_unknown not_applicable)

  @doc false
  @spec enqueue(Event.t()) :: :ok | {:error, atom()}
  def enqueue(%Event{} = event) do
    with true <- valid_event?(event),
         {:ok, payload} <- encode(event),
         true <- byte_size(payload) < 8_000 and String.valid?(payload) and not String.contains?(payload, <<0>>) do
      case Repo.insert(%OutboxEntry{id: event.id, payload: payload}, log: false) do
        {:ok, _entry} -> :ok
        {:error, _changeset} -> {:error, :event_outbox_enqueue_failed}
      end
    else
      _invalid -> {:error, :invalid_event_payload}
    end
  end

  defp valid_event?(event) do
    event.version == 1 and valid_uuid?(event.id) and valid_uuid?(event.pool_id) and match?(%DateTime{}, event.emitted_at) and
      valid_reason?(event.topics, event.reason) and is_map(event.payload) and
      Enum.all?(event.payload, &valid_metadata?/1)
  end

  defp valid_reason?(["request_logs"], reason), do: reason in @request_reasons
  defp valid_reason?(["usage"], "usage_updated"), do: true
  defp valid_reason?(_topics, _reason), do: false

  defp valid_metadata?({"request_id", id}), do: valid_uuid?(id)
  defp valid_metadata?({"status", status}), do: status in @statuses
  defp valid_metadata?({"usage_status", status}), do: status in @usage_statuses
  defp valid_metadata?(_metadata), do: false

  defp valid_uuid?(value), do: match?({:ok, ^value}, Ecto.UUID.cast(value)) and is_binary(value)

  defp encode(event) do
    event
    |> Map.from_struct()
    |> Map.update!(:emitted_at, &DateTime.to_iso8601/1)
    |> Map.put(:origin_id, "transaction:" <> event.id)
    |> CodexPooler.JSON.encode()
  end

  @doc "Publishes one bounded batch in a transaction independent of accounting."
  @spec drain(keyword()) :: {:ok, non_neg_integer()} | {:error, atom()}
  def drain(opts \\ []) do
    if Repo.in_transaction?() do
      {:error, :event_outbox_requires_independent_transaction}
    else
      drain_transaction(opts)
    end
  end

  defp drain_transaction(opts) do
    batch_size = opts |> Keyword.get(:batch_size, @batch_size) |> max(1) |> min(@batch_size)
    timeout = Keyword.get(opts, :timeout, @timeout_ms)

    Repo.transact(
      fn ->
        entries = Repo.all(from entry in OutboxEntry, order_by: [asc: entry.inserted_at, asc: entry.id], limit: ^batch_size, lock: "FOR UPDATE SKIP LOCKED")
        publish_and_delete(entries)
        {:ok, length(entries)}
      end,
      timeout: timeout,
      checkout_retries: 0
    )
  rescue
    _error in [Postgrex.Error, DBConnection.ConnectionError] -> {:error, :event_outbox_dispatch_failed}
  end

  defp publish_and_delete([]), do: :ok

  defp publish_and_delete(entries) do
    payloads = Enum.map(entries, & &1.payload)
    Repo.query!("SELECT pg_notify($1, payload) FROM unnest($2::text[]) AS payload", [Events.postgres_channel(), payloads], log: false)
    ids = Enum.map(entries, & &1.id)
    Repo.delete_all(from entry in OutboxEntry, where: entry.id in ^ids)
    :ok
  end
end

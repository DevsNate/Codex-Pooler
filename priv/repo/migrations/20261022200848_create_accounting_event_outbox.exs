defmodule CodexPooler.Repo.Migrations.CreateAccountingEventOutbox do
  use Ecto.Migration

  def change do
    create table(:accounting_event_outbox, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :payload, :text, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create constraint(:accounting_event_outbox, :accounting_event_outbox_payload_size, check: "octet_length(payload) < 8000")
    create index(:accounting_event_outbox, [:inserted_at, :id])
  end
end

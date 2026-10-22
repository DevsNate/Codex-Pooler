defmodule CodexPooler.Events.OutboxEntry do
  @moduledoc false

  use CodexPooler.Schema

  @type t :: %__MODULE__{id: Ecto.UUID.t(), payload: String.t(), inserted_at: DateTime.t()}

  schema "accounting_event_outbox" do
    field :payload, :string
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end

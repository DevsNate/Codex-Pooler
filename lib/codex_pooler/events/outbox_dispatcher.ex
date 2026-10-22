defmodule CodexPooler.Events.OutboxDispatcher do
  @moduledoc "Polls committed accounting events on every release role, including unclustered nodes."

  use GenServer

  alias CodexPooler.Events.Outbox

  require Logger

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    config = Application.get_env(:codex_pooler, __MODULE__, [])

    if Keyword.get(opts, :enabled, Keyword.get(config, :enabled, true)) do
      GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
    else
      :ignore
    end
  end

  @impl GenServer
  def init(opts) do
    {:ok, %{poll_interval_ms: Keyword.get(opts, :poll_interval_ms, 1_000), failures: 0}, {:continue, :dispatch}}
  end

  @impl GenServer
  def handle_continue(:dispatch, state), do: dispatch(state)

  @impl GenServer
  def handle_info(:dispatch, state), do: dispatch(state)
  def handle_info(_message, state), do: {:noreply, state}

  defp dispatch(state) do
    {state, delay} =
      case Outbox.drain() do
        {:ok, count} ->
          {%{state | failures: 0}, if(count == 100, do: 100, else: state.poll_interval_ms)}

        {:error, _reason} ->
          Logger.warning("accounting event outbox dispatch failed; retrying")
          failures = min(state.failures + 1, 4)
          {%{state | failures: failures}, min(1_000 * Integer.pow(2, failures - 1), 5_000)}
      end

    Process.send_after(self(), :dispatch, delay)
    {:noreply, state}
  end
end

defmodule RC.Accounts.DeletionSweeper do
  @moduledoc """
  Periodic account-lifecycle sweep. Each tick purges:

  1. deletion-pending accounts past their grace period
     (`RC.Accounts.Deletion.purge_due_accounts/0`)
  2. stale unverified `:registered` accounts past the signup expiry
     (`RC.Accounts.purge_stale_unverified_accounts/0` — the
     anti-squatting half of open signup)

  Not started in the test environment — tests call the purge functions
  directly.
  """

  use GenServer

  require Logger

  alias RC.Accounts.Deletion

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(_) do
    # First sweep shortly after boot (past the boot-restore rush), then on
    # the configured interval.
    Process.send_after(self(), :sweep, :timer.minutes(5))
    {:ok, nil}
  end

  @impl true
  def handle_info(:sweep, state) do
    try do
      Deletion.purge_due_accounts()
    rescue
      e -> Logger.error("deletion sweep failed: #{inspect(e)}")
    end

    try do
      RC.Accounts.purge_stale_unverified_accounts()
    rescue
      e -> Logger.error("unverified-account sweep failed: #{inspect(e)}")
    end

    Process.send_after(self(), :sweep, interval_ms())
    {:noreply, state}
  end

  defp interval_ms do
    Application.get_env(:rc, RC.Accounts.Deletion, [])
    |> Keyword.get(:sweep_interval_ms, 21_600_000)
  end
end

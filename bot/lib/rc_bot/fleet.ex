defmodule RcBot.Fleet do
  @moduledoc """
  DynamicSupervisor that holds the running bot sessions. Start/stop bots
  via `start_bot/1` and `stop_bot/1`.

  Each bot's `RcBot.Session` is registered in `RcBot.Registry` under
  `{:session, bot_id}` so the orchestrator (and humans in iex) can find it.
  """

  use DynamicSupervisor

  alias RcBot.Session

  def start_link(_args) do
    DynamicSupervisor.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(:ok) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Start a single bot.

  `args` must include `:email`, `:password`, `:profile_id`, `:instance_id`,
  `:faction_id`. The bot will log in, register if needed, and begin its
  session loop.
  """
  def start_bot(args) do
    spec = {Session, args}
    DynamicSupervisor.start_child(__MODULE__, spec)
  end

  def stop_bot(bot_id) do
    case Registry.lookup(RcBot.Registry, {:session, bot_id}) do
      [{pid, _}] -> DynamicSupervisor.terminate_child(__MODULE__, pid)
      [] -> {:error, :not_found}
    end
  end

  def list_bots do
    DynamicSupervisor.which_children(__MODULE__)
    |> Enum.map(fn {_, pid, _, _} -> pid end)
  end
end

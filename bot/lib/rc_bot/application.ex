defmodule RcBot.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        {Registry, keys: :unique, name: RcBot.Registry},
        RcBot.Fleet
      ]
      |> maybe_add_orchestrator()

    opts = [strategy: :one_for_one, name: RcBot.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp maybe_add_orchestrator(children) do
    if Application.get_env(:rc_bot, :autostart_fleet, false) do
      children ++ [RcBot.Orchestrator]
    else
      children
    end
  end
end

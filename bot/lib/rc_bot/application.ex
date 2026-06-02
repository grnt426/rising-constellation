defmodule RcBot.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: RcBot.Registry},
      RcBot.Fleet
    ]

    opts = [strategy: :one_for_one, name: RcBot.Supervisor]
    Supervisor.start_link(children, opts)
  end
end

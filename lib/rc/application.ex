defmodule RC.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  def start(_type, _args) do
    {:ok, _} = Application.ensure_all_started(:appsignal)

    # List all child processes to be supervised
    children = [
      # Start the Game supervisor
      Game,
      {Phoenix.PubSub, name: RC.PubSub},
      # Start the Ecto repository
      RC.Repo,
      # Start the endpoint when the application starts
      Portal.Endpoint,
      # Start Presence endpoint
      Portal.Presence,
      # Stage 7 F25. Central Task.Supervisor for all fire-and-forget
      # work that used to use bare `Task.start`/`Task.start_link` —
      # autosave, replay-recorder inner span, maintenance LiveView,
      # ChannelWatcher leave callbacks. `restart: :temporary` ensures
      # one task crash doesn't restart the task; it's logged and we
      # move on. Defined BEFORE ChannelWatcher because the watcher's
      # leave callbacks dispatch through this supervisor.
      {Task.Supervisor, name: RC.TaskSupervisor},
      {Portal.ChannelWatcher, :player_channel},
      RC.GC
    ]

    children =
      children ++
        if Application.get_env(:rc, :environment) != :test do
          [
            %{
              type: :worker,
              id: :fix_instances_statuses,
              start: {Task, :start_link, [fn -> RC.Instances.update_instances_state_if_needed(true) end]},
              restart: :temporary,
              shutdown: 5000
            }
          ]
        else
          []
        end

    # Stage 7 F14: explicit max_restarts/max_seconds. RC.Supervisor
    # sits above Phoenix.Endpoint + RC.Repo + Game + PubSub + Presence
    # + ChannelWatcher + RC.GC. The OTP default 3/5s budget meant a
    # transient DB connection failure at boot could tear the whole
    # BEAM down via the default restart strategy. 10 restarts in 60s
    # is enough headroom for a flapping DB connection to settle
    # without masking a true cascade.
    Supervisor.start_link(children,
      strategy: :one_for_one,
      name: RC.Supervisor,
      max_restarts: 10,
      max_seconds: 60
    )
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  def config_change(changed, _new, removed) do
    Portal.Endpoint.config_change(changed, removed)
    :ok
  end
end

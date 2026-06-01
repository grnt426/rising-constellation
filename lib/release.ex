defmodule RC.Release do
  @moduledoc """
  Release-time tasks invoked via `bin/rc eval`.

  The OTP release does not include Mix, so `mix ecto.migrate` is unavailable
  in production. The deploy script (see deploy/bin/deploy.sh) runs:

      bin/rc eval "RC.Release.migrate()"

  before starting the release. This loads the application, starts each repo
  in isolation, runs all pending migrations, and stops the repo.

  Rollback to a specific version with:

      bin/rc eval "RC.Release.rollback(RC.Repo, 20230101000000)"

  See https://hexdocs.pm/phoenix/releases.html#ecto-migrations-and-custom-commands.
  """
  import Ecto.Query, warn: false

  @app :rc

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def migrate_registration_state do
    load_app()

    from(r in RC.Instances.Registration,
      where: r.state == "placeholder"
    )
    |> RC.Repo.all()
    |> Task.async_stream(fn reg ->
      last_state =
        from(s in RC.Instances.RegistrationState,
          where: s.registration_id == ^reg.id,
          order_by: [desc: s.id],
          limit: 1
        )
        |> RC.Repo.one()

      {:ok, _reg} = RC.Registrations.update(reg, %{state: last_state.state})
    end)
    |> Enum.to_list()
    |> Enum.count()
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.load(@app)
  end
end

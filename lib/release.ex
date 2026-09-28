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

  @doc """
  Archive a finished match from the snapshot files under `dir` (see
  deploy/bin/rc-archive-import, which fetches them from the nightly S3
  tarballs). Runs in its own VM with only the repo started, so the snapshot
  decoding never touches the live node's memory.

      bin/rc eval 'RC.Release.import_archive(121, "/tmp/rc-archive-121")'

  Options: `published: true | false` (default: keep the existing flag, or
  false for a first import).
  """
  def import_archive(instance_id, dir, opts \\ []) do
    load_app()

    {:ok, {:ok, match}, _} =
      Ecto.Migrator.with_repo(RC.Repo, fn _repo ->
        paths = RC.Archive.Importer.snapshot_paths(dir, instance_id)
        RC.Archive.Importer.run(instance_id, paths, opts)
      end)

    IO.puts("archive match #{match.id} (instance #{instance_id}) published=#{match.published}")
  end

  @doc "Show / hide an imported archive to players: `RC.Release.publish_archive(121)`."
  def publish_archive(instance_id, published \\ true) do
    load_app()

    {:ok, result, _} =
      Ecto.Migrator.with_repo(RC.Repo, fn _repo ->
        RC.Archive.set_published_for_instance(instance_id, published)
      end)

    IO.inspect(result |> elem(0), label: "publish_archive #{instance_id} -> #{published}")
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

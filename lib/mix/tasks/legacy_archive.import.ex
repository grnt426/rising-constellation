defmodule Mix.Tasks.LegacyArchive.Import do
  @moduledoc """
  Archive a finished match from local snapshot files (dev counterpart of
  `RC.Release.import_archive/3`).

      $ mix legacy_archive.import 121 tmp/snapshots/121 [--publish]

  Every file under the directory whose name contains
  `snapshot-<instance_id>-` is considered; the importer picks one per day.
  Only the repo is started, so this runs alongside a live dev server.
  """
  use Mix.Task

  @shortdoc "Import a finished match into the Legacy archive"

  def run(args) do
    {opts, [iid, dir], _} = OptionParser.parse(args, switches: [publish: :boolean])

    Mix.Task.run("app.config")
    {:ok, _} = Application.ensure_all_started(:ecto_sql)
    {:ok, _} = Application.ensure_all_started(:postgrex)
    {:ok, _} = RC.Repo.start_link()

    instance_id = String.to_integer(iid)
    paths = RC.Archive.Importer.snapshot_paths(dir, instance_id)
    import_opts = if Keyword.has_key?(opts, :publish), do: [published: opts[:publish]], else: []

    {:ok, match} = RC.Archive.Importer.run(instance_id, paths, import_opts)
    Mix.shell().info("match #{match.id} written")
  end
end

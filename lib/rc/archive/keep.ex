defmodule RC.Archive.Keep do
  @moduledoc """
  Saves the last pre-victory snapshot of an official Legacy match for the
  archive (see docs/legacy-archive.md).

  Autosaves keep running through the ~10 h post-victory grace period and
  only the newest 10 stay on disk, so the snapshot closest to the victory
  is pruned within about 2.5 h. `keep_async/2` runs at the victory and
  copies the newest autosave taken at or before it (at most one autosave
  interval, ~15 min, before the win) to `<archive_keep_dir>/<instance_id>/`.
  `deploy/bin/rc-archive-import` adds every file there to the import, so
  the archive's last day is a pre-victory sample.

  Off unless `:rc, :archive_keep_dir` is set (prod: `RC_ARCHIVE_KEEP_DIR`,
  default /home/rc/archive-keep).
  """

  import Ecto.Query, warn: false
  require Logger

  alias RC.Instances.InstanceSnapshot
  alias RC.Repo

  @doc """
  Starts `keep/2` in a supervised task and returns `:ok` at once. Called
  from the Victory agent's tick, so it never raises or exits into the
  caller: an agent crash would restart that agent from its initial state.
  """
  def keep_async(instance_id, at \\ DateTime.utc_now()) do
    Task.Supervisor.start_child(RC.TaskSupervisor, fn -> log_result(instance_id, keep(instance_id, at)) end,
      restart: :temporary
    )

    :ok
  rescue
    e ->
      Logger.error("[archive] victory snapshot keep not started: #{Exception.message(e)}", instance_id: instance_id)
      :ok
  catch
    kind, reason ->
      Logger.error("[archive] victory snapshot keep not started: #{kind} #{inspect(reason)}", instance_id: instance_id)
      :ok
  end

  @doc """
  Copies the newest snapshot of `instance_id` taken at or before `at` into
  the keep dir. Returns `{:ok, path}`, `{:skip, reason}` (keep dir unset,
  not an official Legacy match, no snapshot, S3 backend) or
  `{:error, reason}`.
  """
  def keep(instance_id, at \\ DateTime.utc_now()) do
    with {:ok, keep_dir} <- keep_dir(),
         :ok <- official(instance_id),
         {:ok, snapshot} <- last_snapshot(instance_id, at),
         {:ok, source} <- local_path(snapshot.name) do
      dir = Path.join(keep_dir, to_string(instance_id))
      dest = Path.join(dir, snapshot.name)

      with :ok <- File.mkdir_p(dir),
           :ok <- File.cp(source, dest) do
        {:ok, dest}
      else
        {:error, reason} -> {:error, {reason, source, dest}}
      end
    end
  end

  @doc "Official Legacy: promoted to Discord, not bot-only, slow speed."
  def official?(instance_id), do: official(instance_id) == :ok

  defp official(instance_id) do
    from(i in "instances",
      where: i.id == ^instance_id,
      select: %{
        discord_ready: i.discord_ready,
        is_bot_only: i.is_bot_only,
        game_data: i.game_data,
        game_metadata: i.game_metadata
      }
    )
    |> Repo.one()
    |> case do
      %{discord_ready: true, is_bot_only: false} = instance ->
        if speed(instance) == "slow", do: :ok, else: {:skip, :not_official}

      _ ->
        {:skip, :not_official}
    end
  end

  # Same fallback order as RC.Archive.Importer.
  defp speed(instance) do
    get_in(instance.game_data || %{}, ["speed"]) || get_in(instance.game_metadata || %{}, ["speed"]) || "slow"
  end

  defp keep_dir do
    case Application.get_env(:rc, :archive_keep_dir) do
      dir when is_binary(dir) and dir != "" -> {:ok, dir}
      _ -> {:skip, :disabled}
    end
  end

  defp last_snapshot(instance_id, at) do
    from(s in InstanceSnapshot,
      where: s.instance_id == ^instance_id and s.inserted_at <= ^at,
      order_by: [desc: s.inserted_at],
      limit: 1
    )
    |> Repo.one()
    |> case do
      nil -> {:skip, :no_snapshot}
      snapshot -> {:ok, snapshot}
    end
  end

  defp local_path(name) do
    case Util.Storage.local_path(name) do
      {:ok, path} -> {:ok, path}
      {:error, :not_local} -> {:skip, :not_local}
    end
  end

  defp log_result(instance_id, {:ok, path}),
    do: Logger.info("[archive] kept victory snapshot #{path}", instance_id: instance_id)

  defp log_result(_instance_id, {:skip, :not_official}), do: :ok

  defp log_result(instance_id, {:skip, reason}),
    do: Logger.warning("[archive] victory snapshot not kept: #{reason}", instance_id: instance_id)

  defp log_result(instance_id, {:error, reason}),
    do: Logger.error("[archive] victory snapshot keep failed: #{inspect(reason)}", instance_id: instance_id)
end

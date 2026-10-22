defmodule RC.Archive.KeepTest do
  use RC.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import RC.ScenarioFixtures

  alias RC.Archive.Keep
  alias RC.Instances.{Instance, InstanceSnapshot}
  alias RC.Repo

  setup do
    root = Path.join(System.tmp_dir!(), "rc-keep-test-#{System.unique_integer([:positive])}")
    snapshot_dir = Path.join(root, "snapshots")
    keep_dir = Path.join(root, "keep")
    File.mkdir_p!(snapshot_dir)

    saved = for key <- [:snapshot_backend, :snapshot_dir, :archive_keep_dir], do: {key, Application.get_env(:rc, key)}
    Application.put_env(:rc, :snapshot_backend, :local)
    Application.put_env(:rc, :snapshot_dir, snapshot_dir)
    Application.put_env(:rc, :archive_keep_dir, keep_dir)

    on_exit(fn ->
      Enum.each(saved, fn
        {key, nil} -> Application.delete_env(:rc, key)
        {key, value} -> Application.put_env(:rc, key, value)
      end)

      File.rm_rf!(root)
    end)

    %{instance: instance} = instance_fixture()
    %{instance: instance, snapshot_dir: snapshot_dir, keep_dir: keep_dir}
  end

  defp make_official(instance, overrides \\ []) do
    fields = Keyword.merge([discord_ready: true, is_bot_only: false, game_data: %{"speed" => "slow"}], overrides)
    from(i in Instance, where: i.id == ^instance.id) |> Repo.update_all(set: fields)
  end

  # An autosave as Manager.create_snapshot leaves it: the file in the
  # snapshot dir plus its instance_snapshots row.
  defp autosave(instance, snapshot_dir, name, inserted_at) do
    File.write!(Path.join(snapshot_dir, name), "state #{name}")

    Repo.insert!(%InstanceSnapshot{
      name: name,
      size: 10,
      instance_id: instance.id,
      inserted_at: inserted_at,
      updated_at: inserted_at
    })
  end

  defp ago(seconds), do: DateTime.add(DateTime.utc_now(), -seconds, :second)

  test "copies the newest autosave taken at or before the victory", ctx do
    make_official(ctx.instance)
    victory = ago(60)
    autosave(ctx.instance, ctx.snapshot_dir, "snapshot-#{ctx.instance.id}-1", ago(1_800))
    autosave(ctx.instance, ctx.snapshot_dir, "snapshot-#{ctx.instance.id}-2", ago(600))
    # A grace-period autosave after the victory never stands in for it.
    autosave(ctx.instance, ctx.snapshot_dir, "snapshot-#{ctx.instance.id}-3", ago(10))

    assert {:ok, path} = Keep.keep(ctx.instance.id, victory)
    assert path == Path.join([ctx.keep_dir, to_string(ctx.instance.id), "snapshot-#{ctx.instance.id}-2"])
    assert File.read!(path) == "state snapshot-#{ctx.instance.id}-2"
    assert File.ls!(Path.dirname(path)) == ["snapshot-#{ctx.instance.id}-2"]
  end

  test "keeps nothing for matches that are not official Legacy", ctx do
    autosave(ctx.instance, ctx.snapshot_dir, "snapshot-#{ctx.instance.id}-1", ago(600))

    assert {:skip, :not_official} = Keep.keep(ctx.instance.id)

    make_official(ctx.instance, game_data: %{"speed" => "fast"})
    assert {:skip, :not_official} = Keep.keep(ctx.instance.id)

    make_official(ctx.instance, is_bot_only: true)
    assert {:skip, :not_official} = Keep.keep(ctx.instance.id)

    refute File.exists?(ctx.keep_dir)
  end

  test "speed falls back to the game metadata", ctx do
    make_official(ctx.instance, game_data: %{}, game_metadata: %{"speed" => "slow"})
    autosave(ctx.instance, ctx.snapshot_dir, "snapshot-#{ctx.instance.id}-1", ago(600))

    assert {:ok, _} = Keep.keep(ctx.instance.id)
    assert Keep.official?(ctx.instance.id)
  end

  test "skips without a keep dir, a snapshot or a local backend", ctx do
    make_official(ctx.instance)
    assert {:skip, :no_snapshot} = Keep.keep(ctx.instance.id)

    autosave(ctx.instance, ctx.snapshot_dir, "snapshot-#{ctx.instance.id}-1", ago(600))

    Application.put_env(:rc, :snapshot_backend, :s3)
    assert {:skip, :not_local} = Keep.keep(ctx.instance.id)
    Application.put_env(:rc, :snapshot_backend, :local)

    Application.delete_env(:rc, :archive_keep_dir)
    assert {:skip, :disabled} = Keep.keep(ctx.instance.id)
  end

  test "reports a snapshot file that is gone", ctx do
    make_official(ctx.instance)
    autosave(ctx.instance, ctx.snapshot_dir, "snapshot-#{ctx.instance.id}-1", ago(600))
    File.rm!(Path.join(ctx.snapshot_dir, "snapshot-#{ctx.instance.id}-1"))

    assert {:error, {:enoent, _source, _dest}} = Keep.keep(ctx.instance.id)
  end

  test "keep_async never raises into the caller, even without a task supervisor", ctx do
    # Disabled, so the started task returns before touching the DB and
    # cannot outlive the test's sandbox.
    Application.delete_env(:rc, :archive_keep_dir)
    assert Keep.keep_async(ctx.instance.id) == :ok

    sup = Process.whereis(RC.TaskSupervisor)
    :erlang.unregister(RC.TaskSupervisor)

    try do
      assert Keep.keep_async(ctx.instance.id) == :ok
    after
      Process.register(sup, RC.TaskSupervisor)
    end
  end
end

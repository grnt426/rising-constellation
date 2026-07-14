defmodule RC.InstanceBootRestoreTest do
  @moduledoc """
  Candidate selection for boot-time instance restore. The selection
  predicate is where the risk lives: restoring an instance an operator
  stopped on purpose, or one without a snapshot, would be worse than
  the outage it prevents. The restore action itself reuses the
  battle-tested RC.Instances.restore_instance/2 path.
  """

  use RC.DataCase

  import Ecto.Query

  alias RC.InstanceBootRestore

  defp make_instance(_) do
    %{instance: instance, account: account} = RC.ScenarioFixtures.instance_fixture()
    %{instance: instance, account: account}
  end

  # Simulates the boot status-fixer's demotion: a running-history row,
  # then a not_running row stamped `ago_seconds` in the past.
  # create_instance_state/1 also syncs instances.state via its Multi.
  defp demote(%{instance: instance, account: account}, previous_state, ago_seconds) do
    # The fixture's instance creation writes its own state rows stamped
    # "now" — push everything pre-existing into the past so the two
    # rows we add below are genuinely the newest, as they are in prod.
    now = DateTime.utc_now()

    from(s in RC.Instances.InstanceState, where: s.instance_id == ^instance.id)
    |> RC.Repo.update_all(set: [inserted_at: DateTime.add(now, -ago_seconds - 300, :second)])

    {:ok, %{instance_state: prev}} =
      RC.Instances.create_instance_state(%{
        instance_id: instance.id,
        state: previous_state,
        account_id: account.id
      })

    {:ok, %{instance_state: ns}} =
      RC.Instances.create_instance_state(%{
        instance_id: instance.id,
        state: "not_running",
        account_id: account.id
      })

    # Keep chronology consistent with reality: the previous state
    # strictly precedes the demotion row.
    prev_stamp = DateTime.add(now, -ago_seconds - 60, :second)
    ns_stamp = DateTime.add(now, -ago_seconds, :second)

    from(s in RC.Instances.InstanceState, where: s.id == ^prev.id)
    |> RC.Repo.update_all(set: [inserted_at: prev_stamp])

    from(s in RC.Instances.InstanceState, where: s.id == ^ns.id)
    |> RC.Repo.update_all(set: [inserted_at: ns_stamp])
  end

  defp add_snapshot(instance) do
    {:ok, _} = RC.InstanceSnapshots.insert(%{name: "snapshot-test-#{instance.id}", size: 1, instance_id: instance.id})
  end

  describe "candidate_ids/1" do
    setup [:make_instance]

    test "freshly demoted running instance with a snapshot is a candidate", %{instance: instance} = ctx do
      demote(ctx, "running", 30)
      add_snapshot(instance)

      assert instance.id in InstanceBootRestore.candidate_ids()
    end

    test "previously paused instances are candidates too", %{instance: instance} = ctx do
      demote(ctx, "paused", 30)
      add_snapshot(instance)

      assert instance.id in InstanceBootRestore.candidate_ids()
    end

    test "an instance stopped long ago stays down", %{instance: instance} = ctx do
      demote(ctx, "running", 2 * 60 * 60)
      add_snapshot(instance)

      refute instance.id in InstanceBootRestore.candidate_ids()
    end

    test "maintenance-history instances are excluded (restore_instance CaseClauseError guard)",
         %{instance: instance} = ctx do
      demote(ctx, "maintenance", 30)
      add_snapshot(instance)

      refute instance.id in InstanceBootRestore.candidate_ids()
    end

    test "no snapshot, no restore", %{instance: instance} = ctx do
      demote(ctx, "running", 30)

      refute instance.id in InstanceBootRestore.candidate_ids()
    end

    test "bot-only instances are left to RC.BotOnlyInstanceRestart", %{instance: instance} = ctx do
      demote(ctx, "running", 30)
      add_snapshot(instance)

      from(i in RC.Instances.Instance, where: i.id == ^instance.id)
      |> RC.Repo.update_all(set: [is_bot_only: true])

      refute instance.id in InstanceBootRestore.candidate_ids()
    end
  end
end

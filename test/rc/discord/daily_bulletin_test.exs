defmodule RC.Discord.DailyBulletinTest do
  use RC.DataCase

  import Ecto.Query
  import RC.ScenarioFixtures

  alias RC.Discord.BulletinEvent
  alias RC.Discord.DailyBulletin
  alias RC.Instances.Instance
  alias RC.Repo

  defp add_event(instance) do
    %BulletinEvent{}
    |> BulletinEvent.changeset(%{
      instance_id: instance.id,
      kind: "raid",
      payload: %{"system_name" => "X", "faction" => "ark"}
    })
    |> Repo.insert!()
  end

  describe "prune_ended_matches/0" do
    # Regression: the first version used a left join inside delete_all,
    # which Postgres rejects ("supports only inner joins on delete_all")
    # — every sweep logged a failure and nothing was ever pruned.
    test "deletes events for ended or decided matches, keeps live ones" do
      %{instance: live} = instance_fixture()
      %{instance: ended} = instance_fixture()
      %{instance: decided} = instance_fixture()

      add_event(live)
      add_event(ended)
      add_event(decided)

      Repo.update_all(from(i in Instance, where: i.id == ^ended.id), set: [state: "ended"])
      Repo.insert!(%RC.Instances.Victory{instance_id: decided.id, victory_type: "victory_track"})

      DailyBulletin.prune_ended_matches()

      assert Repo.all(from(e in BulletinEvent, select: e.instance_id)) == [live.id]
    end
  end
end

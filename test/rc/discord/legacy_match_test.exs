defmodule RC.Discord.LegacyMatchTest do
  use RC.DataCase

  import RC.ScenarioFixtures

  alias RC.Discord.LegacyMatch
  alias RC.Instances.Instance
  alias RC.Repo

  # Eligibility for `/promote legacy` moved from a scenario-template flag
  # (`scenarios.discord_ready`) to a per-match flag (`instances.discord_ready`)
  # set on the game-setup page. These guard that the bot's eligibility query
  # and the promote gate both key off the instance flag.

  describe "list_eligible/0" do
    test "excludes an instance that is not marked discord_ready" do
      %{instance: _instance} = instance_fixture()

      assert LegacyMatch.list_eligible() == []
    end

    test "includes an instance once it is marked discord_ready" do
      %{instance: instance} = instance_fixture()

      {:ok, _} = set_discord_ready(instance, true)

      assert Enum.map(LegacyMatch.list_eligible(), & &1.id) == [instance.id]
    end

    test "still excludes a discord_ready instance once it has been promoted" do
      %{instance: instance} = instance_fixture()
      {:ok, _} = set_discord_ready(instance, true)

      # Simulate a completed promotion: a bookkeeping row exists.
      {:ok, _match} =
        %RC.Discord.Match{}
        |> RC.Discord.Match.changeset(%{
          instance_id: instance.id,
          faction_categories: %{"tetrarchy" => "1"},
          promoted_by_discord_id: "1234567890"
        })
        |> Repo.insert()

      assert LegacyMatch.list_eligible() == []
    end
  end

  describe "promote/2 eligibility gate" do
    test "rejects an instance that is not marked discord_ready before any Discord call" do
      %{instance: instance} = instance_fixture()

      assert {:error, :not_eligible} = LegacyMatch.promote(instance.id, "1234567890")
    end
  end

  # Flip discord_ready directly on the persisted row, bypassing the
  # validation-heavy create changeset.
  defp set_discord_ready(instance, value) do
    Instance
    |> Repo.get!(instance.id)
    |> Ecto.Changeset.change(discord_ready: value)
    |> Repo.update()
  end
end

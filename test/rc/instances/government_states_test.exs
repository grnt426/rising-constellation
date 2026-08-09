defmodule RC.Instances.GovernmentStatesTest do
  use RC.DataCase

  import RC.ScenarioFixtures

  alias RC.Instances.GovernmentStates

  # The write-through durability layer for faction-government/diplomacy
  # agent state: full-term round trip, monotonic upsert, and the
  # best-effort contract (a missing instances row must be a quiet no-op,
  # never a raise — headless instances take that path on every write).

  test "persist/fetch round-trips an Elixir term and upserts by rev" do
    %{instance: instance} = instance_fixture()

    government = %{
      seats: %{leader: %{player_id: 7, name: "Kurtz"}},
      treasury: %{credit: 1200, technology: 0, ideology: 40},
      rev: 3
    }

    assert :ok = GovernmentStates.persist(instance.id, 11, "government", 3, government)
    assert {3, ^government} = GovernmentStates.fetch(instance.id, 11, "government")

    # Upsert: same scope overwrites, rev moves forward.
    bumped = %{government | rev: 4, treasury: %{credit: 0, technology: 0, ideology: 40}}
    assert :ok = GovernmentStates.persist(instance.id, 11, "government", 4, bumped)
    assert {4, ^bumped} = GovernmentStates.fetch(instance.id, 11, "government")

    # Scopes are independent: another faction and the instance-scoped
    # diplomacy row (faction 0) don't collide.
    assert GovernmentStates.fetch(instance.id, 12, "government") == nil
    assert :ok = GovernmentStates.persist(instance.id, 0, "diplomacy", 1, %{relations: %{}})
    assert {1, %{relations: %{}}} = GovernmentStates.fetch(instance.id, 0, "diplomacy")
    assert {4, _} = GovernmentStates.fetch(instance.id, 11, "government")
  end

  test "persist against a nonexistent instance is a quiet no-op (headless contract)" do
    assert :ok = GovernmentStates.persist(999_999_999, 1, "government", 1, %{anything: true})
    assert GovernmentStates.fetch(999_999_999, 1, "government") == nil
  end

  test "invalid kind is rejected without raising" do
    %{instance: instance} = instance_fixture()
    assert :ok = GovernmentStates.persist(instance.id, 1, "nonsense", 1, %{})
    assert GovernmentStates.fetch(instance.id, 1, "nonsense") == nil
  end
end

defmodule Instance.StellarSystem.LocalPopulationTest do
  @moduledoc """
  The per-planet population split must follow housing, not only whole-point
  population growth. It used to be recomputed only when the system's
  workforce changed, so housing finished on a second planet sat empty until
  the next population point — in i185 a capital showed all 15 pop on one
  planet while a sibling held more housing. Each planet's population feeds
  its `body_pop` building bonuses, so the stale split also dropped output.
  """
  use ExUnit.Case, async: false

  alias Instance.StellarSystem.{ProductionQueue, StellarBody, StellarSystem, Tile}
  alias Test.FleetScenario

  setup do
    iid = System.unique_integer([:positive])
    FleetScenario.load_game_data(iid, speed: :medium, mode: :prod)
    {:ok, iid: iid}
  end

  test "a bonus recompute re-splits the workforce by planet housing", %{iid: iid} do
    # stale split: every point on the first planet
    {_, _, state} = StellarSystem.update_bonuses(system(iid, 15, [15, 0]), :test, [])

    # 10 vs 13 housing: 6.52 / 8.48 → largest remainder tops up the first
    assert Enum.map(state.bodies, & &1.population) == [7, 8]
    assert state.habitation.value == 23
  end

  test "body_pop bonuses read the refreshed split", %{iid: iid} do
    # the University sits on the second planet, whose stale population is 0;
    # its output must match a system whose split was already right
    {_, _, stale} = StellarSystem.update_bonuses(system(iid, 15, [15, 0]), :test, [])
    {_, _, settled} = StellarSystem.update_bonuses(system(iid, 15, [7, 8]), :test, [])

    assert stale.technology.value == settled.technology.value
  end

  # Two open planets: an Infrastructure (10 housing) on the first; an
  # Infrastructure, Housing (3) and University on the second.
  defp system(iid, workforce, [first_pop, second_pop]) do
    struct(StellarSystem, %{
      id: 997,
      name: "local-population-test",
      status: :inhabited_player,
      instance_id: iid,
      bodies: [
        body(1, first_pop, [:infra_open]),
        body(2, second_pop, [:infra_open, :hab_open, :university_open])
      ],
      queue: ProductionQueue.new(),
      siege: nil,
      owner: nil,
      workforce: workforce,
      population: Core.DynamicValue.new(workforce + 0.5),
      remove_contact: Core.DynamicValue.new(0.0),
      happiness_penalties: [],
      ai_profile: :production
    })
  end

  defp body(id, population, building_keys) do
    tiles =
      building_keys
      |> Enum.with_index(1)
      |> Enum.map(fn {key, tile_id} -> Tile.new(tile_id, :primary) |> Tile.force_building(key, 1) end)

    struct(StellarBody, %{
      id: id,
      uid: "#{id}",
      type: :habitable_planet,
      name: "Planet #{id}",
      industrial_factor: 3,
      technological_factor: 3,
      activity_factor: 3,
      population: population,
      bodies: [],
      tiles: tiles
    })
  end
end

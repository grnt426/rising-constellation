defmodule Instance.StellarSystem.NewBuildingLevelTest do
  @moduledoc """
  A new building always starts at level 1. Before the guard in
  `StellarSystem.order_building_production/2`, an order for a higher level on
  an empty tile was accepted: it queued that level's production cost, the
  player paid that level's credit (`Player.order_building/5` prices the
  requested level) and the building still finished at level 1
  (`Tile.put_building/1`). The UI only ever sends level 1 for a new building,
  so only a crafted client could reach it (found while verifying the help
  manual's Buildings pages, 2026-09-14).
  """
  use ExUnit.Case, async: false

  alias Instance.StellarSystem.{ProductionQueue, StellarBody, StellarSystem, Tile}
  alias Test.FleetScenario

  setup do
    iid = System.unique_integer([:positive])
    FleetScenario.load_game_data(iid, speed: :medium, mode: :prod)
    {:ok, iid: iid}
  end

  test "a new building ordered above level 1 is refused", %{iid: iid} do
    state = system(iid)

    for level <- [2, 3] do
      assert {:error, :new_building_must_be_level_one} =
               StellarSystem.order_building_production(state, {"1", 2, :mine_dome, level})
    end
  end

  test "a new building at level 1 is still accepted", %{iid: iid} do
    state = system(iid)

    assert {:ok, ordered} = StellarSystem.order_building_production(state, {"1", 2, :mine_dome, 1})
    refute ordered.queue == state.queue
  end

  # One barren planet: its infrastructure building at level 3 (so a level 3
  # order is not refused for the infrastructure cap instead) and a free tile.
  defp system(iid) do
    tiles = [
      Tile.new(1, :primary) |> Tile.force_building(:infra_dome, 3),
      Tile.new(2, :primary)
    ]

    body =
      struct(StellarBody, %{
        id: 1,
        uid: "1",
        type: :sterile_planet,
        name: "Level test",
        industrial_factor: 3,
        technological_factor: 3,
        activity_factor: 3,
        population: 10,
        bodies: [],
        tiles: tiles
      })

    struct(StellarSystem, %{
      id: 997,
      name: "new-building-level-test",
      status: :inhabited_player,
      instance_id: iid,
      bodies: [body],
      queue: ProductionQueue.new(),
      siege: nil,
      owner: nil,
      workforce: 20,
      used_workforce: 0,
      habitation: %Core.Value{value: 0, details: %{}},
      happiness: %Core.Value{value: 50, details: %{}},
      population: Core.DynamicValue.new(0.0),
      ai_profile: :production
    })
  end
end

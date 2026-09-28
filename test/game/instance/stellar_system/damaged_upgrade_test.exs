defmodule Instance.StellarSystem.DamagedUpgradeTest do
  @moduledoc """
  A damaged building must be repaired before it can be upgraded. Planning
  (`Tile.plan_building/2`) and finishing (`Tile.put_building/1`) an upgrade
  have no clause for a damaged tile, so before the guard in
  `StellarSystem.order_building_production/2` such an order was accepted,
  charged to the player, sat in the queue and never raised the level. The UI
  hides the Upgrade button on a damaged tile, so only a crafted client could
  reach it (found by the help manual's Buildings planner, 2026-09-14).
  """
  use ExUnit.Case, async: false

  alias Instance.StellarSystem.{ProductionQueue, StellarBody, StellarSystem, Tile}
  alias Test.FleetScenario

  setup do
    iid = System.unique_integer([:positive])
    FleetScenario.load_game_data(iid, speed: :medium, mode: :prod)
    {:ok, iid: iid}
  end

  test "an upgrade order on a damaged building is refused", %{iid: iid} do
    state = system(iid, :damaged)

    assert {:error, :cannot_upgrade_damaged_building} =
             StellarSystem.order_building_production(state, {"1", 2, :hab_dome, 2})
  end

  test "an upgrade order on a built building still goes through", %{iid: iid} do
    state = system(iid, :built)

    assert {:ok, ordered} = StellarSystem.order_building_production(state, {"1", 2, :hab_dome, 2})
    tile = ordered.bodies |> hd() |> Map.fetch!(:tiles) |> Enum.find(&(&1.id == 2))
    assert tile.construction_status != :none
    refute ordered.queue == state.queue
  end

  # One barren planet: its infrastructure building at level 2 (so level 2 is
  # not capped) and a Capsule City at level 1 in the given status.
  defp system(iid, status) do
    tiles = [
      Tile.new(1, :primary) |> Tile.force_building(:infra_dome, 2),
      Tile.new(2, :primary) |> Tile.force_building(:hab_dome, 1) |> Map.put(:building_status, status),
      Tile.new(3, :primary)
    ]

    body =
      struct(StellarBody, %{
        id: 1,
        uid: "1",
        type: :sterile_planet,
        name: "Upgrade test",
        industrial_factor: 3,
        technological_factor: 3,
        activity_factor: 3,
        population: 10,
        bodies: [],
        tiles: tiles
      })

    struct(StellarSystem, %{
      id: 998,
      name: "damaged-upgrade-test",
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

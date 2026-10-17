defmodule Daily.HomePlanetTest do
  @moduledoc """
  A daily system must give the player a home planet with room to build.
  2026-12-22 rolled no planet with tiles at all, only gas giants and
  asteroid belts, and the old guarantee relabelled a tileless giant as the
  habitable planet: no infrastructure, no housing, nothing to build.
  """
  use RC.DataCase, async: false

  @moduletag timeout: 180_000

  test "a system that rolled only tileless bodies gets a real habitable planet" do
    date = "2026-12-22"
    {:ok, %{instance_id: iid, player_id: player_id}} = Daily.Boot.boot_for(date)
    on_exit(fn -> Instance.Manager.destroy(iid) end)

    {:ok, player} = Game.call(iid, :player, player_id, :get_state)
    [home] = player.stellar_systems
    {:ok, system} = Game.call(iid, :stellar_system, home.id, :get_state)

    [planet] = Enum.filter(system.bodies, &(&1.type == :habitable_planet))
    assert length(planet.tiles) >= 6

    # the claim colonized it: infrastructure on tile 1, housing for the settlers
    assert %{building_key: :infra_open, building_status: :built} = Enum.find(planet.tiles, &(&1.id == 1))
    assert system.habitation.value >= 10

    # nothing left of the old relabel: every other planet-sized body is what it rolled
    refute Enum.any?(system.bodies, &(&1.type == :habitable_planet and &1.tiles == []))
  end
end

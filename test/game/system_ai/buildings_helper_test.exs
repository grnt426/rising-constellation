defmodule SystemAI.BuildingsHelperTest do
  @moduledoc """
  The system AI (neutral + dominion auto-construction) must never draw the
  wonder-tier buildings (:monument_dome / :high_factory_dome) from its
  building pools, in any biome, at any speed.
  """
  use ExUnit.Case, async: false

  alias SystemAI.BuildingsHelper

  @excluded [:monument_dome, :high_factory_dome]

  setup do
    iid = System.unique_integer([:positive])
    Data.Data.insert(iid, [speed: :medium, mode: :prod], :shared)
    on_exit(fn -> Data.Data.clear(iid) end)
    {:ok, iid: iid}
  end

  test "wonders are excluded from every biome pool", %{iid: iid} do
    for biome <- [:open, :dome, :orbital] do
      keys = BuildingsHelper.get_biome_buildings(biome, iid) |> Enum.map(& &1.key)

      for excluded <- @excluded do
        refute excluded in keys, "#{excluded} must not be in the #{biome} AI pool"
      end

      assert keys != [], "#{biome} pool should still contain buildings"
    end
  end

  test "wonders are excluded from the AI upgrade path", %{iid: iid} do
    # a body with an already-built wonder (e.g. a player system abandoned back
    # to neutral) must not be upgrade-eligible for the AI
    bodies = [
      %{
        uid: 1,
        type: :sterile_planet,
        tiles: [
          %{id: 1, body_id: 1, building_status: :built, building_key: :monument_dome, building_level: 1},
          %{id: 2, body_id: 1, building_status: :built, building_key: :high_factory_dome, building_level: 1}
        ]
      }
    ]

    for category <- [:production, :credit, :technologic, :ideologic, :defense] do
      assert SystemAI.Helper.get_upgradable_tiles(bodies, iid, category) == []
    end
  end

  test "get_all_buildings still serves the wonders (non-AI lookups)", %{iid: iid} do
    keys = BuildingsHelper.get_all_buildings(iid) |> Enum.map(& &1.key)

    for excluded <- @excluded do
      assert excluded in keys
    end
  end
end

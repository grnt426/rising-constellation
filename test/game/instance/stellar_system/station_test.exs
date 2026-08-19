defmodule Instance.StellarSystem.StationTest do
  use ExUnit.Case, async: true

  alias Instance.StellarSystem.Station
  alias Instance.StellarSystem.StellarSystem

  @moduledoc """
  Station geometry + the system-side order/construction path
  (docs/faction-buildings.md), on partial StellarSystem structs (the
  established pattern here: `struct/2` bypasses `enforce: true` so no
  instance boot is needed; only Data.Querier content is real).
  """

  @test_instance_id 999_999_999

  setup_all do
    Data.Data.insert(@test_instance_id, speed: :fast, mode: :prod)
    on_exit(fn -> Data.Data.clear(@test_instance_id) end)
    :ok
  end

  defp system(overrides \\ %{}) do
    base = %{
      id: 77,
      instance_id: @test_instance_id,
      status: :inhabited_player,
      owner: struct(Instance.StellarSystem.Player, %{id: 9, faction_id: 1, faction: :myrmezir}),
      siege: nil,
      production: %Core.Value{value: 800, details: %{}},
      station: nil
    }

    struct(StellarSystem, Map.merge(base, overrides))
  end

  describe "Station.covered_slots/2" do
    test "1×1 fits every slot" do
      for anchor <- 0..3 do
        assert {:ok, [^anchor]} = Station.covered_slots(%{cols: 1, rows: 1}, anchor)
      end
    end

    test "2×1 fits row starts only" do
      assert {:ok, [0, 1]} = Station.covered_slots(%{cols: 2, rows: 1}, 0)
      assert {:ok, [2, 3]} = Station.covered_slots(%{cols: 2, rows: 1}, 2)
      assert :error = Station.covered_slots(%{cols: 2, rows: 1}, 1)
      assert :error = Station.covered_slots(%{cols: 2, rows: 1}, 3)
    end

    test "1×2 (vertical) fits top-row anchors only" do
      assert {:ok, [0, 2]} = Station.covered_slots(%{cols: 1, rows: 2}, 0)
      assert {:ok, [1, 3]} = Station.covered_slots(%{cols: 1, rows: 2}, 1)
      assert :error = Station.covered_slots(%{cols: 1, rows: 2}, 2)
    end

    test "2×2 fits only anchor 0; out-of-range anchors are errors" do
      assert {:ok, [0, 1, 2, 3]} = Station.covered_slots(%{cols: 2, rows: 2}, 0)
      assert :error = Station.covered_slots(%{cols: 2, rows: 2}, 1)
      assert :error = Station.covered_slots(%{cols: 2, rows: 2}, 4)
      assert :error = Station.covered_slots(%{cols: 2, rows: 2}, -1)
    end
  end

  describe "order_station_building/4" do
    test "places a new construction on free slots" do
      assert {:ok, state, 1} = StellarSystem.order_station_building(system(), :training_center, 0, 1)

      station = Map.get(state, :station)

      assert %{key: :training_center, level: 1, slots: [0, 1], kind: :new, remaining_labor: 48_000} =
               station.construction
    end

    test "control gates: dominion, neutral, wrong faction, siege" do
      assert {:error, :not_player_controlled} =
               StellarSystem.order_station_building(system(%{status: :inhabited_dominion}), :training_center, 0, 1)

      assert {:error, :not_faction_system} =
               StellarSystem.order_station_building(system(), :training_center, 0, 2)

      assert {:error, :no_production_under_siege} =
               StellarSystem.order_station_building(
                 system(%{siege: struct(Instance.StellarSystem.Siege, %{})}),
                 :training_center,
                 0,
                 1
               )
    end

    test "one construction at a time, and slots must not overlap" do
      {:ok, state, 1} = StellarSystem.order_station_building(system(), :training_center, 0, 1)

      assert {:error, :station_busy} =
               StellarSystem.order_station_building(state, :cyber_command, 0, 1)

      # finish the training center, then a 2×2 must be refused (overlap)
      {station, _built} = Station.add_labor(Map.get(state, :station), 48_000)
      state = Map.put(state, :station, station)

      assert {:error, :slots_occupied} =
               StellarSystem.order_station_building(state, :cyber_command, 0, 1)
    end

    test "re-ordering an existing building is an upgrade, capped at max level" do
      {:ok, state, 1} = StellarSystem.order_station_building(system(), :training_center, 0, 1)
      {station, built} = Station.add_labor(Map.get(state, :station), 48_000)
      assert built.status == :built
      state = Map.put(state, :station, station)

      assert {:ok, state, 2} = StellarSystem.order_station_building(state, :training_center, 0, 1)
      assert %{kind: :upgrade, level: 2, building_id: id} = Map.get(state, :station).construction
      assert id == built.id

      # jump the level to max and verify the cap
      station = Map.get(state, :station)
      station = %{station | construction: nil, buildings: Enum.map(station.buildings, &%{&1 | level: 5})}
      state = Map.put(state, :station, station)

      assert {:error, :max_level_reached} =
               StellarSystem.order_station_building(state, :training_center, 0, 1)
    end

    test "gateway spans all four slots" do
      {:ok, state, 1} = StellarSystem.order_station_building(system(), :gateway, 0, 1)
      assert Map.get(state, :station).construction.slots == [0, 1, 2, 3]

      assert {:error, :invalid_anchor} =
               StellarSystem.order_station_building(system(), :gateway, 1, 1)
    end
  end

  describe "construction + cancel" do
    test "add_labor completes exactly at zero and appends the building" do
      {:ok, state, 1} = StellarSystem.order_station_building(system(), :training_center, 0, 1)
      station = Map.get(state, :station)

      {station, nil} = Station.add_labor(station, 47_999)
      assert station.construction.remaining_labor == 1

      {station, built} = Station.add_labor(station, 1)
      assert station.construction == nil
      assert [%{key: :training_center, level: 1, status: :built, slots: [0, 1]}] = station.buildings
      assert built.faction_id == 1
    end

    test "cancel clears the construction and reports what to refund" do
      {:ok, state, 1} = StellarSystem.order_station_building(system(), :training_center, 0, 1)

      assert {:error, :not_faction_construction} = StellarSystem.cancel_station_construction(state, 2)

      assert {:ok, state, %{key: :training_center, level: 1, kind: :new}} =
               StellarSystem.cancel_station_construction(state, 1)

      assert Map.get(state, :station).construction == nil
      assert {:error, :no_construction} = StellarSystem.cancel_station_construction(state, 1)
    end
  end

  describe "resolve_station_effects/2 (Training Center drip)" do
    defp trained_system(overrides \\ %{}) do
      station = %Station{
        buildings: [%{id: 1, key: :training_center, level: 3, faction_id: 1, slots: [0, 1], status: :built}],
        construction: nil,
        powered: Map.get(overrides, :powered, true),
        next_building_id: 2,
        training_elapsed: 0.0
      }

      station =
        case Map.get(overrides, :building_status) do
          nil -> station
          status -> %{station | buildings: Enum.map(station.buildings, &%{&1 | status: status})}
        end

      system(%{
        station: station,
        characters:
          Map.get(overrides, :characters, [
            %{id: 51, owner: %{faction_id: 1}},
            %{id: 52, owner: %{faction_id: 2}}
          ]),
        governor: nil
      })
    end

    test "at the interval, tags a same-faction agent with level XP and rolls the accumulator" do
      # :fast content → training_center_interval = 8
      {change, _notifs, state} =
        StellarSystem.resolve_station_effects({MapSet.new(), [], trained_system()}, 9)

      # the only same-faction candidate is 51 (52 belongs to faction 2);
      # XP = building level
      assert MapSet.member?(change, {:agent_trained, 51, 3})
      assert Map.get(state, :station).training_elapsed == 1

      # below the interval: accumulate, no grant
      {change, _notifs, state} =
        StellarSystem.resolve_station_effects({MapSet.new(), [], state}, 3)

      assert Enum.empty?(change)
      assert Map.get(state, :station).training_elapsed == 4
    end

    test "no grant while unpowered, disabled, or with no same-faction agent present" do
      {change, _n, _s} =
        StellarSystem.resolve_station_effects({MapSet.new(), [], trained_system(%{powered: false})}, 9)

      assert Enum.empty?(change)

      {change, _n, _s} =
        StellarSystem.resolve_station_effects(
          {MapSet.new(), [], trained_system(%{building_status: :disabled})},
          9
        )

      assert Enum.empty?(change)

      {change, _n, state} =
        StellarSystem.resolve_station_effects(
          {MapSet.new(), [], trained_system(%{characters: [%{id: 52, owner: %{faction_id: 2}}]})},
          9
        )

      assert Enum.empty?(change)
      # the clock still rolls — an empty room doesn't bank training time
      assert Map.get(state, :station).training_elapsed == 1
    end
  end

  describe "Station.sync_statuses/3" do
    test "control changes flip building statuses both ways" do
      station = %Station{
        buildings: [%{id: 1, key: :training_center, level: 2, faction_id: 1, slots: [0, 1], status: :built}],
        construction: nil,
        powered: true,
        next_building_id: 2
      }

      captor = struct(Instance.StellarSystem.Player, %{id: 5, faction_id: 2, faction: :ark})
      {station, changed} = Station.sync_statuses(station, :inhabited_player, captor)
      assert [%{status: :disabled}] = changed
      assert [%{status: :disabled}] = station.buildings

      # captor's dominion keeps it disabled, no flip event
      {station, []} = Station.sync_statuses(station, :inhabited_dominion, captor)

      # the owning faction retakes direct control
      liberator = struct(Instance.StellarSystem.Player, %{id: 9, faction_id: 1, faction: :myrmezir})
      {station, changed} = Station.sync_statuses(station, :inhabited_player, liberator)
      assert [%{status: :built}] = changed
      assert [%{status: :built}] = station.buildings
    end
  end
end

defmodule Instance.Faction.GovernmentStationTest do
  use ExUnit.Case, async: true

  alias Instance.Faction.Government

  @moduledoc """
  Engine-level tests for the station-building government ops
  (docs/faction-buildings.md): ordering (seat/patent/treasury gates and
  the check→commit conversation with the system agent, stubbed through
  ctx.station_call), cancel refunds, demolition, the billing registry,
  and the all-or-nothing upkeep power cycle.
  """

  @test_instance_id 999_999_999
  @founding 10

  setup_all do
    Data.Data.insert(@test_instance_id, speed: :fast, mode: :prod)
    on_exit(fn -> Data.Data.clear(@test_instance_id) end)
    :ok
  end

  defp players(count) do
    Enum.map(1..count, fn i -> %Instance.Faction.Player{id: i, name: "Player #{i}"} end)
  end

  defp ctx(faction_key, players, opts \\ []) do
    %{
      instance_id: @test_instance_id,
      faction_id: 1,
      faction_key: faction_key,
      players: players,
      constants: %{
        government_founding_duration: @founding,
        government_election_duration: 10,
        government_election_min_duration: 5,
        government_approval_duration: 10,
        government_term_myrmezir: 100,
        government_term_synelle: 160,
        government_cardan_quorum_pct: 5,
        government_cardan_max_rounds: 3,
        government_tax_cap: 10,
        government_max_laws: 2,
        government_law_cooldown: 10,
        government_lockout_duration: 30,
        market_taxe: 0.1
      },
      faction_ideology_income: fn -> 100 end,
      faction_credit_total: fn -> 100_000 end,
      active_player_ids: fn -> Enum.map(players, & &1.id) end,
      active_player_count: fn -> length(players) end,
      seat_holder_status: fn _player_id -> :ok end,
      station_call: Keyword.get(opts, :station_call, fn _system_id, _message -> {:error, :system_not_found} end)
    }
  end

  # A running government with seated cabinet: player 1 leader,
  # player 2 economy, player 3 military — seated directly (elections
  # are covered by government_test.exs).
  defp running_government(ctx, opts \\ []) do
    government = Government.new(ctx)

    %{
      government
      | phase: :running,
        seats: %{
          leader: %{player_id: 1, name: "Player 1"},
          economy: %{player_id: 2, name: "Player 2"},
          military: %{player_id: 3, name: "Player 3"}
        },
        treasury: Keyword.get(opts, :treasury, %{credit: 3_000_000, technology: 100_000, ideology: 50_000}),
        faction_patents: Keyword.get(opts, :patents, [:research_compact, :orbital_engineering, :gateway_theory])
    }
  end

  # station_call stub that scripts the check → commit conversation and
  # records every message for assertions.
  defp scripted_station_call(script) do
    recorder = :ets.new(:calls, [:public])

    call = fn system_id, message ->
      :ets.insert(recorder, {:erlang.unique_integer([:monotonic]), system_id, message})

      key =
        case message do
          {:station_check_order, _, _, _} -> :check
          {:station_order, _, _, _} -> :order
          {:station_cancel, _} -> :cancel
          {:station_demolish, _, _} -> :demolish
          :get_state -> :get_state
        end

      Map.get(script, key, {:error, :unexpected_call})
    end

    messages = fn ->
      recorder |> :ets.tab2list() |> Enum.sort() |> Enum.map(fn {_seq, sid, msg} -> {sid, msg} end)
    end

    {call, messages}
  end

  describe "order_station_building/6" do
    test "military seat orders a gateway: check, commit, treasury debit, event" do
      {call, messages} = scripted_station_call(%{check: {:ok, 1}, order: {:ok, 1}})
      ctx = ctx(:myrmezir, players(5), station_call: call)
      government = running_government(ctx)

      assert {:ok, government, events} =
               Government.order_station_building(government, 3, 77, :gateway, 0, ctx)

      assert government.treasury.credit == 1_000_000
      assert government.treasury.technology == 25_000
      assert government.treasury.ideology == 30_000

      assert [%{type: :station_ordered, system_id: 77, key: :gateway, level: 1, by: 3}] = events

      assert [
               {77, {:station_check_order, :gateway, 0, 1}},
               {77, {:station_order, :gateway, 0, 1}}
             ] = messages.()
    end

    test "the wrong seat is refused per the building's seat" do
      {call, _} = scripted_station_call(%{check: {:ok, 1}, order: {:ok, 1}})
      ctx = ctx(:myrmezir, players(5), station_call: call)
      government = running_government(ctx)

      # economy head ordering the military's gateway
      assert {:error, :not_head_of_military} =
               Government.order_station_building(government, 2, 77, :gateway, 0, ctx)

      # military head ordering the economy's training center
      assert {:error, :not_head_of_economy} =
               Government.order_station_building(government, 3, 77, :training_center, 0, ctx)

      # rank-and-file member
      assert {:error, :not_head_of_military} =
               Government.order_station_building(government, 5, 77, :gateway, 0, ctx)
    end

    test "tetrarchy leader may order through the royal prerogative, billing tyranny" do
      {call, _} = scripted_station_call(%{check: {:ok, 1}, order: {:ok, 1}})
      ctx = ctx(:tetrarchy, players(5), station_call: call)
      government = running_government(ctx)

      assert {:ok, government, events} =
               Government.order_station_building(government, 1, 77, :gateway, 0, ctx)

      assert Enum.any?(events, &(&1.type == :leader_overreach))
      assert Government.overreach_total(government) > 0
    end

    test "the gating patent must be owned" do
      {call, _} = scripted_station_call(%{check: {:ok, 1}, order: {:ok, 1}})
      ctx = ctx(:myrmezir, players(5), station_call: call)
      government = running_government(ctx, patents: [:research_compact])

      assert {:error, :patent_not_unlocked} =
               Government.order_station_building(government, 3, 77, :gateway, 0, ctx)
    end

    test "the treasury must cover every resource of the level cost" do
      {call, _} = scripted_station_call(%{check: {:ok, 1}, order: {:ok, 1}})
      ctx = ctx(:myrmezir, players(5), station_call: call)
      government = running_government(ctx, treasury: %{credit: 3_000_000, technology: 100, ideology: 50_000})

      assert {:error, :treasury_insufficient} =
               Government.order_station_building(government, 3, 77, :gateway, 0, ctx)
    end

    test "system-side rejections pass through untouched, before any debit" do
      {call, _} = scripted_station_call(%{check: {:error, :slots_occupied}})
      ctx = ctx(:myrmezir, players(5), station_call: call)
      government = running_government(ctx)

      assert {:error, :slots_occupied} =
               Government.order_station_building(government, 3, 77, :gateway, 0, ctx)

      assert government.treasury.credit == 3_000_000
    end

    test "a level mismatch between check and commit rolls the placement back" do
      {call, messages} = scripted_station_call(%{check: {:ok, 1}, order: {:ok, 2}, cancel: {:ok, %{}}})
      ctx = ctx(:myrmezir, players(5), station_call: call)
      government = running_government(ctx)

      assert {:error, :station_conflict} =
               Government.order_station_building(government, 3, 77, :gateway, 0, ctx)

      assert Enum.any?(messages.(), fn {_sid, msg} -> msg == {:station_cancel, 1} end)
    end

    test "unknown building keys are refused" do
      ctx = ctx(:myrmezir, players(5))
      government = running_government(ctx)

      assert {:error, :unknown_key} =
               Government.order_station_building(government, 3, 77, :monument_dome, 0, ctx)
    end
  end

  describe "cancel_station_building/4" do
    test "cancels the running construction and refunds the full level cost" do
      station = %Instance.StellarSystem.Station{
        buildings: [],
        construction: %{
          building_id: 1,
          key: :training_center,
          level: 1,
          faction_id: 1,
          slots: [0, 1],
          total_labor: 48_000,
          remaining_labor: 20_000,
          kind: :new
        },
        powered: true,
        next_building_id: 2
      }

      {call, _} =
        scripted_station_call(%{
          get_state: {:ok, %{station: station}},
          cancel: {:ok, %{key: :training_center, level: 1, kind: :new}}
        })

      ctx = ctx(:myrmezir, players(5), station_call: call)
      government = running_government(ctx, treasury: %{credit: 0, technology: 0, ideology: 0})

      assert {:ok, government, events} =
               Government.cancel_station_building(government, 2, 77, ctx)

      assert government.treasury == %{credit: 300_000, technology: 12_000, ideology: 10_000}
      assert Enum.any?(events, &(&1.type == :station_cancelled))
    end

    test "no construction → :no_construction" do
      {call, _} = scripted_station_call(%{get_state: {:ok, %{station: nil}}})
      ctx = ctx(:myrmezir, players(5), station_call: call)
      government = running_government(ctx)

      assert {:error, :no_construction} = Government.cancel_station_building(government, 2, 77, ctx)
    end
  end

  describe "demolish_station_building/5" do
    test "demolishes and drops the registry entry" do
      building = %{id: 4, key: :gateway, level: 1, faction_id: 1, slots: [0, 1, 2, 3], status: :built}

      {call, _} =
        scripted_station_call(%{
          get_state: {:ok, %{station: %Instance.StellarSystem.Station{buildings: [building]}}},
          demolish: {:ok, %{id: 4, key: :gateway, level: 1}}
        })

      ctx = ctx(:myrmezir, players(5), station_call: call)

      government =
        running_government(ctx)
        |> Government.station_registry_complete(77, building)

      assert {:ok, government, events} =
               Government.demolish_station_building(government, 3, 77, 4, ctx)

      assert Map.get(government, :station_buildings) == []
      assert Enum.any?(events, &(&1.type == :station_demolished))
    end
  end

  describe "registry + upkeep tick" do
    test "completion upserts; upgrades replace in place" do
      ctx = ctx(:myrmezir, players(5))
      government = running_government(ctx)

      building = %{id: 4, key: :training_center, level: 1, faction_id: 1, slots: [0, 1], status: :built}
      government = Government.station_registry_complete(government, 77, building)

      assert [%{system_id: 77, building_id: 4, key: :training_center, level: 1, status: :built}] =
               Map.get(government, :station_buildings)

      government = Government.station_registry_complete(government, 77, %{building | level: 2})

      assert [%{level: 2}] = Map.get(government, :station_buildings)
    end

    test "upkeep debits rate × elapsed for built entries only" do
      ctx = ctx(:myrmezir, players(5))
      government = running_government(ctx, treasury: %{credit: 10_000, technology: 10_000, ideology: 10_000})

      government =
        government
        |> Government.station_registry_complete(77, %{
          id: 1,
          key: :training_center,
          level: 1,
          faction_id: 1,
          slots: [0, 1],
          status: :built
        })
        |> Government.station_registry_status(77, 1, :disabled)
        |> Government.station_registry_complete(78, %{
          id: 2,
          key: :training_center,
          level: 1,
          faction_id: 1,
          slots: [0, 1],
          status: :built
        })

      # only system 78 bills: upkeep 100c/20t/30i per ut × 10 ut
      {government, events} = Government.advance(government, 10, ctx)

      assert government.treasury.credit == 9_000
      assert government.treasury.technology == 9_800
      assert government.treasury.ideology == 9_700
      refute Enum.any?(events, &(&1.type == :station_power))
      assert Map.get(government, :station_powered) == true
    end

    test "a dry treasury powers every station down, recovery powers back up" do
      ctx = ctx(:myrmezir, players(5))
      government = running_government(ctx, treasury: %{credit: 500, technology: 10_000, ideology: 10_000})

      government =
        Government.station_registry_complete(government, 77, %{
          id: 1,
          key: :training_center,
          level: 1,
          faction_id: 1,
          slots: [0, 1],
          status: :built
        })

      # 10 ut of upkeep = 1000 credit > 500 in the till
      {government, events} = Government.advance(government, 10, ctx)

      assert Map.get(government, :station_powered) == false

      assert [%{type: :station_power, powered: false, system_ids: [77]}] =
               Enum.filter(events, &(&1.type == :station_power))

      # nothing was paid
      assert government.treasury.credit == 500

      # refill and tick again → power restored and upkeep paid
      government = %{government | treasury: %{credit: 5_000, technology: 10_000, ideology: 10_000}}
      {government, events} = Government.advance(government, 10, ctx)

      assert Map.get(government, :station_powered) == true
      assert [%{type: :station_power, powered: true}] = Enum.filter(events, &(&1.type == :station_power))
      assert government.treasury.credit == 4_000
    end
  end

  describe "backfill/1" do
    test "restores pre-station snapshots without the new fields" do
      ctx = ctx(:myrmezir, players(5))
      government = running_government(ctx)

      stripped =
        government
        |> Map.delete(:station_buildings)
        |> Map.delete(:station_powered)

      backfilled = Government.backfill(stripped)

      assert Map.get(backfilled, :station_buildings) == []
      assert Map.get(backfilled, :station_powered) == true
    end
  end
end

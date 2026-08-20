defmodule Instance.Faction.GovernmentGatewayTest do
  use ExUnit.Case, async: true

  alias Instance.Faction.Government

  @moduledoc """
  Engine tests for gateway pairing and the portal-transit lock
  (docs/faction-buildings.md): link/unlink lifecycle and billing, the
  reserve → begin_jump → wind_down → free protocol, interruption
  release semantics per phase, the unpowered pause, capture teardown,
  and the orphan sweep.
  """

  @test_instance_id 999_999_999

  setup_all do
    Data.Data.insert(@test_instance_id, speed: :fast, mode: :prod)
    on_exit(fn -> Data.Data.clear(@test_instance_id) end)
    :ok
  end

  defp players(count) do
    Enum.map(1..count, fn i -> %Instance.Faction.Player{id: i, name: "Player #{i}"} end)
  end

  defp ctx(opts \\ []) do
    players = players(5)

    %{
      instance_id: @test_instance_id,
      faction_id: 1,
      faction_key: :myrmezir,
      players: players,
      constants: %{
        government_founding_duration: 10,
        government_election_duration: 10,
        government_election_min_duration: 5,
        government_approval_duration: 10,
        government_term_myrmezir: 10_000,
        government_term_synelle: 160,
        government_cardan_quorum_pct: 5,
        government_cardan_max_rounds: 3,
        government_tax_cap: 10,
        government_max_laws: 2,
        government_law_cooldown: 10,
        government_lockout_duration: 30,
        market_taxe: 0.1,
        gateway_charge_time: 12,
        gateway_jump_time: 4,
        gateway_fatigue_time: 4,
        gateway_link_time: 20,
        gateway_unlink_time: 8,
        gateway_link_cost_credit: 3000,
        gateway_link_cost_technology: 500,
        gateway_unlink_cost_credit: 150_000,
        gateway_unlink_cost_technology: 20_000,
        gateway_charge_upkeep_credit: 250,
        gateway_charge_upkeep_technology: 50
      },
      faction_ideology_income: fn -> 100 end,
      faction_credit_total: fn -> 100_000 end,
      active_player_ids: fn -> Enum.map(players, & &1.id) end,
      active_player_count: fn -> length(players) end,
      seat_holder_status: fn _player_id -> :ok end,
      station_call: fn _system_id, _message -> {:error, :system_not_found} end,
      character_alive: Keyword.get(opts, :character_alive, fn _id -> true end)
    }
  end

  # Running government, player 3 = Head of Military, with BUILT gateways
  # registered on systems 100 and 200.
  defp gateway_government(ctx, opts \\ []) do
    government = Government.new(ctx)

    government = %{
      government
      | phase: :running,
        seats: %{
          leader: %{player_id: 1, name: "Player 1"},
          economy: %{player_id: 2, name: "Player 2"},
          military: %{player_id: 3, name: "Player 3"}
        },
        treasury: Keyword.get(opts, :treasury, %{credit: 10_000_000, technology: 1_000_000, ideology: 0})
    }

    government
    |> Government.station_registry_complete(100, %{id: 1, key: :gateway, level: 1, faction_id: 1, slots: [0, 1, 2, 3], status: :built})
    |> Government.station_registry_complete(200, %{id: 1, key: :gateway, level: 1, faction_id: 1, slots: [0, 1, 2, 3], status: :built})
  end

  defp linked_government(ctx, opts \\ []) do
    government = gateway_government(ctx, opts)
    {:ok, government, _events} = Government.gateway_link(government, 3, 100, 200, ctx)
    {government, events} = Government.advance(government, ctx.constants.gateway_link_time, ctx)
    assert Enum.any?(events, &(&1.type == :gateway_linked))
    government
  end

  defp link(government), do: government |> Map.get(:gateway_links) |> hd()

  describe "gateway_link/5" do
    test "military seat pairs two built gateways; the link forms over time and bills per ut" do
      ctx = ctx()
      government = gateway_government(ctx)

      assert {:ok, government, [%{type: :gateway_link_started, link: new_link}]} =
               Government.gateway_link(government, 3, 100, 200, ctx)

      assert new_link.status == :linking
      assert new_link.remaining == 20
      assert Enum.map(new_link.endpoints, & &1.system_id) == [100, 200]

      credit_before = government.treasury.credit
      technology_before = government.treasury.technology

      {government, events} = Government.advance(government, 10, ctx)
      assert link(government).status == :linking
      assert link(government).remaining == 10
      refute Enum.any?(events, &(&1.type == :gateway_linked))

      # 10 ut of: 2 gateway buildings (500c+50t each) + link (3000c+500t)
      assert credit_before - government.treasury.credit == 40_000
      assert technology_before - government.treasury.technology == 6_000

      {government, events} = Government.advance(government, 10, ctx)
      assert link(government).status == :linked
      assert link(government).remaining == nil
      assert Enum.any?(events, &(&1.type == :gateway_linked))
    end

    test "guards: seat, unknown/disabled gateways, double links" do
      ctx = ctx()
      government = gateway_government(ctx)

      assert {:error, :not_head_of_military} = Government.gateway_link(government, 2, 100, 200, ctx)
      assert {:error, :gateway_not_found} = Government.gateway_link(government, 3, 100, 999, ctx)
      assert {:error, :invalid_payload} = Government.gateway_link(government, 3, 100, 100, ctx)

      disabled = Government.station_registry_status(government, 200, 1, :disabled)
      assert {:error, :building_disabled} = Government.gateway_link(disabled, 3, 100, 200, ctx)

      {:ok, government, _} = Government.gateway_link(government, 3, 100, 200, ctx)
      government = Government.station_registry_complete(government, 300, %{id: 1, key: :gateway, level: 1, faction_id: 1, slots: [0, 1, 2, 3], status: :built})

      assert {:error, :gateway_already_linked} = Government.gateway_link(government, 3, 100, 300, ctx)
    end

    test "an unpowered faction's link formation pauses instead of advancing" do
      ctx = ctx()
      # treasury can't even cover building upkeep → power-down
      government = gateway_government(ctx, treasury: %{credit: 100, technology: 0, ideology: 0})
      {:ok, government, _} = Government.gateway_link(government, 3, 100, 200, ctx)

      {government, events} = Government.advance(government, 10, ctx)

      assert Map.get(government, :station_powered) == false
      assert Enum.any?(events, &(&1.type == :station_power and &1.powered == false))
      assert link(government).status == :linking
      assert link(government).remaining == 20
    end
  end

  describe "gateway_unlink/4" do
    test "one-time cost, teardown window, then the pair is free to relink or demolish" do
      ctx = ctx()
      government = linked_government(ctx)
      credit_before = government.treasury.credit

      assert {:ok, government, [%{type: :gateway_unlink_started} | _]} =
               Government.gateway_unlink(government, 3, 100, ctx)

      assert link(government).status == :unlinking
      assert link(government).remaining == 8
      assert credit_before - government.treasury.credit == 150_000

      {government, events} = Government.advance(government, 8, ctx)
      assert Map.get(government, :gateway_links) == []
      assert Enum.any?(events, &(&1.type == :gateway_unlinked))

      # relinking works once free
      assert {:ok, _government, _} = Government.gateway_link(government, 3, 100, 200, ctx)
    end

    test "guards: only a standing link, never while a transit holds it" do
      ctx = ctx()
      government = gateway_government(ctx)

      assert {:error, :gateway_not_linked} = Government.gateway_unlink(government, 3, 100, ctx)

      {:ok, government, _} = Government.gateway_link(government, 3, 100, 200, ctx)
      assert {:error, :gateway_not_linked} = Government.gateway_unlink(government, 3, 100, ctx)

      government = linked_government(ctx)
      {:ok, government, _target} = Government.gateway_reserve(government, 100, 42)
      assert {:error, :gateway_in_use} = Government.gateway_unlink(government, 3, 100, ctx)
    end
  end

  describe "transit lock protocol" do
    test "reserve → begin_jump → wind_down → timer frees the pair" do
      ctx = ctx()
      government = linked_government(ctx)

      assert {:ok, government, 200} = Government.gateway_reserve(government, 100, 42)
      assert link(government).transit.phase == :charging

      # both ends are locked for everyone else
      assert {:error, :gateway_busy} = Government.gateway_reserve(government, 100, 77)
      assert {:error, :gateway_busy} = Government.gateway_reserve(government, 200, 77)

      assert {:ok, government} = Government.gateway_begin_jump(government, 42)
      assert link(government).transit.phase == :jumping

      assert {:ok, government} = Government.gateway_begin_wind_down(government, 42, ctx)
      assert link(government).transit == %{character_id: 42, phase: :wind_down, remaining: 4}

      {government, events} = Government.advance(government, 2, ctx)
      assert link(government).transit.remaining == 2
      refute Enum.any?(events, &(&1.type == :gateway_ready))

      {government, events} = Government.advance(government, 2, ctx)
      assert link(government).transit == nil
      assert Enum.any?(events, &(&1.type == :gateway_ready))

      assert {:ok, _government, 100} = Government.gateway_reserve(government, 200, 77)
    end

    test "reserving from either end returns the opposite endpoint" do
      ctx = ctx()
      government = linked_government(ctx)
      assert {:ok, _government, 100} = Government.gateway_reserve(government, 200, 42)
    end

    test "release frees ONLY a charging transit; wind-down runs its own clock out" do
      ctx = ctx()
      government = linked_government(ctx)

      {:ok, government, _} = Government.gateway_reserve(government, 100, 42)
      {government, released?} = Government.gateway_release(government, 42)
      assert released?
      assert link(government).transit == nil

      # begin_jump after release must refuse — the capture-race backstop
      assert {:error, :not_reserved} = Government.gateway_begin_jump(government, 42)

      # a wind-down does not release on interruption (traveler death at
      # the arrival system leaves the pair cooling down regardless)
      {:ok, government, _} = Government.gateway_reserve(government, 100, 42)
      {:ok, government} = Government.gateway_begin_jump(government, 42)
      {:ok, government} = Government.gateway_begin_wind_down(government, 42, ctx)
      {government, released?} = Government.gateway_release(government, 42)
      refute released?
      assert link(government).transit.phase == :wind_down
    end

    test "reservation refused while unpowered or with a disabled endpoint" do
      ctx = ctx()
      government = linked_government(ctx)

      unpowered = Map.put(government, :station_powered, false)
      assert {:error, :station_unpowered} = Government.gateway_reserve(unpowered, 100, 42)

      disabled = Government.station_registry_status(government, 200, 1, :disabled)
      assert {:error, :building_disabled} = Government.gateway_reserve(disabled, 100, 42)
    end

    test "a charging transit bills the extra gateway upkeep" do
      ctx = ctx()
      government = linked_government(ctx)
      {:ok, government, _} = Government.gateway_reserve(government, 100, 42)

      credit_before = government.treasury.credit
      {government, _events} = Government.advance(government, 10, ctx)

      # 2 gateways (1000c/ut) + charge surcharge (250c/ut) over 10 ut
      assert credit_before - government.treasury.credit == 12_500
    end
  end

  describe "capture teardown + orphan sweep" do
    test "break_links_for removes the link and flags a charging traveler for abort" do
      ctx = ctx()
      government = linked_government(ctx)
      {:ok, government, _} = Government.gateway_reserve(government, 100, 42)

      {government, events} = Government.break_links_for(government, 100, 1)

      assert Map.get(government, :gateway_links) == []
      assert [%{type: :gateway_link_broken, abort_character_id: 42}] = events
    end

    test "a mid-jump traveler is NOT aborted by teardown — the jump lands regardless" do
      ctx = ctx()
      government = linked_government(ctx)
      {:ok, government, _} = Government.gateway_reserve(government, 100, 42)
      {:ok, government} = Government.gateway_begin_jump(government, 42)

      {_government, events} = Government.break_links_for(government, 200, 1)
      assert [%{type: :gateway_link_broken, abort_character_id: nil}] = events
    end

    test "the sweep frees a lock whose traveler process died without a release hook" do
      ctx = ctx(character_alive: fn _id -> false end)
      government = linked_government(ctx)
      {:ok, government, _} = Government.gateway_reserve(government, 100, 42)

      {government, _events} = Government.advance(government, 1, ctx)
      assert link(government).transit == nil
    end
  end

  describe "demolition guard" do
    test "a gateway with any link state refuses demolition" do
      ctx = ctx()
      government = linked_government(ctx)

      station = %Instance.StellarSystem.Station{
        buildings: [%{id: 1, key: :gateway, level: 1, faction_id: 1, slots: [0, 1, 2, 3], status: :built}],
        construction: nil,
        powered: true,
        next_building_id: 2
      }

      ctx = %{ctx | station_call: fn _system_id, :get_state -> {:ok, %{station: station}} end}

      assert {:error, :gateway_linked} =
               Government.demolish_station_building(government, 3, 100, 1, ctx)
    end
  end

  describe "backfill" do
    test "pre-gateway snapshots restore with empty link state" do
      ctx = ctx()
      government = gateway_government(ctx)

      restored =
        government
        |> Map.delete(:gateway_links)
        |> Map.delete(:gateway_counter)
        |> Government.backfill()

      assert Map.get(restored, :gateway_links) == []
      assert Map.get(restored, :gateway_counter) == 1
    end
  end
end

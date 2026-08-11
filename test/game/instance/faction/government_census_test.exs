defmodule Instance.Faction.GovernmentCensusTest do
  use ExUnit.Case, async: true

  alias Instance.Faction.Government

  @moduledoc """
  Cyber Command census (docs/faction-buildings.md): the per-building
  noisy reconciliation against the cached true malware count, probe
  fan-out, and the gating (unpowered faction, entries without a
  sector).
  """

  @test_instance_id 999_999_999

  setup_all do
    Data.Data.insert(@test_instance_id, speed: :fast, mode: :prod)
    on_exit(fn -> Data.Data.clear(@test_instance_id) end)
    :ok
  end

  # random.(4) → 4 gives the max "+3" step; random.(3) → 3 the max "−2".
  defp ctx(opts \\ []) do
    players = Enum.map(1..3, fn i -> %Instance.Faction.Player{id: i, name: "Player #{i}"} end)

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
        gateway_charge_upkeep_technology: 50,
        training_center_interval: 8,
        cyber_command_interval: 6
      },
      faction_ideology_income: fn -> 100 end,
      faction_credit_total: fn -> 100_000 end,
      active_player_ids: fn -> Enum.map(players, & &1.id) end,
      active_player_count: fn -> length(players) end,
      seat_holder_status: fn _player_id -> :ok end,
      station_call: fn _system_id, _message -> {:error, :system_not_found} end,
      character_alive: fn _id -> true end,
      census_probe: Keyword.get(opts, :census_probe, fn _sector_id -> :ok end),
      random: Keyword.get(opts, :random, fn n -> n end)
    }
  end

  defp government_with_command(ctx, opts \\ []) do
    government = Government.new(ctx)

    government = %{
      government
      | phase: :running,
        seats: %{
          leader: %{player_id: 1, name: "Player 1"},
          economy: %{player_id: 2, name: "Player 2"},
          military: %{player_id: 3, name: "Player 3"}
        },
        treasury: %{credit: 10_000_000, technology: 1_000_000, ideology: 0}
    }

    building = %{
      id: 1,
      key: :cyber_command,
      level: 1,
      faction_id: 1,
      slots: [0, 1, 2, 3],
      status: :built,
      sector_id: Keyword.get(opts, :sector_id, 5)
    }

    Government.station_registry_complete(government, 100, building)
  end

  defp census(government) do
    government |> Map.get(:station_buildings) |> hd() |> Map.get(:census, 0)
  end

  test "an under-reporting census climbs toward the cached true count (random 0..3 step)" do
    ctx = ctx()

    government =
      ctx
      |> government_with_command()
      |> Government.store_census_report(5, 2, 4)
      |> Government.store_census_report(5, 3, 3)

    # true count = 7, census 0 → +3 (max step with random.(4) = 4)
    {government, events} = Government.advance(government, 6, ctx)
    assert census(government) == 3
    assert Enum.any?(events, &(&1.type == :census_updated))

    # keeps climbing on later passes, overshoot allowed by design
    {government, _} = Government.advance(government, 6, ctx)
    assert census(government) == 6

    {government, _} = Government.advance(government, 6, ctx)
    assert census(government) == 9
  end

  test "an over-reporting census sheds 0..2 and never goes negative" do
    ctx = ctx()

    government = government_with_command(ctx)

    government =
      Map.update!(government, :station_buildings, fn [entry] -> [Map.put(entry, :census, 1)] end)

    # true count 0 (no reports), census 1 → −2 clamps to 0
    {government, _} = Government.advance(government, 6, ctx)
    assert census(government) == 0
  end

  test "each pass fires fresh probes for the command's sector" do
    probes = :ets.new(:probes, [:public])
    probe = fn sector_id -> :ets.insert(probes, {sector_id, :probed}) end
    ctx = ctx(census_probe: probe)

    government = government_with_command(ctx, sector_id: 42)
    {_government, _} = Government.advance(government, 6, ctx)

    assert :ets.lookup(probes, 42) == [{42, :probed}]
  end

  test "nothing ticks below the interval, while unpowered, or without a sector" do
    ctx = ctx()

    government =
      ctx
      |> government_with_command()
      |> Government.store_census_report(5, 2, 4)

    {ticked, _} = Government.advance(government, 3, ctx)
    assert census(ticked) == 0

    # a dry treasury powers stations down BEFORE the census step runs
    {unpowered, _} =
      government
      |> Map.put(:treasury, %{credit: 0, technology: 0, ideology: 0})
      |> Government.advance(6, ctx)

    assert Map.get(unpowered, :station_powered) == false
    assert census(unpowered) == 0

    {no_sector, _} =
      ctx
      |> government_with_command(sector_id: nil)
      |> Government.store_census_report(5, 2, 4)
      |> Government.advance(6, ctx)

    assert census(no_sector) == 0
  end
end

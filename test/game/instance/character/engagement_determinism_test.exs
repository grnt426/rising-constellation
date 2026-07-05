defmodule Character.EngagementDeterminismTest do
  @moduledoc """
  Two fleets meet at a system and fight — and the result is byte-identical
  under both content-memory modes (:legacy copy-per-lookup vs :shared
  persistent_term).

  This drives the REAL engagement pipeline — `Fight.check_interception/3` →
  `find_hostiles/3` → `Fight.start/2` → `Fight.Manager.fight/2` → per-player
  `fight_callback` — with two real, content-built fleets, reading real
  ship/constant content through `Data.Querier` under each mode. Surrounding
  agents (stellar_system, character, galaxy, player) are the `Test.FleetScenario`
  fakes, and the RNG is faked for determinism; the galaxy is a tutorial so the
  `RC.PlayerReports.create` DB write is skipped (no DB needed).

  Why this is reliable where a literal "jump across the galaxy and meet" E2E is
  not: the content-memory mode is a pure content read (proven byte-identical),
  so for an identical event sequence both modes are identical by construction.
  A real running instance can't be diffed across two runs because time is
  wall-clock-driven and the shared seeded RNG is consumed by time-driven AI —
  so a divergence there would be a timing artifact, not a memory-mode bug. By
  faking the RNG and running just the deterministic engagement, we compare the
  thing that actually matters (does the battle resolve identically under both
  content paths) without the timing noise.
  """
  use ExUnit.Case, async: false

  alias Instance.Character.Actions.Fight
  alias Instance.Character.Ship, as: CharacterShip
  alias Test.FleetScenario

  @metadata [speed: :fast, mode: :prod]
  @system_id 10

  test "two fleets meeting at a system battle identically under :legacy and :shared" do
    legacy = run_engagement(:legacy)
    shared = run_engagement(:shared)

    # Decisive, sane engagement (the 3-ship attacker wipes the 1-ship defender).
    assert status_of(legacy.attacker) == :victorious
    assert status_of(legacy.defender) == :dead

    # The point: the engagement resolves identically under both content paths.
    assert legacy == shared

    IO.puts("\n[engagement :legacy] #{inspect(legacy)}")
    IO.puts("[engagement :shared] #{inspect(shared)}")
  end

  defp run_engagement(mode) do
    iid = FleetScenario.unique_instance_id()
    Data.Data.insert(iid, @metadata, mode)
    on_exit(fn -> (try do Data.Data.clear(iid) rescue _ -> :ok end) end)

    FleetScenario.spawn_instance_supervisor(self(), instance_id: iid)
    # uniform 0.99 => every avoidance roll fails (strikes land) => decisive.
    FleetScenario.spawn_fake_rand(self(), instance_id: iid, uniform_value: 0.99, random_index: 0)
    FleetScenario.spawn_fake_galaxy(self(), instance_id: iid)

    {_dp, def_player_pid} = FleetScenario.spawn_fake_player(self(), instance_id: iid, player_id: 100, faction: :phoenix)
    {_ap, att_player_pid} = FleetScenario.spawn_fake_player(self(), instance_id: iid, player_id: 200, faction: :crow)

    ship_data = pick_combat_ship(iid)

    # Defender: real admiral parked at the meeting system (id 1, faction phoenix).
    defender = build_real_character(iid, id: 1, faction: :phoenix, owner: 100, ships: 1, ship_data: ship_data)
    spawn_character_agent(iid, 1, defender)

    def_summary = FleetScenario.build_system_character(character_id: 1, faction: :phoenix, owner_id: 100)

    FleetScenario.spawn_fake_stellar_system(self(),
      instance_id: iid,
      system_id: @system_id,
      characters: [def_summary]
    )

    # Attacker: real admiral that has arrived at the meeting system (id 2,
    # faction crow), about to raid — which triggers interception of the defender.
    attacker = build_real_character(iid, id: 2, faction: :crow, owner: 200, ships: 3, ship_data: ship_data)
    spawn_character_agent(iid, 2, attacker)

    raid_action = FleetScenario.build_action(:raid, %{"target" => @system_id})

    {_post, _notifs, _flee_or_dead} =
      Fight.check_interception(attacker, raid_action, [:defend, :attack_enemies, :attack_everyone])

    %{
      defender: summarize(FleetScenario.get_fight_callbacks(def_player_pid)),
      attacker: summarize(FleetScenario.get_fight_callbacks(att_player_pid))
    }
  end

  # --- helpers ---------------------------------------------------------------

  defp pick_combat_ship(iid) do
    Data.Querier.all(Data.Game.Ship, iid)
    |> Enum.filter(fn s -> length(s.unit_energy_strikes) + length(s.unit_explosive_strikes) > 0 end)
    |> Enum.sort_by(fn s -> Atom.to_string(s.key) end)
    |> List.first()
  end

  defp build_real_character(iid, opts) do
    ship_data = Keyword.fetch!(opts, :ship_data)
    count = Keyword.fetch!(opts, :ships)

    character =
      FleetScenario.build_character(
        instance_id: iid,
        character_id: Keyword.fetch!(opts, :id),
        faction: Keyword.fetch!(opts, :faction),
        owner_id: Keyword.fetch!(opts, :owner),
        system: @system_id,
        reaction: :defend,
        action_status: :idle
      )

    tiles =
      Enum.map(1..count, fn id ->
        struct(Instance.Character.Tile, %{id: id, ship_status: :filled, ship: CharacterShip.new(ship_data)})
      end)

    %{character | army: %{character.army | tiles: tiles}}
  end

  defp spawn_character_agent(iid, id, character) do
    {:ok, pid} =
      GenServer.start_link(FleetScenario.FakeCharacter, character, name: Game.via_tuple({iid, :character, id}))

    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :shutdown) end)
    pid
  end

  # Reduce the recorded fight_callbacks to a timing-independent, comparable shape:
  # the {status, surviving-hull} per callback.
  defp summarize(callbacks) do
    Enum.map(callbacks, fn {status, character} -> {status, total_hull(character)} end)
  end

  defp status_of(summary), do: summary |> List.first() |> elem(0)

  defp total_hull(character) do
    Enum.reduce(character.army.tiles, 0.0, fn tile, acc ->
      case tile.ship do
        nil -> acc
        ship -> acc + Enum.reduce(ship.units, 0.0, fn u, a -> a + (u.hull || 0.0) end)
      end
    end)
  end
end

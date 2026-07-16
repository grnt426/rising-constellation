defmodule Game.Fight.BattleDeterminismTest do
  @moduledoc """
  Tier-2 simulation-level differential for the content-memory toggle.

  Runs a REAL fleet battle (`Fight.Manager.fight/2`) end to end, reading real
  ship/constant content through `Data.Querier`, under BOTH content-memory modes
  (`:legacy` copy-per-lookup and `:shared` persistent_term), and asserts the
  outcome is byte-identical. Determinism comes from faking the RNG agent
  (`Test.FleetScenario` FakeRand) — which sidesteps the fact that galaxy
  *generation* is non-deterministic across runs (shared seeded RNG consumed via
  `Task.async_stream`). The combatants here are constructed explicitly from
  content, so generation never enters the picture.

  This is the in-process A/B that proves the `:shared` path is behavior-
  preserving at the simulation level (beyond the byte-equality proof in
  Data.DataPersistentTermTest), and a permanent combat regression asset.
  """
  use ExUnit.Case, async: false

  alias Instance.Character.Ship, as: CharacterShip
  alias Test.FleetScenario

  @metadata [speed: :fast, mode: :prod]

  test "battle outcome is identical under :legacy and :shared content-memory modes" do
    legacy = run_battle(:legacy)
    shared = run_battle(:shared)

    # Decisive, sane outcome (the sim actually ran to a resolution).
    assert legacy.victory == :left
    assert legacy.losses.left == 0 and legacy.losses.right > 0

    # The whole point: copy-per-lookup and persistent_term produce the SAME
    # battle, bit for bit.
    assert legacy.fingerprint == shared.fingerprint

    IO.puts("\n[battle :legacy] #{legacy.fingerprint}")
    IO.puts("[battle :shared] #{shared.fingerprint}")
    File.mkdir_p!("tmp")
    File.write!("tmp/battle_ab.txt", "legacy: #{legacy.fingerprint}\nshared: #{shared.fingerprint}\n")
  end

  # --- one battle under a given content-memory mode --------------------------

  defp run_battle(mode) do
    iid = FleetScenario.unique_instance_id()
    Data.Data.insert(iid, @metadata, mode)

    on_exit(fn ->
      try do
        Data.Data.clear(iid)
      rescue
        _ -> :ok
      end
    end)

    # uniform 0.99: every avoidance roll fails (handling/shield/interception are
    # all <= 0.95 after the level cap), so strikes always land and the battle is
    # decisive. random_index 0: target/unit selection is fully determined.
    FleetScenario.spawn_fake_rand(self(), instance_id: iid, uniform_value: 0.99, random_index: 0)

    ship_data = pick_combat_ship(iid)
    left = build_fleet(iid, character_id: 1, faction: :tetrarchy, ship_data: ship_data, count: 3)
    right = build_fleet(iid, character_id: 2, faction: :myrmezir, ship_data: ship_data, count: 1)

    {{left_out, right_out}, logs, metadata, victory} = Fight.Manager.fight([left], [right])

    %{
      victory: victory,
      losses: metadata.losses,
      log_turns: length(logs),
      fingerprint: fingerprint(ship_data, victory, metadata, left_out, right_out)
    }
  end

  # --- helpers ---------------------------------------------------------------

  defp pick_combat_ship(iid) do
    Data.Querier.all(Data.Game.Ship, iid)
    |> Enum.filter(fn s -> length(s.unit_energy_strikes) + length(s.unit_explosive_strikes) > 0 end)
    |> Enum.sort_by(fn s -> Atom.to_string(s.key) end)
    |> List.first()
  end

  defp build_fleet(iid, opts) do
    count = Keyword.fetch!(opts, :count)
    ship_data = Keyword.fetch!(opts, :ship_data)

    character =
      FleetScenario.build_character(
        instance_id: iid,
        character_id: Keyword.fetch!(opts, :character_id),
        faction: Keyword.fetch!(opts, :faction),
        system: 1,
        reaction: :defend
      )

    tiles =
      Enum.map(1..count, fn id ->
        struct(Instance.Character.Tile, %{id: id, ship_status: :filled, ship: CharacterShip.new(ship_data)})
      end)

    %{character | army: %{character.army | tiles: tiles}}
  end

  defp fingerprint(ship_data, victory, metadata, left_out, right_out) do
    Enum.join(
      [
        "ship=#{ship_data.key}",
        "victory=#{victory}",
        "losses_left=#{fmt(metadata.losses.left)}",
        "losses_right=#{fmt(metadata.losses.right)}",
        "fight_scale=#{fmt(metadata.fight_scale)}",
        "left=#{side_fp(left_out)}",
        "right=#{side_fp(right_out)}"
      ],
      " "
    )
  end

  defp side_fp(side_out) do
    side_out
    |> Enum.map(fn {status, _side, character} -> "{#{status},hull=#{fmt(total_hull(character))}}" end)
    |> Enum.join(",")
  end

  defp total_hull(character) do
    Enum.reduce(character.army.tiles, 0.0, fn tile, acc ->
      case tile.ship do
        nil -> acc
        ship -> acc + Enum.reduce(ship.units, 0.0, fn u, a -> a + (u.hull || 0.0) end)
      end
    end)
  end

  defp fmt(n) when is_float(n), do: :erlang.float_to_binary(n, decimals: 3)
  defp fmt(n), do: to_string(n)
end

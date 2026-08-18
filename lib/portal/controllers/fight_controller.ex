defmodule Portal.FightController do
  use Portal, :controller

  alias Instance.Character.Character
  alias Instance.Character.Player
  alias Instance.Character.Army
  alias Instance.Character.Ship

  @multi_run_cap 100
  # :erlang.phash2 output range (2^32); the seed only needs to be stable, not wide.
  @seed_range 4_294_967_296

  def run(conn, %{"attacker" => attacker_spec, "defender" => defender_spec} = params) do
    balance = normalize_balance(Map.get(params, "balance", "baseline"))
    runs = normalize_runs(Map.get(params, "runs", 1))
    instance_id = balance_instance(balance)

    if runs > 1,
      do: run_many(conn, attacker_spec, defender_spec, balance, runs, instance_id),
      else: run_once(conn, attacker_spec, defender_spec, instance_id)
  end

  defp run_once(conn, attacker_spec, defender_spec, instance_id) do
    attacker = build_character(1, "Joueur 1", :myrmezir, 1, attacker_spec, instance_id)
    defender = build_character(2, "Joueur 2", :tetrarchy, 2, defender_spec, instance_id)

    {{attackers, defenders}, logs, metadata, _} = Fight.Manager.fight([attacker], [defender])

    attackers = Enum.map(attackers, fn {_, _, character} -> character end)
    defenders = Enum.map(defenders, fn {_, _, character} -> character end)

    conn
    |> put_status(200)
    |> json(%{
      initial: %{attackers: [attacker], defenders: [defender]},
      final: %{attackers: attackers, defenders: defenders},
      logs: logs,
      metadata: metadata
    })
  end

  # N seeded battles of the same matchup. The base seed derives from the
  # normalized fleet setup + balance, so an identical setup always returns the
  # identical distribution: re-launching cannot fish for a better roll, and
  # spamming the endpoint extracts nothing new.
  defp run_many(conn, attacker_spec, defender_spec, balance, runs, instance_id) do
    seed =
      :erlang.phash2(
        {normalize_side(attacker_spec), normalize_side(defender_spec), balance},
        @seed_range
      )

    # Construction rolls draw from the seeded :sim rand path too, so the
    # initial armies are reproducible as well (mirrors Sim.Fleet).
    Process.put(:rc_sim_rand_state, :rand.seed_s(:exrop, seed))
    attacker = build_character(1, "Joueur 1", :myrmezir, 1, attacker_spec, instance_id)
    defender = build_character(2, "Joueur 2", :tetrarchy, 2, defender_spec, instance_id)

    # Battle i is seeded with seed + 1 + i (the +1 keeps it off the
    # construction stream). Only battle 0 builds replay logs — it is returned
    # as the example battle; the rest run silent (see Fight.Ship.log_add/2).
    results =
      0..(runs - 1)
      |> Task.async_stream(
        fn i ->
          Process.put(:rc_sim_rand_state, :rand.seed_s(:exrop, seed + 1 + i))
          if i > 0, do: Process.put(:rc_sim_silent, true)

          {{[{_, _, att}], [{_, _, def_}]}, logs, metadata, victory} =
            Fight.Manager.fight([attacker], [defender])

          %{attacker: att, defender: def_, logs: logs, metadata: metadata, victory: victory}
        end,
        max_concurrency: System.schedulers_online(),
        ordered: true,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, r} -> r end)

    [sample | _] = results
    attacker_wins = Enum.count(results, fn r -> r.victory == :left end)
    defender_wins = Enum.count(results, fn r -> r.victory == :right end)
    att_finals = Enum.map(results, & &1.attacker)
    def_finals = Enum.map(results, & &1.defender)

    conn
    |> put_status(200)
    |> json(%{
      initial: %{attackers: [attacker], defenders: [defender]},
      final: %{attackers: [sample.attacker], defenders: [sample.defender]},
      logs: sample.logs,
      metadata: sample.metadata,
      runs: %{
        n: runs,
        attacker_wins: attacker_wins,
        defender_wins: defender_wins,
        draws: runs - attacker_wins - defender_wins,
        sides: %{
          attackers: [side_aggregate(attacker, att_finals)],
          defenders: [side_aggregate(defender, def_finals)]
        },
        losses: %{
          attackers: loss_stats(attacker, att_finals),
          defenders: loss_stats(defender, def_finals)
        }
      }
    })
  end

  # Seed material: the combat-relevant content of a side spec, independent of
  # JSON key order or extraneous params.
  defp normalize_side(spec), do: Enum.map(Map.get(spec, "tiles", []), &tile_spec/1)

  # Per-tile outcome distribution over all runs: in how many battles the ship
  # survived, and quantiles of its surviving hull fraction (survivor-only —
  # averaging across destroyed-and-surviving runs would hide the bimodality).
  defp side_aggregate(initial, finals) do
    pre = pre_hulls(initial)

    tiles =
      initial.army.tiles
      |> Enum.filter(fn t -> Map.has_key?(pre, t.id) end)
      |> Enum.map(fn t ->
        fracs =
          finals
          |> Enum.map(fn char -> tile_outcome(char, t.id, Map.fetch!(pre, t.id)) end)
          |> Enum.reject(&is_nil/1)
          |> Enum.sort()

        survived = length(fracs)

        %{
          id: t.id,
          survived: survived,
          hull:
            if survived > 0 do
              %{
                p10: quantile(fracs, 0.1),
                p50: quantile(fracs, 0.5),
                p90: quantile(fracs, 0.9)
              }
            end
        }
      end)

    %{character: initial.id, tiles: tiles}
  end

  defp pre_hulls(character) do
    for t <- character.army.tiles,
        t.ship_status == :filled and is_map(t.ship),
        into: %{} do
      {t.id, Ship.total_hull(t.ship)}
    end
  end

  # nil when the ship did not survive this run; else its remaining hull as a
  # fraction of its pre-battle hull (clamped — XP level-ups can inflate hull).
  defp tile_outcome(character, tile_id, pre_hull) do
    tile = Enum.find(character.army.tiles, fn t -> t.id == tile_id end)

    if tile != nil and tile.ship_status == :filled and is_map(tile.ship) and
         not Ship.is_destroyed(tile.ship) and pre_hull > 0 do
      Float.round(min(Ship.total_hull(tile.ship) / pre_hull, 1.0), 3)
    end
  end

  # Ships lost per run, as count quantiles over all runs.
  defp loss_stats(initial, finals) do
    pre_count =
      Enum.count(initial.army.tiles, fn t -> t.ship_status == :filled and is_map(t.ship) end)

    losses =
      finals
      |> Enum.map(fn char ->
        alive =
          Enum.count(char.army.tiles, fn t ->
            t.ship_status == :filled and is_map(t.ship) and not Ship.is_destroyed(t.ship)
          end)

        pre_count - alive
      end)
      |> Enum.sort()

    %{
      p10: quantile(losses, 0.1),
      p50: quantile(losses, 0.5),
      p90: quantile(losses, 0.9),
      max: List.last(losses)
    }
  end

  # Nearest-rank quantile on a sorted, non-empty list.
  defp quantile(sorted, q) do
    n = length(sorted)
    Enum.at(sorted, min(n - 1, max(0, round(q * (n - 1)))))
  end

  defp normalize_runs(n) when is_integer(n), do: n |> max(1) |> min(@multi_run_cap)

  defp normalize_runs(n) when is_binary(n) do
    case Integer.parse(n) do
      {i, ""} -> normalize_runs(i)
      _ -> 1
    end
  end

  defp normalize_runs(_), do: 1

  # Sim.Balance presets (`%{name => %{base_ship_key => %{field => value}}}`) so
  # the simulator can show what a balance mode changes vs. live data.
  def balances(conn, _params) do
    conn
    |> put_status(200)
    |> json(Sim.Balance.presets())
  end

  # Build an admiral + army from a side spec: `%{"tiles" => [tile, ...]}` where
  # each tile is null, a bare "ship_key" string (legacy), or
  # `%{"ship_key" => k, "level" => l}`. Combat reads `ship.level` directly, so we
  # set it on the built ship (matching Sim.Fleet) rather than feeding XP through
  # the level curve.
  defp build_character(id, name, faction, faction_id, spec, instance_id) do
    tiles = Map.get(spec, "tiles", [])

    character = Character.new(id, :admiral, :common, 1, instance_id)

    character = %{
      character
      | owner: %Player{id: id, name: name, faction: faction, faction_id: faction_id},
        status: :on_board,
        action_status: :idle,
        army: Army.new(instance_id)
    }

    {character, _index} =
      Enum.reduce(tiles, {character, 1}, fn tile, {character, index} ->
        case tile_spec(tile) do
          nil ->
            {character, index + 1}

          {ship_key, level} ->
            {:ok, character} = Character.order_ship(character, {nil, index, ship_key, nil})

            character =
              character
              |> Character.put_ship(index, 0.0)
              |> set_ship_level(index, level)

            {character, index + 1}
        end
      end)

    character
  end

  defp tile_spec(nil), do: nil

  defp tile_spec(key) when is_binary(key) do
    case safe_ship(key) do
      nil -> nil
      ship -> {ship, 0}
    end
  end

  defp tile_spec(%{"ship_key" => key} = tile) when is_binary(key) do
    case safe_ship(key) do
      nil -> nil
      ship -> {ship, normalize_level(Map.get(tile, "level", 0))}
    end
  end

  defp tile_spec(_), do: nil

  defp safe_ship(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  defp normalize_level(level) when is_integer(level) and level > 0, do: level
  defp normalize_level(_), do: 0

  # Pin the ship to a flat level (experience reset), mirroring Sim.Fleet — the
  # fight scales unit stats off ship.level, which is all combat reads.
  defp set_ship_level(character, _tile_id, level) when level <= 0, do: character

  defp set_ship_level(character, tile_id, level) do
    tiles =
      Enum.map(character.army.tiles, fn t ->
        if t.id == tile_id and t.ship_status == :filled and is_map(t.ship),
          do: %{t | ship: %{t.ship | level: level, experience: 0.0}},
          else: t
      end)

    %{character | army: %{character.army | tiles: tiles}}
  end

  # Every simulator fight runs on the :sim virtual instance. Its dataset is
  # the same (speed: :fast, mode: :prod) content the old :fast_prod path read,
  # but served from the :persistent_term cache, and its rand path is the
  # process-local seeded PRNG (see Game.call(:sim, :rand, ...)) — which is
  # what makes multi-run distributions reproducible. A balance preset patches
  # ship stats off the cached base; baseline installs the base unpatched.
  # NOTE: the :sim dataset is one global slot, so concurrent requests with
  # different balances can race (pre-existing since the preset feature; the
  # portal simulator has no meaningful concurrency).
  defp balance_instance(balance) do
    Sim.Setup.install_overrides(balance_overrides(balance))
    :sim
  end

  defp balance_overrides(:baseline), do: %{}
  defp balance_overrides(preset), do: Sim.Balance.changes(preset)

  # Unknown/invalid preset names fall back to live data.
  defp normalize_balance(name) when name in [nil, "", "baseline"], do: :baseline

  defp normalize_balance(name) do
    case safe_preset(name) do
      nil -> :baseline
      preset -> preset
    end
  end

  defp safe_preset(name) do
    preset = String.to_existing_atom(name)
    if preset in Sim.Balance.names(), do: preset, else: nil
  rescue
    ArgumentError -> nil
  end
end

defmodule Sim.Arena do
  @moduledoc """
  Runs reproducible, parallel headless battles between fleets built by
  `Sim.Fleet`, and aggregates the outcomes.

  Reproducibility: each battle seeds a process-local PRNG (via the `:sim`
  rand path in `Game.call/4`) from a single integer seed, so the same
  `(attacker, defender, seed)` always yields the same result. `matchup/3`
  uses Common Random Numbers — battle `i` of every matchup shares seed
  `base + i` — so comparing two fleets reflects the fleets, not the dice,
  which sharply reduces the noise in fitness comparisons.

  Parallelism: battles run under `Task.async_stream`; each task owns its
  own process-dictionary RNG and reads the shared, read-only dataset from
  `:persistent_term`, so there is no cross-battle contention.
  """

  alias Instance.Character.Army
  alias Instance.Character.Ship

  @doc """
  Run one battle. Deterministic in `seed`. Returns a result map with the
  victor, per-side post-battle survival, and the engine's loss/scale
  metadata.
  """
  def battle(attacker, defender, seed) do
    Process.put(:rc_sim_rand_state, :rand.seed_s(:exrop, seed))
    # Skip building the (discarded) battle-replay log — see Fight.Ship.log_add/2.
    Process.put(:rc_sim_silent, true)

    {{[{att_status, _, att_char}], [{def_status, _, def_char}]}, _logs, metadata, victory} =
      Fight.Manager.fight([attacker], [defender])

    %{
      victory: normalize_victory(victory),
      seed: seed,
      attacker: %{status: att_status, post: summarize(att_char)},
      defender: %{status: def_status, post: summarize(def_char)},
      losses: metadata.losses,
      fight_scale: metadata.fight_scale
    }
  end

  @doc """
  Run `n` battles between the same two fleets with Common Random Numbers
  and aggregate.

  Opts:
    * `:n`         (default `50`)   — battles to run.
    * `:base_seed` (default `1`)    — first seed; battle i uses `base_seed + i`.
    * `:parallel`  (default `true`) — run battles concurrently.
  """
  def matchup(attacker, defender, opts \\ []) do
    n = Keyword.get(opts, :n, 50)
    base = Keyword.get(opts, :base_seed, 1)
    parallel = Keyword.get(opts, :parallel, true)

    pre_att = summarize(attacker)
    pre_def = summarize(defender)
    seeds = Enum.map(0..(n - 1), fn i -> base + i end)

    results =
      if parallel do
        seeds
        |> Task.async_stream(fn s -> battle(attacker, defender, s) end,
          max_concurrency: System.schedulers_online(),
          ordered: false,
          timeout: :infinity
        )
        |> Enum.map(fn {:ok, r} -> r end)
      else
        Enum.map(seeds, fn s -> battle(attacker, defender, s) end)
      end

    aggregate(results, pre_att, pre_def, n)
  end

  @doc """
  Round-robin payoff matrix over mono-type fleets (one variant per fleet,
  `:tiles` copies each). Returns per-pair matchup summaries plus per-fleet
  cost. This is the interpretable ground-truth balance readout; the full
  composition space is far too large to enumerate, which is what motivates
  the genetic search.

  Opts:
    * `:tiles` (default `Sim.Setup.tile_count()`) — fleet size, capped at the army size.
    * `:n`     (default `30`)                     — battles per pair.
  """
  def round_robin(ship_keys, opts \\ []) do
    tiles = min(Keyword.get(opts, :tiles, Sim.Setup.tile_count()), Sim.Setup.tile_count())
    n = Keyword.get(opts, :n, 30)

    pairs = for a <- ship_keys, b <- ship_keys, a < b, do: {a, b}

    matrix =
      pairs
      |> Task.async_stream(
        fn {a, b} ->
          att = Sim.Fleet.mono(a, tiles, id: 1)
          def_ = Sim.Fleet.mono(b, tiles, id: 2)
          {{a, b}, matchup(att, def_, n: n, parallel: false)}
        end,
        max_concurrency: System.schedulers_online(),
        ordered: true,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, r} -> r end)

    costs =
      Map.new(ship_keys, fn key ->
        keys = List.duplicate(key, tiles)
        {key, %{build: Sim.Cost.build_cost(keys), unlock: Sim.Cost.unlock_cost([key])}}
      end)

    %{matrix: matrix, costs: costs, tiles: tiles, n: n}
  end

  ## Helpers

  # Post- (or pre-) battle survival of one admiral's army: remaining hull
  # (PV), and the count of surviving ships/units. A unit with hull 0.001 is
  # the engine's "destroyed" marker.
  defp summarize(character) do
    idx = Sim.Setup.ship_index()
    tiles = character.army.tiles
    pv = Army.compute_total_pv(character.army)

    # bombing / conquest power follow the game's army-coefficient formula:
    # contribution = coef * unit_count * (surviving_hull / max_hull). So a
    # half-dead bomber retains ~half its bombing power — exactly the
    # "surviving strategic capability" the strategic objectives care about.
    {ships, units, bomb, conquest} =
      Enum.reduce(tiles, {0, 0, 0.0, 0.0}, fn tile, {s, u, b, c} ->
        if tile.ship_status == :filled and is_map(tile.ship) and not Ship.is_destroyed(tile.ship) do
          sd = Map.get(idx, tile.ship.key)
          alive = Enum.count(tile.ship.units, fn unit -> unit.hull > 0.001 end)
          frac = hull_frac(tile.ship, sd)

          {s + 1, u + alive, b + sd.unit_raid_coef * frac * sd.unit_count,
           c + sd.unit_invasion_coef * frac * sd.unit_count}
        else
          {s, u, b, c}
        end
      end)

    %{
      pv: Float.round(pv * 1.0, 1),
      ships: ships,
      units: units,
      bomb: Float.round(bomb, 2),
      conquest: Float.round(conquest, 2)
    }
  end

  defp hull_frac(ship, sd) do
    max_hull = sd.unit_count * sd.unit_hull
    if max_hull > 0, do: Ship.total_hull(ship) / max_hull, else: 0.0
  end

  defp aggregate(results, pre_att, pre_def, n) do
    att_wins = Enum.count(results, fn r -> r.victory == :left end)
    def_wins = Enum.count(results, fn r -> r.victory == :right end)
    draws = n - att_wins - def_wins

    mean = fn f -> if n > 0, do: Enum.sum(Enum.map(results, f)) / n, else: 0.0 end
    mean_att_pv = mean.(fn r -> r.attacker.post.pv end)
    mean_def_pv = mean.(fn r -> r.defender.post.pv end)
    att_bombs = Enum.map(results, fn r -> r.attacker.post.bomb end)
    def_bombs = Enum.map(results, fn r -> r.defender.post.bomb end)
    att_conqs = Enum.map(results, fn r -> r.attacker.post.conquest end)
    def_conqs = Enum.map(results, fn r -> r.defender.post.conquest end)
    mean_att_bomb = if n > 0, do: Enum.sum(att_bombs) / n, else: 0.0
    mean_def_bomb = if n > 0, do: Enum.sum(def_bombs) / n, else: 0.0

    %{
      n: n,
      attacker_wins: att_wins,
      defender_wins: def_wins,
      draws: draws,
      attacker_win_rate: Float.round(att_wins / n, 3),
      pre: %{attacker: pre_att, defender: pre_def},
      # raw per-battle surviving strategic power, for threshold-probability objectives/constraints
      attacker_bomb_values: att_bombs,
      defender_bomb_values: def_bombs,
      attacker_conquest_values: att_conqs,
      defender_conquest_values: def_conqs,
      mean_survival: %{
        attacker_pv: Float.round(mean_att_pv, 1),
        defender_pv: Float.round(mean_def_pv, 1),
        attacker_pv_frac: safe_frac(mean_att_pv, pre_att.pv),
        defender_pv_frac: safe_frac(mean_def_pv, pre_def.pv),
        # surviving strategic power (own = attacker, enemy = defender)
        attacker_bomb: Float.round(mean_att_bomb, 2),
        defender_bomb: Float.round(mean_def_bomb, 2)
      }
    }
  end

  defp safe_frac(_num, +0.0), do: 0.0
  defp safe_frac(num, den), do: Float.round(num / den, 3)

  defp normalize_victory(:left), do: :left
  defp normalize_victory(:right), do: :right
  defp normalize_victory(_), do: :draw
end

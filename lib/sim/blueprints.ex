defmodule Sim.Blueprints do
  @moduledoc """
  Availability-conditioned fleet-champion search: what is the best fleet to
  build **given the ships you can actually build right now**, and what
  counters it?

  The strategic-goal arena (`Sim.Strategy`) answers "what's the best fleet
  per job at a coarse game stage". A bot's fleet-builder needs something
  finer: its buildable set is whatever its patent purchases unlock, and the
  best design over {fighter_1} is very different from the best design over
  {everything}. Even if one ship dominates, a builder without its patent
  needs the champion of the *remaining* pool.

  So this module walks a ladder of cumulative **patent tiers** following the
  fast-mode military tech tree (see `tiers/0`), derives each tier's buildable
  ship pool directly from the patent data (`ship.patent ∈ owned set`), and
  for each tier:

    * evolves one champion per strategic goal (`Sim.Strategy.strategies/0`)
      with NSGA-II against a tier-appropriate diverse gauntlet;
    * evolves a **counter fleet** to each goal champion (best response when
      you know exactly what the enemy built);
    * cross-plays all champions + counters for the tier's counter matrix;
    * persists everything as JSON under an output directory — one file per
      tier (written as soon as the tier finishes, so a long run is
      crash-safe and resumable) plus a combined `blueprints.json`.

  The output is the ground truth the headless bots' blueprint table
  (`Headless.Policies.Tunable`) is meant to be regenerated from.

  Dataset: always `speed: :fast, mode: :prod` with **no stat overrides** —
  champions must reflect live balance, never what-if data.
  """

  alias Sim.{GA, Genome, Fleet, Strategy}

  @metadata [speed: :fast, mode: :prod]

  # Cumulative military-patent ladder (fast/prod tree). Each tier owns its
  # `adds` plus everything above it. Tier order follows the tree's forced
  # progression (shipyards + merge patents are chained), with the optional
  # per-ship patents grouped into the tier where a player typically buys them.
  @tiers [
    %{name: :t1_scouts, adds: [:shipyard_1]},
    %{name: :t2_fighters, adds: [:fighter_2, :fighter_3]},
    %{name: :t3_wings, adds: [:fighter_4, :merge_fighter_1]},
    %{name: :t4_corvettes, adds: [:shipyard_2, :corvette_1, :corvette_2]},
    %{name: :t5_strike_groups, adds: [:merge_fighter_corvette, :corvette_3]},
    %{name: :t6_frigates, adds: [:shipyard_3, :frigate_3, :frigate_2, :frigate_4]},
    %{name: :t7_armadas, adds: [:merge_fighter_3, :merge_corvette_2]},
    %{name: :t8_capitals, adds: [:shipyard_4, :capital_1, :capital_2, :capital_3, :merge_frigate_1, :transport_2]}
  ]

  @doc "The tier ladder with cumulative patent sets: `[%{name, patents}]`."
  def tiers do
    {tiers, _} =
      Enum.map_reduce(@tiers, [], fn t, acc ->
        patents = acc ++ t.adds
        {%{name: t.name, patents: patents}, patents}
      end)

    tiers
  end

  @doc "Buildable combat-ship pool for a cumulative patent set (colony ship excluded)."
  def pool(patents) do
    owned = MapSet.new(patents)

    Sim.Setup.ships()
    |> Enum.filter(fn s -> MapSet.member?(owned, s.patent) end)
    |> Enum.map(& &1.key)
    |> Enum.reject(&(&1 == :transport_1))
  end

  @doc """
  Run the full ladder and persist results.

  Opts: `:out` (dir, default "tmp/fleet_arena"), `:pop` (32), `:gens` (20),
  `:battles` (8), `:cross_battles` (40), `:seed` (1), `:counters` (true),
  `:tiers` (list of tier-name atoms, default all), `:force` (false — redo
  tiers whose output file already exists).
  """
  def run(opts \\ []) do
    Sim.Setup.ensure_installed(@metadata)

    out = Keyword.get(opts, :out, "tmp/fleet_arena")
    File.mkdir_p!(out)
    selected = Keyword.get(opts, :tiers)
    force = Keyword.get(opts, :force, false)

    ladder =
      tiers()
      |> Enum.filter(fn t -> selected == nil or t.name in selected end)

    Enum.each(Enum.with_index(ladder), fn {tier, i} ->
      path = tier_path(out, tier.name)

      if not force and File.exists?(path) do
        IO.puts("#{tier.name}: exists, skipping (use --force to redo)")
      else
        run_tier(tier, i, path, opts)
      end
    end)

    combine(out, ladder)
    IO.puts("done — combined file: #{Path.join(out, "blueprints.json")}")
  end

  defp run_tier(tier, tier_index, path, opts) do
    t0 = System.monotonic_time(:millisecond)
    pool = pool(tier.patents)
    gauntlet_keys = gauntlet_keys(pool)
    gauntlet = Enum.map(gauntlet_keys, fn k -> Fleet.mono(k, Sim.Setup.tile_count(), id: 2) end)

    base = [
      pop_size: Keyword.get(opts, :pop, 32),
      generations: Keyword.get(opts, :gens, 20),
      battles: Keyword.get(opts, :battles, 8),
      gauntlet: gauntlet
    ]

    seed0 = Keyword.get(opts, :seed, 1) + tier_index * 100
    IO.puts("#{tier.name}: pool=#{length(pool)} ships, gauntlet=#{inspect(gauntlet_keys)}")

    champions =
      Strategy.strategies()
      |> Enum.with_index()
      |> Enum.map(fn {s, gi} ->
        res = GA.run(pool, base ++ [base_seed: seed0 + gi * 10, objectives: s.objectives])
        champ = Enum.max_by(non_empty(res.front), fn ind -> s.pick.(ind.metrics) end)
        IO.puts("  #{s.name}: #{GA.describe(champ.genome, pool)} (margin #{r2(champ.metrics.margin)}, credit #{champ.metrics.credit})")
        serialize(s.name, s.desc, champ, pool)
      end)

    counters =
      if Keyword.get(opts, :counters, true) do
        Enum.map(Enum.with_index(champions), fn {champ, ci} ->
          target = Fleet.from_genome(champ.genome, pool, id: 2)
          objectives = [{:eff, :max, & &1.margin}, {:cost, :min, & &1.credit}]

          res =
            GA.run(pool, base ++ [gauntlet: [target], base_seed: seed0 + 50 + ci * 10, objectives: objectives])

          best = Enum.max_by(non_empty(res.front), fn ind -> ind.metrics.margin end)
          IO.puts("  counter:#{champ.goal}: #{GA.describe(best.genome, pool)} (margin #{r2(best.metrics.margin)})")
          serialize(:"counter_#{champ.goal}", "best response to the #{champ.goal} champion", best, pool)
        end)
      else
        []
      end

    cross =
      (champions ++ counters)
      |> Enum.map(fn c -> %{name: c.goal, genome: c.genome} end)
      |> Strategy.cross_play(pool, battles: Keyword.get(opts, :cross_battles, 40))

    tier_result = %{
      tier: tier.name,
      patents: tier.patents,
      pool: pool,
      gauntlet: gauntlet_keys,
      params: Map.new(Keyword.take(base, [:pop_size, :generations, :battles])),
      seed: seed0,
      generated_at: System.system_time(:second),
      champions: champions,
      counters: counters,
      cross_play: cross
    }

    File.write!(path, Jason.encode!(tier_result, pretty: true))
    IO.puts("#{tier.name}: written #{path} (#{div(System.monotonic_time(:millisecond) - t0, 1000)}s)")
  end

  # A champion/counter as blueprint-table food: the composition (what to
  # build), the exact tile layout (deployment lines matter), and the traded
  # metrics. `slots` is `[[tile, ship_key, level]]`.
  defp serialize(goal, desc, ind, pool) do
    slots = Genome.decode(ind.genome, pool)

    %{
      goal: goal,
      desc: desc,
      genome: ind.genome,
      composition: slots |> Enum.map(fn {_t, key, _l} -> key end) |> Enum.frequencies(),
      slots: Enum.map(slots, fn {t, k, l} -> [t, k, l] end),
      summary: GA.describe(ind.genome, pool),
      metrics: Map.take(ind.metrics, [:margin, :win_rate, :bomb, :enemy_bomb, :credit, :unlock, :ships])
    }
  end

  # "Build nothing" can be Pareto-optimal on the cost axis when every design
  # loses to the gauntlet (bomb ties at 0) — but an empty fleet is never a
  # useful blueprint, so champions are picked among real fleets when any exist.
  defp non_empty(front) do
    case Enum.filter(front, fn ind -> ind.metrics.ships > 0 end) do
      [] -> front
      real -> real
    end
  end

  # Tier gauntlet: the largest allowed stack variant of every base type in
  # the pool, thinned to at most 6 fleets spread evenly across the credit
  # range — cheap swarms through expensive walls, deterministic.
  defp gauntlet_keys(pool) do
    idx = Sim.Setup.ship_index()

    pool
    |> Enum.group_by(fn k -> base_type(k) end)
    |> Enum.map(fn {_base, variants} -> Enum.max_by(variants, fn k -> idx[k].unit_count end) end)
    |> Enum.sort_by(fn k -> idx[k].credit_cost end)
    |> spread(6)
  end

  defp base_type(key) do
    case Regex.run(~r/^(.*?)v\d+$/, Atom.to_string(key)) do
      [_, base] -> String.to_existing_atom(base)
      _ -> key
    end
  end

  # Up to n elements evenly spaced over a sorted list (always keeps ends).
  defp spread(list, n) when length(list) <= n, do: list

  defp spread(list, n) do
    last = length(list) - 1

    0..(n - 1)
    |> Enum.map(fn i -> Enum.at(list, round(i * last / (n - 1))) end)
    |> Enum.uniq()
  end

  # Merge all existing tier files into one blueprints.json for consumers.
  defp combine(out, ladder) do
    tiers =
      ladder
      |> Enum.map(fn t -> tier_path(out, t.name) end)
      |> Enum.filter(&File.exists?/1)
      |> Enum.map(fn p -> Jason.decode!(File.read!(p)) end)

    combined = %{
      metadata: %{speed: :fast, mode: :prod},
      generated_at: System.system_time(:second),
      tiers: tiers
    }

    File.write!(Path.join(out, "blueprints.json"), Jason.encode!(combined, pretty: true))
  end

  defp tier_path(out, name), do: Path.join(out, "tier_#{name}.json")

  defp r2(f), do: Float.round(f * 1.0, 2)
end

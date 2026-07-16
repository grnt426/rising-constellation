defmodule Sim.AutoBalance do
  @moduledoc """
  Automated balancing (inverse design): an evolution strategy that tweaks ship
  STATS — within per-ship archetype bounds — until the ship-vs-ship win matrix
  matches a target rock-paper-scissors, with all matchups in 50–75% (no blowouts).

  Tractable because (a) stats are bounded to each ship's archetype (preserving
  theme and shrinking the search to ~one box per stat), and (b) the fitness is a
  single round-robin per candidate (NOT a nested fleet-GA). Candidates are
  evaluated serially (each installs its stats globally via the fast patch in
  `Sim.Setup.install_overrides/1`); the battles within a candidate run in parallel.

  `run/1` returns `%{genome, loss, overrides}`. `report/2` prints the achieved
  matrix vs the target and the tuned stats. Targeting the ship matrix yields
  fleet diversity as a consequence — verify afterward with the fleet GA.
  """

  alias Sim.{Setup, Fleet, Arena}

  @params [:handling, :hull, :shield, :flak, :e_count, :e_dmg, :x_count, :x_dmg, :armor]

  # Per-ship archetype bounds {lo, hi}; lo==hi locks the stat (no search).
  # Scout dropped (it's the designated punching bag — too weak to land in-band).
  # `armor` (flat per-hit reduction) is the new anti-swarm lever: locked to 0 for
  # fighters (they ARE the swarm), tunable for corvettes so they can shrug off
  # small fighter hits while still folding to a big alpha strike.
  @schema [
    {:fighter_2,
     %{
       handling: {55, 75},
       hull: {12, 22},
       shield: {0, 15},
       flak: {0, 0},
       e_count: {1, 2},
       e_dmg: {4, 10},
       x_count: {0, 2},
       x_dmg: {3, 6},
       armor: {0, 0}
     }},
    {:fighter_3,
     %{
       handling: {50, 70},
       hull: {15, 25},
       shield: {0, 0},
       flak: {0, 10},
       e_count: {0, 1},
       e_dmg: {4, 8},
       x_count: {1, 2},
       x_dmg: {8, 14},
       armor: {0, 0}
     }},
    {:fighter_4,
     %{
       handling: {65, 85},
       hull: {15, 30},
       shield: {0, 0},
       flak: {0, 0},
       e_count: {2, 4},
       e_dmg: {5, 9},
       x_count: {0, 0},
       x_dmg: {0, 0},
       armor: {0, 0}
     }},
    {:corvette_1,
     %{
       handling: {30, 45},
       hull: {50, 80},
       shield: {20, 40},
       flak: {0, 20},
       e_count: {0, 0},
       e_dmg: {0, 0},
       x_count: {1, 1},
       x_dmg: {20, 35},
       armor: {0, 0}
     }},
    {:corvette_2,
     %{
       handling: {25, 40},
       hull: {90, 130},
       shield: {15, 30},
       flak: {10, 25},
       e_count: {0, 0},
       e_dmg: {0, 0},
       x_count: {1, 1},
       x_dmg: {14, 22},
       armor: {0, 0}
     }},
    {:corvette_3,
     %{
       handling: {15, 30},
       hull: {120, 220},
       shield: {0, 30},
       flak: {0, 15},
       e_count: {3, 6},
       e_dmg: {4, 12},
       x_count: {0, 0},
       x_dmg: {0, 0},
       armor: {0, 10}
     }}
  ]

  # Representative stacks (the target tech state: fighters 4x, corvettes 2x).
  @ships %{
    fighter_2: :fighter_2v2,
    fighter_3: :fighter_3v2,
    fighter_4: :fighter_4v2,
    corvette_1: :corvette_1,
    corvette_2: :corvette_2,
    corvette_3: :corvette_3
  }
  @label %{
    fighter_2: "lightftr",
    fighter_3: "fbomber",
    fighter_4: "intcp",
    corvette_1: "Lcorv",
    corvette_2: "Hcorv",
    corvette_3: "MTcorv"
  }

  # Target: a hard-counter rock-paper-scissors. WITHIN a class, soft counters
  # (winner 55–75%, no blowouts). ACROSS classes, HARD counters (winner ≥80%) —
  # the cycle tank(MT) >> swarm(fighters) >> glass-alpha(Lcorv) >> tank(MT). Soft
  # counters across the swarm/tank divide don't exist in this model (defenses key
  # on total damage; armor is a step-function — see moduledoc), so we stop asking
  # for them and aim for a clean, decisive, non-dominant cycle instead.
  @soft [
    # within fighters: lightftr > intcp > fbomber
    {:fighter_2, :fighter_4},
    {:fighter_4, :fighter_3},
    {:fighter_2, :fighter_3},
    # within corvettes: light corvette's alpha softly out-trades heavy's shield
    {:corvette_1, :corvette_2}
  ]
  @equal [{:corvette_2, :fighter_3}]
  @hard [
    # tank hard-counters the fighter swarm (shield/hull/armor absorb small hits)
    {:corvette_3, :fighter_2},
    {:corvette_3, :fighter_3},
    {:corvette_3, :fighter_4},
    # glass-alpha hard-counters the tank (explosive pierces) and the shield-gated
    # energy interceptor
    {:corvette_1, :corvette_3},
    {:corvette_1, :fighter_4},
    # the explosive/mixed fighters swarm down the glass-alpha corvette
    {:fighter_2, :corvette_1},
    {:fighter_3, :corvette_1}
  ]

  ## Genome <-> overrides

  def random_genome do
    Enum.flat_map(@schema, fn {_ship, ranges} ->
      Enum.map(@params, fn p -> rand_in(ranges[p]) end)
    end)
  end

  def decode(genome) do
    genome
    |> Enum.chunk_every(length(@params))
    |> Enum.zip(@schema)
    |> Map.new(fn {[h, hull, sh, fl, ec, ed, xc, xd, ar], {ship, _}} ->
      {ship,
       %{
         unit_handling: h,
         unit_hull: hull,
         unit_shield: sh,
         unit_interception: fl,
         unit_armor: ar,
         unit_energy_strikes: List.duplicate(ed, ec),
         unit_explosive_strikes: List.duplicate(xd, xc)
       }}
    end)
  end

  def mutate(genome, rate) do
    genome
    |> Enum.zip(flat_ranges())
    |> Enum.map(fn {v, {lo, hi}} ->
      if hi > lo and :rand.uniform() < rate do
        step = round(:rand.normal() * ((hi - lo) * 0.25 + 1))
        (v + step) |> max(lo) |> min(hi)
      else
        v
      end
    end)
  end

  ## Evolution strategy

  @doc "Evolve ship stats toward the target RPS. Returns %{genome, loss, overrides}."
  def run(opts \\ []) do
    pop_n = Keyword.get(opts, :pop, 20)
    gens = Keyword.get(opts, :generations, 20)
    battles = Keyword.get(opts, :battles, 15)
    elite = Keyword.get(opts, :elite, 6)
    mut = Keyword.get(opts, :mutation_rate, 0.3)
    seed = Keyword.get(opts, :seed, 1)
    on_gen = Keyword.get(opts, :on_generation, fn _g, _best -> :ok end)

    Setup.install()
    :rand.seed(:exrop, {seed, seed * 7 + 1, seed * 13 + 3})

    evaluated = for _ <- 1..pop_n, do: scored(random_genome(), battles)

    {_pop, best} =
      Enum.reduce(1..gens, {evaluated, Enum.min_by(evaluated, &elem(&1, 1))}, fn g, {pop, best} ->
        elites = pop |> Enum.sort_by(&elem(&1, 1)) |> Enum.take(elite)
        elite_genomes = Enum.map(elites, &elem(&1, 0))
        offspring = for _ <- 1..(pop_n - elite), do: scored(mutate(Enum.random(elite_genomes), mut), battles)
        next = elites ++ offspring
        gen_best = Enum.min_by(next, &elem(&1, 1))
        best = if elem(gen_best, 1) < elem(best, 1), do: gen_best, else: best
        on_gen.(g, best)
        {next, best}
      end)

    {genome, loss} = best
    %{genome: genome, loss: loss, overrides: decode(genome)}
  end

  @doc "Print the achieved matrix vs the target RPS, plus the tuned stats."
  def report(overrides, battles \\ 40) do
    Setup.install_overrides(overrides)
    sym = win_fun(battles)
    idx = Setup.ship_index()

    IO.puts("Tuned stats:")

    Enum.each(@schema, fn {s, _} ->
      sd = idx[@ships[s]]

      IO.puts(
        "  #{String.pad_trailing(@label[s], 9)} hand #{sd.unit_handling} hull #{sd.unit_hull} shield #{sd.unit_shield} flak #{sd.unit_interception} armor #{sd.unit_armor} E#{inspect(sd.unit_energy_strikes, charlists: :as_lists)} X#{inspect(sd.unit_explosive_strikes, charlists: :as_lists)}"
      )
    end)

    IO.puts("SOFT within-class (want 55-75%):")

    Enum.each(@soft, fn {w, l} ->
      v = round(sym.(w, l) * 100)

      IO.puts(
        "  #{String.pad_trailing("#{@label[w]} > #{@label[l]}", 19)} #{String.pad_leading("#{v}%", 4)}  #{if v >= 55 and v <= 75, do: "ok", else: "MISS"}"
      )
    end)

    IO.puts("EQUAL (want ~50%):")

    Enum.each(@equal, fn {a, b} ->
      v = round(sym.(a, b) * 100)

      IO.puts(
        "  #{String.pad_trailing("#{@label[a]} = #{@label[b]}", 19)} #{String.pad_leading("#{v}%", 4)}  #{if v >= 40 and v <= 60, do: "ok", else: "MISS"}"
      )
    end)

    IO.puts("HARD cross-class (want winner >=80%):")

    Enum.each(@hard, fn {w, l} ->
      v = round(sym.(w, l) * 100)

      IO.puts(
        "  #{String.pad_trailing("#{@label[w]} >> #{@label[l]}", 19)} #{String.pad_leading("#{v}%", 4)}  #{if v >= 80, do: "ok", else: "MISS"}"
      )
    end)
  end

  ## internals

  defp scored(genome, battles), do: {genome, evaluate(genome, battles)}

  defp evaluate(genome, battles) do
    Setup.install_overrides(decode(genome))
    loss(win_fun(battles))
  end

  defp win_fun(battles) do
    ships = ship_keys()
    pairs = for a <- ships, b <- ships, a != b, do: {a, b}

    wr =
      pairs
      |> Task.async_stream(fn {a, b} -> {{a, b}, matchup_wr(a, b, battles)} end,
        max_concurrency: System.schedulers_online(),
        ordered: false,
        timeout: :infinity
      )
      |> Map.new(fn {:ok, kv} -> kv end)

    fn a, b -> (wr[{a, b}] + (1 - wr[{b, a}])) / 2 end
  end

  defp matchup_wr(a, b, n) do
    Arena.matchup(Fleet.mono(@ships[a], 18, id: 1), Fleet.mono(@ships[b], 18, id: 2),
      n: n,
      base_seed: 1,
      parallel: false
    ).attacker_win_rate
  end

  # Hard-counter RPS objective: soft pairs want [0.55, 0.75], equals want ~0.5,
  # and hard pairs want >=0.80 (blowouts are GOOD there, so no ceiling). The
  # no-blowout penalty applies ONLY to soft+equal pairs — those must stay close;
  # hard pairs are exempt (they're supposed to be decisive).
  defp loss(sym) do
    soft = Enum.sum(Enum.map(@soft, fn {w, l} -> band(sym.(w, l), 0.55, 0.75) end))
    equal = Enum.sum(Enum.map(@equal, fn {a, b} -> 2.0 * abs(sym.(a, b) - 0.5) end))
    hard = Enum.sum(Enum.map(@hard, fn {w, l} -> max(0.0, 0.80 - sym.(w, l)) end))
    soft_blow = Enum.sum(Enum.map(@soft ++ @equal, fn {a, b} -> blowout(sym.(a, b)) end))

    soft + equal + 2.0 * hard + 4.0 * soft_blow
  end

  defp band(w, lo, hi), do: max(0.0, lo - w) + max(0.0, w - hi)
  defp blowout(w), do: max(0.0, w - 0.75) + max(0.0, 0.25 - w)

  defp ship_keys, do: Enum.map(@schema, fn {s, _} -> s end)
  defp flat_ranges, do: Enum.flat_map(@schema, fn {_s, r} -> Enum.map(@params, fn p -> r[p] end) end)
  defp rand_in({lo, hi}), do: lo + :rand.uniform(hi - lo + 1) - 1
end

defmodule Sim.GA do
  @moduledoc """
  Multi-objective genetic search (NSGA-II) over fleet designs.

  A candidate is a `Sim.Genome` (18 ints). It is evaluated against a fixed
  *gauntlet* of opponent fleets over `:battles` Common-Random-Number battles,
  producing a metrics map; objectives are extracted from that map. NSGA-II
  then evolves the population toward the **Pareto front** — the set of designs
  where you can't improve one objective without sacrificing another.

  ## Objectives are pluggable

  Each objective is `{name, :max | :min, fn metrics -> number end}`. The default
  set is effectiveness (survival margin vs the gauntlet) traded off against
  credit and unlock cost. The metrics map also carries `:bomb` (own surviving
  bombing power), `:enemy_bomb` (the gauntlet's surviving bombing power),
  `:conquest`, and `:win_rate`, so strategic objectives are one line:

      # "retain the most bombing power, as cheaply as possible"
      objectives: [{:bomb, :max, & &1.bomb}, {:credit, :min, & &1.credit}]

      # antagonistic: "deny the enemy its bombing power" (break-the-siege defense)
      objectives: [{:deny, :min, & &1.enemy_bomb}, {:credit, :min, & &1.credit}]

  ## Reproducibility

  `:base_seed` seeds both the GA operators (init/crossover/mutation/tournament,
  in this process) and the battles (CRN — the same seeds every generation, so a
  fleet's fitness reflects the fleet, not the dice). Same seed + opts => same run.
  """

  alias Sim.{Genome, Fleet, Arena, Cost}

  # Surviving-bomb-power thresholds (multiples of 20) for strategic objectives.
  @bomb_thresholds [20, 40, 60, 80, 100, 120, 140, 160, 180, 200]

  def bomb_thresholds, do: @bomb_thresholds

  @doc "Default objectives: maximize survival margin, minimize credit and unlock cost."
  def default_objectives do
    [
      {:effectiveness, :max, & &1.margin},
      {:credit, :min, & &1.credit},
      {:unlock, :min, & &1.unlock}
    ]
  end

  @doc """
  Objective: maximize the probability the fleet **retains >= `threshold`
  bombing power** after a fight (break-the-siege offense). `threshold` should
  be a multiple of 20.
  """
  def retain_bomb(threshold),
    do: {:"retain_bomb_#{threshold}", :max, fn m -> Map.get(m.bomb_ge, threshold, 0.0) end}

  @doc """
  Antagonistic objective: maximize the probability the fleet **holds the enemy
  below `threshold` bombing power** (break-the-siege defense — deny the enemy
  the strategic capability rather than necessarily winning the battle).
  """
  def deny_bomb(threshold),
    do: {:"deny_bomb_#{threshold}", :max, fn m -> Map.get(m.enemy_bomb_lt, threshold, 0.0) end}

  @doc """
  Hard constraint: the fleet must **retain >= `power` bombing power with at least
  `certainty` probability** across the gauntlet (e.g. `retain_bomb_constraint(40, 0.8)`).
  Returns a violation function for `run/2`'s `:constraints` (0.0 = satisfied,
  positive = how far short of the required certainty). `power` is a multiple of 20.
  """
  def retain_bomb_constraint(power, certainty),
    do: fn m -> max(0.0, certainty - Map.get(m.bomb_ge, power, 0.0)) end

  @doc "Hard constraint: retain >= `power` conquest (invasion) power with >= `certainty` probability."
  def retain_conquest_constraint(power, certainty),
    do: fn m -> max(0.0, certainty - Map.get(m.conquest_ge, power, 0.0)) end

  @doc """
  Evolve fleet designs for `stage`. Returns `%{front, population, stage, objective_names}`
  where each individual is `%{genome, metrics, obj}`.

  Opts: `:pop_size` (60), `:generations` (40), `:battles` (12), `:mutation_rate`
  (1/slots), `:objectives`, `:gauntlet` (built fleets), `:base_seed` (1),
  `:on_generation` (fn gen, population -> any).
  """
  def run(stage, opts \\ []) do
    pop_size = Keyword.get(opts, :pop_size, 60)
    gens = Keyword.get(opts, :generations, 40)
    battles = Keyword.get(opts, :battles, 12)
    mut_rate = Keyword.get(opts, :mutation_rate, 1.0 / Genome.slots())
    objectives = Keyword.get(opts, :objectives, default_objectives())
    constraints = Keyword.get(opts, :constraints, [])
    base_seed = Keyword.get(opts, :base_seed, 1)
    on_gen = Keyword.get(opts, :on_generation, fn _g, _pop -> :ok end)
    num_obj = length(objectives)

    Sim.Setup.ensure_installed()
    :rand.seed(:exrop, {base_seed, base_seed * 7 + 1, base_seed * 13 + 3})

    gauntlet = Keyword.get(opts, :gauntlet) || default_gauntlet(stage)

    init = for _ <- 1..pop_size, do: Genome.random()
    parents = evaluate_population(init, stage, gauntlet, battles, base_seed, objectives, constraints)

    final =
      Enum.reduce(1..gens, parents, fn g, parents ->
        offspring_genomes = make_offspring(parents, pop_size, mut_rate, num_obj)
        offspring = evaluate_population(offspring_genomes, stage, gauntlet, battles, base_seed, objectives, constraints)
        next = select_next(parents ++ offspring, pop_size, num_obj)
        on_gen.(g, next)
        next
      end)

    %{
      front: pareto_front(final),
      population: final,
      stage: stage,
      objective_names: Enum.map(objectives, fn {n, _, _} -> n end)
    }
  end

  @doc """
  Hall-of-Fame co-evolution. Instead of a fixed gauntlet, candidates are
  evaluated against a growing archive of past champions (seeded with the
  stage's mono archetypes). This keeps raising the bar and surfaces counters
  (rock-paper-scissors), while the HoF *retains diverse champions* — so the
  local optima that mark tech / stack-size / level inflection points are
  preserved rather than steamrolled, which is what lets us read off likely
  metas.

  Returns `%{front, hall_of_fame, history, population, objective_names}`.
  `history` is a per-generation list of `%{gen, front_size, hof_size, best_margin}`.
  Opts add `:hof_size` (40) and `:sample` (opponents drawn per generation, 6)
  to the same knobs as `run/2`.
  """
  def coevolve(stage, opts \\ []) do
    pop_size = Keyword.get(opts, :pop_size, 48)
    gens = Keyword.get(opts, :generations, 30)
    battles = Keyword.get(opts, :battles, 10)
    mut_rate = Keyword.get(opts, :mutation_rate, 1.0 / Genome.slots())
    objectives = Keyword.get(opts, :objectives, default_objectives())
    base_seed = Keyword.get(opts, :base_seed, 1)
    hof_cap = Keyword.get(opts, :hof_size, 40)
    sample_n = Keyword.get(opts, :sample, 6)
    on_gen = Keyword.get(opts, :on_generation, fn _g, _pop, _hof -> :ok end)
    num_obj = length(objectives)

    Sim.Setup.ensure_installed()
    :rand.seed(:exrop, {base_seed, base_seed * 7 + 1, base_seed * 13 + 3})

    init = for _ <- 1..pop_size, do: Genome.random()

    {final, hof, history} =
      Enum.reduce(1..gens, {init, seed_hof(stage), []}, fn g, {parent_genomes, hof, history} ->
        # Re-evaluate parents AND offspring against the same opponent sample
        # this generation (the opponent set moves as the HoF grows, so stale
        # objectives from a prior generation aren't comparable).
        opponents = sample_hof(hof, sample_n)
        parents = evaluate_population(parent_genomes, stage, opponents, battles, base_seed, objectives)

        offspring =
          evaluate_population(
            make_offspring(parents, pop_size, mut_rate, num_obj),
            stage,
            opponents,
            battles,
            base_seed,
            objectives
          )

        next = select_next(parents ++ offspring, pop_size, num_obj)
        front = pareto_front(next)
        hof = add_to_hof(hof, front, stage, hof_cap, g)

        summary = %{
          gen: g,
          front_size: length(front),
          hof_size: length(hof),
          best_margin: next |> Enum.map(& &1.metrics.margin) |> Enum.max()
        }

        on_gen.(g, next, hof)
        {Enum.map(next, & &1.genome), hof, [summary | history]}
      end)

    final_eval = evaluate_population(final, stage, sample_hof(hof, sample_n), battles, base_seed, objectives)

    %{
      front: pareto_front(final_eval),
      hall_of_fame: hof,
      history: Enum.reverse(history),
      population: final_eval,
      objective_names: Enum.map(objectives, fn {n, _, _} -> n end)
    }
  end

  # Initial HoF: the stage's mono archetypes (kept as permanent anchors).
  defp seed_hof(stage) do
    tiles = Sim.Setup.tile_count()

    Enum.map(gauntlet_keys(stage), fn key ->
      %{fleet: Fleet.mono(key, tiles, id: 2), sig: "mono:#{key}", gen: 0, metrics: nil}
    end)
  end

  defp sample_hof(hof, n), do: Enum.map(Enum.take_random(hof, min(n, length(hof))), & &1.fleet)

  # Add the generation's Pareto champions to the HoF, deduped by composition.
  # Keep all gen-0 anchors plus the most recent champions up to the cap.
  defp add_to_hof(hof, front, stage, cap, gen) do
    existing = MapSet.new(hof, & &1.sig)

    additions =
      front
      |> Enum.map(fn ind -> {ind, describe(ind.genome, stage)} end)
      |> Enum.reject(fn {_ind, sig} -> sig == "" or MapSet.member?(existing, sig) end)
      |> Enum.uniq_by(fn {_ind, sig} -> sig end)
      |> Enum.map(fn {ind, sig} ->
        %{fleet: Fleet.from_genome(ind.genome, stage, id: 2), sig: sig, gen: gen, metrics: ind.metrics}
      end)

    {seeds, champs} = Enum.split_with(hof ++ additions, fn e -> e.gen == 0 end)
    seeds = Enum.uniq_by(seeds, & &1.sig)
    champs = champs |> Enum.uniq_by(& &1.sig) |> Enum.take(-max(cap - length(seeds), 0))
    seeds ++ champs
  end

  @doc """
  Antagonistic **siege arena**: co-evolve a SIEGE population (maximize the
  probability it retains >= `threshold` bombing power after a fight) against a
  DENIAL population (maximize the probability it holds the siege *below*
  `threshold`). Each side evolves against a Hall of Fame of the *other* side's
  champions — the break-a-siege vs hold-the-siege arms race. The point isn't
  winning the battle, it's the strategic outcome (does the bombing capability
  survive?), so this captures game balance rather than vacuum ship balance.

  `threshold` must be a multiple of 20 (see `bomb_thresholds/0`). Returns
  `%{siege_front, denial_front, siege_hof, denial_hof, history, threshold, stage}`.
  """
  def antagonize(stage, threshold, opts \\ []) do
    unless threshold in @bomb_thresholds do
      raise ArgumentError, "threshold must be one of #{inspect(@bomb_thresholds)}"
    end

    pop_size = Keyword.get(opts, :pop_size, 40)
    gens = Keyword.get(opts, :generations, 25)
    battles = Keyword.get(opts, :battles, 10)
    mut_rate = Keyword.get(opts, :mutation_rate, 1.0 / Genome.slots())
    base_seed = Keyword.get(opts, :base_seed, 1)
    hof_cap = Keyword.get(opts, :hof_size, 30)
    sample_n = Keyword.get(opts, :sample, 5)
    on_gen = Keyword.get(opts, :on_generation, fn _g, _summary -> :ok end)

    siege_obj = [retain_bomb(threshold), {:credit, :min, & &1.credit}]
    denial_obj = [deny_bomb(threshold), {:credit, :min, & &1.credit}]

    Sim.Setup.ensure_installed()
    :rand.seed(:exrop, {base_seed, base_seed * 7 + 1, base_seed * 13 + 3})

    siege0 = for _ <- 1..pop_size, do: Genome.random()
    denial0 = for _ <- 1..pop_size, do: Genome.random()
    # Seed each side's archive with real exemplars so both have a gradient from
    # gen 1: sieges face killers, deniers face actual bombers.
    init = {siege0, denial0, seed_bomber_hof(stage), seed_combat_hof(stage), []}

    {s_pop, d_pop, s_hof, d_hof, history} =
      Enum.reduce(1..gens, init, fn g, {s_pop, d_pop, s_hof, d_hof, history} ->
        {s_next, s_front} =
          evolve_step(s_pop, stage, sample_hof(d_hof, sample_n), pop_size, mut_rate, battles, base_seed, siege_obj)

        {d_next, d_front} =
          evolve_step(d_pop, stage, sample_hof(s_hof, sample_n), pop_size, mut_rate, battles, base_seed, denial_obj)

        s_hof = add_to_hof(s_hof, s_front, stage, hof_cap, g)
        d_hof = add_to_hof(d_hof, d_front, stage, hof_cap, g)

        summary = %{
          gen: g,
          siege_best_retain: s_next |> Enum.map(&Map.get(&1.metrics.bomb_ge, threshold, 0.0)) |> Enum.max(),
          denial_best_deny: d_next |> Enum.map(&Map.get(&1.metrics.enemy_bomb_lt, threshold, 0.0)) |> Enum.max()
        }

        on_gen.(g, summary)
        {Enum.map(s_next, & &1.genome), Enum.map(d_next, & &1.genome), s_hof, d_hof, [summary | history]}
      end)

    s_final = evaluate_population(s_pop, stage, sample_hof(d_hof, sample_n), battles, base_seed, siege_obj)
    d_final = evaluate_population(d_pop, stage, sample_hof(s_hof, sample_n), battles, base_seed, denial_obj)

    %{
      siege_front: pareto_front(s_final),
      denial_front: pareto_front(d_final),
      siege_hof: s_hof,
      denial_hof: d_hof,
      history: Enum.reverse(history),
      threshold: threshold,
      stage: stage
    }
  end

  # One generation for one population: re-evaluate parents + offspring against
  # the given opponents, then elitist-select the next generation. Shared by
  # coevolve/2 and antagonize/3.
  defp evolve_step(parent_genomes, stage, opponents, pop_size, mut_rate, battles, base_seed, objectives) do
    num_obj = length(objectives)
    parents = evaluate_population(parent_genomes, stage, opponents, battles, base_seed, objectives)

    offspring =
      evaluate_population(
        make_offspring(parents, pop_size, mut_rate, num_obj),
        stage,
        opponents,
        battles,
        base_seed,
        objectives
      )

    next = select_next(parents ++ offspring, pop_size, num_obj)
    {next, pareto_front(next)}
  end

  defp seed_bomber_hof(stage), do: mono_hof(bomber_seed_keys(stage))
  defp seed_combat_hof(stage), do: mono_hof(gauntlet_keys(stage))

  defp mono_hof(keys) do
    tiles = Sim.Setup.tile_count()
    Enum.map(keys, fn k -> %{fleet: Fleet.mono(k, tiles, id: 2), sig: "mono:#{k}", gen: 0, metrics: nil} end)
  end

  # Stage exemplar bombers (high raid_coef, ideally survivable) for siege seeding.
  defp bomber_seed_keys(:early), do: [:corvette_2, :corvette_1, :fighter_3]
  defp bomber_seed_keys(:mid), do: [:frigate_2, :frigate_3, :corvette_2, :fighter_3]
  defp bomber_seed_keys(:late), do: [:capital_2, :capital_1, :frigate_2, :corvette_2]

  @doc "Human-readable composition of a genome (counts by ship, with level)."
  def describe(genome, stage) do
    genome
    |> Genome.decode(stage)
    |> Enum.map(fn {_tile, key, level} -> {key, level} end)
    |> Enum.frequencies()
    |> Enum.sort_by(fn {_kl, n} -> -n end)
    |> Enum.map(fn {{key, level}, n} -> "#{n}x #{key}#{if level > 0, do: "@L#{level}", else: ""}" end)
    |> Enum.join(", ")
  end

  @doc "Exact per-tile composition in deployment order (tile N first), for manual validation."
  def describe_ordered(genome, stage) do
    genome
    |> Genome.decode(stage)
    |> Enum.map(fn {tile, key, level} -> "t#{tile}:#{key}#{if level > 0, do: "@L#{level}", else: ""}" end)
    |> Enum.join("  ")
  end

  ## Fitness

  defp evaluate_population(genomes, stage, gauntlet, battles, base_seed, objectives, constraints \\ []) do
    genomes
    |> Task.async_stream(
      fn g -> evaluate_one(g, stage, gauntlet, battles, base_seed, objectives, constraints) end,
      max_concurrency: System.schedulers_online(),
      ordered: true,
      timeout: :infinity
    )
    |> Enum.map(fn {:ok, ind} -> ind end)
  end

  defp evaluate_one(genome, stage, gauntlet, battles, base_seed, objectives, constraints) do
    fleet = Fleet.from_genome(genome, stage, id: 1)
    slots = Fleet.ship_slots(fleet)
    credit = Cost.build_cost(slots).credit
    unlock = Cost.unlock_cost(slots)

    results =
      Enum.map(gauntlet, fn opp ->
        Arena.matchup(fleet, opp, n: battles, base_seed: base_seed, parallel: false)
      end)

    n = max(length(results), 1)
    mean = fn f -> Enum.sum(Enum.map(results, f)) / n end

    att_bomb_vals = Enum.flat_map(results, fn r -> r.attacker_bomb_values end)
    enemy_bomb_vals = Enum.flat_map(results, fn r -> r.defender_bomb_values end)
    att_conq_vals = Enum.flat_map(results, fn r -> r.attacker_conquest_values end)
    enemy_conq_vals = Enum.flat_map(results, fn r -> r.defender_conquest_values end)

    metrics = %{
      margin: mean.(fn r -> r.mean_survival.attacker_pv_frac - r.mean_survival.defender_pv_frac end),
      win_rate: mean.(fn r -> r.attacker_win_rate end),
      bomb: mean.(fn r -> r.mean_survival.attacker_bomb end),
      enemy_bomb: mean.(fn r -> r.mean_survival.defender_bomb end),
      # P(own surviving power >= t) and P(enemy surviving power < t), per threshold
      bomb_ge: Map.new(@bomb_thresholds, fn t -> {t, prob(att_bomb_vals, &(&1 >= t))} end),
      enemy_bomb_lt: Map.new(@bomb_thresholds, fn t -> {t, prob(enemy_bomb_vals, &(&1 < t))} end),
      conquest_ge: Map.new(@bomb_thresholds, fn t -> {t, prob(att_conq_vals, &(&1 >= t))} end),
      enemy_conquest_lt: Map.new(@bomb_thresholds, fn t -> {t, prob(enemy_conq_vals, &(&1 < t))} end),
      credit: credit,
      unlock: unlock,
      ships: length(slots)
    }

    # Total constraint violation (0.0 = feasible); drives feasibility-first domination.
    violation = Enum.reduce(constraints, 0.0, fn c, acc -> acc + c.(metrics) end)

    %{
      genome: genome,
      metrics: metrics,
      obj: Enum.map(objectives, fn {_n, dir, ext} -> orient(dir, ext.(metrics)) end),
      violation: violation
    }
  end

  # Orient every objective to "higher is better" so dominance is uniform.
  defp orient(:max, v), do: v * 1.0
  defp orient(:min, v), do: -(v * 1.0)

  defp prob([], _f), do: 0.0
  defp prob(vals, f), do: Enum.count(vals, f) / length(vals)

  ## NSGA-II

  @doc "First non-dominated front (the Pareto-optimal designs), deduped by genome."
  def pareto_front(inds) do
    [first | _] = non_dominated_sort(inds)
    Enum.uniq_by(first, & &1.genome)
  end

  @doc "Strict Pareto dominance on the (already max-oriented) objective vectors."
  def dominates?(a, b) do
    pairs = Enum.zip(a.obj, b.obj)
    Enum.all?(pairs, fn {x, y} -> x >= y end) and Enum.any?(pairs, fn {x, y} -> x > y end)
  end

  # Constrained domination (Deb's feasibility-first rule): a feasible solution
  # always beats an infeasible one; among infeasible, smaller total violation
  # wins; among feasible, normal objective dominance. Individuals with no
  # :violation key are treated as feasible (so unconstrained runs are unchanged).
  defp cdominates?(a, b) do
    va = Map.get(a, :violation, 0.0)
    vb = Map.get(b, :violation, 0.0)

    cond do
      va == 0.0 and vb == 0.0 -> dominates?(a, b)
      va == 0.0 -> true
      vb == 0.0 -> false
      true -> va < vb
    end
  end

  @doc "Partition individuals into Pareto fronts (front 0 = non-dominated)."
  def non_dominated_sort(inds) do
    arr = List.to_tuple(inds)
    n = tuple_size(arr)
    idxs = Enum.to_list(0..(n - 1))

    {np, sp} =
      Enum.reduce(idxs, {%{}, %{}}, fn p, {np, sp} ->
        pp = elem(arr, p)

        {count, set} =
          Enum.reduce(idxs, {0, []}, fn q, {count, set} ->
            cond do
              q == p -> {count, set}
              cdominates?(pp, elem(arr, q)) -> {count, [q | set]}
              cdominates?(elem(arr, q), pp) -> {count + 1, set}
              true -> {count, set}
            end
          end)

        {Map.put(np, p, count), Map.put(sp, p, set)}
      end)

    first = Enum.filter(idxs, fn p -> Map.get(np, p) == 0 end)

    [first]
    |> build_fronts(np, sp)
    |> Enum.map(fn front -> Enum.map(front, fn i -> elem(arr, i) end) end)
  end

  defp build_fronts(fronts, np, sp) do
    current = List.last(fronts)

    {next_front, np} =
      Enum.reduce(current, {[], np}, fn p, acc ->
        Enum.reduce(Map.get(sp, p), acc, fn q, {nf, np} ->
          c = Map.get(np, q) - 1
          np = Map.put(np, q, c)
          if c == 0, do: {[q | nf], np}, else: {nf, np}
        end)
      end)

    if next_front == [], do: fronts, else: build_fronts(fronts ++ [next_front], np, sp)
  end

  # Crowding distance: density estimate per front member (boundary = :infinity).
  defp crowding(front, num_obj) do
    n = length(front)

    if n <= 2 do
      Enum.map(front, &Map.put(&1, :crowd, :infinity))
    else
      indexed = Enum.with_index(front)
      dist0 = Map.new(indexed, fn {_ind, i} -> {i, 0.0} end)

      dist =
        Enum.reduce(0..(num_obj - 1), dist0, fn m, dist ->
          sorted = Enum.sort_by(indexed, fn {ind, _i} -> Enum.at(ind.obj, m) end)
          {lo, _} = List.first(sorted)
          {hi, _} = List.last(sorted)

          range =
            if Enum.at(hi.obj, m) - Enum.at(lo.obj, m) == 0.0, do: 1.0, else: Enum.at(hi.obj, m) - Enum.at(lo.obj, m)

          sorted
          |> Enum.with_index()
          |> Enum.reduce(dist, fn {{_ind, gi}, pos}, dist ->
            cond do
              pos == 0 or pos == n - 1 ->
                Map.put(dist, gi, :infinity)

              Map.get(dist, gi) == :infinity ->
                dist

              true ->
                {prev, _} = Enum.at(sorted, pos - 1)
                {nxt, _} = Enum.at(sorted, pos + 1)
                add = (Enum.at(nxt.obj, m) - Enum.at(prev.obj, m)) / range
                Map.update!(dist, gi, fn cur -> cur + add end)
            end
          end)
        end)

      Enum.map(indexed, fn {ind, i} -> Map.put(ind, :crowd, Map.get(dist, i)) end)
    end
  end

  # Elitist (mu+lambda) replacement: fill by front, last front by crowding.
  defp select_next(combined, n, num_obj) do
    combined
    |> non_dominated_sort()
    |> do_select(n, num_obj, [])
  end

  defp do_select(_fronts, 0, _num_obj, acc), do: acc
  defp do_select([], _n, _num_obj, acc), do: acc

  defp do_select([front | rest], n, num_obj, acc) do
    if length(front) <= n do
      do_select(rest, n - length(front), num_obj, acc ++ front)
    else
      chosen = front |> crowding(num_obj) |> Enum.sort_by(& &1.crowd, :desc) |> Enum.take(n)
      acc ++ chosen
    end
  end

  defp make_offspring(parents, n, mut_rate, num_obj) do
    pool =
      parents
      |> non_dominated_sort()
      |> Enum.with_index()
      |> Enum.flat_map(fn {front, rank} ->
        front |> crowding(num_obj) |> Enum.map(&Map.put(&1, :rank, rank))
      end)

    for _ <- 1..n do
      p1 = tournament(pool)
      p2 = tournament(pool)
      p1.genome |> Genome.crossover(p2.genome) |> Genome.mutate(mut_rate)
    end
  end

  # Binary tournament by (rank asc, crowding desc) — the NSGA-II crowded operator.
  defp tournament(pool) do
    a = Enum.random(pool)
    b = Enum.random(pool)

    cond do
      a.rank < b.rank -> a
      b.rank < a.rank -> b
      crowd_geq?(a, b) -> a
      true -> b
    end
  end

  defp crowd_geq?(%{crowd: :infinity}, _), do: true
  defp crowd_geq?(_, %{crowd: :infinity}), do: false
  defp crowd_geq?(a, b), do: a.crowd >= b.crowd

  ## Gauntlet

  defp default_gauntlet(stage) do
    tiles = Sim.Setup.tile_count()
    Enum.map(gauntlet_keys(stage), fn key -> Fleet.mono(key, tiles, id: 2) end)
  end

  defp gauntlet_keys(:early), do: [:fighter_4, :corvette_1, :corvette_2]
  defp gauntlet_keys(:mid), do: [:fighter_4, :corvette_1, :corvette_3, :frigate_1]
  defp gauntlet_keys(:late), do: [:corvette_1, :frigate_1, :capital_1, :capital_2]
  defp gauntlet_keys(:fighters), do: [:fighter_4v2, :fighter_2v2, :fighter_3v2]
  defp gauntlet_keys(:fighters_corvettes), do: [:fighter_4v2, :corvette_1, :corvette_2, :corvette_3]
end

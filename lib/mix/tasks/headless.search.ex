defmodule Mix.Tasks.Headless.Search do
  @shortdoc "Evolve Tunable-policy genomes through generations of headless games"

  @moduledoc """
  A (μ+λ) evolution-strategy loop over `Headless.Policies.Tunable` genomes:
  mutate → evaluate over paired-seed games against a fixed opponent →
  select → repeat. The first rung of the strategy-discovery ladder: no
  prescribed orderings, just weighted capabilities and a fitness signal.

      RC_DATA_MEMORY_MODE=shared SPEEDUP=240 mix headless.search \\
        --faction myrmezir --opponent home_dev \\
        --generations 5 --population 6 --seeds 2

  Options:

    * `--faction`      — which faction the genome plays (default myrmezir)
    * `--opponent`     — fixed policy for the other faction
                         (idle | home_dev | colonizer; default home_dev)
    * `--generations`  — ES generations (default 5)
    * `--population`   — genomes per generation (default 6)
    * `--seeds`        — galaxy seeds per evaluation; deterministic
                         generation is forced so every genome sees the SAME
                         maps — paired comparison (default 2)
    * `--time-limit`   — wall-minute game clock (default 120)
    * `--systems-per-sector` — map size (default 25)
    * `--out`          — output dir for per-generation JSON (default
                         tmp/headless_search)

  Fitness per game: 10×(VP margin) + 50×win + 0.3×Σ(colony strength) +
  settle-speed bonus (earlier colonies score more). Mean over seeds.
  """

  use Mix.Task

  alias Headless.Policies.Tunable

  @opponents %{
    "idle" => Headless.Policies.Idle,
    "home_dev" => Headless.Policies.HomeDev,
    "colonizer" => Headless.Policies.Colonizer
  }

  # Fixed seed pool: deterministic generation makes each seed a reproducible
  # galaxy, so all genomes in a generation are compared on identical maps.
  @seed_pool [[692, 628, 599], [101, 202, 303], [7, 77, 777], [500, 600, 700], [42, 4242, 424_242]]

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          faction: :string,
          opponent: :string,
          opponents: :string,
          generations: :integer,
          population: :integer,
          seeds: :integer,
          time_limit: :integer,
          systems_per_sector: :integer,
          victory_points: :integer,
          out: :string
        ]
      )

    Mix.Task.run("app.start")

    # Same seed → same galaxy (see Instance.Manager.generation_concurrency).
    Application.put_env(:rc, :deterministic_generation, true)

    faction = Keyword.get(opts, :faction, "myrmezir")
    generations = Keyword.get(opts, :generations, 5)
    population = Keyword.get(opts, :population, 6)
    seeds = Enum.take(@seed_pool, Keyword.get(opts, :seeds, 3))
    out_dir = Keyword.get(opts, :out, "tmp/headless_search")
    File.mkdir_p!(out_dir)

    opponents =
      Keyword.get(opts, :opponents, Keyword.get(opts, :opponent, "home_dev"))
      |> String.split(",", trim: true)
      |> Enum.map(&resolve_opponent(&1, faction, out_dir))
      |> Enum.reject(&is_nil/1)

    # Real victory rules by default: first to the VP threshold wins outright
    # (games end early when decisive); otherwise the timer + the engine's
    # tie-break decide. 999 disables points-wins for pure-timing studies.
    game_data_base =
      Headless.Scenario.small(systems_per_sector: Keyword.get(opts, :systems_per_sector, 25))
      |> Map.put("time_limit", Keyword.get(opts, :time_limit, 120))
      |> Map.put("victory_points", Keyword.get(opts, :victory_points, 14))

    IO.puts(
      "search: faction=#{faction} vs #{Enum.map_join(opponents, "+", &elem(&1, 0))}, " <>
        "#{generations} gens × #{population} genomes × #{length(seeds)} seeds × #{length(opponents)} opponents " <>
        "(#{generations * population * length(seeds) * length(opponents)} games), SPEEDUP=#{Core.Tick.speedup()}"
    )

    initial = [Tunable.default() | Enum.map(1..(population - 1), fn _ -> Tunable.mutate(Tunable.default(), 0.25) end)]

    {best, _} =
      Enum.reduce(1..generations, {nil, initial}, fn gen, {best_so_far, genomes} ->
        scored = evaluate_generation(genomes, faction, opponents, seeds, game_data_base)
        [{top_fitness, top_genome, top_stats} | _] = scored

        mean = (scored |> Enum.map(&elem(&1, 0)) |> Enum.sum()) / length(scored)

        IO.puts(
          "gen #{gen}: best=#{Float.round(top_fitness, 1)} mean=#{Float.round(mean, 1)} " <>
            "| best genome: wins=#{top_stats.wins}/#{top_stats.games}, mean_vp=#{top_stats.mean_vp}, " <>
            "colonies=#{top_stats.mean_colonies}, first_colony=#{inspect(top_stats.mean_first_colony)}"
        )

        File.write!(
          Path.join(out_dir, "#{faction}_gen#{gen}.json"),
          Jason.encode!(%{
            generation: gen,
            results: Enum.map(scored, fn {f, g, s} -> %{fitness: f, stats: s, genome: g} end)
          })
        )

        best = best_of(best_so_far, {top_fitness, top_genome, top_stats})

        elites = scored |> Enum.take(2) |> Enum.map(&elem(&1, 1))

        offspring =
          Enum.map(1..(population - length(elites) - 1), fn i ->
            Tunable.mutate(Enum.at(elites, rem(i, length(elites))), 0.2)
          end)

        {best, elites ++ offspring ++ [Tunable.random()]}
      end)

    {fitness, genome, stats} = best
    File.write!(Path.join(out_dir, "#{faction}_best.json"), Jason.encode!(%{fitness: fitness, stats: stats, genome: genome}))

    IO.puts("\nbest overall: fitness=#{Float.round(fitness, 1)} #{inspect(stats)}")
    IO.puts("vs default, largest gene shifts:")

    genome
    |> Enum.map(fn {k, v} -> {k, v - Map.get(Tunable.default(), k, 0.0)} end)
    |> Enum.sort_by(fn {_k, d} -> -abs(d) end)
    |> Enum.take(8)
    |> Enum.each(fn {k, d} -> IO.puts("  #{k}: #{if d > 0, do: "+"}#{Float.round(d, 2)}") end)
  end

  defp best_of(nil, candidate), do: candidate
  defp best_of({f1, _, _} = a, {f2, _, _} = b), do: if(f2 > f1, do: b, else: a)

  # An opponent is a named fixed policy, or "champion" — the best genome a
  # PREVIOUS search evolved for the opposing faction (a one-step league:
  # evaluating vs past champions is the anti-cycling measure from
  # docs/game-ai.md §5.6).
  defp resolve_opponent(name, faction, out_dir) do
    case Map.get(@opponents, name) do
      nil ->
        if name == "champion" do
          other = if faction == "myrmezir", do: "tetrarchy", else: "myrmezir"
          path = Path.join(out_dir, "#{other}_best.json")

          case File.read(path) do
            {:ok, json} ->
              {"champion(#{other})", {Tunable, Jason.decode!(json)["genome"]}}

            _ ->
              IO.puts("warning: no champion at #{path}; skipping this opponent")
              nil
          end
        else
          Mix.raise("unknown opponent #{name}; known: #{Enum.join(Map.keys(@opponents), ", ")}, champion")
        end

      module ->
        {name, module}
    end
  end

  # All genome×seed×opponent games of a generation run concurrently (capped).
  defp evaluate_generation(genomes, faction, opponents, seeds, game_data_base) do
    jobs =
      for {genome, gi} <- Enum.with_index(genomes),
          seed <- seeds,
          {_name, opponent} <- opponents,
          do: {gi, genome, seed, opponent}

    results =
      jobs
      |> Task.async_stream(
        fn {gi, genome, seed, opponent} ->
          # De-synchronize instance boots: simultaneous creation storms race
          # agent registration (Character.new enumerating a not-yet-registered
          # agent's error tuple crash-loops the character market — fatal for
          # factions that must market-hire).
          Process.sleep(:rand.uniform(4_000))
          game_data = Map.put(game_data_base, "seed", seed)

          policies =
            case faction do
              "tetrarchy" -> [{Tunable, genome}, opponent]
              "myrmezir" -> [opponent, {Tunable, genome}]
            end

          {:ok, report} = Headless.Runner.run(game_data: game_data, policies: policies, players_per_faction: 1)
          {gi, game_fitness(report, faction)}
        end,
        max_concurrency: min(length(jobs), 8),
        timeout: :infinity,
        ordered: false
      )
      |> Enum.map(fn {:ok, r} -> r end)
      |> Enum.group_by(fn {gi, _} -> gi end, fn {_, f} -> f end)

    genomes
    |> Enum.with_index()
    |> Enum.map(fn {genome, gi} ->
      games = Map.get(results, gi, [])
      fitness = if games == [], do: -1.0e9, else: Enum.sum(Enum.map(games, & &1.fitness)) / length(games)

      first_colonies = games |> Enum.map(& &1.first_colony) |> Enum.reject(&is_nil/1)

      stats = %{
        games: length(games),
        wins: Enum.count(games, & &1.win),
        mean_vp: if(games == [], do: 0.0, else: Float.round(Enum.sum(Enum.map(games, & &1.vp)) / length(games), 1)),
        mean_colonies:
          if(games == [], do: 0.0, else: Float.round(Enum.sum(Enum.map(games, & &1.colonies)) / length(games), 2)),
        mean_first_colony: if(first_colonies == [], do: nil, else: Float.round(Enum.sum(first_colonies) / length(first_colonies), 0))
      }

      {fitness, genome, stats}
    end)
    |> Enum.sort_by(fn {fitness, _, _} -> -fitness end)
  end

  defp game_fitness(report, faction) do
    faction_atom = String.to_existing_atom(faction)

    my_vp = vp(report, faction_atom)
    their_vp = report.factions |> Enum.reject(&(&1.key == faction_atom)) |> Enum.map(& &1.victory_points) |> Enum.max(fn -> 0 end)

    bot = Enum.find(report.bots, fn b -> to_string(b.faction) == faction end)
    colonies = (bot && bot.colonies) || []
    strength = colonies |> Enum.map(&(&1.strength || 0)) |> Enum.sum()
    first_colony = bot && bot.first_colony_ut

    settle_bonus = if first_colony, do: max(0.0, (2400 - first_colony) / 24), else: 0.0
    win = report.winner == faction_atom

    # Victory-first: winning is what the game is for. VP totals are the
    # secondary signal (the engine's tie-break already decided `winner` at
    # the timer); colonies/strength/settle-speed remain as SMALL shaping
    # terms so early search generations have a gradient before wins exist.
    %{
      fitness:
        if(win, do: 300, else: 0) + 15 * (my_vp - their_vp) + 2 * my_vp +
          10 * length(colonies) + 0.1 * strength + settle_bonus / 2,
      win: win,
      vp: my_vp,
      colonies: length(colonies),
      first_colony: first_colony
    }
  end

  defp vp(report, faction_atom) do
    case Enum.find(report.factions, &(&1.key == faction_atom)) do
      nil -> 0
      f -> f.victory_points
    end
  end
end

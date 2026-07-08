defmodule Mix.Tasks.Headless.Marathon do
  @shortdoc "Unattended long-run trainer: all factions, varied maps, niche archives"

  @moduledoc """
  Designed to run detached for hours without oversight:

      RC_DATA_MEMORY_MODE=shared SPEEDUP=240 mix headless.marathon --hours 8

  Each iteration: pick the next faction (round-robin over all five), a
  random opponent faction, and a random synthesized map (2–5 sectors with
  neutral buffer bands, varied per-sector victory points, 12–25 systems per
  sector); build a population from that faction's NICHE ARCHIVE (best
  genome per behavior bucket — expansionist/militant/shadow combinations —
  so distinct strategies are preserved rather than collapsed into one
  champion) plus mutants and a fresh random; evaluate on paired seeds
  against sampled champions of the opponent faction plus the BOOMER
  pace-setter (Headless.Econ.boom_genome — the anti-slow-meta anchor);
  update archives; append every result to results.jsonl.

  Crash-safety: every game and every iteration is rescued — a failure skips
  that unit and the loop continues. Archives persist to disk after every
  iteration, so the run is resumable and progress is never lost. Stop any
  time; the archives ARE the output.

  Output files under `--out` (default tmp/marathon):
    archive_<faction>.json — niche champions per faction
    results.jsonl          — one line per genome evaluation
    marathon.log           — human-readable progress (via stdout redirect)
  """

  use Mix.Task

  alias Headless.Policies.Tunable

  @factions ~w(tetrarchy myrmezir ark cardan synelle)
  @seed_pool [[692, 628, 599], [101, 202, 303], [7, 77, 777], [500, 600, 700], [42, 4242, 424_242], [9, 18, 27]]

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [hours: :float, out: :string, population: :integer, seeds: :integer, concurrency: :integer]
      )

    Application.put_env(:headless, :marathon_concurrency, Keyword.get(opts, :concurrency, 5))

    Mix.Task.run("app.start")
    Application.put_env(:rc, :deterministic_generation, true)

    out = Keyword.get(opts, :out, "tmp/marathon")
    File.mkdir_p!(out)
    deadline = System.monotonic_time(:millisecond) + trunc(Keyword.get(opts, :hours, 8.0) * 3_600_000)
    population = Keyword.get(opts, :population, 6)
    n_seeds = Keyword.get(opts, :seeds, 2)

    IO.puts("marathon: factions=#{Enum.join(@factions, ",")} until +#{Keyword.get(opts, :hours, 8.0)}h, out=#{out}")

    loop(0, deadline, out, population, n_seeds)
  end

  defp loop(i, deadline, out, population, n_seeds) do
    if System.monotonic_time(:millisecond) >= deadline do
      IO.puts("marathon: deadline reached after #{i} iterations")
    else
      try do
        iterate(i, out, population, n_seeds)
      rescue
        e -> IO.puts("iteration #{i} CRASHED (skipping): #{Exception.message(e)}")
      catch
        kind, reason -> IO.puts("iteration #{i} #{kind} (skipping): #{inspect(reason)}")
      end

      loop(i + 1, deadline, out, population, n_seeds)
    end
  end

  # Team formats (user pivot 2026-07-08): production games are largely
  # human+bot or bot-filled teams, so bots must train under the presumption
  # they share a faction with another bot. Even mix of duels and team games,
  # 2-team and 3-team. {n_teams, players_per_team}. A team = one faction
  # with N bot players (victory is scored per faction, so teammates share
  # the win — the cooperation signal, such as it is, is implicit for now).
  @formats [
    {2, 1, "1v1"},
    {2, 2, "2v2"},
    {2, 3, "3v3"},
    {2, 4, "4v4"},
    {3, 3, "3v3v3"},
    {3, 2, "2v2v2"}
  ]

  defp iterate(i, out, population, n_seeds) do
    {n_teams, ppf, fmt_label} = Enum.random(@formats)

    evo = Enum.at(@factions, rem(i, length(@factions)))
    opp_factions = @factions |> List.delete(evo) |> Enum.shuffle() |> Enum.take(n_teams - 1)
    opp = hd(opp_factions)
    # Faction order == spawn/policy order downstream; evolver always first.
    all_factions = [evo | opp_factions]

    map_opts = [
      # At least n_teams bands so every team gets a distinct spawn sector.
      sectors: Enum.random(n_teams..max(n_teams, 5)),
      systems_per_sector: Enum.random(12..25),
      vp_seed: :rand.uniform(50),
      factions: all_factions,
      players_per_faction: ppf,
      # Always 14 — the real game's threshold. If fleets don't pay off
      # inside a 14-VP Fast game, that's a finding about the mode, not a
      # training knob to turn (user ruling 2026-07-04).
      victory_points: 14
    ]

    # Prefer real production-map geometry (tmp/map_pool, all <1000 systems
    # per the Fast rule) — synthetic bands stay in the mix at 20% for the
    # buffer-crossing curriculum they were built for.
    {game_data, map_desc} =
      case Headless.Scenario.pool_maps() do
        pool when pool == [] ->
          {Headless.Scenario.generate(map_opts), "bands-#{map_opts[:sectors]}x#{map_opts[:systems_per_sector]}"}

        pool ->
          if :rand.uniform() < 0.2 do
            {Headless.Scenario.generate(map_opts), "bands-#{map_opts[:sectors]}x#{map_opts[:systems_per_sector]}"}
          else
            path = Enum.random(pool)

            {Headless.Scenario.from_map(path, factions: map_opts[:factions], vp_seed: map_opts[:vp_seed]),
             Path.basename(path, ".json")}
          end
      end

    seeds = @seed_pool |> Enum.shuffle() |> Enum.take(n_seeds)

    archive = load_archive(out, evo)
    opp_archive = load_archive(out, opp)

    # Seed with the 2 FITTEST champions plus 2 RANDOM archive entries — pure
    # best-N seeding lets an early local maximum crowd every population;
    # random archive picks keep injected/niche strategies getting play time.
    sorted = archive |> Map.values() |> Enum.sort_by(&(-&1["fitness"]))
    champions = (Enum.take(sorted, 2) ++ (sorted |> Enum.drop(2) |> Enum.take_random(2))) |> Enum.map(& &1["genome"])

    pop =
      (champions ++
         Enum.map(1..max(population - length(champions) - 1, 1), fn _ ->
           Tunable.mutate(Enum.random([Tunable.default() | champions]), 0.2)
         end) ++ [Tunable.random()])
      |> Enum.take(population)

    # Baseline anchor: every evaluation includes the BOOMER pace-setter
    # alongside sampled champions — self-play-only pools drift into
    # private equilibria (first the HomeDev-era turtle stalemate, then
    # the slow-tempo meta the 2026-07-07 live game exposed: a human
    # out-developed the shipped champion 3-4x on every axis). The boomer
    # races econ on the assumption the opponent is doing the same; a
    # genome that can't beat or out-tempo it stops winning evals.
    opponents =
      opp_archive
      |> Map.values()
      |> Enum.shuffle()
      |> Enum.take(2)
      |> Enum.map(fn c -> {Tunable, c["genome"]} end)
      |> then(&[{Tunable, Headless.Econ.boom_genome()} | &1])

    results = evaluate(pop, evo, opponents, seeds, game_data, map_opts)

    {archive, promoted} =
      Enum.reduce(results, {archive, 0}, fn {genome, fitness, stats}, {arch, n} ->
        bucket = niche(stats, genome)
        current = Map.get(arch, bucket)

        if current == nil or fitness > current["fitness"] do
          {Map.put(arch, bucket, %{"fitness" => fitness, "genome" => genome, "stats" => stats}), n + 1}
        else
          {arch, n}
        end
      end)

    save_archive(out, evo, archive)
    append_results(out, i, evo, opp, map_desc, results, n_teams, ppf)

    best = results |> Enum.map(&elem(&1, 1)) |> Enum.max(fn -> 0 end)

    IO.puts(
      "iter #{i}: #{fmt_label} #{evo} vs #{Enum.join(opp_factions, "+")} | " <>
        "map=#{map_desc} (#{length(game_data["systems"])} systems) | " <>
        "best=#{Float.round(best / 1, 1)} promoted=#{promoted} niches=#{map_size(archive)}"
    )
  end

  defp evaluate(pop, faction, opponents, seeds, game_data, map_opts) do
    jobs = for {genome, gi} <- Enum.with_index(pop), seed <- seeds, opponent <- opponents, do: {gi, genome, seed, opponent}

    ppf = Keyword.get(map_opts, :players_per_faction, 1)
    # In a 3-team game the evolver + the tested opponent hold two factions;
    # any remaining faction is filled by the boomer pace-setter (a stable,
    # non-degenerate third party). The evolver is ALWAYS faction index 0
    # (iterate builds map_opts[:factions] as [evo | opp_factions]).
    extra = List.duplicate({Tunable, Headless.Econ.boom_genome()}, max(length(map_opts[:factions]) - 2, 0))

    # async_stream_NOLINK: a crashed game (e.g. a bot hitting an engine edge
    # case) must yield an {:exit, _} entry, not an exit SIGNAL — linked task
    # crashes kill the caller in ways rescue/catch cannot intercept, which
    # is how night one ended after 81 iterations.
    results =
      jobs
      |> then(
        &Task.Supervisor.async_stream_nolink(
          RC.TaskSupervisor,
          &1,
          fn {gi, genome, seed, opponent} ->
          Process.sleep(:rand.uniform(3_000))
          gd = Map.put(game_data, "seed", seed)

          policies = [{Tunable, genome}, opponent | extra]

          case Headless.Runner.run(game_data: gd, policies: policies, players_per_faction: ppf) do
            {:ok, report} -> {gi, fitness_and_stats(report, faction)}
            _ -> nil
          end
        end,
        max_concurrency: Application.get_env(:headless, :marathon_concurrency, 5),
        timeout: 600_000,
        on_timeout: :kill_task,
        ordered: false
        )
      )
      |> Enum.flat_map(fn
        {:ok, {gi, r}} -> [{gi, r}]
        _ -> []
      end)
      |> Enum.group_by(fn {gi, _} -> gi end, fn {_, r} -> r end)

    pop
    |> Enum.with_index()
    |> Enum.flat_map(fn {genome, gi} ->
      case Map.get(results, gi, []) do
        [] ->
          []

        games ->
          fitness = Enum.sum(Enum.map(games, & &1.fitness)) / length(games)

          stats = %{
            "games" => length(games),
            "wins" => Enum.count(games, & &1.win),
            "mean_vp" => Float.round(Enum.sum(Enum.map(games, & &1.vp)) / length(games), 1),
            "colonies" => Float.round(Enum.sum(Enum.map(games, & &1.colonies)) / length(games), 2),
            "military" => Float.round(Enum.sum(Enum.map(games, & &1.military)) / length(games), 2),
            "covert" => Float.round(Enum.sum(Enum.map(games, & &1.covert)) / length(games), 2),
            "dominion_flips" => Float.round(Enum.sum(Enum.map(games, & &1.flips)) / length(games), 2),
            # Fraction of games whose opening book ran to completion —
            # a deployment gate input (game-ai-v2.md §V2.1).
            "opener_rate" => Float.round(Enum.count(games, & &1.opener) / length(games), 2),
            "mean_their_vp" => Float.round(Enum.sum(Enum.map(games, & &1.their_vp)) / length(games), 1),
            # Win-game-only means: the user-facing export gates ask "when
            # this champion WINS, does it look like a real player's win?"
            # (10+ VP, multiple systems) — all-game means dilute wins with
            # losses and understate exactly the games humans would see.
            "mean_win_vp" => win_mean(games, & &1.vp),
            "mean_win_colonies" => win_mean(games, & &1.colonies),
            "mean_duration_ut" => mean_duration(games),
            # Per-key usage summed across the eval's games:
            # %{patent: %{key => n}, doctrine: ..., build: ..., ship: ..., mission: ...}
            "usage" => merge_usage(games)
          }

          [{genome, fitness, stats}]
      end
    end)
  end

  defp win_mean(games, fun) do
    case Enum.filter(games, & &1.win) do
      [] -> nil
      wins -> Float.round(Enum.sum(Enum.map(wins, fun)) / length(wins), 2)
    end
  end

  defp mean_duration(games) do
    case Enum.reject(Enum.map(games, & &1.duration_ut), &is_nil/1) do
      [] -> nil
      ds -> Float.round(Enum.sum(ds) / length(ds), 1)
    end
  end

  defp merge_usage(games) do
    Enum.reduce(games, %{}, fn game, acc ->
      Enum.reduce(game.usage, acc, fn {group, keys}, acc ->
        Map.update(acc, group, keys, fn existing ->
          Map.merge(existing, keys, fn _k, a, b -> a + b end)
        end)
      end)
    end)
  end

  defp fitness_and_stats(report, faction) do
    faction_atom = String.to_existing_atom(faction)
    my_vp = report.factions |> Enum.find(%{victory_points: 0}, &(&1.key == faction_atom)) |> Map.get(:victory_points)

    their_vp =
      report.factions |> Enum.reject(&(&1.key == faction_atom)) |> Enum.map(& &1.victory_points) |> Enum.max(fn -> 0 end)

    bot = Enum.find(report.bots, fn b -> to_string(b.faction) == faction end) || %{}
    ok = Map.get(bot, :ok, %{})
    colonies = Map.get(bot, :colonies, []) || []
    win = report.winner == faction_atom

    military = Map.get(ok, {:mission, "raid"}, 0) + Map.get(ok, {:mission, "conquest"}, 0)

    covert =
      Map.get(ok, {:mission, "infiltrate"}, 0) + Map.get(ok, {:mission, "encourage_hate"}, 0) +
        Map.get(ok, {:mission, "make_dominion"}, 0) + Map.get(ok, {:mission, "assassination"}, 0) +
        Map.get(ok, {:mission, "conversion"}, 0)

    # Per-key usage: which patents/lexes/buildings/ships/missions this bot
    # actually executed this game (tally keys from Headless.Bot.tally/3).
    usage =
      Enum.reduce(ok, %{}, fn
        {{group, key}, n}, acc when group in [:patent, :doctrine, :build, :ship, :mission] ->
          Map.update(acc, group, %{key => n}, &Map.put(&1, key, Map.get(&1, key, 0) + n))

        _, acc ->
          acc
      end)

    opener = (Map.get(bot, :policy_mem) || %{}) |> Map.get(:opener) || %{}
    opener_ok = Map.get(opener, :done, false) and not Map.get(opener, :timed_out, false)

    # V2.1 stalemate discount: a "win" that never cleared 8 VP is clock-out
    # attrition against an opponent playing equally badly, not proof of
    # play — worth well under half the real thing.
    win_bonus =
      cond do
        not win -> 0
        my_vp >= 8 -> 300
        true -> 120
      end

    %{
      fitness: win_bonus + 15 * (my_vp - their_vp) + 2 * my_vp + 10 * length(colonies),
      win: win,
      vp: my_vp,
      their_vp: their_vp,
      colonies: length(colonies),
      military: military,
      covert: covert,
      flips: Map.get(ok, :to_dominion, 0),
      opener: opener_ok,
      usage: usage,
      # Game clock consumed (UT). ut_time_left is what REMAINED at the
      # winner declaration; time-outs report ~0 left.
      duration_ut: report[:ut_time_left] && Float.round(2400.0 - report.ut_time_left, 1)
    }
  end

  # Behavior niche: which of the three macro styles this genome actually
  # PLAYED (not what its weights say), plus a structural-size dimension —
  # structurally novel genomes compete against their own kind while their
  # weights adapt (NEAT-style innovation protection on MAP-Elites buckets;
  # game-ai-v2.md §2). 8 behavior × 3 structure = 24 buckets per faction.
  defp niche(stats, genome) do
    structure =
      case Headless.Policies.Tunable.structure_size(genome) do
        n when n <= 7 -> "sA"
        n when n <= 11 -> "sB"
        _ -> "sC"
      end

    "exp#{if stats["colonies"] >= 2, do: 1, else: 0}" <>
      "mil#{if stats["military"] >= 1, do: 1, else: 0}" <>
      "shd#{if stats["covert"] >= 2, do: 1, else: 0}" <> structure
  end

  defp load_archive(out, faction) do
    case File.read(Path.join(out, "archive_#{faction}.json")) do
      {:ok, json} -> Jason.decode!(json)
      _ -> %{}
    end
  end

  defp save_archive(out, faction, archive) do
    File.write!(Path.join(out, "archive_#{faction}.json"), Jason.encode!(archive))
  end

  defp append_results(out, iter, evo, opp, map_desc, results, n_factions, ppf) do
    lines =
      Enum.map(results, fn {genome, fitness, stats} ->
        Jason.encode!(%{
          iter: iter,
          at: System.system_time(:second),
          faction: evo,
          opponent: opp,
          map: map_desc,
          n_factions: n_factions,
          players_per_faction: ppf,
          fitness: fitness,
          stats: stats,
          genome: genome
        })
      end)

    File.write!(Path.join(out, "results.jsonl"), Enum.join(lines, "\n") <> "\n", [:append])
  end
end

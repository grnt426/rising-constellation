defmodule Mix.Tasks.Headless.Smoke do
  @shortdoc "Fixed-seed smoke suite: 'is this change broken?' in minutes, not overnight"

  @moduledoc """
  The fast half of the dev-pace split (user pivot 2026-07-18): the smoke
  suite answers "does the policy code still play a full game?" in minutes,
  so the marathon only ever answers "is it better?". Run it after every
  policy/strategist/budget change BEFORE the change enters the marathon.

      SPEEDUP=240 mix headless.smoke               # all flags ON (exercise new code)
      SPEEDUP=240 mix headless.smoke --flags none  # baseline behavior
      SPEEDUP=240 mix headless.smoke --flags first_colony_guarantee,income_gated_lanes

  Fixed geometry (deterministic bands map), fixed seed pool, default
  genome vs the boomer pace-setter. Checks per game: the engine survived
  (decision count), the opener completed, and colonization happened; also
  prints the guarantee/gate counters so a flag that never fires is
  visible immediately.

  Options: --games N (default 6), --concurrency N (default 3),
  --flags all|none|csv (default all), --faction f --opponent f.
  """

  use Mix.Task

  alias Headless.Policies.Tunable

  @seed_pool [[692, 628, 599], [101, 202, 303], [7, 77, 777]]

  # Counters that exist to prove a code path fired (printed even when zero).
  # transport_first_guarantee is hard-coded since 2026-07-19; second_lane
  # only fires in expansion phase with 2+ open slots (may be zero in a short
  # smoke). dev_ladder (hard-coded 2026-07-20) is verified through build
  # usage (production floor); quality_siting through colony placement.
  @flag_counters [:transport_first_guarantee, :second_lane_guarantee]

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [games: :integer, concurrency: :integer, flags: :string, faction: :string, opponent: :string]
      )

    Mix.Task.run("app.start")
    Application.put_env(:rc, :deterministic_generation, true)

    n_games = Keyword.get(opts, :games, 6)
    conc = Keyword.get(opts, :concurrency, 3)
    flags = Headless.Flags.parse(Keyword.get(opts, :flags, "all"))
    faction = Keyword.get(opts, :faction, "myrmezir")
    opp = Keyword.get(opts, :opponent, "cardan")

    # Same galaxy every run: fixed generation options + fixed RNG seed.
    :rand.seed(:exsss, {42, 42, 42})

    game_data =
      Headless.Scenario.generate(
        sectors: 2,
        systems_per_sector: 16,
        vp_seed: 7,
        factions: [faction, opp],
        players_per_faction: 1,
        victory_points: 14
      )

    genome = Map.put(Tunable.default(), "_flags", flags)
    boomer = Headless.Econ.boom_genome()
    flags_on = flags |> Enum.filter(fn {_, v} -> v end) |> Enum.map(&elem(&1, 0))

    IO.puts(
      "smoke: #{n_games} games, #{faction} (default genome) vs #{opp} (boomer) | " <>
        "speedup=#{Core.Tick.speedup()} | flags on: #{inspect(flags_on)}"
    )

    games =
      @seed_pool
      |> Stream.cycle()
      |> Enum.take(n_games)
      |> Enum.with_index()
      |> Task.async_stream(
        fn {seed, idx} ->
          gd = Map.put(game_data, "seed", seed)

          case Headless.Runner.run(game_data: gd, policies: [{Tunable, genome}, {Tunable, boomer}], players_per_faction: 1) do
            {:ok, report} -> {idx, summarize(report, faction)}
            other -> {idx, {:failed, other}}
          end
        end,
        max_concurrency: conc,
        timeout: 900_000,
        on_timeout: :kill_task,
        ordered: true
      )
      |> Enum.map(fn
        {:ok, {idx, summary}} -> {idx, summary}
        {:exit, reason} -> {nil, {:failed, {:exit, reason}}}
      end)

    report(games, flags_on)
  end

  defp summarize(report, faction) do
    faction_atom = String.to_existing_atom(faction)
    bot = Enum.find(report.bots, fn b -> to_string(b.faction) == faction end) || %{}
    mem = Map.get(bot, :policy_mem) || %{}
    blocks = Map.get(mem, :blocks) || %{}
    opener = Map.get(mem, :opener) || %{}
    my_vp = report.factions |> Enum.find(%{victory_points: 0}, &(&1.key == faction_atom)) |> Map.get(:victory_points)

    builds =
      bot
      |> Map.get(:ok, %{})
      |> Enum.flat_map(fn
        {{:build, key}, n} -> [{key, n}]
        _ -> []
      end)
      |> Map.new()

    %{
      decisions: bot |> Map.get(:phase_tally, %{}) |> Map.values() |> Enum.sum(),
      colonies: length(Map.get(bot, :colonies, []) || []),
      funnel: Map.get(bot, :funnel, 0),
      opener_ok: Map.get(opener, :done, false) and not Map.get(opener, :timed_out, false),
      win: report.winner == faction_atom,
      vp: my_vp,
      duration_ut: report[:ut_time_left] && Float.round(2400.0 - report.ut_time_left, 1),
      blocks: blocks,
      builds: builds,
      cycle: Map.get(mem, :colony_log) || []
    }
  end

  defp report(games, flags_on) do
    {ok, failed} = Enum.split_with(games, fn {_, s} -> is_map(s) end)

    Enum.each(games, fn
      {idx, %{} = s} ->
        IO.puts(
          "  game #{idx}: #{if s.win, do: "WIN ", else: "loss"} vp=#{s.vp} " <>
            "colonies=#{s.colonies} funnel=#{s.funnel} decisions=#{s.decisions} " <>
            "dur=#{s.duration_ut} opener=#{if s.opener_ok, do: "ok", else: "INCOMPLETE"}"
        )

      {idx, {:failed, reason}} ->
        IO.puts("  game #{inspect(idx)}: FAILED #{inspect(reason)}")
    end)

    summaries = Enum.map(ok, &elem(&1, 1))

    if summaries != [] do
      blocks =
        Enum.reduce(summaries, %{}, fn s, acc ->
          Map.merge(acc, s.blocks, fn _k, a, b -> a + b end)
        end)

      top =
        blocks
        |> Enum.sort_by(fn {_, v} -> -v end)
        |> Enum.take(8)
        |> Enum.map_join(" ", fn {k, v} -> "#{k}=#{v}" end)

      counters = Enum.map_join(@flag_counters, " ", fn c -> "#{c}=#{Map.get(blocks, c, 0)}" end)

      cycles = Enum.flat_map(summaries, & &1.cycle)

      cycle_line =
        case cycles do
          [] ->
            "no completed colony tasks"

          _ ->
            n = length(cycles)
            mean = fn key -> Float.round(Enum.sum(Enum.map(cycles, &Map.get(&1, key, 0))) / n, 0) end
            "n=#{n} wait=#{mean.(:wait)} build=#{mean.(:build)} idle=#{mean.(:idle)} voyage=#{mean.(:voyage)}"
        end

      all_builds =
        Enum.reduce(summaries, %{}, fn s, acc ->
          Map.merge(acc, Map.get(s, :builds, %{}), fn _k, a, b -> a + b end)
        end)

      builds_top =
        all_builds
        |> Enum.sort_by(fn {_, v} -> -v end)
        |> Enum.take(8)
        |> Enum.map_join(" ", fn {k, v} -> "#{k}=#{v}" end)

      IO.puts("\n  blocks (top): #{top}")
      IO.puts("  builds (top): #{builds_top}")
      IO.puts("  flag counters: #{counters}")
      IO.puts("  colony cycle: #{cycle_line}")
    end

    # Verdict: hard failures are things no overnight run should ever inherit.
    # Decision counts are LOAD-SENSITIVE (each bot cycle stretches with view
    # latency under host contention — a busy box halves them), so the
    # engine-alive line is duration + a crashed-engine floor (~26 decisions),
    # not a throughput bar.
    checks = [
      {"all games completed", failed == []},
      {"engine alive (decisions >= 150 & duration >= 1500 UT every game)",
       summaries != [] and
         Enum.all?(summaries, &(&1.decisions >= 150 and (&1.duration_ut || 0) >= 1500))},
      {"opener completed every game", summaries != [] and Enum.all?(summaries, & &1.opener_ok)},
      {"colonization occurred (any game)", Enum.any?(summaries, &(&1.colonies > 0))}
    ]

    IO.puts("")
    Enum.each(checks, fn {name, pass} -> IO.puts("  #{if pass, do: "PASS", else: "FAIL"}  #{name}") end)

    if Enum.all?(checks, &elem(&1, 1)) do
      IO.puts("\nsmoke: PASS (flags on: #{inspect(flags_on)})")
    else
      IO.puts("\nsmoke: FAIL — do NOT hand this build to the marathon")
    end
  end
end

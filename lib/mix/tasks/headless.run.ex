defmodule Mix.Tasks.Headless.Run do
  @shortdoc "Run headless turbo Fast game(s) and print timing/load reports"

  @moduledoc """
  Run one or more headless Fast games at the compiled SPEEDUP and report
  wall-clock, outcome, and load statistics.

      SPEEDUP=120 mix headless.run [--games 1] [--bots 1] [--time-limit 120]
                                   [--no-bots] [--bot-interval 500]

  Options:

    * `--games`        — how many games, sequential (default 1)
    * `--bots`         — bot players per faction (default 1)
    * `--no-bots`      — engine-only run (no bot drivers)
    * `--time-limit`   — wall-minute limit override (scenario default: 120)
    * `--bot-interval` — bot decision cadence, wall ms (default 500)

  `SPEEDUP` is read at runtime (once per BEAM, see `Core.Tick.speedup/0`),
  so varying it per run needs no recompile.
  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          games: :integer,
          bots: :integer,
          time_limit: :integer,
          no_bots: :boolean,
          bot_interval: :integer,
          victory_points: :integer,
          parallel: :integer,
          systems_per_sector: :integer,
          policies: :string,
          bot_interval_ut: :integer
        ]
      )

    Mix.Task.run("app.start")

    games = Keyword.get(opts, :games, 1)

    runner_opts =
      [
        players_per_faction: Keyword.get(opts, :bots, 1),
        bots: not Keyword.get(opts, :no_bots, false),
        bot_interval_ut: Keyword.get(opts, :bot_interval_ut, 3),
        policies: parse_policies(Keyword.get(opts, :policies, "idle"))
      ] ++
        if(opts[:time_limit], do: [time_limit: opts[:time_limit]], else: []) ++
        if(opts[:victory_points], do: [victory_points: opts[:victory_points]], else: []) ++
        if(opts[:systems_per_sector],
          do: [game_data: Headless.Scenario.small(systems_per_sector: opts[:systems_per_sector])],
          else: []
        )

    IO.puts(
      "headless: #{games} game(s), SPEEDUP=#{Core.Tick.speedup()}, " <>
        "bots/faction=#{runner_opts[:players_per_faction]} (#{if runner_opts[:bots], do: "on", else: "off"}), " <>
        "memory_mode=#{Data.Data.memory_mode()}, schedulers=#{System.schedulers_online()}"
    )

    parallel = Keyword.get(opts, :parallel, 1)

    # Pre-create the bot-profile pool before fanning out so concurrent runs
    # don't race the get-or-create (rows are shared across games; player agents
    # are registered per-instance so ids can't collide).
    Headless.Runner.ensure_bot_profiles(2 * runner_opts[:players_per_faction] * max(parallel, 1))

    Headless.Cpu.enable()
    mem_before_mb = div(:erlang.memory(:total), 1024 * 1024)
    cpu0 = Headless.Cpu.snapshot()
    batch_t0 = System.monotonic_time(:millisecond)

    reports =
      1..games
      |> Task.async_stream(
        fn _n -> {:ok, report} = Headless.Runner.run(runner_opts); report end,
        max_concurrency: parallel,
        ordered: false,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, report} -> report end)

    batch_ms = System.monotonic_time(:millisecond) - batch_t0
    batch_cpu = Headless.Cpu.delta(cpu0, Headless.Cpu.snapshot())

    reports |> Enum.with_index(1) |> Enum.each(fn {report, n} -> print_report(n, report) end)
    print_summary(reports, batch_ms, batch_cpu, mem_before_mb)
  end

  defp print_report(n, r) do
    IO.puts("""
    ── game #{n} ────────────────────────────────────────────────
      result        #{r.result}   winner=#{inspect(r.winner)}   ut_time_left=#{r.ut_time_left}
      factions      #{Enum.map_join(r.factions, "  ", fn f -> "#{f.key}=#{f.victory_points}VP" end)}
      boot          #{r.boot_ms} ms   destroy #{r.destroy_ms} ms
      run           #{r.wall_ms} ms (expected ~#{r.expected_wall_ms} ms at SPEEDUP=#{r.speedup})
      load          run_queue max=#{r.load.max_run_queue} avg=#{r.load.avg_run_queue}  peak_mem=#{r.load.peak_mem_mb}MB  peak_procs=#{r.load.peak_procs}
      cpu           busy=#{r.cpu.busy_seconds}s util=#{Float.round(r.cpu.util * 100, 1)}% (boot→destroy; solo runs only)
    #{Enum.map_join(r.bots, "\n", &format_bot/1)}
    """)
  end

  defp format_bot(b) do
    think_ms = div(b.view_us + b.decide_us + b.act_us, 1000)

    "  bot [#{b.faction}] #{inspect(b.policy)} — #{b.decisions} decisions, #{think_ms}ms think " <>
      "(view #{div(b.view_us, 1000)} / decide #{div(b.decide_us, 1000)} / act #{div(b.act_us, 1000)}), " <>
      "first_colony_ut=#{inspect(b.first_colony_ut)} colonies=#{inspect(Map.get(b, :colonies, []))}\n" <>
      "      ok=#{inspect(b.ok)} refused=#{inspect(b.refused)}\n" <>
      "      mem=#{inspect(Map.drop(Map.get(b, :policy_mem) || %{}, [:target_scores]))}"
  end

  @policy_names %{
    "idle" => Headless.Policies.Idle,
    "home_dev" => Headless.Policies.HomeDev,
    "colonizer" => Headless.Policies.Colonizer,
    "tunable" => Headless.Policies.Tunable
  }

  defp parse_policies(str) do
    str
    |> String.split(",", trim: true)
    |> Enum.map(fn name ->
      Map.get(@policy_names, String.trim(name)) ||
        Mix.raise("unknown policy #{name}; known: #{Enum.join(Map.keys(@policy_names), ", ")}")
    end)
  end

  defp print_summary(reports, batch_ms, batch_cpu, mem_before_mb) do
    n = length(reports)
    walls = Enum.map(reports, & &1.wall_ms)
    boots = Enum.map(reports, & &1.boot_ms)
    peak_mem = reports |> Enum.map(& &1.load.peak_mem_mb) |> Enum.max(fn -> 0 end)

    IO.puts("""
    ── summary (#{n} game#{if n > 1, do: "s"} in #{batch_ms} ms) ─────────────────────────
      run ms     min=#{Enum.min(walls)} avg=#{div(Enum.sum(walls), n)} max=#{Enum.max(walls)}
      boot ms    min=#{Enum.min(boots)} avg=#{div(Enum.sum(boots), n)} max=#{Enum.max(boots)}
      cpu        batch busy=#{batch_cpu.busy_seconds}s (#{Float.round(batch_cpu.busy_seconds / n, 1)}s/game) util=#{Float.round(batch_cpu.util * 100, 1)}% of #{System.schedulers_online()} schedulers
      memory     before=#{mem_before_mb}MB peak=#{peak_mem}MB (Δ=#{peak_mem - mem_before_mb}MB across #{n} concurrent-max)
      throughput #{Float.round(n * 60_000 / batch_ms, 2)} games/min · #{round(n * 86_400_000 / batch_ms)} games/day (at this concurrency)
    """)
  end
end

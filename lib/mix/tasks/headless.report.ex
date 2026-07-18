defmodule Mix.Tasks.Headless.Report do
  @shortdoc "Rich digest of a marathon run: games, factions, usage, lineages"

  @moduledoc """
  The standard training-run report (replaces ad-hoc analysis scripts):

      mix headless.report                       # latest run segment
      mix headless.report --out tmp/marathon_night --runs 2
      mix headless.report --since-hours 12

  Sections: run overview, error census, game shape (length/VP/factions),
  wins by faction, opening-book variants, per-key USAGE leaderboards
  (patents/lexes/buildings/ships/missions — requires evals recorded after
  the 2026-07-06 instrumentation), archive state. Segment = one marathon
  process lifetime (iter counter reset marks a new segment).
  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args, strict: [out: :string, runs: :integer, since_hours: :float])

    dir = Keyword.get(opts, :out, "tmp/marathon_night")
    evals = load(Path.join(dir, "results.jsonl"), Keyword.get(opts, :runs, 1), opts[:since_hours])

    if evals == [] do
      Mix.shell().error("no evals found")
    else
      overview(evals)
      census(Path.join(dir, "marathon.log"))
      game_shape(evals)
      flag_arms(evals)
      wins_by_faction(evals)
      books(evals)
      usage(evals)
      archives(dir)
    end
  end

  defp load(path, runs, since_hours) do
    evals =
      path
      |> File.stream!()
      |> Enum.flat_map(fn line ->
        case Jason.decode(String.trim(line)) do
          {:ok, j} -> [j]
          _ -> []
        end
      end)

    evals =
      case since_hours do
        nil ->
          # Last N segments (iter resets mark marathon restarts).
          starts =
            [0] ++
              for {prev, cur, i} <- Enum.zip([evals, tl(evals), 1..(length(evals) - 1)]),
                  cur["iter"] == 0 and prev["iter"] != 0,
                  do: i

          Enum.drop(evals, Enum.at(starts, max(length(starts) - runs, 0)))

        h ->
          cutoff = System.system_time(:second) - trunc(h * 3600)
          Enum.filter(evals, &(&1["at"] >= cutoff))
      end

    evals
  end

  defp overview(evals) do
    hours = (List.last(evals)["at"] - hd(evals)["at"]) / 3600
    games = Enum.sum(Enum.map(evals, & &1["stats"]["games"]))

    section("Run overview")

    line(
      "#{length(evals)} evals · #{games} games · #{r1(hours)}h span · " <>
        "#{if hours > 0, do: round(length(evals) / hours), else: 0} evals/h · " <>
        "iters 0-#{List.last(evals)["iter"]}"
    )
  end

  defp census(log_path) do
    case File.read(log_path) do
      {:ok, log} ->
        seg = String.slice(log, max(0, byte_size(log) - 2_000_000), 2_000_000)

        section("Error census (log tail)")

        for pat <- ["CRASHED", "GenServer {Game.Registry", "aborting unprocessable", "[supervisor]"] do
          n = seg |> String.split(pat) |> length() |> Kernel.-(1)
          line("#{String.pad_trailing(pat, 28)} #{n}")
        end

      _ ->
        :ok
    end
  end

  defp game_shape(evals) do
    section("Game shape")
    nf = evals |> Enum.map(&(&1["n_factions"] || 2)) |> Enum.frequencies()
    ppf = evals |> Enum.map(&(&1["players_per_faction"] || 1)) |> Enum.frequencies()
    line("factions per game: #{inspect(nf)} · players per faction: #{inspect(ppf)} (bots on all sides in training)")

    durations = evals |> Enum.map(& &1["stats"]["mean_duration_ut"]) |> Enum.reject(&is_nil/1)

    if durations != [] do
      line(
        "game length (UT of 2400): mean #{r1(mean(durations))} · min #{r1(Enum.min(durations))} · " <>
          "max #{r1(Enum.max(durations))} (#{length(durations)} instrumented evals)"
      )
    else
      line("game length: no instrumented evals yet (recorded from 2026-07-06 onward)")
    end

    vps = Enum.map(evals, & &1["stats"]["mean_vp"])
    theirs = evals |> Enum.map(& &1["stats"]["mean_their_vp"]) |> Enum.reject(&is_nil/1)
    line("evolver VP: mean #{r1(mean(vps))}" <> if(theirs != [], do: " · opponent VP: mean #{r1(mean(theirs))}", else: ""))

    zc = Enum.count(evals, &(&1["stats"]["colonies"] == 0))
    line("zero-colony evals: #{pct(zc, length(evals))} · colonies/eval #{r2(mean(Enum.map(evals, & &1["stats"]["colonies"])))}")
  end

  # Per-flag A/B arms (Headless.Flags, 2026-07-18 pivot): every eval line
  # carries the iteration's flag assignment; each flag splits the window
  # into on/off arms — the attribution read for parallel experiments.
  defp flag_arms(evals) do
    flagged = Enum.filter(evals, &is_map(&1["flags"]))

    if flagged != [] do
      section("Experiment flags (A/B arms)")

      flagged
      |> Enum.flat_map(&Map.keys(&1["flags"]))
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.each(fn flag ->
        {on, off} = Enum.split_with(flagged, & &1["flags"][flag])
        line("#{flag}:")

        for {label, arm} <- [{"  on ", on}, {"  off", off}] do
          if arm == [] do
            line("#{label}  (no evals)")
          else
            wins = Enum.sum(Enum.map(arm, & &1["stats"]["wins"]))
            games = Enum.sum(Enum.map(arm, & &1["stats"]["games"]))
            zc = Enum.count(arm, &(&1["stats"]["colonies"] == 0))
            fits = Enum.map(arm, & &1["fitness"])

            line(
              "#{label} #{String.pad_leading(to_string(length(arm)), 4)} evals · " <>
                "winrate #{String.pad_leading(pct(wins, games), 4)} · " <>
                "col/eval #{r2(mean(Enum.map(arm, & &1["stats"]["colonies"])))} · " <>
                "zero-col #{String.pad_leading(pct(zc, length(arm)), 4)} · " <>
                "fit mean #{round(mean(fits))}"
            )
          end
        end
      end)
    end
  end

  defp wins_by_faction(evals) do
    section("Wins by faction (as evolver)")

    evals
    |> Enum.group_by(& &1["faction"])
    |> Enum.sort_by(fn {_f, js} -> -length(js) end)
    |> Enum.each(fn {f, js} ->
      wins = Enum.sum(Enum.map(js, & &1["stats"]["wins"]))
      games = Enum.sum(Enum.map(js, & &1["stats"]["games"]))
      best = Enum.max_by(js, & &1["fitness"])

      line(
        "#{String.pad_trailing(f, 10)} #{String.pad_leading(to_string(length(js)), 4)} evals · " <>
          "winrate #{String.pad_leading(pct(wins, games), 4)} · best fit #{round(best["fitness"])} · " <>
          "mean fit #{round(mean(Enum.map(js, & &1["fitness"])))}"
      )
    end)

    section("Losses conceded by faction (as champion-opponent)")

    evals
    |> Enum.group_by(& &1["opponent"])
    |> Enum.sort_by(fn {_f, js} -> -length(js) end)
    |> Enum.each(fn {f, js} ->
      lost = Enum.sum(Enum.map(js, & &1["stats"]["wins"]))
      games = Enum.sum(Enum.map(js, & &1["stats"]["games"]))
      line("#{String.pad_trailing(f, 10)} defended #{games} games · evolver won #{pct(lost, games)}")
    end)
  end

  defp books(evals) do
    with_book = Enum.filter(evals, &Map.has_key?(&1["stats"], "opener_rate"))
    if with_book != [] do
      section("Opening books")

      with_book
      |> Enum.group_by(fn j ->
        Enum.at(~w(governor_open scout_open colonial_open), trunc(abs(j["genome"]["opener_variant"] || 0.0)) |> rem(3))
      end)
      |> Enum.each(fn {book, js} ->
        wins = Enum.sum(Enum.map(js, & &1["stats"]["wins"]))
        games = Enum.sum(Enum.map(js, & &1["stats"]["games"]))
        rate = mean(Enum.map(js, & &1["stats"]["opener_rate"]))

        line(
          "#{String.pad_trailing(book, 14)} #{String.pad_leading(to_string(length(js)), 4)} evals · " <>
            "winrate #{pct(wins, games)} · completion #{r2(rate)} · colonies/eval #{r2(mean(Enum.map(js, & &1["stats"]["colonies"])))}"
        )
      end)
    end
  end

  defp usage(evals) do
    instrumented = Enum.filter(evals, &is_map(&1["stats"]["usage"]))

    if instrumented == [] do
      section("Usage leaderboards")
      line("no instrumented evals yet — usage recorded from 2026-07-06 onward")
    else
      n = length(instrumented)
      winners = Enum.filter(instrumented, &(&1["stats"]["wins"] > &1["stats"]["games"] / 2))

      for group <- ~w(patent doctrine build ship mission) do
        section("Usage: #{group}s (#{n} instrumented evals; win% = share used by winning evals)")

        totals =
          Enum.reduce(instrumented, %{}, fn j, acc ->
            Enum.reduce(Map.get(j["stats"]["usage"], group, %{}), acc, fn {k, c}, acc ->
              Map.update(acc, k, {c, 0}, fn {t, w} -> {t + c, w} end)
            end)
          end)

        totals =
          Enum.reduce(winners, totals, fn j, acc ->
            Enum.reduce(Map.get(j["stats"]["usage"], group, %{}), acc, fn {k, c}, acc ->
              Map.update(acc, k, {0, c}, fn {t, w} -> {t, w + c} end)
            end)
          end)

        totals
        |> Enum.sort_by(fn {_k, {t, _}} -> -t end)
        |> Enum.take(12)
        |> Enum.each(fn {k, {total, by_winners}} ->
          line("#{String.pad_trailing(k, 28)} #{String.pad_leading(to_string(total), 6)}  (#{pct(by_winners, total)} by winners)")
        end)
      end
    end
  end

  defp archives(dir) do
    section("Archives")

    for faction <- ~w(tetrarchy myrmezir ark cardan synelle) do
      case File.read(Path.join(dir, "archive_#{faction}.json")) do
        {:ok, json} ->
          archive = Jason.decode!(json)
          real = Enum.reject(archive, fn {k, _} -> String.starts_with?(k, "seed_") end)
          {top_key, top} = Enum.max_by(real, fn {_k, v} -> v["fitness"] end, fn -> {"-", %{"fitness" => 0}} end)

          line(
            "#{String.pad_trailing(faction, 10)} #{map_size(archive)} niches " <>
              "(#{length(real)} earned) · top #{top_key} @ #{round(top["fitness"])}"
          )

        _ ->
          :ok
      end
    end
  end

  defp section(title), do: Mix.shell().info("\n== #{title} ==")
  defp line(text), do: Mix.shell().info("  " <> text)
  defp mean([]), do: 0.0
  defp mean(xs), do: Enum.sum(xs) / length(xs)
  defp pct(_n, 0), do: "0%"
  defp pct(n, d), do: "#{round(100 * n / d)}%"
  defp r1(x), do: Float.round(x / 1, 1)
  defp r2(x), do: Float.round(x / 1, 2)
end

defmodule Mix.Tasks.Headless.Dashboard do
  @shortdoc "Render a live bot-performance dashboard (HTML) from a marathon run"

  @moduledoc """
  Generates a self-contained HTML dashboard of the latest marathon segment
  and writes it to `priv/storage/` — which the app serves at `/uploads/`,
  so it is reachable at `http://localhost:<RC_HTTP_PORT>/uploads/bot_dashboard.html`.

      mix headless.dashboard                       # one-shot render
      mix headless.dashboard --watch 120           # re-render every 120s
      mix headless.dashboard --out tmp/marathon_night --file bot_dashboard.html

  Charts are inline SVG (no JS, no external deps) so the page loads anywhere
  and a browser refresh always shows the latest regeneration. Sections:
  overview, fitness histogram, wins-by-faction, win quality (developer vs
  do-nothing), colonies/VP distributions, mission usage, format + opening
  books, per-faction champions, and a time trend.
  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args, strict: [out: :string, file: :string, watch: :integer])

    dir = Keyword.get(opts, :out, "tmp/marathon_night")
    file = Keyword.get(opts, :file, "bot_dashboard.html")
    dest = Path.join([:code.priv_dir(:rc), "storage", file])

    case Keyword.get(opts, :watch) do
      nil ->
        generate(dir, dest)
        Mix.shell().info("wrote #{dest}")

      secs ->
        Mix.shell().info("watching #{dir} — re-rendering every #{secs}s → #{dest}")
        watch(dir, dest, secs)
    end
  end

  defp watch(dir, dest, secs) do
    try do
      generate(dir, dest)
    rescue
      e -> IO.puts("dashboard render failed (retrying): #{Exception.message(e)}")
    end

    Process.sleep(secs * 1000)
    watch(dir, dest, secs)
  end

  defp generate(dir, dest) do
    Process.put(:i18n, load_i18n())
    evals = load(Path.join(dir, "results.jsonl"))
    census = census(Path.join(dir, "marathon.log"))
    champs = champions(dir)
    File.mkdir_p!(Path.dirname(dest))
    # Write atomically: a browser refresh must never fetch a half-written
    # file (which would drop the lower sections — champions, genome explorer).
    tmp = dest <> ".tmp"
    File.write!(tmp, render(evals, census, champs))
    File.rename!(tmp, dest)
  end

  # The game's EN display strings (data.<category>.<key>.name) — so the
  # dashboard shows "Refining Ducts" / "Proto-Empire", not the internal
  # keys. Loaded once per render into the process dictionary.
  @i18n_path "front/src/locales/en/data.json"
  defp load_i18n do
    case File.read(@i18n_path) do
      {:ok, body} -> (Jason.decode!(body)["data"] || %{})
      _ -> %{}
    end
  rescue
    _ -> %{}
  end

  # Display name for an internal key in a content category, or nil.
  defp tname(cat, key) do
    case get_in(Process.get(:i18n, %{}), [cat, to_string(key), "name"]) do
      nil -> nil
      "" -> nil
      # Some entries are "singular | plural"; take the singular.
      name -> name |> String.split("|") |> hd() |> String.trim()
    end
  end

  # Bot telemetry mission keys → i18n character_action_status keys, then a
  # titleized fallback for actions with no game string (e.g. assassination,
  # the bot-only reposition/explore).
  @action_alias %{"infiltrate" => "infiltration"}
  defp mission_name(key) do
    k = Map.get(@action_alias, key, key)
    tname("character_action_status", k) || titleize(key)
  end

  defp faction_name(key), do: tname("faction", key) || titleize(key)

  # Faction brand colors (Data.Game.Faction.Content `color:`), so factions
  # read at a glance rather than as a wall of blue bars.
  @faction_colors %{
    "tetrarchy" => "#3f66df",
    "myrmezir" => "#bc2433",
    "cardan" => "#8e60bf",
    "synelle" => "#a2cd44",
    "ark" => "#c9a115"
  }
  defp faction_color(key), do: Map.get(@faction_colors, to_string(key), "#3f66df")

  defp titleize(nil), do: "?"
  defp titleize(s), do: s |> to_string() |> String.replace("_", " ") |> String.capitalize()

  # --- data loading -----------------------------------------------------------

  # Rolling window of evals shown on the dashboard. Large enough to carry the
  # full accumulated history across a schema change (a marathon restart only
  # rotates the FILE if we choose to; results.jsonl is appended, so history
  # persists). Bounds render cost if the log ever grows unbounded.
  @window 20000

  # Current-quality charts (funnel, wins, colonies, distributions) show the
  # most-recent @recent evals so days-old training doesn't dilute the read.
  # The overview banner counts the FULL retained history, and the fitness
  # trend draws the whole arc — so nothing is hidden, just scoped.
  @recent 2000

  defp load(path) do
    evals =
      case File.read(path) do
        {:ok, body} ->
          body
          |> String.split("\n", trim: true)
          |> Enum.flat_map(fn line ->
            case Jason.decode(line) do
              {:ok, j} -> [j]
              _ -> []
            end
          end)

        _ ->
          []
      end

    # ROLLING WINDOW, not the current marathon segment: a marathon restart
    # resets the iter counter, and a segment-based view would blank the page
    # until the new run warmed up (the "refresh cleared everything" bug). The
    # last N evals always carry recent data, spanning a restart seamlessly.
    Enum.take(evals, -@window)
  end

  defp census(path) do
    case File.read(path) do
      {:ok, log} ->
        seg = String.slice(log, max(0, byte_size(log) - 2_000_000), 2_000_000)

        for pat <- ["CRASHED", "aborting unprocessable"] do
          {pat, seg |> String.split(pat) |> length() |> Kernel.-(1)}
        end

      _ ->
        []
    end
  end

  defp champions(dir) do
    for faction <- ~w(tetrarchy myrmezir ark cardan synelle) do
      entries =
        case File.read(Path.join(dir, "archive_#{faction}.json")) do
          {:ok, json} ->
            json
            |> Jason.decode!()
            |> Enum.reject(fn {k, _} -> String.starts_with?(k, "seed_") end)
            |> Enum.map(fn {_k, v} -> v end)
            |> Enum.sort_by(&(-&1["fitness"]))
            |> Enum.take(3)

          _ ->
            []
        end

      {faction, entries}
    end
  end

  # --- stats ------------------------------------------------------------------

  defp stat(e, key), do: get_in(e, ["stats", key])

  defp mean([]), do: 0.0
  defp mean(xs), do: Enum.sum(xs) / length(xs)
  defp r1(x), do: :erlang.float_to_binary(x / 1, decimals: 1)
  defp pct(_n, 0), do: 0
  defp pct(n, d), do: round(100 * n / d)

  # --- render -----------------------------------------------------------------

  defp render([], _census, _champs) do
    page("Bot Performance", "<p class=empty>No marathon results found yet.</p>")
  end

  # Selectable time windows. Data now spans days, so an all-time view buries
  # recent changes (user 2026-07-11). Each window re-scopes the analysis
  # sections to evals within `secs` of the latest eval; nil = all-time. The
  # trend / champions / genome below stay full-history (window-independent).
  @windows [{"30m", 1_800}, {"2h", 7_200}, {"12h", 43_200}, {"All", nil}]
  @default_window "2h"

  defp render(full, census, champs) do
    now = List.last(full)["at"] || 0

    retained =
      {length(full), full |> Enum.map(&(stat(&1, "games") || 0)) |> Enum.sum(),
       (List.last(full)["at"] - hd(full)["at"]) / 3600}

    winviews =
      for {label, secs} <- @windows, into: "" do
        evals = if secs, do: Enum.filter(full, &((&1["at"] || 0) >= now - secs)), else: full
        hidden = if label == @default_window, do: "", else: " hidden"
        ~s|<div class="winview#{hidden}" data-w="#{label}">#{analysis_sections(evals, census, retained)}</div>|
      end

    body =
      window_bar() <>
        winviews <>
        section("Fitness trend (full history, 15-min windows)", trend(full)) <>
        section("Champions by faction", champ_table(champs)) <>
        section("Genome explorer", genome_explorer(Enum.take(full, -@recent), champs)) <>
        window_script()

    page("Bot Performance", body)
  end

  defp window_bar do
    btns =
      for {label, _} <- @windows, into: "" do
        cls = if label == @default_window, do: "wbtn active", else: "wbtn"
        ~s|<button class="#{cls}" data-w="#{label}" onclick="pickWindow('#{label}')">#{label}</button>|
      end

    ~s(<div class=winbar><span class=winlab>Window</span>#{btns}<span class=winhint>analysis below is scoped to this; trend &amp; champions stay all-time</span></div>)
  end

  defp window_script do
    ~s|<script>function pickWindow(w){document.querySelectorAll('.winview').forEach(function(e){e.classList.toggle('hidden',e.dataset.w!==w)});document.querySelectorAll('.wbtn').forEach(function(b){b.classList.toggle('active',b.dataset.w===w)})}</script>|
  end

  # The analysis sections for ONE time window (empty-safe).
  defp analysis_sections([], _census, _retained),
    do: ~s(<section><p class=empty>No evals in this window yet.</p></section>)

  defp analysis_sections(evals, census, retained) do
    n = length(evals)
    games = evals |> Enum.map(&(stat(&1, "games") || 0)) |> Enum.sum()
    hours = (List.last(evals)["at"] - hd(evals)["at"]) / 3600
    iters = List.last(evals)["iter"]
    wins_total = evals |> Enum.map(&(stat(&1, "wins") || 0)) |> Enum.sum()

    fits = Enum.map(evals, & &1["fitness"])
    vps = Enum.map(evals, &(stat(&1, "mean_vp") || 0))
    cols = Enum.map(evals, &(stat(&1, "colonies") || 0))

    overview(n, games, hours, iters, wins_total, fits, vps, cols, census, retained) <>
      section("Golden line vs a human's development pace", golden_line(evals)) <>
      section("First-colony blocker funnel", funnel_section(evals)) <>
      section("Fitness distribution", histogram(fits, 18)) <>
      two_col(
        section("Wins by faction (evolver vs benchmark)", wins_by_faction(evals)),
        section("Win quality", win_quality(evals))
      ) <>
      section("Colonies of the winning player", colonies_section(evals)) <>
      two_col(
        section("Win rate by format", formats(evals)),
        section("Mission usage (winner-share)", missions(evals))
      ) <>
      section("Opening books", books(evals))
  end

  # The GOLDEN LINE — a human's development pace (instance 7, User1, a
  # deliberately casual game = a lower bound). 25% & 50% are the actual
  # snapshots from the focused first half; 75% is a linear extrapolation of
  # the 25%→50% slope (the player coasted late, so the real numbers under-
  # sell). Agents are a soft target from the player's recollection
  # (~5 Siderians / 3 Navarchs / 3 Erased, could have fielded more).
  @golden %{
    25 => %{"sys" => 2, "pop" => 100, "income" => 1028, "tech" => 201},
    50 => %{"sys" => 4, "pop" => 245, "income" => 2246, "tech" => 404},
    75 => %{"sys" => 6, "pop" => 390, "income" => 3464, "tech" => 607}
  }
  @golden_metrics [{"sys", "Systems"}, {"pop", "Population"}, {"income", "Credit income"}, {"tech", "Tech income"}]

  # For each 25/50/75% checkpoint, the share of evals whose mean economy
  # meets or beats the human's pace on each metric, plus a composite "gold
  # seal" (clears every metric). This is the barometer: if bots can't match
  # a casual human's development at these time points, they aren't there yet.
  defp golden_line(evals) do
    with_cp =
      evals
      |> Enum.map(&stat(&1, "checkpoints"))
      |> Enum.filter(&is_map/1)

    if with_cp == [] do
      ~s|<p class=empty>No checkpoint data yet — the marathon needs a restart on the instrumented build for these to populate.</p>|
    else
      blocks =
        for cp <- [25, 50, 75] do
          golden = @golden[cp]

          snaps =
            evals
            |> Enum.map(fn e -> get_in(e, ["stats", "checkpoints", to_string(cp)]) end)
            |> Enum.filter(&is_map/1)

          n = max(length(snaps), 1)

          rows =
            for {m, label} <- @golden_metrics do
              gv = golden[m]
              passed = Enum.count(snaps, &((&1[m] || 0) >= gv))
              med = snaps |> Enum.map(&(&1[m] || 0)) |> median()
              {label, pct(passed, n), "gold #{fmt_int(gv)} · median #{fmt_int(round(med))}", passrate_color(pct(passed, n))}
            end

          seal =
            Enum.count(snaps, fn s ->
              Enum.all?(@golden_metrics, fn {m, _} -> (s[m] || 0) >= golden[m] end)
            end)

          subsection(
            "#{cp}% elapsed",
            "#{length(snaps)} evals reached this mark · gold seal (clears all): <b>#{pct(seal, n)}%</b>",
            hbars(rows, 100, "%")
          )
        end

      note =
        ~s|<p class=note>The line is a human's <b>casual</b> game (instance 7) — a floor, not a ceiling. Bars show the share of bots meeting or beating that pace at each checkpoint. "Gold seal" = clears every metric at once. Agent target (soft): ~5 Siderians / 3 Navarchs / 3 Erased by late game.</p>|

      note <> ~s|<div class=grid3>#{Enum.join(blocks)}</div>|
    end
  end

  defp median([]), do: 0
  defp median(xs) do
    s = Enum.sort(xs)
    n = length(s)
    Enum.at(s, div(n, 2))
  end

  defp passrate_color(p) when p >= 60, do: "#2ea043"
  defp passrate_color(p) when p >= 30, do: "#b8860b"
  defp passrate_color(_), do: "#bc2433"

  # Funnel stage semantics changed on 2026-07-10 (added the system-expansion
  # lex rung; old data used a 6-stage schema where "stage 2" meant "no
  # Navarch"). The funnel counts ONLY evals from the new schema — everything
  # ELSE on the page still shows the full restored history. Detected by the
  # eval's `at` epoch: new-build evals start ≥ this boundary (there was a
  # ~450s gap at the restart). Bump this if the funnel schema changes again.
  @funnel_since 1_783_721_600

  # Of every ZERO-colony game, the FIRST unmet link on the road to a first
  # colony (Headless.Bot.colony_stage — a strict prerequisite funnel). Tells
  # us exactly where colonization dies — hard blockers (patents, the system
  # lex, having a Navarch) in red, soft ones amber. Stage 2 (never bought the
  # cap lex) vs stage 5 (has the slot but never ordered the ship) is the
  # split that says whether the miss is a purchase or a build order.
  @funnel_labels %{
    "0" => {"No root patent (Citadel)", :hard},
    "1" => {"Has Citadel, no colony-ship patent", :hard},
    "2" => {"Has colony-ship patent, no system-expansion lex", :hard},
    "3" => {"Cap raised, but never recruited a Navarch", :hard},
    "4" => {"Has a Navarch, never deployed it home", :soft},
    "5" => {"Navarch home, never built a colony ship", :soft},
    "6" => {"Built a colony ship, never dispatched it", :soft},
    "7" => {"Dispatched, but never colonized", :soft}
  }
  defp funnel_section(evals) do
    totals =
      evals
      |> Enum.filter(&((&1["at"] || 0) >= @funnel_since))
      |> Enum.map(&stat(&1, "funnel"))
      |> Enum.filter(&is_map/1)
      |> Enum.reduce(%{}, fn f, acc ->
        Enum.reduce(f, acc, fn {k, v}, a -> Map.update(a, k, v, &(&1 + v)) end)
      end)

    if totals == %{} do
      ~s|<p class=empty>No funnel data yet on the current schema — the marathon needs to run on the 8-stage build.</p>|
    else
      total = totals |> Map.values() |> Enum.sum() |> max(1)
      maxc = totals |> Map.values() |> Enum.max(fn -> 1 end)

      rows =
        for s <- ~w(0 1 2 3 4 5 6 7) do
          c = Map.get(totals, s, 0)
          {lab, kind} = @funnel_labels[s]
          color = if kind == :hard, do: "#bc2433", else: "#b8860b"
          {lab, c, "#{c} games · #{pct(c, total)}%", color}
        end

      note =
        ~s|<p class=note>Of every zero-colony game, the first unmet link on the road to a first colony. <span style="color:#bc2433">Red</span> = a HARD blocker (root patent → colony-ship patent → system-expansion lex → having a Navarch); <span style="color:#b8860b">amber</span> = a SOFT blocker once those are met. The "no system-expansion lex" vs "never built a colony ship" rungs split the old catch-all: whether the miss is the cap purchase or the ship build order.</p>|

      note <> funnel_bars(rows, maxc)
    end
  end

  # Dedicated funnel renderer: the blocker labels are long sentences, so the
  # generic hbars (fixed 120px right-aligned label, ellipsis-clipped) mangles
  # them. Here the full label sits ABOVE its bar, the count+% is on the SAME
  # line as the bar (unambiguous which bar it belongs to), and a divider
  # separates each stage into a clear block.
  defp funnel_bars(rows, max) do
    rows
    |> Enum.map(fn {label, val, sub, color} ->
      w = pct(val, max)

      ~s(<div class=frow>) <>
        ~s(<div class=flab><span class=fdot style="background:#{color};color:#{color}"></span>#{label}</div>) <>
        ~s(<div class=fbar><div class=ftrk><div class=ffill style="width:#{w}%;background:#{color}"></div></div>) <>
        ~s(<div class=fsub>#{sub}</div></div></div>)
    end)
    |> Enum.join()
    |> then(&~s(<div class=funnel>#{&1}</div>))
  end

  # Colonies distribution restricted to the WINNING side (the all-games
  # version is skewed by losers who never expand), split into the whole
  # winner pool and just the champion-quality tail (top-fitness winners —
  # the ones close to what we'd export).
  defp colonies_section(evals) do
    wins =
      Enum.filter(evals, fn e ->
        (stat(e, "wins") || 0) > 0 and stat(e, "mean_win_colonies") != nil
      end)

    all = Enum.map(wins, &stat(&1, "mean_win_colonies"))
    # Champion-quality = the top fitness fifth OF WINNERS. Earlier this keyed
    # off the P80 of ALL evals (wins + losses); with the ln(50x) colony bonus,
    # colonizing LOSSES can outscore covert WINS, pushing that threshold above
    # every winner and blanking the plot. Winners' own P80 is always populated
    # when any winner exists.
    thr = percentile(Enum.map(wins, & &1["fitness"]), 0.80)
    champ = Enum.filter(wins, &(&1["fitness"] >= thr))

    # Scatter: for each (faction, whole-colony-count) how many champion-grade
    # wins landed there — faction-colored dots. (mean_win_colonies is a
    # per-eval average, rounded to the nearest whole system for the axis.)
    points =
      champ
      |> Enum.group_by(fn e -> {e["faction"], round(stat(e, "mean_win_colonies"))} end)
      |> Enum.map(fn {{f, col}, es} -> {col, length(es), faction_color(f)} end)

    two_col(
      subsection(
        "All winners",
        "#{length(all)} winning evals · avg #{r1(mean(all))} colonies",
        int_hist(all)
      ),
      subsection(
        "Champion-quality winners",
        "fitness ≥ #{round(thr)} · #{length(champ)} evals · avg #{r1(mean(Enum.map(champ, &stat(&1, "mean_win_colonies"))))}",
        scatter(points, "colonies", "wins")
      )
    )
  end

  # Frequency bars over whole-number colony counts (0,1,2,…) — clearer than a
  # continuous histogram whose bin edges round to duplicate integer labels.
  defp int_hist([]), do: "<p class=empty>no data</p>"

  defp int_hist(values) do
    counts = values |> Enum.map(&round/1) |> Enum.frequencies()
    maxk = counts |> Map.keys() |> Enum.max(fn -> 0 end)
    maxc = counts |> Map.values() |> Enum.max(fn -> 1 end)

    cols =
      for k <- 0..maxk do
        c = Map.get(counts, k, 0)
        ~s(<div class=hcol title="#{k} colonies: #{c} wins"><div class=hbar style="height:#{max(round(100 * c / maxc), 1)}%"></div><div class=tlab>#{k}</div></div>)
      end
      |> Enum.join()

    ~s(<div class="histo trend">#{cols}</div>)
  end

  defp percentile([], _p), do: 0.0

  defp percentile(xs, p) do
    sorted = Enum.sort(xs)
    idx = min(round(p * (length(sorted) - 1)), length(sorted) - 1)
    Enum.at(sorted, idx)
  end

  defp overview(n, games, hours, iters, wins, fits, vps, cols, census, {tot_e, tot_g, tot_h}) do
    zc = Enum.count(cols, &(&1 == 0))

    tiles = [
      tile("evals", n),
      tile("games", games),
      tile("hours", r1(hours)),
      tile("iters", "0–#{iters}"),
      tile("winrate", "#{pct(wins, games)}%"),
      tile("mean fit", round(mean(fits))),
      tile("mean VP", r1(mean(vps))),
      tile("colonies/eval", r1(mean(cols))),
      tile("zero-colony", "#{pct(zc, n)}%")
    ]

    census_tiles =
      for {pat, cnt} <- census do
        cls = if pat == "CRASHED" and cnt > 0, do: " bad", else: ""
        ~s(<div class="tile#{cls}"><div class=v>#{cnt}</div><div class=k>#{pat}</div></div>)
      end

    note =
      if tot_e > n do
        ~s(<p class=note>Tiles and analysis charts below cover the most recent <b>#{n}</b> evals. Full retained history on disk: <b>#{fmt_int(tot_e)}</b> evals · <b>#{fmt_int(tot_g)}</b> games · <b>#{r1(tot_h)}</b>h — the fitness trend draws the whole arc.</p>)
      else
        ""
      end

    ~s(<div class=tiles>#{tiles}#{census_tiles}</div>#{note})
  end

  defp tile(k, v), do: ~s(<div class=tile><div class=v>#{v}</div><div class=k>#{k}</div></div>)

  defp wins_by_faction(evals) do
    rows =
      evals
      |> Enum.group_by(& &1["faction"])
      |> Enum.map(fn {f, js} ->
        w = js |> Enum.map(&(stat(&1, "wins") || 0)) |> Enum.sum()
        g = js |> Enum.map(&(stat(&1, "games") || 0)) |> Enum.sum()
        best = js |> Enum.map(& &1["fitness"]) |> Enum.max(fn -> 0 end)
        {faction_name(f), pct(w, g), "best #{round(best)} · #{length(js)} evals", faction_color(f)}
      end)
      |> Enum.sort_by(fn {_, wr, _, _} -> -wr end)

    hbars(rows, 100, "%")
  end

  defp win_quality(evals) do
    wins =
      Enum.filter(evals, fn e ->
        (stat(e, "wins") || 0) > 0 and stat(e, "mean_win_colonies") != nil and
          stat(e, "mean_win_vp") != nil
      end)

    tot = max(length(wins), 1)
    zc = Enum.count(wins, &(stat(&1, "mean_win_colonies") == 0))
    dev = Enum.count(wins, &(stat(&1, "mean_win_colonies") >= 2))
    milestone = Enum.count(wins, &(stat(&1, "mean_win_vp") >= 8))
    avg = wins |> Enum.map(&stat(&1, "mean_win_colonies")) |> mean()

    rows = [
      {"developer wins (≥2 colonies)", pct(dev, tot), "#{dev}/#{tot}"},
      {"do-nothing wins (0 colonies)", pct(zc, tot), "#{zc}/#{tot}"},
      {"milestone wins (≥8 VP)", pct(milestone, tot), "#{milestone}/#{tot}"}
    ]

    ~s(<p class=lead>avg colonies of the winning player: <b>#{r1(avg)}</b></p>) <> hbars(rows, 100, "%")
  end

  defp formats(evals) do
    label = fn e ->
      nf = e["n_factions"] || 2
      ppf = e["players_per_faction"] || 1
      "#{ppf}v#{ppf}" <> if(nf == 3, do: "v#{ppf}", else: "")
    end

    order = ~w(1v1 2v2 3v3 4v4 3v3v3 2v2v2)

    rows =
      evals
      |> Enum.group_by(label)
      |> Enum.map(fn {k, js} ->
        w = js |> Enum.map(&(stat(&1, "wins") || 0)) |> Enum.sum()
        g = js |> Enum.map(&(stat(&1, "games") || 0)) |> Enum.sum()
        {k, pct(w, g), "#{length(js)} evals"}
      end)
      |> Enum.sort_by(fn {k, _, _} -> Enum.find_index(order, &(&1 == k)) || 99 end)

    note =
      ~s|<p class=note>Share of games the <b>evaluated genome</b> won against its benchmark opponents (boomer + sampled champions) &mdash; a genome-strength signal, not self-play. ~50% is the neutral line for 2-team formats, ~33% for 3-team. Timeouts are included (most games are decided on the VP tiebreak); "won decisively" is the milestone-wins figure in Win quality.</p>|

    note <> hbars(rows, 100, "%")
  end

  defp missions(evals) do
    instrumented = Enum.filter(evals, &is_map(stat(&1, "usage")))
    winners = Enum.filter(instrumented, &((stat(&1, "wins") || 0) > (stat(&1, "games") || 0) / 2))

    totals =
      Enum.reduce(instrumented, %{}, fn e, acc ->
        Enum.reduce(Map.get(stat(e, "usage"), "mission", %{}), acc, fn {k, c}, acc ->
          Map.update(acc, k, {c, 0}, fn {t, w} -> {t + c, w} end)
        end)
      end)

    totals =
      Enum.reduce(winners, totals, fn e, acc ->
        Enum.reduce(Map.get(stat(e, "usage"), "mission", %{}), acc, fn {k, c}, acc ->
          Map.update(acc, k, {0, c}, fn {t, w} -> {t, w + c} end)
        end)
      end)

    max_total = totals |> Enum.map(fn {_, {t, _}} -> t end) |> Enum.max(fn -> 1 end)

    rows =
      totals
      |> Enum.sort_by(fn {_, {t, _}} -> -t end)
      |> Enum.take(10)
      |> Enum.map(fn {k, {t, w}} -> {mission_name(k), t, "#{fmt_int(t)} · #{pct(w, t)}% by winners"} end)

    hbars_raw(rows, max_total)
  end

  defp books(evals) do
    with_book = Enum.filter(evals, &(stat(&1, "opener_rate") != nil))

    if with_book == [] do
      "<p class=empty>no opener telemetry</p>"
    else
      rows =
        with_book
        |> Enum.group_by(fn e ->
          Enum.at(
            ~w(governor scout colonial exobiology),
            (trunc(abs(e["genome"]["opener_variant"] || 0.0)) |> rem(4))
          )
        end)
        |> Enum.map(fn {book, js} ->
          w = js |> Enum.map(&(stat(&1, "wins") || 0)) |> Enum.sum()
          g = js |> Enum.map(&(stat(&1, "games") || 0)) |> Enum.sum()
          colv = js |> Enum.map(&(stat(&1, "colonies") || 0)) |> mean()
          {book, pct(w, g), "#{length(js)} evals · #{r1(colv)} col/ev"}
        end)
        |> Enum.sort_by(fn {_, wr, _} -> -wr end)

      hbars(rows, 100, "%")
    end
  end

  # Trend x-axis labels: raw minutes for short spans, hours/days for long
  # ones (a 167h history in minutes is unreadable).
  defp fmt_minutes(m) when m < 120, do: "#{round(m)}m"
  defp fmt_minutes(m) when m < 2880, do: "#{Float.round(m / 60, 1)}h"
  defp fmt_minutes(m), do: "#{Float.round(m / 1440, 1)}d"

  # Mean fitness over 15-minute windows as a line chart (a trend wants a
  # line, not bars). x = minutes into the window, y = mean fitness.
  defp trend(evals) do
    t0 = hd(evals)["at"]
    w = 15 * 60

    points =
      evals
      |> Enum.group_by(&trunc((&1["at"] - t0) / w))
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {b, js} -> {b * 15, mean(Enum.map(js, & &1["fitness"]))} end)

    linechart(points, "mean fitness")
  end

  # SVG line chart from [{x_minutes, value}]. Labeled y-axis (min/max +
  # title), sparse x-axis (start/mid/end minutes).
  defp linechart(points, ylabel) when length(points) < 2,
    do: "<p class=empty>not enough data for a trend yet (need &gt;15 min)</p>"

  defp linechart(points, ylabel) do
    n = length(points)
    vals = Enum.map(points, &elem(&1, 1))
    {lo, hi} = Enum.min_max(vals)
    hi = if hi == lo, do: lo + 1.0, else: hi
    w = 640
    h = 190
    pl = 46
    pr = 12
    pt = 12
    pb = 26
    pw = w - pl - pr
    ph = h - pt - pb
    xat = fn i -> pl + i / (n - 1) * pw end
    yat = fn v -> pt + (1.0 - (v - lo) / (hi - lo)) * ph end

    poly =
      points
      |> Enum.with_index()
      |> Enum.map(fn {{_x, v}, i} -> "#{Float.round(xat.(i), 1)},#{Float.round(yat.(v), 1)}" end)
      |> Enum.join(" ")

    # Per-point dots only when the series is short enough to read them; a long
    # multi-day trend is just the polyline (hundreds of dots is noise).
    dots =
      if n <= 60 do
        points
        |> Enum.with_index()
        |> Enum.map(fn {{_x, v}, i} ->
          ~s|<circle cx="#{Float.round(xat.(i), 1)}" cy="#{Float.round(yat.(v), 1)}" r="2.4" fill="var(--bar)"><title>#{round(v)}</title></circle>|
        end)
        |> Enum.join()
      else
        ""
      end

    xlabels =
      [0, div(n - 1, 2), n - 1]
      |> Enum.uniq()
      |> Enum.map(fn i ->
        {x, _} = Enum.at(points, i)
        ~s|<text x="#{Float.round(xat.(i), 1)}" y="#{h - 8}" text-anchor="middle" class=svgtxt>#{fmt_minutes(x)}</text>|
      end)
      |> Enum.join()

    ~s|<svg viewBox="0 0 #{w} #{h}" width="#{w}" height="#{h}" class=lc>| <>
      ~s|<line x1="#{pl}" y1="#{pt}" x2="#{pl}" y2="#{pt + ph}" class="axl"/>| <>
      ~s|<line x1="#{pl}" y1="#{pt + ph}" x2="#{pl + pw}" y2="#{pt + ph}" class="axl"/>| <>
      ~s|<text x="#{pl - 6}" y="#{pt + 8}" text-anchor="end" class=svgtxt>#{round(hi)}</text>| <>
      ~s|<text x="#{pl - 6}" y="#{pt + ph}" text-anchor="end" class=svgtxt>#{round(lo)}</text>| <>
      ~s|<text x="14" y="#{pt + ph / 2}" text-anchor="middle" class=svgtxt transform="rotate(-90 14 #{pt + ph / 2})">#{ylabel}</text>| <>
      ~s|<polyline points="#{poly}" fill="none" stroke="var(--bar)" stroke-width="2"/>| <>
      dots <> xlabels <> "</svg>"
  end

  defp champ_table(champs) do
    rows =
      for {faction, entries} <- champs, entry <- entries do
        s = entry["stats"] || %{}
        u = (s["usage"] || %{})["mission"] || %{}
        classes = agent_classes(u)

        ~s(<tr><td class=fac><span class=fdot style="background:#{faction_color(faction)};color:#{faction_color(faction)}"></span>#{faction_name(faction)}</td><td class=num>#{round(entry["fitness"])}</td>) <>
          ~s(<td class=num>#{s["wins"] || 0}/#{s["games"] || 0}</td>) <>
          ~s(<td class=num>#{fmt(s["mean_win_vp"] || s["mean_vp"])}</td>) <>
          ~s(<td class=num>#{fmt(s["mean_win_colonies"] || s["colonies"])}</td>) <>
          ~s(<td>#{classes}</td></tr>)
      end

    ~s(<table><thead><tr><th>faction</th><th class=num>fitness</th><th class=num>W/G</th><th class=num>win-VP</th><th class=num>win-col</th><th>agent classes</th></tr></thead><tbody>#{rows}</tbody></table>)
  end

  defp agent_classes(missions) do
    keys = Map.keys(missions)

    [
      {~w(colonization raid conquest), "Navarch"},
      {~w(infiltrate assassination), "Erased"},
      {~w(encourage_hate make_dominion conversion), "Siderian"}
    ]
    |> Enum.filter(fn {ks, _} -> Enum.any?(ks, &(&1 in keys)) end)
    |> Enum.map(fn {_, name} -> ~s(<span class=chip>#{name}</span>) end)
    |> Enum.join(" ")
  end

  defp fmt(nil), do: "–"
  defp fmt(x) when is_float(x), do: r1(x)
  defp fmt(x), do: to_string(x)

  defp fmt_int(n) when n >= 1000, do: "#{Float.round(n / 1000, 1)}k"
  defp fmt_int(n), do: to_string(n)

  # --- SVG chart helpers ------------------------------------------------------

  # Labeled horizontal bars scaled to a 0..max axis, value shown as "N<unit>".
  # A row may carry an optional color (4-tuple) — the bar fills in that color
  # and a matching dot precedes the label (used for faction brand colors).
  defp hbars(rows, max, unit) do
    rows
    |> Enum.map(fn row ->
      {label, val, sub, color} =
        case row do
          {l, v, s} -> {l, v, s, nil}
          {l, v, s, c} -> {l, v, s, c}
        end

      w = pct(val, max)
      fill = if color, do: ~s(width:#{w}%;background:#{color}), else: ~s(width:#{w}%)
      dot = if color, do: ~s(<span class=fdot style="background:#{color};color:#{color}"></span>), else: ""

      ~s(<div class=row><div class=lab>#{dot}#{label}</div>) <>
        ~s(<div class=bar><div class=fill style="#{fill}"></div></div>) <>
        ~s(<div class=val>#{val}#{unit}</div><div class=sub>#{sub}</div></div>)
    end)
    |> Enum.join()
    |> then(&~s(<div class=hbars>#{&1}</div>))
  end

  # Bars scaled to an absolute max (for raw counts, e.g. mission volume).
  defp hbars_raw(rows, max) do
    rows
    |> Enum.map(fn {label, val, sub} ->
      w = pct(val, max)

      ~s(<div class=row><div class=lab>#{label}</div>) <>
        ~s(<div class=bar><div class=fill style="width:#{w}%"></div></div>) <>
        ~s(<div class=sub wide>#{sub}</div></div>)
    end)
    |> Enum.join()
    |> then(&~s(<div class=hbars>#{&1}</div>))
  end

  # Vertical-bar histogram of continuous (or :int) values.
  defp histogram(values, bins, mode \\ :float)
  defp histogram([], _bins, _mode), do: "<p class=empty>no data</p>"

  defp histogram(values, bins, mode) do
    {lo, hi} = Enum.min_max(values)
    hi = if hi == lo, do: lo + 1, else: hi
    step = (hi - lo) / bins

    counts =
      Enum.reduce(values, %{}, fn v, acc ->
        b = min(trunc((v - lo) / step), bins - 1)
        Map.update(acc, b, 1, &(&1 + 1))
      end)

    maxc = counts |> Map.values() |> Enum.max(fn -> 1 end)

    bar =
      for b <- 0..(bins - 1) do
        c = Map.get(counts, b, 0)
        h = round(100 * c / maxc)
        left = lo + b * step
        label = if mode == :int, do: "#{round(left)}", else: "#{round(left)}"
        ~s(<div class=hcol title="#{label}: #{c}"><div class=hbar style="height:#{max(h, 1)}%"></div></div>)
      end

    ~s(<div class=histo>#{bar}</div><div class=axis><span>#{round(lo)}</span><span>#{round(hi)}</span></div>)
  end

  # SVG scatter from [{x, y, color}] with labeled axes. Used for the
  # "wins at N colonies" plot — dots colored by faction.
  defp scatter(points, xlabel, ylabel) when points == [],
    do: "<p class=empty>no winning games yet</p>"

  defp scatter(points, xlabel, ylabel) do
    xs = Enum.map(points, fn {x, _, _} -> x end)
    ys = Enum.map(points, fn {_, y, _} -> y end)
    xmax = Enum.max([Enum.max(xs), 1])
    ymax = Enum.max([Enum.max(ys), 1])
    w = 640
    h = 200
    pl = 40
    pr = 12
    pt = 12
    pb = 30
    pw = w - pl - pr
    ph = h - pt - pb
    xat = fn x -> pl + x / xmax * pw end
    yat = fn y -> pt + (1.0 - y / ymax) * ph end

    dots =
      points
      |> Enum.map(fn {x, y, c} ->
        ~s|<circle cx="#{Float.round(xat.(x), 1)}" cy="#{Float.round(yat.(y), 1)}" r="6" fill="#{c}" fill-opacity="0.9" stroke="#0e1116" stroke-width="1.5"><title>#{x} colonies: #{y} wins</title></circle>|
      end)
      |> Enum.join()

    xticks =
      0..round(xmax)
      |> Enum.map(fn x ->
        ~s|<text x="#{Float.round(xat.(x), 1)}" y="#{h - 10}" text-anchor="middle" class=svgtxt>#{x}</text>|
      end)
      |> Enum.join()

    ~s|<svg viewBox="0 0 #{w} #{h}" width="#{w}" height="#{h}" class=lc>| <>
      ~s|<line x1="#{pl}" y1="#{pt}" x2="#{pl}" y2="#{pt + ph}" class="axl"/>| <>
      ~s|<line x1="#{pl}" y1="#{pt + ph}" x2="#{pl + pw}" y2="#{pt + ph}" class="axl"/>| <>
      ~s|<text x="#{pl - 6}" y="#{pt + 8}" text-anchor="end" class=svgtxt>#{round(ymax)}</text>| <>
      ~s|<text x="#{pl - 6}" y="#{pt + ph}" text-anchor="end" class=svgtxt>0</text>| <>
      ~s|<text x="12" y="#{pt + ph / 2}" text-anchor="middle" class=svgtxt transform="rotate(-90 12 #{pt + ph / 2})">#{ylabel}</text>| <>
      ~s|<text x="#{pl + pw / 2}" y="#{h - 1}" text-anchor="middle" class=svgtxt>#{xlabel}</text>| <>
      dots <> xticks <> "</svg>"
  end

  # --- layout -----------------------------------------------------------------

  defp section(title, inner), do: ~s(<section><h2>#{title}</h2>#{inner}</section>)
  defp two_col(a, b), do: ~s(<div class=grid2>#{a}#{b}</div>)

  # A titled block WITHIN a section (no panel chrome), with a sub-caption.
  defp subsection(title, cap, inner),
    do: ~s(<div class=subsec><h3>#{title}</h3><div class=cap>#{cap}</div>#{inner}</div>)

  # --- genome explorer --------------------------------------------------------

  # An interactive strip of every gene, blocked by category and shaded by how
  # strongly the reference champion expresses it (0..1 of the gene's range).
  # Hovering a gene shows its population distribution + what it does. Data is
  # embedded as JSON and rendered by a tiny inline script (no deps).
  defp genome_explorer(evals, champs) do
    spec = Headless.Policies.Tunable.spec()

    ref =
      champs
      |> Enum.flat_map(fn {f, es} -> Enum.map(es, &{f, &1}) end)
      |> Enum.max_by(fn {_f, e} -> e["fitness"] end, fn -> nil end)

    case ref do
      nil ->
        "<p class=empty>no champion genome yet</p>"

      {ref_fac, ref_entry} ->
        ref_g = ref_entry["genome"] || %{}
        genomes = Enum.map(evals, &(&1["genome"] || %{}))

        genes =
          spec
          |> Enum.reject(fn {k, _} -> k == "targets" end)
          |> Enum.map(fn {k, {lo, hi}} ->
            v = to_num(Map.get(ref_g, k, lo))
            vals = Enum.map(genomes, &to_num(Map.get(&1, k, lo)))
            span = if hi > lo, do: hi - lo, else: 1.0

            %{
              k: k,
              c: category(k),
              lab: glabel(k),
              d: gdesc(k),
              v: Float.round(v / 1, 2),
              n: Float.round(max(min((v - lo) / span, 1.0), 0.0), 3),
              lo: lo,
              hi: hi,
              m: Float.round(mean(vals), 2),
              h: bucketize(vals, lo, hi, 12)
            }
          end)
          |> Enum.sort_by(&{cat_order(&1.c), &1.k})

        by_cat =
          genes
          |> Enum.with_index()
          |> Enum.group_by(fn {g, _i} -> g.c end)

        strips =
          for cat <- cat_list(), Map.has_key?(by_cat, cat) do
            blocks =
              for {g, i} <- by_cat[cat] do
                shade = round(g.n * 100)
                ~s(<div class=gene data-i="#{i}" style="--x:#{shade}"><span class=gl>#{g.lab}</span></div>)
              end
              |> Enum.join()

            ~s(<div class=catrow><div class=catname>#{cat}</div><div class=genes>#{blocks}</div></div>)
          end
          |> Enum.join()

        json = Jason.encode!(genes)

        ~s|<p class=note>Reference champion: <b>#{ref_fac}</b> @ fitness #{round(ref_entry["fitness"])}. Block shade = how strongly it expresses each gene (dim to bright over the gene's range). Hover a gene for its population distribution across #{length(genomes)} genomes.</p>| <>
          ~s|<div class=genome>#{strips}</div>| <>
          ~s|<div id=gd class=genedetail><div class=gdhint>hover a gene...</div></div>| <>
          ~s|<script id=genes type="application/json">#{json}</script>| <>
          gene_script()
    end
  end

  defp to_num(x) when is_number(x), do: x / 1
  defp to_num(_), do: 0.0

  # Population distribution of a gene as `bins` bucket counts over [lo,hi].
  defp bucketize(values, lo, hi, bins) do
    hi = if hi <= lo, do: lo + 1, else: hi
    step = (hi - lo) / bins

    counts =
      Enum.reduce(values, %{}, fn v, acc ->
        b = v |> Kernel.-(lo) |> Kernel./(step) |> trunc() |> max(0) |> min(bins - 1)
        Map.update(acc, b, 1, &(&1 + 1))
      end)

    for b <- 0..(bins - 1), do: Map.get(counts, b, 0)
  end

  defp category("w_build_" <> _), do: "Buildings"
  defp category("w_patent_" <> _), do: "Patents"
  defp category("w_doc_" <> _), do: "Doctrines / lexes"
  defp category("w_mission_" <> _), do: "Covert missions"
  defp category("r_" <> _), do: "Reactions"
  defp category("focus_" <> _), do: "Archetype focus"

  defp category(k)
       when k in ~w(army_size blueprint_aggression blueprint_mix fleet_investment fleet_readiness
              fleet_retreat_hp reaction_stance w_raid_enemy w_conquest w_defend w_train_navarch
              w_train_covert w_flip_dominion w_undo_dominion w_governor),
       do: "Military / fleet"

  defp category(_), do: "Economy / opening"

  defp cat_list,
    do: [
      "Archetype focus",
      "Economy / opening",
      "Buildings",
      "Patents",
      "Doctrines / lexes",
      "Covert missions",
      "Military / fleet",
      "Reactions"
    ]

  defp cat_order(c), do: Enum.find_index(cat_list(), &(&1 == c)) || 99

  @mission_gene %{
    "infiltrate" => "infiltration",
    "destabilize" => "encourage_hate",
    "make_dominion" => "make_dominion",
    "assassinate" => "assassination",
    "convert" => "conversion"
  }

  defp glabel("w_build_" <> r), do: tname("building", r) || r
  defp glabel("w_patent_" <> r), do: tname("patent", r) || r
  defp glabel("w_doc_" <> r), do: tname("doctrine", r) || r
  defp glabel("w_mission_" <> r), do: tname("character_action_status", Map.get(@mission_gene, r, r)) || titleize(r)
  defp glabel(k), do: k

  @gdescs %{
    "opener_variant" => "Which opening book to run: governor / scout / colonial / exobiology.",
    "credit_floor" => "Credit the bot refuses to spend below — its solvency cushion.",
    "hire_reserve" => "Credit kept in reserve before hiring another agent.",
    "reserve_first_colony" => "Priority protecting the FIRST colony ship's 2000-tech price from patent purchases. A patent only dips into it if its own weight outranks this.",
    "reserve_followup_colony" => "Same tech-reservation priority, but for follow-up colony ships (which the fitness curve rewards far less).",
    "covert_focus" => "≥0.5 lets several agents stack a single destabilize target (the earthquake play).",
    "sandbag" => "Hold infiltration just under a visibility milestone to cross it in one burst.",
    "army_size" => "Target warfleet size in ships.",
    "reaction_stance" => "Fleet combat posture: passive / defend / attack-enemies / attack-all.",
    "fleet_retreat_hp" => "Recall a fleet once its surviving-HP fraction drops below this.",
    "fleet_readiness" => "Fraction of a commissioned fleet that must be built before it's sent.",
    "fleet_investment" => "Over- or under-build relative to army_size.",
    "blueprint_aggression" => "Which fleet blueprint to pick, by aggression (defense→hard-raid).",
    "blueprint_mix" => "How varied the ship mix is across admirals.",
    "w_econ_roi" => "Trust in the Econ bottleneck module that reprioritizes development.",
    "w_governor" => "Desire to seat spare admirals as system governors.",
    "focus_expansion" => "Multiplier on the whole expansion gene family.",
    "focus_military" => "Multiplier on the whole military gene family.",
    "focus_shadows" => "Multiplier on the whole covert gene family.",
    "focus_economy" => "Multiplier on the whole economy gene family.",
    "r_shadow_burst" => "Burst counter-intel when an enemy reaches shadow (visibility) stage 2+.",
    "r_shadow_sustain" => "Sustained shadow-defense lean, scaled by how deep the enemy is on the track.",
    "r_raid_high_pop" => "React when a high-population system is being raided.",
    "r_pressure_sprawl" => "React to an over-extended, sprawling enemy.",
    "r_siege_defense" => "React to a siege on your own systems.",
    "r_expand_slots" => "Push propaganda/flips when paid-for dominion slots sit empty.",
    "r_sprint_lead" => "Closing-sprint behavior when leading late.",
    "r_sprint_trail" => "Closing-sprint behavior when trailing late.",
    "w_mission_infiltrate" => "Weight on infiltrating enemy systems (visibility VP).",
    "w_mission_destabilize" => "Weight on destabilizing enemy worlds (encourage hate).",
    "w_mission_make_dominion" => "Weight on flipping neutral systems into dominions (sector control).",
    "w_mission_assassinate" => "Weight on assassinating discovered enemy agents.",
    "w_mission_convert" => "Weight on seducing/converting enemy agents.",
    "w_raid_enemy" => "Weight on raiding enemy systems with fleets.",
    "w_conquest" => "Weight on invading and taking enemy systems.",
    "w_defend" => "Weight on holding fleets defensively.",
    "w_train_navarch" => "Weight on training admirals on neutral raids.",
    "w_train_covert" => "Weight on training covert agents on neutral targets.",
    "w_flip_dominion" => "Weight on transforming an owned system into a dominion.",
    "w_undo_dominion" => "Weight on reverting a dominion back to a full system."
  }

  defp gdesc("w_build_" <> r), do: "How strongly the bot prioritizes building #{r}."
  defp gdesc("w_patent_" <> r), do: "How strongly the bot prioritizes researching the #{r} patent."
  defp gdesc("w_doc_" <> r), do: "How strongly the bot prioritizes the #{r} lex/doctrine."
  defp gdesc(k), do: Map.get(@gdescs, k, "Evolved scalar gene #{k}.")

  defp gene_script do
    """
    <script>
    (function(){
      var genes = JSON.parse(document.getElementById('genes').textContent);
      var gd = document.getElementById('gd');
      function bars(h){
        var mx = Math.max.apply(null, h) || 1;
        return '<div class="gdhist">' + h.map(function(c){
          return '<div class="gdcol"><div class="gdbar" style="height:'+Math.max(2,Math.round(100*c/mx))+'%"></div></div>';
        }).join('') + '</div>';
      }
      function show(g){
        gd.innerHTML =
          '<div class=gdhead><b>'+g.lab+'</b> <span class=gdcat>'+g.c+'</span> <code class=gdkey>'+g.k+'</code>'+
          '<span class=gdval>champion '+g.v+' · pop mean '+g.m+' · range '+g.lo+'–'+g.hi+'</span></div>'+
          '<div class=gddesc>'+g.d+'</div>'+ bars(g.h)+
          '<div class=gdaxis><span>'+g.lo+'</span><span>'+g.hi+'</span></div>';
      }
      document.querySelectorAll('.gene').forEach(function(el){
        el.addEventListener('mouseenter', function(){ show(genes[+el.dataset.i]); });
        el.addEventListener('click', function(){ show(genes[+el.dataset.i]); });
      });
    })();
    </script>
    """
  end

  defp page(title, body) do
    now = DateTime.utc_now() |> DateTime.to_string()

    """
    <!doctype html><html lang=en><head><meta charset=utf-8>
    <meta http-equiv="Cache-Control" content="no-store, must-revalidate">
    <meta name=viewport content="width=device-width,initial-scale=1">
    <title>#{title}</title>
    <style>#{css()}</style></head>
    <body><header><h1>Bot Performance</h1><div class=gen>generated #{now} UTC · refresh for latest</div></header>
    <main>#{body}</main></body></html>
    """
  end

  defp css do
    """
    :root{--bg:#0e1116;--panel:#171b22;--panel2:#1e242d;--fg:#e6edf3;--mut:#8b949e;--accent:#3f9;--bar:#3f66df;--bar2:#2a3a6b}
    *{box-sizing:border-box}
    body{margin:0;background:var(--bg);color:var(--fg);font:14px/1.5 -apple-system,Segoe UI,Roboto,sans-serif}
    header{padding:20px 28px;border-bottom:1px solid #2a3038}
    h1{margin:0;font-size:20px}
    .gen{color:var(--mut);font-size:12px;margin-top:4px}
    main{padding:20px 28px;max-width:1180px;margin:0 auto}
    section{background:var(--panel);border:1px solid #232a33;border-radius:10px;padding:16px 18px;margin:0 0 18px}
    h2{margin:0 0 14px;font-size:14px;color:var(--mut);text-transform:uppercase;letter-spacing:.04em}
    .grid2{display:grid;grid-template-columns:1fr 1fr;gap:18px}
    @media(max-width:800px){.grid2{grid-template-columns:1fr}}
    .grid2 section{margin:0}
    .grid3{display:grid;grid-template-columns:1fr 1fr 1fr;gap:14px}
    @media(max-width:800px){.grid3{grid-template-columns:1fr}}
    .tiles{display:flex;flex-wrap:wrap;gap:10px}
    .tile{background:var(--panel2);border-radius:8px;padding:12px 16px;min-width:92px}
    .tile .v{font-size:22px;font-weight:600}
    .tile .k{color:var(--mut);font-size:11px;text-transform:uppercase;letter-spacing:.03em;margin-top:2px}
    .tile.bad .v{color:#f77}
    .hbars{display:flex;flex-direction:column;gap:7px}
    .row{display:grid;grid-template-columns:120px 1fr auto;align-items:center;gap:10px}
    .lab{font-size:13px;text-align:right;color:var(--fg);overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
    .bar{background:var(--panel2);border-radius:5px;height:16px;overflow:hidden}
    .fill{background:linear-gradient(90deg,var(--bar2),var(--bar));height:100%;border-radius:5px}
    .val{font-variant-numeric:tabular-nums;font-weight:600;min-width:38px;text-align:right}
    .sub{grid-column:2/4;color:var(--mut);font-size:11px;margin-top:-3px}
    .sub.wide{grid-column:2/4}
    .lead{margin:0 0 12px;color:var(--fg)}
    .histo{display:flex;align-items:flex-end;gap:3px;height:150px;padding-top:8px}
    .histo.trend{height:120px;gap:8px}
    .hcol{flex:1;display:flex;flex-direction:column;justify-content:flex-end;align-items:center;height:100%}
    .hbar{width:100%;background:linear-gradient(180deg,var(--bar),var(--bar2));border-radius:3px 3px 0 0;min-height:2px}
    .tlab{font-size:10px;color:var(--mut);margin-top:4px}
    .axis{display:flex;justify-content:space-between;color:var(--mut);font-size:11px;margin-top:4px}
    .lc{width:100%;height:auto;max-width:100%;display:block}
    .svgtxt{fill:var(--mut);font-size:11px}
    .axl{stroke:#2a3038;stroke-width:1}
    table{width:100%;border-collapse:collapse;font-size:13px}
    th{text-align:left;color:var(--mut);font-weight:500;font-size:11px;text-transform:uppercase;padding:6px 8px;border-bottom:1px solid #2a3038}
    td{padding:6px 8px;border-bottom:1px solid #1e242d}
    td.num,th.num{font-variant-numeric:tabular-nums;text-align:center}
    td.fac{font-weight:600}
    .fdot{display:inline-block;width:9px;height:9px;border-radius:50%;margin-right:7px;vertical-align:baseline;box-shadow:0 0 6px currentColor}
    .gdkey{font-family:ui-monospace,Menlo,monospace;font-size:11px;color:var(--mut);background:var(--panel);border-radius:4px;padding:1px 6px}
    .chip{display:inline-block;background:var(--panel2);border-radius:4px;padding:1px 7px;font-size:11px;color:var(--accent)}
    .empty{color:var(--mut)}
    .note{color:var(--mut);font-size:12px;margin:0 0 12px;line-height:1.45}
    .hidden{display:none}
    .winbar{display:flex;align-items:center;gap:8px;flex-wrap:wrap;margin:0 0 18px;position:sticky;top:0;background:var(--bg);padding:10px 0;z-index:5}
    .winlab{color:var(--mut);font-size:11px;text-transform:uppercase;letter-spacing:.04em}
    .wbtn{background:var(--panel2);color:var(--fg);border:1px solid #2a3038;border-radius:6px;padding:5px 13px;font-size:13px;cursor:pointer;font-variant-numeric:tabular-nums}
    .wbtn:hover{border-color:var(--accent)}
    .wbtn.active{background:var(--bar);border-color:var(--bar);color:#fff;font-weight:600}
    .winhint{color:var(--mut);font-size:11px}
    .subsec h3{margin:0;font-size:13px}
    .subsec .cap{color:var(--mut);font-size:11px;margin:2px 0 8px}
    /* first-colony funnel: full-width labels (no truncation) + rows visually
       grouped as label-on-top, bar + value on one line, dividers between */
    .funnel{display:flex;flex-direction:column}
    .frow{padding:10px 2px;border-top:1px solid #2a3038}
    .frow:first-child{border-top:0;padding-top:2px}
    .flab{font-size:13px;color:var(--fg);margin-bottom:7px;line-height:1.35}
    .flab .fdot{box-shadow:none;vertical-align:middle}
    .fbar{display:flex;align-items:center;gap:12px}
    .ftrk{flex:1;background:var(--panel2);border-radius:5px;height:15px;overflow:hidden}
    .ffill{height:100%;border-radius:5px;min-width:2px}
    .fsub{color:var(--mut);font-size:12px;white-space:nowrap;min-width:108px;text-align:right;font-variant-numeric:tabular-nums}
    /* genome explorer */
    .genome{display:flex;flex-direction:column;gap:8px}
    .catrow{display:grid;grid-template-columns:120px 1fr;gap:10px;align-items:start}
    .catname{color:var(--mut);font-size:11px;text-align:right;padding-top:5px;text-transform:uppercase;letter-spacing:.03em}
    .genes{display:flex;flex-wrap:wrap;gap:3px}
    .gene{background:rgba(63,102,223,calc((var(--x)*0.9 + 8)/100));border:1px solid #2a3646;border-radius:4px;
      padding:3px 6px;font-size:10px;cursor:pointer;max-width:112px;overflow:hidden;white-space:nowrap;text-overflow:ellipsis}
    .gene:hover{outline:1px solid var(--accent)}
    .gl{color:#dfe7f5}
    .genedetail{margin-top:14px;background:var(--panel2);border-radius:8px;padding:12px 14px;min-height:120px}
    .gdhint{color:var(--mut)}
    .gdhead{display:flex;flex-wrap:wrap;gap:8px;align-items:baseline}
    .gdcat{color:var(--accent);font-size:11px;background:var(--panel);border-radius:4px;padding:1px 7px}
    .gdval{color:var(--mut);font-size:12px;font-variant-numeric:tabular-nums}
    .gddesc{color:var(--fg);font-size:13px;margin:6px 0 10px}
    .gdhist{display:flex;align-items:flex-end;gap:3px;height:90px}
    .gdcol{flex:1;display:flex;align-items:flex-end;height:100%}
    .gdbar{width:100%;background:linear-gradient(180deg,var(--bar),var(--bar2));border-radius:3px 3px 0 0;min-height:2px}
    .gdaxis{display:flex;justify-content:space-between;color:var(--mut);font-size:11px;margin-top:4px}
    """
  end
end

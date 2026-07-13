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

    # Companion page: the decision-pipeline anatomy (how a genome becomes
    # actions) with live per-node throughput. Structure is code; only the
    # numbers change per render.
    policy_dest = Path.join(Path.dirname(dest), "bot_policy.html")
    File.write!(policy_dest <> ".tmp", policy_page(evals, dir))
    File.rename!(policy_dest <> ".tmp", policy_dest)
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

    page("Bot Performance", body, ~s|<a class=navlink href="bot_policy.html">How genomes become actions →</a>|)
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
      # TWO COHORTS (user question 2026-07-12): "all" is every evaluated
      # genome — mostly exploration by construction (mutants + a fresh
      # random each iteration + covert niches that win without developing),
      # so it structurally lags. The FRONTIER (top-20% fitness, same cut as
      # champion-quality) is the product question: are the bots we'd ship
      # approaching human pace?
      thr = percentile(Enum.map(evals, & &1["fitness"]), 0.80)
      frontier = Enum.filter(evals, &(&1["fitness"] >= thr))

      cp_snaps = fn grp, cp ->
        grp
        |> Enum.map(fn e -> get_in(e, ["stats", "checkpoints", to_string(cp)]) end)
        |> Enum.filter(&is_map/1)
      end

      blocks =
        for cp <- [25, 50, 75] do
          golden = @golden[cp]
          sa = cp_snaps.(evals, cp)
          sf = cp_snaps.(frontier, cp)
          na = max(length(sa), 1)
          nf = max(length(sf), 1)

          rows =
            Enum.flat_map(@golden_metrics, fn {m, label} ->
              gv = golden[m]
              pa = Enum.count(sa, &((&1[m] || 0) >= gv))
              pf = Enum.count(sf, &((&1[m] || 0) >= gv))
              ma = sa |> Enum.map(&(&1[m] || 0)) |> median()
              mf = sf |> Enum.map(&(&1[m] || 0)) |> median()

              [
                {label, pct(pa, na), "all — gold #{fmt_int(gv)} · median #{fmt_int(round(ma))}", "#3d4854"},
                {"↳ top 20%", pct(pf, nf), "frontier median #{fmt_int(round(mf))}", "#c9a115"}
              ]
            end)

          seal = fn snaps, n ->
            pct(
              Enum.count(snaps, fn s ->
                Enum.all?(@golden_metrics, fn {m, _} -> (s[m] || 0) >= golden[m] end)
              end),
              n
            )
          end

          subsection(
            "#{cp}% elapsed",
            "#{length(sa)} evals · gold seal — all: <b>#{seal.(sa, na)}%</b> · top 20%: <b>#{seal.(sf, nf)}%</b>",
            hbars(rows, 100, "%")
          )
        end

      note =
        ~s|<p class=note>Two cohorts per metric: <b>all</b> (slate) = every genome evaluated in the window — mostly exploration (mutants, fresh randoms, covert niches that win without developing), so it lags by construction. <b><span style="color:#c9a115">top 20%</span></b> = the fitness frontier, the same cut as "champion-quality" — the bots we would actually ship. The line is a human's <b>casual</b> game (instance 7) — a floor, not a ceiling. Agent target (soft): ~5 Siderians / 3 Navarchs / 3 Erased by late game.</p>|

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
    "w_growth" => "How aggressively to chase the population growth curve: scales the stability (>24) and housing-headroom (>10) build boosts, and gates the growth patents.",
    "growth_pop_target" => "Per-system population where the growth push stops — the curve's payoff decays hard toward the 120 cap, so ~70 is the knee.",
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

  # --- policy anatomy page ------------------------------------------------------
  #
  # "How does a genome become actions?" The pipeline SHAPE is fixed code —
  # genes are numeric knobs read by fixed decision nodes — except the
  # `targets` section (evolvable consideration lists) and `opener_variant`
  # (picks a hand-written book). This page draws the pipeline, documents
  # every node (genes read, actions emitted, gates), shows LIVE per-node
  # throughput from recent evals, and contrasts the structural genome of
  # the best evolved champion vs a synthetic seed.

  @node_groups %{
    expansion: {"Expansion", "#3f66df"},
    economy: {"Economy", "#2ea043"},
    military: {"Military", "#bc2433"},
    covert: {"Agents & covert", "#8e60bf"}
  }

  # Execution order = decide_main's action assembly order.
  @policy_nodes [
    %{key: :mission, group: :expansion, title: "Colonization dispatch",
      what: "Sends idle transport-equipped Navarchs to claim systems. Candidate targets are scored by the evolvable consideration list — the one place the genome's STRUCTURE (not just numbers) decides.",
      genes: ~w(targets[colonize] focus_expansion), emits: "colonization mission",
      gates: ~w(colonize_no_ready_transport colonize_syscap)},
    %{key: :employ, group: :covert, title: "Agent employment",
      what: "Batched: every idle Erased/Siderian gets its best mission per role doctrine (Siderians flip neutral dominions / destabilize / seduce; Erased sabotage / remove agents / infiltrate; low-level agents explore for safe XP; agents may sit home as guards).",
      genes: ~w(w_mission_infiltrate w_mission_destabilize w_mission_make_dominion w_mission_assassinate w_mission_convert covert_focus focus_shadows),
      emits: "covert missions + deployments", gates: []},
    %{key: :fleet_emp, group: :military, title: "Fleet employment",
      what: "Raids, conquests and defense for commissioned fleets; targets scored by the raid/conquest/defend consideration lists.",
      genes: ~w(w_raid_enemy w_conquest w_defend fleet_readiness targets[raid|conquest|defend] focus_military),
      emits: "raid / conquest / defend missions", gates: []},
    %{key: :reactions, group: :military, title: "Reactive defense",
      what: "Repositions in response to live threats (sieges, raids on high-population systems).",
      genes: ~w(reaction_stance r_siege_defense), emits: "defensive repositions", gates: []},
    %{key: :dominion, group: :expansion, title: "Dominion management",
      what: "Flips scouted neutral systems into dominions for sector control (and un-flips when the math favors it).",
      genes: ~w(w_flip_dominion w_undo_dominion), emits: "transform to dominion", gates: []},
    %{key: :doctrine, group: :economy, title: "Lex purchases",
      what: "Strict-priority ideology spending over 40 lexes: the expansion ladder (system caps), fleet capacity, covert branches, economy multipliers. Rate-limited to one attempt per 15 ticks.",
      genes: ~w(w_doc_*×40), emits: "purchase lex", gates: []},
    %{key: :ships, group: :expansion, title: "Colony-ship pipeline",
      what: "Slot-gated: orders a transport for every idle colonizer Navarch while open system slots exceed ships owned/being built. The tech reserve protects the ship's 2000-tech price from patent spending.",
      genes: ~w(credit_floor reserve_first_colony reserve_followup_colony),
      emits: "order transport", gates: ~w(no_slot all_committed patent_locked no_tech no_credit no_admiral)},
    %{key: :patents, group: :economy, title: "Patent purchases",
      what: "Strict-priority tech spending over ~40 patents with DESIRE PROPAGATION: a zero-weight prerequisite under a wanted descendant is bought as a stepping stone. Saves toward the single top-weight target.",
      genes: ~w(w_patent_*×40), emits: "purchase patent", gates: []},
    %{key: :roster, group: :covert, title: "Hiring & seating",
      what: "Hires agents from the market and seats spare Navarchs as system governors.",
      genes: ~w(hire_reserve w_train_navarch w_train_covert w_governor), emits: "hire / seat governor", gates: []},
    %{key: :commission, group: :military, title: "Fleet construction",
      what: "Builds whole fleets from arena-bred blueprints (code); the genome only chooses aggression, mix and size — never individual ships.",
      genes: ~w(army_size blueprint_aggression blueprint_mix), emits: "order warships (batch)", gates: []},
    %{key: :builds, group: :economy, title: "Building construction",
      what: "One best-scoring building per idle system queue, over the full 34-building catalog. The happiness gate (code) bars negative-happiness buildings below the floor and boosts producers.",
      genes: ~w(w_build_*×34 credit_floor w_econ_roi focus_economy), emits: "order building", gates: ~w(happiness-floor credit_floor)}
  ]

  @modulation [
    {"Reactions", "gene",
     "Threat signals (code: enemy shadow stage, sieges, sprawl, the closing sprint) scale whole gene families ×(1+r) for THIS decision only.",
     ~w(r_shadow_burst r_shadow_sustain r_raid_high_pop r_pressure_sprawl r_siege_defense r_expand_slots r_sprint_lead r_sprint_trail)},
    {"Expansion critical path", "code",
     "UNCONDITIONAL overrides: next system-cap lex → transport patent → tech bootstrap (university/research builds at 11.0 while the chain needs tech) → parallel-admiral lex → research-patent rung (income-gated). Protects colonization from strict-priority starvation no matter the genome.",
     []},
    {"Econ patent pressure", "gene",
     "The ROI module raises patent weights that gate buildings the genome already wants — trust scaled by one gene.",
     ~w(w_econ_roi)}
  ]

  defp policy_page(evals, dir) do
    now = (List.last(evals) || %{})["at"] || 0
    recent = Enum.filter(evals, &((&1["at"] || 0) >= now - 7_200))
    recent = if recent == [], do: Enum.take(evals, -200), else: recent
    n = max(length(recent), 1)

    body =
      section("The short answer", policy_intro()) <>
        section("The decision pipeline (every ~250ms of game time)", policy_flow()) <>
        section("Inside a node — where the branching actually lives", policy_cascades()) <>
        section("Decision nodes — genes in, actions out (live: last #{n} evals)", policy_cards(recent, n)) <>
        section("Structural genome — the part where SHAPE evolves", policy_targets(dir)) <>
        section("Reading the genome explorer with this map", policy_legend())

    page("Bot Policy — genome → actions", body, ~s|<a class=navlink href="bot_dashboard.html">← Bot Performance</a>|)
  end

  defp policy_intro do
    ~s|<p class=lead>A bot genome is ~150 numbers plus one structured section. <b>The decision tree itself is fixed code</b> — evolution does not grow or rewire nodes. What evolves is: <b>(1) the numbers</b> each fixed node reads (weights = purchase priority, thresholds, reserves), <b>(2) the consideration lists</b> that score targets (the only structural, complexifying part), and <b>(3) which opening book</b> to run. Three code-level override layers sit ABOVE the genome and force critical-path behavior no genome may starve (expansion chain, tech bootstrap, happiness floor) — red in the diagram below.</p>| <>
      ~s|<p class=note>Flow per decision: build a <b>View</b> (perception) → if the opening book is still running it owns every action → otherwise the genome is copied and <b>modulated</b> (reactions, critical-path overrides, econ pressure) → each <b>decision node</b> reads its genes from that modulated copy and emits abstract actions → the driver executes them against the engine and tallies ok/refused.</p>|
  end

  defp policy_flow do
    mods =
      Enum.map(@modulation, fn {t, kind, _, _} ->
        cls = if kind == "code", do: "fnode override", else: "fnode mod"
        ~s|<div class="#{cls}">#{t}</div>|
      end)
      |> Enum.join(~s|<span class=farrow>→</span>|)

    nodes =
      Enum.map(@policy_nodes, fn nd ->
        {_, color} = @node_groups[nd.group]
        ~s|<div class=fnode style="border-color:#{color}">#{nd.title}</div>|
      end)
      |> Enum.join("")

    legend =
      Enum.map(@node_groups, fn {_, {label, color}} ->
        ~s|<span class=lgd><span class=fdot style="background:#{color};color:#{color}"></span>#{label}</span>|
      end)
      |> Enum.join(" ")

    ~s|<div class=flowband><div class=fnode>View<div class=fsubt>perception</div></div><span class=farrow>→</span><div class="fnode book">Opening book<div class=fsubt>owns ALL decisions until done · opener_variant picks 1 of 4</div></div><span class=farrow>→</span>#{mods}</div>| <>
      ~s|<div class=flowdown>↓ modulated genome copy (heredity untouched)</div>| <>
      ~s|<div class=flowgrid>#{nodes}</div>| <>
      ~s|<div class=flowdown>↓ abstract actions → driver → engine (ok / refused tallies)</div>| <>
      ~s|<p class=note>#{legend} · <span class=lgd><span class=fdot style="background:#b8860b;color:#b8860b"></span>genome modulation</span> <span class=lgd><span class=fdot style="background:#e5534b;color:#e5534b"></span>code override (no gene may starve it)</span></p>| <>
      ~s|<p class=note><b>The flat top level is deliberate.</b> ALL nodes run EVERY decision — a <b>portfolio</b>, not a selector tree — because an empire is concurrent: it builds, buys, sails and spies in the same tick. A root "choose economy OR military" selector would serialize what the game lets you do in parallel. The tree-shaped branching lives one level down, INSIDE each node (next section), and the nodes arbitrate shared credit/tech through floors, reserves and a fixed within-tick claim order rather than through a parent node.</p>|
  end

  # The internal decision cascades of three representative nodes, drawn as
  # vertical gate chains — the "actual tree" a reader looking for branching
  # expects to see. Kept in sync with ship_actions/build_actions/
  # employ_one+covert_task by hand; update when those cond ladders change.
  defp policy_cascades do
    ship =
      casc_card("Colony-ship pipeline", "#3f66df", "per decision", [
        {"any open system slot? (max_systems − owned)", "no_slot"},
        {"slot not already covered by a ship built/being built?", "all_committed"},
        {"transport patent owned?", "patent_locked"},
        {"tech ≥ 2,000?", "no_tech"},
        {"credit ≥ 12k + credit_floor?", "no_credit"},
        {"an idle colonizer Navarch at home with a free army tile?", "no_admiral"}
      ], "order a transport for EVERY idle colonizer — capped by open slots and budget")

    build =
      casc_card("Building construction", "#2ea043", "per owned system, per decision", [
        {"build queue idle? (engine: one building at a time per system)", "skip system"},
        {"start: all 34 buildings … drop those whose patent is missing", "filtered"},
        {"drop: credit < cost + credit_floor", "filtered"},
        {"drop: happiness < 15 AND the building costs happiness", "happiness gate"},
        {"score the rest: genome weight + econ bonus + surplus fill + happiness rescue", nil}
      ], "order the single best-scoring building (if it clears the threshold)")

    agents =
      casc_card("Agent employment", "#8e60bf", "per idle agent, highest level first", [
        {"high-level Erased in an owned system while an enemy fleet is on radar? → HOLD as guard", "guard"},
        {"the designated explorer (lowest-level idle)? → scout; map fully revealed → fall through", "explore"},
        {"roles for this type, sorted by genome weight — Siderian: flip neutral / destabilize / seduce · Erased: assassinate / infiltrate — first role with a viable, unreserved, reachable target wins", nil},
        {"nothing viable and low-level? → explore for safe XP", "explore"}
      ], "dispatch the mission; the target system is reserved so agents don't stack (unless the earthquake gene says so)")

    precedence =
      ~w(patents lexes hiring colony·ships fleet·construction dominions buildings colonization covert military reactions)
      |> Enum.map(&~s|<div class=fnode style="font-weight:400">#{String.replace(&1, "·", " ")}</div>|)
      |> Enum.join(~s|<span class=farrow>→</span>|)

    ~s|<div class=grid3>#{ship}#{build}#{agents}</div>| <>
      ~s|<p class=note style="margin-top:14px"><b>Who wins shared resources:</b> within a tick the assembled actions execute in this fixed order — earlier claims on credit/tech win; across ticks, floors and reserves arbitrate. The patent tree itself is a literal tree (ancestors gate descendants): the patent node walks it with desire propagation, so a zero-weight prerequisite under a wanted descendant still gets bought.</p>| <>
      ~s|<div class=flowband>#{precedence}</div>|
  end

  defp casc_card(title, color, cadence, steps, success) do
    rows =
      Enum.map_join(steps, "", fn {cond_text, gate} ->
        g = if gate, do: ~s|<span class=gate>#{gate}</span>|, else: ""
        ~s|<div class=cstep><span>#{cond_text}</span>#{g}</div><div class=cdown>↓</div>|
      end)

    ~s|<div class=casc style="border-top-color:#{color}"><div class=nchead><b>#{title}</b><span class=ncgroup style="color:#{color}">#{cadence}</span></div>| <>
      ~s|<div class=ccap>red = what happens when the step fails (the same names the blocker funnel counts)</div>| <>
      rows <> ~s|<div class="cstep ok">#{success}</div></div>|
  end

  defp policy_cards(recent, n) do
    s = fn e, k -> get_in(e, ["stats", k]) end

    usage = fn group ->
      recent
      |> Enum.map(fn e -> (s.(e, "usage") || %{}) |> Map.get(group, %{}) |> Map.values() |> Enum.sum() end)
      |> Enum.sum()
    end

    mission_vol = fn keys ->
      recent
      |> Enum.map(fn e ->
        m = (s.(e, "usage") || %{}) |> Map.get("mission", %{})
        keys |> Enum.map(&Map.get(m, &1, 0)) |> Enum.sum()
      end)
      |> Enum.sum()
    end

    blocks =
      Enum.reduce(recent, %{}, fn e, acc ->
        Enum.reduce(s.(e, "blocks") || %{}, acc, fn {k, v}, a -> Map.update(a, k, v, &(&1 + v)) end)
      end)

    top_builds =
      recent
      |> Enum.reduce(%{}, fn e, acc ->
        Enum.reduce((s.(e, "usage") || %{}) |> Map.get("build", %{}), acc, fn {k, v}, a ->
          Map.update(a, k, v, &(&1 + v))
        end)
      end)
      |> Enum.sort_by(&(-elem(&1, 1)))
      |> Enum.take(3)
      |> Enum.map(fn {k, v} -> "#{tname("building", k) || titleize(k)} #{fmt_int(div(v, n))}/eval" end)
      |> Enum.join(" · ")

    live = %{
      mission: "#{r1(mission_vol.(["colonization"]) / n)}/eval colonizations",
      employ: "#{fmt_int(div(mission_vol.(~w(infiltrate encourage_hate make_dominion assassination conversion)), n))}/eval covert missions",
      fleet_emp: "#{r1(mission_vol.(~w(raid conquest)) / n)}/eval raids+conquests",
      reactions: nil,
      dominion: nil,
      doctrine: "#{r1(usage.("doctrine") / n)}/eval lexes",
      ships: "#{r1(usage.("ship") / n)}/eval ships · top gate: #{top_gate(blocks)}",
      patents: "#{r1(usage.("patent") / n)}/eval patents",
      roster: nil,
      commission: nil,
      builds: "#{fmt_int(div(usage.("build"), n))}/eval · #{top_builds}"
    }

    cards =
      Enum.map(@policy_nodes, fn nd ->
        {glabel, color} = @node_groups[nd.group]
        genes = nd.genes |> Enum.map(&~s|<span class=gdkey>#{&1}</span>|) |> Enum.join(" ")

        gates =
          case nd.gates do
            [] -> ""
            gs -> ~s|<div class=ncrow><b>gates</b> #{Enum.map_join(gs, " ", &~s(<span class=gate>#{&1}</span>))}</div>|
          end

        livestat =
          case live[nd.key] do
            nil -> ""
            txt -> ~s|<div class=nclive>#{txt}</div>|
          end

        ~s|<div class=ncard style="border-top-color:#{color}"><div class=nchead><b>#{nd.title}</b><span class=ncgroup style="color:#{color}">#{glabel}</span></div>| <>
          ~s|<p class=ncwhat>#{nd.what}</p><div class=ncrow><b>genes</b> #{genes}</div>| <>
          ~s|<div class=ncrow><b>emits</b> #{nd.emits}</div>#{gates}#{livestat}</div>|
      end)
      |> Enum.join("")

    ~s|<div class=ncards>#{cards}</div>|
  end

  defp top_gate(blocks) do
    blocks
    |> Enum.filter(fn {k, _} -> String.starts_with?(k, "transport") end)
    |> Enum.max_by(&elem(&1, 1), fn -> {"none", 0} end)
    |> elem(0)
    |> String.replace("transport_", "")
  end

  defp policy_targets(dir) do
    entries =
      ~w(tetrarchy myrmezir ark cardan synelle)
      |> Enum.flat_map(fn f ->
        case File.read(Path.join(dir, "archive_#{f}.json")) do
          {:ok, json} -> json |> Jason.decode!() |> Enum.map(fn {k, v} -> {f, k, v} end)
          _ -> []
        end
      end)

    best =
      entries
      |> Enum.reject(fn {_, k, _} -> String.starts_with?(k, "seed_") end)
      |> Enum.max_by(fn {_, _, v} -> v["fitness"] || 0 end, fn -> nil end)

    seed = Enum.find(entries, fn {_, k, _} -> k == "seed_developer" end)

    cols =
      [{"Best evolved champion", best}, {"seed_developer (hand-designed)", seed}]
      |> Enum.map(fn
        {label, nil} ->
          ~s|<div class=subsec><h3>#{label}</h3><p class=empty>not found</p></div>|

        {label, {f, _k, v}} ->
          targets = get_in(v, ["genome", "targets"]) || %{}

          rows =
            Enum.map_join(~w(colonize raid conquest defend infiltrate destabilize), "", fn point ->
              chips =
                case Map.get(targets, point) do
                  nil ->
                    ~s|<span class=empty>—</span>|

                  considerations ->
                    Enum.map_join(considerations, " ", fn [name, w] ->
                      ~s|<span class=tchip>#{name} <b>#{r1(w / 1)}</b></span>|
                    end)
                end

              ~s|<div class=trow><span class=tpoint>#{point}</span>#{chips}</div>|
            end)

          cap = ~s|fitness #{round(v["fitness"] || 0)} · <span style="color:#{faction_color(f)}">#{faction_name(f)}</span>|
          ~s|<div class=subsec><h3>#{label}</h3><div class=cap>#{cap}</div>#{rows}</div>|
      end)
      |> Enum.join("")

    note =
      ~s|<p class=note>Each decision point ranks its candidate systems by a weighted sum of CONSIDERATIONS (strength, proximity, population, …). Mutations can add, remove or reweight considerations — complexification. This is the only place the genome's <b>shape</b>, not just its numbers, evolves; everything else on this page is fixed plumbing around evolved constants.</p>|

    note <> ~s|<div class=grid2>#{cols}</div>|
  end

  defp policy_legend do
    ~s|<p class=note>On the <a class=navlink href="bot_dashboard.html">performance page</a>, the genome explorer shows the VALUES of these genes across recent evals and champions; this page is the wiring those values flow through. Rules of thumb: <b>w_*</b> weights are priorities inside one node's ranking (0–10; 11.0 marks a code override) · <b>r_*</b> reactions multiply families per-decision · <b>focus_*</b> scale families at birth · scalars (floors, reserves) gate spending. A gene only matters if its node's preconditions ever fire — which is why usage/eval and the gates above are shown live.</p>|
  end

  defp page(title, body, nav \\ "") do
    now = DateTime.utc_now() |> DateTime.to_string()

    """
    <!doctype html><html lang=en><head><meta charset=utf-8>
    <meta http-equiv="Cache-Control" content="no-store, must-revalidate">
    <meta name=viewport content="width=device-width,initial-scale=1">
    <title>#{title}</title>
    <style>#{css()}</style></head>
    <body><header><div class=hrow><h1>#{title}</h1>#{nav}</div><div class=gen>generated #{now} UTC · refresh for latest</div></header>
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
    /* policy anatomy page */
    .hrow{display:flex;align-items:baseline;gap:16px;flex-wrap:wrap}
    .navlink{color:var(--accent);font-size:13px;text-decoration:none}
    .navlink:hover{text-decoration:underline}
    .flowband{display:flex;align-items:stretch;gap:8px;flex-wrap:wrap;margin-bottom:10px}
    .fnode{background:var(--panel2);border:1px solid #2a3038;border-radius:8px;padding:8px 12px;font-size:13px;font-weight:600;display:flex;flex-direction:column;justify-content:center}
    .fnode.book{border-color:#8b949e}
    .fnode.mod{border-color:#b8860b}
    .fnode.override{border-color:#e5534b}
    .fsubt{font-weight:400;color:var(--mut);font-size:11px;margin-top:2px;max-width:230px}
    .farrow{color:var(--mut);align-self:center;font-size:15px}
    .flowdown{color:var(--mut);font-size:12px;margin:6px 0;padding-left:8px}
    .flowgrid{display:flex;flex-wrap:wrap;gap:8px;margin-bottom:10px}
    .flowgrid .fnode{border-width:1px;border-left-width:4px}
    .lgd{margin-right:12px;font-size:12px;white-space:nowrap}
    .ncards{display:grid;grid-template-columns:1fr 1fr;gap:14px}
    @media(max-width:900px){.ncards{grid-template-columns:1fr}}
    .ncard{background:var(--panel2);border-radius:8px;border-top:3px solid var(--bar);padding:12px 14px}
    .nchead{display:flex;justify-content:space-between;align-items:baseline;gap:10px}
    .ncgroup{font-size:11px;text-transform:uppercase;letter-spacing:.03em}
    .ncwhat{color:var(--mut);font-size:12.5px;line-height:1.45;margin:6px 0 10px}
    .ncrow{font-size:12px;margin:4px 0;line-height:1.9}
    .ncrow b{color:var(--mut);font-size:10px;text-transform:uppercase;margin-right:6px}
    .nclive{margin-top:8px;padding-top:8px;border-top:1px solid #2a3038;font-size:12px;color:var(--accent);font-variant-numeric:tabular-nums}
    .gate{font-family:ui-monospace,Menlo,monospace;font-size:10.5px;background:rgba(229,83,75,.12);color:#e5947f;border-radius:4px;padding:1px 6px}
    .casc{background:var(--panel2);border-radius:8px;border-top:3px solid var(--bar);padding:12px 14px}
    .ccap{color:var(--mut);font-size:11px;margin:4px 0 10px}
    .cstep{display:flex;justify-content:space-between;align-items:center;gap:10px;background:var(--panel);border:1px solid #2a3038;border-radius:6px;padding:7px 10px;font-size:12px;line-height:1.4}
    .cstep.ok{border-color:#2ea043;color:#c6e8c6}
    .cdown{color:var(--mut);font-size:11px;padding:1px 0 1px 14px}
    .trow{display:flex;align-items:baseline;gap:8px;flex-wrap:wrap;padding:5px 0;border-top:1px solid #232a33}
    .tpoint{min-width:86px;color:var(--mut);font-size:12px;text-align:right}
    .tchip{background:var(--panel);border:1px solid #2a3646;border-radius:4px;padding:1px 7px;font-size:11px}
    .tchip b{color:var(--accent)}
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

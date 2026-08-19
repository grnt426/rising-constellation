defmodule RC.Discord.Render.Cards do
  @moduledoc """
  Full news-card compositions for Discord: daily bulletin, rolling
  digest, daily-challenge blast and match victory. Each function
  returns a standalone SVG string sized in CSS pixels, ready for
  `RC.Discord.Render.rasterize/2`.

  These are pure composers -- callers assemble the input maps from the
  bulletin accumulator / relay buckets / daily leaderboard.
  """

  alias RC.Discord.Render.{Assets, GalaxyMap, Style, VpStrip}

  @w 1600

  # ---------------------------------------------------------------
  # Daily bulletin
  # ---------------------------------------------------------------

  @doc """
  data: %{
    instance_name:, day:, date:,
    battles: %{engagements: n, factions: [%{faction:, wins:, losses:}],
               records: [%{name:, faction:, wins:, losses:}]},
    spoils: %{conquests: [%{name:, faction:}],
              bombards: %{systems: [names], buildings: n, population: n},
              pillages: %{raids: n, credits: n, technology: n, ideology: n}},
    game_data:, ownership:, highlights: []
  }
  """
  def bulletin(data) do
    # panel bottoms align: the map panel's height drives the left column
    map_w = 696 - 48
    bottom = 112 + 62 + map_w + 24
    h = bottom + 42

    subtitle =
      ["DAILY BULLETIN", data[:day] && "DAY #{data[:day]}", data[:date]]
      |> Enum.filter(& &1)
      |> Enum.join(" · ")

    legend =
      data[:legend] || [{:conquest, "Conquered"}, {:bombard, "Bombarded"}, {:pillage, "Pillaged"}]

    svg_open(@w, h) <>
      header(data.instance_name, subtitle) <>
      battles_panel(32, 112, 824, 430, data.battles) <>
      spoils_panel(32, 566, 824, bottom - 566, data.spoils) <>
      map_panel(880, 112, 696, data, legend) <>
      brand(h) <>
      "</svg>"
  end

  defp battles_panel(x, y, w, h, battles) do
    total = max(battles.engagements, 1)
    bar_x = x + 24
    bar_w = w - 48
    bar_y = y + 66
    sorted = Enum.sort_by(battles.factions, & &1.wins, :desc)
    # with exactly two factions a W/L recap is redundant (one side's win
    # is the other's loss) -- the in-segment chips carry identity
    multi? = length(sorted) > 2

    segments =
      sorted
      |> Enum.reduce({[], bar_x * 1.0}, fn f, {acc, cx} ->
        seg_w = bar_w * f.wins / total
        color = Style.faction_color(f.faction)
        pct = round(100 * f.wins / total)

        label =
          cond do
            seg_w > 170 ->
              Style.faction_chip(f.faction, cx + 22, bar_y + 20, 26) <>
                ~s{<text x="#{Style.fnum(cx + 42)}" y="#{bar_y + 26}" font-family="#{Style.font_body()}" font-weight="800" font-size="17" fill="#0e1013">#{f.wins} WINS · #{pct}%</text>}

            seg_w > 64 ->
              Style.faction_chip(f.faction, cx + 22, bar_y + 20, 26) <>
                ~s{<text x="#{Style.fnum(cx + 42)}" y="#{bar_y + 26}" font-family="#{Style.font_body()}" font-weight="800" font-size="17" fill="#0e1013">#{f.wins}</text>}

            seg_w > 30 ->
              Style.faction_chip(f.faction, cx + seg_w / 2, bar_y + 20, 24)

            true ->
              ""
          end

        seg =
          ~s{<rect x="#{Style.fnum(cx)}" y="#{bar_y}" width="#{Style.fnum(seg_w)}" height="40" fill="#{color}"/>} <>
            label

        {[acc, seg], cx + seg_w}
      end)
      |> elem(0)
      |> IO.iodata_to_binary()

    faction_line =
      if multi? do
        step = bar_w / length(sorted)

        sorted
        |> Enum.with_index()
        |> Enum.map(fn {f, i} ->
          fx = bar_x + i * step

          Style.faction_chip(f.faction, fx + 12, bar_y + 64, 24) <>
            ~s{<text x="#{Style.fnum(fx + 30)}" y="#{bar_y + 69}" font-family="#{Style.font_body()}" font-weight="800" font-size="14" fill="#{Style.lighten(Style.faction_color(f.faction), 18)}">#{Style.escape(String.upcase(Style.faction_short_name(f.faction)))} #{f.wins}–#{f.losses}</text>}
        end)
        |> IO.iodata_to_binary()
      else
        ""
      end

    sub_y = bar_y + if(multi?, do: 96, else: 64)
    records = battles.records
    grid? = length(records) > 8

    {shown, capacity} =
      if grid? do
        cols = if length(records) > 16, do: 3, else: 2
        rows = div(y + h - 14 - (sub_y + 24), 28)
        {Enum.take(records, cols * rows), cols * rows}
      else
        {records, 8}
      end

    shown_note =
      if length(records) > capacity,
        do: " — SHOWING #{length(shown)} OF #{length(records)}",
        else: ""

    subheader =
      ~s{<text x="#{bar_x}" y="#{sub_y}" font-family="#{Style.font_title()}" font-weight="700" font-size="13" letter-spacing="2" fill="rgba(230,230,230,0.55)">TOP COMMANDERS#{shown_note}</text>}

    body = if grid?, do: records_grid(shown, bar_x, sub_y, w - 48), else: records_list(shown, bar_x, sub_y, x, w)

    Style.panel(x, y, w, h, "Battles — #{battles.engagements} engagements") <>
      segments <> faction_line <> subheader <> body
  end

  # roomy single-column list for small rosters: one dot per battle
  defp records_list(records, bar_x, sub_y, x, w) do
    records
    |> Enum.with_index()
    |> Enum.map(fn {r, i} ->
      ry = sub_y + 24 + i * 34

      pips =
        (List.duplicate(:w, r.wins) ++ List.duplicate(:l, r.losses))
        |> Enum.take(10)
        |> Enum.with_index()
        |> Enum.map(fn {kind, pi} ->
          px = bar_x + 300 + pi * 24

          case kind do
            :w ->
              ~s{<circle cx="#{px}" cy="#{ry - 5}" r="7" fill="#{Style.faction_color(r.faction)}"/>}

            :l ->
              ~s{<circle cx="#{px}" cy="#{ry - 5}" r="6" fill="none" stroke="rgba(230,230,230,0.4)" stroke-width="1.5"/>}
          end
        end)
        |> IO.iodata_to_binary()

      Style.faction_chip(r.faction, bar_x + 12, ry - 5, 22) <>
        ~s{<text x="#{bar_x + 32}" y="#{ry}" font-family="#{Style.font_body()}" font-weight="800" font-size="16" fill="#{Style.white()}">#{Style.escape(r.name)}</text>} <>
        pips <>
        ~s{<text x="#{x + w - 24}" y="#{ry}" text-anchor="end" font-family="#{Style.font_body()}" font-weight="800" font-size="16" fill="rgba(230,230,230,0.8)">#{r.wins}–#{r.losses}</text>}
    end)
    |> IO.iodata_to_binary()
  end

  # dense multi-column grid for large rosters: tally-style pips where a
  # numbered pill stands for a group of five battles
  defp records_grid(records, gx, sub_y, gw) do
    cols = if length(records) > 16, do: 3, else: 2
    cell_w = gw / cols

    records
    |> Enum.with_index()
    |> Enum.map(fn {r, i} ->
      col = rem(i, cols)
      row = div(i, cols)
      cx = gx + col * cell_w
      ry = sub_y + 24 + row * 28

      Style.faction_chip(r.faction, cx + 9, ry - 5, 18) <>
        ~s{<text x="#{Style.fnum(cx + 24)}" y="#{ry}" font-family="#{Style.font_body()}" font-weight="800" font-size="13.5" fill="#{Style.white()}">#{Style.escape(truncate(r.name, 11))}</text>} <>
        compressed_pips(
          r.wins,
          r.losses,
          cx + 118,
          ry - 5,
          Style.faction_color(r.faction),
          if(cols == 3, do: 6, else: 8)
        ) <>
        ~s{<text x="#{Style.fnum(cx + cell_w - 14)}" y="#{ry}" text-anchor="end" font-family="#{Style.font_body()}" font-weight="800" font-size="13" fill="rgba(230,230,230,0.75)">#{r.wins}–#{r.losses}</text>}
    end)
    |> IO.iodata_to_binary()
  end

  # a filled pill marked "5" = five wins; outlined pill = five losses;
  # leftover battles render as single dots
  defp compressed_pips(wins, losses, px, cy, color, max_glyphs) do
    glyphs =
      List.duplicate({:pill, :win}, div(wins, 5)) ++
        List.duplicate({:dot, :win}, rem(wins, 5)) ++
        List.duplicate({:pill, :loss}, div(losses, 5)) ++
        List.duplicate({:dot, :loss}, rem(losses, 5))

    glyphs
    |> Enum.take(max_glyphs)
    |> Enum.reduce({[], px}, fn glyph, {acc, gx} ->
      {frag, advance} =
        case glyph do
          {:pill, :win} ->
            {~s{<rect x="#{Style.fnum(gx)}" y="#{cy - 8}" width="19" height="16" rx="8" fill="#{color}"/>} <>
               ~s{<text x="#{Style.fnum(gx + 9.5)}" y="#{cy + 4.5}" text-anchor="middle" font-family="#{Style.font_body()}" font-weight="800" font-size="12" fill="#0e1013">5</text>},
             23}

          {:pill, :loss} ->
            {~s{<rect x="#{Style.fnum(gx)}" y="#{cy - 8}" width="19" height="16" rx="8" fill="none" stroke="rgba(230,230,230,0.45)" stroke-width="1.5"/>} <>
               ~s{<text x="#{Style.fnum(gx + 9.5)}" y="#{cy + 4.5}" text-anchor="middle" font-family="#{Style.font_body()}" font-weight="800" font-size="12" fill="rgba(230,230,230,0.6)">5</text>},
             23}

          {:dot, :win} ->
            {~s{<circle cx="#{Style.fnum(gx + 5)}" cy="#{cy}" r="5" fill="#{color}"/>}, 13}

          {:dot, :loss} ->
            {~s{<circle cx="#{Style.fnum(gx + 4.5)}" cy="#{cy}" r="4.5" fill="none" stroke="rgba(230,230,230,0.4)" stroke-width="1.4"/>},
             13}
        end

      {[acc, frag], gx + advance}
    end)
    |> elem(0)
    |> IO.iodata_to_binary()
  end

  # Target lists name only non-neutral victims (the caller filters by
  # victim_faction) and cap at 8 names with a "+N more" tail. A nil
  # names list means the vague multifaction tier: totals only, no
  # system names. A damage/loot detail that sums to zero is omitted
  # rather than shown as a false zero (pre-enrichment event rows).
  @spoils_name_cap 8

  defp spoils_panel(x, y, w, h, spoils) do
    rows = [
      {:conquest, "CONQUESTS",
       case spoils.conquests do
         %{count: 0} ->
           {"none", nil, nil}

         %{count: n, names: names} ->
           {"#{n} systems taken", nil, names && capped_names(names)}
       end},
      {:bombard, "BOMBARDS",
       case spoils.bombards do
         %{count: 0} ->
           {"none", nil, nil}

         %{count: _n, systems: k, names: names, buildings: b, population: p} ->
           detail =
             if b + p > 0,
               do: "#{Style.int(b)} buildings damaged · ≈#{Style.int(p)} population lost"

           {"#{k} system#{if k == 1, do: "", else: "s"} shelled", detail, names && capped_names(names)}
       end},
      {:pillage, "PILLAGES",
       case spoils.pillages do
         %{count: 0} ->
           {"none", nil, nil}

         %{count: n, names: names, credits: c, technology: t, ideology: i} ->
           detail =
             if c + t + i > 0,
               do: "#{Style.int(c)} credits · #{Style.int(t)} technology · #{Style.int(i)} ideology looted"

           targets =
             names &&
               Enum.map(names, fn %{name: name, count: count} ->
                 if count > 1, do: "#{name} ×#{count}", else: name
               end)

           {"#{n} raid#{if n == 1, do: "", else: "s"}", detail, targets && capped_names(targets)}
       end}
    ]

    body =
      rows
      |> Enum.with_index()
      |> Enum.map(fn {{kind, label, {headline, detail, targets}}, i} ->
        ry = y + 88 + i * 72

        icon =
          case kind do
            :conquest ->
              ~s{<polygon points="#{Style.star_points(x + 40, ry - 6, 12)}" fill="rgba(230,230,230,0.7)"/>}

            :bombard ->
              legend_burst(x + 40, ry - 6, 12, "#ff832e")

            :pillage ->
              ~s{<rect x="#{x + 31}" y="#{ry - 15}" width="18" height="18" transform="rotate(45 #{x + 40} #{ry - 6})" fill="none" stroke="#ffd166" stroke-width="2.4"/>}
          end

        head =
          ~s{<text x="#{x + 70}" y="#{ry - 4}" font-family="#{Style.font_body()}" font-weight="800" font-size="17" fill="#{Style.white()}">#{label} <tspan fill="rgba(230,230,230,0.65)" font-weight="400">— #{Style.escape(headline)}</tspan></text>}

        detail_line =
          if detail do
            ~s{<text x="#{x + 70}" y="#{ry + 18}" font-family="#{Style.font_body()}" font-size="14.5" fill="rgba(230,230,230,0.6)">#{Style.escape(truncate(detail, 96))}</text>}
          else
            ""
          end

        target_line =
          if targets do
            ty = if detail, do: ry + 38, else: ry + 18

            ~s{<text x="#{x + 70}" y="#{ty}" font-family="#{Style.font_body()}" font-size="14.5" fill="rgba(230,230,230,0.45)">#{Style.escape(truncate(targets, 96))}</text>}
          else
            ""
          end

        icon <> head <> detail_line <> target_line
      end)
      |> IO.iodata_to_binary()

    Style.panel(x, y, w, h, "Spoils of war") <> body
  end

  defp capped_names(names) do
    case Enum.split(names, @spoils_name_cap) do
      {shown, []} -> Enum.join(shown, ", ")
      {shown, rest} -> Enum.join(shown, ", ") <> " +#{length(rest)} more"
    end
  end

  # ---------------------------------------------------------------
  # Rolling digest
  # ---------------------------------------------------------------

  @doc """
  data: %{
    instance_name:, window_label:, day:,
    game_data:, ownership:, highlights: [], legend: [{kind, label}],
    territory: [%{faction:, entries: [%{sign: :+|:-, text:}]}],
    vp: %{win_target:, rows: [%{faction:, vp:, gained:, lost:}]},
    totals: [%{faction:, systems:, dominions:}]
  }

  Up to three factions: big square map left, territory+control and the
  VP track stacked right, all bottoms aligned. Four or five factions
  need more horizontal room for the track, so the layout switches to
  map + territory side by side with a full-width VP panel below.
  """
  def digest(data) do
    n = length(data.vp.rows)
    vp_h = 58 + VpStrip.height(n) + 8
    map_opts = [highlights: data.highlights, legend: data[:legend] || []]

    if n <= 3 do
      h = 1000
      map_bottom = 112 + 856
      vp_y = map_bottom - vp_h

      svg_open(@w, h) <>
        header(data.instance_name, data.window_label) <>
        GalaxyMap.render_nested(data.game_data, data.ownership, 24, 112, 856, map_opts) <>
        territory_panel(904, 112, 672, vp_y - 136, data.territory, data.totals) <>
        vp_panel(904, vp_y, 672, vp_h, data.vp) <>
        brand(h) <>
        "</svg>"
    else
      map_w = 664
      row1_bottom = 112 + map_w
      vp_y = row1_bottom + 24
      h = vp_y + vp_h + 40

      svg_open(@w, h) <>
        header(data.instance_name, data.window_label) <>
        GalaxyMap.render_nested(data.game_data, data.ownership, 24, 112, map_w, map_opts) <>
        territory_panel(712, 112, 864, map_w, data.territory, data.totals) <>
        vp_panel(24, vp_y, 1552, vp_h, data.vp) <>
        brand(h) <>
        "</svg>"
    end
  end

  @doc """
  The Legacy #news 6-hour digest: territory changes only — map plus
  the territory/control panel, no victory track (Legacy already gets
  VP movement from the 5-minute roll-ups). Same data shape as
  `digest/1` minus `:vp`.
  """
  def digest_territory(data) do
    h = 1000
    map_opts = [highlights: data.highlights, legend: data[:legend] || []]

    svg_open(@w, h) <>
      header(data.instance_name, data.window_label) <>
      GalaxyMap.render_nested(data.game_data, data.ownership, 24, 112, 856, map_opts) <>
      territory_panel(904, 112, 672, 856, data.territory, data.totals) <>
      brand(h) <>
      "</svg>"
  end

  # Territory changes with the current-control recap anchored at the
  # panel's bottom edge.
  defp territory_panel(x, y, w, h, groups, totals) do
    body =
      groups
      |> Enum.reduce({[], y + 84}, fn group, {acc, gy} ->
        color = Style.faction_color(group.faction)

        head =
          Style.faction_chip(group.faction, x + 34, gy - 6, 30) <>
            ~s{<text x="#{x + 58}" y="#{gy}" font-family="#{Style.font_body()}" font-weight="800" font-size="17" fill="#{Style.lighten(color, 18)}">#{Style.escape(String.upcase(Style.faction_name(group.faction)))}</text>}

        entries =
          group.entries
          |> Enum.with_index()
          |> Enum.map(fn {e, i} ->
            ey = gy + 30 + i * 28

            {sign, sign_color} =
              case e.sign do
                :+ -> {"+", "#7ee787"}
                :- -> {"−", "#ff7b72"}
              end

            ~s{<text x="#{x + 40}" y="#{ey}" font-family="#{Style.font_body()}" font-weight="800" font-size="17" fill="#{sign_color}">#{sign}</text>} <>
              ~s{<text x="#{x + 62}" y="#{ey}" font-family="#{Style.font_body()}" font-size="16" fill="rgba(230,230,230,0.85)">#{Style.escape(e.text)}</text>}
          end)
          |> IO.iodata_to_binary()

        {[acc, head, entries], gy + 30 + length(group.entries) * 28 + 18}
      end)
      |> elem(0)
      |> IO.iodata_to_binary()

    control_top = y + h - 64 - length(totals) * 30

    control =
      ~s{<line x1="#{x + 18}" y1="#{control_top}" x2="#{x + w - 18}" y2="#{control_top}" stroke="rgba(255,255,255,0.12)" stroke-width="1"/>} <>
        ~s{<text x="#{x + 18}" y="#{control_top + 28}" font-family="#{Style.font_title()}" font-weight="700" font-size="13" letter-spacing="2" fill="rgba(230,230,230,0.55)">CURRENT CONTROL</text>} <>
        (totals
         |> Enum.with_index()
         |> Enum.map(fn {t, i} ->
           ty = control_top + 56 + i * 30

           Style.faction_chip(t.faction, x + 34, ty - 6, 24) <>
             ~s{<text x="#{x + 56}" y="#{ty}" font-family="#{Style.font_body()}" font-size="15" fill="rgba(230,230,230,0.85)"><tspan font-weight="800" fill="#{Style.lighten(Style.faction_color(t.faction), 18)}">#{Style.escape(Style.faction_name(t.faction))}</tspan>  #{t.systems} systems · #{t.dominions} dominions</text>}
         end)
         |> IO.iodata_to_binary())

    Style.panel(x, y, w, h, "Territory changes") <> body <> control
  end

  defp vp_panel(x, y, w, h, vp) do
    Style.panel(x, y, w, h, "Victory track — first to #{vp.win_target}") <>
      VpStrip.render(vp.rows, x + 12, y + 58, w - 24, vp.win_target)
  end

  # ---------------------------------------------------------------
  # Daily challenge
  # ---------------------------------------------------------------

  @doc """
  data: %{
    date:, challenge_name:, winners: [%{rank:, name:, score:}],
    next: %{name:, description:, mutators: [%{polarity:, name:}]}
  }
  """
  def daily(data) do
    h = 900

    svg_open(@w, h) <>
      header("DAILY CHALLENGE", "#{data.date} · RESETS 07:00 UTC") <>
      podium_panel(32, 112, 760, 752, data.challenge_name, data.winners) <>
      next_panel(824, 112, 744, 420, data.next) <>
      daily_cta_panel(824, 556, 744, 308) <>
      brand(h, "tetrarchyfalls.com/play/daily") <>
      "</svg>"
  end

  defp podium_panel(x, y, w, h, challenge_name, winners) do
    title =
      ~s{<text x="#{x + w / 2}" y="#{y + 64}" text-anchor="middle" font-family="#{Style.font_title()}" font-weight="700" font-size="30" fill="#{Style.white()}">#{Style.escape(challenge_name)}</text>} <>
        ~s{<text x="#{x + w / 2}" y="#{y + 94}" text-anchor="middle" font-family="#{Style.font_body()}" font-size="15" letter-spacing="3" fill="rgba(230,230,230,0.55)">FINAL RESULTS</text>}

    medal_colors = %{1 => "#e3b341", 2 => "#b8c0cc", 3 => "#c98a52"}
    # podium order: 2nd left, 1st middle, 3rd right
    slots = %{1 => {x + w / 2, 420}, 2 => {x + w / 2 - 236, 320}, 3 => {x + w / 2 + 236, 255}}
    base_y = y + h - 60

    blocks =
      winners
      |> Enum.filter(&Map.has_key?(slots, &1.rank))
      |> Enum.map(fn wn ->
        {cx, block_h} = slots[wn.rank]
        color = medal_colors[wn.rank]
        by = base_y - block_h

        block =
          ~s{<rect x="#{Style.fnum(cx - 105)}" y="#{by}" width="210" height="#{block_h}" rx="6" fill="rgba(255,255,255,0.06)" stroke="rgba(255,255,255,0.12)"/>} <>
            ~s{<rect x="#{Style.fnum(cx - 105)}" y="#{by}" width="210" height="6" rx="3" fill="#{color}"/>}

        medal =
          ~s{<circle cx="#{Style.fnum(cx)}" cy="#{by - 74}" r="30" fill="#{color}"/>} <>
            ~s{<circle cx="#{Style.fnum(cx)}" cy="#{by - 74}" r="30" fill="none" stroke="rgba(0,0,0,0.3)" stroke-width="3"/>} <>
            ~s{<text x="#{Style.fnum(cx)}" y="#{by - 63}" text-anchor="middle" font-family="#{Style.font_title()}" font-weight="700" font-size="30" fill="#0e1013">#{wn.rank}</text>}

        name =
          ~s{<text x="#{Style.fnum(cx)}" y="#{by - 22}" text-anchor="middle" font-family="#{Style.font_body()}" font-weight="800" font-size="24" fill="#{Style.white()}">#{Style.escape(wn.name)}</text>}

        score =
          ~s{<text x="#{Style.fnum(cx)}" y="#{by + 40}" text-anchor="middle" font-family="#{Style.font_body()}" font-weight="800" font-size="19" fill="#{color}">#{Style.escape(wn.score)}</text>}

        block <> medal <> name <> score
      end)
      |> IO.iodata_to_binary()

    base =
      ~s{<line x1="#{x + 40}" y1="#{base_y}" x2="#{x + w - 40}" y2="#{base_y}" stroke="rgba(255,255,255,0.18)" stroke-width="2"/>}

    Style.panel(x, y, w, h) <> title <> blocks <> base
  end

  defp next_panel(x, y, w, h, next) do
    name =
      ~s{<text x="#{x + 24}" y="#{y + 96}" font-family="#{Style.font_title()}" font-weight="700" font-size="26" fill="#{Style.white()}">#{Style.escape(next.name)}</text>}

    desc_lines =
      next.description
      |> Style.wrap_text(17, w - 48)
      |> Enum.with_index()
      |> Enum.map(fn {line, i} ->
        ~s{<text x="#{x + 24}" y="#{y + 132 + i * 26}" font-family="#{Style.font_body()}" font-size="17" fill="rgba(230,230,230,0.75)">#{Style.escape(line)}</text>}
      end)
      |> IO.iodata_to_binary()

    chip_y = y + h - 64

    chips =
      next.mutators
      |> Enum.reduce({[], x + 24}, fn m, {acc, cx} ->
        {sign, color} =
          case m.polarity do
            :positive -> {"+", "#7ee787"}
            _ -> {"−", "#ff7b72"}
          end

        text = "#{sign} #{m.name}"
        chip_w = String.length(text) * 9.6 + 30

        chip =
          ~s{<rect x="#{Style.fnum(cx)}" y="#{chip_y - 24}" width="#{Style.fnum(chip_w)}" height="36" rx="18" fill="none" stroke="#{color}" stroke-opacity="0.6" stroke-width="1.5"/>} <>
            ~s{<text x="#{Style.fnum(cx + chip_w / 2)}" y="#{chip_y}" text-anchor="middle" font-family="#{Style.font_body()}" font-weight="800" font-size="16" fill="#{color}">#{Style.escape(text)}</text>}

        {[acc, chip], cx + chip_w + 14}
      end)
      |> elem(0)
      |> IO.iodata_to_binary()

    mutator_label =
      ~s{<text x="#{x + 24}" y="#{chip_y - 44}" font-family="#{Style.font_title()}" font-weight="700" font-size="13" letter-spacing="2" fill="rgba(230,230,230,0.55)">MUTATORS</text>}

    Style.panel(x, y, w, h, "Up next") <> name <> desc_lines <> mutator_label <> chips
  end

  defp daily_cta_panel(x, y, w, h) do
    logo = Assets.logo_simple()
    [_, _, vw, _] = String.split(logo.viewbox, " ")
    scale = 120 / String.to_integer(vw)

    ~s{<rect x="#{x}" y="#{y}" width="#{w}" height="#{h}" rx="6" fill="rgba(255,255,255,0.03)" stroke="rgba(255,255,255,0.08)"/>} <>
      ~s{<g transform="translate(#{x + w / 2 - 60},#{y + 40}) scale(#{Style.fnum(scale)})" fill="rgba(230,230,230,0.85)">#{logo.body}</g>} <>
      ~s{<text x="#{x + w / 2}" y="#{y + 205}" text-anchor="middle" font-family="#{Style.font_body()}" font-weight="800" font-size="20" fill="#{Style.white()}">A new challenge is live now</text>} <>
      ~s{<text x="#{x + w / 2}" y="#{y + 238}" text-anchor="middle" font-family="#{Style.font_body()}" font-size="16" fill="rgba(230,230,230,0.6)">one run per day · everyone gets the same galaxy</text>}
  end

  # ---------------------------------------------------------------
  # Victory
  # ---------------------------------------------------------------

  @doc """
  data: %{
    instance_name:, winner:, day:, victory_type_label:,
    vp: %{win_target:, rows:}, totals: [%{faction:, systems:, dominions:, players:}]
  }
  """
  def victory(data) do
    h = 900
    color = Style.faction_color(data.winner)
    icons = Assets.faction_large()
    icon = Map.get(icons, Style.safe_faction_key(data.winner))

    logo =
      case icon do
        %{viewbox: vb, body: body} ->
          [_, _, vw, _] = String.split(vb, " ")
          inner = 150.0
          scale = inner / String.to_integer(vw)

          ~s{<circle cx="800" cy="220" r="108" fill="#{color}"/>} <>
            ~s{<circle cx="800" cy="220" r="108" fill="none" stroke="#e3b341" stroke-width="5"/>} <>
            ~s{<circle cx="800" cy="220" r="122" fill="none" stroke="#e3b341" stroke-opacity="0.35" stroke-width="2"/>} <>
            ~s{<g transform="translate(#{Style.fnum(800 - inner / 2)},#{Style.fnum(220 - inner / 2)}) scale(#{Style.fnum(scale)})" fill="#0e1013">#{body}</g>}

        _ ->
          ""
      end

    title =
      ~s{<text x="800" y="418" text-anchor="middle" font-family="#{Style.font_title()}" font-weight="700" font-size="46" letter-spacing="3" fill="#{Style.lighten(color, 20)}">#{Style.escape(String.upcase(Style.faction_name(data.winner)))} CONQUERS THE GALAXY</text>}

    sub_text =
      [data.instance_name, data.victory_type_label, data[:day] && "day #{data[:day]}"]
      |> Enum.filter(& &1)
      |> Enum.join(" · ")

    sub =
      ~s{<text x="800" y="458" text-anchor="middle" font-family="#{Style.font_body()}" font-size="19" fill="rgba(230,230,230,0.7)">#{Style.escape(sub_text)}</text>}

    standings =
      Style.panel(320, 500, 960, 130 + length(data.vp.rows) * 54, "Final standings") <>
        VpStrip.render(data.vp.rows, 340, 558, 920, data.vp.win_target)

    totals_y = 500 + 130 + length(data.vp.rows) * 54 + 40

    totals =
      data.totals
      |> Enum.with_index()
      |> Enum.map(fn {t, i} ->
        ty = totals_y + i * 30

        ~s{<text x="800" y="#{ty}" text-anchor="middle" font-family="#{Style.font_body()}" font-size="16" fill="rgba(230,230,230,0.65)"><tspan font-weight="800" fill="#{Style.lighten(Style.faction_color(t.faction), 15)}">#{Style.escape(Style.faction_name(t.faction))}</tspan> — #{t.systems} systems · #{t.dominions} dominions · #{t.players} players</text>}
      end)
      |> IO.iodata_to_binary()

    svg_open(@w, h) <>
      header(data.instance_name, "MATCH CONCLUDED") <>
      logo <>
      title <>
      sub <>
      standings <>
      totals <>
      brand(h) <>
      "</svg>"
  end

  # ---------------------------------------------------------------
  # Player profile (/player command)
  # ---------------------------------------------------------------

  @doc """
  data: %{
    name:, full_name:, description:,
    avatar_jpeg: jpeg_binary | nil,
    favorite_faction: "cardan" | nil,
    favorite_icon: "ship/frigate_1" | nil,
    stats: %{
      legacy: %{wins:, participations:},
      daily: %{gold:, silver:, bronze:, completed:, played:},
      factions: %{"faction_ref" => count}
    }
  }

  Opt-in public snapshot — game stats and flavor only, never account
  fields (the assembler, RC.Discord.PlayerCard, enforces that).

  Unlike the 1600px-wide news cards, this one is near-square (1080×1028):
  Discord's image containers on mobile — and its desktop embeds — favor
  square media, and a 2.7:1 banner arrives as a thin cropped strip.
  """
  @player_card_w 1080

  @doc "Natural pixel width of the /player card — rasterize at this width."
  def player_card_width, do: @player_card_w

  def player_profile(data) do
    w = @player_card_w
    h = 1028
    faction_color = Style.faction_color(data.favorite_faction)

    accent =
      if data.favorite_faction,
        do: ~s{<rect width="#{w}" height="4" fill="#{faction_color}"/>},
        else: ""

    svg_open(w, h) <>
      accent <>
      header(data.name, "PLAYER PROFILE", w) <>
      operative_panel(32, 112, w - 64, 300, data, faction_color) <>
      legacy_panel(32, 436, 492, 280, data.stats.legacy) <>
      daily_medals_panel(556, 436, 492, 280, data.stats.daily) <>
      factions_panel(32, 740, w - 64, 240, data.stats.factions) <>
      brand(h, "tetrarchyfalls.com", w) <>
      "</svg>"
  end

  # Identity block: portrait left (the avatars are 2:1 landscape art),
  # name/maxim/allegiance in a text column to its right.
  defp operative_panel(x, y, w, h, data, faction_color) do
    img_x = x + 24
    img_y = y + 24
    img_w = 480
    img_h = div(img_w, 2)
    text_x = img_x + img_w + 24
    text_w = x + w - 24 - text_x

    portrait =
      case data.avatar_jpeg do
        jpeg when is_binary(jpeg) ->
          ~s{<defs><clipPath id="avclip"><rect x="#{img_x}" y="#{img_y}" width="#{img_w}" height="#{img_h}" rx="6"/></clipPath></defs>} <>
            ~s{<image x="#{img_x}" y="#{img_y}" width="#{img_w}" height="#{img_h}" href="data:image/jpeg;base64,#{Base.encode64(jpeg)}" preserveAspectRatio="xMidYMid slice" clip-path="url(#avclip)"/>} <>
            ~s{<rect x="#{img_x}" y="#{img_y}" width="#{img_w}" height="#{img_h}" rx="6" fill="none" stroke="rgba(255,255,255,0.18)" stroke-width="1"/>}

        _ ->
          initial = data.name |> String.slice(0, 1) |> String.upcase()

          ~s{<rect x="#{img_x}" y="#{img_y}" width="#{img_w}" height="#{img_h}" rx="6" fill="rgba(255,255,255,0.04)" stroke="rgba(255,255,255,0.14)"/>} <>
            ~s{<text x="#{img_x + img_w / 2}" y="#{img_y + img_h / 2 + 34}" text-anchor="middle" font-family="#{Style.font_title()}" font-weight="700" font-size="96" fill="rgba(230,230,230,0.25)">#{Style.escape(initial)}</text>}
      end

    # The favorite icon rides the portrait's bottom-right corner,
    # tinted in the favorite faction's color.
    badge = favorite_icon_badge(data.favorite_icon, faction_color, img_x + img_w - 44, img_y + img_h - 12, 36)

    full_name =
      case data.full_name do
        name when is_binary(name) and name != "" ->
          name
          |> Style.wrap_text(24, text_w)
          |> Enum.take(2)
          |> Enum.with_index()
          |> Enum.map(fn {line, i} ->
            ~s{<text x="#{text_x}" y="#{y + 78 + i * 32}" font-family="#{Style.font_title()}" font-weight="700" font-size="24" fill="#{Style.white()}">#{Style.escape(line)}</text>}
          end)
          |> IO.iodata_to_binary()

        _ ->
          ""
      end

    maxim =
      case data.description do
        desc when is_binary(desc) and desc != "" ->
          desc
          |> Style.wrap_text(16, text_w)
          |> Enum.take(4)
          |> Enum.with_index()
          |> Enum.map(fn {line, i} ->
            ~s{<text x="#{text_x}" y="#{y + 146 + i * 24}" font-family="#{Style.font_body()}" font-style="italic" font-size="16" fill="rgba(230,230,230,0.6)">#{Style.escape(line)}</text>}
          end)
          |> IO.iodata_to_binary()

        _ ->
          ""
      end

    allegiance =
      if data.favorite_faction do
        Style.faction_chip(data.favorite_faction, text_x + 13, y + h - 34, 26) <>
          ~s{<text x="#{text_x + 34}" y="#{y + h - 28}" font-family="#{Style.font_body()}" font-weight="800" font-size="15" fill="#{Style.lighten(faction_color, 15)}">Favors the #{Style.escape(Style.faction_name(data.favorite_faction))}</text>}
      else
        ""
      end

    Style.panel(x, y, w, h) <> portrait <> badge <> full_name <> maxim <> allegiance
  end

  defp favorite_icon_badge(nil, _color, _cx, _cy, _r), do: ""

  defp favorite_icon_badge(icon_name, color, cx, cy, r) do
    case RC.ProfileIcons.svg(icon_name) do
      nil ->
        ""

      %{viewbox: viewbox, body: body} ->
        vw =
          case String.split(viewbox, " ") do
            [_, _, vw, _] ->
              case Float.parse(vw) do
                {n, _} -> n
                :error -> 32.0
              end

            _ ->
              32.0
          end

        inner = r * 1.1
        scale = inner / vw
        tx = cx - inner / 2
        ty = cy - inner / 2

        ~s{<circle cx="#{cx}" cy="#{cy}" r="#{r}" fill="#0e1013" stroke="#{color}" stroke-width="3"/>} <>
          ~s{<g transform="translate(#{Style.fnum(tx)},#{Style.fnum(ty)}) scale(#{Style.fnum(scale)})" fill="#{color}" color="#{color}">#{body}</g>}
    end
  end

  defp legacy_panel(x, y, w, h, legacy) do
    cx = x + w / 2

    Style.panel(x, y, w, h, "Official Legacy") <>
      ~s{<text x="#{Style.fnum(cx)}" y="#{y + 176}" text-anchor="middle" font-family="#{Style.font_title()}" font-weight="700" font-size="84" fill="#{Style.white()}">#{Style.int(legacy.wins)}</text>} <>
      ~s{<text x="#{Style.fnum(cx)}" y="#{y + 212}" text-anchor="middle" font-family="#{Style.font_body()}" font-weight="800" font-size="16" letter-spacing="4" fill="rgba(230,230,230,0.55)">WINS</text>} <>
      ~s{<line x1="#{x + 60}" y1="#{y + 236}" x2="#{x + w - 60}" y2="#{y + 236}" stroke="rgba(255,255,255,0.12)" stroke-width="1"/>} <>
      ~s{<text x="#{Style.fnum(cx)}" y="#{y + 266}" text-anchor="middle" font-family="#{Style.font_body()}" font-size="17" fill="rgba(230,230,230,0.75)">#{Style.int(legacy.participations)} official matches entered</text>}
  end

  # Three medal columns (gold/silver/bronze) side by side, tally
  # underneath — reads better than stacked rows in a wide-short panel.
  defp daily_medals_panel(x, y, w, h, daily) do
    medals = [
      {"#e3b341", "GOLD", daily.gold, 0},
      {"#b8c0cc", "SILVER", daily.silver, 1},
      {"#c98a52", "BRONZE", daily.bronze, 2}
    ]

    columns =
      medals
      |> Enum.map(fn {color, label, count, i} ->
        mcx = x + w * (i + 1) / 4
        mcy = y + 128
        dim = if count == 0, do: ~s{ opacity="0.35"}, else: ""

        ~s{<g#{dim}>} <>
          ~s{<circle cx="#{Style.fnum(mcx)}" cy="#{mcy}" r="22" fill="#{color}"/>} <>
          ~s{<circle cx="#{Style.fnum(mcx)}" cy="#{mcy}" r="22" fill="none" stroke="rgba(0,0,0,0.3)" stroke-width="2.5"/>} <>
          ~s{<polygon points="#{Style.star_points(mcx, mcy, 11)}" fill="rgba(0,0,0,0.35)"/>} <>
          ~s{<text x="#{Style.fnum(mcx)}" y="#{mcy + 64}" text-anchor="middle" font-family="#{Style.font_title()}" font-weight="700" font-size="32" fill="#{Style.white()}">#{Style.int(count)}</text>} <>
          ~s{<text x="#{Style.fnum(mcx)}" y="#{mcy + 88}" text-anchor="middle" font-family="#{Style.font_body()}" font-weight="800" font-size="12" letter-spacing="2" fill="rgba(230,230,230,0.5)">#{label}</text>} <>
          "</g>"
      end)
      |> IO.iodata_to_binary()

    footer =
      ~s{<line x1="#{x + 24}" y1="#{y + 240}" x2="#{x + w - 24}" y2="#{y + 240}" stroke="rgba(255,255,255,0.12)" stroke-width="1"/>} <>
        ~s{<text x="#{Style.fnum(x + w / 2)}" y="#{y + 268}" text-anchor="middle" font-family="#{Style.font_body()}" font-size="16" fill="rgba(230,230,230,0.75)">#{Style.int(daily.completed)} completed of #{Style.int(daily.played)} played</text>}

    Style.panel(x, y, w, h, "Daily Challenges") <> columns <> footer
  end

  # One column per faction across the full card width.
  defp factions_panel(x, y, w, h, faction_counts) do
    factions = RC.ProfileIcons.faction_keys()

    columns =
      factions
      |> Enum.with_index()
      |> Enum.map(fn {faction, i} ->
        fcx = x + w * (i + 0.5) / length(factions)
        count = Map.get(faction_counts, faction, 0)
        dim = if count == 0, do: ~s{ opacity="0.35"}, else: ""

        ~s{<g#{dim}>} <>
          Style.faction_chip(faction, fcx, y + 108, 44) <>
          ~s{<text x="#{Style.fnum(fcx)}" y="#{y + 168}" text-anchor="middle" font-family="#{Style.font_title()}" font-weight="700" font-size="28" fill="#{Style.white()}">#{Style.int(count)}</text>} <>
          ~s{<text x="#{Style.fnum(fcx)}" y="#{y + 194}" text-anchor="middle" font-family="#{Style.font_body()}" font-weight="800" font-size="13" fill="rgba(230,230,230,0.7)">#{Style.escape(Style.faction_short_name(faction))}</text>} <>
          "</g>"
      end)
      |> IO.iodata_to_binary()

    footer =
      ~s{<text x="#{Style.fnum(x + w / 2)}" y="#{y + h - 16}" text-anchor="middle" font-family="#{Style.font_body()}" font-size="13" fill="rgba(230,230,230,0.45)">matches, all modes except daily</text>}

    Style.panel(x, y, w, h, "Factions Played") <> columns <> footer
  end

  # ---------------------------------------------------------------
  # Shared chrome
  # ---------------------------------------------------------------

  defp svg_open(w, h) do
    ~s{<?xml version="1.0" encoding="UTF-8"?>} <>
      ~s{<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 #{w} #{h}" width="#{w}" height="#{h}">} <>
      ~s{<rect width="#{w}" height="#{h}" fill="#{Style.card_bg()}"/>} <>
      ~s{<rect width="#{w}" height="4" fill="rgba(255,255,255,0.14)"/>}
  end

  defp header(title, subtitle, w \\ @w) do
    ~s{<text x="32" y="58" font-family="#{Style.font_title()}" font-weight="700" font-size="30" letter-spacing="1" fill="#{Style.white()}">#{Style.escape(String.upcase(title))}</text>} <>
      ~s{<text x="#{w - 32}" y="56" text-anchor="end" font-family="#{Style.font_body()}" font-weight="800" font-size="15" letter-spacing="2" fill="rgba(230,230,230,0.55)">#{Style.escape(subtitle)}</text>} <>
      ~s{<line x1="32" y1="82" x2="#{w - 32}" y2="82" stroke="rgba(255,255,255,0.1)" stroke-width="1"/>}
  end

  defp map_panel(x, y, w, data, legend_entries) do
    map_w = w - 48
    h = 62 + map_w + 24

    map =
      GalaxyMap.render_nested(data.game_data, data.ownership, x + 24, y + 62, map_w,
        highlights: data.highlights,
        legend: legend_entries
      )

    Style.panel(x, y, w, h, "Theatre of operations") <> map
  end

  # floating site URL, bottom-right on every card
  defp brand(h, url \\ "tetrarchyfalls.com", w \\ @w) do
    ~s{<text x="#{w - 32}" y="#{h - 14}" text-anchor="end" font-family="#{Style.font_body()}" font-size="13" letter-spacing="0.5" fill="rgba(230,230,230,0.4)">#{Style.escape(url)}</text>}
  end

  defp legend_burst(cx, cy, r, color) do
    pts =
      0..15
      |> Enum.map(fn i ->
        angle = i * :math.pi() / 8
        rr = if rem(i, 2) == 0, do: r, else: r * 0.4
        "#{Style.fnum(cx + rr * :math.cos(angle))},#{Style.fnum(cy + rr * :math.sin(angle))}"
      end)
      |> Enum.join(" ")

    ~s{<polygon points="#{pts}" fill="none" stroke="#{color}" stroke-width="2.2"/>}
  end

  defp truncate(text, max) do
    if String.length(text) > max, do: String.slice(text, 0, max - 1) <> "…", else: text
  end
end

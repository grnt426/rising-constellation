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
    h = 920

    svg_open(@w, h) <>
      header(data.instance_name, "DAILY BULLETIN · DAY #{data.day} · #{data.date}") <>
      battles_panel(32, 112, 824, 430, data.battles) <>
      spoils_panel(32, 566, 824, 300, data.spoils) <>
      footer_brand(32, h - 26) <>
      map_panel(880, 112, 696, data, [
        {:conquest, "Conquered"},
        {:bombard, "Bombarded"},
        {:pillage, "Pillaged"}
      ]) <>
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

        seg = ~s{<rect x="#{Style.fnum(cx)}" y="#{bar_y}" width="#{Style.fnum(seg_w)}" height="40" fill="#{color}"/>} <> label

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
        compressed_pips(r.wins, r.losses, cx + 118, ry - 5, Style.faction_color(r.faction), if(cols == 3, do: 6, else: 8)) <>
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
               ~s{<text x="#{Style.fnum(gx + 9.5)}" y="#{cy + 4.5}" text-anchor="middle" font-family="#{Style.font_body()}" font-weight="800" font-size="12" fill="#0e1013">5</text>}, 23}

          {:pill, :loss} ->
            {~s{<rect x="#{Style.fnum(gx)}" y="#{cy - 8}" width="19" height="16" rx="8" fill="none" stroke="rgba(230,230,230,0.45)" stroke-width="1.5"/>} <>
               ~s{<text x="#{Style.fnum(gx + 9.5)}" y="#{cy + 4.5}" text-anchor="middle" font-family="#{Style.font_body()}" font-weight="800" font-size="12" fill="rgba(230,230,230,0.6)">5</text>}, 23}

          {:dot, :win} ->
            {~s{<circle cx="#{Style.fnum(gx + 5)}" cy="#{cy}" r="5" fill="#{color}"/>}, 13}

          {:dot, :loss} ->
            {~s{<circle cx="#{Style.fnum(gx + 4.5)}" cy="#{cy}" r="4.5" fill="none" stroke="rgba(230,230,230,0.4)" stroke-width="1.4"/>}, 13}
        end

      {[acc, frag], gx + advance}
    end)
    |> elem(0)
    |> IO.iodata_to_binary()
  end

  # Target lists name only non-neutral victims (the caller filters by
  # victim_faction) and cap at 8 names with a "+N more" tail.
  @spoils_name_cap 8

  defp spoils_panel(x, y, w, h, spoils) do
    rows = [
      {:conquest, "CONQUESTS",
       case spoils.conquests do
         [] -> {"none", nil, nil}
         list -> {"#{length(list)} systems taken", nil, capped_names(Enum.map(list, & &1.name))}
       end},
      {:bombard, "BOMBARDS",
       case spoils.bombards do
         %{systems: []} ->
           {"none", nil, nil}

         %{systems: systems, buildings: b, population: p} ->
           {"#{length(systems)} systems shelled",
            "#{Style.int(b)} buildings damaged · ≈#{Style.int(p)} population lost", capped_names(systems)}
       end},
      {:pillage, "PILLAGES",
       case spoils.pillages do
         %{raids: 0} ->
           {"none", nil, nil}

         %{raids: n, credits: c, technology: t, ideology: i} = p ->
           targets =
             (p[:systems] || [])
             |> Enum.map(fn %{name: name, count: count} ->
               if count > 1, do: "#{name} ×#{count}", else: name
             end)

           {"#{n} raids", "#{Style.int(c)} credits · #{Style.int(t)} technology · #{Style.int(i)} ideology looted",
            capped_names(targets)}
       end}
    ]

    body =
      rows
      |> Enum.with_index()
      |> Enum.map(fn {{kind, label, {headline, detail, targets}}, i} ->
        ry = y + 88 + i * 72

        icon =
          case kind do
            :conquest -> ~s{<polygon points="#{Style.star_points(x + 40, ry - 6, 12)}" fill="rgba(230,230,230,0.7)"/>}
            :bombard -> legend_burst(x + 40, ry - 6, 12, "#ff832e")
            :pillage -> ~s{<rect x="#{x + 31}" y="#{ry - 15}" width="18" height="18" transform="rotate(45 #{x + 40} #{ry - 6})" fill="none" stroke="#ffd166" stroke-width="2.4"/>}
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
    game_data:, ownership:, highlights: [],
    territory: [%{faction:, entries: [%{sign: :+|:-, text:}]}],
    vp: %{win_target:, rows: [%{faction:, vp:, gained:, lost:}]},
    totals: [%{faction:, systems:, dominions:}]
  }
  """
  def digest(data) do
    h = 1000

    map = GalaxyMap.render_nested(data.game_data, data.ownership, 24, 112, 856, highlights: data.highlights)

    svg_open(@w, h) <>
      header(data.instance_name, data.window_label) <>
      map <>
      territory_panel(904, 112, 672, 392, data.territory) <>
      vp_panel(904, 528, 672, 246, data.vp) <>
      digest_footer_panel(904, 798, 672, 170, data.totals) <>
      "</svg>"
  end

  defp territory_panel(x, y, w, h, groups) do
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

    Style.panel(x, y, w, h, "Territory changes") <> body
  end

  defp vp_panel(x, y, w, h, vp) do
    Style.panel(x, y, w, h, "Victory track — first to #{vp.win_target}") <>
      VpStrip.render(vp.rows, x + 12, y + 58, w - 24, vp.win_target)
  end

  defp digest_footer_panel(x, y, w, h, totals) do
    body =
      totals
      |> Enum.with_index()
      |> Enum.map(fn {t, i} ->
        ty = y + 84 + i * 36

        Style.faction_chip(t.faction, x + 34, ty - 6, 26) <>
          ~s{<text x="#{x + 58}" y="#{ty}" font-family="#{Style.font_body()}" font-size="16" fill="rgba(230,230,230,0.85)"><tspan font-weight="800" fill="#{Style.lighten(Style.faction_color(t.faction), 18)}">#{Style.escape(Style.faction_name(t.faction))}</tspan>  #{t.systems} systems · #{t.dominions} dominions</text>}
      end)
      |> IO.iodata_to_binary()

    legend =
      GalaxyMap.legend(x + 24, y + h - 34, [{:gained, "Gained"}, {:lost, "Lost"}])

    Style.panel(x, y, w, h, "Current control") <> body <> legend
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
      ~s{<text x="#{x + w / 2}" y="#{y + 238}" text-anchor="middle" font-family="#{Style.font_body()}" font-size="16" fill="rgba(230,230,230,0.6)">tetrarchyfalls.com/play/daily · one run per day · everyone gets the same galaxy</text>}
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

    sub =
      ~s{<text x="800" y="458" text-anchor="middle" font-family="#{Style.font_body()}" font-size="19" fill="rgba(230,230,230,0.7)">#{Style.escape(data.instance_name)} · #{Style.escape(data.victory_type_label)} · day #{data.day}</text>}

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
      logo <> title <> sub <> standings <> totals <>
      "</svg>"
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

  defp header(title, subtitle) do
    ~s{<text x="32" y="58" font-family="#{Style.font_title()}" font-weight="700" font-size="30" letter-spacing="1" fill="#{Style.white()}">#{Style.escape(String.upcase(title))}</text>} <>
      ~s{<text x="1568" y="56" text-anchor="end" font-family="#{Style.font_body()}" font-weight="800" font-size="15" letter-spacing="2" fill="rgba(230,230,230,0.55)">#{Style.escape(subtitle)}</text>} <>
      ~s{<line x1="32" y1="82" x2="1568" y2="82" stroke="rgba(255,255,255,0.1)" stroke-width="1"/>}
  end

  defp map_panel(x, y, w, data, legend_entries) do
    map_w = w - 48
    h = 62 + map_w + 58
    map = GalaxyMap.render_nested(data.game_data, data.ownership, x + 24, y + 62, map_w, highlights: data.highlights)
    legend = GalaxyMap.legend(x + 24, y + 62 + map_w + 32, legend_entries)

    Style.panel(x, y, w, h, "Theatre of operations") <> map <> legend
  end

  defp footer_brand(x, y) do
    logo = Assets.logo_simple()
    [_, _, vw, _] = String.split(logo.viewbox, " ")
    scale = 26 / String.to_integer(vw)

    ~s{<g transform="translate(#{x},#{y - 20}) scale(#{Style.fnum(scale)})" fill="rgba(230,230,230,0.5)">#{logo.body}</g>} <>
      ~s{<text x="#{x + 36}" y="#{y - 1}" font-family="#{Style.font_body()}" font-size="14" fill="rgba(230,230,230,0.45)">tetrarchyfalls.com</text>}
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

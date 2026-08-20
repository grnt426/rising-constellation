defmodule RC.Discord.Render.VpStrip do
  @moduledoc """
  Compressed victory-track strip: one row per faction with its star
  count toward the win target, echoing the VictoryMiniPanel scoreboard
  (filled stars = banked VP). Stars gained since the last digest get a
  bright highlight ring; stars lost render as hollow outlines in the
  faction color.

  Input rows: `%{faction: "ark", vp: 9, gained: [9], lost: []}` where
  gained/lost are 1-based star indices. Rows render in descending VP
  order.
  """

  alias RC.Discord.Render.Style

  @row_h 54

  def height(faction_count), do: faction_count * @row_h + 16

  @doc """
  Renders at x,y with the given width (card px space). `win_target`
  caps the row (a subtle end-marker names the target).
  """
  def render(rows, x, y, w, win_target) do
    rows = Enum.sort_by(rows, & &1.vp, :desc)

    name_w = 210
    total_w = 92
    star_zone = w - name_w - total_w - 24
    step = min(34, star_zone / win_target)

    rows
    |> Enum.with_index()
    |> Enum.map(fn {row, i} ->
      ry = y + 8 + i * @row_h + @row_h / 2
      color = Style.faction_color(row.faction)
      gained = MapSet.new(row[:gained] || [])
      lost = MapSet.new(row[:lost] || [])

      chip = Style.faction_chip(row.faction, x + 22, ry, 34)

      name =
        ~s{<text x="#{x + 48}" y="#{ry + 5}" font-family="#{Style.font_body()}" font-weight="800" font-size="15" letter-spacing="0.5" fill="#{Style.lighten(color, 18)}">#{Style.escape(String.upcase(Style.faction_short_name(row.faction)))}</text>}

      stars =
        1..win_target
        |> Enum.map(fn s ->
          sx = x + name_w + s * step
          star(sx, ry, s, row.vp, color, gained, lost)
        end)
        |> IO.iodata_to_binary()

      delta = length(row[:gained] || []) - length(row[:lost] || [])

      delta_text =
        cond do
          delta > 0 -> ~s{ <tspan fill="#7ee787">+#{delta}</tspan>}
          delta < 0 -> ~s{ <tspan fill="#ff7b72">#{delta}</tspan>}
          true -> ""
        end

      total =
        ~s{<text x="#{x + w - 16}" y="#{ry + 6}" text-anchor="end" font-family="#{Style.font_body()}" font-weight="800" font-size="19" fill="#{Style.white()}">#{row.vp}<tspan font-size="13" fill="rgba(230,230,230,0.55)"> / #{win_target}</tspan>#{delta_text}</text>}

      sep =
        if i > 0 do
          sy = y + 8 + i * @row_h
          ~s{<line x1="#{x + 8}" y1="#{sy}" x2="#{x + w - 8}" y2="#{sy}" stroke="rgba(255,255,255,0.08)" stroke-width="1"/>}
        else
          ""
        end

      [sep, chip, name, stars, total]
    end)
    |> IO.iodata_to_binary()
  end

  defp star(sx, sy, index, vp, color, gained, lost) do
    r = 10

    cond do
      MapSet.member?(gained, index) ->
        # freshly landed: faint grey star outline behind, like it just
        # popped into place (rings would overlap on multi-star gains)
        ~s{<polygon points="#{Style.star_points(sx, sy, r + 4.5)}" fill="none" stroke="rgba(230,230,230,0.35)" stroke-width="1.3"/>} <>
          ~s{<polygon points="#{Style.star_points(sx, sy, r + 1.5)}" fill="#{Style.lighten(color, 20)}"/>}

      MapSet.member?(lost, index) ->
        # just lost: hollow outline where the star used to be
        ~s{<polygon points="#{Style.star_points(sx, sy, r)}" fill="none" stroke="#{Style.lighten(color, 12)}" stroke-width="1.5" stroke-opacity="0.9"/>}

      index <= vp ->
        ~s{<polygon points="#{Style.star_points(sx, sy, r)}" fill="#{color}"/>}

      true ->
        ~s{<circle cx="#{Style.fnum(sx)}" cy="#{Style.fnum(sy)}" r="2" fill="rgba(230,230,230,0.22)"/>}
    end
  end
end

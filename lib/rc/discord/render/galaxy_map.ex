defmodule RC.Discord.Render.GalaxyMap do
  @moduledoc """
  Far-view galaxy render for Discord news images, reproducing the
  in-game map's most-zoomed-out look (front/src/game/map/blocks/
  sector.js + system.js far LOD): faction-tinted sector polygons with
  sector name labels, system dots in the owner faction's lighter color,
  and blackholes -- plus bright highlight markers for the systems an
  event touched.

  Pure SVG-fragment composer. Geometry comes from `game_data` (the
  instances.game_data jsonb blob, string keys); live ownership comes as
  two maps resolved by the caller from the galaxy agent state:

      ownership = %{
        systems: %{system_id => %{faction: "ark" | nil, status: "inhabited_player"}},
        sectors: %{sector_id => "synelle" | nil}
      }

  Highlights are `%{system_id: id, kind: kind, label: "Mardir",
  faction: "ark", count: 2}` where kind is one of :gained, :lost,
  :conquest, :bombard, :pillage.
  """

  alias RC.Discord.Render.Style

  @bombard_color "#ff832e"
  @pillage_color "#ffd166"
  @lost_color "#aab3c0"

  @doc """
  Emits a nested `<svg>` positioned at x/y with the given pixel width,
  suitable for embedding in a card. The internal viewBox is the galaxy
  in game units.
  """
  def render_nested(game_data, ownership, x, y, w, opts \\ []) do
    size = Map.get(game_data, "size") || 200

    ~s{<svg x="#{x}" y="#{y}" width="#{w}" height="#{w}" viewBox="0 0 #{size} #{size}">} <>
      render_layers(game_data, ownership, size, opts) <>
      "</svg>"
  end

  defp render_layers(game_data, ownership, size, opts) do
    sectors = Map.get(game_data, "sectors") || []
    systems = Map.get(game_data, "systems") || []
    blackholes = Map.get(game_data, "blackholes") || []
    highlights = Keyword.get(opts, :highlights, [])
    system_index = Map.new(systems, &{&1["key"], &1})

    [
      ~s{<rect width="#{size}" height="#{size}" fill="#{Style.map_bg()}" rx="2"/>},
      render_sectors(sectors, ownership),
      render_blackholes(blackholes),
      render_systems(systems, ownership),
      render_sector_labels(sectors, ownership, size),
      render_highlights(highlights, system_index, size)
    ]
    |> IO.iodata_to_binary()
  end

  # Sector fill/border in the owner faction's darker shade, matching the
  # far-LOD look (fill opacity .12, border opacity .5).
  defp render_sectors(sectors, ownership) do
    Enum.map(sectors, fn sector ->
      points = sector["points03"] || sector["points"] || []
      owner = Map.get(ownership.sectors, sector["key"])

      {fill, stroke, fill_op} =
        case Style.safe_faction_key(owner) do
          nil -> {Style.neutral(), Style.neutral(), "0.04"}
          key -> {Style.darken(Style.faction_color(key), 10), Style.darken(Style.faction_color(key), 5), "0.16"}
        end

      pts = Enum.map_join(points, " ", fn [px, py] -> "#{Style.fnum(px)},#{Style.fnum(py)}" end)

      if pts == "" do
        ""
      else
        ~s{<polygon points="#{pts}" fill="#{fill}" fill-opacity="#{fill_op}" stroke="#{stroke}" stroke-opacity="0.55" stroke-width="0.3"/>}
      end
    end)
  end

  defp render_blackholes(blackholes) do
    Enum.map(blackholes, fn b ->
      %{"position" => %{"x" => x, "y" => y}, "radius" => r} = b

      ~s{<circle cx="#{Style.fnum(x)}" cy="#{Style.fnum(y)}" r="#{Style.fnum(r)}" fill="rgba(0,0,0,0.45)" stroke="rgba(120,140,180,0.35)" stroke-width="0.25"/>}
    end)
  end

  # System dots. Owned systems pop in the faction's lighter color (the
  # far-view InstancedMesh tint); neutral inhabited systems read as
  # civilization at a glance; empty space recedes.
  defp render_systems(systems, ownership) do
    Enum.map(systems, fn sys ->
      %{"key" => id, "position" => %{"x" => x, "y" => y}} = sys
      live = Map.get(ownership.systems, id, %{})
      faction = Style.safe_faction_key(live[:faction] || live["faction"])
      status = live[:status] || live["status"]

      {r, fill, opacity} =
        cond do
          faction != nil and status == "inhabited_player" ->
            {0.75, Style.lighten(Style.faction_color(faction), 15), "1"}

          faction != nil ->
            # dominions: faction-colored but visually secondary
            {0.55, Style.lighten(Style.faction_color(faction), 10), "0.85"}

          status == "inhabited_neutral" ->
            {0.45, "#cfd6e4", "0.75"}

          status == "uninhabitable" ->
            {0.25, "#5c6a80", "0.3"}

          true ->
            {0.32, "#8fa0b8", "0.4"}
        end

      ~s{<circle cx="#{Style.fnum(x)}" cy="#{Style.fnum(y)}" r="#{r}" fill="#{fill}" fill-opacity="#{opacity}"/>}
    end)
  end

  # Sector names in the owner's lighter color, like the far-view labels.
  defp render_sector_labels(sectors, ownership, size) do
    Enum.map(sectors, fn sector ->
      case {sector["centroid"], sector["name"]} do
        {[x, y], name} when is_binary(name) ->
          owner = Style.safe_faction_key(Map.get(ownership.sectors, sector["key"]))

          fill =
            case owner do
              nil -> "rgba(230,230,230,0.5)"
              key -> Style.lighten(Style.faction_color(key), 22)
            end

          # keep centroid labels from running off the canvas
          half = String.length(name) * 1.35

          {anchor, tx} =
            cond do
              x + half > size - 2 -> {"end", size - 2}
              x - half < 2 -> {"start", 2}
              true -> {"middle", x}
            end

          ty = min(max(y, 5), size - 2)

          ~s{<text x="#{Style.fnum(tx)}" y="#{Style.fnum(ty)}" text-anchor="#{anchor}" font-family="#{Style.font_body()}" font-weight="800" font-size="3.6" letter-spacing="0.4" fill="#{fill}" stroke="#{Style.map_bg()}" stroke-width="0.55" paint-order="stroke">#{Style.escape(String.upcase(name))}</text>}

        _ ->
          ""
      end
    end)
  end

  # Labels dodge each other: when a label would land within ~a label's
  # width of one already placed, it flips below its marker instead.
  defp render_highlights(highlights, system_index, size) do
    highlights
    |> Enum.reduce({[], []}, fn h, {frags, placed} ->
      case Map.get(system_index, h.system_id) do
        %{"position" => %{"x" => x, "y" => y}} ->
          {label_frag, placed} = highlight_label(h, x, y, size, placed)
          {[frags, marker(h, x, y), label_frag], placed}

        _ ->
          {frags, placed}
      end
    end)
    |> elem(0)
    |> IO.iodata_to_binary()
  end

  defp marker(%{kind: :gained} = h, x, y) do
    color = Style.lighten(Style.faction_color(h[:faction]), 20)

    ~s{<circle cx="#{Style.fnum(x)}" cy="#{Style.fnum(y)}" r="2.4" fill="none" stroke="#ffffff" stroke-width="0.55"/>} <>
      ~s{<circle cx="#{Style.fnum(x)}" cy="#{Style.fnum(y)}" r="3.4" fill="none" stroke="#{color}" stroke-width="0.35" stroke-opacity="0.75"/>}
  end

  defp marker(%{kind: :lost}, x, y) do
    ~s{<circle cx="#{Style.fnum(x)}" cy="#{Style.fnum(y)}" r="2.4" fill="none" stroke="#{@lost_color}" stroke-width="0.45" stroke-dasharray="1.1,0.8"/>}
  end

  defp marker(%{kind: :conquest} = h, x, y) do
    color = Style.lighten(Style.faction_color(h[:faction]), 15)

    ~s{<polygon points="#{Style.star_points(x, y, 2.6)}" fill="#{color}" stroke="#ffffff" stroke-width="0.35"/>}
  end

  defp marker(%{kind: :bombard}, x, y) do
    # eight-point burst
    outer = 2.6
    inner = 1.0

    pts =
      0..15
      |> Enum.map(fn i ->
        angle = i * :math.pi() / 8
        r = if rem(i, 2) == 0, do: outer, else: inner
        "#{Style.fnum(x + r * :math.cos(angle))},#{Style.fnum(y + r * :math.sin(angle))}"
      end)
      |> Enum.join(" ")

    ~s{<polygon points="#{pts}" fill="none" stroke="#{@bombard_color}" stroke-width="0.45"/>}
  end

  defp marker(%{kind: :pillage}, x, y) do
    ~s{<rect x="#{Style.fnum(x - 1.7)}" y="#{Style.fnum(y - 1.7)}" width="3.4" height="3.4" transform="rotate(45 #{Style.fnum(x)} #{Style.fnum(y)})" fill="none" stroke="#{@pillage_color}" stroke-width="0.45"/>}
  end

  defp highlight_label(h, x, y, size, placed) do
    label = h[:label]
    count = h[:count]

    text =
      cond do
        label && count && count > 1 -> "#{label} ×#{count}"
        label -> label
        count && count > 1 -> "×#{count}"
        true -> nil
      end

    if text do
      above = if y < 8, do: y + 6.2, else: y - 4.2
      below = if y > size - 8, do: y - 4.2, else: y + 6.2

      conflicts? = fn ty ->
        Enum.any?(placed, fn {px, py} -> abs(px - x) < 16 and abs(py - ty) < 4.5 end)
      end

      ty = if conflicts?.(above), do: below, else: above

      {anchor, tx} =
        cond do
          x < 14 -> {"start", x - 2}
          x > size - 14 -> {"end", x + 2}
          true -> {"middle", x}
        end

      frag =
        ~s{<text x="#{Style.fnum(tx)}" y="#{Style.fnum(ty)}" text-anchor="#{anchor}" font-family="#{Style.font_body()}" font-weight="800" font-size="3" fill="#ffffff" stroke="#{Style.map_bg()}" stroke-width="0.5" paint-order="stroke">#{Style.escape(text)}</text>}

      {frag, [{x, ty} | placed]}
    else
      {"", placed}
    end
  end

  @doc "Legend entries as a horizontal strip starting at x,y (card px space)."
  def legend(x, y, entries) do
    entries
    |> Enum.reduce({[], x}, fn {kind, text}, {acc, cx} ->
      glyph = legend_glyph(kind, cx + 10, y)
      label_x = cx + 24

      label =
        ~s{<text x="#{label_x}" y="#{y + 5}" font-family="#{Style.font_body()}" font-size="14" fill="rgba(230,230,230,0.75)">#{Style.escape(text)}</text>}

      width = 24 + String.length(text) * 7.2 + 26
      {[acc, glyph, label], cx + width}
    end)
    |> elem(0)
    |> IO.iodata_to_binary()
  end

  defp legend_glyph(:gained, cx, cy),
    do: ~s{<circle cx="#{cx}" cy="#{cy}" r="7" fill="none" stroke="#ffffff" stroke-width="2"/>}

  defp legend_glyph(:lost, cx, cy),
    do: ~s{<circle cx="#{cx}" cy="#{cy}" r="7" fill="none" stroke="#{@lost_color}" stroke-width="1.8" stroke-dasharray="3.5,2.5"/>}

  defp legend_glyph(:conquest, cx, cy),
    do: ~s{<polygon points="#{Style.star_points(cx, cy, 8)}" fill="#e6e6e6"/>}

  defp legend_glyph(:bombard, cx, cy) do
    pts =
      0..15
      |> Enum.map(fn i ->
        angle = i * :math.pi() / 8
        r = if rem(i, 2) == 0, do: 8, else: 3.2
        "#{Style.fnum(cx + r * :math.cos(angle))},#{Style.fnum(cy + r * :math.sin(angle))}"
      end)
      |> Enum.join(" ")

    ~s{<polygon points="#{pts}" fill="none" stroke="#{@bombard_color}" stroke-width="1.6"/>}
  end

  defp legend_glyph(:pillage, cx, cy),
    do:
      ~s{<rect x="#{cx - 6}" y="#{cy - 6}" width="12" height="12" transform="rotate(45 #{cx} #{cy})" fill="none" stroke="#{@pillage_color}" stroke-width="1.6"/>}
end

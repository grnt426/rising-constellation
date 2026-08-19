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
  :flipped (changed hands -- one marker for the gain+loss pair),
  :conquest, :bombard, :pillage.

  `opts[:legend]` takes `[{kind, "Label"}, ...]` and renders a compact
  legend overlaid on the map's top-right corner, so the symbols sit
  next to what they explain.
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
    # The game presents the galaxy with Y up (the SPA's InstanceMap
    # draws y as `size - y`); SVG's Y grows downward, so flip the
    # geometry once at ingestion or the map renders upside down.
    sectors = Enum.map(Map.get(game_data, "sectors") || [], &flip_sector(&1, size))
    systems = Enum.map(Map.get(game_data, "systems") || [], &flip_position(&1, size))
    blackholes = Enum.map(Map.get(game_data, "blackholes") || [], &flip_position(&1, size))
    highlights = Keyword.get(opts, :highlights, [])
    system_index = Map.new(systems, &{&1["key"], &1})

    [
      ~s{<rect width="#{size}" height="#{size}" fill="#{Style.map_bg()}" rx="2"/>},
      render_sectors(sectors, ownership),
      render_blackholes(blackholes),
      render_systems(systems, ownership),
      render_sector_labels(sectors, ownership, size),
      render_highlights(highlights, system_index, size),
      render_map_legend(Keyword.get(opts, :legend, []), size)
    ]
    |> IO.iodata_to_binary()
  end

  defp flip_position(%{"position" => %{"y" => y} = pos} = entity, size),
    do: %{entity | "position" => %{pos | "y" => size - y}}

  defp flip_position(entity, _size), do: entity

  defp flip_sector(sector, size) do
    sector
    |> flip_points("points03", size)
    |> flip_points("points", size)
    |> flip_centroid(size)
  end

  defp flip_points(sector, key, size) do
    case sector[key] do
      points when is_list(points) ->
        Map.put(sector, key, Enum.map(points, fn [x, y] -> [x, size - y] end))

      _ ->
        sector
    end
  end

  defp flip_centroid(%{"centroid" => [x, y]} = sector, size), do: %{sector | "centroid" => [x, size - y]}
  defp flip_centroid(sector, _size), do: sector

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

  # changed hands: solid ring for the new owner wrapped in the broken
  # ring of the old one -- a single marker for the gain+loss pair
  defp marker(%{kind: :flipped} = h, x, y) do
    color = Style.lighten(Style.faction_color(h[:faction]), 20)

    ~s{<circle cx="#{Style.fnum(x)}" cy="#{Style.fnum(y)}" r="2.2" fill="none" stroke="#{color}" stroke-width="0.55"/>} <>
      ~s{<circle cx="#{Style.fnum(x)}" cy="#{Style.fnum(y)}" r="3.4" fill="none" stroke="#{@lost_color}" stroke-width="0.4" stroke-dasharray="1.1,0.8"/>}
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

  # Compact legend overlaid on the map's top-right corner (game-unit
  # space), so the symbols sit next to the markers they explain.
  defp render_map_legend([], _size), do: ""

  defp render_map_legend(entries, size) do
    entry_w = fn {_kind, text} -> 6.2 + String.length(text) * 1.55 + 3.2 end
    total = entries |> Enum.map(entry_w) |> Enum.sum()
    x0 = size - 4 - total
    cy = 6.4

    backdrop =
      ~s{<rect x="#{Style.fnum(x0 - 2)}" y="2.4" width="#{Style.fnum(total + 4)}" height="8" rx="1.6" fill="rgba(14,23,38,0.78)" stroke="rgba(255,255,255,0.14)" stroke-width="0.15"/>}

    frags =
      entries
      |> Enum.reduce({[], x0}, fn {kind, text} = entry, {acc, cx} ->
        glyph = legend_glyph(kind, cx + 2.4, cy)

        label =
          ~s{<text x="#{Style.fnum(cx + 5.6)}" y="#{Style.fnum(cy + 1.1)}" font-family="#{Style.font_body()}" font-weight="800" font-size="3" fill="rgba(230,230,230,0.85)">#{Style.escape(text)}</text>}

        {[acc, glyph, label], cx + entry_w.(entry)}
      end)
      |> elem(0)

    IO.iodata_to_binary([backdrop, frags])
  end

  defp legend_glyph(:gained, cx, cy),
    do:
      ~s{<circle cx="#{Style.fnum(cx)}" cy="#{Style.fnum(cy)}" r="1.7" fill="none" stroke="#ffffff" stroke-width="0.45"/>}

  defp legend_glyph(:lost, cx, cy),
    do:
      ~s{<circle cx="#{Style.fnum(cx)}" cy="#{Style.fnum(cy)}" r="1.7" fill="none" stroke="#{@lost_color}" stroke-width="0.4" stroke-dasharray="0.9,0.7"/>}

  defp legend_glyph(:flipped, cx, cy),
    do:
      ~s{<circle cx="#{Style.fnum(cx)}" cy="#{Style.fnum(cy)}" r="1.3" fill="none" stroke="#ffffff" stroke-width="0.4"/>} <>
        ~s{<circle cx="#{Style.fnum(cx)}" cy="#{Style.fnum(cy)}" r="2.2" fill="none" stroke="#{@lost_color}" stroke-width="0.32" stroke-dasharray="0.9,0.7"/>}

  defp legend_glyph(:conquest, cx, cy),
    do: ~s{<polygon points="#{Style.star_points(cx, cy, 2)}" fill="#e6e6e6"/>}

  defp legend_glyph(:bombard, cx, cy) do
    pts =
      0..15
      |> Enum.map(fn i ->
        angle = i * :math.pi() / 8
        r = if rem(i, 2) == 0, do: 2, else: 0.8
        "#{Style.fnum(cx + r * :math.cos(angle))},#{Style.fnum(cy + r * :math.sin(angle))}"
      end)
      |> Enum.join(" ")

    ~s{<polygon points="#{pts}" fill="none" stroke="#{@bombard_color}" stroke-width="0.4"/>}
  end

  defp legend_glyph(:pillage, cx, cy),
    do:
      ~s{<rect x="#{Style.fnum(cx - 1.4)}" y="#{Style.fnum(cy - 1.4)}" width="2.8" height="2.8" transform="rotate(45 #{Style.fnum(cx)} #{Style.fnum(cy)})" fill="none" stroke="#{@pillage_color}" stroke-width="0.4"/>}
end

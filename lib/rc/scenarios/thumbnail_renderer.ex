defmodule RC.Scenarios.ThumbnailRenderer do
  @moduledoc """
  Renders a Forge map/scenario `game_data` blob to an SVG string suitable
  for rasterization via ImageMagick. Pure function — no I/O, no Repo, no
  process dependencies. Composable as `game_data |> render() |> File.write`.

  The output is a stand-alone SVG with every paint property inlined (no
  CSS classes). librsvg, which ImageMagick shells into for SVG input,
  does not reliably resolve external stylesheets, so anything that needs
  to be rendered must be expressed as an inline attribute.

  Coordinate system mirrors the wizard: viewBox in game units (0 0 size
  size). System dot radii etc. are sized in game units; the final raster
  size is picked at the `convert` step downstream.

  ## game_data shape (jsonb, string keys)

      %{
        "size"        => 120,
        "systems"     => [%{"key" => 1, "type" => "red_dwarf",
                            "position" => %{"x" => 49, "y" => 32}}, ...],
        "sectors"     => [%{"key" => 0, "name" => "Passe de Nari",
                            "points03" => [[x, y], ...],
                            "centroid" => [x, y]}, ...],
        "blackholes"  => [%{"key" => 1, "position" => %{"x" => 60, "y" => 40},
                            "radius" => 5}, ...]
      }
  """

  alias Instance.Galaxy.SpatialGraph
  alias Spatial.Position

  # Match the wizard's display palette so the thumbnail is recognisably
  # the same map the author was looking at. Pulled from
  # front/src/styles/portal/panel/editor.scss.
  @bg "#0e1726"
  @grid_stroke "rgba(255,255,255,0.06)"
  @sector_fill "rgba(255,255,255,0.06)"
  @sector_stroke "rgba(255,255,255,0.18)"
  @blackhole_fill "rgba(0,0,0,0.3)"
  @blackhole_stroke "rgba(0,0,0,0.55)"
  @edge_stroke "rgba(255,255,255,0.18)"
  @label_fill "rgba(255,255,255,0.85)"

  @system_colors %{
    "white_dwarf" => "#d4f4ff",
    "red_dwarf" => "#fa8064",
    "orange_dwarf" => "#ffd1a3",
    "yellow_dwarf" => "#ffe880",
    "red_giant" => "#f2183c",
    "blue_giant" => "#1fa8ed"
  }

  @default_system_color "#ffffff"

  # Scaling for in-viewBox elements. With a 400px raster and a size=120
  # map, a system circle of r=0.7 game units shows up at ~2.3 px —
  # close to the wizard's r=3 on a 1209px container. Tune up for larger
  # giants per the wizard's CSS rules.
  @system_radius 0.7
  @giant_radius 1.2
  @edge_stroke_width 0.18
  @sector_stroke_width 0.25
  @grid_stroke_width 0.12

  @doc """
  Returns an SVG string. `game_data` can be a plain map (string keys) or
  a struct with the same shape. Missing keys are tolerated — a scenario
  with no sectors yet still renders a valid empty grid.
  """
  def render(game_data) when is_map(game_data) do
    size = Map.get(game_data, "size") || Map.get(game_data, :size) || 120
    systems = list_at(game_data, "systems")
    sectors = list_at(game_data, "sectors")
    blackholes = list_at(game_data, "blackholes")
    edges = compute_edges(systems, blackholes)

    """
    <?xml version="1.0" encoding="UTF-8"?>
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 #{size} #{size}" \
    width="#{size}" height="#{size}">
      <rect width="#{size}" height="#{size}" fill="#{@bg}"/>
      #{render_grid(size)}
      #{render_sectors(sectors)}
      #{render_blackholes(blackholes)}
      #{render_edges(edges)}
      #{render_systems(systems)}
      #{render_labels(sectors)}
    </svg>
    """
  end

  # Grid lines every 12 units — matches the wizard's @max_dist constant.
  defp render_grid(size) do
    count = max(1, round(size / 12))

    lines =
      for i <- 1..count do
        y = i * 12

        ~s(<line x1="0" y1="#{y}" x2="#{size}" y2="#{y}" stroke="#{@grid_stroke}" stroke-width="#{@grid_stroke_width}"/>) <>
          ~s(<line x1="#{y}" y1="0" x2="#{y}" y2="#{size}" stroke="#{@grid_stroke}" stroke-width="#{@grid_stroke_width}"/>)
      end

    Enum.join(lines, "")
  end

  defp render_sectors(sectors) do
    sectors
    |> Enum.map(fn sector ->
      points = polygon_points(sector) |> format_points()

      if points == "" do
        ""
      else
        ~s(<polygon points="#{points}" fill="#{@sector_fill}" stroke="#{@sector_stroke}" stroke-width="#{@sector_stroke_width}"/>)
      end
    end)
    |> Enum.join("")
  end

  # The wizard renders sectors using `points03` — the polygon inset by
  # 0.3 game units so adjacent sectors don't visually collide. Fall back
  # to `points` if for some reason the inset version is missing.
  defp polygon_points(sector) do
    case Map.get(sector, "points03") || Map.get(sector, :points03) ||
           Map.get(sector, "points") || Map.get(sector, :points) do
      pts when is_list(pts) -> pts
      _ -> []
    end
  end

  defp format_points(points) do
    points
    |> Enum.map_join(" ", fn [x, y] -> "#{fnum(x)},#{fnum(y)}" end)
  end

  defp render_blackholes(blackholes) do
    blackholes
    |> Enum.map(fn b ->
      pos = position(b)
      r = Map.get(b, "radius") || Map.get(b, :radius) || 0

      ~s(<circle cx="#{fnum(pos.x)}" cy="#{fnum(pos.y)}" r="#{fnum(r)}" fill="#{@blackhole_fill}" stroke="#{@blackhole_stroke}" stroke-width="0.2"/>)
    end)
    |> Enum.join("")
  end

  # Reuses the engine's edge-computation rule (12-unit proximity with
  # blackhole avoidance) so the thumbnail's warp lanes match whatever
  # the live game will instantiate.
  defp compute_edges([], _), do: []

  defp compute_edges(systems, blackholes) do
    sys_structs =
      Enum.map(systems, fn s ->
        %{id: Map.get(s, "key") || Map.get(s, :key), position: to_position(s)}
      end)

    bh_structs =
      Enum.map(blackholes, fn b ->
        %{position: to_position(b), radius: Map.get(b, "radius") || Map.get(b, :radius) || 0}
      end)

    SpatialGraph.generate_edges(sys_structs, bh_structs)
  rescue
    # If for any reason the graph builder explodes (rare — but a corrupt
    # game_data shouldn't blow up the thumbnail), fall back to no edges.
    _ -> []
  end

  defp render_edges(edges) do
    edges
    |> Enum.map(fn %{s1: s1, s2: s2} ->
      ~s(<line x1="#{fnum(s1.position.x)}" y1="#{fnum(s1.position.y)}" x2="#{fnum(s2.position.x)}" y2="#{fnum(s2.position.y)}" stroke="#{@edge_stroke}" stroke-width="#{@edge_stroke_width}"/>)
    end)
    |> Enum.join("")
  end

  defp render_systems(systems) do
    systems
    |> Enum.map(fn sys ->
      pos = position(sys)
      type = Map.get(sys, "type") || Map.get(sys, :type) || ""
      color = Map.get(@system_colors, type, @default_system_color)
      r = if type in ["red_giant", "blue_giant"], do: @giant_radius, else: @system_radius

      ~s(<circle cx="#{fnum(pos.x)}" cy="#{fnum(pos.y)}" r="#{fnum(r)}" fill="#{color}"/>)
    end)
    |> Enum.join("")
  end

  defp render_labels(sectors) do
    sectors
    |> Enum.map(fn sector ->
      centroid = Map.get(sector, "centroid") || Map.get(sector, :centroid)
      name = Map.get(sector, "name") || Map.get(sector, :name) || ""

      case centroid do
        [x, y] when is_number(x) and is_number(y) and name != "" ->
          # font-family must name a real installed font — librsvg
          # (via ImageMagick) treats unknown families as the literal
          # name and crashes when it can't load them. The dev/prod
          # images ship DejaVu Sans; the fallback list is for hosts
          # where it isn't.
          ~s(<text x="#{fnum(x)}" y="#{fnum(y)}" text-anchor="middle" fill="#{@label_fill}" font-family="DejaVu Sans, sans-serif" font-size="3" font-weight="bold">#{escape(name)}</text>)

        _ ->
          ""
      end
    end)
    |> Enum.join("")
  end

  # --- helpers ---

  defp list_at(map, key) do
    case Map.get(map, key) || Map.get(map, String.to_atom(key)) do
      list when is_list(list) -> list
      _ -> []
    end
  end

  defp position(entity) do
    case Map.get(entity, "position") || Map.get(entity, :position) do
      %{"x" => x, "y" => y} -> %{x: x, y: y}
      %{x: x, y: y} -> %{x: x, y: y}
      _ -> %{x: 0, y: 0}
    end
  end

  defp to_position(entity) do
    p = position(entity)
    %Position{x: p.x * 1.0, y: p.y * 1.0}
  end

  # SVG numeric attrs don't need many decimals at this raster size.
  defp fnum(n) when is_integer(n), do: Integer.to_string(n)
  defp fnum(n) when is_float(n), do: :erlang.float_to_binary(n, decimals: 2)
  defp fnum(_), do: "0"

  defp escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end
end

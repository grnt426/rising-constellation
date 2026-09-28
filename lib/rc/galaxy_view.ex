defmodule RC.GalaxyView do
  @moduledoc """
  Galaxy coordinates -> 2D image space, oriented the way the game shows
  them. The server-side twin of front/src/utils/galaxy-view.js.

  The in-game map puts `game_data` coordinates straight into a y-up
  three.js scene: x grows to the right and y grows UP the screen. SVG y
  grows down, so every server-side galaxy render flips y through here:

    * `to_screen/2` flips the geometry itself (systems, blackholes,
      sector outlines and centroids), for renders that also place text
      (RC.Discord.Render.GalaxyMap: news cards, lobby link previews);
    * `flip_transform/1` is the equivalent SVG group transform, for
      renders with no text drawn straight in galaxy coordinates
      (RC.Scenarios.ThumbnailRenderer: Forge thumbnails).

  Stored `game_data` is never rewritten; only drawings are flipped, so
  running games are unaffected.
  """

  @point_keys ["points", "points03", "points05", "points25"]

  @doc "SVG transform flipping a `size`-unit galaxy drawn in its own coordinates."
  def flip_transform(size), do: "translate(0 #{size}) scale(1 -1)"

  @doc """
  `game_data` (string keys, as stored) with every system, blackhole and
  sector flipped into y-down image space of height `size`.
  """
  def to_screen(game_data, size) do
    game_data
    |> update_list("systems", &flip_position(&1, size))
    |> update_list("blackholes", &flip_position(&1, size))
    |> update_list("sectors", &flip_sector(&1, size))
  end

  def flip_position(%{"position" => %{"y" => y} = pos} = entity, size) when is_number(y),
    do: %{entity | "position" => %{pos | "y" => size - y}}

  def flip_position(entity, _size), do: entity

  def flip_sector(sector, size) do
    sector =
      Enum.reduce(@point_keys, sector, fn key, acc ->
        case acc[key] do
          points when is_list(points) -> Map.put(acc, key, Enum.map(points, &flip_point(&1, size)))
          _ -> acc
        end
      end)

    case sector["centroid"] do
      [_, _] = centroid -> %{sector | "centroid" => flip_point(centroid, size)}
      _ -> sector
    end
  end

  def flip_point([x, y], size) when is_number(y), do: [x, size - y]
  def flip_point(point, _size), do: point

  defp update_list(game_data, key, fun) do
    case game_data[key] do
      list when is_list(list) -> Map.put(game_data, key, Enum.map(list, fun))
      _ -> game_data
    end
  end
end

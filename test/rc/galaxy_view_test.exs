defmodule RC.GalaxyViewTest do
  use ExUnit.Case, async: true

  alias RC.GalaxyView

  @game_data %{
    "size" => 100,
    "systems" => [%{"key" => 1, "position" => %{"x" => 25, "y" => 30}}],
    "blackholes" => [%{"key" => 1, "radius" => 4, "position" => %{"x" => 60, "y" => 90}}],
    "sectors" => [
      %{
        "key" => 0,
        "points" => [[0, 0], [50, 0], [50, 40]],
        "points03" => [[1, 1], [49, 1], [49, 39]],
        "centroid" => [33, 13]
      }
    ]
  }

  test "to_screen flips y for systems, blackholes, sector outlines and centroids" do
    screen = GalaxyView.to_screen(@game_data, 100)

    assert [%{"position" => %{"x" => 25, "y" => 70}}] = screen["systems"]
    assert [%{"position" => %{"x" => 60, "y" => 10}, "radius" => 4}] = screen["blackholes"]

    [sector] = screen["sectors"]
    assert sector["points"] == [[0, 100], [50, 100], [50, 60]]
    assert sector["points03"] == [[1, 99], [49, 99], [49, 61]]
    assert sector["centroid"] == [33, 87]
  end

  test "flipping twice is the identity, and the stored data is untouched" do
    assert @game_data |> GalaxyView.to_screen(100) |> GalaxyView.to_screen(100) == @game_data
  end

  test "tolerates missing layers and malformed entries" do
    assert GalaxyView.to_screen(%{"size" => 10}, 10) == %{"size" => 10}
    assert GalaxyView.flip_position(%{"key" => 1}, 10) == %{"key" => 1}
    assert GalaxyView.flip_sector(%{"key" => 1}, 10) == %{"key" => 1}
  end

  test "flip_transform is the equivalent SVG group transform" do
    assert GalaxyView.flip_transform(120) == "translate(0 120) scale(1 -1)"
  end
end

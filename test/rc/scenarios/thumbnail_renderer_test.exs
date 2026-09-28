defmodule RC.Scenarios.ThumbnailRendererTest do
  use ExUnit.Case, async: true

  alias RC.Scenarios.ThumbnailRenderer

  @game_data %{
    "size" => 120,
    "systems" => [%{"key" => 1, "type" => "red_dwarf", "position" => %{"x" => 10, "y" => 20}}],
    "sectors" => [%{"key" => 0, "points03" => [[0, 0], [60, 0], [60, 60]]}],
    "blackholes" => []
  }

  test "the galaxy is drawn y-up like the game, inside one flipped group" do
    svg = ThumbnailRenderer.render(@game_data)

    # Geometry keeps galaxy coordinates; the group flips it on screen,
    # so the system at y=20 lands 20 units from the BOTTOM of the image.
    assert svg =~ ~s[<g transform="translate(0 120) scale(1 -1)">]
    assert svg =~ ~s(cx="10" cy="20")

    [before_group, _] = String.split(svg, "<g transform=", parts: 2)
    refute before_group =~ "<circle"
  end

  test "version 2 is the y-up renderer" do
    assert ThumbnailRenderer.version() == 2
  end
end

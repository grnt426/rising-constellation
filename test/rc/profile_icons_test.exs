defmodule RC.ProfileIconsTest do
  use ExUnit.Case, async: true

  # The generated registry (priv/data/profile_icons.json) backing
  # favorite-icon validation and the Discord card's icon rendering.

  test "registry loads and covers the game-flavored groups" do
    icons = RC.ProfileIcons.list()

    assert length(icons) > 300

    groups = icons |> Enum.map(&(&1 |> String.split("/") |> hd())) |> Enum.uniq() |> Enum.sort()

    assert groups == ~w(
             action agent building doctrine faction marker patent reaction
             resource ship stellar_body stellar_system
           )
  end

  test "known?/1" do
    assert RC.ProfileIcons.known?("marker/flag")
    assert RC.ProfileIcons.known?("faction/ark")
    refute RC.ProfileIcons.known?("logo/simple")
    refute RC.ProfileIcons.known?("ship/frame_ship")
    refute RC.ProfileIcons.known?("not/an-icon")
    refute RC.ProfileIcons.known?(nil)
  end

  test "svg/1 returns rasterizer-safe inline SVG" do
    assert %{viewbox: "0 0 " <> _, body: body} = RC.ProfileIcons.svg("marker/flag")
    assert body =~ "<path"
    # vue-svgicon artifacts must be normalized away (see bin/gen_profile_icons.exs)
    refute body =~ "pid="
    refute body =~ "_fill"
    refute body =~ "_stroke"

    assert RC.ProfileIcons.svg("nope/nope") == nil
  end

  test "faction_keys/0 is the canonical five" do
    assert RC.ProfileIcons.faction_keys() == ~w(tetrarchy myrmezir cardan synelle ark)
  end
end

defmodule RC.Discord.RenderCardsTest do
  use ExUnit.Case, async: true

  alias RC.Discord.Render.Cards

  # Minimal two-sector galaxy fixture in the instances.game_data shape.
  defp game_data do
    %{
      "size" => 100,
      "systems" => [
        %{"key" => 1, "type" => "yellow_dwarf", "position" => %{"x" => 25, "y" => 30}},
        %{"key" => 2, "type" => "red_giant", "position" => %{"x" => 70, "y" => 60}}
      ],
      "sectors" => [
        %{
          "key" => 0,
          "name" => "Alpha",
          "points03" => [[10, 10], [40, 10], [40, 40], [10, 40]],
          "centroid" => [25, 25]
        },
        %{"key" => 1, "name" => "Beta", "points03" => [[50, 50], [90, 50], [90, 90], [50, 90]], "centroid" => [70, 70]}
      ],
      "blackholes" => []
    }
  end

  defp ownership do
    %{
      systems: %{
        1 => %{faction: "synelle", status: "inhabited_player"},
        2 => %{faction: "ark", status: "inhabited_dominion"}
      },
      sectors: %{0 => "synelle", 1 => "ark"}
    }
  end

  defp assert_svg(svg) do
    assert String.starts_with?(svg, ~s(<?xml version="1.0" encoding="UTF-8"?>))
    assert String.ends_with?(svg, "</svg>")
    # balanced text tags is a decent smoke check for broken interpolation
    assert length(String.split(svg, "<text")) == length(String.split(svg, "</text>"))
  end

  test "digest card renders both panels, the VP track, and the highlights" do
    svg =
      Cards.digest(%{
        instance_name: "Test Match",
        window_label: "6-HOUR DIGEST · 06:00–12:00 UTC",
        game_data: game_data(),
        ownership: ownership(),
        highlights: [%{system_id: 1, kind: :gained, label: "One", faction: "synelle"}],
        legend: [{:gained, "Gained"}],
        territory: [%{faction: "synelle", entries: [%{sign: :+, text: "One — system colonized"}]}],
        vp: %{win_target: 14, rows: [%{faction: "synelle", vp: 3, gained: [3], lost: []}]},
        totals: [%{faction: "synelle", systems: 5, dominions: 2}]
      })

    assert_svg(svg)
    assert svg =~ "TEST MATCH"
    assert svg =~ "TERRITORY CHANGES"
    assert svg =~ "CURRENT CONTROL"
    assert svg =~ "VICTORY TRACK — FIRST TO 14"
    assert svg =~ "ALPHA"
    assert svg =~ "One — system colonized"
    assert svg =~ "tetrarchyfalls.com"

    # Y is flipped to match the in-game presentation (SVG y grows down,
    # the game draws y up): system 1 sits at game (25, 30) in a size-100
    # galaxy, so it must render at cy = 100 - 30.
    assert svg =~ ~s(cx="25" cy="70")
  end

  test "digest switches to the wide layout at four factions" do
    rows = for f <- ["synelle", "ark", "cardan", "myrmezir"], do: %{faction: f, vp: 2, gained: [], lost: []}

    svg =
      Cards.digest(%{
        instance_name: "Big Match",
        window_label: "W",
        game_data: game_data(),
        ownership: ownership(),
        highlights: [],
        legend: [],
        territory: [],
        vp: %{win_target: 14, rows: rows},
        totals: []
      })

    assert_svg(svg)
    # wide layout: the VP panel spans the full card width (x=24 w=1552)
    assert svg =~ ~s(<rect x="24" y=)
  end

  test "digest_territory card has no VP track" do
    svg =
      Cards.digest_territory(%{
        instance_name: "Test Match",
        window_label: "TERRITORY REPORT · 06:00–12:00 UTC",
        game_data: game_data(),
        ownership: ownership(),
        highlights: [],
        legend: [],
        territory: [%{faction: "ark", entries: [%{sign: :-, text: "Two — dominion lost"}]}],
        totals: [%{faction: "ark", systems: 4, dominions: 1}]
      })

    assert_svg(svg)
    refute svg =~ "VICTORY TRACK"
    assert svg =~ "TERRITORY CHANGES"
    assert svg =~ "CURRENT CONTROL"
  end

  test "bulletin card renders both detail tiers" do
    base = %{
      instance_name: "Test Match",
      date: "2026-08-11",
      battles: %{
        engagements: 2,
        factions: [%{faction: "synelle", wins: 2, losses: 0}, %{faction: "ark", wins: 0, losses: 2}],
        records: [%{name: "Kalid", faction: "synelle", wins: 2, losses: 0}]
      },
      spoils: %{
        conquests: %{count: 0, names: []},
        bombards: %{count: 2, systems: 1, names: ["Boras"], buildings: 5, population: 120},
        pillages: %{count: 1, names: [%{name: "Amorin", count: 1}], credits: 900, technology: 0, ideology: 0}
      },
      game_data: game_data(),
      ownership: ownership(),
      highlights: [%{system_id: 1, kind: :bombard, label: "One"}],
      legend: [{:bombard, "Bombarded"}]
    }

    detailed = Cards.bulletin(base)
    assert_svg(detailed)
    assert detailed =~ "Kalid"
    assert detailed =~ "Boras"
    assert detailed =~ "900 credits"

    vague =
      Cards.bulletin(%{
        base
        | battles: %{base.battles | records: []},
          spoils: %{
            conquests: %{count: 1, names: nil},
            bombards: %{count: 2, systems: 1, names: nil, buildings: 0, population: 0},
            pillages: %{count: 1, names: nil, credits: 0, technology: 0, ideology: 0}
          },
          highlights: [],
          legend: []
      })

    assert_svg(vague)
    refute vague =~ "Kalid"
    refute vague =~ "Boras"
    # zero-sum damage/loot lines are omitted, not shown as false zeros
    refute vague =~ "0 buildings damaged"
  end

  test "daily and victory cards render" do
    daily =
      Cards.daily(%{
        date: "2026-08-08",
        challenge_name: "Charter of Prosperity",
        winners: [%{rank: 1, name: "Tremes", score: "290s to spare"}],
        next: %{
          name: "The Destroyer's Blueprint",
          description: "A race: research the Destroyer patent.",
          mutators: [%{polarity: :positive, name: "Joyful Industry"}, %{polarity: :negative, name: "Luddite Backlash"}]
        }
      })

    assert_svg(daily)
    assert daily =~ "Tremes"
    assert daily =~ "Luddite Backlash"

    victory =
      Cards.victory(%{
        instance_name: "Test Match",
        winner: "ark",
        victory_type_label: "Victory track complete",
        vp: %{
          win_target: 14,
          rows: [
            %{faction: "ark", vp: 14, gained: [14], lost: []},
            %{faction: "synelle", vp: 6, gained: [], lost: []}
          ]
        },
        totals: [%{faction: "ark", systems: 41, dominions: 49, players: 8}]
      })

    assert_svg(victory)
    assert victory =~ "A.R.K. CONQUERS THE GALAXY"
    assert victory =~ "FINAL STANDINGS"
  end
end

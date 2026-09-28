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

  describe "digest territory panel" do
    defp digest_with(events) do
      %{
        instance_name: "Test Match",
        window_label: "W",
        game_data: game_data(),
        ownership: ownership(),
        highlights: [],
        legend: [],
        territory: RC.Discord.DigestData.territory_groups(events),
        vp: %{win_target: 14, rows: [%{faction: "myrmezir", vp: 3, gained: [], lost: []}]},
        totals: [%{faction: "myrmezir", systems: 5, dominions: 2}, %{faction: "tetrarchy", systems: 9, dominions: 4}]
      }
    end

    defp owned(key, count, extra, prefix) do
      for i <- 1..count, do: {key, Map.merge(%{system_name: "#{prefix}#{i}", system_id: i}, extra)}
    end

    test "up to eight changes stay a one-line-per-change list" do
      svg = Cards.digest(digest_with(owned("news.system.abandoned", 8, %{faction: "myrmezir"}, "Ab")))

      assert_svg(svg)
      assert svg =~ "Ab8 — system abandoned"
      refute svg =~ "SYSTEMS LOST"
    end

    test "more than eight changes fold into category columns" do
      events =
        owned("news.system.abandoned", 5, %{faction: "myrmezir"}, "Ab") ++
          owned("news.dominion.liberated", 6, %{faction: "myrmezir"}, "Lib") ++
          [{"news.sector.lost", %{faction: nil, prev_faction: "myrmezir", sector_name: "Zoggan", sector_id: 5}}]

      svg = Cards.digest(digest_with(events))

      assert_svg(svg)
      assert svg =~ "SYSTEMS LOST"
      assert svg =~ "DOMINIONS LOST"
      assert svg =~ "5 abandoned"
      assert svg =~ "6 liberated"
      assert svg =~ ">Ab5</text>"
      assert svg =~ ">Lib6</text>"
      assert svg =~ "SECTORS"
      assert svg =~ "Zoggan"
      refute svg =~ "— system abandoned"
      # the body can never paint over the panels below it
      assert svg =~ ~s(clip-path="url(#territory-clip-)
    end

    test "past thirty, abandonments and liberations become counts only" do
      events =
        owned("news.system.abandoned", 12, %{faction: "myrmezir"}, "Ab") ++
          owned("news.conquest", 20, %{faction: "tetrarchy", prev_faction: "myrmezir"}, "Cq")

      svg = Cards.digest(digest_with(events))

      assert_svg(svg)
      assert svg =~ "12 abandoned"
      assert svg =~ "20 conquered"
      assert svg =~ "ABANDONED/LIBERATED AS COUNTS"
      refute svg =~ ">Ab1</text>"
      assert svg =~ ">Cq1</text>"
    end

    test "still past thirty after dropping voluntary changes, names truncate with +N more" do
      events = owned("news.conquest", 45, %{faction: "tetrarchy", prev_faction: "myrmezir"}, "Cq")
      svg = Cards.digest(digest_with(events))

      assert_svg(svg)
      assert svg =~ "45 conquered"
      assert svg =~ ~r/\+\d+ more/
      refute svg =~ ">Cq45</text>"
      # the gaining side has no voluntary entries to demote
      refute svg =~ "ABANDONED/LIBERATED AS COUNTS"
    end
  end

  describe "animated digest frames" do
    defp animated_digest do
      %{
        instance_name: "Test Match",
        window_label: "W",
        game_data: game_data(),
        ownership: ownership(),
        highlights: [
          %{system_id: 1, kind: :gained, label: "One", faction: "synelle"},
          %{system_id: 2, kind: :conquest, label: "Two", faction: "ark"}
        ],
        sector_pulses: [%{sector_id: 1, faction: "ark"}],
        legend: [],
        territory: [],
        vp: %{
          win_target: 14,
          rows: [
            %{faction: "synelle", vp: 3, gained: [2, 3], lost: []},
            %{faction: "ark", vp: 1, gained: [], lost: [2]}
          ]
        },
        totals: []
      }
    end

    test "static cards carry no motion; frames transform markers and pulse sectors" do
      data = animated_digest()
      static = Cards.digest(data)
      frame = Cards.digest(data, t: 0.2)

      assert_svg(frame)
      refute static =~ "rotate("
      assert frame =~ "rotate("
      assert frame =~ "stroke-dasharray"
      assert frame != static
      # the pulse overlay only exists on frames
      assert length(String.split(frame, "<polygon")) > length(String.split(static, "<polygon"))
    end

    test "digest_animated?/1 only when something moves" do
      data = animated_digest()
      assert Cards.digest_animated?(data)

      still = %{
        data
        | highlights: [],
          sector_pulses: [],
          vp: %{win_target: 14, rows: [%{faction: "ark", vp: 1, gained: [], lost: []}]}
      }

      refute Cards.digest_animated?(still)
      assert Cards.digest_animated?(%{still | sector_pulses: [%{sector_id: 1, faction: "ark"}]})
      refute Cards.digest_animated?(Map.delete(still, :vp))
    end

    test "the loop is seamless: stars spin by a multiple of 72° and pulses return to rest" do
      alias RC.Discord.Render.Motion

      assert {+0.0, +0.0} = Motion.spin(0.0)
      {end_angle, _} = Motion.spin(0.999)
      assert rem(round(end_angle), 72) == 0
      assert Motion.pulse(0.0) == 0.0
      assert_in_delta Motion.pulse(0.999), 0.0, 0.001
      assert_in_delta Motion.breathe(0.0, 0.2), 1.0, 1.0e-9
    end

    @tag timeout: 120_000
    test "card_image/3 encodes a looping GIF via libvips, and a PNG when static" do
      alias RC.Discord.Render

      if Render.available?() do
        data = animated_digest()
        render = fn t -> Cards.digest(data, t: t) end

        assert {:ok, <<"GIF89a", _::binary>> = gif, "digest.gif"} =
                 Render.card_image(render, "digest", gif_opts: [frames: 4, width: 400])

        # NETSCAPE2.0 application extension = infinite loop
        assert gif =~ "NETSCAPE2.0"

        assert {:ok, <<0x89, "PNG", _::binary>>, "digest.png"} = Render.card_image(render, "digest", animated: false)
      else
        assert {:error, :rasterizer_unavailable} = Render.rasterize_gif(fn _t -> "" end, frames: 1)
      end
    end
  end

  describe "animated bulletin, daily challenge and victory frames" do
    test "bulletin: the battle bar wipes in from a full first frame; spoils markers move" do
      data = %{
        instance_name: "Test Match",
        date: "2026-08-11",
        battles: %{
          engagements: 3,
          factions: [%{faction: "synelle", wins: 2, losses: 1}, %{faction: "ark", wins: 1, losses: 2}],
          records: []
        },
        spoils: %{
          conquests: %{count: 0, names: []},
          bombards: %{count: 1, systems: 1, names: ["One"], buildings: 0, population: 0},
          pillages: %{count: 1, names: [%{name: "Two", count: 1}], credits: 0, technology: 0, ideology: 0}
        },
        game_data: game_data(),
        ownership: ownership(),
        highlights: [%{system_id: 1, kind: :bombard, label: "One"}, %{system_id: 2, kind: :pillage, label: "Two"}]
      }

      static = Cards.bulletin(data)
      refute static =~ "battle-bar-wipe"

      full = Cards.bulletin(data, t: 0.0)
      assert_svg(full)
      assert full =~ ~s(<clipPath id="battle-bar-wipe"><rect x="56" y="174" width="776.00")

      # late in the loop the bar is mid-wipe
      mid = Cards.bulletin(data, t: 0.85)
      [_, width] = Regex.run(~r/id="battle-bar-wipe"><rect x="56" y="174" width="([\d.]+)"/, mid)
      assert String.to_float(width) < 776

      assert Cards.bulletin_animated?(data)
      refute Cards.bulletin_animated?(%{data | battles: %{data.battles | engagements: 0}, highlights: []})
    end

    test "daily: the medal glint visits gold, then silver, then bronze" do
      data = %{
        date: "2026-08-11",
        challenge_name: "Rush",
        winners: [
          %{rank: 1, name: "A", score: "1"},
          %{rank: 2, name: "B", score: "2"},
          %{rank: 3, name: "C", score: "3"}
        ],
        next: %{name: "Next", description: "desc", mutators: []}
      }

      refute Cards.daily(data) =~ "medal-glint"
      refute Cards.daily(data, t: 0.0) =~ "medal-glint"
      assert Cards.daily(data, t: 0.1) =~ "medal-glint-1"
      assert Cards.daily(data, t: 0.25) =~ "medal-glint-2"
      assert Cards.daily(data, t: 0.38) =~ "medal-glint-3"
      refute Cards.daily(data, t: 0.8) =~ "medal-glint"
    end

    test "victory: turning ring, glow, and a shimmer along the winner's stars" do
      data = %{
        instance_name: "Test Match",
        winner: "ark",
        victory_type_label: "Conquest",
        vp: %{
          win_target: 14,
          rows: [%{faction: "ark", vp: 14, gained: [14], lost: []}, %{faction: "synelle", vp: 6, gained: [], lost: []}]
        },
        totals: []
      }

      static = Cards.victory(data)
      refute static =~ "victory-glow"

      frame = Cards.victory(data, t: 0.2)
      assert_svg(frame)
      assert frame =~ "victory-glow"
      assert frame =~ ~s(stroke-dasharray=)
      # the shimmer crest brightens some of the winner's banked stars
      assert frame =~ "fill-opacity="
    end
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

  test "player profile card renders stats, favorites, and the avatar embed" do
    data = %{
      name: "Alrua",
      full_name: "Grand Archon Alrua",
      description: "A maxim & a <test>",
      # any JPEG bytes will do for the data-URI path — validity matters
      # only to the rasterizer, which this test doesn't invoke
      avatar_jpeg: <<0xFF, 0xD8, 0xFF, 0xE0, 0, 0, 0, 0>>,
      favorite_faction: "cardan",
      favorite_icon: "marker/flag",
      stats: %{
        legacy: %{wins: 2, participations: 5},
        daily: %{gold: 3, silver: 7, bronze: 4, completed: 38, played: 51},
        factions: %{"cardan" => 9, "tetrarchy" => 3}
      }
    }

    svg = Cards.player_profile(data)

    assert_svg(svg)
    assert svg =~ "ALRUA"
    assert svg =~ "PLAYER PROFILE"
    assert svg =~ "data:image/jpeg;base64,"
    assert svg =~ "5 official matches entered"
    assert svg =~ "38 completed"
    # user text is escaped
    assert svg =~ "A maxim &amp; a &lt;test&gt;"
    # favorite faction tints the accent strip and the icon badge
    assert svg =~ "#8e60bf"

    # no avatar, no favorites, empty stats — placeholder path
    empty =
      Cards.player_profile(%{
        data
        | avatar_jpeg: nil,
          favorite_faction: nil,
          favorite_icon: nil,
          stats: %{
            legacy: %{wins: 0, participations: 0},
            daily: %{gold: 0, silver: 0, bronze: 0, completed: 0, played: 0},
            factions: %{}
          }
      })

    assert_svg(empty)
    refute empty =~ "data:image/jpeg"
  end
end

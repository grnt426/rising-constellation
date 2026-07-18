defmodule RC.Discord.BulletinTest do
  @moduledoc """
  Pure tests for the daily-summary bulletin: seeded slot selection
  (deterministic, in-window, salt-sensitive) and the two rendering
  tiers (vague for >2 factions, detailed for 2).
  """

  use ExUnit.Case, async: true

  alias RC.Discord.Bulletin

  @salt "2026-07-01 12:34:56.789012Z"

  defp event(kind, payload), do: %RC.Discord.BulletinEvent{kind: kind, payload: payload}

  defp battle(attacker, defender, winner, extra \\ %{}) do
    event(
      "battle",
      Map.merge(
        %{
          "attacker_faction" => attacker,
          "defender_faction" => defender,
          "winner" => winner,
          "winners" => [],
          "losers" => []
        },
        extra
      )
    )
  end

  describe "seeded slots" do
    test "post slot is deterministic and lands on a 30-minute mark between 12:00 and 14:00 ET" do
      for day <- 1..28 do
        date = Date.new!(2026, 7, day)
        dt = Bulletin.post_time(date, @salt)

        assert dt == Bulletin.post_time(date, @salt)
        assert dt.time_zone == "America/New_York"
        assert dt.minute in [0, 30]
        assert dt.hour in 12..14
        refute dt.hour == 14 and dt.minute == 30
      end
    end

    test "cutoff slot lands on a 30-minute mark between 07:00 and 11:00 ET" do
      for day <- 1..28 do
        date = Date.new!(2026, 7, day)
        dt = Bulletin.cutoff_time(date, @salt)

        assert dt.minute in [0, 30]
        assert dt.hour in 7..11
        refute dt.hour == 11 and dt.minute == 30
      end
    end

    test "different salts and different dates shuffle the slots" do
      dates = for day <- 1..28, do: Date.new!(2026, 7, day)

      # Across a month the slot should not be constant (5 possible
      # posting slots, 28 days — a stuck implementation returns 1).
      post_slots = dates |> Enum.map(&Bulletin.post_time(&1, @salt).hour) |> Enum.uniq()
      assert length(post_slots) > 1

      # And two different matches on the same date generally differ;
      # assert at least one differing day across the month.
      assert Enum.any?(dates, fn date ->
               Bulletin.cutoff_time(date, @salt) != Bulletin.cutoff_time(date, "other-salt")
             end)
    end
  end

  describe "render/4 — vague tier (more than two factions)" do
    test "battles show per-faction records and ratios but no players or systems" do
      events = [
        battle("ark", "cardan", "attackers", %{
          "winners" => [%{"name" => "Nova", "faction" => "ark"}],
          "losers" => [%{"name" => "Kael", "faction" => "cardan"}],
          "system_name" => "Mirba"
        }),
        battle("ark", "myrmezir", "attackers"),
        battle("cardan", "ark", "attackers")
      ]

      out = Bulletin.render("Legacy One", 3, events, [])

      assert out =~ "**Battles**: 3 engagements"
      assert out =~ "A.R.K. 2W 1L (67%)"
      refute out =~ "Nova"
      refute out =~ "Mirba"
      refute out =~ "Records:"
    end

    test "conquests, bombards, and pillages show counts only" do
      events = [
        event("conquest", %{"faction" => "ark", "system_name" => "Mirba"}),
        event("conquest", %{"faction" => "ark", "system_name" => "Vega"}),
        event("raid", %{"faction" => "cardan", "system_name" => "Nubrae Prime"}),
        event("loot", %{"faction" => "myrmezir", "system_name" => "Kelvaan"})
      ]

      out = Bulletin.render("Legacy One", 3, events, [])

      assert out =~ "**Conquests**: <:ark:1521144064374739145>A.R.K. 2"
      assert out =~ "**Bombards**: <:cardan:1521144119605329961>Cardan 1"
      assert out =~ "**Pillages**: <:myrmezir:1521144307728519208>Myrmezir 1"
      refute out =~ "Mirba"
      refute out =~ "Nubrae Prime"
    end

    test "empty sections render as none and firsts section is omitted when empty" do
      out = Bulletin.render("Legacy One", 3, [], [])

      assert out =~ "**Battles**: none reported."
      assert out =~ "**Conquests**: none."
      assert out =~ "**Bombards**: none."
      assert out =~ "**Pillages**: none."
      refute out =~ "**Firsts**"
    end

    test "firsts always name the player, even in the vague tier" do
      lines = [Bulletin.first_line("colonize.first", "Nova", "ark")]
      out = Bulletin.render("Legacy One", 3, [], lines)

      assert out =~ "**Firsts**: Nova (A.R.K.) was first to found a colony."
    end

    test "draws count toward the total but nobody's record" do
      events = [battle("ark", "cardan", "draw")]
      out = Bulletin.render("Legacy One", 3, events, [])

      assert out =~ "1 engagement (1 inconclusive)"
      refute out =~ "1W"
    end
  end

  describe "render/4 — detailed tier (two factions)" do
    test "battles include per-player records" do
      events = [
        battle("ark", "cardan", "attackers", %{
          "winners" => [%{"name" => "Nova", "faction" => "ark"}],
          "losers" => [%{"name" => "Kael", "faction" => "cardan"}]
        }),
        battle("cardan", "ark", "attackers", %{
          "winners" => [%{"name" => "Kael", "faction" => "cardan"}],
          "losers" => [%{"name" => "Nova", "faction" => "ark"}]
        })
      ]

      out = Bulletin.render("Duel", 2, events, [])

      assert out =~ "Records:"
      assert out =~ "Nova <:ark:1521144064374739145> 1W 1L"
      assert out =~ "Kael <:cardan:1521144119605329961> 1W 1L"
    end

    test "strike sections name systems and collapse repeats" do
      events = [
        event("raid", %{"faction" => "cardan", "system_name" => "Vega"}),
        event("raid", %{"faction" => "cardan", "system_name" => "Vega"}),
        event("raid", %{"faction" => "cardan", "system_name" => "Mirba"}),
        event("conquest", %{"faction" => "ark", "system_name" => "Kelvaan"})
      ]

      out = Bulletin.render("Duel", 2, events, [])

      assert out =~ "Cardan bombarded Vega x2, Mirba."
      assert out =~ "A.R.K. took Kelvaan."
    end
  end

  describe "first_line/3" do
    test "known first keys read as deeds" do
      assert Bulletin.first_line("dominion.first", "Nova", "ark") =~ "was first to take a dominion"

      assert Bulletin.first_line("building.monument_dome.first", "Nova", nil) ==
               "Nova was first to complete a Monolith."

      assert Bulletin.first_line("ship.capital.first", nil, "cardan") ==
               "Cardan was first to field a capital ship."

      assert Bulletin.first_line("income.technology_100.first", "Kael", nil) =~
               "raise technology output above 100"

      assert Bulletin.first_line("faction.erased_25.first", nil, "synelle") =~ "field 25 Erased"
    end

    test "unknown keys degrade to humanized text and missing names fall back" do
      line = Bulletin.first_line("weird.new_thing.first", nil, nil)
      assert line =~ "Someone was first to"
      refute line =~ "—"
    end
  end

  describe "message hygiene" do
    test "the bulletin contains no em-dashes" do
      events = [battle("ark", "cardan", "attackers")]
      lines = [Bulletin.first_line("colonize.first", "Nova", "ark")]

      refute Bulletin.render("Legacy One", 3, events, lines) =~ "—"
    end

    test "stays under Discord's 2000-char cap even when flooded" do
      events =
        for i <- 1..300 do
          event("raid", %{"faction" => "cardan", "system_name" => "System #{i}"})
        end

      out = Bulletin.render("Flood", 2, events, [])
      assert String.length(out) <= 1990
    end
  end
end

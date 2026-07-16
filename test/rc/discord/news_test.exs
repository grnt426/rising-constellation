defmodule RC.Discord.NewsTest do
  @moduledoc """
  Pure-renderer tests for the Discord news relay. No bot, no gateway —
  `RC.Discord.News.render/2` is a pure function of (bulletin_key,
  payload), and the #news channel is all-factions, so these tests also
  pin the fog-of-war guarantees (no attacker identity on covert ops).
  """

  use ExUnit.Case, async: true

  alias RC.Discord.News

  @base %{
    faction: "tetrarchy",
    system_name: "Mirba",
    system_id: 1,
    sector_id: 0,
    sector_name: "Nubrae"
  }

  describe "render/2 — faction icon handling" do
    test "appends the faction's guild emoji to its display name" do
      line = News.render("news.colonize.first", @base)
      assert line =~ "Tetrarchy <:tetrarchy:1521144218742034463>"
      assert line =~ "Mirba"
    end

    test "every playable faction resolves to name + emoji" do
      assert News.faction_display("ark") == "A.R.K. <:ark:1521144064374739145>"
      assert News.faction_display("cardan") == "Cardan <:cardan:1521144119605329961>"
      assert News.faction_display("myrmezir") == "Myrmezir <:myrmezir:1521144307728519208>"
      assert News.faction_display("synelle") == "Synelectic Federation <:synelle:1521144259015868577>"
      assert News.faction_display("tetrarchy") == "Tetrarchy <:tetrarchy:1521144218742034463>"
    end

    test "unknown faction key degrades to the raw key, no emoji" do
      assert News.faction_display("neutral") == "neutral"
      assert News.faction_display(nil) == "An unknown power"
    end
  end

  describe "render/2 — public-tier wording" do
    test "battle names only the sector, never the belligerents" do
      payload = Map.merge(@base, %{attacker_faction: "synelle", defender_faction: "myrmezir", winner: "attackers"})
      line = News.render("news.battle", payload)
      assert line == "A small skirmish took place in sector Nubrae."
      refute line =~ "ynelle"
      refute line =~ "yrmezir"
    end

    test "assassination names the victim but never a perpetrator" do
      payload = Map.merge(@base, %{target_name: "Gov Karsis", victim_faction: "tetrarchy"})
      line = News.render("news.agent.assassinated", payload)
      assert line =~ "Gov Karsis"
      assert line =~ "no suspects"
      refute line =~ "Tetrarchy"
    end

    test "conversion reads as a resignation, no seducer" do
      payload = Map.merge(@base, %{target_name: "Gov Karsis", victim_faction: "tetrarchy"})
      line = News.render("news.agent.converted", payload)
      assert line =~ "renounced their post"
      refute line =~ "Tetrarchy"
    end

    test "building and ship keys map to display names" do
      assert News.render("news.building.first", Map.put(@base, :building, "monument_dome")) =~ "Monolith"

      assert News.render("news.ship.capital", Map.put(@base, :ship, "capital_2")) =~
               "employs the Cruiser to mark a new age of ship warfare"
    end

    test "summaries interpolate counts" do
      assert News.render("news.battle.summary", Map.put(@base, :count, 7)) =~ "At least 7 more engagements"
      assert News.render("news.raid.summary", Map.put(@base, :count, 4)) =~ "At least 4 more strikes"
    end

    test "corps milestones render for all three agent types" do
      assert News.render("news.faction.erased", @base) =~ "shadow organization"
      assert News.render("news.faction.navarchs", @base) =~ "corps of Navarchs"
      assert News.render("news.faction.siderians", @base) =~ "circle of Siderians"
    end

    test "sector flips name both factions with emoji" do
      payload = Map.merge(@base, %{faction: "ark", prev_faction: "myrmezir"})
      line = News.render("news.sector.flipped", payload)

      assert line ==
               "A.R.K. <:ark:1521144064374739145> has taken control of sector Nubrae " <>
                 "from Myrmezir <:myrmezir:1521144307728519208>."

      assert News.render("news.sector.claimed", Map.put(@base, :faction, "cardan")) ==
               "Cardan <:cardan:1521144119605329961> has taken control of sector Nubrae."

      assert News.render("news.sector.lost", Map.merge(@base, %{faction: nil, prev_faction: "synelle"})) ==
               "Synelectic Federation <:synelle:1521144259015868577> has lost control of sector Nubrae."
    end

    test "economic firsts" do
      assert News.render("news.income.first", Map.put(@base, :resource, "technology")) =~
               "raise its technology output above 100"

      assert News.render("news.credit.first", @base) =~ "ten million credits"
      assert News.render("news.doctrine.first", @base) =~ "fifteen lexes"
    end
  end

  describe "battle_rollup/2" do
    test "single skirmish with participants names victor and vanquished" do
      records = %{{"Kholvax", "synelle"} => {1, 0}, {"Dan", "myrmezir"} => {0, 1}}

      assert News.battle_rollup(%{"Nubrae" => 1}, records) ==
               "A skirmish took place in sector Nubrae — " <>
                 "Kholvax <:synelle:1521144259015868577> defeated Dan <:myrmezir:1521144307728519208>."
    end

    test "single skirmish without participant data keeps the anonymous line" do
      assert News.battle_rollup(%{"Nubrae" => 1}) == "A small skirmish took place in sector Nubrae."
    end

    test "repeat fighting in one sector shows the tally with window records" do
      records = %{{"Kholvax", "synelle"} => {2, 0}, {"Dan", "myrmezir"} => {1, 2}}

      assert News.battle_rollup(%{"Nubrae" => 3}, records) ==
               "Fleet engagements reported in sector Nubrae ×3 — " <>
                 "Kholvax <:synelle:1521144259015868577> 2W · Dan <:myrmezir:1521144307728519208> 1W 2L."
    end

    test "multi-sector fighting sorts sectors by count and players by wins" do
      counts = %{"Kelvaan" => 1, "Nubrae" => 3, "Aldre" => 3}
      records = %{{"Kaya", "ark"} => {0, 2}, {"Kholvax", "synelle"} => {3, 1}}

      assert News.battle_rollup(counts, records) ==
               "Fleet engagements reported: sector Aldre ×3, sector Nubrae ×3, sector Kelvaan ×1 — " <>
                 "Kholvax <:synelle:1521144259015868577> 3W 1L · Kaya <:ark:1521144064374739145> 2L."
    end

    test "unknown faction key renders the player without an emoji" do
      records = %{{"Bot77", "neutral"} => {1, 0}, {"Dan", "myrmezir"} => {0, 1}}

      assert News.battle_rollup(%{"Nubrae" => 1}, records) =~ "Bot77 defeated"
    end
  end

  describe "post_async/3" do
    test "is a silent no-op when the relay is not running" do
      refute Process.whereis(RC.Discord.NewsRelay)
      assert News.post_async(1, "news.battle", %{sector_name: "Nubrae"}) == :ok
    end
  end

  describe "render/2 — robustness" do
    test "unknown bulletin kinds return nil (no Discord post)" do
      assert News.render("news.something.new", @base) == nil
      assert News.render("garbage", %{}) == nil
    end

    test "missing payload fields degrade the sentence, never raise" do
      line = News.render("news.conquest", %{})
      assert line =~ "an uncharted region"
      assert line =~ "An unknown power"
    end
  end
end

defmodule RC.Discord.NewsTest do
  @moduledoc """
  Pure-renderer tests for the Discord news relay. No bot, no gateway —
  `RC.Discord.News.render/2` is a pure function of (bulletin_key,
  payload). These tests pin the immediate-feed policy (player decision
  2026-07): only publicly-visible map events post instantly; battles,
  raids, pillages, conquests, covert ops, and firsts are withheld from
  the instant feed (they ship via the daily bulletin instead).
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
    test "appends the faction's game-guild emoji to its display name" do
      line = News.render("discord.colonized", @base)
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

  describe "render/2 — immediate feed" do
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

    test "every colonization posts with the system named" do
      assert News.render("discord.colonized", Map.put(@base, :faction, "ark")) ==
               "A.R.K. <:ark:1521144064374739145> has colonized Mirba."
    end

    test "dominion flips name the system and the displaced faction" do
      assert News.render("discord.dominion", @base) =~ "has taken Mirba as a dominion"

      line = News.render("discord.dominion", Map.put(@base, :prev_faction, "cardan"))
      assert line =~ "has taken the dominion of Mirba"
      assert line =~ "Cardan"
    end

    test "victory point changes announce rises and falls" do
      rise = News.render("discord.vp_changed", %{faction: "ark", vp: 12, prev_vp: 10})
      assert rise =~ "has risen to 12 victory points"

      fall = News.render("discord.vp_changed", %{faction: "ark", vp: 7, prev_vp: 10})
      assert fall =~ "has fallen to 7 victory points"
    end

    test "dominion liberation and system abandonment still post" do
      assert News.render("news.dominion.liberated", @base) =~ "freely liberated"
      assert News.render("news.system.abandoned", @base) =~ "has abandoned Mirba"
    end
  end

  describe "render/2 — withheld from the instant feed" do
    test "battles never post immediately" do
      payload = Map.merge(@base, %{attacker_faction: "synelle", winner: "attackers"})
      assert News.render("news.battle", payload) == nil
      assert News.render("news.battle.summary", Map.put(@base, :count, 7)) == nil
    end

    test "raids and conquests never post immediately" do
      assert News.render("news.raid", @base) == nil
      assert News.render("news.raid.summary", Map.put(@base, :count, 4)) == nil
      assert News.render("news.conquest", @base) == nil
    end

    test "covert ops stay off Discord entirely" do
      payload = Map.merge(@base, %{target_name: "Gov Karsis"})
      assert News.render("news.agent.assassinated", payload) == nil
      assert News.render("news.agent.converted", payload) == nil
    end

    test "galaxy firsts are daily-bulletin material, not instant posts" do
      assert News.render("news.colonize.first", @base) == nil
      assert News.render("news.dominion.first", @base) == nil
      assert News.render("news.building.first", Map.put(@base, :building, "monument_dome")) == nil
      assert News.render("news.ship.capital", Map.put(@base, :ship, "capital_2")) == nil
      assert News.render("news.income.first", Map.put(@base, :resource, "technology")) == nil
      assert News.render("news.credit.first", @base) == nil
      assert News.render("news.doctrine.first", @base) == nil
      assert News.render("news.faction.erased", @base) == nil
      assert News.render("news.faction.navarchs", @base) == nil
      assert News.render("news.faction.siderians", @base) == nil
    end
  end

  describe "victory_embed/4" do
    test "community embed uses community-guild emoji and the spec wording" do
      embed = News.victory_embed("The Shattered Reach", :cardan, 14, :community)

      assert embed.title == "Congrats to Cardan!"

      assert embed.description ==
               "The Shattered Reach has concluded in a victory with 14 VP " <>
                 "in favor of <:cardan:1528019517744091136>Cardan."
    end

    test "game embed uses the Legacy-guild emoji" do
      embed = News.victory_embed("The Shattered Reach", "ark", 15, :game)

      assert embed.title == "Congrats to A.R.K.!"
      assert embed.description =~ "<:ark:1521144064374739145>A.R.K."
      assert embed.description =~ "15 VP"
    end

    test "victory copy contains no em-dashes" do
      embed = News.victory_embed("The Shattered Reach", :synelle, 14, :community)
      refute embed.title =~ "—"
      refute embed.description =~ "—"
    end
  end

  describe "post_async/3" do
    test "is a silent no-op when the relay is not running" do
      refute Process.whereis(RC.Discord.NewsRelay)
      assert News.post_async(1, "news.battle", %{sector_name: "Nubrae"}) == :ok
    end

    test "victory post is a silent no-op when the relay is not running" do
      refute Process.whereis(RC.Discord.NewsRelay)
      assert News.post_victory_async(1, %{winner: :ark, victory_points: 14}) == :ok
    end
  end

  describe "render/2 — robustness" do
    test "unknown bulletin kinds return nil (no Discord post)" do
      assert News.render("news.something.new", @base) == nil
      assert News.render("garbage", %{}) == nil
    end

    test "missing payload fields degrade the sentence, never raise" do
      line = News.render("discord.colonized", %{})
      assert line =~ "an uncharted system"
      assert line =~ "An unknown power"
    end
  end
end

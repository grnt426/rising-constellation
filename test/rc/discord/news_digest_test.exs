defmodule RC.Discord.NewsDigestTest do
  @moduledoc """
  Pure-renderer tests for the batched news digests. No bot, no
  gateway — `map_digest/3` and `community_digest/2` are pure functions
  of the bucket's `{bulletin_key, payload}` event list. These pin the
  batching policy (user decision 2026-08): Legacy #news batches map
  ownership changes into 5-minute buckets with sector-control changes
  riding along; community #game-news gets a 6-hour digest with running
  totals by faction and by sector.
  """

  use ExUnit.Case, async: true

  alias RC.Discord.News

  @colonized_mirba {"discord.colonized",
                    %{faction: "tetrarchy", system_name: "Mirba", system_id: 1, sector_name: "Nubrae"}}
  @colonized_vega {"discord.colonized",
                   %{faction: "tetrarchy", system_name: "Vega", system_id: 2, sector_name: "Nubrae"}}
  @colonized_ark {"discord.colonized",
                  %{faction: "ark", system_name: "Kel", system_id: 3, sector_name: "Ryfe"}}
  @dominion {"discord.dominion",
             %{faction: "ark", system_name: "Tyr", system_id: 4, sector_name: "Ryfe", prev_faction: nil}}
  @sector_claimed {"news.sector.claimed", %{faction: "tetrarchy", sector_name: "Nubrae", sector_id: 9}}
  @abandoned {"news.system.abandoned", %{faction: "cardan", system_name: "Wex", system_id: 5, sector_name: "Kolua"}}
  @vp_ark_10 {"discord.vp_changed", %{faction: "ark", vp: 10, prev_vp: 8}}
  @vp_ark_12 {"discord.vp_changed", %{faction: "ark", vp: 12, prev_vp: 10}}
  @vp_tet_7 {"discord.vp_changed", %{faction: "tetrarchy", vp: 7, prev_vp: 9}}

  describe "map_key?/1 and vp_key?/1" do
    test "ownership and sector kinds are map keys; VP is its own kind" do
      for key <- [
            "discord.colonized",
            "discord.dominion",
            "news.dominion.liberated",
            "news.system.abandoned",
            "news.sector.flipped",
            "news.sector.claimed",
            "news.sector.lost"
          ] do
        assert News.map_key?(key)
      end

      refute News.map_key?("discord.vp_changed")
      assert News.vp_key?("discord.vp_changed")
      refute News.vp_key?("discord.colonized")
    end
  end

  describe "map_digest/3 — Legacy 5-minute bucket" do
    test "a single event keeps the classic one-line format" do
      assert News.map_digest("Alpha", [@colonized_mirba]) ==
               "📰 **Alpha**: Tetrarchy <:tetrarchy:1521144218742034463> has colonized Mirba."
    end

    test "multiple events render one bulleted line per story" do
      digest = News.map_digest("Alpha", [@colonized_mirba, @dominion])

      assert digest =~ "📰 **Alpha**:\n"
      assert digest =~ "• Tetrarchy <:tetrarchy:1521144218742034463> has colonized Mirba."
      assert digest =~ "• A.R.K. <:ark:1521144064374739145> has taken Tyr as a dominion."
    end

    test "same-faction colonizations aggregate into one roll-up line" do
      digest = News.map_digest("Alpha", [@colonized_mirba, @colonized_vega, @colonized_ark])

      assert digest =~ "has colonized 2 systems: Mirba, Vega."
      assert digest =~ "A.R.K. <:ark:1521144064374739145> has colonized Kel."
    end

    test "sector-control changes ride in the same bucket, listed first" do
      digest = News.map_digest("Alpha", [@colonized_mirba, @sector_claimed])

      [_header, first_bullet | _] = String.split(digest, "\n")
      assert first_bullet =~ "has taken control of sector Nubrae"
      assert digest =~ "has colonized Mirba."
    end
  end

  describe "community_digest/2 — community 6-hour bucket" do
    test "uses community-guild emoji, not the game-guild uploads" do
      digest = News.community_digest("Alpha", [@colonized_ark])

      assert digest =~ "<:ark:1528019447812456519>"
      refute digest =~ "<:ark:1521144064374739145>"
    end

    test "carries the header, stories, VP track, and running totals" do
      events = [@colonized_mirba, @colonized_vega, @dominion, @abandoned, @vp_ark_10, @vp_tet_7]
      digest = News.community_digest("Alpha", events)

      assert digest =~ "📰 **Alpha** — rolling 6-hour digest"
      assert digest =~ "has colonized 2 systems: Mirba, Vega."
      assert digest =~ "has abandoned Wex."
      assert digest =~ "Victory track:"
      assert digest =~ "**System & dominion changes** (running total)"
      assert digest =~ "By faction:"
      assert digest =~ "By sector: Nubrae 2 · Ryfe 1 · Kolua 1"
    end

    test "VP line shows only the latest value per faction, highest first" do
      digest = News.community_digest("Alpha", [@colonized_mirba, @vp_ark_10, @vp_ark_12, @vp_tet_7])

      assert digest =~ "at 12 VP"
      refute digest =~ "at 10 VP"

      [vp_line] = for line <- String.split(digest, "\n"), line =~ "Victory track", do: line
      assert vp_line =~ ~r/A\.R\.K\..* at 12 VP.*Tetrarchy.* at 7 VP/
    end

    test "running totals count ownership changes only, not sector flips" do
      digest = News.community_digest("Alpha", [@colonized_mirba, @sector_claimed])

      [faction_line] = for line <- String.split(digest, "\n"), line =~ "By faction", do: line
      assert faction_line =~ "Tetrarchy 1"
    end

    test "a VP-only bucket renders no totals section" do
      digest = News.community_digest("Alpha", [@vp_ark_10])

      assert digest =~ "Victory track:"
      refute digest =~ "running total"
    end

    test "totals tolerate payloads with no sector name" do
      bare = {"discord.colonized", %{faction: "ark", system_name: "Kel"}}
      digest = News.community_digest("Alpha", [bare])

      assert digest =~ "By sector: uncharted space 1"
    end
  end

  describe "render/3 — guild-aware emoji" do
    test "the same bulletin renders with each guild's emoji uploads" do
      {key, payload} = @colonized_ark

      assert News.render(key, payload, :game) =~ "<:ark:1521144064374739145>"
      assert News.render(key, payload, :community) =~ "<:ark:1528019447812456519>"
    end
  end
end

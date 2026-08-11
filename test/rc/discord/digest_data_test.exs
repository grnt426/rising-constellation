defmodule RC.Discord.DigestDataTest do
  use ExUnit.Case, async: true

  alias RC.Discord.DigestData

  describe "window boundary math" do
    test "ms_until_next_close counts to the next 6-hour UTC boundary" do
      now = ~U[2026-08-11 05:59:00.000000Z]
      assert DigestData.ms_until_next_close(now) == 60_000

      now = ~U[2026-08-11 06:00:00.000000Z]
      assert DigestData.ms_until_next_close(now) == 6 * 3600 * 1000

      now = ~U[2026-08-11 23:30:00.000000Z]
      assert DigestData.ms_until_next_close(now) == 30 * 60 * 1000
    end

    test "window_start returns the boundary that opened the enclosing window" do
      assert DigestData.window_start(~U[2026-08-11 17:59:04.123456Z]) == ~U[2026-08-11 12:00:00Z]
      assert DigestData.window_start(~U[2026-08-11 03:15:00.000000Z]) == ~U[2026-08-11 00:00:00Z]
      assert DigestData.window_start(~U[2026-08-11 23:59:59.999999Z]) == ~U[2026-08-11 18:00:00Z]

      # Exactly on a boundary: a new window starts there.
      assert DigestData.window_start(~U[2026-08-11 18:00:00.000000Z]) == ~U[2026-08-11 18:00:00Z]
    end

    test "window_start and ms_until_next_close partition the 6-hour window" do
      now = ~U[2026-08-11 17:59:04.123456Z]

      assert DateTime.diff(now, DigestData.window_start(now), :millisecond) +
               DigestData.ms_until_next_close(now) == 6 * 3600 * 1000
    end

    test "window_label names the window that just closed" do
      assert DigestData.window_label(~U[2026-08-11 12:00:01.000000Z]) == "06:00–12:00 UTC"
      assert DigestData.window_label(~U[2026-08-11 11:59:58.000000Z]) == "06:00–12:00 UTC"
      assert DigestData.window_label(~U[2026-08-11 00:00:02.000000Z]) == "18:00–00:00 UTC"
      assert DigestData.window_label(~U[2026-08-11 18:00:00.000000Z]) == "12:00–18:00 UTC"
    end
  end

  describe "territory_groups/1" do
    test "orders factions by first movement and signs entries" do
      events = [
        {"discord.dominion", %{faction: "ark", system_name: "Zaproron", system_id: 9, prev_faction: "synelle"}},
        {"discord.colonized", %{faction: "synelle", system_name: "Mardir", system_id: 4}},
        {"news.system.abandoned", %{faction: "tetrarchy", system_name: "Falkstvik", system_id: 7}}
      ]

      assert [
               %{faction: "ark", entries: [%{sign: :+, text: "Zaproron — dominion established"}]},
               %{
                 faction: "synelle",
                 entries: [
                   %{sign: :-, text: "Zaproron — dominion lost"},
                   %{sign: :+, text: "Mardir — system colonized"}
                 ]
               },
               %{faction: "tetrarchy", entries: [%{sign: :-, text: "Falkstvik — system abandoned"}]}
             ] = DigestData.territory_groups(events)
    end

    test "sector flips ledger on both sides" do
      events = [{"news.sector.flipped", %{faction: "ark", prev_faction: "synelle", sector_name: "Azurie"}}]

      assert [
               %{faction: "ark", entries: [%{sign: :+, text: "sector Azurie — control taken"}]},
               %{faction: "synelle", entries: [%{sign: :-, text: "sector Azurie — control lost"}]}
             ] = DigestData.territory_groups(events)
    end
  end

  describe "highlights/1" do
    test "maps kinds and dedupes by system keeping the last event" do
      events = [
        {"discord.colonized", %{faction: "synelle", system_name: "Mardir", system_id: 4}},
        {"discord.dominion", %{faction: "ark", system_name: "Zaproron", system_id: 9, prev_faction: "synelle"}},
        # Mardir flips later in the same window: final state wins
        {"discord.dominion", %{faction: "ark", system_name: "Mardir", system_id: 4, prev_faction: "synelle"}},
        {"news.dominion.liberated", %{faction: "ark", system_name: "Boras", system_id: 2}}
      ]

      highlights = DigestData.highlights(events)

      assert [
               %{system_id: 4, kind: :flipped, faction: "ark"},
               %{system_id: 9, kind: :flipped, faction: "ark"},
               %{system_id: 2, kind: :lost}
             ] = Enum.sort_by(highlights, &{&1.kind, &1.system_id})

      assert length(highlights) == 3
    end

    test "sector events produce no marker" do
      assert DigestData.highlights([{"news.sector.flipped", %{faction: "a", prev_faction: "b", sector_name: "X"}}]) ==
               []
    end
  end

  describe "vp_rows/2" do
    test "computes gained and lost star indices from window movement" do
      factions = [
        %{key: :ark, victory_points: 9},
        %{key: :synelle, victory_points: 6},
        %{key: :cardan, victory_points: 5}
      ]

      vp_events = [
        {"discord.vp_changed", %{faction: "ark", vp: 9, prev_vp: 8}},
        {"discord.vp_changed", %{faction: "synelle", vp: 6, prev_vp: 7}}
      ]

      assert [
               %{faction: "ark", vp: 9, gained: [9], lost: []},
               %{faction: "synelle", vp: 6, gained: [], lost: [7]},
               %{faction: "cardan", vp: 5, gained: [], lost: []}
             ] = DigestData.vp_rows(vp_events, factions)
    end

    test "multi-star gain uses the first prev_vp as the window start" do
      factions = [%{key: :myrmezir, victory_points: 4}]

      vp_events = [
        {"discord.vp_changed", %{faction: "myrmezir", vp: 3, prev_vp: 2}},
        {"discord.vp_changed", %{faction: "myrmezir", vp: 4, prev_vp: 3}}
      ]

      assert [%{faction: "myrmezir", vp: 4, gained: [3, 4], lost: []}] =
               DigestData.vp_rows(vp_events, factions)
    end

    test "round trip (gain then loss back to start) shows no delta" do
      factions = [%{key: :ark, victory_points: 8}]

      vp_events = [
        {"discord.vp_changed", %{faction: "ark", vp: 9, prev_vp: 8}},
        {"discord.vp_changed", %{faction: "ark", vp: 8, prev_vp: 9}}
      ]

      assert [%{faction: "ark", vp: 8, gained: [], lost: []}] = DigestData.vp_rows(vp_events, factions)
    end
  end

  test "legend_for/1 lists only present kinds" do
    highlights = [%{system_id: 1, kind: :gained}, %{system_id: 2, kind: :flipped}]
    assert DigestData.legend_for(highlights) == [{:gained, "Gained"}, {:flipped, "Changed hands"}]
    assert DigestData.legend_for([]) == []
  end
end

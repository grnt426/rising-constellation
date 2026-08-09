defmodule RC.Discord.DailyChallengeBlastTest do
  @moduledoc """
  Pure tests for the daily-challenge winners blast: slot arithmetic and
  message rendering. No bot, no DB — `render_blast/5` takes the ended
  day's objective, the top-3 rows (with resolved Discord names), and
  the next day's objective/mutators.
  """

  use ExUnit.Case, async: true

  alias RC.Discord.DailyChallengeBlast, as: Blast

  @stat_objective Daily.Objective.get(:coffers_of_the_realm)
  @race_objective Daily.Objective.get(:destroyers_blueprint)
  @next_objective Daily.Objective.get(:golden_flow)
  @mutators [%{name: "Rich Veins", polarity: :positive}, %{name: "Solar Flares", polarity: :negative}]

  defp winner(rank, name, score, discord_name \\ nil),
    do: %{rank: rank, name: name, score: score, tiebreak: 0.0, objective: "x", discord_name: discord_name}

  describe "due_at/1" do
    test "the blast for an ended date fires 45 minutes past the next rotation" do
      assert Blast.due_at(~D[2026-08-02]) == ~U[2026-08-03 07:45:00Z]
      assert Blast.due_at(~D[2026-12-31]) == ~U[2027-01-01 07:45:00Z]
    end
  end

  describe "render_blast/5" do
    test "names the top 3 with medals, Discord names in plain text, and the next challenge" do
      winners = [
        winner(1, "Alrua", 1_234_567.0, "AlruaTTV"),
        winner(2, "Bek", 987_000.0),
        winner(3, "Cor", 500.0, "cor_gaming")
      ]

      blast = Blast.render_blast("2026-08-02", @stat_objective, winners, @next_objective, @mutators)

      assert blast =~ "**Daily Challenge — 2026-08-02: Coffers of the Realm**"
      refute blast =~ "🏆"
      assert blast =~ "🥇 Alrua (AlruaTTV) — 1,234,567"
      assert blast =~ "🥈 Bek — 987,000"
      assert blast =~ "🥉 Cor (cor_gaming) — 500"
      assert blast =~ "Up next: **Golden Flow** — Drive credit income as high as it will go."
      assert blast =~ "Mutators: +Rich Veins, −Solar Flares"
      # Plain names only — a <@id> would ping.
      refute blast =~ "<@"
    end

    test "an unclaimed day still previews the next challenge" do
      blast = Blast.render_blast("2026-08-02", @stat_objective, [], @next_objective, [])

      assert blast =~ "went unclaimed"
      assert blast =~ "Up next: **Golden Flow**"
      refute blast =~ "Mutators:"
    end

    test "race scores render as time to spare, DNF-ranked winners as closest" do
      winners = [winner(1, "Alrua", 312.4, nil), winner(2, "Bek", 0.0, nil)]
      blast = Blast.render_blast("2026-08-02", @race_objective, winners, @next_objective, [])

      assert blast =~ "🥇 Alrua — 312s to spare"
      assert blast =~ "🥈 Bek — closest to the goal"
    end
  end
end

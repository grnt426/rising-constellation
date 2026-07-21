defmodule RC.Repo.Migrations.AddTiebreakToDailyEntries do
  use Ecto.Migration

  # Scoring shapes (docs/daily-challenge-ideas.md): every daily objective now
  # publishes a tiebreak alongside its score (race progress, combined income,
  # ...). Stored per entry so the leaderboard can order by (score, tiebreak)
  # and keep-best upserts compare lexicographically.
  def change do
    alter table(:daily_entries) do
      add(:tiebreak, :float, null: false, default: 0.0)
    end
  end
end

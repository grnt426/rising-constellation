defmodule RC.Repo.Migrations.CreateDailyEntries do
  use Ecto.Migration

  def change do
    create table(:daily_entries) do
      add(:profile_id, references(:profiles, on_delete: :delete_all), null: false)
      # ISO-8601 date string of the daily (matches Daily.Generator).
      add(:date, :string, null: false)
      add(:objective, :string)
      add(:score, :float, null: false)
      # The (large, timestamp-based) instance id the score came from. Plain
      # bigint, not a FK — the instance row is finished/torn down after.
      add(:instance_id, :bigint)

      timestamps(type: :utc_datetime_usec)
    end

    # One best score per player per day — Daily.record_score/5 upserts here.
    create(unique_index(:daily_entries, [:profile_id, :date]))
    # Leaderboard reads: a day's scores, highest first.
    create(index(:daily_entries, [:date, :objective]))
  end
end

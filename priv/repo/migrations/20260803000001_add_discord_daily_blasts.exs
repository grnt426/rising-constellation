defmodule RC.Repo.Migrations.AddDiscordDailyBlasts do
  use Ecto.Migration

  # Once-a-day latch for the daily-challenge winners blast
  # (RC.Discord.DailyChallengeBlast): one row per daily date whose
  # blast has been posted. The unique index is the authority — the
  # scheduler's in-memory state is just a fast path.
  def change do
    create table(:discord_daily_blasts) do
      add(:date, :string, null: false)

      timestamps(updated_at: false, type: :utc_datetime_usec)
    end

    create(unique_index(:discord_daily_blasts, [:date]))
  end
end

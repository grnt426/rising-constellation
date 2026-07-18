defmodule RC.Repo.Migrations.AddDiscordBulletinAndMatchExtensions do
  use Ecto.Migration

  # Discord bot feature batch (2026-07-18):
  #
  #   * `discord_matches.announced_start_at` — operator-entered start time
  #     collected by the /promote modal. The registration announcement
  #     renders this instead of instances.opening_date (which historically
  #     hasn't matched real start times).
  #   * `discord_matches.diplomacy_category_id` + `diplo_channels` — the
  #     pairwise inter-faction diplomacy channels created for matches with
  #     more than two factions. category id is nil when the channels were
  #     placed under a pre-existing (operator-owned) category; channel ids
  #     are tracked individually so teardown can delete exactly what the
  #     bot created.
  #   * `discord_matches.bulletin_last_posted_on` / `bulletin_cutoff_at` —
  #     daily-summary bookkeeping. The posted-on date is the once-a-day
  #     latch; the cutoff is the high-water mark of game events already
  #     summarized (a missed day folds into the next bulletin instead of
  #     losing its window).
  #   * `discord_matches.bulletin_salt` — random per-match secret seeding
  #     the daily post/cutoff slots. A stored secret (not a derivable
  #     timestamp) so observing weeks of public post times can never
  #     narrow down the hidden cutoff slot. Generated lazily on first
  #     bulletin sweep.
  #   * `discord_bulletin_events` — battle/raid/loot/conquest accumulator
  #     rows written by Game.News.Server for discord_ready instances.
  #     Consumed (deleted) by each daily bulletin post, so the table stays
  #     one-window small per live match.
  def change do
    alter table(:discord_matches) do
      add(:announced_start_at, :utc_datetime_usec)
      add(:diplomacy_category_id, :string)
      add(:diplo_channels, :map, null: false, default: %{})
      add(:bulletin_last_posted_on, :date)
      add(:bulletin_cutoff_at, :utc_datetime_usec)
      add(:bulletin_salt, :string)
    end

    create table(:discord_bulletin_events) do
      add(:instance_id, references(:instances, on_delete: :delete_all), null: false)
      add(:kind, :string, null: false)
      add(:payload, :map, null: false, default: %{})

      timestamps(updated_at: false, type: :utc_datetime_usec)
    end

    create(index(:discord_bulletin_events, [:instance_id, :inserted_at]))
  end
end

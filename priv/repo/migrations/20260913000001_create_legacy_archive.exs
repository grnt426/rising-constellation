defmodule RC.Repo.Migrations.CreateLegacyArchive do
  use Ecto.Migration

  # Legacy match archive — a frozen, pre-aggregated record of each finished
  # official Legacy match, built by RC.Archive.Importer from the nightly
  # snapshot tarballs (S3) plus the permanent player_events / player_stats
  # rows. Everything the archive pages render comes from these four tables,
  # so the source snapshots can age out of S3 after import.
  #
  # Metrics live in jsonb maps rather than columns: the set grows as we find
  # new things worth charting and old archives simply lack the newer keys
  # (the UI hides charts with no data). Keys are documented in
  # RC.Archive.SnapshotStats and RC.Archive.EventStats.
  def change do
    create table(:archive_matches) do
      add(:instance_id, references(:instances, on_delete: :delete_all), null: false)
      add(:name, :string, null: false)
      add(:map_name, :string)
      add(:speed, :string, null: false)
      add(:started_at, :utc_datetime_usec, null: false)
      add(:ended_at, :utc_datetime_usec, null: false)
      add(:victory_type, :string)
      add(:winner_faction, :string)
      add(:player_count, :integer, null: false, default: 0)
      add(:system_count, :integer, null: false, default: 0)
      # [%{key, rank, players, victory_points, systems, dominions, sectors}]
      # in final-rank order — the list page renders from this alone.
      add(:factions, :map, null: false, default: "[]")
      # Final-state summary blocks (standings, totals, activity per system).
      add(:summary, :map, null: false, default: "{}")
      # Galaxy geometry + per-day sector/system ownership codes.
      add(:map, :map, null: false, default: "{}")
      # Which snapshot files fed which day — provenance for re-imports.
      add(:source, :map, null: false, default: "{}")
      # Hidden from players until an admin has checked the import.
      add(:published, :boolean, null: false, default: false)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:archive_matches, [:instance_id]))
    create(index(:archive_matches, [:published, :ended_at]))

    # One row per faction per match day (day 1 = the first 24h after the
    # instance started running). `sampled_at` is the snapshot the snapshot
    # metrics came from; nil when only event/player_stats data exists.
    create table(:archive_faction_days) do
      add(:match_id, references(:archive_matches, on_delete: :delete_all), null: false)
      add(:faction, :string, null: false)
      add(:day, :integer, null: false)
      add(:sampled_at, :utc_datetime_usec)
      add(:metrics, :map, null: false, default: "{}")
    end

    create(unique_index(:archive_faction_days, [:match_id, :faction, :day]))

    create table(:archive_players) do
      add(:match_id, references(:archive_matches, on_delete: :delete_all), null: false)
      # Nilified if the profile is later deleted — the archived name stays.
      add(:profile_id, references(:profiles, on_delete: :nilify_all))
      add(:name, :string, null: false)
      add(:faction, :string, null: false)
      add(:metrics, :map, null: false, default: "{}")
      # [[day, points, systems, output_credit]] from player_stats.
      add(:series, :map, null: false, default: "[]")
    end

    create(index(:archive_players, [:match_id]))
    create(index(:archive_players, [:profile_id]))

    # How many players of each faction had unlocked a patent / lex by the
    # end, and the first archived day it was seen.
    create table(:archive_unlocks) do
      add(:match_id, references(:archive_matches, on_delete: :delete_all), null: false)
      add(:kind, :string, null: false)
      add(:key, :string, null: false)
      add(:faction, :string, null: false)
      add(:player_count, :integer, null: false)
      add(:first_day, :integer)
    end

    create(unique_index(:archive_unlocks, [:match_id, :kind, :key, :faction]))
  end
end

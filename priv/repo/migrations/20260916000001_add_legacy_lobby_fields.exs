defmodule RC.Repo.Migrations.AddLegacyLobbyFields do
  use Ecto.Migration

  # Legacy lobby additions:
  #
  # * factions.final_victory_points — the VP each faction held when the
  #   victory was declared, written next to final_rank by
  #   RC.Instances.record_victory/2. Until now the end-of-game VP only lived
  #   in the victory agent's (pruned) snapshots and the archive rows, so the
  #   lobby's "latest official result" card had nothing durable to read.
  #   Backfilled from archive_matches for the matches already imported.
  #
  # * site_settings — tiny admin-editable key/value store (jsonb values).
  #   First key: "next_official_legacy" (announced start date/time).
  def up do
    alter table(:factions) do
      add(:final_victory_points, :integer)
    end

    create table(:site_settings, primary_key: false) do
      add(:key, :string, primary_key: true)
      add(:value, :map, null: false, default: "{}")

      timestamps(type: :utc_datetime_usec)
    end

    flush()

    execute("""
    UPDATE factions f
    SET final_victory_points = (entry->>'victory_points')::integer
    FROM archive_matches m, jsonb_array_elements(m.factions) AS entry
    WHERE m.instance_id = f.instance_id
      AND entry->>'key' = f.faction_ref
      AND entry->>'victory_points' IS NOT NULL
    """)
  end

  def down do
    drop(table(:site_settings))

    alter table(:factions) do
      remove(:final_victory_points)
    end
  end
end

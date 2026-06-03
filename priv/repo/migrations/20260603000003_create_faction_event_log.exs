defmodule RC.Repo.Migrations.CreateFactionEventLog do
  use Ecto.Migration

  # Faction-scoped audit log. The first event type it carries is
  # icon-removal/overwrite — the "who deleted my marker?" surface that
  # makes player-placed icons safe to share faction-wide — but the
  # schema is intentionally generic (`event_type` + `payload`) so
  # future audit-worthy events can join without another migration.
  #
  # Self-removals and self-replacements are NOT logged: a player
  # changing their mind about their own icon shouldn't flood the
  # accountability surface. Only cross-player actions land here.
  #
  # The schema duplicates display names into `payload` (and the
  # system name where applicable) so deleted profiles or later
  # system renames don't corrupt the historical record. FK ON DELETE
  # behavior:
  #   - instances: CASCADE — drop with the instance
  #   - factions:  CASCADE — same scope
  #   - profiles:  SET NULL — actor/target can vanish; the cached
  #                name in `payload` keeps the log readable
  def change do
    create table(:faction_event_log) do
      add(:instance_id, references(:instances, on_delete: :delete_all), null: false)
      add(:faction_id, references(:factions, on_delete: :delete_all), null: false)
      add(:actor_profile_id, references(:profiles, on_delete: :nilify_all), null: true)
      add(:target_profile_id, references(:profiles, on_delete: :nilify_all), null: true)
      add(:event_type, :string, null: false)
      add(:payload, :text, null: false)

      timestamps(updated_at: false, type: :utc_datetime_usec)
    end

    # Primary read pattern: latest N for this (instance, faction).
    create(index(:faction_event_log, [:instance_id, :faction_id, :inserted_at]))
  end
end

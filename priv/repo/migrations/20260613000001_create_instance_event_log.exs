defmodule RC.Repo.Migrations.CreateInstanceEventLog do
  use Ecto.Migration

  # Instance-scoped, append-only event log for in-game agent activity:
  # siege lifecycle (start / release / orphan-release) plus, when the
  # `action_trace` debug flag is on, every action an admiral/agent
  # starts, finishes, or aborts. Purpose-built to make "what did this
  # fleet actually do, in what order?" a single ORDER BY query instead
  # of a multi-source reconstruction from snapshots + fight reports.
  #
  # Design notes:
  #   - `kind` + free-form `payload` (JSON text) keeps the schema
  #     generic so new event kinds don't need a migration.
  #   - `character_id` / `system_id` are GAME-DOMAIN ids (the in-memory
  #     agent ids), NOT foreign keys — characters and stellar systems
  #     are not relational tables, they live in the BEAM. Stored as
  #     plain bigints purely so the log is filterable/joinable by hand.
  #   - Only `instance_id` is a real FK. ON DELETE CASCADE so the log
  #     drops with the instance it belongs to.
  #   - High-signal events (sieges) are always-on; the high-volume
  #     action trace is gated behind RC.DebugFlags.action_trace?/0 so
  #     this table only grows quickly while someone is actively
  #     debugging. Add a retention/rotation policy if always-on volume
  #     ever warrants it.
  def change do
    create table(:instance_event_log) do
      add(:instance_id, references(:instances, on_delete: :delete_all), null: false)
      add(:kind, :string, null: false)
      add(:character_id, :bigint, null: true)
      add(:system_id, :bigint, null: true)
      add(:payload, :text, null: false, default: "{}")

      timestamps(updated_at: false, type: :utc_datetime_usec)
    end

    # Primary read pattern: full ordered timeline for one instance.
    create(index(:instance_event_log, [:instance_id, :inserted_at]))
    # Secondary: "every siege event" / "every action of kind X".
    create(index(:instance_event_log, [:instance_id, :kind, :inserted_at]))
  end
end

defmodule RC.Repo.Migrations.CreateBotAssignments do
  use Ecto.Migration

  # Roster table — one row per stress-test bot, defining which game it's
  # assigned to play and how it should behave. Replaces the file-based
  # `:rc_bot, :roster` config we shipped in the harness app: now the
  # dashboard can mutate assignments without redeploying the bot fleet.
  #
  # UNIQUE(account_id) enforces "one bot, one game at a time." If we
  # ever want multi-game bots we can drop this constraint, but the
  # simplification it gives the orchestrator + UI is worth keeping for
  # the foreseeable future.
  #
  # FK ON DELETE behavior:
  #   - accounts: CASCADE — deleting the bot account removes its row
  #   - instances: SET NULL — deleting an instance leaves the bot row
  #     intact but unassigned (rather than dropping the whole row); the
  #     operator can then reassign it from the dashboard
  #   - factions: SET NULL for the same reason
  def change do
    create table(:bot_assignments) do
      add(:account_id, references(:accounts, on_delete: :delete_all), null: false)
      add(:instance_id, references(:instances, on_delete: :nilify_all), null: true)
      add(:faction_id, references(:factions, on_delete: :nilify_all), null: true)

      # Independent of the global stress_test_enabled flag — this is the
      # per-bot toggle. A bot only runs when BOTH flags are true and it
      # has a non-null instance_id + faction_id.
      add(:enabled, :boolean, null: false, default: false)

      # Fully-qualified policy module name (e.g. "RcBot.Policy.Dumb").
      # Stored as string so the rc app doesn't have to know which atoms
      # the harness defines. The harness validates at session start.
      add(:policy, :string, null: false, default: "RcBot.Policy.Dumb")

      # Per-bot session-shape overrides. Nullable: when null the harness
      # uses its own session_defaults config. These exist so an operator
      # can tune one bot to "burst harder" without touching the rest.
      add(:bursts_total, :integer, null: true)
      add(:inter_burst_ms_min, :integer, null: true)
      add(:inter_burst_ms_max, :integer, null: true)

      # Stamped by the orchestrator on each session start. Used for
      # dashboard "stuck" detection in addition to the bot_events
      # last-seen — this catches "never started a session" cases.
      add(:last_session_at, :utc_datetime_usec, null: true)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:bot_assignments, [:account_id]))
    create(index(:bot_assignments, [:instance_id]))
    create(index(:bot_assignments, [:enabled]))
  end
end

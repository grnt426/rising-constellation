defmodule RC.Repo.Migrations.CreateBotEvents do
  use Ecto.Migration

  # Activity log for stress-test bots. Every channel action (player +
  # cheat) lands here when `socket.assigns.account.is_bot == true`, plus
  # bot-reported lifecycle events (login, disconnect, etc.). Powers the
  # /admin/bots dashboard.
  #
  # FKs are nullable because some events (login failures, register
  # failures) happen before the bot has a known profile or instance.
  def change do
    create table(:bot_events) do
      add(:account_id, references(:accounts, on_delete: :delete_all), null: true)
      add(:profile_id, references(:profiles, on_delete: :delete_all), null: true)
      add(:instance_id, references(:instances, on_delete: :delete_all), null: true)

      # "action"     — a channel push the bot made (player or cheat)
      # "lifecycle"  — login, registration, connect, disconnect, burst boundaries
      # "transport"  — socket-level events (reconnect, heartbeat fail)
      add(:event_type, :string, null: false)

      # The specific name: "hire_character", "login", "burst_complete", etc.
      add(:event_name, :string, null: false)

      # Origin: "player" | "cheat" | "lifecycle" | "transport"
      add(:channel, :string, null: false)

      # "ok" | "error" | "info"
      add(:status, :string, null: false)

      # Error reason (atom-as-string from the server reply) when status=error.
      # Null otherwise.
      add(:reason, :string, null: true)

      # Optional timing in ms — populated for actions where we measure it.
      add(:duration_ms, :integer, null: true)

      timestamps(updated_at: false, type: :utc_datetime_usec)
    end

    # Per-bot history lookup (the dashboard's per-bot drill-down).
    create(index(:bot_events, [:account_id, :inserted_at]))

    # Per-instance dashboard view ("which bots in instance N are doing what").
    create(index(:bot_events, [:instance_id, :inserted_at]))

    # Aggregations by type ("how many errors in the last hour").
    create(index(:bot_events, [:event_type, :inserted_at]))
  end
end

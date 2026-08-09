defmodule RC.Repo.Migrations.AddIsReadToPlayerEvents do
  use Ecto.Migration

  # Read-state for the in-game Reports view. Events arrive unread; the
  # player marks them read individually (on open) or in bulk ("mark all
  # read"), and can bulk-delete read / all events. Default false so every
  # pre-existing row shows as unread the first time the new Reports tab is
  # opened — which is the desired behaviour (players should re-see history
  # they may have missed while the notification-replay bug was live).
  def change do
    alter table(:player_events) do
      add(:is_read, :boolean, null: false, default: false)
    end
  end
end

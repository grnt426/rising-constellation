defmodule RC.Repo.Migrations.AddIsBotOnlyToInstances do
  use Ecto.Migration

  # Flag a game instance as bot-only. Non-admin players never see these
  # in /api/instances or /api/instances/:iid. The bots inside still see
  # each other (channel-level joins don't filter), and admins still see
  # everything. Used for stress-test games we don't want polluting the
  # real-player lobby.
  def change do
    alter table(:instances) do
      add :is_bot_only, :boolean, null: false, default: false
    end

    # Partial index so the "filter out is_bot_only" hot path is cheap.
    create index(:instances, [:is_bot_only], where: "is_bot_only = false", name: :instances_visible_index)
  end
end

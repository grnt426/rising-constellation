defmodule RC.Repo.Migrations.AddBotFactionToInstances do
  use Ecto.Migration

  def change do
    alter table(:instances) do
      # faction_ref of the faction played by bots (nil = normal game).
      add(:bot_faction, :string)
    end
  end
end

defmodule RC.Repo.Migrations.AddIsBotToAccountsAndProfiles do
  use Ecto.Migration

  # Marks an account/profile as a stress-test bot. Denormalized onto profiles
  # so the rankings/search hot paths don't need an account join. Only ever
  # written by admin tooling — see `Account.changeset_admin/2`.
  def change do
    alter table(:accounts) do
      add :is_bot, :boolean, null: false, default: false
    end

    alter table(:profiles) do
      add :is_bot, :boolean, null: false, default: false
    end

    create index(:profiles, [:is_bot], where: "is_bot = true", name: :profiles_is_bot_index)
  end
end

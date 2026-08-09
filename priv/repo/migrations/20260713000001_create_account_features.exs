defmodule RC.Repo.Migrations.CreateAccountFeatures do
  use Ecto.Migration

  def change do
    create table(:account_features) do
      add(:account_id, references(:accounts, on_delete: :delete_all), null: false)
      # Opt-in beta feature key, e.g. "agent_fan_display". The catalog of
      # valid keys lives in code (RC.Accounts.AccountFeature.known/0).
      add(:feature, :string, null: false)
      add(:enabled, :boolean, null: false, default: false)

      timestamps(type: :utc_datetime_usec)
    end

    # One row per account per feature — RC.Accounts.set_feature/3 upserts.
    create(unique_index(:account_features, [:account_id, :feature]))
  end
end

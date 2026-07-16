defmodule RC.Repo.Migrations.CreateGovernmentStates do
  use Ecto.Migration

  def change do
    create table(:government_states) do
      add(:instance_id, references(:instances, on_delete: :delete_all), null: false)
      # 0 for instance-scoped kinds (diplomacy) — NOT NULL so the unique
      # index actually dedupes (Postgres treats NULLs as distinct).
      add(:faction_id, :bigint, null: false, default: 0)
      add(:kind, :string, null: false)
      add(:rev, :bigint, null: false, default: 0)
      add(:state, :binary, null: false)

      timestamps()
    end

    create(unique_index(:government_states, [:instance_id, :kind, :faction_id]))
  end
end

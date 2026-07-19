defmodule RC.Repo.Migrations.CreateDeployLog do
  use Ecto.Migration

  def change do
    create table(:deploy_log) do
      add(:flag, :boolean, null: false)
      add(:source, :string, null: false)

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end
  end
end

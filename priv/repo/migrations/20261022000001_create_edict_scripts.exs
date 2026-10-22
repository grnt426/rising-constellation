defmodule RC.Repo.Migrations.CreateEdictScripts do
  use Ecto.Migration

  # Scenario scripts (Edict) saved to an account (RC.Scripts):
  #
  # * edict_scripts — at most 10 per account (enforced by the context).
  #   `source` is the canonical text and `digest` its SHA-256, so a published
  #   script is always exactly what its author last saved. The partial unique
  #   index keeps one published copy of any given text.
  # * edict_match_runs — the state of a running match's scripts (each
  #   player's vars, timers and score), saved so a Legacy match's scripts
  #   survive restarts and deploys (Edict.Match).
  def change do
    create table(:edict_scripts) do
      add(:author_id, references(:accounts, on_delete: :delete_all), null: false)
      add(:name, :string, null: false)
      add(:description, :text, null: false, default: "")
      add(:source, :text, null: false)
      # the editor's tree (node ids included, so the layout below still fits)
      add(:program, :map, null: false)
      add(:layout, :map, null: false, default: %{})
      add(:digest, :string, null: false)
      # checker errors at the last save; a published script must have none
      add(:error_count, :integer, null: false, default: 0)
      add(:published_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:edict_scripts, [:author_id]))
    create(index(:edict_scripts, [:published_at]))

    create(
      unique_index(:edict_scripts, [:digest],
        where: "published_at IS NOT NULL",
        name: :edict_scripts_published_digest_index
      )
    )

    create table(:edict_match_runs, primary_key: false) do
      add(:instance_id, references(:instances, on_delete: :delete_all), primary_key: true)
      add(:state, :binary, null: false)

      timestamps(type: :utc_datetime_usec)
    end
  end
end

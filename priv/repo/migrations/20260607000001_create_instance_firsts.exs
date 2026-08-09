defmodule RC.Repo.Migrations.CreateInstanceFirsts do
  use Ecto.Migration

  @moduledoc """
  News-ticker support. Tracks "first to X" claims per instance so we can
  emit a one-shot news bulletin the first time something happens in a
  game (first colonization, first Metamaterials Factory, first powerful
  patent unlock, etc.).

  The unique constraint on (instance_id, first_key) is the actual
  enforcement of "first" semantics — Game.News.claim_first/3 uses
  ON CONFLICT DO NOTHING and treats a non-empty RETURNING as "you were
  first."
  """

  def change do
    create table(:instance_firsts) do
      add(:first_key, :string, null: false)
      add(:instance_id, references(:instances, on_delete: :delete_all), null: false)
      # Winner refs are nullable so we can track non-player firsts later
      # (galaxy events triggered by neutrals/bots/system-at-large).
      add(:winning_faction_id, references(:factions, on_delete: :nilify_all), null: true)
      add(:winning_registration_id, references(:registrations, on_delete: :nilify_all), null: true)

      timestamps(updated_at: false, type: :utc_datetime)
    end

    create(unique_index(:instance_firsts, [:instance_id, :first_key]))
  end
end

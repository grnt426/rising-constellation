defmodule RC.Repo.Migrations.CreateForesightPredictions do
  use Ecto.Migration

  # One row per token commitment on a match (docs/foresight.md). An
  # account may add several predictions to the same match; each settles
  # independently on its own inserted_at (the earliness input), so rows
  # are immutable until settlement stamps the outcome.
  def change do
    create table(:foresight_predictions) do
      add(:account_id, references(:accounts, on_delete: :delete_all), null: false)
      # Plain bigint, not a FK — instances are deletable in several
      # states and prediction history must survive; the sweeper voids
      # predictions whose instance is gone (same rationale as
      # daily_entries.instance_id).
      add(:instance_id, :bigint, null: false)
      # The per-instance factions row id, plus its stable string key
      # denormalized so history stays renderable after the instance
      # (and its factions) are deleted.
      add(:faction_id, :bigint, null: false)
      add(:faction_ref, :string, null: false)
      add(:tokens, :integer, null: false)
      # Courtesy-minted portion (rule 4). tokens - credited_tokens is
      # what was actually debited from the balance; on refunds only the
      # debited part comes back and the minted part dissolves.
      add(:credited_tokens, :integer, null: false, default: 0)
      # active | correct | incorrect | void
      add(:status, :string, null: false, default: "active")
      add(:tokens_recovered, :integer)
      # Early-call bonus, credited on the account's earliest qualifying
      # prediction at settlement.
      add(:bonus_tokens, :integer, null: false, default: 0)
      add(:points_awarded, :integer)
      add(:settled_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:foresight_predictions, [:instance_id]))
    create(index(:foresight_predictions, [:account_id]))

    # Rule 4: at most ONE outstanding courtesy-credited prediction per
    # account, enforced by the database rather than application checks.
    create(
      unique_index(:foresight_predictions, [:account_id],
        where: "credited_tokens > 0 AND status = 'active'",
        name: :foresight_predictions_one_active_courtesy
      )
    )
  end
end

defmodule RC.Repo.Migrations.AddForesightToAccounts do
  use Ecto.Migration

  # Foresight match predictions (docs/foresight.md): every account holds
  # Foresight Tokens (committed on predictions, redistributed at
  # settlement) and Foresight Points (minted on correct predictions,
  # score-only, never spent). The default of 100 IS the rule-1 seed —
  # it backfills every existing account in one stroke.
  def change do
    alter table(:accounts) do
      add(:foresight_tokens, :integer, null: false, default: 100)
      add(:foresight_points, :integer, null: false, default: 0)
    end
  end
end

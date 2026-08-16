defmodule RC.Repo.Migrations.CreateForesightSettlements do
  use Ecto.Migration

  # Exactly-once settlement latch (docs/foresight.md): settling an
  # instance's predictions writes this row inside the same transaction
  # that applies the results, and the unique index is the authority
  # (same doctrine as discord_daily_blasts). This makes the inline
  # victory hook and the safety-net sweeper safely concurrent.
  def change do
    create table(:foresight_settlements) do
      # Plain bigint like foresight_predictions — must outlive the
      # instance row.
      add(:instance_id, :bigint, null: false)
      # settled | unbacked | void_no_winner | void_min_players |
      # void_single_faction | void_instance_deleted
      add(:outcome, :string, null: false)
      add(:winning_faction_ref, :string)
      # Summary numbers for ops/history; the per-prediction truth lives
      # on the foresight_predictions rows.
      add(:pool_tokens, :integer, null: false, default: 0)
      add(:tokens_recovered, :integer, null: false, default: 0)
      add(:points_minted, :integer, null: false, default: 0)

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(unique_index(:foresight_settlements, [:instance_id]))
  end
end

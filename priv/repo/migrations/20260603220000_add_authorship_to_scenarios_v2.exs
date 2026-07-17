defmodule RC.Repo.Migrations.AddAuthorshipToScenariosV2 do
  use Ecto.Migration

  # Forge Stage 2 — re-apply add_authorship_to_scenarios safely.
  #
  # The original migration shared version 20260602000003 with the bot
  # is_bot_only migration. Prod ran the bot one first and recorded
  # version 003 as applied. When the colliding files were resolved by
  # renaming the bot one to 000004, Ecto saw 003 already recorded and
  # skipped add_authorship_to_scenarios entirely on prod. That left
  # `scenarios.author_id` and `scenarios.published_at` missing in prod,
  # crashing every Forge endpoint that joined :author or filtered on
  # :published_at (Postgrex 42703 undefined_column).
  #
  # Prod was patched by hand with the same DDL this migration carries.
  # Dev / test DBs already added the columns via the original 000003
  # file. A fresh DB still gets them via that original file too. So in
  # every known environment this migration is a no-op. The guards below
  # make it safe to re-run anywhere we forgot, which is the whole point
  # of writing it.
  #
  # Note: `add_if_not_exists` with `references/2` is NOT safe on a DB
  # where the column already exists — Ecto's Postgres adapter emits the
  # FK as a separate `ALTER TABLE ... ADD CONSTRAINT`, which fires even
  # when the ADD COLUMN IF NOT EXISTS is skipped, and trips
  # 42710 duplicate_object. So we add the column as a plain :bigint
  # here and attach the FK via a guarded DO block below.
  def change do
    alter table(:scenarios) do
      add_if_not_exists(:author_id, :bigint, null: true)
      add_if_not_exists(:published_at, :utc_datetime_usec, null: true)
    end

    execute(
      """
      DO $$
      BEGIN
        IF NOT EXISTS (
          SELECT 1 FROM pg_constraint WHERE conname = 'scenarios_author_id_fkey'
        ) THEN
          ALTER TABLE scenarios
            ADD CONSTRAINT scenarios_author_id_fkey
            FOREIGN KEY (author_id) REFERENCES accounts(id)
            ON DELETE SET NULL;
        END IF;
      END$$;
      """,
      "ALTER TABLE scenarios DROP CONSTRAINT IF EXISTS scenarios_author_id_fkey"
    )

    create_if_not_exists(index(:scenarios, [:author_id]))
    create_if_not_exists(index(:scenarios, [:published_at]))

    # Backfill is naturally idempotent (WHERE published_at IS NULL),
    # so re-running it leaves already-published rows alone.
    execute(
      "UPDATE scenarios SET published_at = inserted_at WHERE published_at IS NULL",
      "UPDATE scenarios SET published_at = NULL"
    )
  end
end

defmodule RC.Repo.Migrations.AddAuthorshipToScenarios do
  use Ecto.Migration

  # Forge Stage 2. The shared `scenarios` table now records who created a
  # design and when it was made public. Maps and Scenarios live in the same
  # table (differentiated by `is_map`), so one migration covers both.
  #
  # author_id is nullable on purpose: existing rows seeded by the engine
  # have no author and should keep rendering as "Official" (badge logic:
  # author_id IS NULL AND is_official = true). on_delete: :nilify_all so
  # deleting an account doesn't cascade-delete every map they authored —
  # the work falls back to "anonymous community" rather than vanishing.
  #
  # published_at is nullable to express the draft/published lifecycle. New
  # community designs land as drafts (published_at NULL) and only show up
  # in the public list once the author clicks Publish. We backfill
  # existing rows to inserted_at so they don't disappear from lists the
  # moment this migration runs.
  def change do
    alter table(:scenarios) do
      add :author_id, references(:accounts, on_delete: :nilify_all), null: true
      add :published_at, :utc_datetime_usec, null: true
    end

    create index(:scenarios, [:author_id])
    create index(:scenarios, [:published_at])

    # Backfill: every existing row is treated as "published the day it was
    # inserted." Without this, the published-only default list filter
    # would silently hide every seeded map/scenario.
    execute(
      "UPDATE scenarios SET published_at = inserted_at WHERE published_at IS NULL",
      "UPDATE scenarios SET published_at = NULL"
    )
  end
end

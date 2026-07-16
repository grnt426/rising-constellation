defmodule RC.Repo.Migrations.AddScenarioIdToInstances do
  use Ecto.Migration

  # Stage 4 (mini) — connect a finished/running instance back to the
  # scenario it spawned from, so we can answer "most-played scenario."
  # Nullable + nilify_all because:
  #   - historical instances from before this column existed have to be
  #     left alone (NULL is the unknown-source case);
  #   - deleting a scenario should NOT cascade-delete the games run from
  #     it. Losing the link is annoying; losing the games is destructive.
  def change do
    alter table(:instances) do
      add(:scenario_id, references(:scenarios, on_delete: :nilify_all), null: true)
    end

    # B-tree index — the play-count query filters on scenario_id for
    # every scenarios-list page render.
    create(index(:instances, [:scenario_id]))
  end
end

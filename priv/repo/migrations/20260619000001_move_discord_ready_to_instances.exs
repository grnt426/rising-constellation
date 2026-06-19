defmodule RC.Repo.Migrations.MoveDiscordReadyToInstances do
  use Ecto.Migration

  # Hotfix: "promotable" moves from a scenario-template property to a
  # per-match (per-instance) property. It is now set on the game-setup page
  # at instance creation instead of being toggled in the scenario editor.
  # Eligibility for `/promote legacy` now reads `instances.discord_ready`
  # rather than `scenarios.discord_ready` — see RC.Discord.LegacyMatch.
  #
  # `scenarios.discord_ready` is intentionally NOT dropped here. Rolling the
  # release back to the previous version would resurrect code that reads
  # that column, so it is retained (unused by current code) and can be
  # dropped in a separate, later migration once a rollback is no longer a
  # concern.
  def up do
    alter table(:instances) do
      add(:discord_ready, :boolean, null: false, default: false)
    end

    # Partial index mirrors the old scenarios.discord_ready index: the
    # eligibility query filters on discord_ready = true and the vast
    # majority of instances are false.
    create(
      index(:instances, [:discord_ready],
        where: "discord_ready = true",
        name: :instances_discord_ready_index
      )
    )

    # Backfill so promotability survives the model switch: any instance
    # whose scenario was marked discord_ready carries that forward. This
    # keeps games already opted in (e.g. a live Legacy match) eligible for
    # /promote legacy immediately after deploy, with no manual re-flagging.
    execute(
      "UPDATE instances SET discord_ready = true WHERE scenario_id IN (SELECT id FROM scenarios WHERE discord_ready = true)"
    )
  end

  def down do
    drop(index(:instances, [:discord_ready], name: :instances_discord_ready_index))

    alter table(:instances) do
      remove(:discord_ready)
    end
  end
end

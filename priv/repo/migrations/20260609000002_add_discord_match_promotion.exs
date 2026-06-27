defmodule RC.Repo.Migrations.AddDiscordMatchPromotion do
  use Ecto.Migration

  # Lobby automation, Phase 1.
  #
  # Two pieces:
  #
  # 1. `scenarios.discord_ready` — admin-flippable boolean marking a
  #    scenario as eligible for community-wide Discord promotion. NOT
  #    a property of any specific running game; it's a property of the
  #    template ("this map/setup is sanctioned"). Default false so
  #    every existing scenario stays unsurfaced until an admin opts it
  #    in.
  #
  # 2. `discord_matches` — bookkeeping for instances that an authorized
  #    promoter has run `/promote legacy` against. Stores the Discord
  #    category id (so we can rename / lock / archive later) plus an
  #    audit trail (who promoted, when). `role_assignment_active`
  #    starts false; Phase 2 flips it to true at `opening_date - 6h`,
  #    at which point the bot starts syncing faction roles to Discord
  #    role assignments.
  #
  # on_delete: :delete_all on instance_id — if the underlying instance
  # is deleted, the bookkeeping is dead anyway. The actual Discord
  # channels persist on Discord's side; archival/deletion is a
  # separate operation (Phase 3).
  def change do
    alter table(:scenarios) do
      add(:discord_ready, :boolean, null: false, default: false)
    end

    # Partial index — most scenarios will NOT be discord_ready, so the
    # /promote eligibility query benefits from skipping them at the
    # index level rather than scanning the full table.
    create(
      index(:scenarios, [:discord_ready],
        where: "discord_ready = true",
        name: :scenarios_discord_ready_index
      )
    )

    create table(:discord_matches) do
      add(:instance_id, references(:instances, on_delete: :delete_all), null: false)

      # Per-faction Discord category snowflakes, stored as a JSON map
      # keyed by faction_ref string. Layout:
      #   %{"tetrarchy" => "1234567890", "myrmezir" => "...", ...}
      # Each instance gets one category per faction it actually has
      # (not always all 5 — depends on the scenario). The category
      # holds the 6 per-faction text channels; @everyone is denied
      # VIEW_CHANNEL at category level, the matching Discord role
      # (`Tetrarchy - Legacy`, etc.) is granted.
      #
      # JSONB lookup is fine here — typical query is "for this
      # specific match, what's the category for faction X" which is
      # a key access on a single row.
      add(:faction_categories, :map, null: false, default: %{})

      # Audit fields.
      add(:promoted_by_discord_id, :string, null: false)

      # Phase 2 gate. Stays false until `opening_date - 6h`, at which
      # point a periodic check flips it true and triggers a one-time
      # role sync. After that, registration-change events drive
      # incremental updates.
      add(:role_assignment_active, :boolean, null: false, default: false)

      timestamps(type: :utc_datetime_usec)
    end

    # Each instance can only be promoted once — running /promote on an
    # already-promoted instance is an error, not an upsert. (You'd
    # delete the existing match row first via an admin path, which
    # we'll add when there's a real need.)
    create(unique_index(:discord_matches, [:instance_id]))

    # For the Phase 2 periodic sweep that looks for matches due for
    # role-assignment activation.
    create(
      index(:discord_matches, [:role_assignment_active],
        where: "role_assignment_active = false",
        name: :discord_matches_inactive_index
      )
    )
  end
end

defmodule RC.Repo.Migrations.CreateSystemIcons do
  use Ecto.Migration

  # Player-placed marker icons on stellar systems. One icon per
  # (instance, faction, system) — placement by anyone in the faction
  # silently overwrites the prior one (with the prior placer surfaced
  # in the faction event log).
  #
  # FK ON DELETE behavior:
  #   - instances: CASCADE — instance teardown drops everything
  #   - factions:  CASCADE — same scope as the faction itself
  #   - profiles:  SET NULL — keep the icon, render placer as
  #                "former member" once the profile is gone
  #
  # `icon_kind` is a short string ("shield" / "attack" / "flag" /
  # "path" / "danger" / "target" / "question"). Stored as text rather
  # than a postgres enum so adding a kind later doesn't require a
  # migration; validation lives in RC.Instances.SystemIcon.
  def change do
    create table(:system_icons) do
      add(:instance_id, references(:instances, on_delete: :delete_all), null: false)
      add(:faction_id, references(:factions, on_delete: :delete_all), null: false)
      add(:system_id, :integer, null: false)
      add(:placer_profile_id, references(:profiles, on_delete: :nilify_all), null: true)
      add(:icon_kind, :string, null: false)

      timestamps(updated_at: false, type: :utc_datetime_usec)
    end

    # One icon per faction per system — placement overwrites.
    create(unique_index(:system_icons, [:instance_id, :faction_id, :system_id]))
    # Faction load on agent boot reads by (instance_id, faction_id).
    create(index(:system_icons, [:instance_id, :faction_id]))
    # Per-player cap enforcement reads by placer.
    create(index(:system_icons, [:placer_profile_id]))
  end
end

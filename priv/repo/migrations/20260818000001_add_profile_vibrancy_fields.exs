defmodule RC.Repo.Migrations.AddProfileVibrancyFields do
  use Ecto.Migration

  # Player-profile "vibrancy" batch:
  #
  # accounts.timezone            — IANA zone name (e.g. "America/Chicago"),
  #                                validated against Tzdata at the changeset.
  # accounts.discord_timezone_role — opt-in: mirror the timezone as a Discord
  #                                guild role tag (created on demand).
  # accounts.show_profile_in_discord — opt-in: allow the /player Discord
  #                                command to render this account's profiles.
  # profiles.favorite_faction    — one of the five faction keys.
  # profiles.favorite_icon       — an in-game icon name ("ship/frigate_1"),
  #                                validated against priv/data/profile_icons.json.
  #
  # `profiles.age` is deliberately NOT dropped here: the removal is
  # API-level only (no longer cast, rendered, or editable) so this
  # migration stays trivially reversible while the column ages out.
  def change do
    alter table(:accounts) do
      add(:timezone, :string)
      add(:discord_timezone_role, :boolean, default: false, null: false)
      add(:show_profile_in_discord, :boolean, default: false, null: false)
    end

    alter table(:profiles) do
      add(:favorite_faction, :string)
      add(:favorite_icon, :string)
    end
  end
end

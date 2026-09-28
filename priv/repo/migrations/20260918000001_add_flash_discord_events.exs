defmodule RC.Repo.Migrations.AddFlashDiscordEvents do
  use Ecto.Migration

  # Guild scheduled events for scheduled Flash matches
  # (RC.Discord.FlashEvent). One Discord event per occurrence, created
  # with the lobby 48h ahead and patched as players register and the
  # match runs.
  #
  # * discord_event_id     — the guild scheduled event's snowflake, as
  #   text (same convention as accounts.discord_id).
  # * discord_event_status — the last status pushed to Discord:
  #   scheduled | active | completed | cancelled | failed. The last two
  #   are terminal for us; "failed" means creation was refused and is
  #   not retried (clear the column to try again).
  # * discord_event_digest — fingerprint of the last pushed name +
  #   description + status, so an unchanged event is never re-PATCHed.
  def change do
    alter table(:flash_scheduled_matches) do
      add(:discord_event_id, :string)
      add(:discord_event_status, :string)
      add(:discord_event_digest, :string)
    end
  end
end

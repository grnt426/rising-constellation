defmodule RC.Repo.Migrations.AddMatchAnnouncementTimestamps do
  use Ecto.Migration

  # Announcement bookkeeping for promoted Legacy matches.
  #
  # Per the operator's spec, the bot posts to the community-server
  # announce channel at TWO state transitions, not on /promote:
  #
  #   * `announced_registration_at` — stamped when the instance moves
  #     into `open` state (registration is live)
  #   * `announced_live_at` — stamped when the instance moves into
  #     `running` state (the game actually starts)
  #
  # No fatigue / no reminder cadence: each is a one-shot. The bot's
  # periodic role-sync tick checks (state matches AND timestamp is
  # nil) before posting and stamping. That makes the announcement
  # robust against bot restarts and out-of-order promote-then-state-
  # change sequencing (e.g., promoting an instance that's already
  # in `open` still triggers the registration announcement on the
  # next tick).
  #
  # Both nullable: a match that's never been in the corresponding
  # state has nil; a match that has transitioned and been announced
  # has the post timestamp.
  def change do
    alter table(:discord_matches) do
      add(:announced_registration_at, :utc_datetime_usec, null: true)
      add(:announced_live_at, :utc_datetime_usec, null: true)
    end
  end
end

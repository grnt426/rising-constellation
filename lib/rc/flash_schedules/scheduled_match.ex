defmodule RC.FlashSchedules.ScheduledMatch do
  use Ecto.Schema

  import Ecto.Changeset

  # open     — lobby is up (created 48h before the scheduled start)
  # starting — a player pressed Start; the world is being built
  # started  — the match is running (or finished)
  # expired  — never started within 48h of the scheduled start; closed
  @statuses ~w(open starting started expired)

  schema "flash_scheduled_matches" do
    belongs_to(:schedule, RC.FlashSchedules.Schedule)
    belongs_to(:instance, RC.Instances.Instance)
    field(:scheduled_start_at, :utc_datetime_usec)
    field(:status, :string, default: "open")
    field(:min_players, :integer, default: 2)
    field(:announced_at, :utc_datetime_usec)
    field(:started_at, :utc_datetime_usec)
    belongs_to(:started_by_account, RC.Accounts.Account)
    field(:result_posted_at, :utc_datetime_usec)
    # Discord guild scheduled event (RC.Discord.FlashEvent).
    field(:discord_event_id, :string)
    field(:discord_event_status, :string)
    field(:discord_event_digest, :string)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(match, attrs) do
    match
    |> cast(attrs, [
      :schedule_id,
      :instance_id,
      :scheduled_start_at,
      :status,
      :min_players,
      :announced_at,
      :started_at,
      :started_by_account_id,
      :result_posted_at,
      :discord_event_id,
      :discord_event_status,
      :discord_event_digest
    ])
    |> validate_required([:instance_id, :scheduled_start_at, :status])
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint([:schedule_id, :scheduled_start_at])
    |> unique_constraint(:instance_id)
  end
end

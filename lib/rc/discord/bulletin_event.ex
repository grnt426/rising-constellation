defmodule RC.Discord.BulletinEvent do
  @moduledoc """
  One accumulated game event bound for a match's daily summary
  bulletin (`RC.Discord.DailyBulletin`).

  Written by `Game.News.Server` for `discord_ready` instances only —
  the raw wire events that players agreed should reach Discord as a
  once-a-day digest instead of an instant post:

    * `"battle"`   — a fleet engagement (payload carries factions,
      winners/losers, system/sector for the 2-faction detail level)
    * `"raid"`     — a successful orbital bombardment
    * `"loot"`     — a successful pillage
    * `"conquest"` — a system taken by siege

  Rows are consumed (deleted) by the bulletin post that summarizes
  them, so the table holds at most ~one day of events per live match.
  Payloads are stored verbatim; the bulletin renderer decides how much
  detail each faction-count tier reveals.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "discord_bulletin_events" do
    field(:kind, :string)
    field(:payload, :map, default: %{})

    belongs_to(:instance, RC.Instances.Instance)

    timestamps(updated_at: false, type: :utc_datetime_usec)
  end

  @doc false
  def changeset(event, attrs) do
    event
    |> cast(attrs, [:instance_id, :kind, :payload])
    |> validate_required([:instance_id, :kind])
    |> foreign_key_constraint(:instance_id)
  end
end

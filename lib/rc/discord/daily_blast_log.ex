defmodule RC.Discord.DailyBlastLog do
  @moduledoc """
  Once-a-day latch row for the daily-challenge winners blast: one row
  per daily date (ISO-8601 string, same keying as `Daily.Entry`) whose
  blast has been posted. `RC.Discord.DailyChallengeBlast` inserts it
  after a successful post; the unique index makes a duplicate blast
  impossible even across restarts.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "discord_daily_blasts" do
    field(:date, :string)

    timestamps(updated_at: false, type: :utc_datetime_usec)
  end

  @doc false
  def changeset(log, attrs) do
    log
    |> cast(attrs, [:date])
    |> validate_required([:date])
    |> unique_constraint(:date)
  end
end

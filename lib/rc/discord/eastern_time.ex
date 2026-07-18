defmodule RC.Discord.EasternTime do
  @moduledoc """
  Shared US-Eastern wall-clock plumbing for the Discord features (the
  /promote start-time modal, the daily-bulletin slots). One home for
  the timezone name, the tz database, and the DST disambiguation
  policy so every Discord surface agrees on what "12:00 Eastern"
  means.
  """

  @timezone "America/New_York"
  @tz_db Tzdata.TimeZoneDatabase

  @doc "The IANA timezone all Discord scheduling uses."
  def timezone, do: @timezone

  @doc """
  Resolve a naive Eastern wall time to a `DateTime`. DST policy:
  the fall-back repeated hour takes its FIRST occurrence; the
  spring-forward gap lands just after it.
  """
  @spec from_naive(NaiveDateTime.t()) :: {:ok, DateTime.t()} | {:error, term()}
  def from_naive(%NaiveDateTime{} = naive) do
    case DateTime.from_naive(naive, @timezone, @tz_db) do
      {:ok, dt} -> {:ok, dt}
      {:ambiguous, first, _second} -> {:ok, first}
      {:gap, _before, after_dt} -> {:ok, after_dt}
      {:error, _} = err -> err
    end
  end

  @doc "Same as `from_naive/1` but raises on error."
  def from_naive!(%NaiveDateTime{} = naive) do
    {:ok, dt} = from_naive(naive)
    dt
  end

  @doc "Shift any DateTime to UTC."
  def to_utc(%DateTime{} = dt), do: DateTime.shift_zone!(dt, "Etc/UTC", @tz_db)

  @doc "The current civil date in US Eastern."
  def today do
    DateTime.utc_now()
    |> DateTime.shift_zone!(@timezone, @tz_db)
    |> DateTime.to_date()
  end
end

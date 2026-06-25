defmodule Daily.Entry do
  @moduledoc """
  A player's best score for a given day's daily challenge — one row per
  (profile, date). `Daily.record_score/5` upserts here, keeping the highest
  score across attempts; the leaderboard reads from it.
  """
  use Ecto.Schema

  import Ecto.Changeset

  schema "daily_entries" do
    field(:date, :string)
    field(:objective, :string)
    field(:score, :float)
    field(:instance_id, :integer)
    belongs_to(:profile, RC.Accounts.Profile)

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [:profile_id, :date, :objective, :score, :instance_id])
    |> validate_required([:profile_id, :date, :score])
    |> foreign_key_constraint(:profile_id)
    |> unique_constraint([:profile_id, :date], name: :daily_entries_profile_id_date_index)
  end
end

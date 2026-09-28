defmodule RC.Archive.Match do
  use Ecto.Schema

  schema "archive_matches" do
    field(:instance_id, :integer)
    field(:name, :string)
    field(:map_name, :string)
    field(:speed, :string)
    field(:started_at, :utc_datetime_usec)
    field(:ended_at, :utc_datetime_usec)
    field(:victory_type, :string)
    field(:winner_faction, :string)
    field(:player_count, :integer, default: 0)
    field(:system_count, :integer, default: 0)
    field(:factions, RC.Archive.Json, default: [])
    field(:summary, :map, default: %{})
    field(:map, :map, default: %{})
    field(:source, :map, default: %{})
    field(:published, :boolean, default: false)

    has_many(:faction_days, RC.Archive.FactionDay)
    has_many(:players, RC.Archive.Player)
    has_many(:unlocks, RC.Archive.Unlock)

    timestamps(type: :utc_datetime_usec)
  end
end

defmodule RC.Archive.FactionDay do
  use Ecto.Schema

  schema "archive_faction_days" do
    belongs_to(:match, RC.Archive.Match)
    field(:faction, :string)
    field(:day, :integer)
    field(:sampled_at, :utc_datetime_usec)
    field(:metrics, :map, default: %{})
  end
end

defmodule RC.Archive.Player do
  use Ecto.Schema

  schema "archive_players" do
    belongs_to(:match, RC.Archive.Match)
    field(:profile_id, :integer)
    field(:name, :string)
    field(:faction, :string)
    field(:metrics, :map, default: %{})
    field(:series, RC.Archive.Json, default: [])
  end
end

defmodule RC.Archive.Unlock do
  use Ecto.Schema

  schema "archive_unlocks" do
    belongs_to(:match, RC.Archive.Match)
    field(:kind, :string)
    field(:key, :string)
    field(:faction, :string)
    field(:player_count, :integer)
    field(:first_day, :integer)
  end
end

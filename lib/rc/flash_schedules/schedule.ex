defmodule RC.FlashSchedules.Schedule do
  use Ecto.Schema

  import Ecto.Changeset

  @game_mode_types ~w(casual ranked)

  schema "flash_schedules" do
    field(:name, :string)
    field(:description, :string, default: "")
    field(:enabled, :boolean, default: true)
    # ISO weekday, 1 = Monday .. 7 = Sunday.
    field(:weekday, :integer)
    # US Eastern wall-clock start (RC.Discord.EasternTime).
    field(:start_time, :time)
    field(:scenario_ids, {:array, :integer}, default: [])
    # nil = keep each scenario's own mutators; [] = none.
    field(:mutator_keys, {:array, :string})
    field(:game_mode_type, :string, default: "casual")
    field(:min_players, :integer, default: 2)
    field(:faction_capacity, :integer)
    field(:anchor_date, :date)
    belongs_to(:account, RC.Accounts.Account)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(schedule, attrs) do
    schedule
    |> cast(attrs, [
      :name,
      :description,
      :enabled,
      :weekday,
      :start_time,
      :scenario_ids,
      :mutator_keys,
      :game_mode_type,
      :min_players,
      :faction_capacity,
      :anchor_date,
      :account_id
    ])
    |> update_change(:description, &(&1 || ""))
    |> validate_required([:name, :weekday, :start_time, :scenario_ids, :game_mode_type, :min_players, :anchor_date])
    |> validate_length(:name, min: 1, max: 80)
    |> validate_length(:description, max: 2000)
    |> validate_number(:weekday, greater_than_or_equal_to: 1, less_than_or_equal_to: 7)
    |> validate_inclusion(:game_mode_type, @game_mode_types)
    |> validate_number(:min_players, greater_than_or_equal_to: 2, less_than_or_equal_to: 200)
    |> validate_number(:faction_capacity, greater_than_or_equal_to: 1, less_than_or_equal_to: 200)
    |> validate_length(:scenario_ids, min: 1, max: 20)
    |> validate_mutators()
  end

  defp validate_mutators(changeset) do
    validate_change(changeset, :mutator_keys, fn :mutator_keys, keys ->
      known = MapSet.new(Data.Game.Mutator.implemented(), &to_string(&1.key))

      case Enum.reject(keys || [], &MapSet.member?(known, &1)) do
        [] -> []
        unknown -> [mutator_keys: "unknown mutators: #{Enum.join(unknown, ", ")}"]
      end
    end)
  end
end

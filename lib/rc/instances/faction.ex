defmodule RC.Instances.Faction do
  use Ecto.Schema

  import Ecto.Changeset

  schema "factions" do
    field(:capacity, :integer)
    field(:faction_ref, :string)
    field(:registrations_count, :integer, virtual: true)
    field(:final_rank, :integer)
    # VP held when the victory was declared (RC.Instances.record_victory/2).
    field(:final_victory_points, :integer)

    belongs_to(:instance, RC.Instances.Instance)
    has_many(:registrations, RC.Instances.Registration, on_delete: :delete_all)

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(faction, attrs) do
    faction
    |> cast(attrs, [:faction_ref, :capacity, :instance_id, :final_rank, :final_victory_points])
    |> validate_required([:faction_ref, :capacity])
  end
end

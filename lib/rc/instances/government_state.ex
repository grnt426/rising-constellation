defmodule RC.Instances.GovernmentState do
  @moduledoc """
  Durable copy of an in-memory governance agent state (one row per
  instance × kind × faction). See `RC.Instances.GovernmentStates`.
  """

  use Ecto.Schema

  import Ecto.Changeset

  schema "government_states" do
    field(:instance_id, :integer)
    field(:faction_id, :integer, default: 0)
    field(:kind, :string)
    field(:rev, :integer, default: 0)
    field(:state, :binary)

    timestamps()
  end

  def changeset(struct, attrs) do
    struct
    |> cast(attrs, [:instance_id, :faction_id, :kind, :rev, :state])
    |> validate_required([:instance_id, :faction_id, :kind, :rev, :state])
    |> validate_inclusion(:kind, ["government", "diplomacy"])
  end
end

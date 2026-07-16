defmodule RC.Instances.InstanceFirst do
  @moduledoc """
  Per-instance "first to X" claim row. The unique index on
  `(instance_id, first_key)` is what makes the claim atomic — see
  `RC.InstanceFirsts.claim/1`.

  Winner FKs are nullable so non-player events (galaxy-wide milestones
  triggered by neutrals, bots, the system at large) can still record a
  first without a faction or registration.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "instance_firsts" do
    field(:first_key, :string)

    belongs_to(:instance, RC.Instances.Instance)
    belongs_to(:winning_faction, RC.Instances.Faction, foreign_key: :winning_faction_id)
    belongs_to(:winning_registration, RC.Instances.Registration, foreign_key: :winning_registration_id)

    timestamps(updated_at: false, type: :utc_datetime)
  end

  @doc false
  def changeset(first, attrs) do
    first
    |> cast(attrs, [:first_key, :instance_id, :winning_faction_id, :winning_registration_id])
    |> validate_required([:first_key, :instance_id])
    |> foreign_key_constraint(:instance_id)
    |> foreign_key_constraint(:winning_faction_id)
    |> foreign_key_constraint(:winning_registration_id)
    |> unique_constraint([:instance_id, :first_key])
  end
end

defmodule RC.Instances.SystemIcon do
  use Ecto.Schema

  import Ecto.Changeset

  # Allowed icon kinds. Adding one here + a frontend SVG is enough — no
  # migration needed. Names are intentionally generic so a faction can
  # ascribe its own meaning ("shield" can be "ally", "defend", "stay
  # away", whatever the faction's Discord agreed on).
  @kinds ~w(shield attack flag path danger target question)

  def kinds(), do: @kinds

  def jason(),
    do: [only: [:id, :system_id, :faction_id, :placer_profile_id, :icon_kind, :inserted_at]]

  schema "system_icons" do
    field(:system_id, :integer)
    field(:icon_kind, :string)
    belongs_to(:instance, RC.Instances.Instance)
    belongs_to(:faction, RC.Instances.Faction)
    belongs_to(:placer_profile, RC.Accounts.Profile)

    timestamps(updated_at: false, type: :utc_datetime_usec)
  end

  @doc false
  def changeset(icon, attrs) do
    icon
    |> cast(attrs, [:instance_id, :faction_id, :system_id, :placer_profile_id, :icon_kind])
    |> validate_required([:instance_id, :faction_id, :system_id, :icon_kind])
    |> validate_inclusion(:icon_kind, @kinds)
    |> foreign_key_constraint(:instance_id)
    |> foreign_key_constraint(:faction_id)
    |> foreign_key_constraint(:placer_profile_id)
  end
end

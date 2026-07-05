defmodule RC.Instances.FactionEventLog do
  use Ecto.Schema

  import Ecto.Changeset

  # Event types this log currently knows about. Validation rejects
  # everything else so a typo at the call site can't sneak garbage
  # into a faction's history.
  @event_types ~w(icon_removed icon_replaced election_opened election_closed government_seat_changed government_dissolved taxes_changed laws_changed government_purchase treasury_distributed diplomacy_changed)

  def event_types(), do: @event_types

  def jason(),
    do: [
      only: [
        :id,
        :instance_id,
        :faction_id,
        :actor_profile_id,
        :target_profile_id,
        :event_type,
        :payload,
        :inserted_at
      ]
    ]

  schema "faction_event_log" do
    field(:event_type, :string)
    # JSON-encoded — kind names, system name, and a snapshot of the
    # actor / target display names live here so a profile deletion
    # later doesn't make a row unreadable.
    field(:payload, :string)
    belongs_to(:instance, RC.Instances.Instance)
    belongs_to(:faction, RC.Instances.Faction)
    belongs_to(:actor_profile, RC.Accounts.Profile)
    belongs_to(:target_profile, RC.Accounts.Profile)

    timestamps(updated_at: false, type: :utc_datetime_usec)
  end

  @doc false
  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [
      :instance_id,
      :faction_id,
      :actor_profile_id,
      :target_profile_id,
      :event_type,
      :payload
    ])
    |> validate_required([:instance_id, :faction_id, :event_type, :payload])
    |> validate_inclusion(:event_type, @event_types)
    |> foreign_key_constraint(:instance_id)
    |> foreign_key_constraint(:faction_id)
    |> foreign_key_constraint(:actor_profile_id)
    |> foreign_key_constraint(:target_profile_id)
  end
end

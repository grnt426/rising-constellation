defmodule RC.Instances.InstanceEvent do
  use Ecto.Schema

  import Ecto.Changeset

  # Event kinds this log knows about. Validation rejects everything
  # else so a typo at an emit site can't silently poison the timeline.
  #
  #   siege_started            — a conquest/raid/loot siege began
  #   siege_released           — a siege ended cleanly (action resolved
  #                              or the explicit release path ran)
  #   siege_orphaned_released  — the tick-sweep backstop released a
  #                              siege whose besieging fleet was gone
  #                              (an invariant violation worth alerting on)
  #   action_started/_finished/_aborted — action-trace events, emitted
  #                              only while RC.DebugFlags.action_trace?/0
  #                              is on. `payload.type` carries the action
  #                              type (jump/conquest/raid/loot/...).
  @kinds ~w(
    siege_started
    siege_released
    siege_orphaned_released
    action_started
    action_finished
    action_aborted
  )

  def kinds(), do: @kinds

  def jason(),
    do: [
      only: [
        :id,
        :instance_id,
        :kind,
        :character_id,
        :system_id,
        :payload,
        :inserted_at
      ]
    ]

  schema "instance_event_log" do
    field(:kind, :string)
    # Game-domain ids (in-memory agent ids), not DB foreign keys.
    field(:character_id, :integer)
    field(:system_id, :integer)
    # JSON-encoded free-form details (action type, siege duration,
    # release cause, besieger id, ...).
    field(:payload, :string)
    belongs_to(:instance, RC.Instances.Instance)

    timestamps(updated_at: false, type: :utc_datetime_usec)
  end

  @doc false
  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [:instance_id, :kind, :character_id, :system_id, :payload])
    |> validate_required([:instance_id, :kind, :payload])
    |> validate_inclusion(:kind, @kinds)
    |> foreign_key_constraint(:instance_id)
  end
end

defmodule Instance.Faction.SystemIcon do
  use TypedStruct
  use Util.MakeEnumerable

  # In-memory mirror of an RC.Instances.SystemIcon row. The Faction.Agent
  # keeps a list of these so reads (broadcasts, render-state) never hit
  # the DB; mutations write through to RC.Instances.SystemIcons and then
  # update this list.
  #
  # Field shape matches what the frontend needs to render and attribute:
  # the system the icon is on, which kind, who placed it, and when. The
  # `placer_id` mirrors the DB's `placer_profile_id` and may be nil if
  # the placer's profile was later deleted (the FK is SET NULL); in that
  # case the UI renders "former member".

  def jason(), do: []

  typedstruct enforce: true do
    field(:id, integer())
    field(:system_id, integer())
    field(:placer_id, integer() | nil)
    field(:kind, String.t())
    field(:placed_at, integer())
  end

  def from_db(%RC.Instances.SystemIcon{} = row) do
    %__MODULE__{
      id: row.id,
      system_id: row.system_id,
      placer_id: row.placer_profile_id,
      kind: row.icon_kind,
      placed_at: DateTime.to_unix(row.inserted_at, :second)
    }
  end
end

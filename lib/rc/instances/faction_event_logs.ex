defmodule RC.Instances.FactionEventLogs do
  @moduledoc """
  Persistence layer for the faction-scoped audit log. Mirrors
  RC.Instances.SystemIcons in shape: all functions are intended to be
  called synchronously from inside the Faction.Agent (write path) or
  from the channel handler (read path).
  """

  import Ecto.Query, warn: false

  alias RC.Repo
  alias RC.Instances.FactionEventLog

  # Cap returned to the client per request. Tuned to comfortably fill
  # the Reports panel on a typical screen without forcing pagination
  # in v1; a follow-up can add page/limit args if a faction's log
  # genuinely grows beyond this in normal use.
  @default_limit 100

  @doc """
  Write a new event. `payload` is a plain map and gets JSON-encoded
  here so callers don't need to import Jason. Returns
  `{:ok, %FactionEventLog{}}` or `{:error, changeset}` — the latter
  is swallowed by callers that don't want to crash the place/remove
  path over a non-critical audit failure.
  """
  def record(attrs) do
    attrs = Map.update(attrs, :payload, "{}", &Jason.encode!/1)

    %FactionEventLog{}
    |> FactionEventLog.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Most recent entries for `(instance_id, faction_id)`. Newest first.
  """
  def list_for_faction(instance_id, faction_id, limit \\ @default_limit) do
    from(e in FactionEventLog,
      where: e.instance_id == ^instance_id and e.faction_id == ^faction_id,
      order_by: [desc: e.inserted_at],
      limit: ^limit
    )
    |> Repo.all()
  end
end

defmodule RC.Instances.GovernmentStates do
  @moduledoc """
  Write-through durability for faction-government and diplomacy agent
  state (design: docs/faction-government.md §2.2 durability).

  The in-memory agents remain authoritative; this table exists because a
  CRASHED agent restarts from its genesis child-spec (the periodic
  instance snapshot only helps across whole-instance restores). Every
  government/diplomacy mutation upserts the full term-encoded state here
  under a monotonic `rev`; on the first touch after a process (re)start
  the agent hydrates from the row when its rev is ahead of memory.

  Writes are BEST-EFFORT by contract: callers wrap in `persist/5` which
  never raises — headless instances have no `instances` row (FK) and a
  down DB must never take a faction agent with it. A lost write costs at
  most one mutation of durability, strictly better than the status quo.
  """

  import Ecto.Query, warn: false

  require Logger

  alias RC.Instances.GovernmentState
  alias RC.Repo

  @doc """
  Upsert the durable copy. `scope_id` is the faction id for kind
  "government", 0 for instance-scoped kinds (diplomacy). Never raises.
  """
  def persist(instance_id, scope_id, kind, rev, term) do
    binary = :erlang.term_to_binary(term)

    %GovernmentState{}
    |> GovernmentState.changeset(%{
      instance_id: instance_id,
      faction_id: scope_id,
      kind: kind,
      rev: rev,
      state: binary
    })
    |> Repo.insert(
      on_conflict: [set: [rev: rev, state: binary, updated_at: DateTime.utc_now()]],
      conflict_target: [:instance_id, :kind, :faction_id]
    )
    |> case do
      {:ok, _} -> :ok
      {:error, changeset} -> log_skip(instance_id, kind, inspect(changeset.errors))
    end
  rescue
    # FK misses (headless instances), encoding surprises, DB down — all
    # non-fatal by design.
    e -> log_skip(instance_id, kind, Exception.message(e))
  end

  @doc """
  The durable copy, decoded, or nil. Decode goes through the snapshot
  pipeline's safe path (atom-universe interning + `binary_to_term`
  `:safe`) — a corrupt or undecodable row is treated as absent rather
  than crashing the hydrating agent.
  """
  def fetch(instance_id, scope_id, kind) do
    row =
      Repo.one(
        from(g in GovernmentState,
          where: g.instance_id == ^instance_id and g.faction_id == ^scope_id and g.kind == ^kind
        )
      )

    with %GovernmentState{rev: rev, state: binary} <- row,
         {:ok, term} <- Util.Storage.decode_binary(binary) do
      {rev, term}
    else
      nil ->
        nil

      other ->
        Logger.warning("government_states: undecodable row dropped",
          instance_id: instance_id,
          kind: kind,
          detail: inspect(other)
        )

        nil
    end
  rescue
    e ->
      Logger.warning("government_states: fetch failed: #{Exception.message(e)}",
        instance_id: instance_id,
        kind: kind
      )

      nil
  end

  defp log_skip(instance_id, kind, detail) do
    # Expected for headless instances (no instances row) — keep quiet
    # enough not to spam marathon logs, loud enough to see in dev.
    Logger.debug("government_states: persist skipped: #{detail}",
      instance_id: instance_id,
      kind: kind
    )

    :ok
  end
end

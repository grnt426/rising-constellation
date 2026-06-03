defmodule RC.Instances.SystemIcons do
  @moduledoc """
  Persistence layer for player-placed marker icons on stellar systems.

  All public functions are intended to be called from inside the
  Faction.Agent (or its boot path in Instance.Manager) — they perform
  synchronous DB work and return values the agent uses to update its
  in-memory cache and to emit broadcasts / audit-log entries.
  """

  import Ecto.Query, warn: false

  alias RC.Repo
  alias RC.Instances.SystemIcon

  @doc """
  Load every icon currently placed by `faction_id` in `instance_id`.
  Called once when the Faction.Agent boots so its in-memory cache
  matches the DB.
  """
  def list_for_faction(instance_id, faction_id) do
    from(i in SystemIcon,
      where: i.instance_id == ^instance_id and i.faction_id == ^faction_id
    )
    |> Repo.all()
  end

  @doc """
  Per-player icon count across an entire instance — used to enforce the
  cap (default 50 in Faction.Faction).
  """
  def count_for_placer(instance_id, placer_profile_id) do
    from(i in SystemIcon,
      where: i.instance_id == ^instance_id and i.placer_profile_id == ^placer_profile_id,
      select: count()
    )
    |> Repo.one()
  end

  @doc """
  Place an icon for `(instance_id, faction_id, system_id)`, silently
  overwriting any prior icon at that key. Returns
  `{:ok, %{previous: prev_or_nil, current: new_icon}}` so the caller
  can audit-log the overwrite if `previous` is non-nil and belongs to
  a different placer.
  """
  def place(attrs) do
    Repo.transaction(fn ->
      previous = get_existing(attrs[:instance_id], attrs[:faction_id], attrs[:system_id])

      if previous, do: Repo.delete!(previous)

      case %SystemIcon{}
           |> SystemIcon.changeset(attrs)
           |> Repo.insert() do
        {:ok, current} -> %{previous: previous, current: current}
        {:error, cs} -> Repo.rollback(cs)
      end
    end)
  end

  @doc """
  Remove the icon at `(instance_id, faction_id, system_id)` if any.
  Returns `{:ok, removed_or_nil}`.
  """
  def remove(instance_id, faction_id, system_id) do
    case get_existing(instance_id, faction_id, system_id) do
      nil -> {:ok, nil}
      icon -> {:ok, Repo.delete!(icon)}
    end
  end

  defp get_existing(instance_id, faction_id, system_id) do
    Repo.one(
      from(i in SystemIcon,
        where:
          i.instance_id == ^instance_id and
            i.faction_id == ^faction_id and
            i.system_id == ^system_id
      )
    )
  end
end

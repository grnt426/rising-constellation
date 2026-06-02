defmodule RC.BotAssignments do
  @moduledoc """
  CRUD + queries for the stress-test bot roster (`bot_assignments` table).

  Two distinct callers:

    * The admin LiveView at `/admin/bots` — full CRUD for managing
      which bot plays in which game, per-bot policy/session overrides,
      and the enabled flag.

    * The bot harness — reads `list_runnable/0` via the HTTP endpoint
      to decide which sessions to spawn. The harness never writes
      directly.
  """

  import Ecto.Query

  alias RC.BotAssignments.Assignment
  alias RC.Repo

  @doc """
  All assignments, ordered by account_id, with `:account` + `:instance` +
  `:faction` preloaded for dashboard rendering.
  """
  def list_all do
    Assignment
    |> order_by([a], asc: a.account_id)
    |> preload([:account, :instance, :faction])
    |> Repo.all()
  end

  @doc """
  Assignments the orchestrator should actually spawn sessions for —
  enabled, with a non-null instance_id and faction_id. Preloads the
  account for credential access.
  """
  def list_runnable do
    from(a in Assignment,
      where: a.enabled == true and not is_nil(a.instance_id) and not is_nil(a.faction_id)
    )
    |> preload([:account])
    |> Repo.all()
  end

  @doc """
  Fetch by primary key. Returns nil if not found.
  """
  def get(id), do: Repo.get(Assignment, id) |> preload_assocs()

  @doc """
  Fetch by account_id (the unique key). Returns nil if not found.
  """
  def get_by_account(account_id) do
    Repo.get_by(Assignment, account_id: account_id) |> preload_assocs()
  end

  @doc """
  Create or update by account_id. Mirrors how the dashboard wants to
  think about assignments — one bot, one current assignment.
  """
  def upsert(attrs) do
    case attrs[:account_id] || attrs["account_id"] do
      nil ->
        {:error, :missing_account_id}

      account_id ->
        existing = Repo.get_by(Assignment, account_id: account_id) || %Assignment{}

        existing
        |> Assignment.changeset(attrs)
        |> Repo.insert_or_update()
    end
  end

  @doc """
  Flip the `enabled` flag without touching anything else. Used by the
  per-bot toggle in the dashboard. Returns `{:error, :not_found}` if
  the assignment doesn't exist yet — caller should `upsert` first.
  """
  def set_enabled(account_id, enabled?) when is_boolean(enabled?) do
    case Repo.get_by(Assignment, account_id: account_id) do
      nil ->
        {:error, :not_found}

      assignment ->
        assignment
        |> Assignment.changeset(%{enabled: enabled?})
        |> Repo.update()
    end
  end

  @doc """
  Stamp the assignment's `last_session_at` to now. Fire-and-forget from
  the orchestrator on session start. Tolerant of missing rows so a
  deleted assignment doesn't crash the orchestrator.
  """
  def stamp_session_start(account_id) do
    now = DateTime.utc_now()

    from(a in Assignment, where: a.account_id == ^account_id)
    |> Repo.update_all(set: [last_session_at: now])

    :ok
  end

  @doc """
  Delete an assignment. Use with care from the dashboard; the bot
  account itself isn't touched.
  """
  def delete(id) do
    case Repo.get(Assignment, id) do
      nil -> {:error, :not_found}
      assignment -> Repo.delete(assignment)
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────

  defp preload_assocs(nil), do: nil
  defp preload_assocs(assignment), do: Repo.preload(assignment, [:account, :instance, :faction])
end

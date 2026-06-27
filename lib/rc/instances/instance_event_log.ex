defmodule RC.Instances.InstanceEventLog do
  @moduledoc """
  Write/read layer for the instance-scoped agent event log
  (`instance_event_log`).

  The write path (`emit/3`) is called from inside the hot game agents
  (stellar-system, character, action-orchestrator), so it is
  **fire-and-forget and best-effort**: the insert runs on the central
  `RC.TaskSupervisor` and any failure is logged, never raised — a
  missed audit row must never stall a tick or crash an agent.

  The read path (`list_for_instance/2`, `recent_sieges/2`) is for
  operators / forensics and runs synchronously against the repo.
  """

  import Ecto.Query, warn: false
  require Logger

  alias RC.Repo
  alias RC.Instances.InstanceEvent

  @default_limit 500

  @doc """
  Append an event. Returns `:ok` immediately; the DB write happens
  asynchronously and best-effort.

  `attrs` may carry `:character_id`, `:system_id`, and `:payload`
  (a plain map, JSON-encoded here). Unknown/omitted keys are fine.

  ## Examples

      InstanceEventLog.emit(iid, "siege_started", %{
        system_id: sys_id, character_id: besieger_id,
        payload: %{type: :conquest, duration: time, besieger_id: besieger_id}
      })
  """
  def emit(instance_id, kind, attrs \\ %{}) do
    record = %{
      instance_id: instance_id,
      kind: kind,
      character_id: Map.get(attrs, :character_id),
      system_id: Map.get(attrs, :system_id),
      payload: attrs |> Map.get(:payload, %{}) |> encode_payload()
    }

    Task.Supervisor.start_child(RC.TaskSupervisor, fn -> insert(record) end)
    :ok
  rescue
    # Even spawning the task must never take down the caller.
    e ->
      Logger.error("instance_event_log emit failed to enqueue: #{inspect(e)}")
      :ok
  end

  @doc """
  Most recent events for an instance, newest first. Optional
  `:kind` filters to a single event kind; `:limit` caps the result
  (default #{@default_limit}).
  """
  def list_for_instance(instance_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_limit)

    query =
      from(e in InstanceEvent,
        where: e.instance_id == ^instance_id,
        order_by: [desc: e.inserted_at, desc: e.id],
        limit: ^limit
      )

    query =
      case Keyword.get(opts, :kind) do
        nil -> query
        kind -> from(e in query, where: e.kind == ^kind)
      end

    Repo.all(query)
  end

  @doc """
  Convenience: the siege-lifecycle slice of the log for an instance,
  newest first. Handy for "did any siege orphan?" sweeps.
  """
  def recent_sieges(instance_id, limit \\ @default_limit) do
    from(e in InstanceEvent,
      where:
        e.instance_id == ^instance_id and
          e.kind in ["siege_started", "siege_released", "siege_orphaned_released"],
      order_by: [desc: e.inserted_at, desc: e.id],
      limit: ^limit
    )
    |> Repo.all()
  end

  ## Private

  defp insert(record) do
    %InstanceEvent{}
    |> InstanceEvent.changeset(record)
    |> Repo.insert()
  rescue
    e ->
      Logger.warning("instance_event_log insert failed: #{inspect(e)}")
      :error
  end

  # Payloads are author-controlled small maps, but guard against a
  # stray non-encodable term (e.g. a struct or tuple) poisoning the
  # write — fall back to an inspect string rather than crashing.
  defp encode_payload(payload) do
    Jason.encode!(payload)
  rescue
    _ -> Jason.encode!(%{raw: inspect(payload)})
  end
end

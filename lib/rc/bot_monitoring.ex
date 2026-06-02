defmodule RC.BotMonitoring do
  @moduledoc """
  Capture and query bot activity for the `/admin/bots` dashboard.

  Two write paths:

    * `record_action/4` — called from PlayerChannel / CheatChannel
      handlers after each push, gated on `socket.assigns.account.is_bot`.
      No-op for real players.

    * `record_lifecycle/1` — called from the `/api/bot-events` endpoint
      when the bot harness reports its own lifecycle events (login,
      disconnect, burst boundaries, sleep windows). Also called
      server-side for events we observe directly (channel join, leave).

  Read path:

    * `summary/0` — top-line aggregates for the dashboard header
      (total bots, active now, events last hour, error rate).
    * `active_bots/0` — bots that have done anything recently, with
      last-seen timestamp and stuck flag.
    * `recent_events/1` — filtered paginated event stream.
  """

  import Ecto.Query

  alias RC.BotMonitoring.Event
  alias RC.Repo

  # A bot whose last event is older than this is flagged as "stuck" in the
  # dashboard. Generous enough to not flag bots that are mid-sleep between
  # bursts; tight enough to catch a hung session within a minute or two.
  @stuck_threshold_seconds 120

  # "Active in the last N seconds" for the active_bots query. Anything
  # older isn't shown unless the operator opens the historical view.
  @active_window_seconds 600

  # ── WRITE PATH ──────────────────────────────────────────────────────

  @doc """
  Record a channel action taken by a bot. Returns `:ok` regardless of
  outcome — we never want monitoring writes to break the game path.

  `socket` is the Phoenix channel socket; we expect `socket.assigns.account`
  and `socket.assigns.instance_id` / `:player_id`.

  `result` is the value the agent returned (`:ok`, `{:ok, _}`, `{:error, reason}`,
  etc.). We classify it into `status` + optional `reason` for storage.
  """
  def record_action(socket, event_name, channel, result, duration_us \\ nil) do
    if bot_socket?(socket) do
      {status, reason} = classify(result)

      attrs = %{
        account_id: socket.assigns.account.id,
        profile_id: socket.assigns[:player_id],
        instance_id: socket.assigns[:instance_id],
        event_type: "action",
        event_name: to_string(event_name),
        channel: to_string(channel),
        status: status,
        reason: reason,
        duration_ms: us_to_ms(duration_us)
      }

      insert_async(attrs)
    end

    :ok
  end

  defp us_to_ms(nil), do: nil
  defp us_to_ms(us) when is_integer(us), do: div(us, 1000)

  @doc """
  Insert a lifecycle event (login, register, disconnect, burst_*, sleep
  boundaries, etc.). Caller has already authorised the report.

  Accepts a map with at least `:event_name` and `:status`; everything
  else is optional.
  """
  def record_lifecycle(%{event_name: _, status: _} = attrs) do
    attrs
    |> Map.put_new(:event_type, "lifecycle")
    |> Map.put_new(:channel, "lifecycle")
    |> normalize_attrs()
    |> insert_async()

    :ok
  end

  # ── READ PATH ───────────────────────────────────────────────────────

  @doc """
  Top-line aggregates for the dashboard header.
  """
  def summary do
    one_hour_ago = DateTime.add(DateTime.utc_now(), -3600, :second)
    active_cutoff = DateTime.add(DateTime.utc_now(), -@active_window_seconds, :second)

    %{
      total_bots: count_bots(),
      active_bots: count_active_bots(active_cutoff),
      events_last_hour: count_events_since(one_hour_ago),
      errors_last_hour: count_errors_since(one_hour_ago)
    }
  end

  @doc """
  Bots that have generated an event in the last N seconds (default 600),
  with their most-recent event timestamp and a stuck flag.

  Joins the account + instance for display names. Two passes: aggregate
  the events in SQL, then resolve names in a second query so the GROUP BY
  stays simple.
  """
  def active_bots do
    cutoff = DateTime.add(DateTime.utc_now(), -@active_window_seconds, :second)
    stuck_cutoff = DateTime.add(DateTime.utc_now(), -@stuck_threshold_seconds, :second)

    rows =
      from(e in Event,
        where: e.inserted_at > ^cutoff and not is_nil(e.account_id),
        group_by: [e.account_id, e.instance_id],
        select: %{
          account_id: e.account_id,
          instance_id: e.instance_id,
          last_seen: max(e.inserted_at),
          event_count: count(e.id),
          error_count:
            fragment(
              "COUNT(*) FILTER (WHERE ? = ?)",
              e.status,
              "error"
            )
        },
        order_by: [desc: max(e.inserted_at)]
      )
      |> Repo.all()

    account_names = lookup_account_names(Enum.map(rows, & &1.account_id))
    instance_names = lookup_instance_names(Enum.map(rows, & &1.instance_id))

    Enum.map(rows, fn row ->
      row
      |> Map.put(:stuck, DateTime.compare(row.last_seen, stuck_cutoff) == :lt)
      |> Map.put(:account_name, Map.get(account_names, row.account_id, "(unknown)"))
      |> Map.put(:instance_name, Map.get(instance_names, row.instance_id, "—"))
    end)
  end

  defp lookup_account_names(ids) do
    ids = Enum.uniq(Enum.reject(ids, &is_nil/1))

    from(a in RC.Accounts.Account, where: a.id in ^ids, select: {a.id, a.name})
    |> Repo.all()
    |> Map.new()
  end

  defp lookup_instance_names(ids) do
    ids = Enum.uniq(Enum.reject(ids, &is_nil/1))

    from(i in RC.Instances.Instance, where: i.id in ^ids, select: {i.id, i.name})
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  Recent events for the table view. Accepts optional filters.

      opts = [
        instance_id: 1,
        event_type: "action",
        account_id: 11,
        limit: 100
      ]
  """
  def recent_events(opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)

    Event
    |> maybe_filter(:account_id, opts[:account_id])
    |> maybe_filter(:instance_id, opts[:instance_id])
    |> maybe_filter(:event_type, opts[:event_type])
    |> order_by([e], desc: e.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Delete bot_events older than `cutoff_days` (default 30). Returns the
  number of rows deleted. Intended to be called periodically.
  """
  def prune_older_than(cutoff_days \\ 30) do
    cutoff = DateTime.add(DateTime.utc_now(), -cutoff_days * 86_400, :second)

    {count, _} =
      from(e in Event, where: e.inserted_at < ^cutoff)
      |> Repo.delete_all()

    count
  end

  # ── INTERNAL ────────────────────────────────────────────────────────

  defp bot_socket?(socket) do
    case socket.assigns do
      %{account: %{is_bot: true}} -> true
      _ -> false
    end
  end

  defp classify(:ok), do: {"ok", nil}
  defp classify({:ok, _}), do: {"ok", nil}
  defp classify({:error, reason}), do: {"error", truncate_reason(reason)}
  defp classify(other), do: {"info", truncate_reason(other)}

  defp truncate_reason(reason) do
    reason
    |> inspect()
    |> String.slice(0, 256)
  end

  defp normalize_attrs(attrs) do
    Enum.into(attrs, %{}, fn
      {k, v} when is_atom(v) -> {k, to_string(v)}
      kv -> kv
    end)
  end

  # Fire-and-forget DB insert. A monitoring write must never block the
  # caller (channel action or HTTP request). Supervised under
  # RC.TaskSupervisor; logs but does not raise on failure.
  defp insert_async(attrs) do
    Task.Supervisor.start_child(
      RC.TaskSupervisor,
      fn ->
        try do
          %Event{}
          |> Event.changeset(attrs)
          |> Repo.insert()
        rescue
          e ->
            require Logger
            Logger.warning("bot_monitoring insert failed: #{Exception.message(e)}")
        end
      end,
      restart: :temporary
    )
  end

  defp maybe_filter(query, _key, nil), do: query

  defp maybe_filter(query, key, value) do
    from(e in query, where: field(e, ^key) == ^value)
  end

  defp count_bots do
    from(a in RC.Accounts.Account, where: a.is_bot == true, select: count())
    |> Repo.one()
  end

  defp count_active_bots(cutoff) do
    from(e in Event,
      where: e.inserted_at > ^cutoff and not is_nil(e.account_id),
      select: count(e.account_id, :distinct)
    )
    |> Repo.one()
  end

  defp count_events_since(cutoff) do
    from(e in Event, where: e.inserted_at > ^cutoff, select: count()) |> Repo.one()
  end

  defp count_errors_since(cutoff) do
    from(e in Event, where: e.inserted_at > ^cutoff and e.status == "error", select: count())
    |> Repo.one()
  end
end

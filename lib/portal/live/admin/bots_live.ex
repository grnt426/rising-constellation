defmodule Portal.BotsLive do
  @moduledoc """
  Admin dashboard for stress-test bots. Reads from the `bot_events` table
  populated by `RC.BotMonitoring`.

  Refresh cadence: every #{5}s via `Process.send_after(self(), :refresh,
  ...)`. Polling is simpler than PubSub and good enough for stress-test
  observation — promote to push later if sub-second freshness ever
  matters.
  """

  use Portal, :admin_live_view

  import Ecto.Query

  alias RC.{BotAssignments, BotMonitoring}

  @refresh_ms 5_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: schedule_refresh()

    {:ok,
     socket
     |> assign(:refresh_ms, @refresh_ms)
     |> assign(:filter_instance_id, nil)
     |> assign(:filter_event_type, nil)
     |> load_dashboard()}
  end

  @impl true
  def handle_info(:refresh, socket) do
    schedule_refresh()
    {:noreply, load_dashboard(socket)}
  end

  @impl true
  def handle_event("filter", params, socket) do
    socket =
      socket
      |> assign(:filter_instance_id, parse_int(params["instance_id"]))
      |> assign(:filter_event_type, blank_to_nil(params["event_type"]))
      |> load_dashboard()

    {:noreply, socket}
  end

  def handle_event("toggle_assignment", %{"id" => id_str}, socket) do
    case Integer.parse(id_str) do
      {id, _} ->
        case BotAssignments.get(id) do
          nil ->
            {:noreply, socket}

          assignment ->
            BotAssignments.set_enabled(assignment.account_id, not assignment.enabled)
            {:noreply, load_dashboard(socket)}
        end

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("delete_assignment", %{"id" => id_str}, socket) do
    case Integer.parse(id_str) do
      {id, _} ->
        BotAssignments.delete(id)
        {:noreply, load_dashboard(socket)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("save_assignment", %{"assignment" => params}, socket) do
    attrs =
      %{}
      |> put_int(params, "account_id")
      |> put_int(params, "instance_id")
      |> put_int(params, "faction_id")
      |> put_int(params, "bursts_total")
      |> put_int(params, "inter_burst_ms_min")
      |> put_int(params, "inter_burst_ms_max")
      |> maybe_put(params, "policy")
      |> Map.put(:enabled, params["enabled"] == "true")

    case BotAssignments.upsert(attrs) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Assignment saved")
         |> load_dashboard()}

      {:error, changeset} ->
        {:noreply, put_flash(socket, :error, "Save failed: #{inspect(changeset.errors)}")}
    end
  end

  defp schedule_refresh do
    Process.send_after(self(), :refresh, @refresh_ms)
  end

  defp load_dashboard(socket) do
    filters = [
      instance_id: socket.assigns[:filter_instance_id],
      event_type: socket.assigns[:filter_event_type],
      limit: 100
    ]

    events = BotMonitoring.recent_events(filters)
    account_ids = events |> Enum.map(& &1.account_id) |> Enum.uniq() |> Enum.reject(&is_nil/1)

    account_names =
      from(a in RC.Accounts.Account, where: a.id in ^account_ids, select: {a.id, a.name})
      |> RC.Repo.all()
      |> Map.new()

    socket
    |> assign(:summary, BotMonitoring.summary())
    |> assign(:active_bots, BotMonitoring.active_bots())
    |> assign(:recent_events, events)
    |> assign(:account_names, account_names)
    |> assign(:now, DateTime.utc_now())
    |> assign(:assignments, BotAssignments.list_all())
    |> assign(:bot_accounts, list_bot_accounts())
    |> assign(:open_instances, list_open_instances())
    |> assign(:factions_by_instance, factions_by_instance())
  end

  defp put_int(attrs, params, key) do
    case parse_int(params[key]) do
      nil -> attrs
      n -> Map.put(attrs, String.to_atom(key), n)
    end
  end

  defp maybe_put(attrs, params, key) do
    case params[key] do
      nil -> attrs
      "" -> attrs
      v -> Map.put(attrs, String.to_atom(key), v)
    end
  end

  # ── Dropdown sources ─────────────────────────────────────────────

  defp list_bot_accounts do
    from(a in RC.Accounts.Account, where: a.is_bot == true, order_by: a.id, select: {a.id, a.name})
    |> RC.Repo.all()
  end

  defp list_open_instances do
    from(i in RC.Instances.Instance,
      where: i.state in ["open", "running"],
      order_by: i.id,
      select: {i.id, i.name, i.state, i.game_metadata}
    )
    |> RC.Repo.all()
  end

  # Returns %{instance_id => [{faction_id, faction_ref}, ...]} for the
  # template's faction selector. Computed once per dashboard load.
  defp factions_by_instance do
    from(f in RC.Instances.Faction,
      order_by: [f.instance_id, f.id],
      select: {f.instance_id, f.id, f.faction_ref}
    )
    |> RC.Repo.all()
    |> Enum.group_by(fn {iid, _, _} -> iid end, fn {_, fid, ref} -> {fid, ref} end)
  end

  defp parse_int(nil), do: nil
  defp parse_int(""), do: nil

  defp parse_int(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, _} -> n
      _ -> nil
    end
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(s), do: s

  # ── Template helpers ───────────────────────────────────────────────

  @doc false
  def humanize_ago(%DateTime{} = past, %DateTime{} = now) do
    diff = DateTime.diff(now, past, :second)

    cond do
      diff < 5 -> "just now"
      diff < 60 -> "#{diff}s ago"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      true -> "#{div(diff, 3600)}h ago"
    end
  end

  def humanize_ago(_, _), do: "—"

  @doc false
  def status_class("ok"), do: "is-green-1"
  def status_class("error"), do: "is-red-1"
  def status_class("info"), do: "is-grey"
  def status_class(_), do: "is-grey"

  @doc false
  def error_rate(%{events_last_hour: 0}), do: "0%"
  def error_rate(%{events_last_hour: total, errors_last_hour: errors}) do
    pct = Float.round(errors / total * 100, 1)
    "#{pct}%"
  end

  @doc false
  # Compact description of an instance's game_metadata for the assignment
  # table — e.g. "fast · 270 systems · 2 factions". Defensive against
  # missing fields so a partial scenario doesn't crash the row render.
  def describe_instance(nil), do: "—"

  def describe_instance(instance) do
    gm = instance.game_metadata || %{}
    parts = []
    parts = if gm["speed"], do: parts ++ [gm["speed"]], else: parts
    parts = if gm["system_number"], do: parts ++ ["#{gm["system_number"]} systems"], else: parts

    parts =
      case gm["factions"] do
        list when is_list(list) -> parts ++ ["#{length(list)} factions"]
        _ -> parts
      end

    case parts do
      [] -> "—"
      _ -> Enum.join(parts, " · ")
    end
  end
end

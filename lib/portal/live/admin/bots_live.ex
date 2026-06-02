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

  alias RC.BotMonitoring

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

end

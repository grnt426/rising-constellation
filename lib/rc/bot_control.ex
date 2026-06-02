defmodule RC.BotControl do
  @moduledoc """
  Global on/off switch for the stress-test bot fleet.

  Follows the same dual-storage pattern as `RC.Maintenance`:

    * `Portal.Config` (Horde.Registry) holds the live boolean for cheap
      reads by the dashboard, the orchestrator polling endpoint, and any
      LiveView template.

    * The audit trail goes into `bot_events` as `fleet_enabled` /
      `fleet_disabled` lifecycle rows so we get the timeline for free
      and don't need a separate settings table.

  ## Pause semantics

  Toggling to `false` means the orchestrator stops spawning **new**
  sessions. In-flight sessions complete their current burst loop and
  disconnect normally. So a pause goes from full activity to zero over
  the lifetime of the last in-flight session (~30-60s). There is
  intentionally no "kill everything now" path — the polite version is
  always preferable for a live stress run.

  ## Default

  On a fresh server (no prior `fleet_*` events) we default to `false`.
  Operators must explicitly enable the fleet from the dashboard. That
  way an unexpected rc restart never silently turns a paused fleet
  back on.
  """

  alias Portal.Config
  alias Portal.Controllers.PortalChannel
  alias RC.BotMonitoring

  @key :stress_test_enabled

  @doc """
  True iff the orchestrator should currently spawn new sessions.
  Cache-first; falls back to the latest `fleet_*` event in bot_events.
  """
  def enabled? do
    case Config.fetch_key(@key) do
      :error -> read_from_db()
      value when is_boolean(value) -> value
      _ -> false
    end
  end

  @doc """
  Persist a new fleet-enabled state. `account_id` is recorded with the
  audit event for the dashboard's "who flipped this" view.
  """
  def set_enabled(enabled?, account_id) when is_boolean(enabled?) do
    Config.update_key(@key, enabled?)

    BotMonitoring.record_lifecycle(%{
      account_id: account_id,
      event_name: if(enabled?, do: "fleet_enabled", else: "fleet_disabled"),
      status: "ok",
      channel: "control"
    })

    # Notify any open admin dashboards so the indicator updates without
    # waiting for the 5s poll tick.
    PortalChannel.broadcast_change("portal:user:*", %{stress_test_enabled: enabled?})

    :ok
  end

  @doc """
  Called at startup (via `Portal.Config.init_config`) to seed the cache
  with whatever state was last persisted, defaulting to `false`.
  """
  def initial_state do
    read_from_db()
  end

  defp read_from_db do
    import Ecto.Query

    q =
      from(e in RC.BotMonitoring.Event,
        where: e.event_name in ["fleet_enabled", "fleet_disabled"],
        order_by: [desc: e.inserted_at],
        limit: 1,
        select: e.event_name
      )

    case RC.Repo.one(q) do
      "fleet_enabled" -> true
      _ -> false
    end
  end
end

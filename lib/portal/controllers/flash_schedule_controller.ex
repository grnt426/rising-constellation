defmodule Portal.FlashScheduleController do
  @moduledoc """
  Scheduled Flash matches (RC.FlashSchedules).

      GET    /flash/schedules?from&to   schedules + calendar entries in [from, to)
      POST   /flash/schedules           admin: %{schedule: attrs}
      PUT    /flash/schedules/:id       admin: %{schedule: attrs}
      DELETE /flash/schedules/:id       admin

      PUT    /flash/matches/:iid/ready  %{ready: bool} — the caller's ready flag
      POST   /flash/matches/:iid/start  start the lobby (any joined player)

  Schedule times are US Eastern wall-clock (`start_time` "HH:MM:SS").
  """
  use Portal, :controller

  alias RC.Discord.EasternTime
  alias RC.FlashSchedules

  action_fallback(Portal.FallbackController)

  @default_range_days 42
  @max_range_days 100

  def index(conn, params) do
    now = DateTime.utc_now()
    from = parse_datetime(params["from"]) || now
    to = parse_datetime(params["to"]) || DateTime.add(from, @default_range_days * 86_400)
    to = Enum.min([to, DateTime.add(from, @max_range_days * 86_400)], DateTime)

    schedules = FlashSchedules.list_schedules()
    maps = FlashSchedules.scenario_summaries(Enum.flat_map(schedules, & &1.scenario_ids))

    json(conn, %{
      time_zone: EasternTime.timezone(),
      schedules: Enum.map(schedules, &schedule_json(&1, maps, now)),
      calendar: FlashSchedules.calendar(from, to, now)
    })
  end

  def create(conn, %{"schedule" => attrs}) do
    with {:ok, schedule} <- FlashSchedules.create_schedule(attrs, conn.private.guardian_default_resource.id) do
      conn |> put_status(201) |> json(one(schedule))
    end
  end

  def update(conn, %{"id" => id, "schedule" => attrs}) do
    with schedule when not is_nil(schedule) <- FlashSchedules.get_schedule(id) || {:error, :not_found},
         {:ok, schedule} <- FlashSchedules.update_schedule(schedule, attrs) do
      json(conn, one(schedule))
    end
  end

  def delete(conn, %{"id" => id}) do
    with schedule when not is_nil(schedule) <- FlashSchedules.get_schedule(id) || {:error, :not_found},
         {:ok, _} <- FlashSchedules.delete_schedule(schedule) do
      send_resp(conn, 204, "")
    end
  end

  def ready(conn, %{"iid" => iid} = params) do
    ready? = params["ready"] in [true, "true"]

    case FlashSchedules.set_ready(to_int(iid), account_id(conn), ready?) do
      {:ok, lobby} -> json(conn, %{scheduled: lobby})
      {:error, reason} -> conn |> put_status(400) |> json(%{message: reason})
    end
  end

  def start(conn, %{"iid" => iid}) do
    case FlashSchedules.start_match(to_int(iid), account_id(conn)) do
      {:ok, status} -> json(conn, %{message: status})
      {:error, reason} -> conn |> put_status(400) |> json(%{message: reason})
    end
  end

  defp one(schedule) do
    schedule_json(schedule, FlashSchedules.scenario_summaries(schedule.scenario_ids), DateTime.utc_now())
  end

  defp schedule_json(schedule, maps, now) do
    next = schedule |> FlashSchedules.occurrences(now, DateTime.add(now, 8 * 86_400)) |> List.first()

    %{
      id: schedule.id,
      name: schedule.name,
      description: schedule.description,
      enabled: schedule.enabled,
      weekday: schedule.weekday,
      start_time: Time.to_iso8601(Time.truncate(schedule.start_time, :second)),
      scenario_ids: schedule.scenario_ids,
      maps: schedule.scenario_ids |> Enum.map(&Map.get(maps, &1)) |> Enum.reject(&is_nil/1),
      mutator_keys: schedule.mutator_keys,
      game_mode_type: schedule.game_mode_type,
      min_players: schedule.min_players,
      faction_capacity: schedule.faction_capacity,
      next_starts_at: if(schedule.enabled and next, do: next.starts_at),
      next_scenario_id: if(schedule.enabled and next, do: next.scenario_id)
    }
  end

  defp account_id(conn), do: conn.private.guardian_default_resource.id

  defp to_int(value) when is_integer(value), do: value

  defp to_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> -1
    end
  end

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp parse_datetime(_), do: nil
end

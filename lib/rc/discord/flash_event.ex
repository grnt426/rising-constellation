defmodule RC.Discord.FlashEvent do
  @moduledoc """
  Discord **guild scheduled events** for scheduled Flash matches
  (`RC.FlashSchedules`).

  Every occurrence gets one event in the community guild, created with
  its lobby 48h ahead so members can hit *Interested* and be pinged when
  it starts. The event is an `EXTERNAL` one whose location is the lobby
  URL, and its description carries the live registration counts — the
  scheduler re-pushes it whenever they change.

  Its life follows the match:

  | Match                     | Event status |
  |---------------------------|--------------|
  | `open`                    | `SCHEDULED`  |
  | `starting` / `started`    | `ACTIVE`     |
  | started, victory declared | `COMPLETED`  |
  | `expired`                 | `CANCELLED`  |

  Discord only allows `SCHEDULED → ACTIVE → COMPLETED` and
  `SCHEDULED → CANCELLED`, so `plan/2` advances at most one step per
  tick and never touches an event it has already finished.

  `plan/2` and the param builders are pure; `create/1` and `modify/2`
  are best-effort and return `:skipped` when the bot isn't running, so
  the scheduler only records a push that was actually attempted.

  **Ops:** the bot needs the *Manage Events* permission in the community
  guild. Without it creation is refused, the row is marked `failed` (no
  retry storm) and the match still gets its #lfg post.
  """

  require Logger

  alias Nostrum.Api.ScheduledEvent
  alias RC.Discord.News

  # privacy_level: GUILD_ONLY is the only value Discord accepts.
  @guild_only 2
  # entity_type: EXTERNAL — no voice/stage channel, just a location.
  @external 3
  @status_codes %{scheduled: 1, active: 2, completed: 3, cancelled: 4}

  @terminal ["completed", "cancelled", "failed"]

  # Discord's own limits.
  @name_limit 100
  @description_limit 1000
  @location_limit 100

  @doc "Statuses `plan/2` will never move away from."
  def terminal_statuses, do: @terminal

  @doc "Public URL of a guild scheduled event, or nil when unconfigured."
  def event_url(event_id, guild_id \\ nil)
  def event_url(nil, _guild_id), do: nil

  def event_url(event_id, guild_id) do
    case guild_id || RC.Discord.community_guild_id() do
      nil -> nil
      guild -> "https://discord.com/events/#{guild}/#{event_id}"
    end
  end

  @doc """
  What to push to Discord for `match`, given `RC.FlashSchedules.event_data/2`.

  Returns `{:create, params, record}`, `{:modify, params, record}` or
  `:none`. `record` is what the caller writes back on the match once the
  push was attempted.
  """
  def plan(match, data) do
    status = next_status(match.discord_event_status, data.state)
    name = name(data)
    description = description(data)
    record = %{discord_event_status: to_string(status), discord_event_digest: digest(name, description, status)}

    cond do
      match.discord_event_status in @terminal ->
        :none

      is_nil(match.discord_event_id) ->
        create_plan(data, status, name, description, record)

      record.discord_event_digest == match.discord_event_digest ->
        :none

      true ->
        {:modify, modify_params(data, status, name, description), record}
    end
  end

  # An event is only ever created for a match that hasn't started yet:
  # Discord refuses a start time in the past, and a match created inside
  # the late-create grace window is already under way.
  defp create_plan(data, :scheduled, name, description, record) do
    if DateTime.compare(data.scheduled_start_at, data.now) == :gt do
      {:create, create_params(data, name, description), record}
    else
      :none
    end
  end

  defp create_plan(_data, _status, _name, _description, _record), do: :none

  # Discord's allowed transitions: SCHEDULED → ACTIVE → COMPLETED and
  # SCHEDULED → CANCELLED. Anything further away advances one step and
  # lands on the next tick.
  defp next_status(nil, desired), do: next_status("scheduled", desired)
  defp next_status("scheduled", :completed), do: :active
  defp next_status("active", :cancelled), do: :completed
  defp next_status("active", :scheduled), do: :active
  defp next_status(_current, desired), do: desired

  @doc false
  def create_params(data, name \\ nil, description \\ nil) do
    %{
      name: name || name(data),
      description: description || description(data),
      privacy_level: @guild_only,
      entity_type: @external,
      # Must be null for an EXTERNAL event.
      channel_id: nil,
      entity_metadata: %{location: String.slice(data.lobby_url, 0, @location_limit)},
      scheduled_start_time: data.scheduled_start_at,
      scheduled_end_time: data.ends_at
    }
  end

  @doc false
  def modify_params(data, status, name \\ nil, description \\ nil) do
    %{
      name: name || name(data),
      description: description || description(data),
      status: @status_codes[status],
      # Re-sent so a match that started late still shows a sane end.
      scheduled_end_time: data.ends_at
    }
  end

  @doc "The event's title: the lobby's own name."
  def name(data), do: String.slice(data.name || "Scheduled Flash match", 0, @name_limit)

  @doc "The event body, including the live player counts."
  def description(data) do
    [headline(data), counts(data), footer(data)]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n\n")
    |> String.slice(0, @description_limit)
  end

  defp headline(%{state: :completed} = data) do
    case data.result do
      %{winner: winner} when is_binary(winner) -> "#{News.faction_name(winner)} won#{on_map(data)}."
      _ -> "This match has ended#{on_map(data)}."
    end
  end

  defp headline(%{state: :cancelled}),
    do: "Cancelled — the lobby never reached enough ready players and closed."

  defp headline(%{state: :active} = data), do: "The match is under way#{on_map(data)}."

  defp headline(data), do: "#{mode(data)} Flash match#{on_map(data)}."

  defp counts(%{state: :completed} = data) do
    case data.result do
      %{factions: [_ | _] = factions} -> "Final standings:\n" <> standings(factions)
      _ -> nil
    end
  end

  defp counts(%{state: :cancelled}), do: nil

  defp counts(%{state: :active} = data), do: "#{players(data.joined_count)} in the match."

  defp counts(data) do
    still_needed = max(data.required_ready - data.ready_count, 0)

    needed =
      if still_needed > 0,
        do: " · #{still_needed} more ready needed to start",
        else: " · enough to start"

    "#{players(data.joined_count)} registered · #{data.ready_count} ready#{needed}"
  end

  defp standings(factions) do
    Enum.map_join(factions, "\n", fn f ->
      vp = if f.victory_points, do: " — #{f.victory_points} VP", else: ""
      "#{f.rank || "-"}. #{News.faction_name(f.key)}#{vp}"
    end)
  end

  defp footer(%{state: state}) when state in [:completed, :cancelled], do: nil

  defp footer(%{state: :active} = data), do: "Follow the match: #{data.lobby_url}"

  defp footer(data) do
    "Join a faction and ready up: #{data.lobby_url}\n" <>
      "Players who are not ready when the match starts are removed."
  end

  defp players(1), do: "1 player"
  defp players(n), do: "#{n} players"

  defp mode(%{ranked: true}), do: "Ranked"
  defp mode(_), do: "Casual"

  defp on_map(%{map_name: name}) when is_binary(name) and name != "", do: " on #{name}"
  defp on_map(_), do: ""

  defp digest(name, description, status),
    do: {name, description, status} |> :erlang.phash2() |> Integer.to_string()

  ## Discord calls

  @doc "Creates the event: `{:ok, event_id}`, `:skipped` or `{:error, reason}`."
  def create(params) do
    with_guild(fn guild_id ->
      case ScheduledEvent.create(guild_id, params) do
        {:ok, %{id: id}} ->
          {:ok, to_string(id)}

        {:error, reason} = error ->
          Logger.warning("[flash_event] create failed: #{inspect(reason)}")
          error
      end
    end)
  end

  @doc "Patches the event: `:ok`, `:skipped` or `{:error, reason}`."
  def modify(event_id, params) do
    with_guild(fn guild_id ->
      case ScheduledEvent.modify(guild_id, String.to_integer(event_id), params) do
        {:ok, _event} ->
          :ok

        {:error, reason} = error ->
          Logger.warning("[flash_event] modify of ##{event_id} failed: #{inspect(reason)}")
          error
      end
    end)
  end

  defp with_guild(fun) do
    guild_id = RC.Discord.community_guild_id()

    if RC.Discord.running?() and guild_id do
      try do
        fun.(guild_id)
      rescue
        e ->
          Logger.warning("[flash_event] Discord call raised: #{inspect(e)}")
          {:error, e}
      end
    else
      :skipped
    end
  end
end

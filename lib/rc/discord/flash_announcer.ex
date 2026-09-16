defmodule RC.Discord.FlashAnnouncer do
  @moduledoc """
  #lfg posts for scheduled Flash matches (RC.FlashSchedules): the lobby
  announcement when a match is created, and the result once it ends in a
  victory. Mirrors the Legacy promotion embed, minus any chat rooms.

  Rendering (`announcement_embed/1`, `result_embed/1`) is pure; `post/1`
  is best-effort and reports `:skipped` when the bot or the channel isn't
  configured, so the scheduler only marks a post done once it was tried.
  """

  require Logger

  alias Nostrum.Api.Message
  alias RC.Discord.News

  @footer %{text: "Marat · Friend of the People"}

  @doc "Posts an embed to #lfg: `:ok`, `:skipped` (bot/channel off) or `{:error, reason}`."
  def post(embed) do
    channel_id = RC.Discord.lfg_channel_id()

    if RC.Discord.running?() and channel_id do
      try do
        case Message.create(channel_id, %{embeds: [embed]}) do
          {:ok, _message} ->
            :ok

          {:error, reason} = error ->
            Logger.warning("[flash_announcer] #lfg post failed: #{inspect(reason)}")
            error
        end
      rescue
        e ->
          Logger.warning("[flash_announcer] #lfg post raised: #{inspect(e)}")
          {:error, e}
      end
    else
      :skipped
    end
  end

  @doc "The lobby announcement for `RC.FlashSchedules.announcement_data/1`."
  def announcement_embed(data) do
    unix = DateTime.to_unix(data.scheduled_start_at)
    url = lobby_url(data.instance_id)

    factions =
      data.factions
      |> Enum.map(&"#{News.faction_display(&1.key)} · #{&1.capacity} seats")
      |> Enum.join("\n")

    %{
      title: "⚡ Scheduled Flash match: #{data.name}",
      url: url,
      description:
        "The lobby is open! Join a faction and **Ready Up**. Once the start time has passed " <>
          "and at least 80% of the players in the lobby are ready (minimum 2), any ready player " <>
          "can start the match. Players who aren't ready by then are left out.\n\n" <>
          "Starts <t:#{unix}:F> (<t:#{unix}:R>)",
      color: if(data.ranked, do: 0xE67E22, else: 0x5865F2),
      fields: [
        %{name: "Map", value: data.map_name || "—", inline: true},
        %{name: "Mode", value: if(data.ranked, do: "Ranked", else: "Casual"), inline: true},
        %{name: "Minimum players", value: to_string(data.min_players), inline: true},
        %{name: "Factions", value: blank_dash(factions), inline: false},
        %{name: "Mutators", value: blank_dash(Enum.join(data.mutators, ", ")), inline: false},
        %{name: "Lobby", value: url, inline: false}
      ],
      footer: @footer
    }
  end

  @doc "The result post for `RC.FlashSchedules.result_data/1`."
  def result_embed(data) do
    standings =
      data.factions
      |> Enum.map(fn f ->
        vp = if f.victory_points, do: " — #{f.victory_points} VP", else: ""
        "#{f.rank || "–"}. #{News.faction_display(f.key)}#{vp}"
      end)
      |> Enum.join("\n")

    %{
      title: "🏆 #{News.faction_name(data.winner)} wins #{data.name}",
      url: lobby_url(data.instance_id),
      description:
        "#{News.faction_display(data.winner)} took the #{if data.ranked, do: "ranked ", else: ""}" <>
          "scheduled Flash match on **#{data.map_name || data.name}**#{victory_label(data.victory_type)}.",
      color: 0x57F287,
      fields: [
        %{name: "Winning players", value: blank_dash(Enum.join(data.winner_players, ", ")), inline: false},
        %{name: "Final standings", value: blank_dash(standings), inline: false}
      ],
      footer: @footer
    }
  end

  defp victory_label("victory_track"), do: " by reaching the victory points target"
  defp victory_label("win_on_time"), do: " on time"
  defp victory_label(_), do: ""

  defp blank_dash(""), do: "—"
  defp blank_dash(value), do: value

  def lobby_url(instance_id) do
    base = Application.get_env(:rc, :rc_domain, "https://tetrarchyfalls.com/")
    String.trim_trailing(base, "/") <> "/portal/instance/#{instance_id}"
  end
end

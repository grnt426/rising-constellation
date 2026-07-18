defmodule RC.Discord.NewsRelay do
  @moduledoc """
  GenServer that owns all immediate posting of Game.News bulletins to
  the #news channel, plus the end-of-game victory announcement.

  ## Immediate feed

  `RC.Discord.News.render/2` decides which bulletin kinds post — the
  instant feed is limited to publicly-visible map events (sector
  control, colonizations, dominion flips, victory-point movement).
  The render check is pure and runs FIRST, so withheld kinds cost
  nothing; the `discord_ready` + name lookup is cached per instance
  for the relay's lifetime.

  ## Roll-up (anti-flood)

  Colonizations, dominion flips, and VP movements can arrive in
  bursts (a game-start settling rush, a sector tug-of-war). Per
  (instance, kind, faction), a follower arriving within 5 minutes of
  the previous post EDITS that message — colonize/dominion lines
  aggregate into a systems list, VP lines update in place to the
  newest value. Sector-control events post one message each (rare and
  momentous).

  ## Victory announcements

  `{:victory, instance_id, info}` posts an embed to both the
  community announce channel (community-guild emoji) and the Legacy
  #news channel (game-guild emoji). Best-effort.

  ## Lifecycle

  Runs only under `RC.Discord`'s supervisor, i.e. only when the bot is
  configured and connected. `RC.Discord.News.post_async/3` casts here;
  a cast to the unregistered name (bot off, :test) is a silent no-op
  by GenServer semantics. Roll-up state is in-memory only — a restart
  simply starts fresh messages, never loses news.
  """

  use GenServer

  require Logger

  alias Nostrum.Api.Message
  alias RC.Discord.News

  # A follower arriving within this of the last post/edit for the same
  # (instance, kind, faction) edits that message instead of posting.
  @rollup_window_ms 5 * 60 * 1000
  # A message absorbs at most this many events; the next one starts a
  # fresh message (and a fresh window).
  @max_events_per_message 20

  # Bulletin kinds that roll up. Everything else that renders posts
  # one message per event.
  @rollup_keys ["discord.colonized", "discord.dominion", "discord.vp_changed"]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    # instances: %{instance_id => {discord_ready, name} | :missing}
    # windows:   %{{instance_id, key, faction} => %{msg_id, channel_id,
    #              payloads, count, last_at}}
    {:ok, %{instances: %{}, windows: %{}}}
  end

  @impl true
  def handle_cast({:bulletin, instance_id, bulletin_key, payload}, state) do
    state =
      with headline when not is_nil(headline) <- News.render(bulletin_key, payload),
           channel_id when not is_nil(channel_id) <- RC.Discord.news_channel_id(),
           {state, {true, instance_name}} <- instance_info(state, instance_id) do
        dispatch(state, instance_id, channel_id, instance_name, bulletin_key, payload, headline)
      else
        # Withheld kind, channel unset, or instance missing / not
        # discord_ready. instance_info threads state through even on
        # the negative path.
        {state, _not_ready} -> state
        _ -> state
      end

    {:noreply, state}
  rescue
    e ->
      Logger.warning("[RC.Discord.NewsRelay] bulletin handling crashed: #{inspect(e)}")
      {:noreply, state}
  end

  @impl true
  def handle_cast({:victory, instance_id, info}, state) do
    case RC.Instances.get_instance(instance_id) do
      %{discord_ready: true} = instance ->
        post_victory(instance, info)

      _ ->
        :ok
    end

    {:noreply, state}
  rescue
    e ->
      Logger.warning("[RC.Discord.NewsRelay] victory handling crashed: #{inspect(e)}")
      {:noreply, state}
  end

  # discord_ready never flips once a game is live (promotion happens
  # pre-start), and instance names don't change mid-match — cache both
  # for the relay's lifetime instead of re-querying per event.
  defp instance_info(state, instance_id) do
    case Map.get(state.instances, instance_id) do
      nil ->
        info =
          case RC.Instances.get_instance(instance_id) do
            %{discord_ready: ready, name: name} -> {ready, name}
            _ -> :missing
          end

        state = put_in(state.instances[instance_id], info)
        {state, if(info == :missing, do: false, else: info)}

      :missing ->
        {state, false}

      {ready, name} ->
        {state, {ready, name}}
    end
  end

  ## Immediate posting, with roll-up for burst-prone kinds.

  defp dispatch(state, instance_id, channel_id, instance_name, key, payload, _headline)
       when key in @rollup_keys do
    window_key = {instance_id, key, payload[:faction]}
    now = System.monotonic_time(:millisecond)
    window = state.windows[window_key]

    if window != nil and now - window.last_at < @rollup_window_ms and
         window.count < @max_events_per_message do
      payloads = window.payloads ++ [payload]
      content = "📰 **#{instance_name}**: #{rollup_content(key, payload[:faction], payloads)}"

      case Message.edit(window.channel_id, window.msg_id, %{content: content}) do
        {:ok, _} ->
          window = %{window | payloads: payloads, count: window.count + 1, last_at: now}
          put_in(state.windows[window_key], window)

        {:error, reason} ->
          # Message likely deleted by a moderator — fall back to a
          # fresh post carrying the aggregate so nothing is lost.
          Logger.warning("[RC.Discord.NewsRelay] roll-up edit failed: #{inspect(reason)}")

          start_window(state, window_key, channel_id, instance_id, instance_name, key, payloads, now)
      end
    else
      start_window(state, window_key, channel_id, instance_id, instance_name, key, [payload], now)
    end
  end

  defp dispatch(state, instance_id, channel_id, instance_name, _key, _payload, headline) do
    create("📰 **#{instance_name}**: #{headline}", channel_id, instance_id)
    state
  end

  defp start_window(state, window_key, channel_id, instance_id, instance_name, key, payloads, now) do
    {_iid, _key, faction} = window_key
    content = "📰 **#{instance_name}**: #{rollup_content(key, faction, payloads)}"

    case create(content, channel_id, instance_id) do
      {:ok, msg} ->
        window = %{
          msg_id: msg.id,
          channel_id: channel_id,
          payloads: payloads,
          count: length(payloads),
          last_at: now
        }

        put_in(state.windows[window_key], window)

      _ ->
        # Post failed — drop the window so the next event retries fresh.
        %{state | windows: Map.delete(state.windows, window_key)}
    end
  end

  # A single event renders its normal line; from the second on, the
  # message becomes an aggregate (colonize/dominion) or the newest
  # value (VP).
  defp rollup_content(key, faction, payloads)

  defp rollup_content(key, _faction, [payload]), do: News.render(key, payload)

  defp rollup_content("discord.colonized", faction, payloads),
    do: News.colonized_rollup(faction, Enum.map(payloads, &(&1[:system_name] || "an uncharted system")))

  defp rollup_content("discord.dominion", faction, payloads),
    do: News.dominion_rollup(faction, Enum.map(payloads, &(&1[:system_name] || "an uncharted system")))

  defp rollup_content("discord.vp_changed", _faction, payloads),
    do: News.render("discord.vp_changed", List.last(payloads))

  ## Victory

  defp post_victory(instance, info) do
    instance = RC.Repo.preload(instance, [:scenario])

    scenario_name =
      case instance.scenario do
        %{game_metadata: metadata} -> get_in(metadata || %{}, ["name"])
        _ -> nil
      end

    scenario_name = scenario_name || instance.name || "A Legacy match"

    destinations = [
      {RC.Discord.community_announce_channel_id(), :community, "community announce"},
      {RC.Discord.news_channel_id(), :game, "news"}
    ]

    Enum.each(destinations, fn
      {nil, _guild, label} ->
        Logger.info("[RC.Discord.NewsRelay] no #{label} channel; skipping victory post")

      {channel_id, guild, _label} ->
        embed = News.victory_embed(scenario_name, info[:winner], info[:victory_points], guild)

        case Message.create(channel_id, %{embeds: [embed]}) do
          {:ok, _msg} ->
            :ok

          {:error, reason} ->
            Logger.warning(
              "[RC.Discord.NewsRelay] victory post failed (channel #{channel_id}, " <>
                "instance ##{instance.id}): #{inspect(reason)}"
            )
        end
    end)
  end

  defp create(content, channel_id, instance_id) do
    case Message.create(channel_id, %{content: content}) do
      {:ok, _msg} = ok ->
        ok

      {:error, reason} ->
        Logger.warning(
          "[RC.Discord.NewsRelay] post failed (channel #{channel_id}, instance ##{instance_id}): " <>
            inspect(reason)
        )

        :error
    end
  end
end

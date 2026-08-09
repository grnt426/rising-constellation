defmodule RC.Discord.NewsRelay do
  @moduledoc """
  GenServer that owns all rolling-feed posting of Game.News bulletins
  to Discord, plus the end-of-game victory announcement.

  ## Feed policy

  `RC.Discord.News.render/3` decides which bulletin kinds post — the
  rolling feed is limited to publicly-visible map events (sector
  control, colonizations, dominion flips, victory-point movement).
  The render check is pure and runs FIRST, so withheld kinds cost
  nothing; the `discord_ready` + name lookup is cached per instance
  for the relay's lifetime.

  ## Batching buckets (anti-flood)

  Per instance, three windows:

    * **Legacy map bucket (5 min)** — every map-ownership change
      (colonize, dominion, liberation, abandonment) AND the
      sector-control changes they cause share one bucket. The first
      event posts a message to Legacy #news; every follower inside
      the bucket EDITS that message into a digest
      (`News.map_digest/3`). After 5 minutes (or the event cap) the
      next event opens a fresh message.
    * **Legacy VP roll-up (5 min, per faction)** — victory-point
      lines update in place to the bucket's net delta plus the full
      victory track (`News.vp_rollup/3`).
    * **Community bucket (6 h)** — the same events (VP included)
      accumulate into one message per 6 hours in the community
      #game-news channel (`News.community_digest/2`), carrying a
      running total of system/dominion changes by faction and by
      sector, and the victory track (per-mover deltas + full
      standings). One message per instance per window keeps the
      community feed low-traffic.

  ## Victory announcements

  `{:victory, instance_id, info}` posts an embed to both the
  community announce channel (community-guild emoji) and the Legacy
  #news channel (game-guild emoji). Best-effort.

  ## Lifecycle

  Runs only under `RC.Discord`'s supervisor, i.e. only when the bot is
  configured and connected. `RC.Discord.News.post_async/3` casts here;
  a cast to the unregistered name (bot off, :test) is a silent no-op
  by GenServer semantics. Bucket state is in-memory only — a restart
  (e.g. a deploy) simply starts fresh messages, never loses news; the
  community running totals restart with the fresh message.
  """

  use GenServer

  require Logger

  alias Nostrum.Api.Message
  alias RC.Discord.News

  # Legacy map/VP bucket length: a follower arriving while the bucket
  # message is younger than this edits it instead of posting.
  @map_window_ms 5 * 60 * 1000
  # Community #game-news bucket length.
  @community_window_ms 6 * 60 * 60 * 1000
  # A legacy bucket message absorbs at most this many events; the next
  # one starts a fresh message (and a fresh window).
  @max_events_per_message 20
  # The community digest aggregates per faction/sector so it compresses
  # well; the cap is a runaway guard, not a display bound.
  @community_max_events 400

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    # instances:  %{instance_id => {discord_ready, name} | :missing}
    # map:        %{instance_id => window}   (legacy 5-min ownership bucket)
    # vp:         %{{instance_id, faction} => window}   (legacy VP roll-up)
    # community:  %{instance_id => window}   (community 6-h bucket)
    # window: %{msg_id, channel_id, events, count, started_at}
    #   events: [{bulletin_key, payload}] in arrival order
    {:ok, %{instances: %{}, map: %{}, vp: %{}, community: %{}}}
  end

  @impl true
  def handle_cast({:bulletin, instance_id, bulletin_key, payload}, state) do
    state =
      with headline when not is_nil(headline) <- News.render(bulletin_key, payload),
           {state, {true, instance_name}} <- instance_info(state, instance_id) do
        state
        |> dispatch_legacy(instance_id, instance_name, bulletin_key, payload, headline)
        |> dispatch_community(instance_id, instance_name, bulletin_key, payload)
      else
        # Withheld kind, or instance missing / not discord_ready.
        # instance_info threads state through even on the negative path.
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

  ## Legacy #news dispatch ----------------------------------------------

  defp dispatch_legacy(state, instance_id, instance_name, key, payload, headline) do
    case RC.Discord.news_channel_id() do
      nil ->
        state

      channel_id ->
        cond do
          News.map_key?(key) ->
            update_bucket(state, :map, instance_id, channel_id, {key, payload},
              window_ms: @map_window_ms,
              max_events: @max_events_per_message,
              render: fn events -> News.map_digest(instance_name, events, :game) end
            )

          News.vp_key?(key) ->
            update_bucket(state, :vp, {instance_id, payload[:faction]}, channel_id, {key, payload},
              window_ms: @map_window_ms,
              max_events: @max_events_per_message,
              render: fn events ->
                # VP lines update in place: net bucket delta + the full
                # victory track (News.vp_rollup/3).
                News.vp_rollup(instance_name, events, :game)
              end
            )

          true ->
            # A future renderable kind outside the buckets: one message
            # per event, as before.
            create("📰 **#{instance_name}**: #{headline}", channel_id, instance_id)
            state
        end
    end
  end

  ## Community #game-news dispatch --------------------------------------

  defp dispatch_community(state, instance_id, instance_name, key, payload) do
    case RC.Discord.community_game_news_channel_id() do
      nil ->
        state

      channel_id ->
        update_bucket(state, :community, instance_id, channel_id, {key, payload},
          window_ms: @community_window_ms,
          max_events: @community_max_events,
          render: fn events -> News.community_digest(instance_name, events) end
        )
    end
  end

  ## Bucket mechanics ----------------------------------------------------

  # Append an event to the bucket under state[kind][bucket_key]. While
  # the bucket's message is younger than window_ms (and under the event
  # cap), the message is EDITED to the re-rendered digest; otherwise a
  # fresh message opens a fresh bucket.
  defp update_bucket(state, kind, bucket_key, channel_id, event, opts) do
    now = System.monotonic_time(:millisecond)
    window = state[kind][bucket_key]
    render = Keyword.fetch!(opts, :render)

    if window != nil and now - window.started_at < Keyword.fetch!(opts, :window_ms) and
         window.count < Keyword.fetch!(opts, :max_events) do
      events = window.events ++ [event]

      case Message.edit(window.channel_id, window.msg_id, %{content: render.(events)}) do
        {:ok, _} ->
          window = %{window | events: events, count: window.count + 1}
          put_in(state[kind][bucket_key], window)

        {:error, reason} ->
          # Message likely deleted by a moderator — fall back to a
          # fresh post carrying the whole digest so nothing is lost.
          Logger.warning("[RC.Discord.NewsRelay] bucket edit failed: #{inspect(reason)}")
          start_bucket(state, kind, bucket_key, channel_id, events, now, render)
      end
    else
      start_bucket(state, kind, bucket_key, channel_id, [event], now, render)
    end
  end

  defp start_bucket(state, kind, bucket_key, channel_id, events, now, render) do
    case create(render.(events), channel_id, bucket_key) do
      {:ok, msg} ->
        window = %{
          msg_id: msg.id,
          channel_id: channel_id,
          events: events,
          count: length(events),
          started_at: now
        }

        put_in(state[kind][bucket_key], window)

      _ ->
        # Post failed — drop the bucket so the next event retries fresh.
        %{state | kind => Map.delete(state[kind], bucket_key)}
    end
  end

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

  defp create(content, channel_id, context) do
    case Message.create(channel_id, %{content: content}) do
      {:ok, _msg} = ok ->
        ok

      {:error, reason} ->
        Logger.warning(
          "[RC.Discord.NewsRelay] post failed (channel #{channel_id}, #{inspect(context)}): " <>
            inspect(reason)
        )

        :error
    end
  end
end

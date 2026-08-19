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
    * **6-hour digest windows (00/06/12/18 UTC)** — the same events
      (VP included) accumulate silently per instance; when the fixed
      UTC boundary passes, each non-empty window posts ONE image
      digest per instance and clears. The community #game-news
      channel gets the full card (map + territory changes + victory
      track); the Legacy #news channel gets the territory-only card
      (VP already flows there via the 5-minute roll-ups). Nothing is
      edited after posting — scrollback becomes a flipbook of the
      war. If rasterization fails (no librsvg on the host), the
      community channel falls back to the text digest
      (`News.community_digest/2`) and the Legacy digest is skipped.

  ## Victory announcements

  `{:victory, instance_id, info}` posts an embed to both the
  community announce channel (community-guild emoji) and the Legacy
  #news channel (game-guild emoji). Best-effort.

  ## Lifecycle

  Runs only under `RC.Discord`'s supervisor, i.e. only when the bot is
  configured and connected. `RC.Discord.News.post_async/3` casts here;
  a cast to the unregistered name (bot off, :test) is a silent no-op
  by GenServer semantics. The legacy 5-minute buckets are in-memory
  only — a restart (e.g. a deploy) simply starts fresh messages, never
  loses news. The 6-hour digest window is rebuilt best-effort from
  `player_events` on boot (`RC.Discord.DigestReplay`, via
  handle_continue so queued casts wait behind it) — a deploy landing
  just before a window boundary no longer silently drops the window.
  Worst case for the tiny boot race (a row inserted between the relay
  registering and the replay query) is one duplicated digest line, not
  a lost window.
  """

  use GenServer

  require Logger

  alias Nostrum.Api.Message
  alias RC.Discord.{DigestData, News, Render}
  alias RC.Discord.Render.Cards

  # Legacy map/VP bucket length: a follower arriving while the bucket
  # message is younger than this edits it instead of posting.
  @map_window_ms 5 * 60 * 1000
  # A legacy bucket message absorbs at most this many events; the next
  # one starts a fresh message (and a fresh window).
  @max_events_per_message 20
  # The 6-hour digest aggregates per faction/sector so it compresses
  # well; the cap is a runaway guard, not a display bound.
  @digest_max_events 400

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    # instances:  %{instance_id => {discord_ready, name} | :missing}
    # map:        %{instance_id => window}   (legacy 5-min ownership bucket)
    # vp:         %{{instance_id, faction} => window}   (legacy VP roll-up)
    # digest:     %{instance_id => %{events: [...], count: n}}  (6-h window)
    # window: %{msg_id, channel_id, events, count, started_at}
    #   events: [{bulletin_key, payload}] in arrival order
    schedule_digest_close()

    {:ok, %{instances: %{}, map: %{}, vp: %{}, digest: %{}, concluded: MapSet.new()}, {:continue, :replay_digest}}
  end

  # Rebuild the current 6-hour window from player_events so a deploy
  # mid-window doesn't drop it. Skipped when no digest destination is
  # configured — mirrors accumulate_digest/4's gate. DigestReplay
  # rescues internally and returns %{} on any failure.
  @impl true
  def handle_continue(:replay_digest, state) do
    if RC.Discord.community_game_news_channel_id() || RC.Discord.news_channel_id() do
      digest = RC.Discord.DigestReplay.rebuild(max_events: @digest_max_events)

      if map_size(digest) > 0 do
        events = digest |> Enum.map(fn {_id, w} -> w.count end) |> Enum.sum()

        Logger.info(
          "[RC.Discord.NewsRelay] replayed #{events} event(s) across #{map_size(digest)} " <>
            "instance window(s) from player_events"
        )
      end

      {:noreply, %{state | digest: digest}}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:bulletin, instance_id, bulletin_key, payload}, state) do
    # Conquests are digest-only: no rolling-feed headline (withheld
    # kind), but they are territory changes and belong in the 6-hour
    # windows.
    headline = News.render(bulletin_key, payload)

    state =
      with false <- MapSet.member?(state.concluded, instance_id),
           true <- headline != nil or News.digest_feed_key?(bulletin_key),
           {state, {true, instance_name}} <- instance_info(state, instance_id) do
        state
        |> maybe_dispatch_legacy(instance_id, instance_name, bulletin_key, payload, headline)
        |> accumulate_digest(instance_id, bulletin_key, payload)
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

    # The match is decided: stop broadcasting for it. Drop pending
    # buckets and the open digest window, and ignore later events from
    # the post-victory tail.
    state = %{
      state
      | concluded: MapSet.put(state.concluded, instance_id),
        map: Map.delete(state.map, instance_id),
        vp: Map.reject(state.vp, fn {{iid, _faction}, _w} -> iid == instance_id end),
        digest: Map.delete(state.digest, instance_id)
    }

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

  defp maybe_dispatch_legacy(state, _instance_id, _instance_name, _key, _payload, nil), do: state

  defp maybe_dispatch_legacy(state, instance_id, instance_name, key, payload, headline),
    do: dispatch_legacy(state, instance_id, instance_name, key, payload, headline)

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

  ## 6-hour digest windows (00/06/12/18 UTC) -----------------------------

  # Accumulate silently; posting happens on the boundary timer. Events
  # are collected whenever either digest destination is configured.
  defp accumulate_digest(state, instance_id, key, payload) do
    if RC.Discord.community_game_news_channel_id() || RC.Discord.news_channel_id() do
      window = Map.get(state.digest, instance_id, %{events: [], count: 0})

      if window.count < @digest_max_events do
        window = %{window | events: window.events ++ [{key, payload}], count: window.count + 1}
        put_in(state.digest[instance_id], window)
      else
        state
      end
    else
      state
    end
  end

  @impl true
  def handle_info(:digest_close, state) do
    label = DigestData.window_label()

    state =
      Enum.reduce(state.digest, state, fn {instance_id, %{events: events}}, acc ->
        case events do
          [] -> acc
          _ -> post_window_digests(acc, instance_id, events, label)
        end
      end)

    {:noreply, %{state | digest: %{}}}
  rescue
    e ->
      Logger.warning("[RC.Discord.NewsRelay] digest close crashed: #{inspect(e)}")
      {:noreply, %{state | digest: %{}}}
  after
    schedule_digest_close()
  end

  defp schedule_digest_close do
    Process.send_after(self(), :digest_close, DigestData.ms_until_next_close())
  end

  # One instance's closed window: full card to community #game-news,
  # territory-only card to Legacy #news. Best-effort per destination.
  defp post_window_digests(state, instance_id, events, label) do
    {state, info} = instance_info(state, instance_id)

    with {true, instance_name} <- info,
         %{} = instance <- RC.Instances.get_instance(instance_id) do
      case DigestData.assemble(instance, instance_name, events, label) do
        {:ok, %{community: community_data, legacy: legacy_data}} ->
          post_digest_card(
            RC.Discord.community_game_news_channel_id(),
            fn -> Cards.digest(community_data) end,
            "📰 **#{instance_name}** — 6-hour digest (#{label})",
            fn -> News.community_digest(instance_name, events) end,
            instance_id
          )

          map_events = Enum.filter(events, fn {k, _} -> News.map_key?(k) end)

          legacy_fallback =
            if map_events != [], do: fn -> News.map_digest(instance_name, map_events, :game) end

          post_digest_card(
            RC.Discord.news_channel_id(),
            fn -> Cards.digest_territory(legacy_data) end,
            "📰 **#{instance_name}** — territory report (#{label})",
            legacy_fallback,
            instance_id
          )

        {:error, reason} ->
          # Instance unreachable (ended mid-window, agent down): the
          # community text digest still works from events alone.
          Logger.warning("[RC.Discord.NewsRelay] digest assembly failed (instance ##{instance_id}): #{inspect(reason)}")

          if channel_id = RC.Discord.community_game_news_channel_id() do
            create(News.community_digest(instance_name, events), channel_id, instance_id)
          end
      end

      state
    else
      _ -> state
    end
  end

  defp post_digest_card(nil, _render, _caption, _text_fallback, _instance_id), do: :ok

  defp post_digest_card(channel_id, render, caption, text_fallback, instance_id) do
    with svg when is_binary(svg) <- render.(),
         {:ok, png} <- Render.rasterize(svg) do
      # A rejected attachment (e.g. a channel overwrite without Attach
      # Files) degrades to the text digest rather than dropping the
      # window for that channel.
      fallback_opts = if text_fallback, do: %{content: text_fallback.()}

      case Render.create_or_fallback(channel_id, Render.image_message(caption, png, "digest.png"), fallback_opts) do
        {:ok, _} ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "[RC.Discord.NewsRelay] digest post failed (channel #{channel_id}, " <>
              "instance ##{instance_id}): #{inspect(reason)}"
          )
      end
    else
      error ->
        Logger.warning("[RC.Discord.NewsRelay] digest render failed (instance ##{instance_id}): #{inspect(error)}")

        if text_fallback, do: create(text_fallback.(), channel_id, instance_id)
    end
  rescue
    e ->
      Logger.warning("[RC.Discord.NewsRelay] digest card crashed (instance ##{instance_id}): #{inspect(e)}")
      if text_fallback, do: create(text_fallback.(), channel_id, instance_id)
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
    victory_png = victory_card(scenario_name, info)

    destinations = [
      {RC.Discord.community_announce_channel_id(), :community, "community announce"},
      {RC.Discord.news_channel_id(), :game, "news"}
    ]

    Enum.each(destinations, fn
      {nil, _guild, label} ->
        Logger.info("[RC.Discord.NewsRelay] no #{label} channel; skipping victory post")

      {channel_id, guild, _label} ->
        embed = News.victory_embed(scenario_name, info[:winner], info[:victory_points], guild)

        message_opts =
          case victory_png do
            {:ok, png} ->
              caption = "🏆 **#{News.faction_name(to_string(info[:winner]))}** wins **#{scenario_name}**!"
              Render.image_message(caption, png, "victory.png")

            _ ->
              %{embeds: [embed]}
          end

        case Render.create_or_fallback(channel_id, message_opts, %{embeds: [embed]}) do
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

  # The victory card needs the final ranking; older payloads without it
  # (or a host without librsvg) fall back to the classic embed.
  defp victory_card(scenario_name, info) do
    case info[:ranking] do
      [_ | _] = ranking ->
        winner = to_string(info[:winner])
        win_target = info[:win_points_target] || 14

        rows =
          Enum.map(ranking, fn r ->
            gained = if r.faction == winner, do: [r.vp], else: []
            %{faction: r.faction, vp: r.vp, gained: gained, lost: []}
          end)

        totals =
          Enum.map(ranking, fn r ->
            %{faction: r.faction, systems: r.systems, dominions: r.dominions, players: r.players}
          end)

        data = %{
          instance_name: scenario_name,
          winner: winner,
          victory_type_label: victory_type_label(info[:victory_type]),
          vp: %{win_target: win_target, rows: rows},
          totals: totals
        }

        Render.rasterize(Cards.victory(data))

      _ ->
        {:error, :no_ranking}
    end
  rescue
    e -> {:error, e}
  end

  defp victory_type_label("win_on_time"), do: "Time-limit victory"
  defp victory_type_label("victory_track"), do: "Victory track complete"
  defp victory_type_label(other), do: to_string(other || "Victory")

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

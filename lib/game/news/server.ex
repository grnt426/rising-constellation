defmodule Game.News.Server do
  @moduledoc """
  Per-instance GenServer that consumes raw `Game.News.emit/3` messages
  off PubSub and decides whether each one becomes a news bulletin.

  Emit sites publish *raw* events (`"dominion.taken"`, `"battle.fought"`,
  `"agent.spy_hired"`, …). This server owns all newsworthiness rules:

    * **Eligibility gate** — drops everything in fast-speed and
      tutorial instances (checked once, cached).
    * **Firsts** — routed events claim a first via
      `RC.InstanceFirsts.claim/1`; only the actual first becomes a
      bulletin. Settled claims are cached in `state.claimed` so
      repeat probes (e.g. the per-stats-tick income check) cost
      nothing after the first resolution.
    * **Dedup windows** — flood-prone events (battles, raids) arm a
      5-minute window keyed by kind+location. The first event
      publishes immediately; followers are counted silently; at
      expiry a single "ongoing operations" summary bulletin is
      published if enough piled up.
    * **Ranking rules** — assassination/conversion bulletins only
      fire when the victim was a governor in the galaxy's top
      max(5, 5%) by level; the Erased milestone fires when a faction
      first fields 25 living Erased.
    * **Persistence + toast** — bulletins are written to
      `player_events` as global rows under `news.*` keys, then
      broadcast on the instance global channel as `%{global_news: …}`
      for the in-game "breaking news" toast.

  ## Resilience

  Only ephemeral dedup/cache state lives here. A crash restarts it
  empty: worst case is one duplicate bulletin inside a window, and
  first-claims stay correct because the DB unique index is the
  authority — the `claimed` set is merely a fast path.
  """

  use GenServer

  require Logger

  alias Portal.Controllers.GlobalChannel
  alias RC.InstanceFirsts
  alias RC.PlayerEvents

  @dedup_window_ms 5 * 60 * 1000
  # A window that swallowed at least this many follow-up events emits
  # a summary bulletin when it expires.
  @summary_threshold 3
  # Erased / Navarchs / Siderians corps-size milestone.
  @corps_threshold 25
  # Governor-ranking rule: top max(5, ceil(5%)) of living governors.
  @top_governors_min 5
  @top_governors_pct 0.05

  defstruct [
    :instance_id,
    eligibility: :unknown,
    # first_keys whose claim has been settled (won or lost) this
    # server lifetime — repeat probes short-circuit here.
    claimed: MapSet.new(),
    # %{dedup_key => %{count: n, bulletin_key: k, sample: payload}}
    dedup: %{}
  ]

  ## Client API

  def start_link(opts) do
    instance_id = Keyword.fetch!(opts, :instance_id)

    GenServer.start_link(
      __MODULE__,
      instance_id,
      name: Game.via_tuple({instance_id, :news_server})
    )
  end

  ## Callbacks

  @impl true
  def init(instance_id) do
    Phoenix.PubSub.subscribe(RC.PubSub, Game.News.topic(instance_id))
    {:ok, %__MODULE__{instance_id: instance_id}}
  end

  @impl true
  def handle_info({:news_emit, key, payload}, %__MODULE__{} = state) do
    state = resolve_eligibility(state)

    state =
      if state.eligibility == :eligible do
        route(state, key, payload)
      else
        state
      end

    {:noreply, state}
  end

  def handle_info({:dedup_expired, dkey}, %__MODULE__{} = state) do
    {window, dedup} = Map.pop(state.dedup, dkey)

    if window != nil and window.count >= @summary_threshold do
      publish(state, window.bulletin_key <> ".summary", Map.put(window.sample, :count, window.count))
    end

    {:noreply, %{state | dedup: dedup}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  ## Routing — one clause per raw event kind.

  defp route(state, "colonize.first", payload),
    do: first(state, "colonize.first", "news.colonize.first", payload)

  defp route(state, "dominion.taken", payload),
    do: first(state, "dominion.first", "news.dominion.first", payload)

  defp route(state, "conquest.taken", payload),
    do: publish(state, "news.conquest", payload)

  defp route(state, "raid.hit", payload),
    do: dedup(state, {:raid, payload[:faction], payload[:system_id]}, "news.raid", payload)

  defp route(state, "battle.fought", payload),
    do: dedup(state, {:battle, payload[:sector_id]}, "news.battle", payload)

  defp route(state, "agent.assassinated", payload) do
    if top_governor?(state.instance_id, payload),
      do: publish(state, "news.agent.assassinated", payload),
      else: state
  end

  defp route(state, "agent.converted", payload) do
    if top_governor?(state.instance_id, payload),
      do: publish(state, "news.agent.converted", payload),
      else: state
  end

  # 25-strong agent-corps milestones: Erased (spies), Navarchs
  # (admirals), Siderians (speakers). One galaxy-first each.
  @agent_corps %{
    "spy" => {"faction.erased_25.first", "news.faction.erased"},
    "admiral" => {"faction.navarchs_25.first", "news.faction.navarchs"},
    "speaker" => {"faction.siderians_25.first", "news.faction.siderians"}
  }

  defp route(state, "agent.hired", payload) do
    case Map.fetch(@agent_corps, payload[:character_type]) do
      {:ok, {first_key, bulletin_key}} ->
        cond do
          MapSet.member?(state.claimed, first_key) ->
            state

          faction_character_count(state.instance_id, payload[:winning_faction_id], payload[:character_type]) >=
              @corps_threshold ->
            first(state, first_key, bulletin_key, payload)

          true ->
            state
        end

      :error ->
        state
    end
  end

  defp route(state, "building.completed", payload),
    do: first(state, "building.#{payload[:building]}.first", "news.building.first", payload)

  defp route(state, "ship.fielded", payload),
    do: first(state, "ship.capital.first", "news.ship.capital", payload)

  defp route(state, "income.crossed", payload),
    do: first(state, "income.#{payload[:resource]}_100.first", "news.income.first", payload)

  defp route(state, "credit.crossed", payload),
    do: first(state, "credit.10m.first", "news.credit.first", payload)

  defp route(state, "doctrine.crossed", payload),
    do: first(state, "doctrine.15.first", "news.doctrine.first", payload)

  defp route(state, "dominion.liberated", payload),
    do: publish(state, "news.dominion.liberated", payload)

  defp route(state, "system.abandoned", payload),
    do: publish(state, "news.system.abandoned", payload)

  # Unknown raw kinds pass through as-is so a new emit site can ship
  # before this router learns about it. The frontend renders unknown
  # keys with its generic fallback template.
  defp route(state, key, payload),
    do: publish(state, "news." <> key, payload)

  ## First-claim gate

  defp first(state, first_key, bulletin_key, payload) do
    if MapSet.member?(state.claimed, first_key) do
      state
    else
      attrs = %{
        first_key: first_key,
        instance_id: state.instance_id,
        winning_faction_id: payload[:winning_faction_id],
        winning_registration_id: payload[:winning_registration_id]
      }

      case InstanceFirsts.claim(attrs) do
        {:ok, _row} ->
          publish(state, bulletin_key, payload)
          %{state | claimed: MapSet.put(state.claimed, first_key)}

        {:already_claimed, _existing} ->
          %{state | claimed: MapSet.put(state.claimed, first_key)}

        {:error, reason} ->
          # Do NOT cache on error — a transient DB failure should not
          # permanently swallow a first for this server's lifetime.
          Logger.warning("Game.News.Server first-claim failed",
            instance_id: state.instance_id,
            first_key: first_key,
            reason: inspect(reason)
          )

          state
      end
    end
  end

  ## Dedup window

  defp dedup(state, dkey, bulletin_key, payload) do
    case Map.fetch(state.dedup, dkey) do
      :error ->
        # First in the window: publish now, arm the window.
        publish(state, bulletin_key, payload)
        Process.send_after(self(), {:dedup_expired, dkey}, @dedup_window_ms)
        window = %{count: 0, bulletin_key: bulletin_key, sample: payload}
        %{state | dedup: Map.put(state.dedup, dkey, window)}

      {:ok, window} ->
        # Follower: swallow, count, keep the freshest payload for the
        # eventual summary.
        window = %{window | count: window.count + 1, sample: payload}
        %{state | dedup: Map.put(state.dedup, dkey, window)}
    end
  end

  ## Publication

  # Fields that exist only for instance_firsts bookkeeping — never
  # shipped to clients (the disguised patent bulletin in particular
  # must not carry the winner's faction id in its payload).
  @bookkeeping_fields [:winning_faction_id, :winning_registration_id]

  # Covert-ops bulletins must not reveal the perpetrator: the spy
  # mechanically stayed under cover, so the attacker faction is a
  # hard secret even from the victim.
  @secret_fields %{
    "news.agent.assassinated" => [:attacker_faction],
    "news.agent.converted" => [:attacker_faction]
  }

  defp publish(state, bulletin_key, payload) do
    payload =
      payload
      |> Map.drop(@bookkeeping_fields)
      |> Map.drop(Map.get(@secret_fields, bulletin_key, []))
      |> enrich_sector_name(state.instance_id)

    case PlayerEvents.create(%{
           type: "global",
           key: bulletin_key,
           data: Jason.encode!(payload),
           instance_id: state.instance_id
         }) do
      {:ok, event} ->
        # In-game "breaking news" toast + live ticker refresh. Same
        # shape the REST endpoint serves, so the FE reuses one renderer.
        GlobalChannel.broadcast_change("instance:global:#{state.instance_id}", %{
          global_news: %{
            id: event.id,
            key: event.key,
            data: payload,
            inserted_at: event.inserted_at
          }
        })

        # Discord relay for discord_ready games (async, best-effort;
        # posts only the public tier — #news is an all-factions channel).
        RC.Discord.News.post_async(state.instance_id, bulletin_key, payload)

      {:error, reason} ->
        Logger.warning("Game.News.Server publish failed",
          instance_id: state.instance_id,
          key: bulletin_key,
          reason: inspect(reason)
        )
    end

    state
  end

  # Resolve sector_id → sector name so templates can say "in the
  # Ryfe sector" without the frontend needing galaxy data. Uses a
  # dedicated lightweight galaxy call (NOT :get_state — the full
  # galaxy struct is huge and this runs on every bulletin).
  defp enrich_sector_name(%{sector_id: sector_id} = payload, instance_id)
       when is_integer(sector_id) do
    case Game.call_no_log(instance_id, :galaxy, :master, {:get_sector_name, sector_id}, 1, 1_000) do
      {:ok, name} when is_binary(name) -> Map.put(payload, :sector_name, name)
      _ -> payload
    end
  end

  defp enrich_sector_name(payload, _instance_id), do: payload

  ## Ranking rules

  # A victim qualifies if they were a governor and fewer than
  # max(5, ceil(5% of living governors)) living governors outrank
  # them by level. The victim is already dead (removed from rosters)
  # when this runs, so we rank them against the survivors — the
  # strictly-higher-level count keeps that comparison exact.
  defp top_governor?(instance_id, payload) do
    if payload[:target_status] == "governor" do
      governors = collect_governors(instance_id)
      top_n = max(@top_governors_min, ceil(length(governors) * @top_governors_pct))
      outranked_by = Enum.count(governors, fn g -> g.level > payload[:target_level] end)
      outranked_by < top_n
    else
      false
    end
  rescue
    e ->
      Logger.warning("Game.News.Server top_governor? check failed: #{inspect(e)}")
      false
  end

  defp collect_governors(instance_id) do
    for player_id <- player_ids(instance_id),
        {:ok, player} <- [Game.call_no_log(instance_id, :player, player_id, :get_state, 1, 1_000)],
        character <- player.characters,
        character.status == :governor do
      %{level: character.level, id: character.id}
    end
  end

  defp faction_character_count(instance_id, faction_id, type_string) do
    for player_id <- player_ids(instance_id),
        {:ok, player} <- [Game.call_no_log(instance_id, :player, player_id, :get_state, 1, 1_000)],
        player.faction_id == faction_id,
        character <- player.characters,
        Atom.to_string(character.type) == type_string do
      character
    end
    |> length()
  rescue
    e ->
      Logger.warning("Game.News.Server faction_character_count failed: #{inspect(e)}")
      0
  end

  defp player_ids(instance_id) do
    case Game.call_no_log(instance_id, :galaxy, :master, :get_state, 1, 1_000) do
      {:ok, galaxy} -> Map.keys(galaxy.players)
      _ -> []
    end
  end

  ## Eligibility (speed + tutorial gate)

  defp resolve_eligibility(%{eligibility: :unknown, instance_id: iid} = state) do
    eligibility =
      if eligible_speed?(iid) and not tutorial?(iid),
        do: :eligible,
        else: :ineligible

    %{state | eligibility: eligibility}
  end

  defp resolve_eligibility(state), do: state

  defp eligible_speed?(instance_id) do
    case Data.Data.get(instance_id, :metadata) do
      nil -> false
      # :fast matches the existing PlayerEvent convention; :daily is the
      # single-player daily-challenge speed — private games, no audience.
      metadata -> Keyword.get(metadata, :speed) not in [:fast, :daily]
    end
  rescue
    _ -> false
  end

  defp tutorial?(instance_id) do
    # Galaxy.Agent's :get_state reply is `{:ok, state.data}` — i.e.
    # `galaxy` here is already the Galaxy struct, not the agent
    # wrapper. is_tutorial/1 reads its `:tutorial_id` field.
    case Game.call_no_log(instance_id, :galaxy, :master, :get_state, 1, 1_000) do
      {:ok, galaxy} -> Instance.Galaxy.Galaxy.is_tutorial(galaxy)
      _ -> false
    end
  rescue
    _ -> false
  catch
    _, _ -> false
  end
end

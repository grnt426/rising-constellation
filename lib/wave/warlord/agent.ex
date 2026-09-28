defmodule Wave.Warlord.Agent do
  @moduledoc """
  The Rebellion's commander process — one per Wave Defense instance.

  A `Core.TickServer`, started by `Instance.Manager` inside the instance
  supervision tree. That placement is deliberate: the Warlord starts, stops,
  pauses, speed-cheats, snapshots and restores with the rest of the instance,
  and its clocks advance from game time (`elapsed_time`) rather than wall time,
  so a paused instance freezes the Rebellion too. (A plain GenServer here would
  crash the Manager's start/stop/snapshot fan-outs — the Game.News.Server
  wedge.)

  It never holds authoritative game state. Everything it does goes through the
  same player/character/market agent calls a human's client reaches through the
  player channel, so the engine validates every order. What the Warlord adds is
  the bypass layer the bot is entitled to and humans are not: free colony
  ships, a solvency floor, and (via `Wave.Config`) lifted caps and bankruptcy
  immunity.

  ## Cost discipline

  A pass reads the player once, reads the galaxy at most once, and builds one
  `Wave.Geometry` shared by every decision in the pass. Hop distances are
  memoized per source system. Only agents the player's roster reports as idle
  get a full state read (a full refresh of every agent runs every
  `state_refresh_passes` passes, in case the roster cache lags). With nothing
  to target, agents are skipped outright instead of searched for.

  ## Behaviour log

  Siderian decisions and outcomes go to `instance_event_log` as `wave_*`
  events (async, best-effort), with one `wave_daily` rollup per match day, so
  a finished test game can be analysed after the fact.
  """

  use Core.TickServer

  require Logger

  alias Instance.Character.{ActionQueue, Character, Speaker}
  alias Wave.{Geometry, Nav, Warlord}

  @colony_ship :transport_1

  # ---------------------------------------------------------------------------
  # Calls
  # ---------------------------------------------------------------------------

  @decorate tick()
  def on_call(:get_state, _from, state) do
    {:reply, {:ok, state.data}, state}
  end

  @decorate tick()
  def on_call(:status, _from, state) do
    {:reply, {:ok, Warlord.summary(state.data)}, state}
  end

  # Dev/test lever: make the Navarch hire due and run a pass immediately,
  # instead of waiting six real hours at Legacy speed.
  @decorate tick()
  def on_call(:force_hire, _from, state) do
    data = Warlord.upgrade(state.data)
    data = %{data | hire_accum: Warlord.hire_interval(data)}
    state = next_tick(%{state | data: data})
    {:reply, {:ok, Warlord.summary(state.data)}, state}
  end

  # Dev/test lever: run one management pass now.
  @decorate tick()
  def on_call(:run_now, _from, state) do
    state = next_tick(state)
    {:reply, {:ok, Warlord.summary(state.data)}, state}
  end

  # Override the default {:start, _} so a restored or resumed Warlord re-asserts
  # the bot player's client connection on its next tick. Snapshot restore zeroes
  # a player's `connected_clients`; a bot faction with no active player collapses
  # its victory-track thresholds (see Instance.Victory.Faction.reset_player_count/2).
  # No I/O here — this runs inside the Manager's start fan-out.
  def on_call({:start, cumulated_pauses}, _from, state) do
    tick = Core.Tick.start(%{state.tick | cumulated_pauses: cumulated_pauses})
    data = Warlord.upgrade(state.data)
    {:reply, :ok, %{state | tick: tick, data: %{data | connected: false}}}
  end

  @decorate tick()
  def on_info(:tick, state) do
    {:noreply, state}
  end

  # ---------------------------------------------------------------------------
  # Tick
  # ---------------------------------------------------------------------------

  defp do_next_tick(state, elapsed_time) do
    data =
      state.data
      |> Warlord.upgrade()
      |> Warlord.advance(elapsed_time)
      |> timed_pass()

    {%{state | data: data}, Warlord}
  end

  defp timed_pass(data) do
    {:reductions, r0} = Process.info(self(), :reductions)
    t0 = System.monotonic_time(:microsecond)
    data = run(data)
    {:reductions, r1} = Process.info(self(), :reductions)
    Warlord.record_pass(data, System.monotonic_time(:microsecond) - t0, r1 - r0)
  end

  # A failure anywhere in the loop must cost one pass, never the process: a
  # crash here would restart the Warlord from the last snapshot on every tick.
  defp run(%Warlord{player_id: nil} = data) do
    case resolve_player(data) do
      nil -> data
      player_id -> run(%{data | player_id: player_id})
    end
  end

  defp run(%Warlord{} = data) do
    data = ensure_connected(data)

    case call(data, :player, data.player_id, :get_state) do
      {:ok, player} ->
        top_up(data, player)
        pass(data, player)

      _ ->
        data
    end
  rescue
    error ->
      Logger.error(
        "[wave] warlord pass failed in instance #{data.instance_id}: #{Exception.format(:error, error, __STACKTRACE__)}"
      )

      data
  end

  defp pass(data, player) do
    summaries = Map.new(player.characters, &{&1.id, &1})

    data =
      data
      |> drop_departed(player, summaries)
      |> observe_siderians(summaries)

    refresh? = rem(data.passes, max(knob(data, "state_refresh_passes", 20), 1)) == 0
    idle_navarchs = Enum.filter(Map.keys(data.colonisers), &(refresh? or roster_idle?(summaries[&1])))
    idle_siderians = Enum.filter(Map.keys(data.siderians), &(refresh? or roster_idle?(summaries[&1])))

    # A due hire only needs the galaxy when the last reading left room for one.
    # A held-due Navarch clock with a zero cap would otherwise rebuild the
    # geometry every pass for nothing; caps are re-read on every refresh pass.
    gauges = data.gauges

    hire_pending? =
      (Warlord.hire_due?(data) and Warlord.active_coloniser_count(data) < Map.get(gauges, :coloniser_cap, 1)) or
        (Warlord.siderian_hire_due?(data) and map_size(data.siderians) < Map.get(gauges, :siderian_cap, 1))

    needs_geometry? = refresh? or idle_navarchs != [] or idle_siderians != [] or hire_pending?

    data =
      with true <- needs_geometry?,
           {:ok, galaxy} <- call(data, :galaxy, :master, :get_state) do
        geo = Geometry.build(galaxy, data.bot_faction)

        # Pace and restraint: open new fronts only while behind the sector pace,
        # keep working an owned sector only while its vote lead is thin, and
        # never send more agents at a sector than it still needs.
        allowance = Warlord.sector_allowance(data, length(galaxy.sectors))
        frontier_open? = MapSet.size(geo.owned) < allowance
        hold_margin = trunc(knob(data, "hold_margin", 2))
        sector_of = Map.new(geo.systems, &{&1.id, &1.sector_id})
        pending = Warlord.pending_by_sector(data, sector_of)
        workable = Geometry.workable_sectors(geo, hold_margin, frontier_open?, pending)

        ctx = %{
          player: player,
          geo: geo,
          distances: %{},
          hold_margin: hold_margin,
          sector_of: sector_of,
          pending: pending
        }

        data =
          data
          |> Warlord.gauge(:sector_allowance, allowance)
          |> Warlord.gauge(:frontier_open, frontier_open?)
          |> Warlord.gauge(:workable_sectors, MapSet.size(workable))

        colonisation = Geometry.colonisation_candidates(geo, workable)
        captures = Geometry.capture_candidates(geo, workable)

        # The ceilings scale with the humans the Rebellion faces.
        humans = galaxy.players |> Map.values() |> Enum.count(&(&1.faction != data.bot_faction))
        data = Warlord.gauge(data, :human_players, humans)

        # The Navarch ceiling, under an optional hard `max_active_colonisers` cap.
        navarch_ceiling =
          case knob(data, "max_active_colonisers", nil) do
            cap when is_number(cap) -> min(Warlord.agent_ceiling(data, :navarchs), trunc(cap))
            _ -> Warlord.agent_ceiling(data, :navarchs)
          end

        nav_cap =
          Warlord.coloniser_cap(
            length(colonisation),
            knob(data, "idle_navarch_factor", 1.5) * 1.0,
            navarch_ceiling
          )

        sid_cap = Warlord.siderian_cap(length(captures), Warlord.agent_ceiling(data, :siderians))

        data =
          data
          |> Warlord.gauge(:unclaimed_neighbouring, length(colonisation))
          |> Warlord.gauge(:coloniser_cap, nav_cap)
          |> Warlord.gauge(:capture_targets, length(captures))
          |> Warlord.gauge(:siderian_cap, sid_cap)
          |> Warlord.gauge(:sectors_owned, MapSet.size(geo.owned))

        {data, ctx} = steer_navarchs(data, ctx, idle_navarchs, colonisation, nav_cap)
        {data, ctx} = steer_siderians(data, ctx, idle_siderians, captures)

        data
        |> maybe_hire_navarch(ctx, nav_cap)
        |> maybe_hire_siderian(ctx, sid_cap)
      else
        _ -> data
      end

    maybe_report_day(data, player)
  end

  # The roster summary is kept current by the character agents' update casts;
  # it is only a pre-filter — the full state is re-read before acting.
  defp roster_idle?(%{action_status: :idle, actions: nil}), do: true
  defp roster_idle?(%{action_status: :idle, actions: actions}), do: ActionQueue.empty?(actions)
  defp roster_idle?(_), do: false

  # Tracked agents that left the board: dismiss the ones sitting in the deck
  # (a recall whose dismissal didn't go through), forget the rest (killed,
  # converted, dismissed elsewhere).
  defp drop_departed(data, player, summaries) do
    deck = MapSet.new(player.character_deck, fn %{character: c} -> c.id end)

    tracked =
      Enum.map(Map.keys(data.colonisers), &{&1, :navarch}) ++ Enum.map(Map.keys(data.siderians), &{&1, :siderian})

    Enum.reduce(tracked, data, fn {id, role}, acc ->
      cond do
        Map.has_key?(summaries, id) ->
          acc

        MapSet.member?(deck, id) ->
          dismiss(acc, id, role)

        role == :navarch ->
          Warlord.forget(acc, id)

        true ->
          log(acc, "wave_siderian_lost", id, nil, siderian_record(acc, id))

          acc
          |> Warlord.count(:siderians_lost)
          |> Warlord.forget_siderian(id)
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Setup steps
  # ---------------------------------------------------------------------------

  # The bot player is normally known at boot (Instance.Manager passes it in).
  # This fallback covers a Warlord started before the bot registered.
  defp resolve_player(data) do
    with {:ok, galaxy} <- call(data, :galaxy, :master, :get_state),
         %{id: id} <- galaxy.players |> Map.values() |> Enum.find(&(&1.faction == data.bot_faction)) do
      id
    else
      _ -> nil
    end
  end

  defp ensure_connected(%Warlord{connected: true} = data), do: data

  defp ensure_connected(data) do
    case call(data, :player, data.player_id, {:update_client_status, :connect}) do
      :ok -> %{data | connected: true}
      _ -> data
    end
  end

  # Keep the bot's stock at its floors. Hiring charges the canonical market
  # price, so without this later hires would fail on affordability. Bankruptcy
  # itself is suppressed in Player.detect_bankruptcy.
  defp top_up(data, player) do
    credit = shortfall(player.credit.value, knob(data, "credit_floor", 0))
    technology = shortfall(player.technology.value, knob(data, "technology_floor", 0))
    ideology = shortfall(player.ideology.value, knob(data, "ideology_floor", 0))

    if credit + technology + ideology > 0 do
      call(data, :player, data.player_id, {:add_resources, credit, technology, ideology})
    end

    :ok
  end

  defp shortfall(value, floor) when is_number(value) and is_number(floor) and value < floor,
    do: trunc(Float.ceil((floor - value) / 1))

  defp shortfall(_value, _floor), do: 0

  # ---------------------------------------------------------------------------
  # Navarchs: hiring
  # ---------------------------------------------------------------------------

  defp maybe_hire_navarch(data, ctx, cap) do
    cond do
      not Warlord.hire_due?(data) ->
        data

      Warlord.active_coloniser_count(data) >= cap ->
        # Hold the clock at "due" rather than letting it bank several intervals,
        # which would otherwise fire a burst of hires the moment a slot frees.
        %{data | hire_accum: Warlord.hire_interval(data)}

      true ->
        data
        |> Warlord.consume_hire()
        |> hire_navarch(ctx)
    end
  end

  # Buy a one-star Navarch, deploy it on-board at home, and put a colony ship
  # straight into its fleet.
  defp hire_navarch(data, ctx) do
    tile = knob(data, "colony_ship_tile", 1)

    with {:ok, %{id: id}, home_id} <- hire_agent(data, ctx, :admiral),
         {:ok, _} <- grant_colony_ship(data, id, tile) do
      Logger.info("[wave] instance #{data.instance_id}: rebellion deployed Navarch #{id} at system #{home_id}")

      data
      |> Warlord.count(:hired)
      |> Warlord.count(:deployed)
      |> Warlord.track(id)
    else
      {:error, stage, reason} ->
        Logger.warning("[wave] instance #{data.instance_id}: Navarch hire refused at #{stage}: #{inspect(reason)}")
        Warlord.refuse(data, stage, reason)
    end
  end

  # Market purchase + on-board activation at the capital, shared by both roles.
  # `score` ranks market candidates (Warlord.pick_candidate/3); Navarchs take
  # the default, which is cheapest-first. Returns the bought character.
  defp hire_agent(data, ctx, type, score \\ fn _character -> 1 end) do
    rank = rank_atom(knob(data, "hire_rank", "common"))

    with {:ok, market} <- step(:market, call(data, :character_market, :master, :get_state)),
         {:ok, candidate} <- step(:market, Warlord.pick_candidate(market_by_rank(market, type), rank, score)),
         {:ok, player} <-
           step(:hire, player_reply(call(data, :player, data.player_id, {:hire_character, candidate.id}))),
         {:ok, home_id} <- home_system(player || ctx.player),
         {:ok, _player} <-
           step(
             :activate,
             player_reply(call(data, :player, data.player_id, {:activate_character, candidate.id, :on_board, home_id}))
           ) do
      {:ok, candidate, home_id}
    end
  end

  # The market's characters of one type, grouped by rank.
  defp market_by_rank(market, type) do
    market.slots
    |> Enum.filter(&(&1.key == type))
    |> Enum.flat_map(& &1.data)
    |> Map.new(fn %{key: key, data: slots} -> {key, slots |> Enum.map(& &1.character) |> Enum.reject(&is_nil/1)} end)
  end

  # Prefer the capital; otherwise any owned system that isn't under siege
  # (activation is refused under siege).
  defp home_system(player) do
    systems = Enum.reject(player.stellar_systems, &(Map.get(&1, :siege) != nil))

    case Enum.find(systems, &Map.get(&1, :capital?, false)) || List.first(systems) do
      nil -> {:error, :activate, :no_home_system}
      system -> {:ok, system.id}
    end
  end

  # The "instant build": plan the ship on the tile, then complete it at once.
  # This is the same order_ship + put_ship pair the fight simulator uses — no
  # production queue, no credit, no patent, no shipyard. `put_ship` is a cast,
  # so the Navarch reads `:docking` until it lands; dispatch waits a pass.
  defp grant_colony_ship(data, character_id, tile) do
    case call(data, :character, character_id, {:order_ship, {nil, tile, @colony_ship, nil}}) do
      {:ok, _character} ->
        Game.cast(data.instance_id, :character, character_id, {:put_ship, tile, 0})
        {:ok, :granted}

      other ->
        {:error, :colony_ship, reason_of(other)}
    end
  end

  # ---------------------------------------------------------------------------
  # Navarchs: management
  # ---------------------------------------------------------------------------

  defp steer_navarchs(data, ctx, [], _colonisation, _cap), do: {Warlord.gauge(data, :navarchs_without_target, 0), ctx}

  defp steer_navarchs(data, ctx, ids, colonisation, cap) do
    surplus = max(Warlord.active_coloniser_count(data) - cap, 0)

    {data, ctx, _surplus, without_target} =
      Enum.reduce(ids, {data, ctx, surplus, 0}, fn id, {d, c, s, nt} ->
        case call(d, :player, d.player_id, {:get_character_state, id}) do
          %Character{type: :admiral} = character -> steer_navarch(d, c, character, colonisation, s, nt)
          _ -> {d, c, s, nt}
        end
      end)

    {Warlord.gauge(data, :navarchs_without_target, without_target), ctx}
  end

  defp steer_navarch(data, ctx, character, colonisation, surplus, without_target) do
    entry = Map.get(data.colonisers, character.id)
    idle? = character.action_status == :idle and ActionQueue.empty?(character.actions)
    has_ship? = Character.has_colonization_ship?(character)

    cond do
      # Travelling, colonising, or still docking while its ship lands.
      not idle? ->
        {data, ctx, surplus, without_target}

      # More colonisers than the neighbourhood can use: release this one.
      has_ship? and surplus > 0 ->
        {recall_and_dismiss(data, ctx, character, :released), ctx, surplus - 1, without_target}

      has_ship? ->
        case dispatch_navarch(data, ctx, character, colonisation) do
          {:no_target, data, ctx} -> {data, ctx, surplus, without_target + 1}
          {:ok, data, ctx} -> {data, ctx, surplus, without_target}
        end

      # We sent it and the ship is spent: the colony landed. Recall, then dismiss.
      entry.stage == :dispatched ->
        {recall_and_dismiss(data, ctx, character, :colonised), ctx, surplus, without_target}

      # Idle with no ship and never dispatched — the ship grant was lost. Retry it.
      true ->
        data =
          case grant_colony_ship(data, character.id, knob(data, "colony_ship_tile", 1)) do
            {:ok, _} -> data
            {:error, stage, reason} -> Warlord.refuse(data, stage, reason)
          end

        {data, ctx, surplus, without_target}
    end
  end

  defp dispatch_navarch(data, ctx, %Character{system: nil}, _colonisation), do: {:no_target, data, ctx}

  defp dispatch_navarch(data, ctx, character, colonisation) do
    # Don't count this Navarch's own stale target as reserved against itself.
    reserved = data |> Warlord.released(character.id) |> Warlord.reserved_targets()
    own_target = data.colonisers |> Map.get(character.id, %{}) |> Map.get(:target)

    open =
      colonisation
      |> Enum.reject(&MapSet.member?(reserved, &1.id))
      |> Enum.filter(&sector_room?(ctx, &1, own_target))

    if open == [] do
      {:no_target, data, ctx}
    else
      {distances, ctx} = distances(ctx, character.system)

      case Geometry.nearest(open, distances) do
        nil ->
          {:no_target, data, ctx}

        %{id: target_id} ->
          {data, ctx} =
            case order(data, ctx, character, "colonization", target_id) do
              :ok ->
                {data |> Warlord.dispatched(character.id, target_id) |> Warlord.count(:dispatched),
                 commit_sector(ctx, target_id)}

              {:error, reason} ->
                {Warlord.refuse(data, :dispatch, reason), ctx}
            end

          {:ok, data, ctx}
      end
    end
  end

  defp recall_and_dismiss(data, ctx, character, counter, role \\ :navarch) do
    case player_reply(call(data, :player, data.player_id, {:deactivate_character, character.id})) do
      {:ok, _player} ->
        data
        |> Warlord.count(counter)
        |> dismiss(character.id, role)

      # Not standing in an owned system — walk it home, recall next pass.
      {:error, :character_not_at_home} ->
        send_home(data, ctx, character)

      {:error, reason} ->
        Warlord.refuse(data, :recall, reason)
    end
  end

  # Dismissal carries no deck cooldown (Player.dismiss_character/2 only checks
  # the card exists), so a freshly recalled agent can be released at once.
  defp dismiss(data, character_id, role) do
    case player_reply(call(data, :player, data.player_id, {:dismiss_character, character_id})) do
      {:ok, _player} ->
        data = Warlord.count(data, :dismissed)

        if role == :navarch do
          Warlord.forget(data, character_id)
        else
          log(data, "wave_siderian_released", character_id, nil, siderian_record(data, character_id))
          Warlord.forget_siderian(data, character_id)
        end

      {:error, reason} ->
        Warlord.refuse(data, :dismiss, reason)
    end
  end

  defp send_home(data, ctx, character) do
    {distances, _ctx} = distances(ctx, character.system)

    home =
      (ctx.player.stellar_systems ++ ctx.player.dominions)
      |> Enum.filter(&Map.has_key?(distances, &1.id))
      |> Enum.min_by(&Map.fetch!(distances, &1.id), fn -> nil end)

    with %{id: home_id} <- home,
         hops when is_list(hops) and hops != [] <- Nav.path_hops(ctx.geo.adjacency, character.system, home_id),
         jumps =
           Enum.map(hops, fn {from, to} -> %{"type" => "jump", "data" => %{"source" => from, "target" => to}} end),
         :ok <- call(data, :player, data.player_id, {:add_character_actions, character.id, jumps}) do
      data
    else
      _ -> Warlord.refuse(data, :recall, :no_route_home)
    end
  end

  # ---------------------------------------------------------------------------
  # Siderians: hiring and dominion capture
  # ---------------------------------------------------------------------------

  defp maybe_hire_siderian(data, ctx, cap) do
    if map_size(data.siderians) < cap and Warlord.siderian_hire_due?(data) do
      specializations = speaker_specializations(data)
      strength = fn character -> Warlord.capture_strength(Map.get(character, :skills), specializations) end

      case hire_agent(data, ctx, :speaker, strength) do
        {:ok, candidate, home_id} ->
          Logger.info(
            "[wave] instance #{data.instance_id}: rebellion deployed Siderian #{candidate.id} at system #{home_id}"
          )

          log(data, "wave_siderian_hired", candidate.id, home_id, %{
            day: Warlord.match_day(data),
            strength: strength.(candidate),
            level: Map.get(candidate, :level),
            specialization: Map.get(candidate, :specialization),
            roster: map_size(data.siderians) + 1,
            cap: cap
          })

          data
          |> Warlord.count(:siderians_hired)
          |> Warlord.track_siderian(candidate.id)

        # Nobody on the market can win a capture roll. Buying one anyway would
        # hold a slot with a Siderian that fails every attempt.
        {:error, :market, :no_candidate} ->
          data
          |> Warlord.refuse(:market, :no_capable_siderian)
          |> Warlord.defer_siderian_hire()

        {:error, stage, reason} ->
          Logger.warning("[wave] instance #{data.instance_id}: Siderian hire refused at #{stage}: #{inspect(reason)}")
          Warlord.refuse(data, stage, reason)
      end
    else
      data
    end
  end

  # The speaker skill table, for Warlord.capture_strength/2. Read at most once
  # per pass, and only when Siderians are hired or steered.
  defp speaker_specializations(data) do
    Data.Querier.one(Data.Game.Character, data.instance_id, :speaker).specializations
  end

  # Charge game time to each Siderian's observed state. The roster summary has
  # no speaker data, so idle Siderians are observed in steer_siderian instead,
  # where the full state shows whether a cooldown is running.
  defp observe_siderians(data, summaries) do
    Enum.reduce(Map.keys(data.siderians), data, fn id, acc ->
      case Map.get(summaries, id) do
        %{action_status: status} when status != :idle ->
          observe(acc, id, Warlord.siderian_bucket(status, false), status)

        _ ->
          acc
      end
    end)
  end

  defp observe(data, character_id, bucket, action_status) do
    {data, events} = Warlord.observe_siderian(data, character_id, bucket, action_status)

    Enum.each(events, fn {:started, id, payload} ->
      log(data, "wave_siderian_started", id, payload.target, payload)
    end)

    data
  end

  defp steer_siderians(data, ctx, [], _captures), do: {Warlord.gauge(data, :siderians_without_target, 0), ctx}

  defp steer_siderians(data, ctx, ids, captures) do
    specializations = speaker_specializations(data)

    {data, ctx, without_target} =
      Enum.reduce(ids, {data, ctx, 0}, fn id, {d, c, nt} ->
        case call(d, :player, d.player_id, {:get_character_state, id}) do
          %Character{type: :speaker} = character -> steer_siderian(d, c, character, captures, specializations, nt)
          _ -> {d, c, nt}
        end
      end)

    {Warlord.gauge(data, :siderians_without_target, without_target), ctx}
  end

  defp steer_siderian(data, ctx, character, captures, specializations, without_target) do
    locked? = Speaker.locked?(character.speaker)

    data =
      observe(data, character.id, Warlord.siderian_bucket(character.action_status, locked?), character.action_status)

    entry = Map.get(data.siderians, character.id)
    idle? = character.action_status == :idle and ActionQueue.empty?(character.actions)

    cond do
      not idle? ->
        {data, ctx, without_target}

      true ->
        # An attempt we sent has concluded one way or the other: score it.
        data =
          if entry.stage == :dispatched,
            do: resolve_capture(data, ctx, character.id, entry.target),
            else: data

        cond do
          # No capture skill means every roll fails: free the slot for a capable hire.
          Warlord.capture_strength(character.skills, specializations) <= 0 ->
            {recall_and_dismiss(data, ctx, character, :siderians_released, :siderian), ctx, without_target}

          # After an attempt a Siderian rests (the make_dominion cooldown).
          locked? ->
            {data, ctx, without_target}

          true ->
            dispatch_siderian(data, ctx, character, captures, without_target)
        end
    end
  end

  defp resolve_capture(data, ctx, character_id, target_id) do
    captured? = Enum.any?(ctx.geo.systems, &(&1.id == target_id and &1.faction == data.bot_faction))
    {data, payload} = Warlord.resolve_siderian(data, character_id, captured?)

    if payload, do: log(data, "wave_siderian_resolved", character_id, target_id, payload)

    data
  end

  defp dispatch_siderian(data, ctx, %Character{system: nil}, _captures, without_target),
    do: {data, ctx, without_target + 1}

  defp dispatch_siderian(data, ctx, _character, [], without_target), do: {data, ctx, without_target + 1}

  # Targets other Siderians already work on stay in play, but each extra
  # Siderian on a target is much less likely (Warlord.admit_targets/4), and a
  # sector that already has all the work it needs is skipped.
  defp dispatch_siderian(data, ctx, character, captures, without_target) do
    {distances, ctx} = distances(ctx, character.system)
    commitments = Warlord.commitments(data, character.id)

    admitted =
      captures
      |> Enum.filter(&(Map.has_key?(distances, &1.id) and sector_room?(ctx, &1)))
      |> Warlord.admit_targets(commitments, roll(data), knob(data, "capture_overlap_falloff", 0.2) * 1.0)

    case Geometry.pick_capture(ctx.geo, admitted, distances, roll(data), capture_weights(data)) do
      nil ->
        {data, ctx, without_target + 1}

      %{id: target_id} = target ->
        info = %{
          class: Geometry.class_of(ctx.geo, target),
          sector: target.sector_id,
          hops: Map.fetch!(distances, target_id),
          overlap: Map.get(commitments, target_id, 0),
          from: character.system
        }

        {data, ctx} =
          case order(data, ctx, character, "make_dominion", target_id) do
            :ok ->
              log(
                data,
                "wave_siderian_dispatched",
                character.id,
                target_id,
                Map.put(info, :day, Warlord.match_day(data))
              )

              data =
                data
                |> Warlord.siderian_dispatched(character.id, target_id, info)
                |> Warlord.count(:captures_attempted)
                |> then(&if(info.overlap > 0, do: Warlord.count(&1, :capture_overlaps), else: &1))

              {data, commit_sector(ctx, target_id)}

            {:error, reason} ->
              {Warlord.refuse(data, :capture, reason), ctx}
          end

        {data, ctx, without_target}
    end
  end

  defp capture_weights(data) do
    weights = knob(data, "capture_weights", %{})

    %{
      frontier: Map.get(weights, "frontier", 80),
      border: Map.get(weights, "border", 15),
      internal: Map.get(weights, "internal", 5)
    }
  end

  defp roll(data) do
    case Game.call(data.instance_id, :rand, :master, {:uniform}) do
      value when is_float(value) -> value
      _ -> :rand.uniform()
    end
  end

  # ---------------------------------------------------------------------------
  # Behaviour log
  # ---------------------------------------------------------------------------

  # One wave_daily rollup per match day: cumulative counters, gauges and
  # Siderian time, plus the empire's size.
  defp maybe_report_day(data, player) do
    if Warlord.daily_report_due?(data) do
      payload =
        Warlord.daily_payload(data, %{
          systems: length(player.stellar_systems),
          dominions: length(player.dominions),
          characters: length(player.characters)
        })

      log(data, "wave_daily", nil, nil, payload)
      Warlord.mark_daily_reported(data)
    else
      data
    end
  end

  defp siderian_record(data, character_id) do
    entry = Map.get(data.siderians, character_id, %{})

    %{
      day: Warlord.match_day(data),
      stage: Map.get(entry, :stage),
      target: Map.get(entry, :target),
      hired_ut_ago: Float.round((data.elapsed - Map.get(entry, :since, data.elapsed)) / 1, 1),
      time_ut: Map.get(entry, :time, %{})
    }
  end

  # instance_event_log rows, written async and best-effort (never raises).
  defp log(data, kind, character_id, system_id, payload) do
    RC.Instances.InstanceEventLog.emit(data.instance_id, kind, %{
      character_id: character_id,
      system_id: system_id,
      payload: payload
    })
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Overshoot guard: a sector takes only as many colonisations and captures as
  # it still needs (Geometry.sector_need/3), counting work already on its way
  # and dispatches made earlier in this pass. `own_target` is the agent's own
  # previous target, which shouldn't count against it.
  defp sector_room?(ctx, system, own_target \\ nil) do
    sector = system.sector_id
    own = if own_target != nil and Map.get(ctx.sector_of, own_target) == sector, do: 1, else: 0
    Geometry.sector_need(ctx.geo, sector, ctx.hold_margin) > Map.get(ctx.pending, sector, 0) - own
  end

  # Book a dispatch against its sector for the rest of the pass.
  defp commit_sector(ctx, target_id) do
    case Map.get(ctx.sector_of, target_id) do
      nil -> ctx
      sector -> %{ctx | pending: Map.update(ctx.pending, sector, 1, &(&1 + 1))}
    end
  end

  # Push lane hops + a terminal action in one go, then confirm the engine kept
  # it: add_character_actions answers :ok even when pre-validation silently
  # dropped every entry.
  defp order(data, ctx, character, action_type, target_id) do
    with hops when is_list(hops) <- Nav.path_hops(ctx.geo.adjacency, character.system, target_id),
         :ok <-
           call(
             data,
             :player,
             data.player_id,
             {:add_character_actions, character.id, Warlord.itinerary(hops, action_type, target_id)}
           ),
         true <- accepted?(data, character.id) do
      :ok
    else
      nil -> {:error, :no_route}
      false -> {:error, :dropped_by_engine}
      other -> {:error, reason_of(other)}
    end
  end

  defp accepted?(data, character_id) do
    case call(data, :player, data.player_id, {:get_character_state, character_id}) do
      %Character{actions: actions, action_status: status} -> not ActionQueue.empty?(actions) or status != :idle
      _ -> false
    end
  end

  # Hop distances from a system, computed once per pass per source.
  defp distances(ctx, from) do
    case Map.fetch(ctx.distances, from) do
      {:ok, distances} ->
        {distances, ctx}

      :error ->
        distances = Nav.hop_distances(ctx.geo.adjacency, from)
        {distances, %{ctx | distances: Map.put(ctx.distances, from, distances)}}
    end
  end

  defp call(data, type, id, message), do: Game.call(data.instance_id, type, id, message, 2, 5_000)

  defp knob(data, key, default), do: Wave.Config.knob(data.instance_id, key, default)

  defp step(_stage, {:ok, value}), do: {:ok, value}
  defp step(stage, other), do: {:error, stage, reason_of(other)}

  # Several player-agent handlers reply with the bare player struct on success.
  defp player_reply(%Instance.Player.Player{} = player), do: {:ok, player}
  defp player_reply({:error, reason}), do: {:error, reason}
  defp player_reply(other), do: {:error, reason_of(other)}

  defp reason_of({:error, reason}), do: reason
  defp reason_of({:error, _stage, reason}), do: reason
  defp reason_of(:process_not_found), do: :process_not_found
  defp reason_of(other), do: {:unexpected, other}

  defp rank_atom(rank) when is_atom(rank), do: rank

  defp rank_atom(rank) when is_binary(rank) do
    String.to_existing_atom(rank)
  rescue
    ArgumentError -> :common
  end
end

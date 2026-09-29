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

  Siderian and Erased decisions and outcomes go to `instance_event_log` as
  `wave_*` events (async, best-effort), with one `wave_daily` rollup per match
  day, so a finished test game can be analysed after the fact.

  ## Roles

  Navarchs colonize, Siderians capture dominions, and the Erased hunt people:
  removal, sabotage and infiltration, split between the sectors the Rebellion
  owns and the ones it strikes into. What they may see of a target comes from
  `Wave.Recon` and `Wave.Intel`; what they do about it is `Wave.Erased`.
  """

  use Core.TickServer

  require Logger

  alias Instance.Character.{ActionQueue, Character, Speaker, Spy}
  alias Wave.{Erased, Geometry, Nav, Warlord}

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
    data = %{data | hire_accum: Warlord.hire_interval(data)} |> Warlord.force_pass()
    state = next_tick(%{state | data: data})
    {:reply, {:ok, Warlord.summary(state.data)}, state}
  end

  # Dev/test lever: run one management pass now.
  @decorate tick()
  def on_call(:run_now, _from, state) do
    state = next_tick(%{state | data: state.data |> Warlord.upgrade() |> Warlord.force_pass()})
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

    # Calls tick too (see Warlord.pass_due?/1): only the scheduled wake-up acts.
    data = if Warlord.pass_due?(data), do: data |> timed_pass() |> Warlord.mark_pass(), else: data

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
      |> observe_erased(summaries)

    refresh? = rem(data.passes, max(knob(data, "state_refresh_passes", 20), 1)) == 0
    idle_navarchs = Enum.filter(Map.keys(data.colonisers), &(refresh? or roster_idle?(summaries[&1])))
    idle_siderians = Enum.filter(Map.keys(data.siderians), &(refresh? or roster_idle?(summaries[&1])))
    idle_erased = Enum.filter(Map.keys(data.erased), &(refresh? or roster_idle?(summaries[&1])))

    # A due hire only needs the galaxy when the last reading left room for one.
    # A held-due Navarch clock with a zero cap would otherwise rebuild the
    # geometry every pass for nothing; caps are re-read on every refresh pass.
    gauges = data.gauges

    hire_pending? =
      (Warlord.hire_due?(data) and Warlord.active_coloniser_count(data) < Map.get(gauges, :coloniser_cap, 1)) or
        (Warlord.siderian_hire_due?(data) and map_size(data.siderians) < Map.get(gauges, :siderian_cap, 1)) or
        (Warlord.erased_hire_due?(data) and map_size(data.erased) < Map.get(gauges, :erased_cap, 1))

    needs_geometry? = refresh? or idle_navarchs != [] or idle_siderians != [] or idle_erased != [] or hire_pending?

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
          galaxy: galaxy,
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
        erased_cap = Warlord.agent_ceiling(data, :erased)

        data =
          data
          |> Warlord.gauge(:unclaimed_neighbouring, length(colonisation))
          |> Warlord.gauge(:coloniser_cap, nav_cap)
          |> Warlord.gauge(:capture_targets, length(captures))
          |> Warlord.gauge(:siderian_cap, sid_cap)
          |> Warlord.gauge(:erased_cap, erased_cap)
          |> Warlord.gauge(:sectors_owned, MapSet.size(geo.owned))

        {data, ctx} = steer_navarchs(data, ctx, idle_navarchs, colonisation, nav_cap)
        {data, ctx} = steer_siderians(data, ctx, idle_siderians, captures)
        {data, ctx} = steer_erased(data, ctx, idle_erased)

        data
        |> maybe_hire_navarch(ctx, nav_cap)
        |> maybe_hire_siderian(ctx, sid_cap)
        |> maybe_hire_erased(ctx, erased_cap)
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
      Enum.map(Map.keys(data.colonisers), &{&1, :navarch}) ++
        Enum.map(Map.keys(data.siderians), &{&1, :siderian}) ++
        Enum.map(Map.keys(data.erased), &{&1, :erased})

    Enum.reduce(tracked, data, fn {id, role}, acc ->
      cond do
        Map.has_key?(summaries, id) ->
          acc

        MapSet.member?(deck, id) ->
          dismiss(acc, id, role)

        role == :navarch ->
          Warlord.forget(acc, id)

        role == :erased ->
          log(acc, "wave_erased_lost", id, nil, erased_record(acc, id))

          acc
          |> Warlord.count(:erased_lost)
          |> Warlord.forget_erased(id)

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
      |> Warlord.order("hire:navarch", :ok)
      |> Warlord.track(id)
    else
      {:error, stage, reason} ->
        Logger.warning("[wave] instance #{data.instance_id}: Navarch hire refused at #{stage}: #{inspect(reason)}")

        data
        |> Warlord.refuse(stage, reason)
        |> Warlord.order("hire:navarch", {:error, {stage, reason}})
    end
  end

  # Market purchase + on-board activation at the capital, shared by all three
  # roles. `score` ranks market candidates (Warlord.pick_candidate/3); Navarchs
  # take the default, which is cheapest-first. Returns the bought character.
  #
  # The home system is resolved BEFORE the purchase, and a card that cannot be
  # activated afterwards is dismissed again. Activation is refused under siege,
  # so a Rebellion down to one besieged system would otherwise buy an agent it
  # cannot deploy every pass until the deck is full — and a full deck refuses
  # every later hire, long after the siege lifts.
  defp hire_agent(data, ctx, type, score \\ fn _character -> 1 end) do
    ranks = Warlord.unlocked_ranks(data)

    with {:ok, _deployable} <- deployable_home(ctx.player),
         {:ok, market} <- step(:market, call(data, :character_market, :master, :get_state)),
         {:ok, candidate} <- step(:market, Warlord.pick_candidate(market_by_rank(market, type), ranks, score)),
         {:ok, player} <-
           step(:hire, player_reply(call(data, :player, data.player_id, {:hire_character, candidate.id}))),
         {:ok, home_id} <- home_system(player || ctx.player),
         {:ok, _player} <-
           step(
             :activate,
             player_reply(call(data, :player, data.player_id, {:activate_character, candidate.id, :on_board, home_id}))
           ) do
      {:ok, candidate, home_id}
    else
      {:error, :activate, _reason} = error ->
        release_card(data, type)
        error

      error ->
        error
    end
  end

  # The same check `home_system/1` makes, run before any credit is spent.
  defp deployable_home(player) do
    case home_system(player) do
      {:ok, id} -> {:ok, id}
      _ -> {:error, :market, :no_deployable_home}
    end
  end

  # Hand back every card sitting in the deck: the Rebellion only ever buys to
  # deploy at once, so anything still in the deck is a stranded purchase.
  defp release_card(data, type) do
    case call(data, :player, data.player_id, :get_state) do
      {:ok, player} ->
        for %{character: %{id: id, type: ^type}} <- player.character_deck do
          call(data, :player, data.player_id, {:dismiss_character, id})
        end

      _ ->
        :ok
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
                data =
                  data
                  |> Warlord.dispatched(character.id, target_id)
                  |> Warlord.count(:dispatched)
                  |> Warlord.order("order:colonization", :ok)

                {data, commit_sector(ctx, target_id)}

              {:error, reason} ->
                {data |> Warlord.refuse(:dispatch, reason) |> Warlord.order("order:colonization", {:error, reason}),
                 ctx}
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
        |> Warlord.order("recall", :ok)
        |> dismiss(character.id, role)

      # Not standing in an owned system — walk it home, recall next pass.
      {:error, :character_not_at_home} ->
        send_home(data, ctx, character)

      {:error, reason} ->
        data |> Warlord.refuse(:recall, reason) |> Warlord.order("recall", {:error, reason})
    end
  end

  # Dismissal carries no deck cooldown (Player.dismiss_character/2 only checks
  # the card exists), so a freshly recalled agent can be released at once.
  defp dismiss(data, character_id, role) do
    case player_reply(call(data, :player, data.player_id, {:dismiss_character, character_id})) do
      {:ok, _player} ->
        data = data |> Warlord.count(:dismissed) |> Warlord.order("dismiss", :ok)

        case role do
          :navarch ->
            Warlord.forget(data, character_id)

          :siderian ->
            log(data, "wave_siderian_released", character_id, nil, siderian_record(data, character_id))
            Warlord.forget_siderian(data, character_id)

          :erased ->
            log(data, "wave_erased_released", character_id, nil, erased_record(data, character_id))
            Warlord.forget_erased(data, character_id)
        end

      {:error, reason} ->
        data |> Warlord.refuse(:dismiss, reason) |> Warlord.order("dismiss", {:error, reason})
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
      Warlord.order(data, "order:return_home", :ok)
    else
      _ ->
        data
        |> Warlord.refuse(:recall, :no_route_home)
        |> Warlord.order("order:return_home", {:error, :no_route_home})
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
          |> Warlord.order("hire:siderian", :ok)
          |> Warlord.track_siderian(candidate.id)

        # Nothing worth buying — nobody on the market can win a capture roll, or
        # there is nowhere to deploy one. Look again after `siderian_retry_ut`
        # rather than on every pass.
        {:error, :market, reason} ->
          data
          |> Warlord.refuse(:market, reason)
          |> Warlord.order("hire:siderian", {:error, {:market, reason}})
          |> Warlord.defer_siderian_hire()

        {:error, stage, reason} ->
          Logger.warning("[wave] instance #{data.instance_id}: Siderian hire refused at #{stage}: #{inspect(reason)}")

          data
          |> Warlord.refuse(stage, reason)
          |> Warlord.order("hire:siderian", {:error, {stage, reason}})
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
                |> Warlord.order("order:make_dominion", :ok)
                |> then(&if(info.overlap > 0, do: Warlord.count(&1, :capture_overlaps), else: &1))

              {data, commit_sector(ctx, target_id)}

            {:error, reason} ->
              {data |> Warlord.refuse(:capture, reason) |> Warlord.order("order:make_dominion", {:error, reason}), ctx}
          end

        {data, ctx, without_target}
    end
  end

  # ---------------------------------------------------------------------------
  # Erased: hiring, postings and strikes
  # ---------------------------------------------------------------------------

  defp maybe_hire_erased(data, ctx, cap) do
    if map_size(data.erased) < cap and Warlord.erased_hire_due?(data) do
      specializations = spy_specializations(data)
      score = fn character -> Erased.offensive_strength(Map.get(character, :skills), specializations) end

      case hire_agent(data, ctx, :spy, score) do
        {:ok, candidate, home_id} ->
          posting = roll_posting(data, Map.get(candidate, :skills))

          Logger.info(
            "[wave] instance #{data.instance_id}: rebellion deployed Erased #{candidate.id} " <>
              "at system #{home_id} (#{posting.theatre}/#{posting.duty})"
          )

          log(data, "wave_erased_hired", candidate.id, home_id, %{
            day: Warlord.match_day(data),
            theatre: posting.theatre,
            duty: posting.duty,
            train_target: posting.train_target,
            skills: Erased.skill_points(Map.get(candidate, :skills)),
            strength: score.(candidate),
            level: Map.get(candidate, :level),
            ranks: ranks_view(data),
            specialization: Map.get(candidate, :specialization),
            roster: map_size(data.erased) + 1,
            cap: cap
          })

          data
          |> Warlord.count(:erased_hired)
          |> Warlord.order("hire:erased", :ok)
          |> Warlord.track_erased(candidate.id, posting)

        # Nothing worth buying — nobody on the market can infiltrate, remove or
        # sabotage, or there is nowhere to deploy one. Look again after
        # `erased_retry_ut` rather than on every pass.
        {:error, :market, reason} ->
          data
          |> Warlord.refuse(:market, reason)
          |> Warlord.order("hire:erased", {:error, {:market, reason}})
          |> Warlord.defer_erased_hire()

        {:error, stage, reason} ->
          Logger.warning("[wave] instance #{data.instance_id}: Erased hire refused at #{stage}: #{inspect(reason)}")

          data
          |> Warlord.refuse(stage, reason)
          |> Warlord.order("hire:erased", {:error, {stage, reason}})
      end
    else
      data
    end
  end

  # Theatre, then duty. A home posting is only a real posting when the agent
  # can already do the work; otherwise it trains until it can (or until the
  # field claims it).
  defp roll_posting(data, skills) do
    min_points = trunc(knob(data, "erased_home_duty_points", 2))
    theatre = Erased.theatre(roll(data), knob(data, "erased_home_share", 0.25) * 1.0)

    if theatre == :home and not Erased.fit_for_home_duty?(skills, min_points) do
      [lo, hi] = train_range(data)
      %{theatre: :home, duty: :training, train_target: Erased.train_target(roll(data), lo, hi)}
    else
      %{theatre: theatre, duty: Erased.duty(roll(data), duty_weights(data, theatre), skills), train_target: nil}
    end
  end

  # The spy skill table, for Erased.strength/3. Read at most once per pass, and
  # only when Erased are hired or steered.
  defp spy_specializations(data) do
    Data.Querier.one(Data.Game.Character, data.instance_id, :spy).specializations
  end

  # Charge game time to each Erased's observed state from the roster summary.
  # An idle Erased is observed in steer_erased instead, where the full state
  # shows whether its cover has dropped it out of action.
  defp observe_erased(data, summaries) do
    Enum.reduce(Map.keys(data.erased), data, fn id, acc ->
      case Map.get(summaries, id) do
        %{action_status: status} when status != :idle -> observe_spy(acc, id, Erased.bucket(status, false), status)
        _ -> acc
      end
    end)
  end

  defp observe_spy(data, character_id, bucket, action_status) do
    {data, events} = Warlord.observe_erased(data, character_id, bucket, action_status)

    Enum.each(events, fn {:started, id, payload} ->
      log(data, "wave_erased_started", id, payload.target, payload)
    end)

    data
  end

  defp steer_erased(data, ctx, []), do: {Warlord.gauge(data, :erased_without_target, 0), ctx}

  defp steer_erased(data, ctx, ids) do
    interval = knob(data, "erased_recon_interval_ut", 3.0) * 1.0

    # A hostile reading costs a faction read, one call per human player and a
    # capped sweep of the systems their agents stand in. Held for a few ut so
    # a fast tick cadence doesn't re-read the galaxy's people every pass.
    if Warlord.recon_due?(data, interval) do
      view = build_recon(data, ctx)
      specializations = spy_specializations(data)

      characters =
        ids
        |> Enum.map(&call(data, :player, data.player_id, {:get_character_state, &1}))
        |> Enum.filter(&match?(%Character{type: :spy}, &1))

      # The training Navarch is read, deployed or moved once, before anyone
      # decides whether to practise on it.
      {data, ctx} = prepare_dummy(data, ctx, characters)

      {data, ctx, without_target} =
        Enum.reduce(characters, {Warlord.mark_recon(data), ctx, 0}, fn character, {d, c, nt} ->
          steer_one_erased(d, c, view, character, specializations, nt)
        end)

      data =
        Enum.reduce(view.gauges, data, fn {key, value}, acc -> Warlord.gauge(acc, key, value) end)

      {Warlord.gauge(data, :erased_without_target, without_target), ctx}
    else
      {data, ctx}
    end
  end

  defp build_recon(data, ctx) do
    humans =
      ctx.galaxy.players
      |> Map.values()
      |> Enum.filter(&(&1.faction != data.bot_faction))
      |> Enum.map(& &1.id)

    Wave.Recon.build(
      instance_id: data.instance_id,
      faction: data.bot_faction,
      faction_id: ctx.player.faction_id,
      geo: ctx.geo,
      player: ctx.player,
      human_ids: humans,
      elapsed: data.elapsed,
      field_depth: trunc(knob(data, "erased_field_depth", 2)),
      scan_cap: trunc(knob(data, "erased_scan_cap", 60)),
      probe_cap: trunc(knob(data, "erased_probe_cap", 12)),
      probe_tiles: trunc(knob(data, "erased_sabotage_min_tiles", 6))
    )
  end

  defp steer_one_erased(data, ctx, view, character, specializations, without_target) do
    discovered? = Spy.discovered?(character.spy.cover.value, data.instance_id)
    data = observe_spy(data, character.id, Erased.bucket(character.action_status, discovered?), character.action_status)

    entry = Map.get(data.erased, character.id)
    idle? = character.action_status == :idle and ActionQueue.empty?(character.actions)

    cond do
      not idle? ->
        {data, ctx, without_target}

      true ->
        data =
          case Map.get(entry, :stage) do
            # A strike we ordered has run its course one way or the other: score it.
            :dispatched -> resolve_strike(data, view, character, entry)
            # A roamer has arrived: nothing to score, just free its slot.
            :roaming -> Warlord.erased_released(data, character.id)
            _ -> data
          end

        cond do
          # No offensive skill at all means every roll fails: free the slot.
          Erased.offensive_strength(character.skills, specializations) <= 0 ->
            {recall_and_dismiss(data, ctx, character, :erased_released, :erased), ctx, without_target}

          # Discovered. Every coefficient is multiplied to zero until the cover
          # recovers (Instance.Character.Spy.compute_bonus/3), so striking now
          # is a guaranteed failure, and the engine will not move a discovered
          # spy either (Instance.Character.Actions.Jump.pre_validate/2). It lies
          # low where it stands.
          discovered? ->
            {data, ctx, without_target}

          true ->
            data = maybe_graduate(data, character)
            dispatch_erased(data, ctx, view, character, without_target)
        end
    end
  end

  # A trainee that has learned its trade takes a permanent posting.
  defp maybe_graduate(data, character) do
    entry = Map.get(data.erased, character.id, %{})

    if Map.get(entry, :duty) == :training and Erased.trained?(character.skills, Map.get(entry, :train_target)) do
      {theatre, duty} =
        Erased.graduate(character.skills, {roll(data), roll(data)},
          home_share: knob(data, "erased_graduate_home_share", 0.5) * 1.0,
          min_points: trunc(knob(data, "erased_home_duty_points", 2)),
          home_weights: duty_weights(data, :home),
          field_weights: duty_weights(data, :field)
        )

      log(data, "wave_erased_graduated", character.id, character.system, %{
        day: Warlord.match_day(data),
        theatre: theatre,
        duty: duty,
        train_target: Map.get(entry, :train_target),
        skills: Erased.skill_points(character.skills),
        level: character.level
      })

      data
      |> Warlord.count(:erased_graduated)
      |> Warlord.repost_erased(character.id, theatre, duty)
    else
      data
    end
  end

  defp dispatch_erased(data, ctx, _view, %Character{system: nil}, without_target), do: {data, ctx, without_target + 1}

  defp dispatch_erased(data, ctx, view, character, without_target) do
    entry = Map.get(data.erased, character.id, %{})
    {distances, ctx} = distances(ctx, character.system)

    plan =
      case Map.get(entry, :duty) do
        :removal -> plan_removal(data, view, character, entry, distances)
        :sabotage -> plan_sabotage(data, view, character, entry, distances)
        :training -> plan_practice_infiltration(data, ctx, character, entry, distances)
        _ -> plan_infiltration(data, ctx, view, character, entry, distances)
      end

    # Nothing worth striking. While still green an Erased practises; trained,
    # or with nothing to practise on, it scouts ground the Rebellion has never
    # seen; with all of that seen, it waits.
    plan = plan || plan_practice(data, ctx, character, entry, distances)
    plan = plan || plan_explore(data, ctx, view, character, entry, distances)

    case plan do
      nil -> {data, ctx, without_target + 1}
      # The training Navarch is still walking to its post.
      :hold -> {data, ctx, without_target}
      plan -> commit_plan(data, ctx, view, character, entry, distances, plan, without_target)
    end
  end

  # Push a plan — a strike or a reposition — and book it on the roster.
  defp commit_plan(data, ctx, view, character, entry, distances, plan, without_target) do
    %{action: action, target: target_id} = plan

    info =
      plan
      |> Map.take([
        :action,
        :target_character,
        :target_key,
        :odds,
        :odds_class,
        :overlap,
        :target_tiles,
        :target_name,
        :move_only,
        :training
      ])
      |> Map.merge(%{
        duty: Map.get(entry, :duty),
        theatre: Map.get(entry, :theatre),
        hops: Map.get(distances, target_id),
        from: character.system,
        # What the strike will cost, measured after the fact: cover only
        # recovers on its own, so a drop is proof the action ran.
        cover: character.spy.cover.value,
        target_visibility: Wave.Recon.visibility(view, target_id)
      })

    extra = if plan[:target_character], do: %{"target_character" => plan.target_character}, else: %{}
    move_only? = Map.get(plan, :move_only, false)

    result =
      if move_only?,
        do: travel(data, ctx, character, target_id),
        else: order(data, ctx, character, action, target_id, extra)

    practice? = Map.get(plan, :training, false)

    kind =
      cond do
        move_only? -> "order:roam"
        practice? -> "practice:#{action}"
        true -> "order:#{action}"
      end

    data = Warlord.order(data, kind, result)

    data =
      case result do
        :ok ->
          log(data, "wave_erased_dispatched", character.id, target_id, loggable(info, data))

          data
          |> then(
            &if(move_only?,
              do: Warlord.erased_roaming(&1, character.id, target_id, info),
              else: Warlord.erased_dispatched(&1, character.id, target_id, info)
            )
          )
          |> Warlord.count(if(practice?, do: :erased_practice, else: counter_for(action)))
          |> then(&if(Map.get(info, :overlap, 0) > 0, do: Warlord.count(&1, :erased_overlaps), else: &1))

        {:error, reason} ->
          Warlord.refuse(data, Warlord.erased_refusal_key(action), reason)
      end

    {data, ctx, without_target}
  end

  # The behaviour log is JSON; a `{:character, 34}` target key is not. Print it
  # instead — the roster keeps the tuple, which is what commitments count on.
  defp loggable(info, data) do
    info
    |> Map.put(:day, Warlord.match_day(data))
    |> Map.update(:target_key, nil, fn
      {kind, id} -> "#{kind}:#{id}"
      other -> other
    end)
  end

  defp ranks_view(data), do: data |> Warlord.unlocked_ranks() |> Enum.map(&Atom.to_string/1)

  defp counter_for("assassination"), do: :removals_attempted
  defp counter_for("sabotage"), do: :sabotages_attempted
  defp counter_for("roam"), do: :erased_roams
  defp counter_for(_action), do: :infiltrations_attempted

  # --- Erased: target plans ---------------------------------------------------

  # Removal is the one strike that can be thrown away on a single roll, so the
  # shortlist is walked best-odds-first and each candidate is gated on what the
  # Rebellion can actually read of its defence.
  defp plan_removal(data, view, character, entry, distances) do
    attack = character.spy.assassination_coef.value
    gate = knob(data, "erased_removal_gate", %{})

    candidates =
      view
      |> then(&reachable_hostiles(data, &1, entry, character, distances))
      |> Enum.filter(&Erased.removable?/1)
      |> admit(data, entry, character, &{:character, &1.id})

    candidates
    |> Enum.map(fn hostile ->
      chance = removal_chance(attack, character.level, hostile)
      {Erased.removal_priority(hostile, chance, Map.fetch!(distances, hostile.system)), hostile, chance}
    end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.take(3)
    |> Enum.find_value(fn {_priority, hostile, chance} ->
      if roll(data) < Wave.Intel.attempt_chance(chance, gate) do
        %{
          action: "assassination",
          target: hostile.system,
          target_character: hostile.id,
          target_key: {:character, hostile.id},
          odds: chance && Float.round(chance, 3),
          odds_class: Wave.Intel.odds_class(chance),
          # Kept so the strike can be scored: a Navarch holding a fleet is not
          # killed outright — the engine hands the fleet to a fresh CMO under
          # the same character id, and the new name is the only tell.
          target_name: hostile.name,
          overlap: overlap(data, character.id, {:character, hostile.id})
        }
      end
    end)
  end

  # A defence the Rebellion cannot read leaves `chance` nil, which the gate
  # turns into its flat blind-attempt rate.
  defp removal_chance(_attack, _level, %{protection: nil}), do: nil

  defp removal_chance(attack, level, hostile),
    do: Wave.Intel.success_chance(attack, level, hostile.protection + (hostile.counter_intelligence || 0))

  defp plan_sabotage(data, view, character, entry, distances) do
    min_tiles =
      if Map.get(entry, :theatre) == :home,
        do: trunc(knob(data, "erased_home_sabotage_min_tiles", 4)),
        else: trunc(knob(data, "erased_sabotage_min_tiles", 6))

    view
    |> then(&reachable_hostiles(data, &1, entry, character, distances))
    |> Enum.filter(&Erased.worth_sabotaging?(&1, min_tiles))
    |> admit(data, entry, character, &{:character, &1.id})
    |> Enum.min_by(&Erased.sabotage_priority(&1, Map.fetch!(distances, &1.system)), fn -> nil end)
    |> case do
      nil ->
        nil

      hostile ->
        %{
          action: "sabotage",
          target: hostile.system,
          target_character: hostile.id,
          target_key: {:character, hostile.id},
          target_tiles: hostile.tiles,
          overlap: overlap(data, character.id, {:character, hostile.id})
        }
    end
  end

  # Field infiltration works enemy ground and the neutral systems around it,
  # skipping anything the Rebellion can already see whole, and anything whose
  # Intelligence it has learned is out of this agent's reach.
  defp plan_infiltration(data, ctx, view, character, entry, distances) do
    theatre = Map.get(entry, :theatre, :field)
    depth = trunc(knob(data, "erased_field_depth", 2))
    min_chance = knob(data, "erased_train_min_chance", 0.25) * 1.0
    attack = character.spy.infiltrate_coef.value

    ctx.geo.systems
    |> Enum.filter(fn system ->
      system.faction != data.bot_faction and
        Map.has_key?(distances, system.id) and
        Geometry.theatre_of(ctx.geo, system, depth) == theatre and
        system.status in [:inhabited_neutral, :inhabited_dominion, :inhabited_player] and
        Erased.worth_infiltrating?(Wave.Recon.visibility(view, system.id)) and
        Erased.practice_odds(infiltration_chance(data, attack, character.level, system.id), min_chance) != :hopeless
    end)
    |> admit(data, entry, character, &{:system, &1.id})
    |> Enum.min_by(&{infiltration_rank(&1), Map.fetch!(distances, &1.id), &1.id}, fn -> nil end)
    |> case do
      nil ->
        nil

      system ->
        %{
          action: "infiltrate",
          target: system.id,
          target_key: {:system, system.id},
          overlap: overlap(data, character.id, {:system, system.id})
        }
    end
  end

  # Enemy dominions first, then enemy systems, then neutral ground.
  defp infiltration_rank(%{faction: nil}), do: 2
  defp infiltration_rank(%{status: :inhabited_dominion}), do: 0
  defp infiltration_rank(_system), do: 1

  # --- Erased: practice --------------------------------------------------------

  # Idle and still below the level cap: practise. Infiltration is the better
  # teacher, so any informer point settles it; an agent with sabotage points
  # and none in infiltration works the training Navarch instead while it is
  # close enough. Returns a plan, :hold (the training Navarch is on its way to
  # its post) or nil.
  defp plan_practice(data, ctx, character, entry, distances) do
    dummy? = knob(data, "erased_dummy", true) == true

    cond do
      not Erased.trains?(character.level, knob(data, "erased_train_max_level", 5)) ->
        nil

      Erased.practice(character.skills, dummy?) == :sabotage ->
        case plan_dummy_sabotage(data, ctx, character) do
          :unavailable -> plan_practice_infiltration(data, ctx, character, entry, distances)
          plan_or_hold -> plan_or_hold
        end

      true ->
        plan_practice_infiltration(data, ctx, character, entry, distances)
    end
  end

  # Practice ground: neutral systems and other factions' dominions in the
  # agent's theatre. Nobody can read a system's Intelligence before
  # infiltrating it, so practice goes anywhere until one of our results has
  # reported it; from then on a known-soft system comes first and a
  # known-hopeless one is dropped. With no informer points the attack is 0,
  # which beats an Intelligence of 0 about half the time and nothing else.
  defp plan_practice_infiltration(data, ctx, character, entry, distances) do
    theatre = Map.get(entry, :theatre, :field)
    depth = trunc(knob(data, "erased_field_depth", 2))
    min_chance = knob(data, "erased_train_min_chance", 0.25) * 1.0
    attack = character.spy.infiltrate_coef.value

    candidates =
      ctx.geo.systems
      |> Enum.filter(fn system ->
        system.faction != data.bot_faction and
          system.status in [:inhabited_neutral, :inhabited_dominion] and
          Map.has_key?(distances, system.id) and
          Geometry.theatre_of(ctx.geo, system, depth) == theatre
      end)
      |> Enum.map(&{&1, infiltration_chance(data, attack, character.level, &1.id)})
      |> Enum.reject(fn {_system, chance} -> Erased.practice_odds(chance, min_chance) == :hopeless end)

    chances = Map.new(candidates, fn {system, chance} -> {system.id, chance} end)

    candidates
    |> Enum.map(&elem(&1, 0))
    |> admit(data, entry, character, &{:system, &1.id})
    |> Enum.min_by(&Erased.practice_priority(&1, chances[&1.id], Map.fetch!(distances, &1.id)), fn -> nil end)
    |> case do
      nil ->
        nil

      system ->
        chance = chances[system.id]

        %{
          action: "infiltrate",
          target: system.id,
          target_key: {:system, system.id},
          training: true,
          odds: chance && Float.round(chance, 3),
          odds_class: Wave.Intel.odds_class(chance),
          overlap: overlap(data, character.id, {:system, system.id})
        }
    end
  end

  # This agent's odds against a system's Intelligence as the Rebellion last
  # learned it, or nil when it has never been told.
  defp infiltration_chance(data, attack, level, system_id) do
    case Warlord.known_ci(data, system_id) do
      nil -> nil
      ci -> Wave.Intel.success_chance(attack, level, ci)
    end
  end

  # The training Navarch, when it is at its post, near enough and beatable.
  # :hold while it is still being deployed or walking there; :unavailable when
  # there is none, it is too far, or the odds are too poor to learn anything.
  defp plan_dummy_sabotage(data, ctx, character) do
    min_chance = knob(data, "erased_train_min_chance", 0.25) * 1.0
    max_travel = knob(data, "erased_dummy_max_travel_ut", 480.0)

    case ctx do
      %{dummy_ready?: true, dummy: %Character{} = dummy, dummy_defense: defense} ->
        travel = travel_ut(data, ctx, character.system, dummy.system)
        chance = Wave.Intel.success_chance(character.spy.sabotage_coef.value, character.level, defense)

        if is_number(travel) and travel <= max_travel and chance >= min_chance do
          %{
            action: "sabotage",
            target: dummy.system,
            target_character: dummy.id,
            target_key: {:character, dummy.id},
            target_name: dummy.name,
            training: true,
            odds: Float.round(chance, 3),
            odds_class: Wave.Intel.odds_class(chance)
          }
        else
          :unavailable
        end

      %{dummy_pending?: true} ->
        :hold

      _ ->
        :unavailable
    end
  end

  # --- Erased: the training Navarch ---------------------------------------------

  # Teams train saboteurs on a teammate's Navarch. The Rebellion is one player,
  # so it trains on its own; the engine lets the bot faction sabotage itself
  # (Instance.Character.Actions.Sabotage.start/2). It needs no ships: a
  # sabotage roll pays its experience whether or not there is a fleet to hit.
  # Read once a pass, deployed the first time a saboteur wants one, and kept
  # off rebel ground, where the system's Intelligence would join its defence.
  defp prepare_dummy(data, ctx, characters) do
    ctx = Map.merge(ctx, %{dummy: nil, dummy_ready?: false, dummy_pending?: false, dummy_defense: nil})
    wanted? = knob(data, "erased_dummy", true) == true and Enum.any?(characters, &wants_dummy?(data, &1))

    case Warlord.training_dummy(data) do
      nil ->
        if wanted?, do: deploy_dummy(data, ctx), else: {data, ctx}

      id ->
        if Enum.any?(ctx.player.characters, &(&1.id == id)) do
          case call(data, :player, data.player_id, {:get_character_state, id}) do
            %Character{type: :admiral} = dummy -> tend_dummy(data, ctx, dummy)
            # A failed read costs this pass, never the dummy.
            _ -> {data, %{ctx | dummy_pending?: true}}
          end
        else
          # Gone from the roster: removed by the humans, or dismissed. The next
          # saboteur that wants one gets a fresh one.
          log(data, "wave_dummy_lost", id, nil, %{day: Warlord.match_day(data)})
          data = data |> Warlord.set_training_dummy(nil) |> Warlord.count(:dummies_lost)
          if wanted?, do: deploy_dummy(data, ctx), else: {data, ctx}
        end
    end
  end

  # An idle, undiscovered agent below the level cap that would practise sabotage.
  defp wants_dummy?(data, character) do
    character.action_status == :idle and
      not Spy.discovered?(character.spy.cover.value, data.instance_id) and
      Erased.trains?(character.level, knob(data, "erased_train_max_level", 5)) and
      Erased.practice(character.skills, true) == :sabotage
  end

  # The Rebellion's own starting Navarch sits unused in its deck, and that is
  # the training Navarch. Without one, a Navarch is bought like any other.
  defp deploy_dummy(data, ctx) do
    result =
      case deck_navarch(ctx.player) do
        nil -> hire_agent(data, ctx, :admiral)
        card_id -> activate_card(data, ctx, card_id)
      end

    case result do
      {:ok, %{id: id}, home_id} ->
        Logger.info(
          "[wave] instance #{data.instance_id}: rebellion deployed training Navarch #{id} at system #{home_id}"
        )

        log(data, "wave_dummy_deployed", id, home_id, %{day: Warlord.match_day(data)})

        data =
          data
          |> Warlord.set_training_dummy(id)
          |> Warlord.count(:dummies_deployed)
          |> Warlord.order("deploy:dummy", :ok)

        # It starts at home; the next pass walks it to its post.
        {data, %{ctx | dummy_pending?: true}}

      {:error, stage, reason} ->
        {data |> Warlord.refuse(stage, reason) |> Warlord.order("deploy:dummy", {:error, {stage, reason}}), ctx}
    end
  end

  defp deck_navarch(%{character_deck: deck}) when is_list(deck) do
    Enum.find_value(deck, fn
      %{character: %{type: :admiral, id: id}} -> id
      _ -> nil
    end)
  end

  defp deck_navarch(_player), do: nil

  defp activate_card(data, ctx, card_id) do
    with {:ok, home_id} <- home_system(ctx.player),
         {:ok, _player} <-
           step(
             :activate,
             player_reply(call(data, :player, data.player_id, {:activate_character, card_id, :on_board, home_id}))
           ) do
      {:ok, %{id: card_id}, home_id}
    end
  end

  # A Navarch standing in one of its own faction's systems adds that system's
  # Intelligence to its defence against sabotage, so the dummy's post is the
  # nearest system nobody holds. Until it stands there, saboteurs hold.
  defp tend_dummy(data, ctx, dummy) do
    ctx = %{ctx | dummy: dummy}
    idle? = dummy.action_status == :idle and ActionQueue.empty?(dummy.actions)

    cond do
      not idle? or dummy.system == nil ->
        {data, %{ctx | dummy_pending?: true}}

      not rebel_held?(data, ctx, dummy.system) ->
        {data, dummy_ready(ctx, dummy.protection)}

      true ->
        case dummy_post(ctx, dummy.system) do
          # Nowhere better within reach: train here, against the full defence.
          nil ->
            {data, dummy_ready(ctx, dummy.protection + system_ci(data, dummy.system))}

          post ->
            case travel(data, ctx, dummy, post) do
              :ok ->
                {Warlord.order(data, "order:post_dummy", :ok), %{ctx | dummy_pending?: true}}

              {:error, reason} = error ->
                data = data |> Warlord.refuse(:post_dummy, reason) |> Warlord.order("order:post_dummy", error)
                {data, dummy_ready(ctx, dummy.protection + system_ci(data, dummy.system))}
            end
        end
    end
  end

  defp dummy_ready(ctx, defense), do: %{ctx | dummy_ready?: true, dummy_defense: defense}

  defp dummy_post(ctx, from) do
    distances = Nav.hop_distances(ctx.geo.adjacency, from)

    ctx.geo.systems
    |> Enum.filter(&(&1.faction == nil and &1.id != from and Map.has_key?(distances, &1.id)))
    |> Enum.min_by(&{Map.fetch!(distances, &1.id), &1.id}, fn -> nil end)
    |> case do
      nil -> nil
      system -> system.id
    end
  end

  defp rebel_held?(data, ctx, system_id) do
    case Enum.find(ctx.geo.systems, &(&1.id == system_id)) do
      %{faction: faction} -> faction == data.bot_faction
      _ -> false
    end
  end

  # Our own systems are legible in full, Intelligence included.
  defp system_ci(data, system_id), do: read_ci(data, system_id) || 0

  defp read_ci(data, system_id) do
    case call(data, :stellar_system, system_id, :get_state) do
      {:ok, %{counter_intelligence: %{value: ci}}} when is_number(ci) -> ci
      _ -> nil
    end
  end

  # Walking time along the shortest lane path, timed the way the engine times
  # each jump. nil when there is no path.
  defp travel_ut(data, ctx, from, to) do
    case Nav.path_hops(ctx.geo.adjacency, from, to) do
      hops when is_list(hops) -> Nav.travel_ut(hops, Nav.lane_weights(ctx.galaxy), movement_factor(data))
      _ -> nil
    end
  end

  defp movement_factor(data),
    do: Data.Querier.one(Data.Game.Constant, data.instance_id, :main).character_movement_factor

  # --- Erased: scouting ------------------------------------------------------------

  # Nothing to strike and nothing (left) to practise: scout the nearest system
  # the Rebellion has never seen, the way players send their first agents out
  # to find colony sites. A system seen once stays seen, so scouts fan out
  # instead of trading places, and with everything in reach seen the agent
  # waits. Only occasionally per idle pass, so the roster still reads as
  # lying in wait rather than milling about.
  defp plan_explore(data, ctx, view, character, entry, distances) do
    if roll(data) >= knob(data, "erased_roam_chance", 0.35) * 1.0 do
      nil
    else
      theatre = Map.get(entry, :theatre, :field)
      depth = trunc(knob(data, "erased_field_depth", 2))

      ctx.geo.systems
      |> Enum.filter(&(&1.faction != data.bot_faction and Geometry.theatre_of(ctx.geo, &1, depth) == theatre))
      |> Erased.explore_targets(
        &Wave.Recon.seen?(view, &1),
        trunc(knob(data, "erased_roam_max_hops", 6)),
        distances
      )
      |> admit(data, entry, character, &{:system, &1.id})
      |> Enum.min_by(&Erased.explore_priority(&1, Map.fetch!(distances, &1.id)), fn -> nil end)
      |> case do
        nil ->
          nil

        system ->
          %{
            action: "roam",
            target: system.id,
            target_key: {:system, system.id},
            move_only: true,
            overlap: overlap(data, character.id, {:system, system.id})
          }
      end
    end
  end

  # --- Erased: shared target plumbing -----------------------------------------

  # Hostiles in this agent's theatre that it can actually walk to. An
  # undercover Erased is invisible to the Rebellion and so is not a target at
  # all; a discovered one is fair game.
  defp reachable_hostiles(data, view, entry, character, distances) do
    theatre = Map.get(entry, :theatre, :field)
    transient_hops = trunc(knob(data, "erased_transient_hops", 1))

    Enum.filter(view.hostiles, fn hostile ->
      # Below visibility 2 the system's character list never reaches the
      # Rebellion at all, so there is nobody there to aim at. This is what
      # makes the field infiltrators load-bearing: they buy the sight the
      # removers and saboteurs work from — but only the sight they leave
      # behind travels, which is what `committable?` holds the line on.
      hostile.theatre == theatre and
        hostile.id != character.id and
        Map.has_key?(distances, hostile.system) and
        Wave.Recon.visibility(view, hostile.system) >= 2 and
        Erased.committable?(hostile, Map.fetch!(distances, hostile.system), transient_hops) and
        not (hostile.type == :spy and hostile.discovered? != true)
    end)
  end

  # One shared roll admits (or closes) the crowded targets, so the drop-off
  # reads as a decision by this agent rather than a lottery per candidate.
  defp admit(candidates, data, entry, character, key_fun) do
    commitments = Warlord.erased_commitments(data, character.id)

    cap =
      if Map.get(entry, :theatre) == :home,
        do: trunc(knob(data, "erased_home_target_cap", 7)),
        else: trunc(knob(data, "erased_target_cap", 5))

    Erased.admit(
      candidates,
      &Map.get(commitments, key_fun.(&1), 0),
      roll(data),
      knob(data, "erased_overlap_falloff", 0.35) * 1.0,
      cap
    )
  end

  defp overlap(data, character_id, key), do: Map.get(Warlord.erased_commitments(data, character_id), key, 0)

  defp duty_weights(data, :home), do: weights(data, "erased_home_weights", %{removal: 50, sabotage: 50})

  defp duty_weights(data, _field),
    do: weights(data, "erased_field_weights", %{infiltration: 40, removal: 30, sabotage: 30})

  defp weights(data, key, defaults) do
    stored = knob(data, key, %{})

    Map.new(defaults, fn {duty, default} ->
      {duty, number(Map.get(stored, Atom.to_string(duty), Map.get(stored, duty)), default)}
    end)
  end

  defp train_range(data) do
    case knob(data, "erased_train_points", [3, 6]) do
      [lo, hi] when is_number(lo) and is_number(hi) and hi >= lo -> [trunc(lo), trunc(hi)]
      _ -> [3, 6]
    end
  end

  defp number(value, _default) when is_number(value), do: value * 1.0
  defp number(_value, default), do: default * 1.0

  # --- Erased: scoring a finished strike ---------------------------------------

  # What the strike actually achieved, as far as the Rebellion can tell:
  # whether the victim is gone, how much of the fleet is left, how much more
  # of the system it can now see.
  defp resolve_strike(data, view, character, entry) do
    effect =
      case Map.get(entry, :action) do
        "assassination" -> %{removed: removed?(data, entry)}
        "sabotage" -> sabotage_effect(view, entry)
        _ -> infiltration_effect(view, entry)
      end

    {data, effect} = learn_intel(data, entry, effect)
    effect = Map.put(effect, :cover_after, character.spy.cover.value)
    {data, payload} = Warlord.resolve_erased(data, character.id, effect)
    if payload, do: log(data, "wave_erased_resolved", character.id, Map.get(entry, :target), payload)

    data
  end

  # Did the commander die? Most agents simply leave the board. A Navarch with a
  # fleet does not: `Player.assassinate_character` keeps the character id and
  # rebuilds it as a level-1 replacement officer so the ships stay crewed
  # (Instance.Character.Character.replace_agent_with_default/2). A changed name
  # under the same id is therefore a kill, not a miss.
  defp removed?(data, entry) do
    with target_id when is_integer(target_id) <- Map.get(entry, :target_character),
         before when is_binary(before) <- Map.get(entry, :target_name) do
      case call(data, :character, target_id, :get_state) do
        {:ok, %{status: status}} when status != :on_board -> true
        {:ok, %{name: name}} -> name != before
        :process_not_found -> true
        _ -> nil
      end
    else
      _ -> nil
    end
  end

  defp sabotage_effect(view, entry) do
    before = Map.get(entry, :target_tiles)

    case Enum.find(view.hostiles, &(&1.id == Map.get(entry, :target_character))) do
      nil -> %{tiles_before: before, tiles_after: nil}
      hostile -> %{tiles_before: before, tiles_after: hostile.tiles}
    end
  end

  defp infiltration_effect(view, entry) do
    %{
      visibility_before: Map.get(entry, :target_visibility),
      visibility_after: Wave.Recon.visibility(view, Map.get(entry, :target))
    }
  end

  # An infiltration's result report shows the attacker the defence it rolled
  # against: the system's Intelligence. Remember it, so practice can come back
  # to soft systems and stay away from hopeless ones. Only an infiltration seen
  # running has a report.
  defp learn_intel(data, entry, effect) do
    with action when action in ["infiltrate", nil] <- Map.get(entry, :action),
         started when started != nil <- Map.get(entry, :started_at),
         system_id when is_integer(system_id) <- Map.get(entry, :target),
         ci when is_number(ci) <- read_ci(data, system_id) do
      {Warlord.learn_intel(data, system_id, ci), Map.put(effect, :ci, ci)}
    else
      _ -> {data, effect}
    end
  end

  defp erased_record(data, character_id) do
    entry = Map.get(data.erased, character_id, %{})

    %{
      day: Warlord.match_day(data),
      theatre: Map.get(entry, :theatre),
      duty: Map.get(entry, :duty),
      stage: Map.get(entry, :stage),
      target: Map.get(entry, :target),
      target_character: Map.get(entry, :target_character),
      hired_ut_ago: Float.round((data.elapsed - Map.get(entry, :since, data.elapsed)) / 1, 1),
      time_ut: Map.get(entry, :time, %{})
    }
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
  # dropped every entry. `extra` carries an action's non-target data (the
  # Erased attacks name a victim).
  defp order(data, ctx, character, action_type, target_id, extra \\ %{}) do
    with hops when is_list(hops) <- Nav.path_hops(ctx.geo.adjacency, character.system, target_id),
         :ok <-
           call(
             data,
             :player,
             data.player_id,
             {:add_character_actions, character.id, Warlord.itinerary(hops, action_type, target_id, extra)}
           ),
         true <- accepted?(data, character.id) do
      :ok
    else
      nil -> {:error, :no_route}
      false -> {:error, :dropped_by_engine}
      other -> {:error, reason_of(other)}
    end
  end

  # Lane hops with nothing at the end of them — a reposition, not a strike.
  defp travel(data, ctx, character, target_id) do
    with hops when is_list(hops) and hops != [] <- Nav.path_hops(ctx.geo.adjacency, character.system, target_id),
         jumps =
           Enum.map(hops, fn {from, to} -> %{"type" => "jump", "data" => %{"source" => from, "target" => to}} end),
         :ok <- call(data, :player, data.player_id, {:add_character_actions, character.id, jumps}),
         true <- accepted?(data, character.id) do
      :ok
    else
      nil -> {:error, :no_route}
      [] -> {:error, :already_there}
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
end

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
  ships, warships its shipyard systems lay down without production, a
  solvency floor, and (via `Wave.Config`) lifted caps and bankruptcy immunity.

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

  Where a game switches fleets on, more Navarchs are hired for a role each
  (`Wave.Fleet`), given a design players fielded in it (`Wave.Blueprints`),
  built one ship at a time in a shipyard system and posted. They do not
  attack yet.
  """

  use Core.TickServer

  require Logger

  alias Instance.Character.{ActionQueue, Character, Speaker, Spy}
  alias Wave.{Blueprints, Doctrine, Erased, Fleet, Geometry, Nav, Research, Siderian, Warlord}

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

  # A fleet Navarch came out of a fight or finished an action (the engine's
  # `Wave.report_fleet/3`): score the identity it was built from. No tick: a
  # result must never make the Rebellion act.
  def on_cast({:fleet_result, character_id, kind, result}, state) do
    data = Warlord.upgrade(state.data)

    data =
      with outcome when outcome != nil <- Doctrine.outcome(result),
           {data, %{} = identity} <- Warlord.fleet_result(data, character_id, outcome) do
        log(data, "wave_fleet_result", character_id, nil, %{
          day: Warlord.match_day(data),
          kind: kind,
          result: result,
          outcome: outcome,
          design: identity.id,
          generation: identity.generation
        })

        Warlord.count(data, if(outcome == :win, do: :fleet_wins, else: :fleet_losses))
      else
        _ -> data
      end

    {:noreply, %{state | data: data}}
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

    engine_idle = for {id, character} <- summaries, roster_idle?(character), into: MapSet.new(), do: id

    data =
      data
      |> drop_departed(player, summaries)
      |> observe_siderians(summaries)
      |> observe_erased(summaries)
      |> Warlord.mark_stuck(engine_idle)

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
        (Warlord.siderian_hire_due?(data) and Warlord.hired_siderian_count(data) < Map.get(gauges, :siderian_cap, 1)) or
        (Warlord.erased_hire_due?(data) and Warlord.hired_erased_count(data) < Map.get(gauges, :erased_cap, 1))

    adrift_fleets = adrift_fleets(data, player, summaries)

    needs_geometry? =
      refresh? or idle_navarchs != [] or idle_siderians != [] or idle_erased != [] or adrift_fleets != [] or
        hire_pending?

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
        # Past `sector_open_contested_from_day` a neighbouring sector the humans
        # have a foothold in is worked whatever the pace says.
        contested = if Warlord.contested_open?(data), do: Geometry.contested_frontier(geo), else: MapSet.new()
        workable = Geometry.workable_sectors(geo, hold_margin, frontier_open?, pending, contested)

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
          |> Warlord.gauge(:contested_open, MapSet.size(contested))
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

        # The Siderian ceiling split between the trades; capture only takes
        # its share while there is something to capture.
        # Seduction waits for someone to seduce: until a human holds ground in
        # or next to the Rebellion's sectors, only a few seducers are kept.
        contact? = Geometry.contact?(geo, trunc(knob(data, "seduce_contact_depth", 1)))
        seduce_cap = if contact?, do: nil, else: trunc(knob(data, "seducers_before_contact", 1))

        quotas =
          Siderian.quotas(Warlord.agent_ceiling(data, :siderians), role_weights(data), length(captures), seduce_cap)

        sid_cap = quotas |> Map.values() |> Enum.sum()
        erased_cap = Warlord.agent_ceiling(data, :erased)

        data =
          data
          |> Warlord.gauge(:unclaimed_neighbouring, length(colonisation))
          |> Warlord.gauge(:coloniser_cap, nav_cap)
          |> Warlord.gauge(:capture_targets, length(captures))
          |> Warlord.gauge(:siderian_cap, sid_cap)
          |> Warlord.gauge(:siderian_quotas, quotas)
          |> Warlord.gauge(:human_contact, contact?)
          |> Warlord.gauge(:erased_cap, erased_cap)
          |> Warlord.gauge(:sectors_owned, MapSet.size(geo.owned))

        # Agents seduced from the humans join the rosters before anyone is steered.
        data = adopt_converts(data, ctx)

        # One hostile reading per recon interval, for the Erased and for the
        # Siderians whose trades weigh people and stability.
        {data, view} = maybe_recon(data, ctx, idle_erased != [] or Enum.any?(idle_siderians, &reads_people?(data, &1)))

        {data, ctx} = steer_navarchs(data, ctx, idle_navarchs, colonisation, nav_cap)
        {data, ctx} = steer_siderians(data, ctx, view, idle_siderians, captures)
        {data, ctx} = steer_erased(data, ctx, view, idle_erased)

        data
        |> steer_fleets(ctx, adrift_fleets)
        |> tend_convert_navarchs(ctx)
        |> maybe_hire_navarch(ctx, nav_cap)
        |> maybe_hire_siderian(ctx, quotas)
        |> maybe_hire_erased(ctx, erased_cap)
      else
        _ -> data
      end

    data
    |> tend_fleets(player, summaries)
    |> maybe_research(player)
    |> maybe_report_day(player)
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
        Enum.map(Map.keys(data.erased), &{&1, :erased}) ++
        Enum.map(Map.keys(Warlord.fleets(data)), &{&1, :fleet})

    Enum.reduce(tracked, data, fn {id, role}, acc ->
      cond do
        Map.has_key?(summaries, id) ->
          acc

        MapSet.member?(deck, id) ->
          dismiss(acc, id, role)

        role == :navarch ->
          Warlord.forget(acc, id)

        role == :fleet ->
          log(acc, "wave_fleet_lost", id, nil, fleet_record(acc, id))

          acc
          |> Warlord.count(:fleets_lost)
          |> Warlord.forget_fleet(id)

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
        data = Warlord.consume_hire(data)

        case employ_convert_navarch(data, ctx) do
          {:ok, data} -> data
          :none -> hire_navarch(data, ctx)
        end
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
  defp hire_agent(data, ctx, type, score \\ fn _character -> 1 end, deploy_at \\ nil) do
    ranks = Warlord.unlocked_ranks(data)

    with {:ok, _deployable} <- deployable_home(ctx.player),
         {:ok, market} <- step(:market, call(data, :character_market, :master, :get_state)),
         {:ok, candidate} <- step(:market, Warlord.pick_candidate(market_by_rank(market, type), ranks, score)),
         {:ok, player} <-
           step(:hire, player_reply(call(data, :player, data.player_id, {:hire_character, candidate.id}))),
         {:ok, home_id} <- deploy_system(player || ctx.player, deploy_at),
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

  # A fleet Navarch is deployed straight into its yard when the Rebellion runs
  # that system itself and it is not besieged; otherwise at home, like the rest.
  defp deploy_system(player, nil), do: home_system(player)

  defp deploy_system(player, system_id) do
    if Enum.any?(player.stellar_systems, &(&1.id == system_id and Map.get(&1, :siege) == nil)),
      do: {:ok, system_id},
      else: home_system(player)
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

          :fleet ->
            Warlord.forget_fleet(data, character_id)

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
  # Converts: agents the Siderians seduced away from the humans
  # ---------------------------------------------------------------------------

  # A seduced agent lands on the Rebellion's board with nobody tracking it. It
  # is put to work on top of the day's ceilings: an Erased under a rolled
  # posting, a Siderian in a rolled role, a Navarch in reserve at home until
  # colonisation wants one. Anything else on board and untracked is left
  # alone: the training Navarch, and nothing else should ever be there.
  defp adopt_converts(data, ctx) do
    known =
      MapSet.new(
        Map.keys(data.colonisers) ++
          Map.keys(data.siderians) ++
          Map.keys(data.erased) ++
          Map.keys(Warlord.fleets(data)) ++
          Map.keys(Warlord.convert_navarchs(data)) ++ [Warlord.training_dummy(data)]
      )

    ctx.player.characters
    |> Enum.filter(&(&1.status == :on_board and not MapSet.member?(known, &1.id)))
    |> Enum.reduce(data, fn summary, acc ->
      case call(acc, :player, acc.player_id, {:get_character_state, summary.id}) do
        %Character{} = character -> adopt_convert(acc, character)
        _ -> acc
      end
    end)
  end

  defp adopt_convert(data, %Character{type: :spy} = character) do
    posting = roll_posting(data, character.skills)
    log_convert(data, character, %{theatre: posting.theatre, duty: posting.duty})

    data
    |> Warlord.adopt_erased(character.id, posting)
    |> Warlord.count(:converts_adopted)
  end

  defp adopt_convert(data, %Character{type: :speaker} = character) do
    role = Siderian.role(roll(data), role_weights(data), character.skills)
    log_convert(data, character, %{role: role})

    data
    |> Warlord.adopt_siderian(character.id, role)
    |> Warlord.count(:converts_adopted)
  end

  defp adopt_convert(data, %Character{type: :admiral} = character) do
    log_convert(data, character, %{reserve: true})

    data
    |> Warlord.hold_convert_navarch(character.id)
    |> Warlord.count(:converts_adopted)
  end

  defp adopt_convert(data, _character), do: data

  defp log_convert(data, character, extra) do
    log(
      data,
      "wave_convert_adopted",
      character.id,
      character.system,
      Map.merge(extra, %{day: Warlord.match_day(data), type: character.type, level: character.level})
    )
  end

  # Reserve Navarchs walk home and wait there. One that has left the board is
  # forgotten.
  defp tend_convert_navarchs(data, ctx) do
    on_board = MapSet.new(ctx.player.characters, & &1.id)

    Enum.reduce(Map.keys(Warlord.convert_navarchs(data)), data, fn id, acc ->
      cond do
        not MapSet.member?(on_board, id) ->
          Warlord.release_convert_navarch(acc, id)

        true ->
          case call(acc, :player, acc.player_id, {:get_character_state, id}) do
            %Character{action_status: :idle, system: system} = character when is_integer(system) ->
              if rebel_held?(acc, ctx, system), do: acc, else: send_home(acc, ctx, character)

            _ ->
              acc
          end
      end
    end)
  end

  # Colonisation wants a Navarch: take an idle one from the reserve before
  # buying. It gets a colony ship like any hire and is tracked as a coloniser.
  defp employ_convert_navarch(data, _ctx) do
    idle =
      data
      |> Warlord.convert_navarchs()
      |> Map.keys()
      |> Enum.sort()
      |> Enum.find_value(fn id ->
        case call(data, :player, data.player_id, {:get_character_state, id}) do
          %Character{type: :admiral, action_status: :idle} = character -> character
          _ -> nil
        end
      end)

    with %Character{id: id} <- idle,
         {:ok, _} <- grant_colony_ship(data, id, knob(data, "colony_ship_tile", 1)) do
      Logger.info("[wave] instance #{data.instance_id}: rebellion put seduced Navarch #{id} to colonising")

      {:ok,
       data
       |> Warlord.release_convert_navarch(id)
       |> Warlord.count(:converts_employed)
       |> Warlord.order("employ:navarch", :ok)
       |> Warlord.track(id)}
    else
      nil ->
        :none

      {:error, stage, reason} ->
        {:ok, data |> Warlord.refuse(stage, reason) |> Warlord.order("employ:navarch", {:error, {stage, reason}})}
    end
  end

  # ---------------------------------------------------------------------------
  # Siderians: hiring
  # ---------------------------------------------------------------------------

  # Fill the roles toward their quotas, most short first (Wave.Siderian.quotas/3).
  # A role nobody on the market has a point in yields to the next; with nobody
  # for any of them, look again after `siderian_retry_ut`.
  defp maybe_hire_siderian(data, ctx, quotas) do
    order = Siderian.hire_order(Warlord.siderian_counts(data), quotas)

    if order != [] and Warlord.siderian_hire_due?(data) do
      hire_siderian(data, ctx, order, speaker_specializations(data), quotas)
    else
      data
    end
  end

  defp hire_siderian(data, _ctx, [], _specializations, _quotas) do
    data
    |> Warlord.refuse(:market, :no_candidate)
    |> Warlord.order("hire:siderian", {:error, {:market, :no_candidate}})
    |> Warlord.defer_siderian_hire()
  end

  defp hire_siderian(data, ctx, [role | rest], specializations, quotas) do
    strength = fn character -> Siderian.strength(Map.get(character, :skills), specializations, role) end

    case hire_agent(data, ctx, :speaker, strength) do
      {:ok, candidate, home_id} ->
        Logger.info(
          "[wave] instance #{data.instance_id}: rebellion deployed Siderian #{candidate.id} (#{role}) at system #{home_id}"
        )

        log(data, "wave_siderian_hired", candidate.id, home_id, %{
          day: Warlord.match_day(data),
          role: role,
          strength: strength.(candidate),
          level: Map.get(candidate, :level),
          specialization: Map.get(candidate, :specialization),
          skills: Siderian.skill_points(Map.get(candidate, :skills)),
          roster: Warlord.hired_siderian_count(data) + 1,
          quotas: quotas
        })

        data
        |> Warlord.count(:siderians_hired)
        |> Warlord.order("hire:siderian", :ok)
        |> Warlord.track_siderian(candidate.id, role)

      # Nobody on the market has a point in this role: try the next one.
      {:error, :market, :no_candidate} ->
        hire_siderian(data, ctx, rest, specializations, quotas)

      # Nowhere to deploy, or the market could not be read: look again later.
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
  end

  defp role_weights(data) do
    stored = knob(data, "siderian_role_weights", %{})

    Map.new(%{capture: 40, destab: 30, seduce: 30}, fn {role, default} ->
      {role, number(Map.get(stored, Atom.to_string(role), Map.get(stored, role)), default)}
    end)
  end

  # The speaker skill table, for Wave.Siderian.strength/3. Read at most once
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

  # ---------------------------------------------------------------------------
  # Siderians: steering
  # ---------------------------------------------------------------------------

  defp steer_siderians(data, ctx, _view, [], _captures), do: {Warlord.gauge(data, :siderians_without_target, 0), ctx}

  defp steer_siderians(data, ctx, view, ids, captures) do
    specializations = speaker_specializations(data)

    {data, ctx, without_target} =
      Enum.reduce(ids, {data, ctx, 0}, fn id, {d, c, nt} ->
        case call(d, :player, d.player_id, {:get_character_state, id}) do
          %Character{type: :speaker} = character ->
            steer_siderian(d, c, view, character, captures, specializations, nt)

          _ ->
            {d, c, nt}
        end
      end)

    {Warlord.gauge(data, :siderians_without_target, without_target), ctx}
  end

  defp steer_siderian(data, ctx, view, character, captures, specializations, without_target) do
    locked? = Speaker.locked?(character.speaker)

    data =
      observe(data, character.id, Warlord.siderian_bucket(character.action_status, locked?), character.action_status)

    entry = Map.get(data.siderians, character.id)
    role = Warlord.siderian_role(entry)
    idle? = character.action_status == :idle and ActionQueue.empty?(character.actions)

    cond do
      not idle? ->
        {data, ctx, without_target}

      true ->
        data = settle_siderian(data, ctx, character, entry, locked?)

        cond do
          # No point in its trade means every roll fails, and the in-game
          # action is greyed out anyway: free the slot for a capable hire.
          Siderian.strength(character.skills, specializations, role) <= 0 ->
            {recall_and_dismiss(data, ctx, character, :siderians_released, :siderian), ctx, without_target}

          # Resting on its cooldown: keep moving outside rebel-held space.
          locked? ->
            evade_or_rest(data, ctx, character, Map.get(data.siderians, character.id, entry), without_target)

          role == :destab ->
            dispatch_agitator(data, ctx, view, character, without_target)

          role == :seduce ->
            dispatch_seducer(data, ctx, view, character, without_target)

          true ->
            dispatch_siderian(data, ctx, character, captures, without_target)
        end
    end
  end

  # Whatever the Siderian was last sent to do has run its course: score it, or
  # just free it when it was only moving.
  defp settle_siderian(data, ctx, character, entry, locked?) do
    case Map.get(entry, :stage) do
      :dispatched ->
        case Map.get(entry, :action) do
          "encourage_hate" -> resolve_destab(data, character, entry)
          "conversion" -> resolve_seduction(data, character, entry, locked?)
          _ -> resolve_capture(data, ctx, character.id, entry.target)
        end

      stage when stage in [:evading, :scouting] ->
        Warlord.siderian_released(data, character.id)

      _ ->
        data
    end
  end

  # A Siderian cannot hide. On its cooldown outside rebel-held sectors it keeps
  # moving, one lane at a time to a random neighbour, because nothing
  # intercepts a Siderian in transit; in the backline it simply rests.
  defp evade_or_rest(data, ctx, %Character{system: nil}, _entry, without_target), do: {data, ctx, without_target}

  defp evade_or_rest(data, ctx, character, entry, without_target) do
    backline? = MapSet.member?(ctx.geo.owned, Map.get(ctx.sector_of, character.system))

    hop =
      if knob(data, "siderian_evade", true) == true and Siderian.evade?(true, backline?),
        do:
          Siderian.evasion_hop(Map.get(ctx.geo.adjacency, character.system, []), Map.get(entry, :came_from), roll(data))

    case hop && travel(data, ctx, character, hop) do
      nil ->
        {data, ctx, without_target}

      :ok ->
        {data |> Warlord.siderian_evading(character.id, hop, character.system) |> Warlord.order("order:evade", :ok),
         ctx, without_target}

      {:error, reason} = error ->
        {data |> Warlord.refuse(:evade, reason) |> Warlord.order("order:evade", error), ctx, without_target}
    end
  end

  # --- agitators ------------------------------------------------------------------

  # In order: the mass-destabilization focus, the capture target a capture
  # Siderian is heading for, practice, then scouting. An agitator with no duty
  # trains rather than stand idle, whatever its level.
  defp dispatch_agitator(data, ctx, _view, %Character{system: nil}, without_target), do: {data, ctx, without_target + 1}

  defp dispatch_agitator(data, ctx, view, character, without_target) do
    reach = max(knob(data, "destab_max_travel_ut", 480.0), knob(data, "siderian_train_max_travel_ut", 480.0))
    times = travel_times(data, ctx, character.system, reach)

    plan =
      plan_mass_destab(data, ctx, view, character, times) ||
        plan_soften_capture(data, character, times) ||
        plan_destab_practice(data, ctx, character, times) ||
        plan_siderian_scout(data, ctx, view, character)

    commit_siderian(data, ctx, character, plan, without_target)
  end

  # Enemy systems and dominions within a day's travel, converging on one at a
  # time: the one agitators already work comes first, and each takes up to
  # `destab_focus_cap` until the Rebellion's estimate of its happiness reaches
  # `destab_floor`; after that one agitator keeps it there.
  defp plan_mass_destab(data, ctx, view, character, times) do
    reach = knob(data, "destab_max_travel_ut", 480.0)
    {cap, floor, margin, decay} = destab_limits(data)
    commitments = Warlord.role_commitments(data, :destab, character.id)
    now = data.elapsed

    ctx.geo.systems
    |> Enum.filter(fn system ->
      system.faction not in [nil, data.bot_faction] and
        system.status in [:inhabited_player, :inhabited_dominion] and
        within?(times, system.id, reach)
    end)
    |> Enum.map(fn system ->
      reading = Warlord.siderian_reading(data, system.id)
      committed = Map.get(commitments, {:system, system.id}, 0)

      %{
        id: system.id,
        committed: committed,
        need: Siderian.destab_need(reading, now, decay, floor, margin, cap),
        working_sector?: Geometry.class_of(ctx.geo, system) in [:frontier, :border],
        population: if(view && Wave.Recon.visibility(view, system.id) >= 3, do: Map.get(system, :population)),
        estimate: Siderian.estimate(reading, now, decay),
        travel: Map.fetch!(times, system.id)
      }
    end)
    |> Enum.filter(&(&1.committed < &1.need))
    |> Enum.min_by(&Siderian.destab_priority/1, fn -> nil end)
    |> case do
      nil ->
        nil

      target ->
        destab_plan(target.id, false, %{
          purpose: :mass,
          travel: target.travel,
          estimate: target.estimate,
          overlap: target.committed
        })
    end
  end

  # No enemy in reach: soften the neutral a capture Siderian is heading for,
  # one agitator each, while it still looks happier than `capture_soften_above`.
  defp plan_soften_capture(data, character, times) do
    reach = knob(data, "destab_max_travel_ut", 480.0)
    above = knob(data, "capture_soften_above", 10) * 1.0
    {_cap, _floor, _margin, decay} = destab_limits(data)
    commitments = Warlord.role_commitments(data, :destab, character.id)

    data.siderians
    |> Enum.filter(fn {_id, entry} -> Warlord.siderian_role(entry) == :capture and entry.stage == :dispatched end)
    |> Enum.map(fn {_id, entry} -> entry.target end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.filter(fn target ->
      estimate = Siderian.estimate(Warlord.siderian_reading(data, target), data.elapsed, decay)

      within?(times, target, reach) and Map.get(commitments, {:system, target}, 0) == 0 and
        (estimate == nil or estimate > above)
    end)
    |> Enum.min_by(&{Map.fetch!(times, &1), &1}, fn -> nil end)
    |> case do
      nil -> nil
      target -> destab_plan(target, false, %{purpose: :soften, travel: Map.fetch!(times, target)})
    end
  end

  # Practise on the shared neutral ground: every penalty makes the next roll
  # easier, so agitators cluster. The ground is a neutral in one of the
  # Rebellion's border sectors when one is in reach, and holds while it is
  # still neutral and no better-placed ground has come into reach (the front
  # moves on, and the cluster follows it); an agitator out of its reach
  # practises on its own nearest pick without moving everyone else. Any level
  # practises unless `siderian_train_max_level` sets a cap.
  defp plan_destab_practice(data, ctx, character, times) do
    if Siderian.strength(character.skills, speaker_specializations(data), :destab) > 0 and
         below_cap?(character.level, knob(data, "siderian_train_max_level", nil)) do
      reach = knob(data, "siderian_train_max_travel_ut", 480.0)
      ground = Enum.find(ctx.geo.systems, &(&1.id == Warlord.destab_ground(data) and &1.status == :inhabited_neutral))
      pick = pick_ground(data, ctx, times, reach)
      rank = fn system -> Siderian.sector_rank(Geometry.class_of(ctx.geo, system)) end

      cond do
        ground != nil and within?(times, ground.id, reach) and (pick == nil or rank.(ground) <= rank.(pick)) ->
          destab_plan(ground.id, true, %{purpose: :practice, travel: Map.fetch!(times, ground.id)})

        pick == nil ->
          nil

        true ->
          # The pick replaces the shared ground when there is none any more,
          # or when the old one is in reach and the pick is better placed.
          shared? = ground == nil or within?(times, ground.id, reach)
          destab_plan(pick.id, true, %{purpose: :practice, travel: Map.fetch!(times, pick.id), ground: shared?})
      end
    end
  end

  defp below_cap?(level, cap) when is_number(cap), do: level < cap
  defp below_cap?(_level, _cap), do: true

  # The best practice ground in reach, as its system (see Siderian.ground_priority/1).
  defp pick_ground(data, ctx, times, reach) do
    {_cap, _floor, _margin, decay} = destab_limits(data)
    wanted = ctx.geo |> Geometry.capture_candidates() |> MapSet.new(& &1.id)

    ctx.geo.systems
    |> Enum.filter(&(&1.status == :inhabited_neutral and &1.faction == nil and within?(times, &1.id, reach)))
    |> Enum.min_by(
      fn system ->
        Siderian.ground_priority(%{
          id: system.id,
          sector_class: Geometry.class_of(ctx.geo, system),
          capture_candidate?: MapSet.member?(wanted, system.id),
          estimate: Siderian.estimate(Warlord.siderian_reading(data, system.id), data.elapsed, decay),
          travel: Map.fetch!(times, system.id)
        })
      end,
      fn -> nil end
    )
  end

  defp destab_plan(target, training?, info) do
    Map.merge(info, %{
      action: "encourage_hate",
      target: target,
      target_key: {:system, target},
      training: training?
    })
  end

  defp destab_limits(data) do
    decay = Data.Querier.one(Data.Game.Constant, data.instance_id, :main).happiness_penalty_reduction_factor

    {trunc(knob(data, "destab_focus_cap", 5)), knob(data, "destab_floor", -30) * 1.0,
     knob(data, "destab_rehit_margin", 10) * 1.0, decay}
  end

  # The report shows the attacker the defence it rolled against,
  # `max(happiness, 0)`, and the penalty it applied; the penalty is also the
  # cooldown the Siderian came back with. Fold both into the system's reading.
  defp resolve_destab(data, character, entry) do
    target = entry.target
    ran? = Map.get(entry, :started_at) != nil
    penalty = if ran?, do: Siderian.penalty_from_cooldown(character.speaker.cooldown.initial)

    {data, effect} =
      with true <- is_number(penalty),
           happiness when is_number(happiness) <- read_happiness(data, target) do
        {_cap, floor, _margin, decay} = destab_limits(data)
        defence = max(happiness + penalty, 0)
        data = Warlord.record_destab(data, target, defence, penalty, decay, floor)
        estimate = Siderian.estimate(Warlord.siderian_reading(data, target), data.elapsed, decay)
        {data, %{penalty: penalty, defence: defence, estimate: estimate && Float.round(estimate, 1)}}
      else
        _ -> {data, %{penalty: penalty}}
      end

    {data, payload} = Warlord.resolve_siderian_action(data, character.id, effect)
    if payload, do: log(data, "wave_siderian_resolved", character.id, target, payload)
    data
  end

  defp read_happiness(data, system_id) do
    case call(data, :stellar_system, system_id, :get_state) do
      {:ok, %{happiness: %{value: value}}} when is_number(value) -> value
      _ -> nil
    end
  end

  # --- seducers -------------------------------------------------------------------

  # A seducer works like an Erased remover, weighing stability instead of
  # Intelligence. With no one to seduce it practises destabilization if it has
  # the points for it, else scouts.
  defp dispatch_seducer(data, ctx, _view, %Character{system: nil}, without_target), do: {data, ctx, without_target + 1}

  # Without a fresh hostile reading a seducer waits for the next one rather
  # than wander off to practise.
  defp dispatch_seducer(data, ctx, nil, _character, without_target), do: {data, ctx, without_target}

  defp dispatch_seducer(data, ctx, view, character, without_target) do
    {distances, ctx} = distances(ctx, character.system)

    plan =
      (view && plan_seduction(data, ctx, view, character, distances)) ||
        plan_destab_practice(
          data,
          ctx,
          character,
          travel_times(data, ctx, character.system, knob(data, "siderian_train_max_travel_ut", 480.0))
        ) ||
        plan_siderian_scout(data, ctx, view, character)

    commit_siderian(data, ctx, character, plan, without_target)
  end

  defp plan_seduction(data, _ctx, view, character, distances) do
    attack = character.speaker.conversion_coef.value
    gate = knob(data, "seduce_gate", %{})
    transient_hops = trunc(knob(data, "erased_transient_hops", 1))
    {_cap, _floor, _margin, decay} = destab_limits(data)

    # Removers and seducers share the targets they would both kill.
    committed =
      Map.merge(Warlord.erased_commitments(data), Warlord.role_commitments(data, :seduce, character.id), fn _k, a, b ->
        a + b
      end)

    view.hostiles
    |> Enum.filter(fn hostile ->
      hostile.theatre in [:home, :field] and
        Map.has_key?(distances, hostile.system) and
        Wave.Recon.visibility(view, hostile.system) >= 2 and
        Erased.committable?(hostile, Map.fetch!(distances, hostile.system), transient_hops) and
        Siderian.seducible?(hostile)
    end)
    |> Erased.admit(
      &Map.get(committed, {:character, &1.id}, 0),
      roll(data),
      knob(data, "erased_overlap_falloff", 0.35) * 1.0,
      trunc(knob(data, "erased_target_cap", 5))
    )
    |> Enum.map(fn hostile ->
      chance = seduction_chance(data, attack, character.level, hostile, decay)
      {Erased.removal_priority(hostile, chance, Map.fetch!(distances, hostile.system)), hostile, chance}
    end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.take(3)
    |> Enum.find_value(fn {_priority, hostile, chance} ->
      if roll(data) < Wave.Intel.attempt_chance(chance, gate) do
        %{
          action: "conversion",
          target: hostile.system,
          target_character: hostile.id,
          target_key: {:character, hostile.id},
          target_name: hostile.name,
          governor: hostile.governor?,
          odds: chance && Float.round(chance, 3),
          odds_class: Wave.Intel.odds_class(chance),
          hops: Map.fetch!(distances, hostile.system),
          overlap: Map.get(committed, {:character, hostile.id}, 0)
        }
      end
    end)
  end

  # Determination is legible at visibility 4; the home system's happiness at 3,
  # or else from the Rebellion's own destabilization reading of that system.
  defp seduction_chance(data, attack, level, hostile, decay) do
    happiness =
      hostile.home_happiness ||
        Siderian.estimate(Warlord.siderian_reading(data, hostile.system), data.elapsed, decay)

    case Siderian.seduction_defence(hostile.determination, hostile.in_own_system?, happiness) do
      nil -> nil
      defence -> Wave.Intel.success_chance(attack, level, defence)
    end
  end

  # Conversion resolves the moment it starts: the cooldown shows it ran, and
  # the victim gone from its owner (dead, or rebuilt as a stand-in under the
  # same id) shows it worked.
  defp resolve_seduction(data, character, entry, locked?) do
    converted = removed?(data, entry)
    effect = %{converted: converted == true, cooldown_started: locked?, governor: Map.get(entry, :governor)}
    {data, payload} = Warlord.resolve_siderian_action(data, character.id, effect)
    if payload, do: log(data, "wave_siderian_resolved", character.id, Map.get(entry, :target), payload)
    data
  end

  # --- shared ------------------------------------------------------------------------

  # Nothing to do: walk to the nearest system the Rebellion has never seen, as
  # the Erased do, within the field theatre.
  defp plan_siderian_scout(_data, _ctx, nil, _character), do: nil

  defp plan_siderian_scout(data, ctx, view, character) do
    if roll(data) < knob(data, "erased_roam_chance", 0.35) * 1.0 do
      depth = trunc(knob(data, "erased_field_depth", 2))
      {distances, _ctx} = distances(ctx, character.system)

      ctx.geo.systems
      |> Enum.filter(&(&1.faction != data.bot_faction and Geometry.theatre_of(ctx.geo, &1, depth) in [:home, :field]))
      |> Erased.explore_targets(&Wave.Recon.seen?(view, &1), trunc(knob(data, "erased_roam_max_hops", 6)), distances)
      |> Enum.min_by(&Erased.explore_priority(&1, Map.fetch!(distances, &1.id)), fn -> nil end)
      |> case do
        nil -> nil
        system -> %{action: "scout", target: system.id, move_only: true}
      end
    end
  end

  defp commit_siderian(data, ctx, _character, nil, without_target), do: {data, ctx, without_target + 1}

  defp commit_siderian(data, ctx, character, plan, without_target) do
    %{action: action, target: target} = plan
    move_only? = Map.get(plan, :move_only, false)
    training? = Map.get(plan, :training, false)
    extra = if plan[:target_character], do: %{"target_character" => plan.target_character}, else: %{}

    result =
      if move_only?,
        do: travel(data, ctx, character, target),
        else: order(data, ctx, character, action, target, extra)

    kind =
      cond do
        move_only? -> "order:siderian_scout"
        training? -> "practice:#{action}"
        true -> "order:#{action}"
      end

    data = Warlord.order(data, kind, result)
    role = data.siderians |> Map.get(character.id, %{}) |> Warlord.siderian_role()

    data =
      case result do
        :ok ->
          info =
            plan
            |> Map.drop([:move_only, :ground])
            |> Map.merge(%{role: role, from: character.system})

          log(data, "wave_siderian_dispatched", character.id, target, loggable(info, data))

          cond do
            move_only? ->
              data |> Warlord.siderian_scouting(character.id, target) |> Warlord.count(:siderian_scouts)

            true ->
              data
              |> Warlord.siderian_dispatched(character.id, target, info)
              |> Warlord.count(siderian_counter(action, training?))
              |> then(&if(Map.get(plan, :ground), do: Warlord.set_destab_ground(&1, target), else: &1))
          end

        {:error, reason} ->
          Warlord.refuse(data, siderian_refusal_key(action), reason)
      end

    {data, ctx, without_target}
  end

  defp siderian_counter("encourage_hate", true), do: :destab_practice
  defp siderian_counter("encourage_hate", false), do: :destabs_attempted
  defp siderian_counter("conversion", _training?), do: :seductions_attempted
  defp siderian_counter(_action, _training?), do: :captures_attempted

  # Literal atoms: refusals live in snapshotted state (see Warlord.erased_refusal_key/1).
  defp siderian_refusal_key("encourage_hate"), do: :destab
  defp siderian_refusal_key("conversion"), do: :seduce
  defp siderian_refusal_key(_action), do: :siderian_scout

  defp travel_times(data, ctx, from, max_ut) do
    Nav.travel_times(ctx.geo.adjacency, Nav.lane_weights(ctx.galaxy), from, movement_factor(data), max_ut * 1.0)
  end

  defp within?(times, system_id, reach) do
    case Map.get(times, system_id) do
      ut when is_number(ut) -> ut <= reach
      _ -> false
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
    if Warlord.hired_erased_count(data) < cap and Warlord.erased_hire_due?(data) do
      specializations = spy_specializations(data)

      # While a forward posting stands open, informer points count twice.
      informer_bonus = if forward_vacancy?(data), do: 1, else: 0

      score = fn character ->
        skills = Map.get(character, :skills)

        Erased.offensive_strength(skills, specializations) +
          informer_bonus * Erased.strength(skills, specializations, :spy_infiltrate)
      end

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

  defp steer_erased(data, ctx, _view, []), do: {Warlord.gauge(data, :erased_without_target, 0), ctx}

  # No fresh reading this pass: idle Erased simply wait for the next one.
  defp steer_erased(data, ctx, nil, _ids), do: {data, ctx}

  defp steer_erased(data, ctx, view, ids) do
    specializations = spy_specializations(data)

    characters =
      ids
      |> Enum.map(&call(data, :player, data.player_id, {:get_character_state, &1}))
      |> Enum.filter(&match?(%Character{type: :spy}, &1))

    # The training Navarch is read, deployed or moved once, before anyone
    # decides whether to practise on it.
    {data, ctx} = prepare_dummy(data, ctx, characters)

    # Finished orders are closed out for everyone before anyone is re-posted
    # or sent again, so a strike is scored under the posting it was ordered on.
    data = Enum.reduce(characters, data, &settle_erased(&2, view, &1))
    data = post_forward(data, characters, specializations)

    {data, ctx, without_target} =
      Enum.reduce(characters, {data, ctx, 0}, fn character, {d, c, nt} ->
        steer_one_erased(d, c, view, character, specializations, nt)
      end)

    {Warlord.gauge(data, :erased_without_target, without_target), ctx}
  end

  # Forward postings (Wave.Erased, "Forward postings"): idle field informers
  # fill the scout and deep-infiltration quotas, the strongest first.
  defp post_forward(data, characters, specializations) do
    quotas = forward_quotas(data)
    data = Warlord.gauge(data, :erased_forward_quotas, quotas)
    min_points = trunc(knob(data, "erased_forward_min_points", 1))

    characters
    |> Enum.filter(fn character ->
      erased_idle?(character) and Map.get(Map.get(data.erased, character.id, %{}), :theatre) == :field and
        Erased.fit_for_forward?(character.skills, min_points)
    end)
    |> Enum.sort_by(fn character ->
      Erased.forward_rank(
        Erased.strength(character.skills, specializations, :spy_infiltrate),
        Map.get(Map.get(data.erased, character.id, %{}), :duty),
        character.id
      )
    end)
    |> Enum.zip(Erased.forward_vacancies(quotas, Erased.forward_held(data.erased)))
    |> Enum.reduce(data, fn {character, duty}, acc ->
      entry = Map.get(acc.erased, character.id, %{})

      log(acc, "wave_erased_posted", character.id, character.system, %{
        day: Warlord.match_day(acc),
        theatre: :forward,
        duty: duty,
        from_duty: Map.get(entry, :duty),
        skills: Erased.skill_points(character.skills),
        level: character.level,
        quotas: quotas
      })

      acc
      |> Warlord.count(:erased_posted)
      |> Warlord.repost_erased(character.id, :forward, duty)
    end)
  end

  defp forward_quotas(data) do
    room = trunc(map_size(data.erased) * knob(data, "erased_forward_max_share", 0.3))

    Erased.forward_quotas(
      Warlord.scale_players(data),
      knob(data, "erased_scouts_per_player", 0.35) * 1.0,
      knob(data, "erased_deep_per_player", 0.2) * 1.0,
      room
    )
  end

  defp forward_vacancy?(data),
    do: Erased.forward_vacancies(forward_quotas(data), Erased.forward_held(data.erased)) != []

  defp erased_idle?(character), do: character.action_status == :idle and ActionQueue.empty?(character.actions)

  # A hostile reading costs a faction read, one call per human player and a
  # capped sweep of the systems their agents stand in. Held for a few ut so a
  # fast tick cadence doesn't re-read the galaxy's people every pass.
  defp maybe_recon(data, ctx, wanted?) do
    interval = knob(data, "erased_recon_interval_ut", 3.0) * 1.0

    if wanted? and Warlord.recon_due?(data, interval) do
      view = build_recon(data, ctx)

      data =
        Enum.reduce(view.gauges, Warlord.mark_recon(data), fn {key, value}, acc -> Warlord.gauge(acc, key, value) end)

      {data, view}
    else
      {data, nil}
    end
  end

  defp reads_people?(data, id) do
    case Map.get(data.siderians, id) do
      nil -> false
      entry -> Warlord.siderian_role(entry) in [:destab, :seduce]
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

  # Observe an Erased and, when it stands idle, close out the order it was on.
  defp settle_erased(data, view, character) do
    discovered? = Spy.discovered?(character.spy.cover.value, data.instance_id)
    data = observe_spy(data, character.id, Erased.bucket(character.action_status, discovered?), character.action_status)
    entry = Map.get(data.erased, character.id, %{})

    if erased_idle?(character) do
      case Map.get(entry, :stage) do
        # A strike we ordered has run its course one way or the other: score it.
        :dispatched -> resolve_strike(data, view, character, entry)
        # A roamer has arrived: nothing to score, just free its slot.
        :roaming -> Warlord.erased_released(data, character.id)
        _ -> data
      end
    else
      data
    end
  end

  defp steer_one_erased(data, ctx, view, character, specializations, without_target) do
    discovered? = Spy.discovered?(character.spy.cover.value, data.instance_id)

    cond do
      not erased_idle?(character) ->
        {data, ctx, without_target}

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
        duty when duty in [:scout, :deep] -> plan_forward(data, ctx, view, character, entry, distances)
        _ -> plan_infiltration(data, ctx, view, character, entry, distances)
      end

    # Nothing worth striking. While still green an Erased practises; trained,
    # or with nothing to practise on, it scouts ground the Rebellion has never
    # seen; with all of that seen it practises again, whatever its level,
    # rather than stand idle.
    plan = plan || plan_practice(data, ctx, character, entry, distances)

    plan =
      plan ||
        case unseen_ground(data, ctx, view, entry, distances) do
          [] -> plan_practice(data, ctx, character, entry, distances, true)
          unseen -> plan_explore(data, character, entry, distances, unseen)
        end

    case plan do
      nil ->
        {data, ctx, without_target + 1}

      # The training Navarch is still walking to its post.
      :hold ->
        {data, ctx, without_target}

      plan ->
        if short_of_cover?(data, character, plan),
          do: {data, ctx, without_target},
          else: commit_plan(data, ctx, view, character, entry, distances, plan, without_target)
    end
  end

  # An infiltration costs cover even when it works, and one ordered the moment
  # the agent is back above the threshold drops it straight below again: shown
  # to the owner after every attempt, its skills at zero, unable to leave. So
  # it waits where it stands, unseen, until a success would leave it hidden.
  # Cover only recovers while an agent is idle, so this is the same rest taken
  # before the attempt instead of after it. Removal and sabotage cost more
  # than any cover absorbs and are not held.
  defp short_of_cover?(data, character, %{action: "infiltrate"}) do
    threshold = Data.Querier.one(Data.Game.Constant, data.instance_id, :main).cover_threshold
    margin = knob(data, "erased_infiltrate_cover_margin", 12) * 1.0

    not Erased.covered_for_infiltration?(character.spy.cover.value, threshold, margin)
  end

  defp short_of_cover?(_data, _character, _plan), do: false

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
      # The skill it goes in with. By the time a failure is scored the agent
      # is discovered and reads zero.
      |> then(&if(action == "infiltrate", do: Map.put(&1, :attack, character.spy.infiltrate_coef.value), else: &1))

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
    gate = infiltration_gate(data)
    attack = character.spy.infiltrate_coef.value

    ctx.geo.systems
    |> Enum.filter(fn system ->
      system.faction != data.bot_faction and
        Map.has_key?(distances, system.id) and
        Geometry.theatre_of(ctx.geo, system, depth) == theatre and
        system.status in [:inhabited_neutral, :inhabited_dominion, :inhabited_player] and
        Erased.worth_infiltrating?(Wave.Recon.visibility(view, system.id)) and
        workable?(data, gate, system.id, infiltration_chance(data, attack, character.level, system.id))
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

  # Forward infiltration works the ground the humans hold wherever it lies,
  # however long the walk: a scout from the edge nearest rebel space inwards, a
  # deep infiltrator from the far end outwards. Like field infiltration it
  # skips what the Rebellion already sees whole and what it has learned is out
  # of this agent's reach.
  defp plan_forward(data, ctx, view, character, entry, distances) do
    gate = infiltration_gate(data)
    attack = character.spy.infiltrate_coef.value
    duty = Map.get(entry, :duty)

    candidates =
      ctx.geo.systems
      |> Enum.filter(fn system ->
        Erased.forward_ground?(system, data.bot_faction) and
          Map.has_key?(distances, system.id) and
          Erased.worth_infiltrating?(Wave.Recon.visibility(view, system.id))
      end)
      |> Enum.map(&{&1, infiltration_chance(data, attack, character.level, &1.id)})
      |> Enum.filter(fn {system, chance} -> workable?(data, gate, system.id, chance) end)

    chances = Map.new(candidates, fn {system, chance} -> {system.id, chance} end)

    candidates
    |> Enum.map(&elem(&1, 0))
    |> admit(data, entry, character, &{:system, &1.id})
    |> Enum.min_by(
      &Erased.forward_priority(duty, &1, Geometry.depth_of(ctx.geo, &1), chances[&1.id], Map.fetch!(distances, &1.id)),
      fn -> nil end
    )
    |> case do
      nil ->
        nil

      system ->
        chance = chances[system.id]

        %{
          action: "infiltrate",
          target: system.id,
          target_key: {:system, system.id},
          odds: chance && Float.round(chance, 3),
          odds_class: Wave.Intel.odds_class(chance),
          overlap: overlap(data, character.id, {:system, system.id})
        }
    end
  end

  # A forward agent has no ground of its own to practise or scout on: with
  # nothing left to infiltrate it uses whatever lies outside rebel space.
  defp in_theatre?(ctx, system, depth, :forward), do: Geometry.theatre_of(ctx.geo, system, depth) != :home
  defp in_theatre?(ctx, system, depth, theatre), do: Geometry.theatre_of(ctx.geo, system, depth) == theatre

  # --- Erased: practice --------------------------------------------------------

  # Idle and still below the level cap: practise. Infiltration is the better
  # teacher, so any informer point settles it; an agent with sabotage points
  # and none in infiltration works the training Navarch instead while it is
  # close enough. Returns a plan, :hold (the training Navarch is on its way to
  # its post) or nil.
  defp plan_practice(data, ctx, character, entry, distances, any_level? \\ false) do
    dummy? = knob(data, "erased_dummy", true) == true

    cond do
      not any_level? and not Erased.trains?(character.level, knob(data, "erased_train_max_level", 5)) ->
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
    gate = infiltration_gate(data)
    attack = character.spy.infiltrate_coef.value

    candidates =
      ctx.geo.systems
      |> Enum.filter(fn system ->
        system.faction != data.bot_faction and
          system.status in [:inhabited_neutral, :inhabited_dominion] and
          Map.has_key?(distances, system.id) and
          in_theatre?(ctx, system, depth, theatre)
      end)
      |> Enum.map(&{&1, infiltration_chance(data, attack, character.level, &1.id)})
      |> Enum.filter(fn {system, chance} -> workable?(data, gate, system.id, chance) end)

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

  # The odds rules every infiltration plan shares, read once per plan.
  defp infiltration_gate(data) do
    %{
      min_chance: knob(data, "erased_train_min_chance", 0.25) * 1.0,
      cooloff_chance: knob(data, "erased_fail_cooloff_chance", 0.75) * 1.0,
      cooloff_ut: knob(data, "erased_fail_cooloff_ut", 480.0) * 1.0
    }
  end

  # A target is worth this agent's attempt unless its learned Intelligence
  # puts it out of reach, or it beat one of ours lately and this agent's odds
  # there are no better than modest (Wave.Erased, "Staying hidden").
  defp workable?(data, gate, system_id, chance) do
    Erased.practice_odds(chance, gate.min_chance) != :hopeless and
      not Erased.cooling_off?(chance, Warlord.failed_ago(data, system_id), gate.cooloff_chance, gate.cooloff_ut)
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

  # Systems in the agent's theatre and within its roaming range that the
  # Rebellion has never seen. A system seen once stays seen, so scouts fan out
  # instead of trading places.
  defp unseen_ground(data, ctx, view, entry, distances) do
    theatre = Map.get(entry, :theatre, :field)
    depth = trunc(knob(data, "erased_field_depth", 2))

    ctx.geo.systems
    |> Enum.filter(&(&1.faction != data.bot_faction and in_theatre?(ctx, &1, depth, theatre)))
    |> Erased.explore_targets(&Wave.Recon.seen?(view, &1), trunc(knob(data, "erased_roam_max_hops", 6)), distances)
  end

  # Nothing to strike and nothing (left) to practise: scout the nearest of the
  # `unseen` systems, the way players send their first agents out to find
  # colony sites. Only occasionally per idle pass, so the roster still reads
  # as lying in wait rather than milling about.
  defp plan_explore(data, character, entry, distances, unseen) do
    if roll(data) >= knob(data, "erased_roam_chance", 0.35) * 1.0 do
      nil
    else
      unseen
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
    {data, effect} = score_infiltration(data, character, entry, effect)
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

  # Whether the infiltration failed, and at what odds this agent would go
  # again now that the system's Intelligence is known. A failure at modest
  # odds in a system somebody holds puts it on a cool-off (Wave.Erased,
  # "Staying hidden"): its owner has just been shown the agent, and is a
  # building or two from shutting it out. Neutral ground has nobody to answer.
  defp score_infiltration(data, character, entry, %{ci: ci} = effect) do
    with attack when is_number(attack) <- Map.get(entry, :attack),
         failed? when is_boolean(failed?) <-
           Erased.infiltration_failed?(Map.get(entry, :cover), character.spy.cover.value) do
      chance = Wave.Intel.success_chance(attack, character.level, ci)
      effect = Map.merge(effect, %{failed: failed?, odds_now: Float.round(chance, 3)})
      target = Map.get(entry, :target)

      if failed? and chance < knob(data, "erased_fail_cooloff_chance", 0.75) * 1.0 and held?(data, target),
        do: {Warlord.infiltration_failed(data, target), Map.put(effect, :cooloff, true)},
        else: {data, effect}
    else
      _ -> {data, effect}
    end
  end

  defp score_infiltration(data, _character, _entry, effect), do: {data, effect}

  defp held?(data, system_id) do
    case call(data, :stellar_system, system_id, :get_state) do
      {:ok, %{owner: owner}} -> owner != nil
      _ -> false
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
  # Fleets: Navarchs hired for a role, built in a shipyard system, then posted
  # ---------------------------------------------------------------------------

  # The part of the fleet step that needs no galaxy reading: look the yards
  # over, let each lay down a ship, hire the next Navarch.
  defp tend_fleets(data, player, summaries) do
    if Warlord.fleets_enabled?(data) do
      data
      |> survey_yards(player)
      |> review_doctrine()
      |> build_fleets(player, summaries)
      |> maybe_hire_fleet(player)
    else
      data
    end
  end

  # Every owned system's type is read once (it never changes); the military
  # ones are the yards, and they are read again at every survey for the
  # shipyards standing there and the experience they give.
  defp survey_yards(data, player) do
    if Warlord.yards_due?(data, number(knob(data, "fleet_yard_refresh_ut", 120.0), 120.0)) do
      dominions = if knob(data, "fleet_yard_dominions", true) != false, do: player.dominions, else: []
      known = Map.get(data, :system_profiles, %{})
      old_yards = Map.get(data, :yards, %{})
      yard_profiles = knob(data, "fleet_yard_profiles", ["defense"])

      {profiles, yards} =
        Enum.reduce(player.stellar_systems ++ dominions, {%{}, %{}}, fn %{id: id}, {profiles, yards} ->
          profile = Map.get(known, id)

          if profile != nil and not Fleet.yard_profile?(profile, yard_profiles) do
            {Map.put(profiles, id, profile), yards}
          else
            case call(data, :stellar_system, id, :get_state) do
              {:ok, system} ->
                yard? = Fleet.yard_profile?(system.ai_profile, yard_profiles)
                yards = if yard?, do: Map.put(yards, id, Fleet.yard(system)), else: yards
                {Map.put(profiles, id, system.ai_profile), yards}

              # Unreadable this time: keep what the last survey said.
              _ ->
                profiles = if profile, do: Map.put(profiles, id, profile), else: profiles
                yards = if yard = Map.get(old_yards, id), do: Map.put(yards, id, yard), else: yards
                {profiles, yards}
            end
          end
        end)

      data
      |> survey_hulls()
      |> Warlord.put_yards(profiles, yards)
      |> Warlord.gauge(:yards, map_size(yards))
      |> then(&Warlord.gauge(&1, :capital_allowance, Warlord.capital_allowance(&1)))
    else
      data
    end
  end

  # One ship per yard per `fleet_ship_interval_ut` (longer for a costly hull
  # when `fleet_production_pace` is set), for the fleet that has waited there
  # longest. A besieged yard builds nothing.
  defp build_fleets(data, player, summaries) do
    besieged =
      for system <- player.stellar_systems ++ player.dominions, Map.get(system, :siege) != nil, into: MapSet.new() do
        system.id
      end

    data
    |> Warlord.fleets()
    |> Enum.filter(fn {id, entry} -> entry.stage == :building and docked?(summaries[id], entry.yard) end)
    |> Enum.group_by(fn {_id, entry} -> entry.yard end, fn {id, entry} -> {entry.since, id} end)
    |> Enum.reduce(data, fn {yard_id, queue}, acc ->
      if Warlord.yard_ready?(acc, yard_id) and not MapSet.member?(besieged, yard_id),
        do: lay_down(acc, yard_id, Enum.sort(queue)),
        else: acc
    end)
  end

  # Standing in the yard with nothing queued. `:docking` is the moment between
  # a ship being ordered and landing.
  defp docked?(%{system: system, action_status: status, actions: actions}, yard_id)
       when system == yard_id and status in [:idle, :docking],
       do: is_nil(actions) or ActionQueue.empty?(actions)

  defp docked?(_summary, _yard_id), do: false

  defp lay_down(data, _yard_id, []), do: data

  defp lay_down(data, yard_id, [{_since, id} | rest]) do
    entry = Map.get(Warlord.fleets(data), id)
    yard = Map.get(data.yards, yard_id)

    case yard && entry && call(data, :player, data.player_id, {:get_character_state, id}) do
      %Character{type: :admiral, system: ^yard_id, army: army} = character ->
        case Fleet.next_ship(entry.slots, army) do
          # Nothing missing: this fleet is done, the yard serves the next one.
          nil -> data |> fleet_complete(character, entry) |> lay_down(yard_id, rest)
          {tile, key} -> lay_ship(data, id, yard, tile, key)
        end

      _ ->
        lay_down(data, yard_id, rest)
    end
  end

  # The same order_ship + put_ship pair the colony ship uses: no production
  # queue and no credit. The ship takes the experience the yard gives its
  # class, as a player's ship would.
  defp lay_ship(data, character_id, yard, tile, key) do
    ship = Data.Querier.one(Data.Game.Ship, data.instance_id, key)

    case call(data, :character, character_id, {:order_ship, {nil, tile, key, nil}}) do
      {:ok, _character} ->
        Game.cast(data.instance_id, :character, character_id, {:put_ship, tile, Fleet.initial_xp(yard, ship)})

        interval = Fleet.class_interval(ship, Warlord.ship_interval(data), knob(data, "fleet_class_interval_ut", %{}))
        ut = Fleet.ship_ut(yard, ship, interval, number(knob(data, "fleet_production_pace", 0), 0))

        data
        |> Warlord.ship_laid(character_id, yard.id, ut)
        |> Warlord.count(:fleet_ships_laid)

      other ->
        Warlord.refuse(data, :fleet_ship, reason_of(other))
    end
  end

  defp fleet_complete(data, character, entry) do
    stance = fleet_stance(data, entry.role)
    call(data, :player, data.player_id, {:update_reaction, character.id, stance})

    log(data, "wave_fleet_built", character.id, character.system, %{
      day: Warlord.match_day(data),
      role: entry.role,
      design: entry.design,
      ships: length(entry.slots),
      stance: stance,
      build_ut: Float.round((data.elapsed - entry.since) / 1, 1)
    })

    data
    |> Warlord.fleet_stage(character.id, :complete)
    |> Warlord.count(:fleets_built)
  end

  defp fleet_stance(data, role) do
    name = "fleet_stances" |> then(&knob(data, &1, %{})) |> Map.get(Atom.to_string(role))
    Enum.find([:flee, :fight_back, :defend, :attack_enemies, :attack_everyone], :defend, &(Atom.to_string(&1) == name))
  end

  # The roster grows toward the fleet ceiling, one Navarch per
  # `fleet_hire_interval_ut`, each hired for the role furthest below its share.
  defp maybe_hire_fleet(data, player) do
    ceiling = Warlord.fleet_ceiling(data)
    stage = Research.stage(Warlord.elapsed_days(data), knob(data, "fleet_stage_days", [5, 12]))
    quotas = Fleet.quotas(ceiling, Fleet.role_weights(knob(data, "fleet_role_weights", %{}), stage))

    data =
      data
      |> Warlord.gauge(:fleet_cap, ceiling)
      |> Warlord.gauge(:fleet_quotas, quotas)

    cond do
      not Warlord.fleet_hire_due?(data) ->
        data

      map_size(Warlord.fleets(data)) >= ceiling ->
        Warlord.hold_fleet_hire(data)

      map_size(data.yards) == 0 ->
        data |> Warlord.defer_fleet_hire() |> Warlord.refuse(:fleet, :no_yard)

      true ->
        data |> Warlord.consume_fleet_hire() |> hire_fleet(player, quotas)
    end
  end

  defp hire_fleet(data, player, quotas) do
    env = fleet_env(data)

    # The first role with places open that the Rebellion has, or can take from
    # the library, a design for.
    {data, plan} =
      quotas
      |> Fleet.role_order(Warlord.fleet_counts(data))
      |> Enum.reduce_while({data, nil}, fn role, {acc, nil} ->
        case fleet_design(acc, env, role) do
          {acc, nil} -> {:cont, {acc, nil}}
          {acc, {identity, slots}} -> {:halt, {acc, {role, identity, slots}}}
        end
      end)

    with {role, identity, slots} <- plan,
         %{} = yard <- Fleet.pick_yard(env.yards, slots, env.ships, Warlord.yard_load(data), env.needs_shipyard?),
         {:ok, %{id: id} = navarch, deployed_at} <-
           hire_agent(data, %{player: player}, :admiral, &navarch_score/1, yard.id) do
      Logger.info(
        "[wave] instance #{data.instance_id}: rebellion raised #{role} Navarch #{id} at system #{deployed_at} " <>
          "for yard #{yard.id} (#{identity.id})"
      )

      log(data, "wave_fleet_hired", id, deployed_at, %{
        day: Warlord.match_day(data),
        role: role,
        design: identity.id,
        generation: identity.generation,
        ships: Enum.map(slots, fn {_tile, key} -> key end),
        yard: yard.id,
        level: Map.get(navarch, :level)
      })

      data
      |> Warlord.count(:fleets_hired)
      |> Warlord.order("hire:fleet", :ok)
      |> Warlord.track_fleet(id, role, identity.id, slots, yard.id)
    else
      nil ->
        data
        |> Warlord.defer_fleet_hire()
        |> Warlord.refuse(:fleet, :no_design)
        |> Warlord.order("hire:fleet", {:error, :no_design})

      {:error, stage, reason} ->
        data
        |> Warlord.refuse(stage, reason)
        |> Warlord.order("hire:fleet", {:error, {stage, reason}})
    end
  end

  # What every design decision reads: the catalog, the hulls the humans have
  # unlocked (the Rebellion builds nothing else), the cap on capital ships and
  # what the yards can lay down.
  defp fleet_env(data) do
    ships = Map.new(Data.Querier.all(Data.Game.Ship, data.instance_id), &{&1.key, &1})
    patents = Warlord.human_hulls(data)
    hulls = Blueprints.hulls(ships, patents)
    yards = Map.values(data.yards)
    needs_shipyard? = knob(data, "fleet_yard_needs_shipyard", true) != false
    allowance = Warlord.capital_allowance(data)

    %{
      ships: ships,
      patents: patents,
      yards: yards,
      needs_shipyard?: needs_shipyard?,
      share: number(knob(data, "fleet_design_share", 0.5), 0.5),
      alternatives: Doctrine.alternatives(ships, hulls),
      allow: fn slots -> Enum.any?(yards, &Fleet.builds?(&1, slots, ships, needs_shipyard?)) end,
      shape: fn layout ->
        Doctrine.cap_capitals(layout, ships, allowance, Doctrine.capital_substitute(layout, ships, hulls))
      end
    }
  end

  # A hull layout as the ships a yard would lay down today, or nil when the
  # hulls are not unlocked or no yard can build them.
  defp build_slots(env, layout) do
    case Blueprints.resolve(%{slots: env.shape.(layout)}, env.patents, env.ships) do
      {:ok, [_ | _] = slots} -> if env.allow.(slots), do: slots
      _ -> nil
    end
  end

  # The design a new fleet of `role` is built to: one of the role's identities
  # once the book is full, a new one from the library until then.
  defp fleet_design(data, env, role) do
    book = Warlord.identities(data, role)
    usable = for identity <- book, slots = build_slots(env, identity.slots), do: {identity, slots}
    wanted = max(trunc(number(knob(data, "fleet_identities_per_role", 2), 2)), 1)

    if length(book) >= wanted and usable != [] do
      {data, Enum.at(usable, min(trunc(roll(data) * length(usable)), length(usable) - 1))}
    else
      # A full book with nothing buildable in it gives up its oldest identity.
      data = if length(book) >= wanted, do: Warlord.drop_identity(data, role, hd(book).id), else: data

      case mint_identity(data, env, role) do
        {data, nil} -> {data, List.first(usable)}
        {data, identity} -> {data, {identity, build_slots(env, identity.slots)}}
      end
    end
  end

  # A library design the role's book does not hold yet, fuzzed into an
  # identity of the Rebellion's own.
  defp mint_identity(data, env, role) do
    exclude = data |> Warlord.identities(role) |> Enum.map(& &1.base)

    pick =
      Blueprints.pick(Blueprints.pool(), role, env.patents, env.ships, roll(data),
        share: env.share,
        allow: env.allow,
        shape: env.shape,
        exclude: exclude
      )

    case pick do
      :none ->
        {data, nil}

      {:ok, %{design: base}} ->
        swaps = trunc(number(knob(data, "fleet_fuzz_swaps", 3), 3))
        moves = trunc(number(knob(data, "fleet_fuzz_moves", 2), 2))
        {id, data} = Warlord.next_design_id(data, base.id)
        identity = Doctrine.new(base, id, data.elapsed, env.alternatives, rolls(data, swaps + moves), swaps, moves)

        # Hulls stay in their class, so a fuzz cannot take a design out of a
        # yard's reach; if it ever did, the design is flown as the players did.
        identity = if build_slots(env, identity.slots), do: identity, else: %{identity | slots: base.slots}

        log(data, "wave_design_new", nil, nil, design_record(data, role, identity))

        {data |> Warlord.put_identity(role, identity) |> Warlord.count(:designs_new), identity}
    end
  end

  # Two dice per fuzz operation.
  defp rolls(_data, operations) when operations <= 0, do: []
  defp rolls(data, operations), do: for(_ <- 1..(operations * 2), do: roll(data))

  defp design_record(data, role, identity) do
    %{
      day: Warlord.match_day(data),
      role: role,
      design: identity.id,
      base: identity.base,
      generation: identity.generation,
      hulls: identity.slots |> Enum.map(fn {_tile, hull} -> hull end) |> Enum.frequencies(),
      wins: identity.total_wins,
      losses: identity.total_losses,
      strikes: identity.strikes
    }
  end

  # Once a day the book is read against what its fleets did: winners are
  # fuzzed again, losers out of forgiveness are replaced from the library, and
  # so is an identity the library has left behind unless it is winning.
  defp review_doctrine(data) do
    if Warlord.review_due?(data, number(knob(data, "fleet_review_interval_ut", 480.0), 480.0)) do
      env = fleet_env(data)

      Blueprints.roles()
      |> Enum.reduce(data, fn role, acc ->
        floor =
          Blueprints.draw_floor(Blueprints.pool(), role, env.patents, env.ships,
            share: env.share,
            allow: env.allow,
            shape: env.shape
          )

        acc
        |> Warlord.identities(role)
        |> Enum.reduce(acc, &review_identity(&2, env, role, &1, floor))
      end)
      |> Warlord.mark_reviewed()
    else
      data
    end
  end

  defp review_identity(data, env, role, identity, floor) do
    verdict =
      Doctrine.verdict(
        identity,
        trunc(number(knob(data, "fleet_design_min_results", 2), 2)),
        number(knob(data, "fleet_design_win_share", 0.5), 0.5),
        number(knob(data, "fleet_design_lose_share", 0.34), 0.34)
      )

    # Left behind: what it builds today costs well under the cheapest design
    # the library would still offer for the role.
    slots = build_slots(env, identity.slots)
    slack = number(knob(data, "fleet_design_outdated_share", 0.75), 0.75)
    outdated? = floor != nil and (slots == nil or Blueprints.production(slots, env.ships) < floor * slack)

    forgiveness = trunc(number(knob(data, "fleet_design_forgiveness", 1), 1))

    case Doctrine.review(identity, verdict, forgiveness: forgiveness, outdated?: outdated?) do
      {:keep, identity} ->
        Warlord.put_identity(data, role, identity)

      {:refuzz, identity} ->
        swaps = trunc(number(knob(data, "fleet_refuzz_swaps", 1), 1))
        moves = trunc(number(knob(data, "fleet_refuzz_moves", 1), 1))
        next = Doctrine.refuzz(identity, env.alternatives, rolls(data, swaps + moves), swaps, moves)
        next = if build_slots(env, next.slots), do: next, else: %{identity | generation: next.generation}

        log(data, "wave_design_refuzzed", nil, nil, design_record(data, role, next))

        data
        |> Warlord.put_identity(role, next)
        |> Warlord.count(:designs_refuzzed)

      {:replace, identity} ->
        log(
          data,
          "wave_design_replaced",
          nil,
          nil,
          Map.merge(design_record(data, role, identity), %{verdict: verdict, outdated: outdated?})
        )

        data
        |> Warlord.drop_identity(role, identity.id)
        |> Warlord.count(:designs_replaced)
        |> mint_identity(env, role)
        |> elem(0)
    end
  end

  # The ship-branch patents the humans hold: the only hulls a fleet is built
  # from, and the clock the capital allowance runs on.
  defp survey_hulls(data) do
    case read_humans(data) do
      [] ->
        data

      humans ->
        held =
          Research.ship_patents(Data.Querier.all(Data.Game.Patent, data.instance_id), Enum.map(humans, & &1.patents))

        capital? =
          Data.Game.Ship
          |> Data.Querier.all(data.instance_id)
          |> Enum.any?(&(&1.class == :capital and &1.patent in held))

        data = Warlord.learn_hulls(data, held, capital?)
        Warlord.gauge(data, :human_hulls, length(Warlord.human_hulls(data)))
    end
  end

  # Only a commander's level reaches the battle (it feeds the ships' morale),
  # so of the ranks the day has unlocked the highest level is bought.
  defp navarch_score(character), do: max(Map.get(character, :level) || 1, 1)

  # The fleets that are idle with somewhere to go: off their yard while
  # building, finished and not yet posted, away from their post, or mauled.
  # Steering them needs the galaxy.
  defp adrift_fleets(data, player, summaries) do
    if Warlord.fleets_enabled?(data) do
      held = MapSet.new(player.stellar_systems ++ player.dominions, & &1.id)
      refit = number(knob(data, "fleet_refit_share", 0.35), 0.35)

      for {id, entry} <- Warlord.fleets(data),
          summary = summaries[id],
          roster_idle?(summary),
          summary.system != nil,
          Map.get(entry, :retry_at, 0.0) <= data.elapsed,
          fleet_adrift?(data, entry, summary, held, refit),
          do: id
    else
      []
    end
  end

  defp fleet_adrift?(data, %{stage: :building} = entry, summary, _held, _refit),
    do: summary.system != entry.yard or not Map.has_key?(data.yards, entry.yard)

  defp fleet_adrift?(_data, %{stage: :complete}, _summary, _held, _refit), do: true

  defp fleet_adrift?(_data, %{stage: :posted} = entry, summary, held, refit) do
    summary.system != entry.post or not MapSet.member?(held, entry.post) or
      Fleet.missing_share(entry.slots, fleet_size(summary)) >= refit
  end

  defp fleet_adrift?(_data, _entry, _summary, _held, _refit), do: false

  defp fleet_size(%{army_size: %{filled: filled}}) when is_integer(filled), do: filled
  defp fleet_size(_summary), do: 0

  defp steer_fleets(data, _ctx, []), do: data

  defp steer_fleets(data, ctx, ids) do
    posts = fleet_posts(data, ctx)

    Enum.reduce(ids, data, fn id, acc ->
      entry = Map.get(Warlord.fleets(acc), id)
      summary = Enum.find(ctx.player.characters, &(&1.id == id))

      if entry && summary, do: steer_fleet(acc, ctx, posts, summary, entry), else: acc
    end)
  end

  # Building: walk to the yard, or find another when the yard was lost.
  defp steer_fleet(data, ctx, _posts, summary, %{stage: :building} = entry) do
    if Map.has_key?(data.yards, entry.yard) do
      fleet_travel(data, ctx, summary, entry.yard, "order:fleet_to_yard")
    else
      case another_yard(data, entry) do
        nil -> Warlord.fleet_stage(data, summary.id, :complete)
        yard -> Warlord.fleet_stage(data, summary.id, :building, %{yard: yard.id})
      end
    end
  end

  # Finished: take a post and walk there.
  defp steer_fleet(data, ctx, posts, summary, %{stage: :complete} = entry) do
    case fleet_post(data, posts, entry) do
      nil ->
        Warlord.fleet_wait(data, summary.id, 20.0)

      post ->
        log(data, "wave_fleet_posted", summary.id, post, %{
          day: Warlord.match_day(data),
          role: entry.role,
          design: entry.design,
          from: summary.system
        })

        data
        |> Warlord.fleet_stage(summary.id, :posted, %{post: post})
        |> Warlord.count(:fleets_posted)
        |> fleet_travel(ctx, summary, post, "order:fleet_to_post")
    end
  end

  # Posted: back to a yard when mauled, to a new post when this one was lost,
  # back to the post when a lost fight threw it off.
  defp steer_fleet(data, ctx, posts, summary, %{stage: :posted} = entry) do
    refit = number(knob(data, "fleet_refit_share", 0.35), 0.35)

    cond do
      Fleet.missing_share(entry.slots, fleet_size(summary)) >= refit ->
        case another_yard(data, entry) do
          nil ->
            Warlord.fleet_wait(data, summary.id, 120.0)

          yard ->
            log(data, "wave_fleet_refit", summary.id, yard.id, %{
              day: Warlord.match_day(data),
              role: entry.role,
              design: entry.design,
              ships_left: fleet_size(summary)
            })

            data
            |> Warlord.fleet_stage(summary.id, :building, %{yard: yard.id})
            |> Warlord.count(:fleets_refit)
            |> fleet_travel(ctx, summary, yard.id, "order:fleet_to_yard")
        end

      not MapSet.member?(posts.held, entry.post) ->
        Warlord.fleet_stage(data, summary.id, :complete, %{post: nil})

      true ->
        fleet_travel(data, ctx, summary, entry.post, "order:fleet_to_post")
    end
  end

  defp steer_fleet(data, _ctx, _posts, _summary, _entry), do: data

  defp another_yard(data, entry) do
    ships = Map.new(Data.Querier.all(Data.Game.Ship, data.instance_id), &{&1.key, &1})
    needs_shipyard? = knob(data, "fleet_yard_needs_shipyard", true) != false

    Fleet.pick_yard(Map.values(data.yards), entry.slots, ships, Warlord.yard_load(data), needs_shipyard?)
  end

  # A move that cannot be ordered is not retried every pass: each retry would
  # cost a galaxy reading.
  defp fleet_travel(data, _ctx, %{system: system}, target_id, _kind) when system == target_id, do: data

  defp fleet_travel(data, ctx, summary, target_id, kind) do
    case travel(data, ctx, summary, target_id) do
      :ok ->
        Warlord.order(data, kind, :ok)

      {:error, reason} ->
        data
        |> Warlord.refuse(:fleet_move, reason)
        |> Warlord.order(kind, {:error, reason})
        |> Warlord.fleet_wait(summary.id, 20.0)
    end
  end

  # The Rebellion's systems as posts: border sectors and inner ones, shipyards
  # first, and the border system nearest the humans, where the fleets with a
  # job outside muster.
  defp fleet_posts(data, ctx) do
    held = ctx.player.stellar_systems ++ ctx.player.dominions
    yard_ids = data.yards |> Map.keys() |> MapSet.new()
    {border, core} = Enum.split_with(held, &(Geometry.class_of(ctx.geo, &1) == :border))
    border = Fleet.rank_posts(border, yard_ids)
    core = Fleet.rank_posts(core, yard_ids)

    %{border: border, core: core, held: MapSet.new(held, & &1.id), muster: muster_point(data, ctx, border, core)}
  end

  defp muster_point(data, ctx, border, core) do
    hostile = for system <- ctx.geo.systems, system.faction not in [nil, data.bot_faction], do: system.id
    candidates = Enum.take(if(border == [], do: core, else: border), 12)

    nearest =
      candidates
      |> Enum.with_index()
      |> Enum.map(fn {id, rank} ->
        distances = Nav.hop_distances(ctx.geo.adjacency, id)
        {hostile |> Enum.map(&Map.get(distances, &1)) |> Enum.reject(&is_nil/1) |> Enum.min(fn -> nil end), rank, id}
      end)
      |> Enum.reject(fn {hops, _rank, _id} -> is_nil(hops) end)
      |> Enum.min(fn -> nil end)

    case nearest do
      {_hops, _rank, id} -> id
      nil -> List.first(candidates)
    end
  end

  defp fleet_post(data, posts, %{role: :defense}) do
    posted =
      for {_id, %{role: :defense, stage: :posted, post: post}} <- Warlord.fleets(data), post != nil, do: post

    Fleet.defense_post(
      posted,
      posts.border,
      posts.core,
      number(knob(data, "fleet_defense_border_share", 0.6), 0.6)
    )
  end

  defp fleet_post(_data, posts, _entry), do: posts.muster

  # ---------------------------------------------------------------------------
  # Research: patents and lexes
  # ---------------------------------------------------------------------------

  # The Rebellion researches like a player, through the player agent and at
  # the engine's price: a starter set once, the humans' ship patents on every
  # survey, and one random building patent or lex per research interval
  # (Wave.Research has the rules). The catalogs and the humans are only read
  # on a pass that has something to do.
  defp maybe_research(data, player) do
    seeding? = not Warlord.research_seeded?(data)
    if Warlord.research_enabled?(data), do: publish_economy(data, player.patents)

    if Warlord.research_enabled?(data) and
         (seeding? or Warlord.survey_due?(data) or Warlord.research_due?(data) or Warlord.enact_pending?(data)) do
      catalog = %{
        patents: Data.Querier.all(Data.Game.Patent, data.instance_id),
        lexes: Data.Querier.all(Data.Game.Doctrine, data.instance_id)
      }

      # What the Rebellion holds, kept current as this pass buys.
      book = %{patents: player.patents, lexes: player.doctrines, slots: player.max_policies, enacted: player.policies}

      {data, book} = if seeding?, do: seed_research(data, book, catalog), else: {data, book}

      {data, book} =
        if seeding? or Warlord.survey_due?(data), do: survey_humans(data, book, catalog), else: {data, book}

      {data, book} = if Warlord.research_due?(data), do: timed_purchase(data, book, catalog), else: {data, book}
      publish_economy(data, book.patents)

      if Warlord.enact_pending?(data), do: enact_lexes(data, player, book, catalog), else: data
    else
      data
    end
  end

  # Rebel systems build only what the Rebellion holds the patent for, and
  # know the stage of the game from here (`Wave.Config.economy/1`). The
  # instance metadata is rebuilt at every boot, so this runs on every pass
  # and writes only when something changed.
  defp publish_economy(data, patents) do
    Wave.Config.publish_economy(data.instance_id, patents, research_stage(data))
  end

  defp research_stage(data) do
    Research.stage(Warlord.elapsed_days(data), knob(data, "research_stage_days", [5, 12]))
  end

  # The starter patents and the standing lexes with their ancestors. Stays
  # unseeded, and tries again next pass, until every one of them is owned.
  defp seed_research(data, book, catalog) do
    starter = Research.starter_patents(catalog.patents, starter_quotas(data, catalog))
    always = always_lexes(data, catalog)

    {data, book, _} = buy(data, book, :patents, Enum.reject(starter, &(&1 in book.patents)), "research:starter_patent")

    {data, book, _} =
      buy(data, book, :lexes, Research.purchase_plan(catalog.lexes, always, book.lexes), "research:standing_lex")

    if Enum.all?(starter, &(&1 in book.patents)) and Enum.all?(always, &(&1 in book.lexes)),
      do: {data |> Warlord.mark_research_seeded() |> Warlord.set_enact_pending(true), book},
      else: {data, book}
  end

  # Ships are copied, not chosen: every ship-branch patent a human holds is
  # bought, and so is a building patent enough of them hold. The same reading
  # sets how many lex slots the Rebellion may hold.
  defp survey_humans(data, book, catalog) do
    case read_humans(data) do
      [] ->
        {Warlord.mark_surveyed(data, Warlord.lex_slot_cap(data)), book}

      humans ->
        held = Enum.map(humans, & &1.patents)
        ships = Research.ship_patents(catalog.patents, held)

        followed =
          case knob(data, "patent_follow_humans", 2) do
            holders when is_integer(holders) and holders > 0 ->
              Research.followed_patents(catalog.patents, held, holders)

            _ ->
              []
          end

        slot_cap = humans |> Enum.map(& &1.max_policies) |> Enum.max()

        {data, book, result} =
          buy(
            data,
            book,
            :patents,
            Research.purchase_plan(catalog.patents, ships, book.patents),
            "research:ship_patent"
          )

        {data, book, result} =
          if result == :ok do
            plan = Research.purchase_plan(catalog.patents, followed, book.patents)
            buy(data, book, :patents, plan, "research:followed_patent")
          else
            {data, book, result}
          end

        data =
          data
          |> Warlord.gauge(:human_ship_patents, length(ships))
          |> Warlord.gauge(:human_building_patents, length(followed))
          |> Warlord.gauge(:human_lex_slots, slot_cap)

        # A patent the stock could not cover is retried next pass, after the top-up.
        if unaffordable?(result), do: {data, book}, else: {Warlord.mark_surveyed(data, slot_cap), book}
    end
  end

  defp read_humans(data) do
    case call(data, :galaxy, :master, :get_state) do
      {:ok, galaxy} ->
        for p <- Map.values(galaxy.players),
            p.faction != data.bot_faction,
            {:ok, human} <- [call(data, :player, p.id, :get_state)],
            do: human

      _ ->
        []
    end
  end

  # One turn per research interval, a building patent and a lex in turn.
  defp timed_purchase(data, book, catalog) do
    turn = Warlord.research_turn(data)

    # A patent turn buys the building patent of the day or passes, so the
    # lexes keep their own pace instead of taking the patents' turns too. A
    # lex turn with no lex left to buy may go to the patent, if one is due.
    kinds = if turn == :lex, do: [:lex, :patent], else: [:patent]

    case Enum.find_value(kinds, fn kind -> (key = research_pick(data, book, catalog, kind)) && {kind, key} end) do
      nil ->
        {Warlord.research_passed(data, turn), book}

      {:patent, key} ->
        {data, book, result} = buy(data, book, :patents, [key], "research:patent")
        {after_timed(data, :patent, result), book}

      {:lex, key} ->
        {data, book, result} = buy(data, book, :lexes, [key], "research:lex")
        {after_timed(data, :lex, result), book}
    end
  end

  # The cheapest building patent on offer, within the stage of the game, and
  # no more often than `patent_interval_ut`.
  defp research_pick(data, book, catalog, :patent) do
    if Warlord.patent_due?(data) do
      cap = Research.cost_cap(research_stage(data), knob(data, "patent_stage_cost", [5_000, 45_000]))
      Research.building_pick(catalog.patents, book.patents, cap)
    end
  end

  # The next step down the economy list; once that is all owned, a random lex
  # worth having. Either is approached one purchase at a time, so this may
  # buy a penalised lex on the way, which is never enacted.
  defp research_pick(data, book, catalog, :lex) do
    case Research.economy_step(catalog.lexes, named_lexes(data, catalog, "lex_economy"), book.lexes) do
      nil ->
        case pick(data, Research.lex_targets(catalog.lexes, book.lexes)) do
          nil -> nil
          target -> Research.next_step(catalog.lexes, target, book.lexes)
        end

      step ->
        step
    end
  end

  defp pick(_data, []), do: nil
  defp pick(data, list), do: Enum.at(list, min(trunc(roll(data) * length(list)), length(list) - 1))

  defp after_timed(data, kind, :ok), do: Warlord.research_bought(data, kind)

  defp after_timed(data, _kind, result) do
    # Unaffordable: stay due, the next pass has the stock topped up again.
    if unaffordable?(result), do: data, else: Warlord.restart_research(data)
  end

  defp unaffordable?({:error, reason}), do: reason in [:not_enough_technology, :not_enough_ideology]
  defp unaffordable?(_result), do: false

  # Buys `keys` in order off one shelf (`:patents` or `:lexes`) and stops at
  # the first refusal, since later keys may hang off the one refused.
  defp buy(data, book, shelf, keys, ledger) do
    Enum.reduce_while(keys, {data, book, :ok}, fn key, {data, book, _result} ->
      {message, counter} =
        case shelf do
          :patents -> {{:purchase_patent, key}, :patents_bought}
          :lexes -> {{:purchase_doctrine, key}, :lexes_bought}
        end

      case call(data, :player, data.player_id, message) do
        :ok ->
          book = Map.update!(book, shelf, &(&1 ++ [key]))
          data = data |> Warlord.order(ledger, :ok) |> Warlord.count(counter)
          data = if shelf == :lexes, do: Warlord.set_enact_pending(data, true), else: data

          log(data, "wave_research", nil, nil, %{
            day: Warlord.match_day(data),
            bought: ledger,
            key: Atom.to_string(key),
            owned: length(Map.fetch!(book, shelf))
          })

          {:cont, {data, book, :ok}}

        other ->
          reason = reason_of(other)
          data = data |> Warlord.order(ledger, {:error, reason}) |> Warlord.refuse(:research, reason)
          {:halt, {data, book, {:error, reason}}}
      end
    end)
  end

  # Slots first, then the lexes that fill them. Lex changes share one
  # cooldown, so a change that finds it running waits for a later pass.
  defp enact_lexes(data, player, book, catalog) do
    always = always_lexes(data, catalog)
    named = Enum.uniq(always ++ named_lexes(data, catalog, "lex_economy"))
    penalties? = knob(data, "lex_enact_expansion_penalties", false) == true
    enactable = Research.enactable(catalog.lexes, book.lexes, named, penalties?)

    wanted =
      Research.slots_wanted(length(enactable), Enum.count(always, &(&1 in book.lexes)), Warlord.lex_slot_cap(data))

    {data, book} = buy_slots(data, book, wanted)
    desired = Enum.take(enactable, book.slots)

    cond do
      Enum.sort(desired) == Enum.sort(book.enacted) ->
        Warlord.set_enact_pending(data, false)

      Core.CooldownValue.locked?(player.policies_cooldown) ->
        data

      true ->
        case call(data, :player, data.player_id, {:update_policies, desired}) do
          :ok ->
            log(data, "wave_research", nil, nil, %{
              day: Warlord.match_day(data),
              enacted: Enum.map(desired, &Atom.to_string/1),
              slots: book.slots
            })

            data
            |> Warlord.order("research:enact", :ok)
            |> Warlord.count(:lex_updates)
            |> Warlord.set_enact_pending(false)

          other ->
            reason = reason_of(other)
            data = data |> Warlord.order("research:enact", {:error, reason}) |> Warlord.refuse(:research, reason)
            # Only a cooldown is worth waiting out; anything else waits for the next purchase.
            if reason == :cooldown_not_unlock, do: data, else: Warlord.set_enact_pending(data, false)
        end
    end
  end

  defp buy_slots(data, %{slots: slots} = book, wanted) when slots >= wanted, do: {data, book}

  defp buy_slots(data, book, wanted) do
    case call(data, :player, data.player_id, :purchase_policy_slot) do
      :ok ->
        data = data |> Warlord.order("research:lex_slot", :ok) |> Warlord.count(:lex_slots_bought)
        buy_slots(data, %{book | slots: book.slots + 1}, wanted)

      other ->
        reason = reason_of(other)
        {data |> Warlord.order("research:lex_slot", {:error, reason}) |> Warlord.refuse(:research, reason), book}
    end
  end

  # The `patent_starter` knob as `%{class => count}`, over the catalog's own
  # class atoms (the knob's keys are strings from the instance's game data).
  defp starter_quotas(data, catalog) do
    quotas =
      case knob(data, "patent_starter", %{}) do
        map when is_map(map) -> map
        _ -> %{}
      end

    for class <- catalog.patents |> Enum.map(& &1.class) |> Enum.uniq(),
        count = Map.get(quotas, Atom.to_string(class)),
        is_number(count),
        into: %{},
        do: {class, trunc(count)}
  end

  defp always_lexes(data, catalog), do: named_lexes(data, catalog, "lex_always")

  # A knob listing lexes, as catalog keys in the knob's order; names the
  # catalog does not know are dropped.
  defp named_lexes(data, catalog, name) do
    by_name = Map.new(catalog.lexes, &{Atom.to_string(&1.key), &1.key})

    case knob(data, name, []) do
      names when is_list(names) ->
        names |> Enum.map(&Map.get(by_name, to_string(&1))) |> Enum.reject(&is_nil/1) |> Enum.uniq()

      _ ->
        []
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

  defp fleet_record(data, character_id) do
    entry = Map.get(Warlord.fleets(data), character_id, %{})

    %{
      day: Warlord.match_day(data),
      role: Map.get(entry, :role),
      design: Map.get(entry, :design),
      stage: Map.get(entry, :stage),
      post: Map.get(entry, :post)
    }
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

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
  """

  use Core.TickServer

  require Logger

  alias Instance.Character.{ActionQueue, Character}
  alias Wave.{Nav, Warlord}

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

  # Dev/test lever: make the hire cycle due and run the loop immediately,
  # instead of waiting six real hours at Legacy speed.
  @decorate tick()
  def on_call(:force_hire, _from, state) do
    data = %{state.data | hire_accum: Warlord.hire_interval(state.data)}
    state = next_tick(%{state | data: data})
    {:reply, {:ok, Warlord.summary(state.data)}, state}
  end

  # Dev/test lever: run one management pass now (dispatch/recall/dismiss).
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
    {:reply, :ok, %{state | tick: tick, data: %{state.data | connected: false}}}
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
      |> Warlord.advance(elapsed_time)
      |> run()

    {%{state | data: data}, Warlord}
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
    data
    |> ensure_connected()
    |> top_up()
    |> maybe_hire()
    |> manage_colonisers()
  rescue
    error ->
      Logger.error("[wave] warlord pass failed in instance #{data.instance_id}: #{Exception.format(:error, error, __STACKTRACE__)}")
      data
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
  # price, so without this the second or third Navarch would already fail on
  # affordability. Bankruptcy itself is suppressed in Player.detect_bankruptcy.
  defp top_up(data) do
    case call(data, :player, data.player_id, :get_state) do
      {:ok, player} ->
        credit = shortfall(player.credit.value, knob(data, "credit_floor", 0))
        technology = shortfall(player.technology.value, knob(data, "technology_floor", 0))
        ideology = shortfall(player.ideology.value, knob(data, "ideology_floor", 0))

        if credit + technology + ideology > 0 do
          call(data, :player, data.player_id, {:add_resources, credit, technology, ideology})
        end

        data

      _ ->
        data
    end
  end

  defp shortfall(value, floor) when is_number(value) and is_number(floor) and value < floor,
    do: trunc(Float.ceil((floor - value) / 1))

  defp shortfall(_value, _floor), do: 0

  # ---------------------------------------------------------------------------
  # Recruitment
  # ---------------------------------------------------------------------------

  defp maybe_hire(data) do
    cap = knob(data, "max_active_colonisers", 6)

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
        |> hire_and_deploy()
    end
  end

  # Buy a one-star Navarch from the shared character market, deploy it on-board
  # at home, and put a colony ship straight into its fleet.
  defp hire_and_deploy(data) do
    rank = rank_atom(knob(data, "hire_rank", "common"))
    tile = knob(data, "colony_ship_tile", 1)

    with {:ok, market} <- step(:market, call(data, :character_market, :master, :get_state)),
         {:ok, candidate} <- cheapest_candidate(market, :admiral, rank),
         {:ok, player} <- step(:hire, player_reply(call(data, :player, data.player_id, {:hire_character, candidate.id}))),
         {:ok, home_id} <- home_system(player),
         {:ok, _player} <-
           step(:activate, player_reply(call(data, :player, data.player_id, {:activate_character, candidate.id, :on_board, home_id}))),
         {:ok, _} <- grant_colony_ship(data, candidate.id, tile) do
      Logger.info("[wave] instance #{data.instance_id}: rebellion deployed Navarch #{candidate.id} at system #{home_id}")

      data
      |> Warlord.count(:hired)
      |> Warlord.count(:deployed)
      |> Warlord.track(candidate.id)
    else
      {:error, stage, reason} ->
        Logger.warning("[wave] instance #{data.instance_id}: hire cycle refused at #{stage}: #{inspect(reason)}")
        Warlord.refuse(data, stage, reason)
    end
  end

  defp cheapest_candidate(market, type, rank) do
    market.slots
    |> Enum.filter(&(&1.key == type))
    |> Enum.flat_map(& &1.data)
    |> Enum.filter(&(&1.key == rank))
    |> Enum.flat_map(& &1.data)
    |> Enum.map(& &1.character)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> {:error, :market, :no_candidate}
      candidates -> {:ok, Enum.min_by(candidates, &(&1.credit_cost || 0))}
    end
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
  # Coloniser management
  # ---------------------------------------------------------------------------

  defp manage_colonisers(%Warlord{colonisers: colonisers} = data) when map_size(colonisers) == 0, do: data

  defp manage_colonisers(data) do
    with {:ok, player} <- call(data, :player, data.player_id, :get_state),
         {:ok, galaxy} <- call(data, :galaxy, :master, :get_state) do
      context = %{player: player, galaxy: galaxy, adjacency: Nav.adjacency(galaxy)}

      Enum.reduce(Map.keys(data.colonisers), data, fn character_id, acc ->
        manage_one(acc, character_id, context)
      end)
    else
      _ -> data
    end
  end

  defp manage_one(data, character_id, %{player: player} = context) do
    on_board? = Enum.any?(player.characters, &(&1.id == character_id))
    in_deck? = Enum.any?(player.character_deck, fn %{character: c} -> c.id == character_id end)

    cond do
      on_board? ->
        case call(data, :player, data.player_id, {:get_character_state, character_id}) do
          %Character{} = character -> steer(data, character, context)
          _ -> data
        end

      # Recalled on an earlier pass but the dismissal didn't go through.
      in_deck? ->
        dismiss(data, character_id)

      # Gone from both lists: killed, converted, or dismissed elsewhere.
      true ->
        Warlord.forget(data, character_id)
    end
  end

  defp steer(data, character, context) do
    entry = Map.get(data.colonisers, character.id)
    idle? = character.action_status == :idle and ActionQueue.empty?(character.actions)

    cond do
      # Travelling, colonising, or still docking while its ship lands.
      not idle? ->
        data

      Character.has_colonization_ship?(character) ->
        dispatch(data, character, context)

      # We sent it and the ship is spent: the colony landed. Recall, then dismiss.
      entry.stage == :dispatched ->
        recall_and_dismiss(data, character, context)

      # Idle with no ship and never dispatched — the ship grant was lost. Retry it.
      true ->
        case grant_colony_ship(data, character.id, knob(data, "colony_ship_tile", 1)) do
          {:ok, _} -> data
          {:error, stage, reason} -> Warlord.refuse(data, stage, reason)
        end
    end
  end

  defp dispatch(data, character, %{galaxy: galaxy, adjacency: adjacency}) do
    # Don't count this Navarch's own stale target as reserved against itself.
    reserved = data |> Warlord.released(character.id) |> Warlord.reserved_targets()

    with %{id: target_id} <- Warlord.colonisation_target(galaxy, data.bot_faction, character.system, reserved),
         hops when is_list(hops) <- Nav.path_hops(adjacency, character.system, target_id),
         actions = Warlord.colonisation_actions(hops, target_id),
         :ok <- call(data, :player, data.player_id, {:add_character_actions, character.id, actions}),
         true <- accepted?(data, character.id) do
      data
      |> Warlord.dispatched(character.id, target_id)
      |> Warlord.count(:dispatched)
    else
      nil -> Warlord.refuse(data, :dispatch, :no_target)
      false -> Warlord.refuse(data, :dispatch, :dropped_by_engine)
      other -> Warlord.refuse(data, :dispatch, reason_of(other))
    end
  end

  # add_character_actions answers :ok even when pre-validation silently dropped
  # every entry, so confirm the order actually landed in the queue.
  defp accepted?(data, character_id) do
    case call(data, :player, data.player_id, {:get_character_state, character_id}) do
      %Character{actions: actions, action_status: status} ->
        not ActionQueue.empty?(actions) or status != :idle

      _ ->
        false
    end
  end

  defp recall_and_dismiss(data, character, context) do
    case player_reply(call(data, :player, data.player_id, {:deactivate_character, character.id})) do
      {:ok, _player} ->
        data
        |> Warlord.count(:colonised)
        |> dismiss(character.id)

      # Not standing in an owned system — walk it home, recall next pass.
      {:error, :character_not_at_home} ->
        send_home(data, character, context)

      {:error, reason} ->
        Warlord.refuse(data, :recall, reason)
    end
  end

  # Dismissal carries no deck cooldown (Player.dismiss_character/2 only checks
  # the card exists), so a freshly recalled Navarch can be released at once.
  defp dismiss(data, character_id) do
    case player_reply(call(data, :player, data.player_id, {:dismiss_character, character_id})) do
      {:ok, _player} ->
        Logger.info("[wave] instance #{data.instance_id}: rebellion dismissed Navarch #{character_id}")

        data
        |> Warlord.count(:dismissed)
        |> Warlord.forget(character_id)

      {:error, reason} ->
        Warlord.refuse(data, :dismiss, reason)
    end
  end

  defp send_home(data, character, %{player: player, adjacency: adjacency}) do
    distances = Nav.hop_distances(adjacency, character.system)

    home =
      (player.stellar_systems ++ player.dominions)
      |> Enum.filter(&Map.has_key?(distances, &1.id))
      |> Enum.min_by(&Map.fetch!(distances, &1.id), fn -> nil end)

    with %{id: home_id} <- home,
         hops when is_list(hops) and hops != [] <- Nav.path_hops(adjacency, character.system, home_id),
         jumps = Enum.map(hops, fn {from, to} -> %{"type" => "jump", "data" => %{"source" => from, "target" => to}} end),
         :ok <- call(data, :player, data.player_id, {:add_character_actions, character.id, jumps}) do
      data
    else
      _ -> Warlord.refuse(data, :recall, :no_route_home)
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

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

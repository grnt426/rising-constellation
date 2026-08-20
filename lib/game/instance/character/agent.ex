defmodule Instance.Character.Agent do
  use Core.TickServer

  alias Instance.Character.Action
  alias Instance.Character.ActionImpl
  alias Instance.Character.ActionQueue
  alias Instance.Character.Character

  require Logger

  # SERVER

  # Rebase every in-flight action's `started_at` into the live monotonic
  # frame before the tick loop kicks off. Two scenarios are covered by the
  # same call (see `Action.rebase_started_at/3`):
  #
  #   * Post-deploy restore — the snapshot carries `started_at` values from
  #     the dead BEAM's monotonic clock, which `compute_progress` cannot
  #     interpret in the new BEAM's frame. Without this, `Faction` radar's
  #     `in_disk` check rejects every in-flight character (their position
  #     extrapolates to nonsense), and the client renders them at the start
  #     of the path because the corresponding client-side formula produces
  #     a hugely-negative percent that clamps to 0.
  #
  #   * Engine pause/resume — between stop and start no character tick
  #     fires, so `remaining_time` is intact, but `started_at` still
  #     references the pre-pause clock. Rebasing makes progress resume
  #     from the pre-pause fraction (no advance during downtime —
  #     matching the engine's "no simulation while paused" contract).
  #
  # We override the TickServer default `{:start, _}` rather than tacking the
  # rebase onto every callback because (a) `:start` is called exactly once
  # per agent life via `Instance.Manager.start`, and (b) the live monotonic
  # frame is whatever monotonic clock the just-started tick will use, so
  # this is the moment the new frame becomes authoritative.
  def on_call({:start, cumulated_pauses}, _from, state) do
    factor = state.tick.factor
    data = rebase_in_flight_actions(state.data, factor, cumulated_pauses)
    tick = Core.Tick.start(%{state.tick | cumulated_pauses: cumulated_pauses})
    {:reply, :ok, %{state | tick: tick, data: data}}
  end

  defp rebase_in_flight_actions(%Character{actions: nil} = data, _factor, _cumulated_pauses), do: data

  defp rebase_in_flight_actions(%Character{actions: %ActionQueue{} = aq} = data, factor, cumulated_pauses) do
    %{data | actions: ActionQueue.map(aq, &Action.rebase_started_at(&1, factor, cumulated_pauses))}
  end

  @decorate tick()
  def on_call(:get_state, _from, state) do
    {:reply, {:ok, state.data}, state}
  end

  def on_call({:add_actions, _}, _from, %{data: %Character{on_strike: true}} = state) do
    {:reply, {:error, :character_on_strike}, state}
  end

  @decorate tick()
  def on_call({:add_actions, actions}, _from, state) do
    data = Character.add_actions(state.data, actions, &ActionImpl.pre_validate_action/2)
    Game.cast(state.instance_id, :player, data.owner.id, {:update_character, data})

    {:reply, :ok, %{state | data: data}}
  end

  @decorate tick()
  def on_call(:flee, _from, state) do
    # fleeing clears the whole queue — a charging traveler's gateway
    # lock must not leak with it
    Instance.Character.Actions.Gateway.release_if_interrupted(state.data)

    target_id = Game.call(state.instance_id, :galaxy, :master, {:get_closest_system, state.data.system})
    data = Character.flee(state.data, target_id)

    {:reply, data, %{state | data: data}}
  end

  @decorate tick()
  def on_call({:sabotage_army, target_pv}, _from, state) do
    if state.data.type == :admiral do
      data = Character.sabotage_army(state.data, target_pv)
      {:reply, {:ok, data}, %{state | data: data}}
    else
      {:reply, {:error, :error}, state}
    end
  end

  @decorate tick()
  def on_call({:order_ship, production_data}, _from, state) do
    case Character.order_ship(state.data, production_data) do
      {:ok, data} -> {:reply, {:ok, data}, %{state | data: data}}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @decorate tick()
  def on_call({:cancel_ship, tile_id}, _from, state) do
    case Character.cancel_ship(state.data, tile_id) do
      {:ok, data} ->
        # Mirror put_ship: the player's cached copy must see the updated
        # planned-ship count and, when this was the last planned ship, the
        # docking -> idle flip. Without this the cache stays :docking forever
        # (no later event refreshes it) — the character can't be moved from
        # the UI or listed on the market.
        Game.cast(state.instance_id, :player, data.owner.id, {:update_character, data})
        {:reply, {:ok, data}, %{state | data: data}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @decorate tick()
  def on_call({:destroy_ship, tile_id}, _from, state) do
    data = Character.remove_ship(state.data, tile_id)
    {:reply, {:ok, data}, %{state | data: data}}
  end

  @decorate tick()
  def on_call(:cancel_all_ships, _from, state) do
    data = Character.cancel_all_ships(state.data)
    {:reply, data, %{state | data: data}}
  end

  def on_call({:update_reaction, _}, _from, %{data: %Character{on_strike: true}} = state) do
    {:reply, {:error, :character_on_strike}, state}
  end

  @decorate tick()
  def on_call({:update_reaction, reaction}, _from, %{data: %{type: :admiral}} = state) do
    data = Character.update_reaction(state.data, reaction)
    {:reply, {:ok, data}, %{state | data: data}}
  end

  def on_call({:update_reaction, _reaction}, _from, state) do
    {:reply, {:error, :reaction_only_for_admirals}, state}
  end

  # Armada membership sync — the owning Player.Agent is the single
  # writer (Instance.Player.ArmadaImpl); this just applies the new map
  # (or nil on detach/dissolve) and refreshes the player cache.
  @decorate tick()
  def on_call({:update_armada, armada}, _from, state) do
    data = Character.update_armada(state.data, armada)
    Game.cast(state.instance_id, :player, data.owner.id, {:update_character, data})

    {:reply, {:ok, data}, %{state | data: data}}
  end

  # Attached transit (docs/armadas.md §3.3): the armada lead's
  # Jump.start pulls every other member out of the source system. An
  # attached member carries no motion state at all — no queue, no
  # spatial entry — so there is nothing to desynchronize in transit.
  @decorate tick()
  def on_call({:armada_attach, source_system_id}, _from, state) do
    data = state.data

    if data.status == :on_board and data.type == :admiral and data.system == source_system_id do
      {:ok, _system} =
        Game.call(state.instance_id, :stellar_system, source_system_id, {:remove_character, data, :on_board})

      Spatial.delete(data)
      data = %{data | system: nil, action_status: :attached}
      Game.cast(state.instance_id, :player, data.owner.id, {:update_character, data})

      {:reply, {:ok, data}, %{state | data: data}}
    else
      {:reply, {:error, :not_attachable}, state}
    end
  end

  # Attached transit arrival: the lead's Jump.finish materializes every
  # member into the destination before the (single) interception pass.
  # virtual_position is pinned to the destination so the member's own
  # later orders validate from where it actually stands.
  @decorate tick()
  def on_call({:armada_materialize, system_id, position}, _from, state) do
    data = state.data

    if data.status == :on_board and data.action_status == :attached do
      {:ok, _system} = Game.call(state.instance_id, :stellar_system, system_id, {:push_character, data, :on_board})

      data =
        data
        |> Character.enter_system(system_id, position)
        |> Character.set_virtual_position(system_id)

      Game.cast(state.instance_id, :player, data.owner.id, {:update_character, data})

      {:reply, {:ok, data}, %{state | data: data}}
    else
      {:reply, {:error, :not_attached}, state}
    end
  end

  # Armada retreat support: a losing member that is not the flee-lead
  # drops its remaining orders and idles; the flee-lead's Jump.start
  # re-attaches it for the retreat jump (test class 5).
  @decorate tick()
  def on_call(:armada_clear_to_idle, _from, state) do
    Instance.Character.Actions.MakeDominion.unmark_if_interrupted(state.data)
    # dropping the queue must not leak a mid-charge gateway lock
    Instance.Character.Actions.Gateway.release_if_interrupted(state.data)

    data =
      state.data
      |> Character.clear_actions()
      |> Character.set_virtual_position(state.data.system)
      |> Character.idle()

    Game.cast(state.instance_id, :player, data.owner.id, {:update_character, data})

    {:reply, {:ok, data}, %{state | data: data}}
  end

  def on_call({:update_owner, player}, _from, state) do
    iid = state.instance_id
    data = state.data
    position = data.actions.virtual_position

    Game.call(iid, :stellar_system, position, {:remove_character, data, :on_board})
    data = Character.update_owner(data, player)
    Game.call(iid, :stellar_system, position, {:push_character, data, :on_board})

    {:reply, {:ok, data}, %{state | data: data}}
  end

  @decorate tick()
  def on_call({:update_strike, player_is_bankrupt}, _from, state) do
    data = Character.update_strike(state.data, player_is_bankrupt)
    {:reply, {:ok, data}, %{state | data: data}}
  end

  @decorate tick()
  def on_call({:update_bonuses, from, bonuses}, _, state) do
    data = Character.update_bonuses(state.data, from, bonuses)

    {:reply, data, %{state | data: data}}
  end

  def on_call(:get_position, _from, state) do
    instance_id = state.instance_id
    {position, angle} = Character.get_position(state.data, instance_id)

    {:reply, {:ok, {state.data, position, angle}}, state}
  end

  def on_call({:fix, systems}, _from, state) do
    {result, data} = Character.fix(state.data, systems)
    Game.cast(state.instance_id, :player, data.owner.id, {:update_character, data})

    {:reply, result, %{state | data: data}}
  end

  def on_call({:set_on_sold}, _from, state) do
    data = Character.set_on_sold(state.data)
    {:reply, {:ok, data}, %{state | data: data}}
  end

  def on_call({:unset_on_sold}, _from, state) do
    data = Character.unset_on_sold(state.data)
    {:reply, {:ok, data}, %{state | data: data}}
  end

  # called by orchestrator
  def on_call({:done, _hook_type, %Character{} = character}, _from, state) do
    ref = Process.send_after(self(), :tick, 0)
    tick = %{state.tick | time: Instance.Time.Time.now(state.tick.cumulated_pauses), ref: ref, running?: true}

    # agent state might have changed while orchestrator was doing its thing
    character =
      if state.data.on_strike and not character.on_strike do
        %{character | on_strike: state.data.on_strike}
      else
        character
      end

    {:reply, :ok, %{state | tick: tick, data: character}}
  end

  @decorate tick()
  def on_cast({:update_state, character}, state) do
    {:noreply, %{state | data: character}}
  end

  @decorate tick()
  def on_cast({:put_ship, tile_id, initial_xp}, state) do
    data = Character.put_ship(state.data, tile_id, initial_xp)
    Game.cast(state.instance_id, :player, data.owner.id, {:update_character, data})

    {:noreply, %{state | data: data}}
  end

  @decorate tick()
  def on_cast({:clear_actions, index}, state) do
    if index == 0 and Instance.Character.Actions.Gateway.jump_in_progress?(state.data) do
      # a portal jump cannot be recalled: clearing the head would strand
      # the traveler at system nil forever — the jump must land first
      {:noreply, state}
    else
      # clearing from index 0 drops the in-progress action too — if that's
      # a running make_dominion, lift the target owner's under-attack mark;
      # if it's a gateway transit, free the faction's gateway lock
      if index == 0 do
        Instance.Character.Actions.MakeDominion.unmark_if_interrupted(state.data)
        Instance.Character.Actions.Gateway.release_if_interrupted(state.data)
      end

      data = Character.clear_actions_after(state.data, index)
      Game.cast(state.instance_id, :player, data.owner.id, {:update_character, data})

      {:noreply, %{state | data: data}}
    end
  end

  # Passive XP grant (Training Center drip and any future trainer).
  @decorate tick()
  def on_cast({:add_experience, amount}, state) do
    {change, notifs, data} = Character.add_experience(state.data, amount)
    change = MapSet.put(change, :player_update)

    send_update(change, data)
    send_notifs(notifs, data)

    {:noreply, %{state | data: data}}
  end

  # Government-driven charge abort (gateway link torn down by capture).
  # Only a running charge aborts; a jump lands and fatigue is local.
  @decorate tick()
  def on_cast({:gateway_abort}, state) do
    case Instance.Character.Actions.Gateway.abort_charge(state.data) do
      {:aborted, data} ->
        Game.cast(state.instance_id, :player, data.owner.id, {:update_character, data})
        {:noreply, %{state | data: data}}

      {:noop, _data} ->
        {:noreply, state}
    end
  end

  # called by orchestrator
  def orchestrated(:start, %Action{} = action, %Character{} = character) do
    {change, notifs, character} = ActionImpl.on_start(%Character{} = character, action)

    send_update(change, character)
    send_notifs(notifs, character)

    {:ok, character}
  end

  # called by orchestrator
  def orchestrated(:finish, %Action{} = action, %Character{} = character) do
    {change, notifs, character} = ActionImpl.on_finish(%Character{} = character, action)

    send_update(change, character)
    send_notifs(notifs, character)

    {:ok, character}
  end

  @decorate tick()
  def on_info(:tick, state) do
    {:noreply, state}
  end

  # TICK FUNCTIONS

  defp do_next_tick(state, next_tick) do
    {change, notifs, %Character{} = character} = Character.next_tick(state.data, next_tick, state.tick.cumulated_pauses)

    send_update(change, character)
    send_notifs(notifs, character)

    {%{state | data: character}, Character}
  end

  # PRIVATE FUNCTIONS

  defp send_notifs(notifs, %Character{} = character) do
    unless Enum.empty?(notifs),
      do: Game.cast(character.instance_id, :player, character.owner.id, {:push_notifs, notifs})
  end

  defp send_update(change, %Character{} = character) do
    if MapSet.member?(change, :player_update) and character.owner != nil do
      Game.cast(character.instance_id, :player, character.owner.id, {:update_character, character})
    end

    if MapSet.member?(change, :system_update) and character.system != nil do
      Game.cast(character.instance_id, :stellar_system, character.system, {:update_character, character})
    end
  end
end

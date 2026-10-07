defmodule Instance.Character.Agent do
  use Core.TickServer

  alias Instance.Character.Action
  alias Instance.Character.ActionImpl
  alias Instance.Character.ActionQueue
  alias Instance.Character.Character
  alias Instance.Character.LockMerge

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

  # Also back-fills uids: actions restored from a snapshot taken before
  # uids existed have none, and every plan edit (cancel, reorder) names
  # actions by uid — without this such a queue stays uneditable until it
  # has fully played out.
  defp rebase_in_flight_actions(%Character{actions: %ActionQueue{} = aq} = data, factor, cumulated_pauses) do
    rebase = fn action -> action |> Action.rebase_started_at(factor, cumulated_pauses) |> Action.ensure_uid() end
    %{data | actions: ActionQueue.map(aq, rebase)}
  end

  @decorate tick()
  def on_call(:get_state, _from, state) do
    {:reply, {:ok, state.data}, state}
  end

  def on_call({:add_actions, _}, _from, %{data: %Character{on_strike: true}} = state) do
    {:reply, {:error, :character_on_strike}, state}
  end

  # All or nothing: a refused action rejects the whole batch with its
  # reason (`:invalid_jump`, `:invalid_position`, …), which the client
  # toasts. The queue and the owner's cached copy stay as they were.
  #
  # While the orchestrator runs the head's start/finish hook the queue is
  # locked, and its `{:done}` hands back the queue as the hook left it
  # (LockMerge keeps the hook's `:actions`) — an edit applied in between
  # would be acknowledged and then silently undone. Player edits are
  # refused with `:agent_busy` instead
  # (the channel retries for a few seconds; see Portal.Channels.BusyRetry).
  # The tick runs before the body, so a head that became due just now is
  # already locked here.
  @decorate tick()
  def on_call({:add_actions, actions}, _from, state) do
    if ActionQueue.locked?(state.data.actions) do
      {:reply, {:error, :agent_busy}, state}
    else
      case Character.add_actions(state.data, actions, &ActionImpl.validate_action/2) do
        {:ok, data} ->
          Game.cast(state.instance_id, :player, data.owner.id, {:update_character, data})
          {:reply, :ok, %{state | data: data}}

        {:error, _reason} = error ->
          {:reply, error, state}
      end
    end
  end

  # Player plan edit (remove/reorder stops): keep through `keep_uid`,
  # replace the rest with the validated `tail`. Same lock rule as above.
  @decorate tick()
  def on_call({:edit_actions, keep_uid, tail}, _from, state) do
    if ActionQueue.locked?(state.data.actions) do
      {:reply, {:error, :agent_busy}, state}
    else
      case Character.edit_actions(state.data, keep_uid, tail, &ActionImpl.validate_action/2) do
        {:ok, data} ->
          Game.cast(state.instance_id, :player, data.owner.id, {:update_character, data})
          {:reply, :ok, %{state | data: data}}

        {:error, _reason} = error ->
          {:reply, error, state}
      end
    end
  end

  # Player cancel: keep the queue up to and including the action with
  # `uid` (the entry before the one clicked) — or, for callers without
  # uids, the first `index` entries. A call, not a cast, so the reply
  # says what actually happened.
  @decorate tick()
  def on_call({:clear_actions, spec}, _from, state) do
    with :ok <- if(ActionQueue.locked?(state.data.actions), do: {:error, :agent_busy}, else: :ok),
         {:ok, index} <- clear_index(state.data.actions, spec) do
      clear_actions(state, index)
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @decorate tick()
  def on_call(:flee, _from, state) do
    target_id = Game.call(state.instance_id, :galaxy, :master, {:get_closest_system, state.data.system})

    if ActionQueue.locked?(state.data.actions) do
      # A hook is in flight for this agent (it lost a fight while its own
      # action was starting/finishing). Clearing the queue now would drop
      # the lock under that hook and let a second one start; the flee is
      # applied to the hook's result instead (see {:done}). The caller
      # (fight_callback) gets the fleeing character right away.
      defer_queue_op({:flee, state.data.system, target_id})
      {:reply, Character.flee(state.data, target_id), state}
    else
      data = flee(state.data, target_id)
      {:reply, data, %{state | data: data}}
    end
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

  # CHEAT (fleet editor): see Character.cheat_edit_army/2. Reached only via
  # the CheatChannel; re-checks the instance flag like the other agent-side
  # cheat ops. The owner's cached copy (army_size, upkeep -> income) is
  # refreshed like a ship completion; the system summary carries no army.
  @decorate tick()
  def on_call({:cheat_edit_army, edit}, _from, state) do
    with true <- Instance.Cheats.enabled?(state.instance_id) or {:error, :cheats_disabled},
         {:ok, data} <- Character.cheat_edit_army(state.data, edit) do
      Game.cast(state.instance_id, :player, data.owner.id, {:update_character, data})
      {:reply, {:ok, data}, %{state | data: data}}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
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
  # writer (Instance.Player.ArmadaImpl); this applies the new map (or
  # nil on detach/dissolve) and refreshes both caches: the player
  # roster AND the stellar system's summary copy, which carries the
  # armada grouping every viewer of the system sees.
  @decorate tick()
  def on_call({:update_armada, armada}, _from, state) do
    data = Character.update_armada(state.data, armada)
    Game.cast(state.instance_id, :player, data.owner.id, {:update_character, data})

    if data.system != nil do
      Game.cast(state.instance_id, :stellar_system, data.system, {:update_character, data})
    end

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
    if ActionQueue.locked?(state.data.actions) do
      # same as :flee — applied to the pending hook's result on {:done}
      defer_queue_op(:armada_clear_to_idle)
      {:reply, {:ok, idle(state.data, false)}, state}
    else
      data = idle(state.data, true)
      Game.cast(state.instance_id, :player, data.owner.id, {:update_character, data})
      {:reply, {:ok, data}, %{state | data: data}}
    end
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

  # The owner can no longer pay for a university course (the player
  # agent's tuition check): the student stops there and waits to be
  # recalled. The system's roster follows, since the slot is free again —
  # and so does the owner's, although the reply carries the same state:
  # the tick that ran just before this body may have cast an update of its
  # own (settled in, a credit, a level), which the owner will read AFTER
  # the reply and must not be left with.
  @decorate tick()
  def on_call({:end_course, reason}, _from, state) do
    case Character.end_course(state.data, reason) do
      {:ok, data} ->
        Game.cast(state.instance_id, :player, data.owner.id, {:update_character, data})

        if data.system != nil do
          Game.cast(state.instance_id, :stellar_system, data.system, {:update_character, data})
        end

        {:reply, {:ok, data}, %{state | data: data}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
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

  # called by orchestrator, with the character it was handed (`base`,
  # queue locked) — see Instance.Character.LockMerge: writes that landed
  # while the hook ran are merged into its result instead of discarded.
  def on_call({:done, hook_type, %Character{} = character, %Character{} = base}, _from, state) do
    {merged, changed, conflicts} = LockMerge.merge(base, state.data, character)

    unless conflicts == [] do
      Logger.warning(
        "character #{character.id}: #{inspect(conflicts)} changed both during the #{inspect(hook_type)} hook " <>
          "and by the hook itself; kept the hook's"
      )
    end

    merged = if changed == [], do: merged, else: Character.recompute_bonus(merged)
    {merged, replayed?} = replay_queue_ops(merged)

    # the owner only heard about the hook's result (sent from inside the
    # hook); refresh it when the window's writes are part of the outcome
    unless (changed == [] and not replayed?) or merged.owner == nil do
      Game.cast(state.instance_id, :player, merged.owner.id, {:update_character, merged})
    end

    {:reply, :ok, done(state, merged)}
  end

  # Pre-merge protocol (an orchestrator from before this change still in
  # flight across a deploy): the hook's copy wins, apart from a strike.
  def on_call({:done, _hook_type, %Character{} = character}, _from, state) do
    character =
      if state.data.on_strike and not character.on_strike do
        %{character | on_strike: state.data.on_strike}
      else
        character
      end

    {character, _replayed?} = replay_queue_ops(character)
    {:reply, :ok, done(state, character)}
  end

  @decorate tick()
  def on_cast({:update_state, character}, state) do
    {:noreply, %{state | data: character}}
  end

  # Verdict of the async attached-state watchdog probe (spawned by the
  # tick — see Character.check_armada_attachment). A verdict that raced
  # a materialization or detach is dropped by the :attached guard.
  def on_cast({:armada_watch_result, healthy?}, %{data: %Character{action_status: :attached}} = state) do
    case Character.apply_armada_watch_result(state.data, healthy?) do
      {:ok, data} ->
        {:noreply, %{state | data: data}}

      {:recovered, data} ->
        Game.cast(state.instance_id, :player, data.owner.id, {:update_character, data})
        {:noreply, %{state | data: data}}
    end
  end

  def on_cast({:armada_watch_result, _healthy?}, state), do: {:noreply, state}

  @decorate tick()
  def on_cast({:put_ship, tile_id, initial_xp}, state) do
    data = Character.put_ship(state.data, tile_id, initial_xp)
    Game.cast(state.instance_id, :player, data.owner.id, {:update_character, data})

    {:noreply, %{state | data: data}}
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

  defp clear_index(actions, {:keep_uid, uid}) when is_integer(uid) do
    case ActionQueue.keep_count_through(actions, uid) do
      # the kept action already ran or the queue was replaced since the
      # client rendered it: the click no longer means what it meant
      nil -> {:error, :stale_queue}
      index -> {:ok, index}
    end
  end

  defp clear_index(_actions, index) when is_integer(index) and index >= 0, do: {:ok, index}
  defp clear_index(_actions, _spec), do: {:error, :invalid_payload}

  defp clear_actions(state, index) do
    if index == 0 and Instance.Character.Actions.Gateway.jump_in_progress?(state.data) do
      # a portal jump cannot be recalled: clearing the head would strand
      # the traveler at system nil forever — the jump must land first
      {:reply, {:error, :gateway_jump_in_progress}, state}
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

      {:reply, :ok, %{state | data: data}}
    end
  end

  # after a hook: install the result and tick right away (the next action
  # may be due)
  defp done(state, character) do
    ref = Process.send_after(self(), :tick, 0)
    tick = %{state.tick | time: Instance.Time.Time.now(state.tick.cumulated_pauses), ref: ref, running?: true}
    %{state | tick: tick, data: character}
  end

  defp flee(data, target_id) do
    # fleeing clears the whole queue — a charging traveler's gateway
    # lock must not leak with it
    Instance.Character.Actions.Gateway.release_if_interrupted(data)
    Character.flee(data, target_id)
  end

  defp idle(data, cleanup?) do
    if cleanup? do
      Instance.Character.Actions.MakeDominion.unmark_if_interrupted(data)
      # dropping the queue must not leak a mid-charge gateway lock
      Instance.Character.Actions.Gateway.release_if_interrupted(data)
    end

    data
    |> Character.clear_actions()
    |> Character.set_virtual_position(data.system)
    |> Character.idle()
  end

  # Queue operations that arrived while a hook was in flight (they must not
  # touch the locked queue), applied in order to the hook's result. Kept in
  # the process dictionary: they only live for one lock window.
  @deferred_ops :character_deferred_queue_ops

  defp defer_queue_op(op), do: Process.put(@deferred_ops, [op | Process.get(@deferred_ops, [])])

  defp replay_queue_ops(data) do
    case Process.delete(@deferred_ops) do
      nil -> {data, false}
      ops -> {ops |> Enum.reverse() |> Enum.reduce(data, &replay_queue_op/2), true}
    end
  end

  # The hook may have taken the agent elsewhere (a jump started): it is no
  # longer standing where the fight happened, so there is nothing to flee.
  defp replay_queue_op({:flee, from_system, target_id}, %Character{system: from_system} = data)
       when from_system != nil,
       do: flee(data, target_id)

  defp replay_queue_op({:flee, _from_system, _target_id}, data), do: data
  defp replay_queue_op(:armada_clear_to_idle, data), do: idle(data, true)
end

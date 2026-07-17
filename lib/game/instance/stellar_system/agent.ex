defmodule Instance.StellarSystem.Agent do
  use Core.TickServer

  require Logger

  alias Instance.StellarSystem.StellarSystem
  alias RC.Instances.InstanceEventLog

  @decorate tick()
  def on_call(:get_state, _from, state) do
    {:reply, {:ok, state.data}, state}
  end

  def on_call(:get_position, _from, state) do
    {:reply, {:ok, state.data.position}, state}
  end

  def on_call({:order_building, "build", production_data}, _, state) do
    case StellarSystem.order_building_production(state.data, production_data) do
      {:ok, data} -> {:reply, {:ok, data}, %{state | data: data}}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def on_call({:order_building, "repair", production_data}, _, state) do
    case StellarSystem.order_building_repairs(state.data, production_data) do
      {:ok, data} -> {:reply, {:ok, data}, %{state | data: data}}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def on_call({:order_ship, production_data}, _, state) do
    with {character_id, _, _, _} <- production_data,
         {:ok, character} <- Game.call(state.instance_id, :character, character_id, :get_state),
         {:ok, data} <- StellarSystem.can_order_ship(state.data, production_data, character),
         {:ok, character} <- Game.call(state.instance_id, :character, character_id, {:order_ship, production_data}),
         {:ok, data} <- StellarSystem.order_ship_production(data, production_data, character) do
      {:reply, {:ok, character, data}, %{state | data: data}}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @decorate tick()
  def on_call({:remove_building, production_data}, _, state) do
    case StellarSystem.remove_building(state.data, production_data) do
      {:ok, change, notifs, data} ->
        cast_hook(state.instance_id, {change, notifs, data})
        {:reply, {:ok, data}, %{state | data: data}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @decorate tick()
  def on_call({:cancel_production, production_id}, _, state) do
    case StellarSystem.cancel_production(state.data, production_id) do
      {:ok, :building, credit, data} ->
        {:reply, {credit, 0, data}, %{state | data: data}}

      {:ok, :building_repairs, credit, data} ->
        {:reply, {credit, 0, data}, %{state | data: data}}

      {:ok, :ship, item, credit, technology, data} ->
        case Game.call(state.instance_id, :character, item.target_id, {:cancel_ship, item.tile_id}) do
          {:ok, _} ->
            {:reply, {credit, technology, data}, %{state | data: data}}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @decorate tick()
  def on_call({:claim, player, is_initial_system, is_dominion}, _, state) do
    data =
      case StellarSystem.claim(state.data, player, is_initial_system, is_dominion) do
        {:radar_update, data} ->
          Game.cast(state.instance_id, :victory, :master, {:radar_update, data})
          data

        {:no_radar_update, data} ->
          data
      end

    {:reply, data, %{state | data: data}}
  end

  @decorate tick()
  def on_call({:abandon}, _, state) do
    {:radar_update, data} = StellarSystem.abandon(state.data)
    Game.cast(state.instance_id, :victory, :master, {:radar_update, data})

    {:reply, data, %{state | data: data}}
  end

  @decorate tick()
  def on_call({:release_siege, lost_population_chances, damaged_buildings_chances}, _, state) do
    if state.data.siege do
      InstanceEventLog.emit(state.instance_id, "siege_released", %{
        system_id: state.data.id,
        character_id: state.data.siege.besieger_id,
        payload: %{
          cause: "action_resolved",
          type: state.data.siege.type,
          besieger_id: state.data.siege.besieger_id
        }
      })
    end

    {data, logs} =
      state.data
      |> StellarSystem.release_siege()
      |> StellarSystem.raid(lost_population_chances, damaged_buildings_chances)

    if data.owner do
      case data.status do
        :inhabited_player -> Game.cast(data.instance_id, :player, data.owner.id, {:update_system, data})
        :inhabited_dominion -> Game.cast(data.instance_id, :player, data.owner.id, {:update_dominion, data})
        _ -> nil
      end

      # Refund the owner for any upgrades whose tile was hit by the raid
      # damage roll. The credit cast is async because the owner's player
      # process is already going to receive the system update above and we
      # don't want to block this stellar_system handler on their mailbox.
      refund = Map.get(logs, :cancelled_upgrades_refund, 0)

      if refund > 0 do
        Game.cast(data.instance_id, :player, data.owner.id, {:add_resources, refund, 0, 0})
      end
    end

    {:reply, {:ok, data, logs}, %{state | data: data}}
  end

  # Check if it's used
  @decorate tick()
  def on_call({:raid, lost_population_chances, lost_buildings_chances}, _, state) do
    {data, _logs} = StellarSystem.raid(state.data, lost_population_chances, lost_buildings_chances)

    {:reply, :ok, %{state | data: data}}
  end

  @decorate tick()
  def on_call({:update_bonuses, from, bonuses}, _, state) do
    {_, _, data} = StellarSystem.update_bonuses(state.data, from, bonuses)
    {:reply, data, %{state | data: data}}
  end

  # push/remove/update_character notify the owner so their Player.StellarSystem
  # snapshot (side-panel agent dots, governor display) tracks arrivals and
  # departures. Without this the snapshot only refreshed when some unrelated
  # event raised :player_update — a foreign agent could leave and its dot
  # would linger indefinitely on a quiet system.
  @decorate tick()
  def on_call({:push_character, character, mode}, _, state) do
    {:ok, data} = StellarSystem.push_character(state.data, character, mode)
    notify_owner_update(state.instance_id, data)
    {:reply, {:ok, data}, %{state | data: data}}
  end

  @decorate tick()
  def on_call({:remove_character, character, mode}, _, state) do
    {:ok, data} = StellarSystem.remove_character(state.data, character, mode)

    # Backstop: a siege must not outlive its besieging fleet. The
    # normal release paths (conquest/raid/loot `finish`, the death/flee
    # callback) cover the common cases, but ANY other departure — a
    # queue re-plan that drops the conquest then jumps the fleet away,
    # a flee whose callback raced the `action_status` it keys off — used
    # to leave the siege standing on an empty system until its own timer
    # expired. Releasing here closes that leak at the single choke point
    # every departure (death, deactivate, jump-out) flows through.
    data =
      if data.siege != nil and data.siege.besieger_id == character.id do
        released = StellarSystem.release_siege(data)

        InstanceEventLog.emit(state.instance_id, "siege_released", %{
          system_id: data.id,
          character_id: character.id,
          payload: %{cause: "besieger_left", type: data.siege.type, besieger_id: character.id}
        })

        released
      else
        data
      end

    notify_owner_update(state.instance_id, data)
    {:reply, {:ok, data}, %{state | data: data}}
  end

  @decorate tick()
  def on_cast({:update_character, character}, state) do
    {:ok, data} = StellarSystem.update_character(state.data, character)
    notify_owner_update(state.instance_id, data)
    {:noreply, %{state | data: data}}
  end

  @decorate tick()
  def on_cast({:besiege, type, duration, character_id}, state) do
    data = StellarSystem.besiege(state.data, type, duration, character_id)
    notif = Notification.Text.new(:system_under_siege, data.id, %{system: data.name})

    InstanceEventLog.emit(state.instance_id, "siege_started", %{
      system_id: data.id,
      character_id: character_id,
      payload: %{type: type, duration: duration, besieger_id: character_id}
    })

    if data.owner do
      case data.status do
        :inhabited_player -> Game.cast(data.instance_id, :player, data.owner.id, {:update_system, data})
        :inhabited_dominion -> Game.cast(data.instance_id, :player, data.owner.id, {:update_dominion, data})
        _ -> nil
      end

      Game.cast(state.instance_id, :player, data.owner.id, {:push_notifs, notif})
    end

    {:noreply, %{state | data: data}}
  end

  @decorate tick()
  def on_cast({:cancel_ordered_ships, character_id}, state) do
    data = StellarSystem.cancel_ordered_ships(state.data, character_id)

    if data.owner do
      Game.cast(state.instance_id, :player, data.owner.id, {:update_system, data})
    end

    {:noreply, %{state | data: data}}
  end

  @decorate tick()
  def on_cast({:add_happiness_penalty, reason, value}, state) do
    {change, notifs, data} = StellarSystem.add_happiness_penalty(state.data, reason, value)
    cast_hook(state.instance_id, {change, notifs, data})

    {:noreply, %{state | data: data}}
  end

  @decorate tick()
  def on_info(:tick, state) do
    {:noreply, state}
  end

  defp do_next_tick(state, next_tick) do
    {change, notifs, data} = StellarSystem.next_tick(state.data, next_tick)
    cast_hook(state.instance_id, {change, notifs, data})

    {%{state | data: data}, StellarSystem}
  end

  defp cast_hook(instance_id, {change, notifs, data}) do
    handle_siege_orphan(instance_id, change, data)

    if MapSet.member?(change, :remove_contact) do
      Game.cast(instance_id, :victory, :master, {:remove_informer, data.id})
    end

    if MapSet.member?(change, :population_class_update) do
      Game.cast(instance_id, :galaxy, :master, {:update_system_population_class, data})
    end

    if data.owner != nil do
      if MapSet.member?(change, :player_update) do
        case data.status do
          :inhabited_player -> Game.cast(instance_id, :player, data.owner.id, {:update_system, data})
          :inhabited_dominion -> Game.cast(instance_id, :player, data.owner.id, {:update_dominion, data})
          _ -> nil
        end
      end

      if MapSet.member?(change, :radar_update) do
        Game.cast(instance_id, :victory, :master, {:radar_update, data})
      end

      if not Enum.empty?(notifs) do
        Game.cast(instance_id, :player, data.owner.id, {:push_notifs, notifs})
      end

      change
      |> Enum.filter(fn
        {:ship_built, _item, _initial_xp} -> true
        _ -> false
      end)
      |> Enum.each(fn {:ship_built, item, initial_xp} ->
        Game.cast(instance_id, :character, item.target_id, {:put_ship, item.tile_id, initial_xp})
      end)
    end
  end

  # The tick-sweep in StellarSystem.update_siege/2 releases a siege
  # whose besieging fleet has vanished and tags the change set with
  # `{:siege_orphaned, besieger_id}`. Surface it loudly (so the
  # upstream leak gets found) and record it durably; the siege itself
  # is already cleared in `data`.
  defp handle_siege_orphan(instance_id, change, data) do
    orphan =
      Enum.find(change, fn
        {:siege_orphaned, _besieger_id} -> true
        _ -> false
      end)

    case orphan do
      {:siege_orphaned, besieger_id} ->
        Logger.warning(
          "orphaned siege released by tick-sweep " <>
            "(instance=#{instance_id}, system=#{data.id}, besieger=#{besieger_id}) — " <>
            "besieging fleet was no longer in-system; a release path was missed upstream"
        )

        InstanceEventLog.emit(instance_id, "siege_orphaned_released", %{
          system_id: data.id,
          character_id: besieger_id,
          payload: %{besieger_id: besieger_id}
        })

        notify_owner_update(instance_id, data)

      _ ->
        :ok
    end
  end

  # Push a freshened system snapshot to its owner. Mirrors the inline
  # owner-update casts used by besiege/release so siege state changes
  # (and the production penalties they toggle) reach the client.
  defp notify_owner_update(instance_id, data) do
    if data.owner do
      case data.status do
        :inhabited_player -> Game.cast(instance_id, :player, data.owner.id, {:update_system, data})
        :inhabited_dominion -> Game.cast(instance_id, :player, data.owner.id, {:update_dominion, data})
        _ -> nil
      end
    end
  end
end

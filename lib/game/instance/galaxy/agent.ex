defmodule Instance.Galaxy.Agent do
  use Core.TickServer

  alias Instance.Galaxy.Galaxy
  alias Instance.Galaxy.StellarSystem
  alias Portal.Controllers.GlobalChannel

  @decorate tick()
  def on_call(:get_state, _from, state) do
    {:reply, {:ok, state.data}, state}
  end

  @decorate tick()
  def on_call({:check_jump, from_system_id, to_system_id}, _, state) do
    case Galaxy.check_jump(state.data, from_system_id, to_system_id) do
      :invalid_jump -> {:reply, :invalid_jump, state}
      data -> {:reply, data, state}
    end
  end

  @decorate tick()
  def on_call({:check_system_takeability, system_id, faction_key}, _, state) do
    result = Galaxy.check_system_takeability(state.data, system_id, faction_key)
    {:reply, result, state}
  end

  @decorate tick()
  def on_call({:get_closest_system, system_id}, _, state) do
    target_id = Galaxy.get_closest_system(state.data, system_id)
    {:reply, target_id, state}
  end

  # Lightweight lookup for the news pipeline: sector name without
  # shipping the whole galaxy struct across process boundaries.
  @decorate tick()
  def on_call({:get_sector_name, sector_id}, _, state) do
    sector = Enum.find(state.data.sectors, fn s -> s.id == sector_id end)
    {:reply, {:ok, sector && sector.name}, state}
  end

  # Stage 7 F8. Galaxy.Agent is a per-instance SINGLETON, so a crash
  # here blocks every player in the instance until restart. The
  # three handlers below cross-call StellarSystem.Agent; if that
  # callee crashed mid-call, F6 now returns {:error, :callee_crashed}
  # (or :process_not_found) instead of cascading an :exit. We
  # explicitly reply with the error rather than feeding it into
  # StellarSystem.convert/1, which would raise on a non-struct
  # input and tear the Galaxy.Agent down.
  defp claim_error?(:process_not_found), do: true
  defp claim_error?({:error, _}), do: true
  defp claim_error?(_), do: false

  @decorate tick()
  def on_call({:claim_initial_system, player}, _, state) do
    system = Galaxy.get_initial_system(state.data, player.faction, state.instance_id)
    result = Game.call(state.instance_id, :stellar_system, system.id, {:claim, player, true, false})

    if claim_error?(result) do
      {:reply, {:error, :downstream_unavailable}, state}
    else
      new_system = StellarSystem.convert(result)
      state = update_system_with_hook(state, new_system)
      {:reply, result, state}
    end
  end

  @decorate tick()
  def on_call({:claim_system, player, system_id, is_dominion}, _, state) do
    case Galaxy.get_system(state.data, system_id) do
      {:ok, system} ->
        result = Game.call(state.instance_id, :stellar_system, system.id, {:claim, player, false, is_dominion})

        if claim_error?(result) do
          {:reply, {:error, :downstream_unavailable}, state}
        else
          new_system = StellarSystem.convert(result)
          state = update_system_with_hook(state, new_system)
          {:reply, {:ok, result}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @decorate tick()
  def on_call({:abandon_system, system_id}, _, state) do
    case Galaxy.get_system(state.data, system_id) do
      {:ok, system} ->
        result = Game.call(state.instance_id, :stellar_system, system.id, {:abandon})

        if claim_error?(result) do
          {:reply, {:error, :downstream_unavailable}, state}
        else
          new_system = StellarSystem.convert(result)
          state = update_system_with_hook(state, new_system)
          {:reply, {:ok, result}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def on_call(:get_behavior_tree, _, state) do
    {:reply, {:ok, state.data.behavior_tree}, state}
  end

  @decorate tick()
  def on_cast({:add_player, player}, state) do
    data = Galaxy.add_player(state.data, player)
    GlobalChannel.broadcast_change(state.channel, %{global_galaxy_player: data.players})
    {:noreply, %{state | data: data}}
  end

  @decorate tick()
  def on_cast({:update_system_population_class, system}, state) do
    new_system = StellarSystem.convert(system)
    state = update_system_with_hook(state, new_system)
    {:noreply, state}
  end

  @decorate tick()
  def on_cast({:update_contacts, faction_key, contacts}, state) do
    visibility_count =
      state.data.stellar_systems
      |> Enum.filter(fn s -> s.owner != nil and s.faction != faction_key end)
      |> Enum.reduce(0, fn s, acc ->
        visibility = Map.get(contacts, s.id, Core.VisibilityValue.new())
        acc + visibility.value
      end)

    Game.cast(
      state.instance_id,
      :victory,
      :master,
      {:update_visibility, faction_key, visibility_count, state.data.players}
    )

    {:noreply, state}
  end

  @decorate tick()
  def on_info(:tick, state) do
    {:noreply, state}
  end

  defp do_next_tick(state, elapsed_time) do
    {change, data} = Galaxy.next_tick(state.data, elapsed_time)

    if MapSet.member?(change, :sectors_update) do
      GlobalChannel.broadcast_change(state.channel, %{global_galaxy_sector: data.sectors})
    end

    {%{state | data: data}, Galaxy}
  end

  defp update_system_with_hook(state, new_system) do
    {data, {status, new_sector, old_sector}} = Galaxy.update_stellar_system(state.data, new_system)

    if status == :changed do
      Game.cast(state.instance_id, :victory, :master, {:update_sector, new_sector, data.players})
      GlobalChannel.broadcast_change(state.channel, %{global_galaxy_sector: data.sectors})

      if state.speed != :fast do
        new_owner = new_sector.owner
        new_faction_data = Data.Querier.one(Data.Game.Faction, state.instance_id, new_owner)
        new_theme = if is_nil(new_faction_data), do: nil, else: new_faction_data.theme

        old_owner = old_sector.owner
        old_faction_data = Data.Querier.one(Data.Game.Faction, state.instance_id, old_owner)
        old_theme = if is_nil(old_faction_data), do: nil, else: old_faction_data.theme

        key =
          cond do
            is_nil(new_owner) -> "sector_update_new"
            is_nil(old_owner) -> "sector_update_old"
            true -> "sector_update"
          end

        RC.PlayerEvents.create(%{
          type: "global",
          key: key,
          data:
            Jason.encode!(%{
              sector: new_sector.name,
              old_faction: old_owner,
              old_theme: old_theme,
              new_faction: new_owner,
              new_theme: new_theme
            }),
          instance_id: state.instance_id
        })
      end
    end

    Game.cast(state.instance_id, :victory, :master, {:update_systems, data.stellar_systems, data.players})
    GlobalChannel.broadcast_change(state.channel, %{global_galaxy_system: new_system})

    %{state | data: data}
  end
end

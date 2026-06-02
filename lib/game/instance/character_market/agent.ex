defmodule Instance.CharacterMarket.Agent do
  use Core.TickServer

  alias Instance.CharacterMarket.CharacterMarket
  alias Portal.Controllers.GlobalChannel

  @decorate tick()
  def on_call(:get_state, _, state) do
    {:reply, {:ok, state.data}, state}
  end

  @decorate tick()
  def on_call(:get_next_character_id, _, state) do
    {counter, data} = CharacterMarket.get_and_increment_character_counter(state.data)

    {:reply, {:ok, counter}, %{state | data: data}}
  end

  @decorate tick()
  def on_call({:sell_character, character_id}, _, state) do
    case CharacterMarket.sell_character(state.data, character_id) do
      {:ok, data, character} ->
        data = CharacterMarket.fill_empty_slots(data)
        GlobalChannel.broadcast_change(state.channel, %{global_character_market: data})

        {:reply, {:ok, character}, %{state | data: data}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  # Hire-character atomicity fix (Stage 4 #C2 follow-up). The previous
  # flow called the destructive `:sell_character` FIRST and then
  # checked affordability on the buyer side; an unaffordable purchase
  # therefore removed the character from the market AND returned an
  # error, producing a "ghost character" indistinguishable from a
  # successful theft from the buyer's perspective.
  #
  # This handler accepts the buyer's resource snapshot together with
  # the character id and decides atomically — within a single
  # CharacterMarket.Agent handle_call body, which is the only place
  # `state.data.slots` can be mutated — whether to take the slot or
  # leave it untouched. Because the market is a singleton GenServer
  # and the buyer's Player.Agent is also single-threaded, no race
  # can interleave between the affordability decision and the slot
  # mutation, and no other buyer can grab the same character ahead
  # of a successful take.
  #
  # `available` is `{credit, technology, ideology}` — the buyer's
  # current DynamicValue.value for each resource pool. The market
  # is the source of truth for canonical costs; the buyer never
  # supplies them.
  @decorate tick()
  def on_call({:sell_if_affordable, character_id, {credit, technology, ideology}}, _, state) do
    case find_character_in_slots(state.data, character_id) do
      nil ->
        {:reply, {:error, :character_unavailable}, state}

      %Instance.Character.Character{} = character ->
        {c_cost, t_cost, i_cost} = canonical_cost(character)

        cond do
          credit < c_cost ->
            {:reply, {:error, :not_enough_credit}, state}

          technology < t_cost ->
            {:reply, {:error, :not_enough_technology}, state}

          ideology < i_cost ->
            {:reply, {:error, :not_enough_ideology}, state}

          true ->
            # All checks passed inside this same handler — commit the
            # sale. The atomicity guarantee is the whole point of this
            # handler existing.
            case CharacterMarket.sell_character(state.data, character_id) do
              {:ok, data, ^character} ->
                data = CharacterMarket.fill_empty_slots(data)
                GlobalChannel.broadcast_change(state.channel, %{global_character_market: data})

                {:reply, {:ok, character}, %{state | data: data}}

              {:error, reason} ->
                # Should be unreachable — find_character_in_slots/2
                # found it less than 10 lines ago in the same handler —
                # but treat it as a clean failure if it ever happens.
                {:reply, {:error, reason}, state}
            end
        end
    end
  end

  defp find_character_in_slots(data, character_id) do
    data.slots
    |> Enum.flat_map(fn %{data: ranks} -> ranks end)
    |> Enum.flat_map(fn %{data: slots} -> slots end)
    |> Enum.find_value(fn slot ->
      if slot.character != nil and slot.character.id == character_id,
        do: slot.character,
        else: false
    end)
  end

  defp canonical_cost(%Instance.Character.Character{} = character) do
    {
      max(character.credit_cost || 0, 0),
      max(character.technology_cost || 0, 0),
      max(character.ideology_cost || 0, 0)
    }
  end

  @decorate tick()
  def on_info(:tick, state) do
    {:noreply, state}
  end

  defp do_next_tick(state, next_tick) do
    {change, data} = CharacterMarket.next_tick(state.data, next_tick)

    if MapSet.member?(change, :update_market) do
      GlobalChannel.broadcast_change(state.channel, %{global_character_market: data})
    end

    {%{state | data: data}, CharacterMarket}
  end
end

defmodule Instance.Player.Market do
  require Logger

  alias Instance.Player.Player
  alias Instance.Character.Character

  def create_offer(state, %{
        "type" => type,
        "data" => data,
        "price" => price,
        "allowed_players" => allowed_players,
        "allowed_factions" => allowed_factions
      })
      when price >= 0 do
    case place_offer(state, type, data) do
      {:ok, state, data, internal, value} ->
        price = Enum.max([price, 0])
        price = Enum.min([price, 1_000_000_000])

        attrs = %{
          type: type,
          data: data,
          internal: internal,
          price: price,
          profile_id: state.id,
          instance_id: state.instance_id,
          value: value
        }

        cond do
          length(allowed_players) > 0 ->
            RC.Offers.create_for_allowed_players(attrs, allowed_players)

          length(allowed_factions) > 0 ->
            RC.Offers.create_for_allowed_factions(attrs, allowed_factions)

          true ->
            RC.Offers.create(attrs)
        end

        {:ok, state}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def create_offer(_state, _args) do
    {:error, :bad_argument}
  end

  # Stage 4 #C4 fix.
  #
  # Replaced the TOCTOU "read status -> verify == active -> update_all_offers_to_sold"
  # sequence with `RC.Offers.transition_status/3`, which performs a
  # conditional UPDATE gated on the row still being in the expected
  # status. Exactly one concurrent caller wins; everyone else aborts
  # with `:stale_status` and is told the offer is no longer available.
  #
  # We also handle `nil` offer cleanly (was a Player.Agent crash via
  # `nil.status` before the with-block even started).
  def cancel_offer(state, offer_id) do
    with %RC.Instances.Offer{} = offer <- RC.Offers.get_offer(offer_id) || :offer_not_found,
         true <- offer.profile_id == state.id || :not_offer_owner,
         {:ok, offer} <- RC.Offers.transition_status(offer, "active", "inactive"),
         {:ok, state} <- unplace_offer(state, offer.type, offer) do
      {:ok, state}
    else
      :offer_not_found -> {:error, :offer_not_found}
      :not_offer_owner -> {:error, :not_offer_owner}
      {:error, :stale_status} -> {:error, :offer_not_active}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :offer_not_found}
    end
  end

  def buy_offer(state, offer_id) do
    # Stage 7 F10. The previous flow already reverted the "sold"
    # DB row on the documented {:error, _} return from
    # `transfer_offer/3`, but any *uncaught* failure (a raise inside
    # `transfer_offer`, an unexpected non-tuple return, an :exit
    # cascading out from before the F6 try/catch landed) would
    # leave the row stuck in "sold" with no buyer credited and no
    # seller payout. Wrapping the inner flow in try/rescue/catch
    # gives us a final safety net: any uncaught failure during a
    # buy attempt reverts the row to "active" before re-surfacing
    # the error. The Player.Agent itself then stays alive — the
    # buyer just gets an :internal_error and can retry.
    try do
      do_buy_offer(state, offer_id)
    rescue
      e ->
        Logger.error(
          "buy_offer crashed mid-flight, reverting offer status",
          offer_id: offer_id,
          error: Exception.message(e),
          stacktrace: Exception.format_stacktrace(__STACKTRACE__)
        )

        revert_status(offer_id, "active")
        {:error, :internal_error}
    catch
      kind, reason ->
        Logger.error(
          "buy_offer exited mid-flight, reverting offer status",
          offer_id: offer_id,
          kind: kind,
          reason: inspect(reason)
        )

        revert_status(offer_id, "active")
        {:error, :internal_error}
    end
  end

  defp do_buy_offer(state, offer_id) do
    c = Data.Querier.one(Data.Game.Constant, state.instance_id, :main)

    with %RC.Instances.Offer{} = offer <- RC.Offers.get_offer(offer_id) || :offer_not_found,
         true <- offer.profile_id != state.id || :cannot_buy_own_offer,
         {:ok, offer} <- RC.Offers.transition_status(offer, "active", "sold"),
         final_price <- offer.price + c.market_taxe * offer.value,
         true <- state.credit.value >= final_price || :not_enough_credit,
         {:ok, state} <- transfer_offer(state, offer.type, offer) do
      state = Player.add_credit(state, -final_price)
      {:ok, state, offer.profile_id, offer.price}
    else
      :offer_not_found ->
        {:error, :offer_not_found}

      :cannot_buy_own_offer ->
        {:error, :cannot_buy_own_offer}

      :not_enough_credit ->
        # We already won the active -> sold transition; revert it so a
        # different (richer) buyer can try. Safe to use plain
        # update_offer_status — no race on the way back since this caller
        # is the only one holding the "sold" state for this row.
        revert_status(offer_id, "active")
        {:error, :not_enough_credit}

      {:error, :stale_status} ->
        {:error, :offer_not_active}

      {:error, reason} ->
        # transfer_offer downstream failed AFTER we won the transition.
        # Push the row back to "active" so the goods aren't lost.
        revert_status(offer_id, "active")
        {:error, reason}

      _error ->
        # Last-resort revert in case some new failure mode escaped the
        # else clauses above.
        revert_status(offer_id, "active")
        {:error, :offer_not_found}
    end
  end

  # Stage 4 #C3 fix.
  #
  # Before: `is_number(amount)` accepted ANY number, including negatives
  # and zero. With amount = -1_000_000, `state.technology.value >= amount`
  # is trivially true, and `Player.add_technology(state, -amount)` minted
  # the absolute value into the seller. The offer was then persisted with
  # `value = amount * 10` (negative), priced at 0, listed as bait nobody
  # would buy. Loop = unbounded resource minting.
  #
  # After: amount must be a positive integer. Same fix for ideology.
  # Safe rollback helper — re-fetches the offer (it may have been deleted
  # between our transition and this revert in edge cases) and only writes
  # if it still exists. Used by buy_offer error paths.
  defp revert_status(offer_id, status) do
    case RC.Offers.get_offer(offer_id) do
      %RC.Instances.Offer{} = o -> RC.Offers.update_offer_status(o, status)
      _ -> :ok
    end
  end

  defp place_offer(state, "technology", data) do
    with true <- Map.has_key?(data, "amount"),
         amount <- Map.get(data, "amount"),
         true <- is_integer(amount) and amount > 0,
         true <- state.technology.value >= amount do
      value = amount * 10
      state = Player.add_technology(state, -amount)
      {:ok, state, Jason.encode!(data), nil, value}
    else
      _ -> {:error, :not_enough_technology}
    end
  end

  defp place_offer(state, "ideology", data) do
    with true <- Map.has_key?(data, "amount"),
         amount <- Map.get(data, "amount"),
         true <- is_integer(amount) and amount > 0,
         true <- state.ideology.value >= amount do
      value = amount * 10
      state = Player.add_ideology(state, -amount)
      {:ok, state, Jason.encode!(data), nil, value}
    else
      _ -> {:error, :not_enough_ideology}
    end
  end

  defp place_offer(state, "character_deck", data) do
    with true <- Map.has_key?(data, "character_id"),
         character_id <- Map.get(data, "character_id"),
         character <- Enum.find(state.character_deck, fn %{character: c} -> c.id == character_id end) do
      %{cooldown: nil, character: character} = character
      value = character.level * 50_000
      data = Map.put(data, "character", character)

      character_deck =
        Enum.map(state.character_deck, fn character_cd ->
          if character_cd.character.id == character_id,
            do: %{character_cd | character: Character.set_on_sold(character_cd.character)},
            else: character_cd
        end)

      state = %{state | character_deck: character_deck}
      {:ok, state, Jason.encode!(data), :erlang.term_to_binary(character), value}
    else
      _ -> {:error, :error}
    end
  end

  defp place_offer(state, "board_character", data) do
    with true <- Map.has_key?(data, "character_id"),
         character_id <- Map.get(data, "character_id"),
         true <- Player.own_character?(state, character_id),
         player_character <- Enum.find(state.characters, fn c -> c.id == character_id end),
         true <- player_character.status == :on_board and player_character.action_status == :idle,
         {:ok, character} <- Game.call(state.instance_id, :character, character_id, {:set_on_sold}) do
      state = Player.update_character(state, character)
      maintenance = if character.type == :admiral, do: character.army.maintenance.value * 250, else: 0
      value = character.level * 50_000 + maintenance
      data = Map.put(data, "character", character)

      {:ok, state, Jason.encode!(data), :erlang.term_to_binary(character), trunc(value)}
    else
      {:error, error} -> {:error, error}
      _ -> {:error, :error}
    end
  end

  defp unplace_offer(state, "technology", offer) do
    data = Jason.decode!(offer.data)
    state = Player.add_technology(state, Map.get(data, "amount"))
    {:ok, state}
  end

  defp unplace_offer(state, "ideology", offer) do
    data = Jason.decode!(offer.data)
    state = Player.add_ideology(state, Map.get(data, "amount"))
    {:ok, state}
  end

  defp unplace_offer(state, "character_deck", offer) do
    data = Jason.decode!(offer.data)
    character_id = Map.get(data, "character_id")

    character_deck =
      Enum.map(state.character_deck, fn character_cd ->
        if character_cd.character.id == character_id,
          do: %{character_cd | character: Character.unset_on_sold(character_cd.character)},
          else: character_cd
      end)

    state = %{state | character_deck: character_deck}
    {:ok, state}
  end

  defp unplace_offer(state, "board_character", offer) do
    data = Jason.decode!(offer.data)
    character_id = Map.get(data, "character_id")
    {:ok, character} = Game.call(state.instance_id, :character, character_id, {:unset_on_sold})
    state = Player.update_character(state, character)
    {:ok, state}
  end

  defp transfer_offer(state, "technology", offer) do
    data = Jason.decode!(offer.data)
    state = Player.add_technology(state, Map.get(data, "amount"))
    {:ok, state}
  end

  defp transfer_offer(state, "ideology", offer) do
    data = Jason.decode!(offer.data)
    state = Player.add_ideology(state, Map.get(data, "amount"))
    {:ok, state}
  end

  defp transfer_offer(state, "character_deck", offer) do
    data = Jason.decode!(offer.data)

    with :ok <- Player.check_hire_character(state, {0, 0, 0}) do
      character = :erlang.binary_to_term(offer.internal)
      character_id = Map.get(data, "character_id")

      new_owner = Instance.Character.Player.convert(state)
      character = %{character | owner: new_owner}
      character_deck = [%{cooldown: nil, character: character} | state.character_deck]
      state = %{state | character_deck: character_deck}
      Game.call(state.instance_id, :player, offer.profile_id, {:dismiss_character, character_id})

      {:ok, state}
    else
      {:error, error} -> {:error, error}
      _ -> {:error, :error}
    end
  end

  defp transfer_offer(state, "board_character", offer) do
    data = Jason.decode!(offer.data)
    character = :erlang.binary_to_term(offer.internal)
    character_id = Map.get(data, "character_id")

    with true <- Player.character_available_slots?(state, character.type),
         {:ok, _} <- Game.call(state.instance_id, :character, character_id, {:update_owner, state}),
         {:ok, character} <- Game.call(state.instance_id, :character, character_id, {:unset_on_sold}),
         {:ok, _} <- Game.call(state.instance_id, :player, offer.profile_id, {:transfer_character, character_id}) do
      characters = state.characters ++ [Instance.Player.Character.convert(character)]
      state = %{state | characters: characters}

      {:ok, state}
    else
      {:error, error} -> {:error, error}
      _ -> {:error, :not_enough_agents_slot}
    end
  end
end

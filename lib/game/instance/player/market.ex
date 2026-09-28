defmodule Instance.Player.Market do
  @moduledoc """
  The player market. Offers come in three modes, stored as `"mode"` in the
  offer's JSON `data` (rows without it predate the modes and are trades):

    * `"trade"` — the classic listing: technology, ideology or an agent for
      a credit price. The buyer pays price + tax; the poster gets the price.
    * `"donation"` — Mutual Aid. Credits, technology, ideology or an agent
      given to the team, no price: the claimer receives it whole and pays
      the tax on top.
    * `"request"` — Mutual Aid. A player asks the team for credits,
      technology or ideology. Nothing is escrowed at posting; whoever
      fulfils it pays the requested amount plus the tax, and the requester
      receives exactly the amount asked for.

  The tax is always paid by whoever completes the offer (see `tax/2`); the
  poster only escrows the goods (refunded on cancel).

  Audience: Mutual Aid offers only ever reach the poster's own faction
  (optionally narrowed to named players of that faction). Trades do the same
  in matches with two factions or fewer; with three or more, the poster
  picks the audience freely. Taking an offer re-checks the audience, so an
  offer id alone cannot be used to take an offer one could not see.

  Tax (`tax/2`):
    * technology / ideology: 1 credit per point exchanged, or `market_taxe`
      (10%) of the price, whichever is greater — most team listings are
      free, while a steep price to another faction carries a steeper tax;
    * credits: `market_taxe` (10%) of the credits exchanged, on top;
    * agents: `market_taxe` of the agent's valuation (level × 50 000, plus
      fleet upkeep × 250 for a Navarch on assignment).

  The stored offer `value` keeps its historical scale (10 per point, 1 per
  credit, the agent valuation); before these rules the tax was always
  `market_taxe × value`, i.e. 1 credit per point whatever the price.
  """

  require Logger

  alias Instance.Player.Player
  alias Instance.Character.Character

  @resources ["credit", "technology", "ideology"]
  @agents ["character_deck", "board_character"]
  @unit_value %{"credit" => 1, "technology" => 10, "ideology" => 10}
  @tax_per_point 1
  @max_amount 1_000_000_000

  @offer_fields [:id, :type, :status, :data, :value, :price, :profile_id, :inserted_at]

  @doc """
  Offers as client maps. Agents listed from the field (`board_character`)
  gain `live`: where they are now, their current fleet, and whether they can
  still be bought — the listing's `data.character` is a snapshot from
  posting time, and the poster is often offline to ask. A listed agent can't
  take actions, but it can still die or be captured.
  """
  def with_live_agents(offers, instance_id) do
    Enum.map(offers, fn offer ->
      map = Map.take(offer, @offer_fields)

      if offer.type == "board_character",
        do: Map.put(map, :live, live_agent(instance_id, offer)),
        else: map
    end)
  end

  defp live_agent(instance_id, offer) do
    character_id = offer.data |> Jason.decode!() |> Map.get("character_id")

    case safe_get_character(instance_id, character_id) do
      {:ok, %{status: :on_board, owner: %{id: owner_id}} = character} when owner_id == offer.profile_id ->
        %{available: true, system_id: character.system, character: character}

      _ ->
        %{available: false, system_id: nil, character: nil}
    end
  end

  defp safe_get_character(instance_id, character_id) do
    Game.call(instance_id, :character, character_id, :get_state)
  catch
    _, _ -> :error
  end

  @doc "Offer mode stored in `data`; offers from before the modes are trades."
  def offer_mode(%{data: data}) when is_binary(data) do
    case Jason.decode(data) do
      {:ok, %{"mode" => mode}} when mode in ["donation", "request"] -> mode
      _ -> "trade"
    end
  end

  def offer_mode(_), do: "trade"

  def create_offer(state, args) when is_map(args) do
    # Final safety net around the whole placement flow. `place_offer` and
    # the offer-persistence steps run inside the seller's Player.Agent; an
    # uncaught raise/exit here used to crash that agent and revert the
    # player to their genesis state. Any unexpected failure now surfaces as
    # an error tuple and leaves the agent (and the player's progress) alive.
    try do
      do_create_offer(state, args)
    rescue
      e ->
        Logger.error(
          "create_offer crashed mid-flight, aborting",
          error: Exception.message(e),
          stacktrace: Exception.format_stacktrace(__STACKTRACE__)
        )

        {:error, :internal_error}
    catch
      kind, reason ->
        Logger.error(
          "create_offer exited mid-flight, aborting",
          kind: kind,
          reason: inspect(reason)
        )

        {:error, :internal_error}
    end
  end

  def create_offer(_state, _args), do: {:error, :bad_argument}

  defp do_create_offer(state, %{"type" => type, "data" => data} = args) when is_map(data) do
    mode = Map.get(args, "mode", "trade")

    with :ok <- validate_mode(mode, type),
         {:ok, price} <- offer_price(mode, Map.get(args, "price")),
         data = Map.put(data, "mode", mode),
         {:ok, placed, encoded, internal, value} <- place(state, mode, type, data) do
      attrs = %{
        type: type,
        data: encoded,
        internal: internal,
        price: price,
        profile_id: state.id,
        instance_id: state.instance_id,
        value: value
      }

      allowed_players = id_list(Map.get(args, "allowed_players"))
      allowed_factions = id_list(Map.get(args, "allowed_factions"))

      # Placement has succeeded in memory only (the agent discards `placed`
      # on error), except for an on-board agent, whose character agent was
      # already flagged on_sold — undo that if the offer cannot be stored.
      case publish(state, mode, attrs, allowed_players, allowed_factions) do
        :ok ->
          {:ok, placed}

        {:error, reason} ->
          if type == "board_character", do: release_board_character(state, data)
          {:error, reason}
      end
    end
  end

  defp do_create_offer(_state, _args), do: {:error, :bad_argument}

  @doc """
  Tax owed by whoever completes `offer` (buyer, claimer or fulfiller):
  the greater of 1 credit per technology/ideology point and `market_taxe` of
  the price; `market_taxe` of credits exchanged; `market_taxe` of an agent's
  valuation.
  """
  def tax(%{type: type} = offer, market_taxe) when type in ["technology", "ideology"],
    do: max(offer_amount(offer) * @tax_per_point, (offer.price || 0) * market_taxe)

  def tax(%{type: "credit"} = offer, market_taxe), do: offer_amount(offer) * market_taxe
  def tax(%{value: value}, market_taxe), do: value * market_taxe

  defp offer_amount(offer), do: offer.data |> Jason.decode!() |> Map.get("amount")

  defp validate_mode("trade", type) when type in ["technology", "ideology" | @agents], do: :ok
  defp validate_mode("donation", type) when type in @resources or type in @agents, do: :ok
  defp validate_mode("request", type) when type in @resources, do: :ok
  defp validate_mode(_mode, _type), do: {:error, :bad_argument}

  # Mutual Aid never carries a price.
  defp offer_price("trade", price) when is_number(price) and price >= 0,
    do: {:ok, price |> trunc() |> min(@max_amount)}

  defp offer_price("trade", _price), do: {:error, :bad_argument}
  defp offer_price(_mode, _price), do: {:ok, 0}

  defp id_list(ids) when is_list(ids), do: Enum.filter(ids, &is_integer/1)
  defp id_list(_), do: []

  defp publish(state, mode, attrs, allowed_players, allowed_factions) do
    try do
      with {:ok, audience} <- resolve_audience(state, mode, allowed_players, allowed_factions),
           {:ok, _offer} <- insert_offer(attrs, audience) do
        :ok
      else
        {:error, %Ecto.Changeset{}} -> {:error, :internal_error}
        {:error, reason} -> {:error, reason}
      end
    rescue
      e ->
        Logger.error("create_offer could not publish the offer", error: Exception.message(e))
        {:error, :internal_error}
    end
  end

  @doc """
  Who may see and take an offer. Mutual Aid (and every trade in a match with
  two factions or fewer) is locked to the poster's faction; named players
  must then belong to it.
  """
  def resolve_audience(state, mode, allowed_players, allowed_factions) do
    locked? = mode != "trade" or RC.Offers.faction_count(state.instance_id) <= 2

    cond do
      allowed_players != [] ->
        if locked? and not RC.Offers.all_in_faction?(state.instance_id, allowed_players, state.faction_id),
          do: {:error, :market_player_not_in_faction},
          else: {:ok, {:players, allowed_players}}

      locked? ->
        {:ok, {:factions, [state.faction_id]}}

      allowed_factions != [] ->
        {:ok, {:factions, allowed_factions}}

      true ->
        {:ok, :public}
    end
  end

  defp insert_offer(attrs, {:players, players}), do: RC.Offers.create_for_allowed_players(attrs, players)
  defp insert_offer(attrs, {:factions, factions}), do: RC.Offers.create_for_allowed_factions(attrs, factions)
  defp insert_offer(attrs, :public), do: RC.Offers.create(attrs)

  defp release_board_character(state, data) do
    Game.call(state.instance_id, :character, Map.get(data, "character_id"), {:unset_on_sold})
  catch
    _, _ -> :ok
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
         {:ok, state} <- unplace(state, offer_mode(offer), offer) do
      {:ok, state}
    else
      :offer_not_found -> {:error, :offer_not_found}
      :not_offer_owner -> {:error, :not_offer_owner}
      {:error, :stale_status} -> {:error, :offer_not_active}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :offer_not_found}
    end
  end

  @doc """
  Take an offer: buy a trade, claim a donation or fulfil a request.

  Returns `{:ok, state, poster_id, {credit, technology, ideology}, mode}` —
  the tuple is what the poster receives.
  """
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
         true <- offer.instance_id == state.instance_id || :offer_not_found,
         true <- offer.profile_id != state.id || :cannot_buy_own_offer,
         true <- RC.Offers.visible_to?(offer, state.id, state.faction_id) || :offer_not_found,
         true <- not war_embargoed?(state, offer) || :war_embargo,
         {:ok, offer} <- RC.Offers.transition_status(offer, "active", "sold"),
         mode = offer_mode(offer),
         {:ok, state, payout} <- settle(state, mode, offer, tax(offer, c.market_taxe)) do
      {:ok, state, offer.profile_id, payout, mode}
    else
      :offer_not_found ->
        {:error, :offer_not_found}

      :cannot_buy_own_offer ->
        {:error, :cannot_buy_own_offer}

      :war_embargo ->
        {:error, :war_embargo}

      {:error, :stale_status} ->
        {:error, :offer_not_active}

      {:error, reason} ->
        # We already won the active -> sold transition (a failed
        # affordability check or a downstream transfer failure). Push the
        # row back to "active" so a different taker can try and the goods
        # aren't lost. No race on the way back: this caller is the only one
        # holding the "sold" state for this row.
        revert_status(offer_id, "active")
        {:error, reason}

      _error ->
        # Last-resort revert in case some new failure mode escaped the
        # else clauses above.
        revert_status(offer_id, "active")
        {:error, :offer_not_found}
    end
  end

  # Fulfilling a request: the taker hands over the requested amount and pays
  # the fee; the requester receives the amount.
  defp settle(state, "request", offer, fee) do
    amount = offer_amount(offer)
    credit_cost = fee + if(offer.type == "credit", do: amount, else: 0)

    cond do
      state.credit.value < credit_cost ->
        {:error, :not_enough_credit}

      offer.type == "technology" and state.technology.value < amount ->
        {:error, :not_enough_technology}

      offer.type == "ideology" and state.ideology.value < amount ->
        {:error, :not_enough_ideology}

      true ->
        state = Player.add_credit(state, -credit_cost)

        case offer.type do
          "credit" -> {:ok, state, {amount, 0, 0}}
          "technology" -> {:ok, Player.add_technology(state, -amount), {0, amount, 0}}
          "ideology" -> {:ok, Player.add_ideology(state, -amount), {0, 0, amount}}
        end
    end
  end

  # Claiming donated credits: the claimer receives them whole and pays the
  # tax on top — out of the same credits, so no prior balance is needed.
  defp settle(state, "donation", %{type: "credit"} = offer, fee) do
    {:ok, Player.add_credit(state, offer_amount(offer) - fee), {0, 0, 0}}
  end

  # Trades and every other donation: pay the price (0 for donations) + tax.
  defp settle(state, _mode, offer, fee) do
    final_price = offer.price + fee

    with true <- state.credit.value >= final_price || {:error, :not_enough_credit},
         {:ok, state} <- transfer_offer(state, offer.type, offer) do
      {:ok, Player.add_credit(state, -final_price), {offer.price, 0, 0}}
    end
  end

  # War embargo: players may not buy from a faction their own faction is
  # at war with (design: docs/faction-government.md §4). Government-level
  # resource transfers are exempt by design — they don't go through this
  # market. Fails open: if the seller's faction or the diplomacy agent
  # can't be resolved (pre-diplomacy instances), trade proceeds.
  defp war_embargoed?(state, offer) do
    seller_faction_id = RC.Registrations.get_faction_id(state.instance_id, offer.profile_id)

    if seller_faction_id == nil or seller_faction_id == state.faction_id do
      false
    else
      try do
        {:ok, :war} ==
          Game.call(state.instance_id, :diplomacy, :master, {:stance, state.faction_id, seller_faction_id})
      catch
        _, _ -> false
      end
    end
  end

  # Safe rollback helper — re-fetches the offer (it may have been deleted
  # between our transition and this revert in edge cases) and only writes
  # if it still exists. Used by buy_offer error paths.
  defp revert_status(offer_id, status) do
    case RC.Offers.get_offer(offer_id) do
      %RC.Instances.Offer{} = o -> RC.Offers.update_offer_status(o, status)
      _ -> :ok
    end
  end

  # Requests escrow nothing; everything else goes through place_offer.
  defp place(state, "request", type, data) do
    case valid_amount(data) do
      {:ok, amount} -> {:ok, state, Jason.encode!(data), nil, amount * @unit_value[type]}
      :error -> {:error, :bad_argument}
    end
  end

  defp place(state, _mode, type, data), do: place_offer(state, type, data)

  defp valid_amount(data) do
    case Map.get(data, "amount") do
      amount when is_integer(amount) and amount > 0 and amount <= @max_amount -> {:ok, amount}
      _ -> :error
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
  # After: amount must be a positive integer. Same fix for ideology and
  # donated credits.
  defp place_offer(state, "credit", data) do
    with {:ok, amount} <- valid_amount(data),
         true <- state.credit.value >= amount do
      state = Player.add_credit(state, -amount)
      {:ok, state, Jason.encode!(data), nil, amount * @unit_value["credit"]}
    else
      _ -> {:error, :not_enough_credit}
    end
  end

  defp place_offer(state, "technology", data) do
    with {:ok, amount} <- valid_amount(data),
         true <- state.technology.value >= amount do
      state = Player.add_technology(state, -amount)
      {:ok, state, Jason.encode!(data), nil, amount * @unit_value["technology"]}
    else
      _ -> {:error, :not_enough_technology}
    end
  end

  defp place_offer(state, "ideology", data) do
    with {:ok, amount} <- valid_amount(data),
         true <- state.ideology.value >= amount do
      state = Player.add_ideology(state, -amount)
      {:ok, state, Jason.encode!(data), nil, amount * @unit_value["ideology"]}
    else
      _ -> {:error, :not_enough_ideology}
    end
  end

  defp place_offer(state, "character_deck", data) do
    # A deck card carries a cooldown that is `nil` (never deployed) OR a
    # %Core.CooldownValue{} once it has been deployed and recalled — the
    # recall cooldown ticks down to `value: 0` but is never reset back to
    # `nil` (see Player.next_tick). The old code hard-matched
    # `%{cooldown: nil, character: character} = card`, which RAISED a
    # MatchError for any previously-deployed card, crashing the seller's
    # Player.Agent (and, via the crash path, wiping the player back to
    # their join-time genesis state). Treat a card as sellable when its
    # cooldown is nil or expired, and reject a still-locked card cleanly.
    with true <- Map.has_key?(data, "character_id"),
         character_id <- Map.get(data, "character_id"),
         %{character: character} = card <-
           Enum.find(state.character_deck, fn %{character: c} -> c.id == character_id end) ||
             :character_unavailable,
         false <- deck_card_locked?(card) do
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
      :character_unavailable -> {:error, :character_unavailable}
      true -> {:error, :character_on_cooldown}
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

  # A deck card is free to be listed when it has no cooldown or its recall
  # cooldown has fully ticked down (value 0). A card still on cooldown is not.
  defp deck_card_locked?(%{cooldown: nil}), do: false
  defp deck_card_locked?(%{cooldown: %Core.CooldownValue{} = cd}), do: Core.CooldownValue.locked?(cd)
  defp deck_card_locked?(_), do: false

  defp unplace(state, "request", _offer), do: {:ok, state}

  defp unplace(state, _mode, offer), do: unplace_offer(state, offer.type, offer)

  defp unplace_offer(state, "credit", offer) do
    data = Jason.decode!(offer.data)
    {:ok, Player.add_credit(state, Map.get(data, "amount"))}
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

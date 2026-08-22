defmodule Instance.Player.Agent do
  use Core.TickServer

  require Logger

  alias Instance.Character.{ActionQueue, Character}
  alias Instance.Player.ArmadaImpl
  alias Instance.Player.Player
  alias Instance.Player.Market
  alias Instance.StellarSystem.StellarSystem
  alias Portal.Controllers.PlayerChannel

  # Wall-clock cadence for the daily-challenge leaderboard safety net.
  @daily_autosave_ms 60_000

  @decorate tick()
  def on_call(:get_state, _from, state) do
    {:reply, {:ok, state.data}, state}
  end

  # Stress-test bot cheat. Reached only via CheatChannel, which refuses to
  # join unless the calling account is a bot (`is_bot = true`) or the game
  # creator of a cheats-enabled instance. The agent itself trusts that gate
  # — there is no other production caller for this clause.
  @decorate tick()
  def on_call({:cheat, :grant_resources, amounts}, _from, state) do
    %{credit: c, technology: t, ideology: i} = amounts

    data = state.data

    data = %{
      data
      | credit: Core.DynamicValue.add_value(data.credit, c),
        technology: Core.DynamicValue.add_value(data.technology, t),
        ideology: Core.DynamicValue.add_value(data.ideology, i)
    }

    PlayerChannel.broadcast_change(state.channel, %{player_player: data})
    {:reply, :ok, %{state | data: data}}
  end

  # CHEAT (creator-only, gated at the CheatChannel AND on the instance's
  # cheats_enabled metadata): instantly settle a system for this player.
  # Mirrors the {:claim_system, _} cast — the full authoritative chain
  # (galaxy -> stellar_system claim/convert -> victory radar update ->
  # bonus re-apply -> broadcasts) — but as a call so the cheat UI gets a
  # result, and without the system-slot cap (it's a debug tool). The
  # CheatChannel only routes here for systems with no current player
  # owner, so no {:lose_system, _} bookkeeping is needed.
  @decorate tick()
  def on_call({:cheat_claim_system, system_id}, _, state) do
    with true <- Instance.Cheats.enabled?(state.instance_id) or {:error, :cheats_disabled},
         {:ok, system} <- Game.call(state.instance_id, :galaxy, :master, {:claim_system, state.data, system_id, false}),
         {:ok, data} <- Player.add_stellar_system(state.data, system) do
      # update newly claimed system with existing bonuses
      system_bonuses = Player.extract_bonus(data, [:stellar_system])
      system = Game.call(state.instance_id, :stellar_system, system.id, {:update_bonuses, :player, system_bonuses})
      data = Player.update_stellar_system(data, system)

      PlayerChannel.broadcast_change(state.channel, %{player_player: data})
      {:reply, :ok, %{state | data: data}}
    else
      {:error, reason} ->
        Logger.error(":cheat_claim_system #{inspect(reason)}")
        {:reply, {:error, reason}, state}

      reason ->
        Logger.error(":cheat_claim_system #{inspect(reason)}")
        {:reply, {:error, :claim_failed}, state}
    end
  end

  # CHEAT: clear this player's policy/doctrine re-lock cooldown.
  @decorate tick()
  def on_call(:cheat_clear_policies_cooldown, _, state) do
    if Instance.Cheats.enabled?(state.instance_id) do
      data = %{state.data | policies_cooldown: Core.CooldownValue.new()}
      PlayerChannel.broadcast_change(state.channel, %{player_player: data})
      {:reply, :ok, %{state | data: data}}
    else
      {:reply, {:error, :cheats_disabled}, state}
    end
  end

  def on_call(:get_public_state, _from, state) do
    db_profile = RC.Accounts.get_profile(state.data.id)
    public_player = Instance.Player.PublicPlayer.new(state.data, db_profile)

    {:reply, {:ok, public_player}, state}
  end

  def on_call({:update_client_status, status}, _from, state) do
    data = Player.update_client_status(state.data, status)

    # Daily: start the economy on the first client connect (deferred from boot)
    # so the 3-minute clock doesn't run while the browser is still loading.
    # ensure_started/1 is idempotent — reconnects are no-ops.
    if status == :connect and Instance.Mutators.daily?(state.instance_id) do
      Daily.Boot.ensure_started(state.instance_id)
    end

    if data.connected_clients > 0 do
      {notifs, data} = Player.flush_notification(data)

      unless Enum.empty?(notifs), do: PlayerChannel.broadcast_change(state.channel, %{player_notifs: notifs})

      {:reply, :ok, %{state | data: data}}
    else
      # Last client left. For a daily we do nothing here — no score write, no
      # teardown. The instance keeps running so the player can reconnect and
      # continue; the wall-clock autosave (which fires server-side regardless of
      # the client) is the crash/connection-loss safety net. The final score is
      # written only at the deadline (Daily.Boot.finalize/1) or on an explicit
      # Exit (Daily.Boot.quit/1) — never on a mere disconnect.
      {:reply, :ok, %{state | data: data}}
    end
  end

  @decorate tick()
  def on_call(:claim_initial_system, _, state) do
    system = Game.call(state.instance_id, :galaxy, :master, {:claim_initial_system, state.data})
    {:ok, data} = Player.add_stellar_system(state.data, system)

    system_bonuses = Player.extract_bonus(data, [:stellar_system])
    system = Game.call(state.instance_id, :stellar_system, system.id, {:update_bonuses, :player, system_bonuses})
    data = Player.update_stellar_system(data, system)

    {:reply, data, %{state | data: data}}
  end

  @decorate tick()
  def on_call({:transform_system_to_dominion, system_id}, _, state) do
    with true <- Player.own_system?(state.data, system_id),
         true <- Player.can_transform_system(state.data),
         true <- Player.can_remove_stellar_system(state.data),
         true <- Player.can_add_dominion(state.data),
         {:ok, system} <- Game.call(state.instance_id, :galaxy, :master, {:claim_system, state.data, system_id, true}),
         {:ok, data} <- prepare_leaving_system(state, system_id),
         {:ok, data} <- Player.pay_transform_system(data),
         {:ok, data} <- Player.remove_stellar_system(data, system_id),
         {:ok, data} <- Player.add_dominion(data, system) do
      PlayerChannel.broadcast_change(state.channel, %{player_player: data})
      {:reply, :ok, %{state | data: data}}
    else
      false ->
        {:reply, {:error, :system_not_found}, state}

      {:error, reason} ->
        Logger.error(":transform_system_to_dominion #{inspect(reason)}")
        {:reply, {:error, reason}, state}

      reason ->
        Logger.error(":transform_system_to_dominion #{inspect(reason)}")
        {:reply, {:error, :system_not_found}, state}
    end
  end

  @decorate tick()
  def on_call({:transform_dominion_to_system, system_id}, _, state) do
    with true <- Player.own_dominion?(state.data, system_id),
         true <- Player.can_transform_system(state.data),
         true <- Player.can_add_stellar_system(state.data),
         {:ok, system} <- Game.call(state.instance_id, :galaxy, :master, {:claim_system, state.data, system_id, false}),
         {:ok, data} <- Player.pay_transform_system(state.data),
         {:ok, data} <- Player.remove_dominion(data, system_id),
         {:ok, data} <- Player.add_stellar_system(data, system) do
      PlayerChannel.broadcast_change(state.channel, %{player_player: data})
      {:reply, :ok, %{state | data: data}}
    else
      false ->
        {:reply, {:error, :system_not_found}, state}

      {:error, reason} ->
        Logger.error(":transform_dominion_to_system #{inspect(reason)}")
        {:reply, {:error, reason}, state}

      reason ->
        Logger.error(":transform_dominion_to_system #{inspect(reason)}")
        {:reply, {:error, :system_not_found}, state}
    end
  end

  @decorate tick()
  def on_call({:abandon_system, system_id}, _, state) do
    with true <- Player.own_system?(state.data, system_id),
         true <- Player.can_abandon_system(state.data),
         true <- Player.can_remove_stellar_system(state.data),
         {:ok, gsystem} <- Game.call(state.instance_id, :galaxy, :master, {:abandon_system, system_id}),
         {:ok, data} <- prepare_leaving_system(state, system_id),
         {:ok, data} <- Player.pay_abandon_system(data),
         {:ok, data} <- Player.remove_stellar_system(data, system_id) do
      Game.News.emit(state.instance_id, "system.abandoned", %{
        faction: Atom.to_string(state.data.faction),
        system_name: gsystem.name,
        system_id: system_id,
        sector_id: gsystem.sector_id
      })

      PlayerChannel.broadcast_change(state.channel, %{player_player: data})
      {:reply, :ok, %{state | data: data}}
    else
      false ->
        {:reply, {:error, :system_not_found}, state}

      {:error, reason} ->
        Logger.error(":abandon_system #{inspect(reason)}")
        {:reply, {:error, reason}, state}

      reason ->
        Logger.error(":abandon_system #{inspect(reason)}")
        {:reply, {:error, :system_not_found}, state}
    end
  end

  @decorate tick()
  def on_call({:abandon_dominion, system_id}, _, state) do
    with true <- Player.own_dominion?(state.data, system_id),
         true <- Player.can_abandon_system(state.data),
         {:ok, gsystem} <- Game.call(state.instance_id, :galaxy, :master, {:abandon_system, system_id}),
         {:ok, data} <- Player.pay_abandon_system(state.data),
         {:ok, data} <- Player.remove_dominion(data, system_id) do
      Game.News.emit(state.instance_id, "dominion.liberated", %{
        faction: Atom.to_string(state.data.faction),
        system_name: gsystem.name,
        system_id: system_id,
        sector_id: gsystem.sector_id
      })

      PlayerChannel.broadcast_change(state.channel, %{player_player: data})
      {:reply, :ok, %{state | data: data}}
    else
      false -> {:reply, {:error, :system_not_found}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @decorate tick()
  def on_call({:add_resources, credit, technology, ideology}, _, state) do
    data =
      state.data
      |> Player.add_credit(credit)
      |> Player.add_technology(technology)
      |> Player.add_ideology(ideology)

    PlayerChannel.broadcast_change(state.channel, %{player_player: data})

    {:reply, :ok, %{state | data: data}}
  end

  # Stage 7 F9. Async variant of {:add_resources} used by the
  # buy_offer seller-credit path. A synchronous Player ↔ Player
  # Game.call across two players who both happen to be running
  # `:buy_offer` against each other's offers simultaneously is a
  # mutual deadlock: both block until the GenServer.call timeout
  # (5s) and then both Player.Agents crash. By accepting
  # `:add_resources` as a cast, the seller-credit application is
  # decoupled from the buyer's call site and the deadlock is
  # structurally impossible. The trade-off is eventual consistency
  # for the seller's balance: a very brief window exists where the
  # buyer has been debited but the seller has not yet been credited.
  # For a small community game this is acceptable; for a larger
  # deployment a dedicated Market.Agent per instance would serialise
  # both sides atomically — see docs/stage-7-report.md Cluster C.
  @decorate tick()
  def on_cast({:add_resources, credit, technology, ideology}, state) do
    data =
      state.data
      |> Player.add_credit(credit)
      |> Player.add_technology(technology)
      |> Player.add_ideology(ideology)

    PlayerChannel.broadcast_change(state.channel, %{player_player: data})

    {:noreply, %{state | data: data}}
  end

  # Faction-government effects (faction-wide bonuses + tax rates),
  # pushed by the Faction.Agent on every government change and on its
  # periodic self-heal sync. Recomputes the bonus pipeline so the new
  # rates/bonuses take effect immediately.
  @decorate tick()
  def on_cast({:set_government_effects, effects}, state) when is_map(effects) do
    data = Player.set_government_effects(state.data, effects)
    PlayerChannel.broadcast_change(state.channel, %{player_player: data})

    {:noreply, %{state | data: data}}
  end

  # Stage 4 #C5 fix.
  #
  # Atomic debit for cross-agent transfers (Faction.Market.send_resources).
  # The PRIOR flow was three separate Game.calls against the sender's
  # Player.Agent — get_state → can_send → add_resources(-amounts) — with
  # the sender's GenServer mailbox free to interleave other messages
  # between them. A concurrent PlayerChannel order or purchase that
  # spent the sender's balance between the snapshot and the debit drove
  # the sender below zero (no floor in DynamicValue.add_value), while the
  # receiver still got the full positive credit. Per-race mint.
  #
  # Now the snapshot, affordability check, and debit all run inside the
  # sender's GenServer in a single message — atomically. The reply
  # carries the tax-included amounts the caller already computed so the
  # Faction.Market knows exactly what was deducted.
  @decorate tick()
  def on_call({:try_debit_send, %{credit: credit, technology: technology, ideology: ideology}}, _, state)
      when is_number(credit) and is_number(technology) and is_number(ideology) and
             credit >= 0 and technology >= 0 and ideology >= 0 do
    cond do
      state.data.credit.value < credit ->
        {:reply, {:error, :not_enough_credit}, state}

      state.data.technology.value < technology ->
        {:reply, {:error, :not_enough_technology}, state}

      state.data.ideology.value < ideology ->
        {:reply, {:error, :not_enough_ideology}, state}

      true ->
        data =
          state.data
          |> Player.add_credit(-credit)
          |> Player.add_technology(-technology)
          |> Player.add_ideology(-ideology)

        PlayerChannel.broadcast_change(state.channel, %{player_player: data})
        {:reply, :ok, %{state | data: data}}
    end
  end

  def on_call({:try_debit_send, _}, _, state) do
    {:reply, {:error, :invalid_amounts}, state}
  end

  @decorate tick()
  def on_call({:order_building, system_id, type, production_data}, _, state) do
    with {:ok, production_data} <- resolve_repair_data(state.instance_id, system_id, type, production_data),
         {:ok, _} <- Player.order_building(state.data, system_id, type, production_data, true),
         {:ok, system} <-
           Game.call(state.instance_id, :stellar_system, system_id, {:order_building, type, production_data}),
         {:ok, data} <- Player.order_building(state.data, system_id, type, production_data) do
      data = Player.update_stellar_system(data, system)
      broadcast_production_change(state, data, system, body_uid: elem(production_data, 0))

      {:reply, data, %{state | data: data}}
    else
      {:error, reason} ->
        {:reply, {:error, reason}, state}

      # Game.call returns a BARE :process_not_found when the callee agent
      # is mid-restart/teardown — a WithClauseError here crashes the
      # player agent (genesis reset). Catch-all, like remove_building.
      _ ->
        {:reply, {:error, :system_not_found}, state}
    end
  end

  @decorate tick()
  def on_call({:order_ship, system_id, production_data}, _, state) do
    with {:ok, _} <- Player.order_ship(state.data, system_id, production_data, true),
         {:ok, character, system} <-
           Game.call(state.instance_id, :stellar_system, system_id, {:order_ship, production_data}),
         {:ok, data} <- Player.order_ship(state.data, system_id, production_data) do
      data =
        data
        |> Player.update_character(character)
        |> Player.update_stellar_system(system)

      broadcast_production_change(state, data, system, character: character)

      {:reply, data, %{state | data: data}}
    else
      {:error, reason} ->
        {:reply, {:error, reason}, state}

      _ ->
        {:reply, {:error, :system_not_found}, state}
    end
  end

  @decorate tick()
  def on_call({:remove_building, system_id, production_data}, _, state) do
    with true <- Player.own_system?(state.data, system_id),
         request = {:remove_building, production_data},
         {:ok, system} <- Game.call(state.instance_id, :stellar_system, system_id, request) do
      data = Player.update_stellar_system(state.data, system)
      broadcast_production_change(state, data, system, body_uid: elem(production_data, 0))

      {:reply, data, %{state | data: data}}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
      _ -> {:reply, {:error, :system_not_found}, state}
    end
  end

  @decorate tick()
  def on_call({:destroy_ship, character_id, tile_id}, _, state) do
    with true <- Player.own_character?(state.data, character_id),
         character <- Enum.find(state.data.characters, fn c -> c.id == character_id end),
         true <- not character.on_sold,
         request = {:destroy_ship, tile_id},
         {:ok, character} <- Game.call(state.instance_id, :character, character_id, request) do
      data = Player.update_character(state.data, character)
      PlayerChannel.broadcast_change(state.channel, %{player_player: data})

      {:reply, data, %{state | data: data}}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
      _ -> {:reply, {:error, :system_not_found}, state}
    end
  end

  @decorate tick()
  def on_call({:cancel_production, system_id, production_id}, _, state) do
    with true <- Player.own_system?(state.data, system_id),
         {credit, technology, system, item} <-
           Game.call(state.instance_id, :stellar_system, system_id, {:cancel_production, production_id}) do
      data =
        state.data
        |> Player.add_credit(credit)
        |> Player.add_technology(technology)
        |> Player.update_stellar_system(system)

      # A ship cancel also flips the army tile back to :empty, but that
      # lands through the character agent's async {:update_character}
      # cast (full player_player broadcast), not through this payload.
      body_uid = if item.type in [:building, :building_repairs], do: item.target_id, else: nil
      broadcast_production_change(state, data, system, body_uid: body_uid)

      {:reply, data, %{state | data: data}}
    else
      false ->
        {:reply, {:error, :system_not_found}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}

      _ ->
        {:reply, {:error, :system_not_found}, state}
    end
  end

  @decorate tick()
  def on_call({:purchase_patent, patent_key}, _, state) do
    case Player.purchase_patent(state.data, patent_key) do
      {:ok, data} ->
        # NOTE deliberately NO news emit here. Even a disguised "someone
        # unlocked capital tech" bulletin is valuable intel on its own —
        # the capital-ship story fires when the first capital ship is
        # actually FIELDED (see StellarSystem.add_production), at which
        # point the ship is observable anyway.
        #
        # Daily patent races complete at the instant of purchase — check on
        # the fresh data rather than waiting for the next agent interaction
        # (no-op outside dailies).
        data = Daily.Boot.race_tick(state.instance_id, data)
        PlayerChannel.broadcast_change(state.channel, %{player_player: data})
        {:reply, :ok, %{state | data: data}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @decorate tick()
  def on_call({:purchase_doctrine, doctrine_key}, _, state) do
    case Player.purchase_doctrine(state.data, doctrine_key) do
      {:ok, data} ->
        # News-ticker hook: first player in the galaxy to hold 15 lexes.
        if length(data.doctrines) >= 15 do
          Game.News.emit(state.instance_id, "doctrine.crossed", %{
            faction: Atom.to_string(data.faction),
            player_name: data.name,
            winning_faction_id: data.faction_id,
            winning_registration_id: data.registration_id
          })
        end

        PlayerChannel.broadcast_change(state.channel, %{player_player: data})
        {:reply, :ok, %{state | data: data}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @decorate tick()
  def on_call(:purchase_policy_slot, _, state) do
    case Player.purchase_policy_slot(state.data) do
      {:ok, data} ->
        PlayerChannel.broadcast_change(state.channel, %{player_player: data})
        {:reply, :ok, %{state | data: data}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @decorate tick()
  def on_call({:update_policies, doctrines_key}, _, state) do
    case Player.update_policies(state.data, doctrines_key) do
      {:ok, data, system_bonuses, character_bonuses} ->
        # TODO: propagate to systems, dominions, and characters in parallel

        # propagate doctrine to stellar systems
        data =
          Enum.reduce(data.stellar_systems, data, fn system, acc ->
            request = {:update_bonuses, :player, system_bonuses}
            new_system = Game.call(state.instance_id, :stellar_system, system.id, request)
            Player.update_stellar_system(acc, new_system)
          end)

        # propagate doctrine to dominions
        data =
          Enum.reduce(data.dominions, data, fn system, acc ->
            request = {:update_bonuses, :player, system_bonuses}
            new_system = Game.call(state.instance_id, :stellar_system, system.id, request)
            Player.update_dominion(acc, new_system)
          end)

        # propagate doctrine to characters
        data =
          data.characters
          |> Enum.filter(fn character -> character.status == :on_board end)
          |> Enum.reduce(data, fn character, acc ->
            request = {:update_bonuses, :player, character_bonuses}
            new_character = Game.call(state.instance_id, :character, character.id, request)
            Player.update_character(acc, new_character)
          end)

        PlayerChannel.broadcast_change(state.channel, %{player_player: data})
        {:reply, :ok, %{state | data: data}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  # Stage 4 #C2 + atomicity follow-up.
  #
  # Stage 4 #C2 closed the client-supplied-cost vulnerability by
  # making the market the source of truth for hire costs. The Stage 4
  # implementation, however, called the destructive `:sell_character`
  # BEFORE the affordability check; an unaffordable purchase removed
  # the character from the market and returned an error to the buyer,
  # leaving the slot empty with no refund and no hire — a player-
  # visible "ghost character" bug observed on live.
  #
  # The fix is to make the market handler check-and-take atomically.
  # We pass the buyer's resource snapshot together with the character
  # id; the market handler (a singleton GenServer) decides inside one
  # handle_call body whether to commit the take, and either:
  #
  #   - returns `{:ok, character}` AFTER mutating its own state — the
  #     slot is genuinely consumed and we proceed to hire,
  #   - returns `{:error, reason}` WITHOUT mutating its state — the
  #     slot is untouched, the character is still available for sale.
  #
  # No race can interleave between the check and the take: the market
  # is a singleton GenServer (its mailbox serialises everything),
  # the buyer's Player.Agent is also single-threaded, and the buyer
  # cannot have its own state mutated mid-handle_call (the snapshot
  # we send to the market is therefore equal to the state we will
  # commit against). See `Instance.CharacterMarket.Agent`
  # `on_call({:sell_if_affordable, …})`.
  #
  # `Player.hire_character/3` still runs its own
  # `check_hire_character/2` internally — that re-check is redundant
  # given the single-threading invariant, but harmless and worth the
  # defence-in-depth.
  @decorate tick()
  def on_call({:hire_character, character_id}, _, state) when is_integer(character_id) do
    available = available_resources(state.data)

    with {:ok, character} <-
           Game.call(state.instance_id, :character_market, :master, {:sell_if_affordable, character_id, available}),
         resources = canonical_hire_cost(character),
         {:ok, data} <- Player.hire_character(state.data, resources, character) do
      # News-ticker hook: News.Server counts the faction's living agents
      # of this type and claims the 25-strong milestone first (Erased /
      # Navarchs / Siderians each have one).
      Game.News.emit(state.instance_id, "agent.hired", %{
        character_type: Atom.to_string(character.type),
        faction: Atom.to_string(data.faction),
        winning_faction_id: data.faction_id
      })

      PlayerChannel.broadcast_change(state.channel, %{player_player: data})

      {:reply, data, %{state | data: data}}
    else
      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp available_resources(%Instance.Player.Player{} = player_state) do
    {
      player_state.credit.value,
      player_state.technology.value,
      player_state.ideology.value
    }
  end

  # Defensive: only the canonical struct's costs are trusted. The fields
  # are populated by Character.new (lib/game/instance/character/character.ex)
  # at market generation, never written by a player.
  defp canonical_hire_cost(%Instance.Character.Character{} = character) do
    {
      max(character.credit_cost || 0, 0),
      max(character.technology_cost || 0, 0),
      max(character.ideology_cost || 0, 0)
    }
  end

  @decorate tick()
  def on_call({:dismiss_character, character_id}, _, state) do
    case Player.dismiss_character(state.data, character_id) do
      {:ok, data} ->
        PlayerChannel.broadcast_change(state.channel, %{player_player: data})
        {:reply, data, %{state | data: data}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @decorate tick()
  def on_call({:transfer_character, character_id}, _, state) do
    case Player.transfer_character(state.data, character_id) do
      {:ok, data} ->
        PlayerChannel.broadcast_change(state.channel, %{player_player: data})
        {:reply, {:ok, data}, %{state | data: data}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @decorate tick()
  def on_call({:activate_character, character_id, mode, system_id}, _, state) do
    case Player.activate_character(state.data, character_id, mode, system_id) do
      {:ok, data, character} ->
        state = %{state | data: data}

        # reset strike status before activation
        character = Character.update_strike(character, data.is_bankrupt)

        {:ok, supervisor_pid} = Instance.Supervisor.get_pid(state.instance_id)
        channel = "instance:player:#{state.instance_id}:#{data.id}"
        character_gen_state = Core.GenState.new(:character, state.instance_id, character.id, character, channel)

        DynamicSupervisor.start_child(supervisor_pid, {Instance.Character.Agent, state: character_gen_state})

        {:ok, time} = Game.call(state.instance_id, :time, :master, :get_state)

        if time.is_running do
          :ok = Game.call(state.instance_id, :character, character.id, {:start, state.tick.cumulated_pauses})
        end

        case Game.call(state.instance_id, :stellar_system, system_id, {:push_character, character, mode}) do
          {:error, reason} ->
            {:reply, {:error, reason}, state}

          {:ok, system} ->
            data = Player.update_stellar_system(data, system)

            # propagate doctrine to characters
            bonuses = Player.extract_bonus(data, [:character, :army, :spy, :speaker])
            character = Game.call(state.instance_id, :character, character.id, {:update_bonuses, :player, bonuses})
            data = Player.update_character(data, character)

            state = next_tick(%{state | data: data})

            PlayerChannel.broadcast_change(state.channel, %{player_player: data})

            {:reply, state.data, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @decorate tick()
  def on_call({:deactivate_character, character_id}, _, state) do
    # snapshot the armada affiliation before deactivation wipes it, so
    # the remaining members can be detached/dissolved on success
    armada_before =
      case Game.call(state.instance_id, :character, character_id, :get_state) do
        {:ok, character} -> Map.get(character, :armada)
        _ -> nil
      end

    case deactivate_character(state, character_id, true) do
      {:ok, state} ->
        case armada_before do
          nil -> :ok
          armada -> ArmadaImpl.detach_by_map(state.instance_id, armada, character_id)
        end

        {:reply, state.data, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @decorate tick()
  def on_call({:assassinate_character, character_id}, _, state) do
    if Player.own_character?(state.data, character_id) do
      {:ok, character} = Game.call(state.instance_id, :character, character_id, :get_state)

      if character.status == :on_board and character.type == :admiral and
           (Character.has_planned_ship?(character) or Character.has_ship?(character)) do
        # the fleet survives under a default agent, but the assassinated
        # commander's gateway transit dies with them: free the lock and
        # drop a running charge from the queue the replacement inherits
        Instance.Character.Actions.Gateway.release_if_interrupted(character)
        {_result, character} = Instance.Character.Actions.Gateway.abort_charge(character)
        character = Character.replace_agent_with_default(character, state.instance_id)
        Game.cast(state.instance_id, :character, character_id, {:update_state, character})
        Game.cast(state.instance_id, :stellar_system, character.system, {:update_character, character})
        {:ok, system} = Game.call(state.instance_id, :stellar_system, character.system, :get_state)

        data =
          state.data
          |> Player.update_character(character)
          |> Player.update_stellar_system(system)

        state = next_tick(%{state | data: data})
        PlayerChannel.broadcast_change(state.channel, %{player_player: state.data})

        {:reply, :ok, state}
      else
        with {:ok, data, _character} <- Player.assassinate_character(state.data, character),
             state = %{state | data: data},
             {:ok, system} <-
               Game.call(
                 state.instance_id,
                 :stellar_system,
                 character.system,
                 {:remove_character, character, character.status}
               ) do
          # a Siderian killed mid-conquest never reaches MakeDominion.finish;
          # lift the target owner's under-attack mark before the agent dies —
          # and free the faction's gateway lock if they died mid-charge
          Instance.Character.Actions.MakeDominion.unmark_if_interrupted(character)
          Instance.Character.Actions.Gateway.release_if_interrupted(character)

          # an assassinated armada member leaves its armada before the
          # agent dies; below 2 members the armada dissolves
          ArmadaImpl.detach(state.instance_id, character)

          Instance.Manager.kill_child(state.instance_id, {state.instance_id, :character, character.id})
          data = Player.update_stellar_system(data, system)

          state = next_tick(%{state | data: data})
          PlayerChannel.broadcast_change(state.channel, %{player_player: state.data})

          {:reply, :ok, state}
        else
          {:error, reason} -> {:reply, {:error, reason}, state}
          error -> {:reply, {:error, error}, state}
        end
      end
    else
      {:reply, {:error, :character_not_found}, state}
    end
  end

  @decorate tick()
  def on_call({:convert_character, character, system_id}, _, state) do
    {:ok, character_id} = Game.call(state.instance_id, :character_market, :master, :get_next_character_id)
    {:ok, data, character} = Player.convert_character(state.data, character, character_id, system_id)
    state = %{state | data: data}

    # reset strike status before activation
    character = Character.update_strike(character, data.is_bankrupt)

    {:ok, supervisor_pid} = Instance.Supervisor.get_pid(state.instance_id)
    channel = "instance:player:#{state.instance_id}:#{data.id}"
    character_gen_state = Core.GenState.new(:character, state.instance_id, character.id, character, channel)

    DynamicSupervisor.start_child(supervisor_pid, {Instance.Character.Agent, state: character_gen_state})

    {:ok, time} = Game.call(state.instance_id, :time, :master, :get_state)

    if time.is_running do
      :ok = Game.call(state.instance_id, :character, character.id, {:start, state.tick.cumulated_pauses})
    end

    case Game.call(state.instance_id, :stellar_system, system_id, {:push_character, character, :on_board}) do
      {:error, reason} ->
        {:reply, {:error, reason}, state}

      {:ok, _system} ->
        PlayerChannel.broadcast_change(state.channel, %{player_player: data})
        {:reply, :ok, state}
    end
  end

  @decorate tick()
  def on_call({:add_character_actions, character_id, actions}, _, state) do
    with true <- Player.own_character?(state.data, character_id),
         character <- Enum.find(state.data.characters, fn c -> c.id == character_id end),
         true <- not character.on_sold,
         :ok <- ArmadaImpl.check_enqueue(state.instance_id, character_id, actions),
         :ok <- Game.call(state.instance_id, :character, character_id, {:add_actions, actions}) do
      {:reply, :ok, state}
    else
      false ->
        {:reply, {:error, :character_not_found}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @decorate tick()
  def on_call({:clear_character_actions, character_id, index}, _, state) do
    with true <- Player.own_character?(state.data, character_id),
         character <- Enum.find(state.data.characters, fn c -> c.id == character_id end),
         true <- not character.on_sold do
      Game.cast(state.instance_id, :character, character_id, {:clear_actions, index})
      {:reply, :ok, state}
    else
      _ ->
        {:reply, {:error, :character_not_found}, state}
    end
  end

  @decorate tick()
  def on_call({:get_character_state, character_id}, _, state) do
    with true <- Player.own_character?(state.data, character_id),
         {:ok, character} <- Game.call(state.instance_id, :character, character_id, :get_state) do
      actions = ActionQueue.skip_initial_lock(character.actions)
      character = %{character | actions: actions}
      {:reply, character, state}
    else
      false ->
        {:reply, {:error, :character_not_found}, state}

      err ->
        Logger.error(":get_character_state #{inspect(err)}")
        {:reply, {:error, :character_not_found}, state}
    end
  end

  @decorate tick()
  def on_call({:update_reaction, character_id, reaction}, _, state) do
    with true <- Player.own_character?(state.data, character_id),
         character <- Enum.find(state.data.characters, fn c -> c.id == character_id end),
         true <- not character.on_sold,
         :ok <- ArmadaImpl.check_reaction(state.instance_id, character_id, reaction),
         {:ok, character} <- Game.call(state.instance_id, :character, character_id, {:update_reaction, reaction}) do
      data = Player.update_character(state.data, character)
      PlayerChannel.broadcast_change(state.channel, %{player_player: data})

      {:reply, state.data, state}
    else
      false ->
        {:reply, {:error, :character_not_found}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @decorate tick()
  def on_call({:fight_callback, status, %Character{} = character}, _, state) do
    {data, character, has_to_die?} = fight_callback(status, state, character)

    {:reply, {character, has_to_die?}, %{state | data: data}}
  end

  # Armada commands (docs/armadas.md; Instance.Player.ArmadaImpl).
  # The player agent is the armada's single writer — form/join/break
  # and every detach run through here, serialized per player.
  @decorate tick()
  def on_call({:form_armada, character_id, other_id}, _, state) do
    case ArmadaImpl.form(state.instance_id, state.data, character_id, other_id) do
      :ok ->
        PlayerChannel.broadcast_change(state.channel, %{player_player: state.data})
        {:reply, :ok, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @decorate tick()
  def on_call({:join_armada, character_id, armada_member_id}, _, state) do
    case ArmadaImpl.join(state.instance_id, state.data, character_id, armada_member_id) do
      :ok ->
        PlayerChannel.broadcast_change(state.channel, %{player_player: state.data})
        {:reply, :ok, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @decorate tick()
  def on_call({:break_armada, character_id}, _, state) do
    case ArmadaImpl.break(state.instance_id, state.data, character_id) do
      :ok ->
        PlayerChannel.broadcast_change(state.channel, %{player_player: state.data})
        {:reply, :ok, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @decorate tick()
  def on_call({:create_offer, offer_data}, _, state) do
    case Market.create_offer(state.data, offer_data) do
      {:ok, data} ->
        PlayerChannel.broadcast_change(state.channel, %{player_player: data})
        {:reply, :ok, %{state | data: data}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @decorate tick()
  def on_call({:cancel_offer, offer_id}, _, state) do
    case Market.cancel_offer(state.data, offer_id) do
      {:ok, data} ->
        PlayerChannel.broadcast_change(state.channel, %{player_player: data})
        {:reply, :ok, %{state | data: data}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @decorate tick()
  def on_call({:buy_offer, offer_id}, _, state) do
    case Market.buy_offer(state.data, offer_id) do
      {:ok, data, seller_id, amount} ->
        # Stage 7 F9. Game.cast (not call) avoids a Player ↔ Player
        # synchronous deadlock when two players simultaneously buy
        # each other's offers. The seller-credit application is now
        # eventually consistent; see the on_cast({:add_resources, …})
        # handler above for the reasoning.
        Game.cast(state.instance_id, :player, seller_id, {:add_resources, amount, 0, 0})

        notif = Notification.Text.new(:offer_sold, nil, %{buyer: state.data.name, offer_id: offer_id})
        Game.cast(state.instance_id, :player, seller_id, {:push_notifs, notif})

        PlayerChannel.broadcast_change(state.channel, %{player_player: data})
        {:reply, :ok, %{state | data: data}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @decorate tick()
  def on_cast({:claim_system, system_id}, state) do
    with true <- Player.can_add_stellar_system(state.data),
         {:ok, system} <- Game.call(state.instance_id, :galaxy, :master, {:claim_system, state.data, system_id, false}),
         {:ok, data} <- Player.add_stellar_system(state.data, system) do
      # update newly claimed system with existing bonuses
      system_bonuses = Player.extract_bonus(data, [:stellar_system])
      system = Game.call(state.instance_id, :stellar_system, system.id, {:update_bonuses, :player, system_bonuses})
      data = Player.update_stellar_system(data, system)

      PlayerChannel.broadcast_change(state.channel, %{player_player: data})
      {:noreply, %{state | data: data}}
    else
      {:error, reason} ->
        Logger.error(":claim_system #{inspect(reason)}")
        {:noreply, state}

      reason ->
        Logger.error(":claim_system #{inspect(reason)}")
        {:noreply, state}
    end
  end

  @decorate tick()
  def on_cast({:claim_dominion, system_id}, state) do
    with true <- Player.can_add_dominion(state.data),
         {:ok, system} <- Game.call(state.instance_id, :galaxy, :master, {:claim_system, state.data, system_id, true}),
         {:ok, data} <- Player.add_dominion(state.data, system) do
      # update newly claimed system with existing bonuses
      system_bonuses = Player.extract_bonus(data, [:stellar_system])
      system = Game.call(state.instance_id, :stellar_system, system.id, {:update_bonuses, :player, system_bonuses})
      data = Player.update_dominion(data, system)

      PlayerChannel.broadcast_change(state.channel, %{player_player: data})
      {:noreply, %{state | data: data}}
    else
      {:error, reason} ->
        Logger.error(":claim_dominion #{inspect(reason)}")
        {:noreply, state}

      reason ->
        Logger.error(":claim_dominion #{inspect(reason)}")
        {:noreply, state}
    end
  end

  @decorate tick()
  def on_cast({:lose_system, system_id}, state) do
    with true <- Player.own_system?(state.data, system_id),
         system when not is_nil(system) <- Enum.find(state.data.stellar_systems, fn s -> s.id == system_id end),
         {:ok, data} <- prepare_leaving_system(state, system_id),
         {:ok, data} <- Player.remove_stellar_system(data, system_id) do
      if data.is_dead do
        RC.Instances.kill_player(data.faction_id, data.id)
      end

      state = %{state | data: data}

      PlayerChannel.broadcast_change(state.channel, %{player_player: state.data})

      {:noreply, state}
    else
      err ->
        Logger.error(":lose_system #{inspect(err)}")
        {:noreply, state}
    end
  end

  @decorate tick()
  def on_cast({:lose_dominion, system_id}, state) do
    with true <- Player.own_dominion?(state.data, system_id),
         system when not is_nil(system) <- Enum.find(state.data.dominions, fn s -> s.id == system_id end),
         {:ok, data} <- Player.remove_dominion(state.data, system_id) do
      state = %{state | data: data}
      PlayerChannel.broadcast_change(state.channel, %{player_player: state.data})

      {:noreply, state}
    else
      err ->
        Logger.error(":lose_dominion #{inspect(err)}")
        {:noreply, state}
    end
  end

  @decorate tick()
  def on_cast({:update_system, %StellarSystem{} = system}, state) do
    data = Player.update_stellar_system(state.data, system)
    state = next_tick(%{state | data: data})

    PlayerChannel.broadcast_change(state.channel, %{player_player: state.data})

    {:noreply, state}
  end

  @decorate tick()
  def on_cast({:update_dominion, %StellarSystem{} = system}, state) do
    data = Player.update_dominion(state.data, system)
    state = next_tick(%{state | data: data})

    PlayerChannel.broadcast_change(state.channel, %{player_player: state.data})

    {:noreply, state}
  end

  @decorate tick()
  def on_cast({:mark_dominion_under_attack, system_id}, state) do
    data = Player.mark_dominion_under_attack(state.data, system_id)
    state = %{state | data: data}

    PlayerChannel.broadcast_change(state.channel, %{player_player: state.data})

    {:noreply, state}
  end

  @decorate tick()
  def on_cast({:unmark_dominion_under_attack, system_id}, state) do
    data = Player.unmark_dominion_under_attack(state.data, system_id)
    state = %{state | data: data}

    PlayerChannel.broadcast_change(state.channel, %{player_player: state.data})

    {:noreply, state}
  end

  @decorate tick()
  def on_cast({:update_character, %Character{status: :governor} = character}, state) do
    data = Player.update_character(state.data, character)
    state = %{state | data: data}

    case Game.call(state.instance_id, :stellar_system, character.system, {:push_character, character, :governor}) do
      {:ok, system} ->
        data = Player.update_stellar_system(data, system)
        state = next_tick(%{state | data: data})

        PlayerChannel.broadcast_change(state.channel, %{player_player: state.data})

        {:noreply, state}

      {:error, _} ->
        {:noreply, state}
    end
  end

  @decorate tick()
  def on_cast({:update_character, %Character{} = character}, state) do
    data = Player.update_character(state.data, character)
    state = %{state | data: data} |> next_tick()

    characters =
      Enum.map(state.data.characters, fn character ->
        actions = ActionQueue.skip_initial_lock(character.actions)
        %{character | actions: actions}
      end)

    data = %{state.data | characters: characters}
    PlayerChannel.broadcast_change(state.channel, %{player_player: data})

    {:noreply, state}
  end

  # A stranded :attached armada member self-recovered (the attached-
  # state watchdog, docs/armadas.md §8.5): it has already re-entered a
  # system and cleared its own membership — mend the survivors' maps
  # and leave an operator-greppable trace.
  def on_cast({:armada_recovered_member, %Character{} = character}, state) do
    Logger.warning("[armada] stale-member recovery: detaching recovered member",
      instance_id: state.instance_id,
      player_id: state.data.id,
      character_id: character.id,
      character_name: character.name,
      armada: inspect(Map.get(character, :armada))
    )

    ArmadaImpl.detach(state.instance_id, character)
    {:noreply, state}
  end

  def on_cast({:push_notifs, []}, state), do: {:noreply, state}

  def on_cast({:push_notifs, notif}, state) when not is_list(notif),
    do: on_cast({:push_notifs, [notif]}, state)

  def on_cast({:push_notifs, notifs}, state) do
    data =
      Enum.reduce(notifs, state.data, fn notif, acc ->
        if state.speed != :fast do
          save_event(acc.instance_id, acc.registration_id, notif)
        end

        if state.data.connected_clients == 0 and notif.keep?,
          do: Player.store_notification(acc, notif),
          else: acc
      end)

    unless Enum.empty?(notifs), do: PlayerChannel.broadcast_change(state.channel, %{player_notifs: notifs})

    {:noreply, %{state | data: data}}
  end

  # Kick off the daily leaderboard safety net (see :daily_autosave below).
  def on_cast(:start_daily_autosave, state) do
    Process.send_after(self(), :daily_autosave, @daily_autosave_ms)
    {:noreply, state}
  end

  # Daily "Headhunter": this player's Erased landed a successful assassination
  # (cast from Instance.Character.Actions.Assassination). Count it for scoring.
  # Snapshot-tolerant (Map.get/Map.put); harmless in non-daily games (never
  # read there).
  def on_cast(:increment_assassinations, state) do
    count = Map.get(state.data, :agents_assassinated, 0)
    {:noreply, %{state | data: Map.put(state.data, :agents_assassinated, count + 1)}}
  end

  # Daily "Monumental" race: a tracked wonder finished in one of this player's
  # systems (StellarSystem.Agent.cast_hook). Latch the key so the race
  # objective's tick (Daily.Boot.race_tick → Daily.Objective.race_completed?)
  # can see the completion. Snapshot-tolerant (Map.get/Map.put).
  def on_cast({:wonder_built, key}, state) do
    built = Map.get(state.data, :wonders_built, [])

    data =
      if key in built,
        do: state.data,
        else: Map.put(state.data, :wonders_built, [key | built])

    # Daily wonder races complete the instant the latch lands — check on the
    # fresh data rather than waiting for the next agent interaction (no-op
    # outside dailies).
    data = Daily.Boot.race_tick(state.instance_id, data)

    {:noreply, %{state | data: data}}
  end

  @decorate tick()
  def on_info(:tick, state) do
    {:noreply, state}
  end

  # Daily safety net (undecorated — this is a wall-clock timer, not a game
  # tick). Kicked off once at boot via `:start_daily_autosave`, it upserts the
  # leaderboard score every minute so a crash/disconnect before the deadline
  # still records progress. `Daily.Boot.autosave/2` returns `:stop` once the
  # run has finalized (deadline reached), which ends the loop.
  def on_info(:daily_autosave, state) do
    case Daily.Boot.autosave(state.instance_id, state.data) do
      :continue -> Process.send_after(self(), :daily_autosave, @daily_autosave_ms)
      _ -> :ok
    end

    {:noreply, state}
  end

  defp do_next_tick(state, elapsed_time) do
    {change, data} = Player.next_tick(state.data, elapsed_time)

    # Daily race objectives: detect goal completion live (records the win
    # exactly once; a couple of map lookups and a no-op outside dailies).
    data = Daily.Boot.race_tick(state.instance_id, data)

    # flush withheld faction taxes to the treasury (fire-and-forget;
    # anything lost to an unavailable faction agent is re-remitted on
    # the next stats interval)
    data =
      if MapSet.member?(change, :remit_taxes) do
        amounts = Map.get(data, :tax_accumulator, %{})
        Game.cast(state.instance_id, :faction, data.faction_id, {:treasury_deposit, amounts})
        Map.put(data, :tax_accumulator, %{credit: 0, technology: 0, ideology: 0})
      else
        data
      end

    if MapSet.member?(change, :make_stats) do
      {:ok, galaxy} = Game.call(state.instance_id, :galaxy, :master, :get_state)

      unless Instance.Galaxy.Galaxy.is_tutorial(galaxy) do
        Player.get_stats(data)
        |> RC.PlayerStats.create_player_stat()
      end

      # News-ticker hook: milestone probes. Re-emitting every stats
      # window is fine — News.Server caches settled first-claims and
      # drops repeats without touching the DB.
      for {resource, value} <- [{"technology", data.technology.change}, {"ideology", data.ideology.change}],
          value >= 100 do
        Game.News.emit(state.instance_id, "income.crossed", %{
          resource: resource,
          faction: Atom.to_string(data.faction),
          player_name: data.name,
          winning_faction_id: data.faction_id,
          winning_registration_id: data.registration_id
        })
      end

      if data.credit.value >= 10_000_000 do
        Game.News.emit(state.instance_id, "credit.crossed", %{
          faction: Atom.to_string(data.faction),
          player_name: data.name,
          winning_faction_id: data.faction_id,
          winning_registration_id: data.registration_id
        })
      end
    end

    if MapSet.member?(change, :player_update) do
      PlayerChannel.broadcast_change(state.channel, %{player_player: data})
    end

    if MapSet.member?(change, :update_player_activity) do
      Game.cast(state.instance_id, :galaxy, :master, {:add_player, data})
    end

    {%{state | data: data}, Player}
  end

  defp clear_associated_production_queue(%Player{} = player, character_id) do
    character = Game.call(player.instance_id, :character, character_id, :cancel_all_ships)
    Game.cast(player.instance_id, :stellar_system, character.system, {:cancel_ordered_ships, character.id})

    Player.update_character(player, character)
  end

  defp deactivate_character(state, nil, _broadcast?),
    do: {:ok, state}

  defp deactivate_character(state, character_id, broadcast?) do
    with {:ok, character} <- Game.call(state.instance_id, :character, character_id, :get_state),
         mode = character.status,
         system_id = character.system,
         # deactivation kills the agent, so a running make_dominion never
         # reaches finish — lift the target owner's under-attack mark
         _ = Instance.Character.Actions.MakeDominion.unmark_if_interrupted(character),
         {:ok, data, character} <- Player.deactivate_character(state.data, character),
         state = %{state | data: data},
         :ok <- Instance.Manager.kill_child(state.instance_id, {state.instance_id, :character, character.id}),
         {:ok, system} <- Game.call(state.instance_id, :stellar_system, system_id, {:remove_character, character, mode}) do
      data = Player.update_stellar_system(data, system)
      state = next_tick(%{state | data: data})

      if broadcast? do
        PlayerChannel.broadcast_change(state.channel, %{player_player: state.data})
      end

      {:ok, state}
    else
      {:error, reason} ->
        {:error, reason}

      error ->
        {:error, error}
    end
  end

  defp fight_callback(:victorious, state, character) do
    data = Player.update_character(state.data, character)
    Game.cast(state.instance_id, :character, character.id, {:update_state, character})

    {data, character, false}
  end

  defp fight_callback(:fleeing, state, character) do
    if Enum.member?([:conquest, :raid, :loot], character.action_status) do
      {:ok, _system, _siege_logs} =
        Game.call(character.instance_id, :stellar_system, character.system, {:release_siege, 0, 0})
    end

    Game.cast(state.instance_id, :character, character.id, {:update_state, character})

    # A beaten armada flees together (test class 5): the first losing
    # member to reach this callback enqueues the retreat jump (it is
    # the flee-lead); every other member just drops its orders and
    # idles — the flee-lead's Jump.start re-attaches them.
    character =
      case Map.get(character, :armada) do
        nil ->
          Game.call(state.instance_id, :character, character.id, :flee)

        armada ->
          case ArmadaImpl.armada_flee_role(state.instance_id, character, armada) do
            :lead ->
              Game.call(state.instance_id, :character, character.id, :flee)

            :follower ->
              {:ok, cleared} = Game.call(state.instance_id, :character, character.id, :armada_clear_to_idle)
              cleared
          end
      end

    data =
      state.data
      |> clear_associated_production_queue(character.id)
      |> Player.update_character(character)

    {data, character, false}
  end

  defp fight_callback(:dead, state, character) do
    if Enum.member?([:conquest, :raid, :loot], character.action_status) do
      {:ok, _system, _siege_logs} =
        Game.call(character.instance_id, :stellar_system, character.system, {:release_siege, 0, 0})
    end

    # a dead member leaves its armada; below 2 members it dissolves
    ArmadaImpl.detach(state.instance_id, character)

    data =
      state.data
      |> clear_associated_production_queue(character.id)
      |> Player.kill_character(character)

    # we need to do that there because the character process will no longer be active
    # therefore the player will not receive a signal telling it to broadcast new state
    PlayerChannel.broadcast_change(state.channel, %{player_player: data})

    {data, character, true}
  end

  defp prepare_leaving_system(state, system_id) do
    system = Enum.find(state.data.stellar_systems, fn s -> s.id == system_id end)

    # deactivate governor if any
    with governor_id <- if(system.governor == nil, do: nil, else: system.governor.id),
         {:ok, state} <- deactivate_character(state, governor_id, false) do
      data =
        system.characters
        |> Enum.reduce(state.data, fn
          # clear admiral production queues
          c, data when c.type == :admiral and c.owner.id == state.data.id ->
            clear_associated_production_queue(data, c.id)

          _, data ->
            data
        end)

      {:ok, data}
    else
      _ -> :error
    end
  end

  # Repairs must be priced from the building actually on the tile. The
  # client's prod_key/prod_level used to be trusted for the debit while
  # the stellar system repaired the tile's real building — a crafted
  # payload could repair an expensive building at a cheap one's cost.
  defp resolve_repair_data(_iid, _system_id, "build", production_data), do: {:ok, production_data}

  defp resolve_repair_data(iid, system_id, "repair", {target_id, tile_id, _prod_key, _prod_level}) do
    case Game.call(iid, :stellar_system, system_id, {:get_tile, target_id, tile_id}) do
      {:ok, nil} ->
        {:error, :unknown_tile}

      {:ok, %{building_key: nil}} ->
        {:error, :no_undamaged_repairs}

      {:ok, %{building_key: key, building_level: level}} ->
        {:ok, {target_id, tile_id, key, level}}

      _ ->
        {:error, :system_not_found}
    end
  end

  defp resolve_repair_data(_iid, _system_id, _type, _production_data), do: {:error, :invalid_payload}

  # Construction orders used to broadcast the whole player struct (the
  # entire empire summary per click). This slim payload carries only what
  # an order/cancel can change: the debited resource DynamicValues, the
  # affected system's queue + workforce + player-summary entry, the
  # (re)planned tiles of the one affected body, and — for ship orders —
  # the updated character (full struct for the selected-character panel,
  # plus its Player.Character summary for the roster cards). Ordering
  # does not move the system's production/income Core.Values (only ticks
  # and completions do, and those still broadcast player_player; a
  # demolition's value changes also arrive via the {:update_system} cast
  # → full player_player chain). The client patches this delta into its
  # store and skips the full get_system/get_character round trips on
  # this path; the trailing settle sync self-heals anything the payload
  # doesn't carry.
  #
  # Shape parity: tiles/queue pass through the owner-visibility (level 5)
  # faction view untouched (Tile.obfuscate/2 is identity at 5), so raw
  # structs here match what get_system returns to the owner.
  #
  # Protocol negotiation: the slim delta is only sent to players whose
  # client announced the "player_production" capability at channel join
  # (gated by the `slim_sync` beta feature). Everyone else — beta flag
  # off, stale bundle — gets the legacy full player_player broadcast,
  # byte-identical to the pre-delta protocol. The client needs no mode
  # flag: its sync behavior keys off which message kind arrives.
  defp broadcast_production_change(state, data, system, opts) do
    if RC.ClientCapabilities.has?(state.instance_id, data.id, "player_production") do
      broadcast_production_delta(state, data, system, opts)
    else
      PlayerChannel.broadcast_change(state.channel, %{player_player: data})
    end
  end

  defp broadcast_production_delta(state, data, system, opts) do
    payload = %{
      system_id: system.id,
      credit: data.credit,
      technology: data.technology,
      ideology: data.ideology,
      stellar_system: Instance.Player.StellarSystem.convert(system),
      queue: system.queue,
      used_workforce: system.used_workforce
    }

    payload =
      case find_body(system.bodies, opts[:body_uid]) do
        nil -> payload
        body -> Map.put(payload, :body_tiles, %{body_uid: body.uid, tiles: body.tiles})
      end

    payload =
      case opts[:character] do
        nil ->
          payload

        character ->
          # Mirror {:get_character_state, ...}: the client's selected
          # character always has the initial action lock skipped. The
          # summary entry comes from `data` (already updated via
          # Player.update_character) so it is exactly what a full
          # player_player broadcast would have carried.
          actions = ActionQueue.skip_initial_lock(character.actions)

          payload
          |> Map.put(:character, %{character | actions: actions})
          |> Map.put(:player_character, Enum.find(data.characters, fn c -> c.id == character.id end))
      end

    PlayerChannel.broadcast_change(state.channel, %{player_production: payload})
  end

  defp find_body(_bodies, nil), do: nil

  defp find_body(bodies, uid) do
    Enum.find_value(bodies, fn body ->
      if body.uid == uid, do: body, else: find_body(body.bodies, uid)
    end)
  end

  def save_event(_iid, _rid, %Notification.Notification{type: :sound} = _notif),
    do: nil

  def save_event(iid, rid, %Notification.Notification{} = notif) do
    RC.PlayerEvents.create(%{
      type: Atom.to_string(notif.type),
      key: Atom.to_string(notif.key),
      data: Jason.encode!(notif.data),
      instance_id: iid,
      registration_id: rid
    })
  end
end

defmodule Instance.Faction.Agent do
  use Core.TickServer

  alias Instance.Faction.Faction
  alias Instance.Faction.Character
  alias Instance.Faction.GalacticSurvey
  alias Instance.Faction.Government
  alias Instance.Faction.Market
  alias Instance.Faction.StellarSystem
  alias Portal.Controllers.FactionChannel

  require Logger

  @decorate tick()
  def on_call(:get_state, _from, state) do
    {:reply, {:ok, state.data}, state}
  end

  @decorate tick()
  def on_call(:get_galactic_survey, _, state) do
    # Read / write via Map.get + Map.put rather than the struct accessor
    # because faction state is snapshotted to DB and restored across
    # deploys: a snapshot taken before this field existed deserializes
    # into a struct that's literally missing :galactic_survey_cache, and
    # `state.data.galactic_survey_cache` or `%{state.data | …}` would
    # both raise KeyError. Map-based access works for both shapes; subsequent
    # writes back-fill the field so later access uses the normal layout.
    {cache, rows} =
      GalacticSurvey.get_or_build(
        Map.get(state.data, :galactic_survey_cache),
        state.data,
        state.instance_id
      )

    data = Map.put(state.data, :galactic_survey_cache, cache)
    {:reply, {:ok, rows}, %{state | data: data}}
  end

  @decorate tick()
  def on_call({:get_system_state, system_id}, _, state) do
    case Game.call(state.instance_id, :stellar_system, system_id, :get_state) do
      {:ok, system} ->
        contact = Faction.resolve_system_visibility(state.data, system)

        # Note: this path obfuscates with Instance.StellarSystem.Character — a
        # summary struct without :army / :action_status — so the F4/F8 leak
        # surfaces from the Stage 8 fix are not present here, and there is no
        # viewer_faction_key to plumb. F4/F8 protections apply on the
        # :get_character_state path below, which goes through Faction.Character.
        obfuscated_system =
          StellarSystem.obfuscate(system, contact, state.data.id, state.instance_id)

        {:reply, obfuscated_system, state}

      error ->
        Logger.error(error)
        {:reply, :error, state}
    end
  end

  @decorate tick()
  def on_call({:get_character_state, character_id}, _, state) do
    with {:ok, character} <- Game.call(state.instance_id, :character, character_id, :get_state),
         {:ok, system} <- Game.call(state.instance_id, :stellar_system, character.system, :get_state) do
      visibility = Faction.resolve_character_visibility(state.data, system, character)

      # Stage 8 F4/F8: same as :get_system_state — forward our own
      # faction key so the obfuscation can distinguish own-faction
      # characters from cross-faction characters viewed at the same
      # visibility tier.
      obfuscated_character = Character.obfuscate(character, visibility, state.data.key)

      {:reply, obfuscated_character, state}
    else
      _error -> {:reply, :error, state}
    end
  end

  @decorate tick()
  def on_call({:get_system_informer_count, system_id}, _, state) do
    contacts = Faction.get_system_contact(state.data, system_id)
    informer = Map.get(contacts.details, :informer, [])
    {:reply, {:ok, length(informer)}, state}
  end

  @decorate tick()
  def on_call({:add_player, player}, _, state) do
    data = Faction.add_player(state.data, player)
    faction_data = Data.Querier.one(Data.Game.Faction, state.instance_id, state.data.key)

    FactionChannel.broadcast_change(state.channel, %{faction_faction: data})
    Game.cast(state.instance_id, :victory, :master, {:add_player, state.data.id})

    if state.speed != :fast do
      RC.PlayerEvents.create(%{
        type: "faction",
        key: "new_player",
        data: Jason.encode!(%{player: player.name, theme: faction_data.theme}),
        instance_id: state.instance_id,
        faction_id: state.data.id
      })
    end

    {:reply, :ok, %{state | data: data}}
  end

  @decorate tick()
  def on_call({:drop_explorer, system_id, player_name}, _, state) do
    {response, contact, data} = Faction.drop_system_explorer(state.data, system_id, player_name)
    system_and_contact = %{system_id: system_id, contact: contact}

    FactionChannel.broadcast_change(state.channel, %{faction_faction_contact: system_and_contact})
    Game.cast(state.instance_id, :galaxy, :master, {:update_contacts, data.key, data.contacts})

    {:reply, response, %{state | data: data}}
  end

  @decorate tick()
  def on_call({:drop_informer, system_id, player_name, count}, _, state) do
    {change, contact, data} = Faction.drop_system_informer(state.data, system_id, player_name, count)

    if MapSet.member?(change, :dropped) do
      system_and_contact = %{system_id: system_id, contact: contact}
      Game.cast(state.instance_id, :galaxy, :master, {:update_contacts, data.key, data.contacts})
      FactionChannel.broadcast_change(state.channel, %{faction_faction_contact: system_and_contact})
    end

    if MapSet.member?(change, :radar_update) do
      FactionChannel.broadcast_change(state.channel, %{faction_faction: data})
    end

    {:reply, :ok, %{state | data: data}}
  end

  @decorate tick()
  def on_call({:send_resources, from_player_id, to_player_id, resources}, _, state) do
    {action, result, state} = Market.send_resources(state, {from_player_id, to_player_id, resources})

    if result == :ok do
      name = Faction.get_player_name(state.data, from_player_id)
      notif = Notification.Text.new(:receive_resources, nil, %{player: name, resources: resources})
      Game.cast(state.instance_id, :player, to_player_id, {:push_notifs, notif})
    end

    FactionChannel.broadcast_change(state.channel, %{faction_faction: state.data})
    {action, result, state}
  end

  # Player-icon placement. Returns `:ok` or `{:error, reason}` to the
  # channel so cap / rate-limit / bad-kind rejections are user-visible
  # (chat-style silent drops would let a buggy client think its
  # placement succeeded). On success, broadcast the whole faction
  # struct — same pattern as chat — so every member's in-memory copy
  # of `:icons` stays in sync without a bespoke delta message.
  #
  # Authority: `placer_id` is passed from the channel as
  # `socket.assigns.player_id`, never trusted from the client payload.
  @decorate tick()
  def on_call({:place_icon, placer_id, system_id, kind}, _from, state) do
    case Faction.place_icon(ensure_icon_fields(state.data), placer_id, system_id, kind) do
      {:ok, data, info} ->
        FactionChannel.broadcast_change(state.channel, %{faction_faction: data})
        # The audit-log write is fire-and-forget — a DB hiccup here
        # shouldn't roll back a successful placement that already
        # broadcast to the faction. Cross-player overwrites only;
        # self-overwrites are excluded by the guard inside
        # log_icon_replaced/4.
        log_icon_replaced(%{state | data: data}, placer_id, info, kind)
        {:reply, :ok, %{state | data: data}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @decorate tick()
  def on_call({:remove_icon, requester_id, system_id}, _from, state) do
    case Faction.remove_icon(ensure_icon_fields(state.data), requester_id, system_id) do
      {:ok, data, removed} ->
        FactionChannel.broadcast_change(state.channel, %{faction_faction: data})
        log_icon_removed(%{state | data: data}, requester_id, removed)
        {:reply, :ok, %{state | data: data}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  # Same shape as the :galactic_survey_cache handling in :get_galactic_survey
  # above: a Faction snapshot taken before commit 748c9fc (Player-placed
  # icons) deserializes into a struct literally missing :icons and
  # :icon_rate_buckets. The Faction module's read sites (icon_count_for,
  # rate_limited?, etc.) and write sites (`%{state | icons: …}`) both
  # raise KeyError on those legacy shapes. Backfill once at the agent
  # boundary; Map.put_new preserves fields on fresh / post-feature state.
  defp ensure_icon_fields(data) do
    data
    |> Map.put_new(:icons, [])
    |> Map.put_new(:icon_rate_buckets, %{})
  end

  # ------------------------------------------------------------------
  # Faction government
  # ------------------------------------------------------------------

  # Lazy init doubling as snapshot back-fill: fresh instances and
  # pre-feature snapshots both arrive here without a government, and get
  # one if (and only if) this instance runs the feature (Legacy speed +
  # the creation-time opt-in). The founding countdown therefore starts at
  # first tick after creation — or, for existing Legacy games, at the
  # first tick after the deploy that ships the feature.
  defp ensure_government(data, speed) do
    data = hydrate_government(data, speed)

    case Map.get(data, :government) do
      nil ->
        if Government.enabled?(data.instance_id, speed),
          do: Map.put(data, :government, Government.new(Government.build_ctx(data))),
          else: Map.put(data, :government, nil)

      _government ->
        data
    end
  end

  # Once per PROCESS LIFETIME (the process dictionary dies with the
  # process, which is exactly the semantic): after any restart, adopt the
  # DB write-through copy when its revision is ahead of what we restored
  # from. This is what makes a crashed faction agent resume its elections
  # instead of reverting them to the genesis child-spec (or an older
  # instance snapshot) — see RC.Instances.GovernmentStates.
  defp hydrate_government(data, speed) do
    cond do
      Process.get(:government_hydrated) ->
        data

      not Government.enabled?(data.instance_id, speed) ->
        data

      true ->
        Process.put(:government_hydrated, true)

        case RC.Instances.GovernmentStates.fetch(data.instance_id, data.id, "government") do
          {rev, government} when is_map(government) ->
            if rev > government_rev(Map.get(data, :government)),
              do: Map.put(data, :government, government),
              else: data

          _ ->
            data
        end
    end
  end

  defp government_rev(nil), do: -1
  defp government_rev(government), do: Map.get(government, :rev) || 0

  # Write-through: bump the revision and upsert the durable copy. Called
  # on every mutation path (ops, treasury casts, tick advances) — a
  # best-effort write that never raises (headless instances, DB hiccups).
  defp persist_government(state) do
    case Map.get(state.data, :government) do
      nil ->
        state

      government ->
        government = Map.put(government, :rev, government_rev(government) + 1)

        RC.Instances.GovernmentStates.persist(
          state.instance_id,
          state.data.id,
          "government",
          Map.get(government, :rev),
          government
        )

        %{state | data: Map.put(state.data, :government, government)}
    end
  end

  @decorate tick()
  def on_call({:get_government, player_id}, _, state) do
    data = ensure_government(state.data, state.speed)

    case Map.get(data, :government) do
      nil ->
        {:reply, {:error, :government_disabled}, %{state | data: data}}

      government ->
        reply = %{
          government: government,
          my_votes: Government.own_votes(government, player_id),
          tax_income: Government.tax_income(data)
        }

        {:reply, {:ok, reply}, %{state | data: data}}
    end
  end

  @decorate tick()
  def on_call({:gov_nominate, actor_id, ballot_id, candidate_id}, _, state) do
    with_government(state, fn government, ctx ->
      Government.nominate(government, actor_id, ballot_id, candidate_id, ctx)
    end)
  end

  @decorate tick()
  def on_call({:gov_vote, actor_id, ballot_id, payload}, _, state) do
    with_government(state, fn government, ctx ->
      cast_government_vote(government, actor_id, ballot_id, payload, ctx)
    end)
  end

  @decorate tick()
  def on_call({:gov_appoint, actor_id, seat, appointee_id}, _, state) do
    with_government(state, fn government, ctx ->
      Government.appoint(government, actor_id, seat, appointee_id, ctx)
    end)
  end

  @decorate tick()
  def on_call({:gov_by_election, actor_id, seat}, _, state) do
    with_government(state, fn government, ctx ->
      Government.call_by_election(government, actor_id, seat, ctx)
    end)
  end

  @decorate tick()
  def on_call({:gov_set_taxes, actor_id, rates}, _, state) do
    with_government(state, fn government, ctx ->
      Government.set_tax_rates(government, actor_id, rates, ctx)
    end)
  end

  @decorate tick()
  def on_call({:gov_purchase_patent, actor_id, key}, _, state) do
    with_government(state, fn government, ctx ->
      Government.purchase_patent(government, actor_id, key, ctx)
    end)
  end

  @decorate tick()
  def on_call({:gov_purchase_lex, actor_id, key}, _, state) do
    with_government(state, fn government, ctx ->
      Government.purchase_lex(government, actor_id, key, ctx)
    end)
  end

  @decorate tick()
  def on_call({:gov_update_laws, actor_id, keys}, _, state) do
    with_government(state, fn government, ctx ->
      Government.update_laws(government, actor_id, keys, ctx)
    end)
  end

  @decorate tick()
  def on_call({:gov_distribute_treasury, actor_id, pct}, _, state) do
    with_government(state, fn government, ctx ->
      Government.distribute_treasury(government, actor_id, pct, ctx)
    end)
  end

  @decorate tick()
  def on_call({:gov_set_withdraw_cap, actor_id, pct}, _, state) do
    with_government(state, fn government, ctx ->
      Government.set_withdraw_cap(government, actor_id, pct, ctx)
    end)
  end

  @decorate tick()
  def on_call({:gov_withdraw, actor_id, amounts}, _, state) do
    with_government(state, fn government, ctx ->
      Government.withdraw(government, actor_id, amounts, ctx)
    end)
  end

  @decorate tick()
  def on_call({:gov_grant, actor_id, player_id, amounts}, _, state) do
    with_government(state, fn government, ctx ->
      Government.grant(government, actor_id, player_id, amounts, ctx)
    end)
  end

  # Member donation: uncapped, escrowed BEFORE the deposit (atomic debit
  # on the donor's Player.Agent, same contract as auction bids) — the
  # deposit itself cannot fail, so no refund path is needed after a
  # successful escrow.
  @decorate tick()
  def on_call({:gov_donate, actor_id, amounts}, _, state) do
    with_government(state, fn government, ctx ->
      cond do
        not Enum.any?([:credit, :technology, :ideology], fn key ->
          amount = Map.get(amounts, key, 0)
          is_number(amount) and amount > 0
        end) ->
          {:error, :invalid_payload}

        not Enum.any?(ctx.players, &(&1.id == actor_id)) ->
          {:error, :not_a_member}

        true ->
          escrow = %{
            credit: max(Map.get(amounts, :credit, 0), 0),
            technology: max(Map.get(amounts, :technology, 0), 0),
            ideology: max(Map.get(amounts, :ideology, 0), 0)
          }

          case Game.call(ctx.instance_id, :player, actor_id, {:try_debit_send, escrow}) do
            :ok ->
              government = Government.deposit(government, escrow)
              {:ok, government, [%{type: :treasury_donated, by: actor_id, amounts: escrow}]}

            {:error, reason} ->
              {:error, reason}

            _ ->
              {:error, :not_enough_credit}
          end
      end
    end)
  end

  @decorate tick()
  def on_call({:gov_depose, actor_id, seat}, _, state) do
    with_government(state, fn government, ctx ->
      Government.depose(government, actor_id, seat, ctx)
    end)
  end

  @decorate tick()
  def on_call({:gov_snap, actor_id, target}, _, state) do
    with_government(state, fn government, ctx ->
      Government.snap(government, actor_id, target, ctx)
    end)
  end

  # ARK bid-to-challenge: the stake escrows BEFORE the engine op (same
  # atomic-debit contract as auction bids) and bounces straight back on
  # any engine refusal.
  @decorate tick()
  def on_call({:gov_challenge, actor_id, stake}, _, state) do
    with_government(state, fn government, ctx ->
      with true <- (is_integer(stake) and stake > 0) || {:error, :invalid_payload},
           :ok <- escrow_bid(ctx, actor_id, stake) do
        case Government.challenge(government, actor_id, stake, ctx) do
          {:ok, _government, _events} = success ->
            success

          {:error, _reason} = error ->
            Game.cast(ctx.instance_id, :player, actor_id, {:add_resources, stake, 0, 0})
            error
        end
      else
        {:error, reason} -> {:error, reason}
        error -> error
      end
    end)
  end

  # A personal match escrows like a bid; a treasury match draws from the
  # government treasury inside the engine op (no player escrow).
  @decorate tick()
  def on_call({:gov_challenge_match, actor_id, amount, use_treasury}, _, state) do
    with_government(state, fn government, ctx ->
      cond do
        not is_integer(amount) or amount <= 0 ->
          {:error, :invalid_payload}

        use_treasury ->
          Government.challenge_match(government, actor_id, amount, true, ctx)

        true ->
          with :ok <- escrow_bid(ctx, actor_id, amount) do
            case Government.challenge_match(government, actor_id, amount, false, ctx) do
              {:ok, _government, _events} = success ->
                success

              {:error, _reason} = error ->
                Game.cast(ctx.instance_id, :player, actor_id, {:add_resources, amount, 0, 0})
                error
            end
          end
      end
    end)
  end

  # Station buildings (faction build slots): seat gating, patents, and
  # treasury all check inside the engine op; the op itself round-trips
  # to the system agent through ctx.station_call.
  @decorate tick()
  def on_call({:gov_order_station_building, actor_id, system_id, key, anchor}, _, state) do
    with_government(state, fn government, ctx ->
      Government.order_station_building(government, actor_id, system_id, key, anchor, ctx)
    end)
  end

  @decorate tick()
  def on_call({:gov_cancel_station_building, actor_id, system_id}, _, state) do
    with_government(state, fn government, ctx ->
      Government.cancel_station_building(government, actor_id, system_id, ctx)
    end)
  end

  @decorate tick()
  def on_call({:gov_demolish_station_building, actor_id, system_id, building_id}, _, state) do
    with_government(state, fn government, ctx ->
      Government.demolish_station_building(government, actor_id, system_id, building_id, ctx)
    end)
  end

  # Gateway pairing ops (Military rep; overreach applies inside the engine).
  @decorate tick()
  def on_call({:gov_gateway_link, actor_id, system_a, system_b}, _, state) do
    with_government(state, fn government, ctx ->
      Government.gateway_link(government, actor_id, system_a, system_b, ctx)
    end)
  end

  @decorate tick()
  def on_call({:gov_gateway_unlink, actor_id, system_id}, _, state) do
    with_government(state, fn government, ctx ->
      Government.gateway_unlink(government, actor_id, system_id, ctx)
    end)
  end

  # Transit lock protocol, called from the action orchestrator (never
  # from character agent processes — that direction would deadlock with
  # the tick sweep's faction→character probes).
  @decorate tick()
  def on_call({:gateway_reserve, system_id, character_id}, _, state) do
    gateway_state_call(state, fn government ->
      case Government.gateway_reserve(government, system_id, character_id) do
        {:ok, government, target} -> {:ok, government, {:ok, target}}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  @decorate tick()
  def on_call({:gateway_begin_jump, character_id}, _, state) do
    gateway_state_call(state, fn government ->
      case Government.gateway_begin_jump(government, character_id) do
        {:ok, government} -> {:ok, government, :ok}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  @decorate tick()
  def on_call({:gateway_begin_wind_down, character_id}, _, state) do
    gateway_state_call(state, fn government ->
      ctx = Government.build_ctx(state.data)

      case Government.gateway_begin_wind_down(government, character_id, ctx) do
        {:ok, government} -> {:ok, government, :ok}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  # Fire-and-forget release from the interruption hooks (kill, seduce,
  # orders cleared). Only frees a :charging transit — see the engine doc.
  @decorate tick()
  def on_cast({:gateway_release, character_id}, state) do
    data = ensure_government(state.data, state.speed)

    case Map.get(data, :government) do
      nil ->
        {:noreply, %{state | data: data}}

      government ->
        {government, released?} = Government.gateway_release(Government.backfill(government), character_id)

        if released? do
          state = %{state | data: Map.put(data, :government, government)}
          state = persist_government(state)
          write_log_entry(state, "gateway_transit_interrupted", nil, nil, %{character_id: character_id})
          FactionChannel.broadcast_change(state.channel, %{faction_faction: state.data})
          {:noreply, state}
        else
          {:noreply, %{state | data: data}}
        end
    end
  end

  defp gateway_state_call(state, fun) do
    data = ensure_government(state.data, state.speed)

    case Map.get(data, :government) do
      nil ->
        {:reply, {:error, :government_disabled}, %{state | data: data}}

      government ->
        case fun.(Government.backfill(government)) do
          {:ok, government, reply} ->
            state = %{state | data: Map.put(data, :government, government)}
            state = persist_government(state)
            FactionChannel.broadcast_change(state.channel, %{faction_faction: state.data})
            {:reply, reply, reschedule_tick(state)}

          {:error, reason} ->
            {:reply, {:error, reason}, %{state | data: data}}
        end
    end
  end

  # Diplomacy relay: verify the actor holds the Leader seat, then
  # forward to the per-instance Diplomacy.Agent with our faction id as
  # the acting side. All state and side effects live there; we only
  # provide the authority check (the government is OUR state).
  @decorate tick()
  def on_call({:gov_diplomacy, actor_id, action}, _, state) do
    data = ensure_government(state.data, state.speed)

    government = Map.get(data, :government)

    cond do
      government == nil ->
        {:reply, {:error, :government_disabled}, %{state | data: data}}

      not Government.leader?(Government.backfill(government), actor_id) ->
        {:reply, {:error, :not_leader}, %{state | data: data}}

      true ->
        message =
          case action do
            {:declare_war, to} -> {:declare_war, data.id, to}
            {:propose, to, kind} -> {:propose, data.id, to, kind}
            {:accept, proposal_id} -> {:accept, proposal_id, data.id}
            {:reject, proposal_id} -> {:reject, proposal_id, data.id}
            {:break_pact, to} -> {:break_pact, data.id, to}
          end

        reply = Game.call(state.instance_id, :diplomacy, :master, message)
        {:reply, reply, %{state | data: data}}
    end
  end

  # Stance-cache push from the Diplomacy.Agent. The fresh cache feeds
  # the visibility modifiers (war −1 / pact +1) on the next resolve;
  # broadcast so clients can re-render the diplomatic map.
  @decorate tick()
  def on_cast({:update_diplomacy, stances}, state) when is_map(stances) do
    data = Map.put(state.data, :diplomacy, stances)
    FactionChannel.broadcast_change(state.channel, %{faction_faction: data})
    {:noreply, %{state | data: data}}
  end

  # DEV ONLY: seed the treasury for testing (harness gov-debug/deposit) —
  # taxes fill it far too slowly for a play-test loop.
  @decorate tick()
  def on_call({:gov_debug_deposit, amounts}, _, state) do
    if Application.get_env(:rc, :environment) == :dev do
      with_government(state, fn government, _ctx ->
        {:ok, Government.deposit(government, amounts), []}
      end)
    else
      {:reply, {:error, :not_available}, state}
    end
  end

  # Tax remittances (and any future faction-bound income) from member
  # Player.Agents. Fire-and-forget by design: a lost cast self-heals at
  # the next remit; a DB-backed treasury ledger is a later phase.
  @decorate tick()
  def on_cast({:treasury_deposit, amounts}, state) do
    data = ensure_government(state.data, state.speed)

    case Map.get(data, :government) do
      nil ->
        {:noreply, %{state | data: data}}

      government ->
        government = Government.deposit(Government.backfill(government), amounts)
        state = persist_government(%{state | data: Map.put(data, :government, government)})
        {:noreply, state}
    end
  end

  # Station lifecycle reports from system agents. Same tolerance as
  # :treasury_deposit: a disabled/absent government just drops the cast
  # (the building then has no registry entry and bills nothing).
  @decorate tick()
  def on_cast({:station_completed, system_id, building}, state) do
    update_station_registry(state, fn government ->
      Government.station_registry_complete(government, system_id, building)
    end, fn settled_state, government ->
      # A completion while the faction's stations are unpowered must not
      # slip through powered — push the current power state down.
      if not Map.get(government, :station_powered, true) do
        Game.cast(settled_state.instance_id, :stellar_system, system_id, {:station_set_power, false})
      end

      write_log_entry(settled_state, "station_completed", nil, nil, %{
        system_id: system_id,
        key: building.key,
        level: building.level
      })

      government_player_event(settled_state, "station_completed", %{
        key: Atom.to_string(building.key),
        level: building.level
      })
    end)
  end

  # A control flip also tears down any gateway links anchored on the
  # flipped building (a captured ring's command codes are dead), which
  # aborts a charging traveler and notifies both endpoints.
  @decorate tick()
  def on_cast({:station_status, system_id, building_id, status}, state) do
    data = ensure_government(state.data, state.speed)

    case Map.get(data, :government) do
      nil ->
        {:noreply, %{state | data: data}}

      government ->
        government =
          Government.station_registry_status(Government.backfill(government), system_id, building_id, status)

        {government, break_events} =
          if status == :disabled,
            do: Government.break_links_for(government, system_id, building_id),
            else: {government, []}

        state = %{state | data: Map.put(data, :government, government)}
        state = settle_government_events(state, break_events)
        state = persist_government(state)

        write_log_entry(state, "station_status_changed", nil, nil, %{
          system_id: system_id,
          building_id: building_id,
          status: status
        })

        FactionChannel.broadcast_change(state.channel, %{faction_faction: state.data})
        {:noreply, state}
    end
  end

  # A construction lost to conquest/abandon: nothing to update in the
  # registry (constructions are only registered on completion), but the
  # faction should hear about the sunk treasury.
  @decorate tick()
  def on_cast({:station_construction_lost, system_id, key}, state) do
    write_log_entry(state, "station_construction_lost", nil, nil, %{
      system_id: system_id,
      key: key
    })

    government_player_event(state, "station_construction_lost", %{key: Atom.to_string(key)})
    {:noreply, state}
  end

  # Cyber-census probe from another faction's government: report how
  # many informers WE hold on the probed systems — a local read, replied
  # by cast (synchronous faction→faction calls could deadlock two
  # censusing factions against each other). Not government-gated: the
  # informer ledger is plain faction state.
  @decorate tick()
  def on_cast({:census_probe, requester_faction_id, sector_id, system_ids}, state) when is_list(system_ids) do
    count =
      Enum.reduce(system_ids, 0, fn system_id, acc ->
        case Faction.get_system_contact(state.data, system_id) do
          %{details: details} -> acc + length(Map.get(details, :informer, []))
          _ -> acc
        end
      end)

    Game.cast(
      state.instance_id,
      :faction,
      requester_faction_id,
      {:census_report, sector_id, state.data.id, count}
    )

    {:noreply, state}
  end

  @decorate tick()
  def on_cast({:census_report, sector_id, from_faction_id, count}, state) do
    data = ensure_government(state.data, state.speed)

    case Map.get(data, :government) do
      nil ->
        {:noreply, %{state | data: data}}

      government ->
        government =
          Government.store_census_report(Government.backfill(government), sector_id, from_faction_id, count)

        state = %{state | data: Map.put(data, :government, government)}
        {:noreply, persist_government(state)}
    end
  end

  defp update_station_registry(state, update_fun, side_effects_fun) do
    data = ensure_government(state.data, state.speed)

    case Map.get(data, :government) do
      nil ->
        {:noreply, %{state | data: data}}

      government ->
        government = update_fun.(Government.backfill(government))
        state = %{state | data: Map.put(data, :government, government)}
        state = persist_government(state)
        side_effects_fun.(state, government)
        FactionChannel.broadcast_change(state.channel, %{faction_faction: state.data})
        {:noreply, state}
    end
  end

  # DEV ONLY: run the government clock forward by `ut` game-time units
  # through the real engine — founding ends, ballots close, quorums and
  # tallies all process exactly as if the time had passed. Lets Legacy
  # timings (72h founding, 48h elections) be tested in seconds. Gated
  # here AND at the channel boundary; in prod it does not exist.
  @decorate tick()
  def on_call({:gov_debug_advance, ut}, _, state) do
    if Application.get_env(:rc, :environment) == :dev and is_number(ut) and ut > 0 do
      with_government(state, fn government, ctx ->
        {government, events} = Government.advance(government, ut, ctx)
        {:ok, government, events}
      end)
    else
      {:reply, {:error, :not_available}, state}
    end
  end

  # CHEAT (creator-only, gated at the CheatChannel AND on the instance's
  # cheats_enabled metadata): end the founding grace period now. Advances
  # the government clock by exactly the remaining founding time — the
  # founding clause discards overflow, so this only opens the initial
  # elections, never resolves them.
  @decorate tick()
  def on_call(:cheat_gov_skip_founding, _, state) do
    if Instance.Cheats.enabled?(state.instance_id) do
      with_government(state, fn government, ctx ->
        case government.phase do
          :founding ->
            {government, events} = Government.advance(government, government.founding.value + 1, ctx)
            {:ok, government, events}

          _ ->
            {:error, :not_in_founding}
        end
      end)
    else
      {:reply, {:error, :cheats_disabled}, state}
    end
  end

  # CHEAT: conclude every open election that already has a passing result
  # — winners seat immediately through the real close path. Elections
  # that would still fail (no votes, no majority, quorum unmet) keep
  # running untouched, so the cheat can never destroy the electorate's
  # chance to vote. A pending ARK bid-to-challenge is likewise left to
  # its own clock — its deadline default (unanswered = overthrow) is not
  # a "majority success" to fast-forward. One call = one round: press
  # again for follow-up rounds a government opens in response.
  @decorate tick()
  def on_call(:cheat_gov_conclude_elections, _, state) do
    if Instance.Cheats.enabled?(state.instance_id) do
      with_government(state, fn government, ctx ->
        cond do
          government.phase != :running ->
            {:error, :not_running}

          Enum.empty?(government.ballots) ->
            {:error, :no_open_elections}

          true ->
            case Government.conclude_successful(government, ctx) do
              {_government, _events, 0} -> {:error, :no_concludable_elections}
              {government, events, _count} -> {:ok, government, events}
            end
        end
      end)
    else
      {:reply, {:error, :cheats_disabled}, state}
    end
  end

  # CHEAT: (re-)open the standard election slate on demand — vacant seats
  # after a failed race, or a snap re-election mid-mandate. Sitting
  # holders stay seated as acting heads until replaced; seats with a race
  # already open keep the one they have.
  @decorate tick()
  def on_call(:cheat_gov_reopen_elections, _, state) do
    if Instance.Cheats.enabled?(state.instance_id) do
      with_government(state, fn government, ctx ->
        case government.phase do
          :running ->
            case Government.reopen_elections(government, ctx) do
              {_government, _events, 0} -> {:error, :elections_already_open}
              {government, events, _count} -> {:ok, government, events}
            end

          _ ->
            {:error, :not_running}
        end
      end)
    else
      {:reply, {:error, :cheats_disabled}, state}
    end
  end

  # CHEAT: clear the faction-level lex/law-change cooldown.
  @decorate tick()
  def on_call(:cheat_gov_clear_law_cooldown, _, state) do
    if Instance.Cheats.enabled?(state.instance_id) do
      with_government(state, fn government, _ctx ->
        {:ok, %{government | law_cooldown: Core.CooldownValue.new()}, []}
      end)
    else
      {:reply, {:error, :cheats_disabled}, state}
    end
  end

  # Shared plumbing for the government RPCs: back-fill, gate, run the
  # engine op, settle its events, broadcast the updated faction state
  # (icons/chat pattern: whole-struct broadcast keeps every member's
  # copy in sync without bespoke delta messages).
  defp with_government(state, fun) do
    data = ensure_government(state.data, state.speed)

    case Map.get(data, :government) do
      nil ->
        {:reply, {:error, :government_disabled}, %{state | data: data}}

      government ->
        ctx = Government.build_ctx(data)

        case fun.(Government.backfill(government), ctx) do
          {:ok, government, events} ->
            state = %{state | data: Map.put(data, :government, government)}
            state = settle_government_events(state, events)
            state = persist_government(state)
            # Any government mutation may change the faction-wide effects
            # (bonuses, tax rates) — push the fresh payload to members.
            push_government_effects(state)
            FactionChannel.broadcast_change(state.channel, %{faction_faction: state.data})
            {:reply, :ok, reschedule_tick(state)}

          {:error, reason} ->
            {:reply, {:error, reason}, %{state | data: data}}
        end
    end
  end

  defp push_government_effects(state) do
    case Map.get(state.data, :government) do
      nil ->
        :ok

      government ->
        ctx = %{instance_id: state.instance_id}
        effects = Government.effects(government, ctx)

        Enum.each(state.data.players, fn player ->
          Game.cast(state.instance_id, :player, player.id, {:set_government_effects, effects})
        end)
    end
  end

  # Government ops can move the next deadline (a debug advance, the last
  # vote before a close). The tick decorator reschedules at handler ENTRY
  # — before the mutation — so without this the new deadline waits for
  # the previously scheduled tick (up to ~9 wall-minutes at Legacy speed,
  # and nothing ever pokes a faction with no connected members).
  defp reschedule_tick(%{tick: %{running?: true}} = state) do
    interval = Faction.compute_next_tick_interval(state.data)
    interval = Core.Tick.unit_time_to_millisecond(state.tick, interval)
    %{state | tick: Core.Tick.next(state.tick, interval)}
  end

  defp reschedule_tick(state), do: state

  # Vote casting with the two stake-kind preambles that need player
  # agent round-trips: Cardan pledges snapshot the pledger's ideology
  # income rate; ARK bids escrow the credit delta BEFORE the engine
  # records the stake (refunded if the engine then rejects the vote).
  defp cast_government_vote(government, actor_id, ballot_id, payload, ctx) do
    case Government.voter_stake(government, ballot_id, actor_id) do
      {:error, reason} ->
        {:error, reason}

      {:ok, current_stake, kind} ->
        case kind do
          :stake_pledge ->
            pct = Map.get(payload, :pct, 0)
            stake = own_ideology_income(ctx, actor_id) * pct / 100
            payload = Map.put(payload, :stake, stake)
            Government.cast_vote(government, actor_id, ballot_id, payload, ctx)

          :stake_bid ->
            cast_bid(government, actor_id, ballot_id, payload, current_stake, ctx)

          _ ->
            Government.cast_vote(government, actor_id, ballot_id, payload, ctx)
        end
    end
  end

  defp cast_bid(government, actor_id, ballot_id, payload, current_stake, ctx) do
    amount = Map.get(payload, :amount, 0)
    delta = amount - current_stake

    cond do
      not is_integer(amount) or amount <= 0 ->
        {:error, :invalid_payload}

      delta < 0 ->
        {:error, :cannot_lower_bid}

      true ->
        with :ok <- escrow_bid(ctx, actor_id, delta) do
          payload = %{candidate_id: Map.get(payload, :candidate_id), stake: amount}

          case Government.cast_vote(government, actor_id, ballot_id, payload, ctx) do
            {:ok, _government, _events} = success ->
              success

            {:error, _reason} = error ->
              # The engine rejected the vote after we took the money —
              # give the delta straight back (async, same as market
              # seller credit).
              if delta > 0,
                do: Game.cast(ctx.instance_id, :player, actor_id, {:add_resources, delta, 0, 0})

              error
          end
        end
    end
  end

  defp escrow_bid(_ctx, _actor_id, 0), do: :ok

  defp escrow_bid(ctx, actor_id, delta) do
    Game.call(
      ctx.instance_id,
      :player,
      actor_id,
      {:try_debit_send, %{credit: delta, technology: 0, ideology: 0}}
    )
  end

  defp own_ideology_income(ctx, player_id) do
    case Game.call(ctx.instance_id, :player, player_id, :get_state) do
      {:ok, %{ideology: %{change: change}}} -> max(change, 0)
      _ -> 0
    end
  end

  # Government events, from ticks (drained) and from direct ops:
  # `:refund` settles escrow; lifecycle milestones go to the faction
  # audit log and (Legacy pace only, same guard as :add_player) the
  # player-event card feed. Leadership ceremony events additionally
  # relay to Discord (best-effort cast; no-op without the bot).
  defp settle_government_events(state, events) do
    {events, consolidated_cards} = consolidate_failed_round(events)

    state =
      Enum.reduce(events, state, fn event, state ->
        settle_government_event(state, event)
        # Discord relay decides which events broadcast (leadership
        # ceremony only — patents/lexes/taxes/policy churn stay off the
        # wire by design, user decision 2026-07-18). Non-ceremony events
        # are dropped inside post_async before any cast happens.
        RC.Discord.GovRelay.post_async(state.instance_id, state.data.key, event)
        state
      end)

    Enum.each(consolidated_cards, fn {key, data} -> government_player_event(state, key, data) end)
    state
  end

  # A grouped election that fails re-opens every seat on the same tick
  # (Cardan's tithe rounds), so one failed round would otherwise spew a
  # "vote concluded" AND a "re-vote begins" player card PER SEAT — six
  # timeline entries stamped the same second. Collapse the player-facing
  # feed to ONE card for the whole round. The per-seat AUDIT rows and the
  # Discord relay still fire for every ballot (dispute trail intact); only
  # the timeline cards are suppressed via a transient `:_suppress_card`
  # marker the ballot_closed/revote_opened clauses honour. Winners are
  # never collapsed — a seated candidate is worth naming on its own.
  # Public only so the pure transform can be unit-tested (same reason
  # `Government.advance/3` is public); game code reaches it via
  # `settle_government_events/2`.
  @doc false
  def consolidate_failed_round(events) do
    revotes = Enum.filter(events, &(&1.type == :revote_opened))

    exhausted? =
      Enum.any?(events, &match?(%{type: :election_failed, reason: :quorum_rounds_exhausted}, &1))

    if revotes == [] and not exhausted? do
      {events, []}
    else
      events =
        Enum.map(events, fn
          %{type: :ballot_closed, outcome: outcome} = e when outcome not in [:seated, :approved] ->
            Map.put(e, :_suppress_card, true)

          %{type: :revote_opened} = e ->
            Map.put(e, :_suppress_card, true)

          e ->
            e
        end)

      failed_seats =
        events
        |> Enum.filter(&(&1.type == :ballot_closed and Map.get(&1, :_suppress_card, false)))
        |> Enum.map(& &1.seat)
        |> Enum.uniq()

      card =
        if revotes != [] do
          {"election_revote", %{seats: failed_seats, round: revotes |> Enum.map(& &1.round) |> Enum.max()}}
        else
          {"election_abandoned", %{seats: failed_seats}}
        end

      {events, [card]}
    end
  end

  defp settle_government_event(state, %{type: :refund} = event) do
    Game.cast(state.instance_id, :player, event.player_id, {:add_resources, event.credit, 0, 0})
  end

  defp settle_government_event(state, %{type: :elections_opened} = event) do
    write_log_entry(state, "election_opened", nil, nil, %{seats: event.seats, renewal: event.renewal})
    government_player_event(state, "election_started", %{seats: event.seats})
  end

  defp settle_government_event(state, %{type: :ballot_closed} = event) do
    payload = %{
      seat: event.seat,
      question: event.question,
      outcome: event.outcome,
      winner: event.winner && event.winner.name
    }

    write_log_entry(state, "election_closed", nil, event.winner && event.winner.player_id, payload)

    unless Map.get(event, :_suppress_card, false),
      do: government_player_event(state, "election_ended", payload)
  end

  defp settle_government_event(state, %{type: :seat_changed} = event) do
    write_log_entry(state, "government_seat_changed", nil, event.player_id, %{
      seat: event.seat,
      name: event.name
    })
  end

  defp settle_government_event(state, %{type: :revote_opened} = event) do
    unless Map.get(event, :_suppress_card, false),
      do: government_player_event(state, "election_revote", %{seat: event.seat, round: event.round})
  end

  defp settle_government_event(state, %{type: :government_dissolved} = event) do
    write_log_entry(state, "government_dissolved", nil, nil, %{reason: event.reason})
    government_player_event(state, "government_dissolved", %{reason: event.reason})
  end

  defp settle_government_event(state, %{type: :seat_incapacitated} = event) do
    payload = %{seat: event.seat, name: event.name, reason: event.reason}
    write_log_entry(state, "seat_incapacitated", nil, event.player_id, payload)
    government_player_event(state, "seat_incapacitated", payload)
  end

  defp settle_government_event(state, %{type: :deposition_started} = event) do
    write_log_entry(state, "deposition_started", event.by, nil, %{seat: event.seat})
    government_player_event(state, "deposition_started", %{seat: event.seat})
  end

  defp settle_government_event(state, %{type: :deposed} = event) do
    payload = %{seat: event.seat, name: event.name}
    write_log_entry(state, "deposed", nil, event.player_id, payload)
    government_player_event(state, "deposed", payload)
  end

  defp settle_government_event(state, %{type: :deposition_failed} = event) do
    write_log_entry(state, "deposition_failed", nil, nil, %{seat: event.seat})
  end

  defp settle_government_event(state, %{type: :nomination_window_expired} = event) do
    write_log_entry(state, "nomination_window_expired", nil, nil, %{
      strikes: event.strikes,
      failed_rounds: event.failed_rounds
    })
  end

  defp settle_government_event(state, %{type: :cabinet_dissolved} = event) do
    write_log_entry(state, "cabinet_dissolved", event.by, nil, %{})
    government_player_event(state, "cabinet_dissolved", %{})
  end

  defp settle_government_event(state, %{type: :crisis_vote_started} = event) do
    write_log_entry(state, "crisis_vote_started", event.by, nil, %{})
    government_player_event(state, "crisis_vote_started", %{})
  end

  defp settle_government_event(state, %{type: :challenge_started} = event) do
    payload = %{name: event.name, stake: event.stake}
    write_log_entry(state, "challenge_started", event.challenger_id, nil, payload)
    government_player_event(state, "challenge_started", payload)
  end

  defp settle_government_event(state, %{type: :challenge_defended} = event) do
    payload = %{name: event.name, stake: event.stake, penalty: event.penalty}
    write_log_entry(state, "challenge_defended", nil, event.challenger_id, payload)
    government_player_event(state, "challenge_defended", payload)
  end

  defp settle_government_event(state, %{type: :government_overthrown} = event) do
    payload = %{name: event.name, stake: event.stake}
    write_log_entry(state, "government_overthrown", nil, event.challenger_id, payload)
    government_player_event(state, "government_overthrown", payload)
  end

  defp settle_government_event(state, %{type: :tithe_settled} = event) do
    write_log_entry(state, "tithe_settled", nil, nil, %{
      seat: event.seat,
      total: event.total,
      pledgers: event.pledgers
    })
  end

  # Royal prerogative: the accountability half of the mechanic — every
  # member's newspaper reports what the monarch's impatience costs them.
  defp settle_government_event(state, %{type: :leader_overreach} = event) do
    payload = %{seat: event.seat, action: event.action, malus: event.malus, name: event.name}
    write_log_entry(state, "leader_overreach", event.by, nil, payload)
    government_player_event(state, "leader_overreach", %{name: event.name, malus: event.malus})
  end

  defp settle_government_event(state, %{type: :laws_proposed} = event) do
    write_log_entry(state, "laws_proposed", event.by, nil, %{laws: event.laws})
  end

  defp settle_government_event(state, %{type: :withdraw_cap_changed} = event) do
    write_log_entry(state, "withdraw_cap_changed", event.by, nil, %{pct: event.pct})
  end

  defp settle_government_event(state, %{type: :treasury_withdrawn} = event) do
    write_log_entry(state, "treasury_withdrawn", event.by, nil, %{
      amounts: event.amounts,
      net: event.net
    })
  end

  defp settle_government_event(state, %{type: :treasury_granted} = event) do
    write_log_entry(state, "treasury_granted", event.by, event.player_id, %{
      amounts: event.amounts
    })
  end

  defp settle_government_event(state, %{type: :treasury_donated} = event) do
    write_log_entry(state, "treasury_donated", event.by, nil, %{amounts: event.amounts})
  end

  defp settle_government_event(state, %{type: :laws_rejected} = event) do
    write_log_entry(state, "laws_rejected", nil, nil, %{laws: event.laws})
  end

  defp settle_government_event(state, %{type: :taxes_changed} = event) do
    write_log_entry(state, "taxes_changed", event.by, nil, %{rates: event.rates})
  end

  defp settle_government_event(state, %{type: :laws_changed} = event) do
    write_log_entry(state, "laws_changed", event.by, nil, %{laws: event.laws})
  end

  defp settle_government_event(state, %{type: :grant} = event) do
    Game.cast(
      state.instance_id,
      :player,
      event.player_id,
      {:add_resources, event.credit, event.technology, event.ideology}
    )
  end

  defp settle_government_event(state, %{type: :treasury_distributed} = event) do
    write_log_entry(state, "treasury_distributed", event.by, nil, %{
      pct: event.pct,
      shares: event.shares
    })

    government_player_event(state, "treasury_distributed", %{shares: event.shares})
  end

  defp settle_government_event(state, %{type: purchase} = event)
       when purchase in [:patent_purchased, :lex_purchased] do
    write_log_entry(state, "government_purchase", event.by, nil, %{
      kind: event.type,
      key: event.key,
      cost: event.cost
    })
  end

  defp settle_government_event(state, %{type: :station_ordered} = event) do
    payload = %{system_id: event.system_id, key: event.key, level: event.level, cost: event.cost}
    write_log_entry(state, "station_ordered", event.by, nil, payload)

    government_player_event(state, "station_ordered", %{
      key: Atom.to_string(event.key),
      level: event.level
    })
  end

  defp settle_government_event(state, %{type: :station_cancelled} = event) do
    write_log_entry(state, "station_cancelled", event.by, nil, %{
      system_id: event.system_id,
      key: event.key,
      level: event.level,
      refund: event.refund
    })
  end

  defp settle_government_event(state, %{type: :station_demolished} = event) do
    payload = %{system_id: event.system_id, key: event.key, level: event.level}
    write_log_entry(state, "station_demolished", event.by, nil, payload)

    government_player_event(state, "station_demolished", %{key: Atom.to_string(event.key)})
  end

  # The all-or-nothing upkeep power flip: fan the new state out to every
  # system holding one of our station buildings, and tell the members —
  # an unpowered station fleet is the kind of thing a treasury debate
  # starts over.
  defp settle_government_event(state, %{type: :station_power} = event) do
    Enum.each(event.system_ids, fn system_id ->
      Game.cast(state.instance_id, :stellar_system, system_id, {:station_set_power, event.powered})
    end)

    write_log_entry(state, "station_power_changed", nil, nil, %{powered: event.powered})

    card_key = if event.powered, do: "station_power_on", else: "station_power_off"
    government_player_event(state, card_key, %{})
  end

  defp settle_government_event(state, %{type: :gateway_link_started} = event) do
    stamp_gateway_link(state, event.link)
    write_log_entry(state, "gateway_link_started", event.by, nil, link_log_payload(event.link))
  end

  defp settle_government_event(state, %{type: :gateway_linked} = event) do
    stamp_gateway_link(state, event.link)
    write_log_entry(state, "gateway_linked", nil, nil, link_log_payload(event.link))
    government_player_event(state, "gateway_linked", %{})
  end

  defp settle_government_event(state, %{type: :gateway_unlink_started} = event) do
    stamp_gateway_link(state, event.link)
    write_log_entry(state, "gateway_unlink_started", event.by, nil, link_log_payload(event.link))
  end

  defp settle_government_event(state, %{type: :gateway_unlinked} = event) do
    stamp_gateway_link(state, event.link, :cleared)
    write_log_entry(state, "gateway_unlinked", nil, nil, link_log_payload(event.link))
    government_player_event(state, "gateway_unlinked", %{})
  end

  # Wind-down over — refresh the endpoint stamps (their `busy` flag).
  defp settle_government_event(state, %{type: :gateway_ready} = event) do
    stamp_gateway_link(state, event.link)
  end

  # Capture tore the link down: clear both endpoint stamps and abort a
  # traveler caught still charging (mid-jump travelers land regardless).
  defp settle_government_event(state, %{type: :gateway_link_broken} = event) do
    stamp_gateway_link(state, event.link, :cleared)

    if event.abort_character_id do
      Game.cast(state.instance_id, :character, event.abort_character_id, {:gateway_abort})
    end

    write_log_entry(state, "gateway_link_broken", nil, nil, link_log_payload(event.link))
    government_player_event(state, "gateway_link_broken", %{})
  end

  # Heartbeat from the government tick: re-push effects to members and
  # refresh the faction broadcast so quiet factions' treasury/laws
  # displays don't go stale.
  defp settle_government_event(state, %{type: :sync_effects}) do
    push_government_effects(state)
    FactionChannel.broadcast_change(state.channel, %{faction_faction: state.data})
  end

  # :ballot_opened, :candidate_added, :vote_cast, :appointment_* and
  # :election_failed ride the faction broadcast; logging them would only
  # add noise to the audit table.
  defp settle_government_event(_state, _event), do: :ok

  # Push a link's current state onto both endpoint systems' station
  # buildings (UI + system JSON); :cleared wipes the stamp instead.
  defp stamp_gateway_link(state, link, mode \\ :current) do
    Enum.each(link.endpoints, fn endpoint ->
      info =
        case mode do
          :cleared ->
            nil

          :current ->
            other = Enum.find(link.endpoints, &(&1.system_id != endpoint.system_id))

            %{
              status: link.status,
              target_system_id: other.system_id,
              busy: link.transit != nil
            }
        end

      Game.cast(
        state.instance_id,
        :stellar_system,
        endpoint.system_id,
        {:station_link_update, endpoint.building_id, info}
      )
    end)
  end

  defp link_log_payload(link) do
    %{link_id: link.id, systems: Enum.map(link.endpoints, & &1.system_id), status: link.status}
  end

  defp government_player_event(state, key, data) do
    if state.speed != :fast do
      faction_data = Data.Querier.one(Data.Game.Faction, state.instance_id, state.data.key)

      RC.PlayerEvents.create(%{
        type: "faction",
        key: key,
        data: Jason.encode!(Map.put(data, :theme, faction_data.theme)),
        instance_id: state.instance_id,
        faction_id: state.data.id
      })
    end
  end

  # Cross-player icon replacement: log who overwrote whose marker
  # with what. Self-overwrites (player changes their mind about
  # their own icon) are silently skipped — the user-visible
  # accountability surface would otherwise fill with noise.
  defp log_icon_replaced(_state, _placer_id, %{previous: nil}, _new_kind), do: :ok

  defp log_icon_replaced(_state, placer_id, %{previous: %{placer_profile_id: same}}, _new_kind)
       when same == placer_id,
       do: :ok

  defp log_icon_replaced(state, placer_id, %{previous: previous, current: current}, new_kind) do
    write_log_entry(state, "icon_replaced", placer_id, previous.placer_profile_id, %{
      system_id: current.system_id,
      system_name: fetch_system_name(state.instance_id, current.system_id),
      previous_kind: previous.icon_kind,
      new_kind: new_kind,
      actor_name: Faction.get_player_name(state.data, placer_id),
      target_name: Faction.get_player_name(state.data, previous.placer_profile_id)
    })
  end

  defp log_icon_removed(_state, _requester_id, nil), do: :ok

  defp log_icon_removed(_state, requester_id, %{placer_id: same}) when same == requester_id,
    do: :ok

  defp log_icon_removed(state, requester_id, removed) do
    write_log_entry(state, "icon_removed", requester_id, removed.placer_id, %{
      system_id: removed.system_id,
      system_name: fetch_system_name(state.instance_id, removed.system_id),
      icon_kind: removed.kind,
      actor_name: Faction.get_player_name(state.data, requester_id),
      target_name: Faction.get_player_name(state.data, removed.placer_id)
    })
  end

  defp write_log_entry(state, event_type, actor_id, target_id, payload) do
    case RC.Instances.FactionEventLogs.record(%{
           instance_id: state.instance_id,
           faction_id: state.data.id,
           actor_profile_id: actor_id,
           target_profile_id: target_id,
           event_type: event_type,
           payload: payload
         }) do
      {:ok, _entry} ->
        :ok

      {:error, changeset} ->
        # Audit logging is best-effort. Surface the failure to the
        # operator log but don't crash the per-faction agent — a
        # missed audit row is recoverable; a downed faction isn't.
        Logger.warning(
          "faction_event_log insert failed: #{inspect(changeset.errors)} " <>
            "(instance=#{state.instance_id}, faction=#{state.data.id}, type=#{event_type})"
        )

        :ok
    end
  end

  defp fetch_system_name(instance_id, system_id) do
    case Game.call(instance_id, :stellar_system, system_id, :get_state) do
      {:ok, %{name: name}} -> name
      _ -> nil
    end
  end

  @decorate tick()
  def on_cast({:remove_informer, system_id}, state) do
    {change, data} = Faction.remove_informer(state.data, system_id)

    Game.cast(state.instance_id, :galaxy, :master, {:update_contacts, data.key, data.contacts})

    if MapSet.member?(change, :radar_update) do
      FactionChannel.broadcast_change(state.channel, %{faction_faction: data})
    end

    {:noreply, %{state | data: data}}
  end

  # Stage 4 #C1 + #H8 fix.
  #
  # `from` is now the JWT-bound `player_id` (integer) sent from the
  # channel handler — NOT a client-supplied string. We resolve the
  # display name here against the authoritative faction roster, so the
  # stored ChatMessage author always matches the real authenticated
  # sender.
  #
  # Defensive guards on shape: `is_integer(from)` + `is_binary(message)`.
  # The channel boundary already validates this, but the agent is shared
  # by every faction member and any future caller bug would otherwise
  # crash the whole faction. Catch-all returns unchanged state.
  @decorate tick()
  def on_cast({:push_message, from, message}, state)
      when is_integer(from) and is_binary(message) do
    display_name = Faction.get_player_name(state.data, from)
    data = Faction.push_message(state.data, display_name, from, message)
    FactionChannel.broadcast_change(state.channel, %{faction_faction: data})

    {:noreply, %{state | data: data}}
  end

  def on_cast({:push_message, _from, _message}, state) do
    Logger.warning("ignoring malformed :push_message payload")
    {:noreply, state}
  end

  # Server-originated system chat line (the deploy "update applied"
  # announcement, etc.). Same wire shape as the genesis CHEAT
  # announcement: from "SYSTEM", from_id nil. Only ever cast from trusted
  # server code (RC.Deploy fan-out), never from a channel's client-facing
  # handlers.
  @decorate tick()
  def on_cast({:push_system_message, message}, state) when is_binary(message) do
    data = Faction.push_system_message(state.data, message)
    FactionChannel.broadcast_change(state.channel, %{faction_faction: data})

    {:noreply, %{state | data: data}}
  end

  def on_cast({:radar_update, system}, state) do
    data =
      case Faction.radar_update(state.data, system) do
        {:radar_update, data} ->
          FactionChannel.broadcast_change(state.channel, %{faction_faction: data})
          data

        {:no_radar_update, data} ->
          data
      end

    {:noreply, %{state | data: data}}
  end

  @decorate tick()
  def on_info(:tick, state) do
    {:noreply, state}
  end

  # TICK FUNCTIONS

  defp do_next_tick(state, next_tick) do
    data = ensure_government(state.data, state.speed)
    pre_tick_government = Map.get(data, :government)
    {change, data} = Faction.next_tick(data, next_tick)

    # Government milestones (founding over, ballots opened/closed, seats
    # changed, refunds due) accumulate on the struct during the tick;
    # settle them here and push the fresh state to every member.
    data =
      if MapSet.member?(change, :government_update) do
        {events, government} = Government.drain_events(data.government)
        data = Map.put(data, :government, government)

        _ = settle_government_events(%{state | data: data}, events)
        FactionChannel.broadcast_change(state.channel, %{faction_faction: data})
        data
      else
        data
      end

    # Tick advances mutate the government too (election countdowns, term
    # clocks, closes) — keep the durable copy current so a crash never
    # rewinds an election players are watching.
    state =
      if Map.get(data, :government) != pre_tick_government,
        do: persist_government(%{state | data: data}),
        else: %{state | data: data}

    data = state.data

    if MapSet.member?(change, :update_object) do
      # Broadcast the internal blip list verbatim. Per-recipient
      # sanitization (drop the viewer's own characters, strip
      # `character_id` + `owner_player_id`) runs in
      # Portal.Controllers.FactionChannel.handle_out/3 — see the
      # sanitize_for_viewer/2 path there. Doing it at the channel
      # boundary instead of the agent lets us filter per-player
      # (so faction-mates remain visible as anonymous radar blips),
      # which the previous agent-side faction-wide filter could not
      # express.
      FactionChannel.broadcast_change(state.channel, %{detected_objects: data.detected_objects})
    end

    if MapSet.member?(change, :new_object_in_radar) do
      notif = Notification.Sound.new(:new_object_in_radar)
      FactionChannel.broadcast_change(state.channel, %{player_notifs: [notif]})
    end

    {%{state | data: data}, Faction}
  end
end

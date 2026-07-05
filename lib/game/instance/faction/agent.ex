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
  # one if (and only if) this instance's speed runs the feature. The
  # founding countdown therefore starts at first tick after creation —
  # or, for existing Legacy games, at the first tick after the deploy
  # that ships the feature.
  defp ensure_government(data, speed) do
    case Map.get(data, :government) do
      nil ->
        if Government.enabled?(speed),
          do: Map.put(data, :government, Government.new(Government.build_ctx(data))),
          else: Map.put(data, :government, nil)

      _government ->
        data
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
        {:noreply, %{state | data: Map.put(data, :government, government)}}
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
  # player-event card feed.
  defp settle_government_events(state, events) do
    Enum.reduce(events, state, fn event, state ->
      settle_government_event(state, event)
      state
    end)
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
    government_player_event(state, "election_ended", payload)
  end

  defp settle_government_event(state, %{type: :seat_changed} = event) do
    write_log_entry(state, "government_seat_changed", nil, event.player_id, %{
      seat: event.seat,
      name: event.name
    })
  end

  defp settle_government_event(state, %{type: :revote_opened} = event) do
    government_player_event(state, "election_revote", %{seat: event.seat, round: event.round})
  end

  defp settle_government_event(state, %{type: :government_dissolved} = event) do
    write_log_entry(state, "government_dissolved", nil, nil, %{reason: event.reason})
    government_player_event(state, "government_dissolved", %{reason: event.reason})
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

defmodule Instance.Faction.Government do
  use TypedStruct
  use Util.MakeEnumerable

  alias Core.CooldownValue
  alias Instance.Faction.Government
  alias Instance.Faction.Government.Ballot
  alias Instance.Faction.Government.Rules

  @moduledoc """
  Faction government: the election engine. Legacy-only (see `enabled?/1`).

  One `%Government{}` lives on each faction's runtime state
  (`Instance.Faction.Faction.government`) and is driven from the faction
  tick. The engine owns the generic ballot lifecycle — the founding
  countdown, opening/closing ballots, group quorum, seats, treasury,
  history — while everything faction-specific is delegated to a
  `Government.Rules` module chosen by faction key.

  Durability: the struct rides the faction agent's normal
  snapshot/restore, so it survives deploys. It is a NEW field on a
  snapshotted struct — all access from the agent goes through the
  `ensure_government/2` back-fill (see Faction.Agent), never bare
  dot-access on restored state. Lifecycle milestones are journaled to
  `faction_event_log`; per-vote DB journaling is deliberately deferred
  (a crash can lose up to one autosave interval of votes — accepted for
  v1).

  Time: every duration is game-time (`ut`, 1 ut = 3 wall-minutes on
  Legacy speed), ticked by `Core.CooldownValue` — pauses and deploys
  freeze election clocks instead of eating the window.
  """

  @history_cap 20

  def jason(), do: [except: [:pending_events, :meta]]

  typedstruct enforce: true do
    # :founding (pre-election grace period) | :running
    field(:phase, atom())
    field(:founding, %CooldownValue{})
    # %{leader: nil | %{player_id, name}, economy: …, military: …}
    field(:seats, map())
    field(:ballots, [Ballot.t()])
    field(:history, [map()])
    field(:treasury, map())
    field(:term, %CooldownValue{} | nil)
    field(:counter, integer())
    field(:pending_events, [map()])
    # Rules-module scratch state (e.g. Synelle's failed-nomination
    # counter). Server-internal, never serialized to clients.
    field(:meta, map())
    # Phase 2 — the treasury economy. Income tax rates (percent,
    # engine-capped at government_tax_cap) set by the Head of Economy;
    # faction research and laws bought from the treasury.
    field(:tax_rates, map())
    field(:faction_patents, [atom()])
    field(:faction_lexes, [atom()])
    field(:active_laws, [atom()])
    field(:law_cooldown, %CooldownValue{})
    # Self-healing re-push of effects to member Player.Agents (covers
    # restarts and lost casts); reset each time it fires.
    field(:effects_sync, %CooldownValue{})
  end

  # Interval of the effects self-heal push, in game-time units
  # (~1h wall at Legacy speed, ~30s at :fast).
  @effects_sync_interval 20

  @doc """
  Government runs only in Legacy games (`:slow`). The config flag lets
  dev/test environments exercise it at faster speeds; it is off in prod.
  """
  def enabled?(speed),
    do: speed == :slow or Application.get_env(:rc, :government_all_speeds, false)

  def new(ctx) do
    %Government{
      phase: :founding,
      founding: CooldownValue.new(ctx.constants.government_founding_duration),
      seats: %{leader: nil, economy: nil, military: nil},
      ballots: [],
      history: [],
      treasury: %{credit: 0, technology: 0, ideology: 0},
      term: nil,
      counter: 1,
      pending_events: [],
      meta: %{},
      tax_rates: %{credit: 0, technology: 0, ideology: 0},
      faction_patents: [],
      faction_lexes: [],
      active_laws: [],
      law_cooldown: CooldownValue.new(),
      effects_sync: CooldownValue.new(@effects_sync_interval)
    }
  end

  # Fields added after the first government snapshots existed — back-fill
  # restored structs at the tick/ops boundary so pre-field shapes never
  # dot-access-crash (same convention as :meta and ensure_government).
  def backfill(government) do
    government
    |> Map.put_new(:meta, %{})
    |> Map.put_new(:tax_rates, %{credit: 0, technology: 0, ideology: 0})
    |> Map.put_new(:faction_patents, [])
    |> Map.put_new(:faction_lexes, [])
    |> Map.put_new(:active_laws, [])
    |> Map.put_new(:law_cooldown, CooldownValue.new())
    |> Map.put_new(:effects_sync, CooldownValue.new(@effects_sync_interval))
  end

  # :meta arrived after the first government snapshots existed — back-fill
  # on read so restored pre-:meta structs don't KeyError (same convention
  # as ensure_government at the agent boundary).
  def get_meta(government, key, default),
    do: government |> Map.get(:meta, %{}) |> Map.get(key, default)

  def put_meta(government, key, value),
    do: Map.put(government, :meta, Map.put(Map.get(government, :meta, %{}), key, value))

  # ----------------------------------------------------------------
  # Faction tick pipeline step
  # ----------------------------------------------------------------

  @doc """
  Pipeline step for `Instance.Faction.Faction.next_tick/2`. Tick-driven
  events (elections opening/closing, seats changing, refunds) accumulate
  in `pending_events`; the agent drains and settles them after the tick.
  """
  def tick({change, state}, elapsed_time) do
    case Map.get(state, :government) do
      nil ->
        {change, state}

      government ->
        government = backfill(government)
        ctx = build_ctx(state)
        {government, events} = advance(government, elapsed_time, ctx)

        change =
          if events == [],
            do: change,
            else: MapSet.put(change, :government_update)

        government = %{government | pending_events: government.pending_events ++ events}
        {change, Map.put(state, :government, government)}
    end
  end

  def drain_events(%Government{} = government),
    do: {government.pending_events, %{government | pending_events: []}}

  @doc """
  Soonest government deadline (founding end, ballot close, term expiry)
  in game-time units, or nil when nothing is pending. The faction agent
  uses this to schedule its next tick ON the deadline instead of up to
  a full tick interval late — at Legacy speed a faction ticks every
  ~9 wall-minutes, which would otherwise delay every election close by
  up to that much past the countdown players watch.
  """
  def next_deadline(%Government{phase: :founding} = government),
    do: positive_or_nil(government.founding.value)

  def next_deadline(%Government{} = government) do
    ballot_deadlines = Enum.map(government.ballots, & &1.cooldown.value)
    term_deadline = if government.term, do: [government.term.value], else: []

    (ballot_deadlines ++ term_deadline)
    |> Enum.filter(&(&1 > 0))
    |> Enum.min(fn -> nil end)
  end

  defp positive_or_nil(value) when value > 0, do: value
  defp positive_or_nil(_value), do: nil

  @doc "Build the rules ctx from live faction state (agent-side helper)."
  def build_ctx(faction_state) do
    instance_id = faction_state.instance_id

    %{
      instance_id: instance_id,
      faction_id: faction_state.id,
      faction_key: faction_state.key,
      players: faction_state.players,
      constants: Data.Querier.one(Data.Game.Constant, instance_id, :main),
      faction_ideology_income: fn -> faction_ideology_income(faction_state) end,
      active_player_count: fn -> active_player_count(faction_state) end
    }
  end

  # Active-member count (Synelle approval threshold base). Fan-out like
  # faction_ideology_income; if every agent is unreachable, fall back to
  # roster size rather than letting a 0-threshold rubber-stamp votes.
  defp active_player_count(faction_state) do
    count =
      faction_state.players
      |> Task.async_stream(
        fn player ->
          case Game.call(faction_state.instance_id, :player, player.id, :get_state) do
            {:ok, %{is_active: active}} -> active != false
            _ -> false
          end
        end,
        on_timeout: :kill_task
      )
      |> Enum.count(fn
        {:ok, true} -> true
        _ -> false
      end)

    if count == 0, do: length(faction_state.players), else: count
  end

  # Faction-wide ideology income rate (Cardan quorum base). Fan-out to
  # the member Player.Agents, same pattern as update_detected_object;
  # unreachable players count 0 — an election must not crash on a dead
  # agent.
  defp faction_ideology_income(faction_state) do
    faction_state.players
    |> Task.async_stream(
      fn player ->
        case Game.call(faction_state.instance_id, :player, player.id, :get_state) do
          {:ok, %{ideology: %{change: change}}} -> change
          _ -> 0
        end
      end,
      on_timeout: :kill_task
    )
    |> Enum.reduce(0, fn
      {:ok, change}, acc -> acc + max(change, 0)
      _, acc -> acc
    end)
  end

  @doc """
  Advance the government clock by `elapsed_time` (game-time units).
  Public so tests can drive the lifecycle with a stubbed ctx; game code
  goes through `tick/2`.
  """
  def advance(%Government{phase: :founding} = government, elapsed_time, ctx) do
    founding = CooldownValue.next_tick(government.founding, elapsed_time)
    government = %{government | founding: founding}

    if CooldownValue.locked?(founding) do
      {government, []}
    else
      rules = Rules.module_for(ctx.faction_key)
      {government, open_events} = open_ballots(government, rules.initial_ballots(ctx))

      government = %{government | phase: :running, term: term_from_spec(rules.term_spec(ctx))}

      seats = government.ballots |> Enum.map(& &1.seat) |> Enum.uniq()
      {government, [%{type: :elections_opened, seats: seats, renewal: false} | open_events]}
    end
  end

  def advance(%Government{phase: :running} = government, elapsed_time, ctx) do
    ballots = Enum.map(government.ballots, &Ballot.next_tick(&1, elapsed_time))

    government = %{
      government
      | ballots: ballots,
        law_cooldown: CooldownValue.next_tick(government.law_cooldown, elapsed_time)
    }

    {government, close_events} = close_expired(government, ctx)
    {government, term_events} = tick_term(government, elapsed_time, ctx)
    {government, sync_events} = tick_effects_sync(government, elapsed_time)

    {government, close_events ++ term_events ++ sync_events}
  end

  # Periodic :sync_effects heartbeat — the agent re-pushes the current
  # effects payload to every member Player.Agent, healing missed casts
  # and post-restart caches.
  defp tick_effects_sync(%Government{} = government, elapsed_time) do
    sync = CooldownValue.next_tick(government.effects_sync, elapsed_time)

    if CooldownValue.locked?(sync) do
      {%{government | effects_sync: sync}, []}
    else
      {%{government | effects_sync: CooldownValue.set(sync, @effects_sync_interval)},
       [%{type: :sync_effects}]}
    end
  end

  defp term_from_spec(nil), do: nil
  defp term_from_spec(%{duration: duration}), do: CooldownValue.new(duration)

  defp tick_term(%Government{term: nil} = government, _elapsed_time, _ctx), do: {government, []}

  defp tick_term(%Government{} = government, elapsed_time, ctx) do
    term = CooldownValue.next_tick(government.term, elapsed_time)

    if CooldownValue.locked?(term) do
      {%{government | term: term}, []}
    else
      rules = Rules.module_for(ctx.faction_key)
      {government, events} = rules.on_term_expired(%{government | term: term}, ctx)

      # Re-arm the mandate clock for the next cycle.
      {%{government | term: CooldownValue.set(term, term.initial)}, events}
    end
  end

  # ----------------------------------------------------------------
  # Ballot close
  # ----------------------------------------------------------------

  # Ballots close in groups: grouped ballots (Cardan rounds, Myrmezir
  # cycles) share one duration, so they expire on the same tick and any
  # election-wide quorum is computed across the whole group.
  defp close_expired(%Government{} = government, ctx) do
    {expired, open} = Enum.split_with(government.ballots, &Ballot.expired?/1)

    if expired == [] do
      {government, []}
    else
      government = %{government | ballots: open}

      expired
      |> Enum.group_by(& &1.group)
      |> Enum.reduce({government, []}, fn {_group, ballots}, {government, events} ->
        quorum_met = group_quorum_stage(ballots, ctx) == 3

        Enum.reduce(ballots, {government, events}, fn ballot, {government, events} ->
          result = ballot_result(ballot, quorum_met, ctx)
          {government, close_events} = apply_close(government, ballot, result, ctx)
          {government, events ++ close_events}
        end)
      end)
    end
  end

  # Approval votes pass on at least half the ACTIVE membership approving
  # (not a majority of votes cast) — an unanswered nomination is a failed
  # nomination, which is what arms Synelle's dissolution counter.
  defp ballot_result(%Ballot{kind: :approval} = ballot, _quorum_met, ctx),
    do: Ballot.tally_approval(ballot, ctx.active_player_count.())

  defp ballot_result(ballot, quorum_met, _ctx) do
    if ballot.quorum != nil and not quorum_met,
      do: {:failed, :quorum_not_met, Ballot.candidate_totals(ballot)},
      else: Ballot.tally(ballot)
  end

  # Election-wide pledge progress, bucketed so clients never see the
  # numbers: 0 (< 1/3 of the quorum), 1 (< 2/3), 2 (< met), 3 (met).
  # Stage 3 is the close condition; the stages below only feed the
  # client's staged indicator.
  defp group_quorum_stage(ballots, ctx) do
    case Enum.find(ballots, &(&1.quorum != nil)) do
      nil ->
        3

      %{quorum: %{kind: :ideology_income_pct, pct: pct}} ->
        threshold = ctx.faction_ideology_income.() * pct / 100
        total = Enum.reduce(ballots, 0, &(Ballot.total_stake(&1) + &2))

        cond do
          threshold <= 0 -> 3
          total >= threshold -> 3
          total >= threshold * 2 / 3 -> 2
          total >= threshold / 3 -> 1
          true -> 0
        end
    end
  end

  defp apply_close(government, ballot, result, ctx) do
    rules = Rules.module_for(ctx.faction_key)

    government = push_history(government, ballot, result)
    {government, events} = rules.after_close(government, ballot, result, ctx)

    close_event = %{
      type: :ballot_closed,
      ballot_id: ballot.id,
      seat: ballot.seat,
      question: ballot.question,
      outcome: outcome_of(result),
      winner: winner_of(result)
    }

    {government, [close_event | events]}
  end

  defp outcome_of({:winner, _, _}), do: :seated
  defp outcome_of({:approved, _}), do: :approved
  defp outcome_of({:rejected, _}), do: :rejected
  defp outcome_of({:failed, reason, _}), do: reason

  defp winner_of({:winner, winner, _}), do: winner
  defp winner_of(_), do: nil

  # Post-close results are public as AGGREGATES only (per-candidate
  # totals and shares — the mockup's "number and % of votes gathered"),
  # never per-voter. This also reveals Cardan sums after the fact, which
  # is the intended reading of "players can only see [the boolean]"
  # while the vote runs.
  defp push_history(government, ballot, result) do
    entry = %{
      ballot_id: ballot.id,
      group: ballot.group,
      seat: ballot.seat,
      kind: ballot.kind,
      question: ballot.question,
      outcome: outcome_of(result),
      winner: winner_of(result),
      totals: totals_of(result)
    }

    %{government | history: Enum.take([entry | government.history], @history_cap)}
  end

  defp totals_of({:winner, _, totals}), do: public_totals(totals)
  defp totals_of({:approved, totals}), do: totals
  defp totals_of({:rejected, totals}), do: totals
  defp totals_of({:failed, _, totals}), do: public_totals(totals)

  defp public_totals(totals),
    do: totals |> Enum.map(&Map.drop(&1, [:first_order])) |> Enum.sort_by(&(-&1.amount))

  # ----------------------------------------------------------------
  # Engine helpers used by rule modules
  # ----------------------------------------------------------------

  def open_ballots(%Government{} = government, specs) do
    {government, opened} =
      Enum.reduce(specs, {government, []}, fn spec, {government, opened} ->
        ballot = Ballot.new(government.counter, spec)

        {%{government | counter: government.counter + 1, ballots: government.ballots ++ [ballot]},
         [ballot | opened]}
      end)

    events =
      Enum.map(opened, fn ballot ->
        %{type: :ballot_opened, ballot_id: ballot.id, seat: ballot.seat, question: ballot.question}
      end)

    {government, events}
  end

  @doc "Seat a player; a player never holds two seats, so vacate others first."
  def fill_seat(%Government{} = government, seat, %{player_id: player_id, name: name}) do
    holder = %{player_id: player_id, name: name}

    seats =
      government.seats
      |> Map.new(fn {key, current} ->
        if current != nil and current.player_id == player_id,
          do: {key, nil},
          else: {key, current}
      end)
      |> Map.put(seat, holder)

    {%{government | seats: seats},
     [%{type: :seat_changed, seat: seat, player_id: player_id, name: name}]}
  end

  def vacate_seat(%Government{} = government, seat) do
    case Map.get(government.seats, seat) do
      nil ->
        {government, []}

      _holder ->
        {%{government | seats: Map.put(government.seats, seat, nil)},
         [%{type: :seat_changed, seat: seat, player_id: nil, name: nil}]}
    end
  end

  def deposit_treasury(%Government{} = government, resource, amount) when amount > 0,
    do: %{government | treasury: Map.update!(government.treasury, resource, &(&1 + amount))}

  def deposit_treasury(%Government{} = government, _resource, _amount), do: government

  def leader?(%Government{seats: %{leader: %{player_id: id}}}, player_id), do: id == player_id
  def leader?(%Government{}, _player_id), do: false

  def seat_holder?(%Government{seats: seats}, player_id) do
    Enum.any?(seats, fn {_seat, holder} -> holder != nil and holder.player_id == player_id end)
  end

  def open_ballot_for_seat?(%Government{ballots: ballots}, seat),
    do: Enum.any?(ballots, &(&1.seat == seat))

  defp find_ballot(%Government{ballots: ballots}, ballot_id),
    do: Enum.find(ballots, &(&1.id == ballot_id))

  defp roster_member?(ctx, player_id), do: Enum.any?(ctx.players, &(&1.id == player_id))

  # ----------------------------------------------------------------
  # Player-facing operations (called from Faction.Agent)
  # ----------------------------------------------------------------

  @doc """
  Add a candidate to an open-candidacy ballot. `:self_only` (Myrmezir)
  also enforces one-seat-per-candidate across the ballot's group;
  `:others_only` (Cardan) forbids self-nomination.
  """
  def nominate(%Government{} = government, actor_id, ballot_id, candidate_id, ctx) do
    with %Ballot{} = ballot <- find_ballot(government, ballot_id) || {:error, :ballot_not_found},
         true <- roster_member?(ctx, actor_id) || {:error, :not_a_member},
         %{} = candidate <-
           Rules.roster_candidate(ctx.players, candidate_id) || {:error, :candidate_not_found},
         :ok <- check_candidacy(government, ballot, actor_id, candidate_id),
         {:ok, ballot} <- Ballot.add_candidate(ballot, candidate) do
      {:ok, put_ballot(government, ballot),
       [%{type: :candidate_added, ballot_id: ballot.id, seat: ballot.seat, name: candidate.name}]}
    else
      {:error, reason} -> {:error, reason}
      false -> {:error, :invalid}
    end
  end

  defp check_candidacy(government, ballot, actor_id, candidate_id) do
    case ballot.open_candidacy do
      :self_only ->
        cond do
          candidate_id != actor_id -> {:error, :self_nomination_only}
          candidate_in_group?(government, ballot, candidate_id) -> {:error, :already_running}
          true -> :ok
        end

      :anyone ->
        :ok

      :others_only ->
        if candidate_id == actor_id,
          do: {:error, :cannot_nominate_self},
          else: :ok

      # :by_stake candidacy happens through bidding, nil is closed.
      _ ->
        {:error, :closed_candidacy}
    end
  end

  defp candidate_in_group?(_government, %Ballot{group: nil} = ballot, candidate_id),
    do: Ballot.candidate?(ballot, candidate_id)

  defp candidate_in_group?(government, %Ballot{group: group}, candidate_id) do
    government.ballots
    |> Enum.filter(&(&1.group == group))
    |> Enum.any?(&Ballot.candidate?(&1, candidate_id))
  end

  @doc """
  Cast a vote. Payload contract per ballot kind (the agent validates
  shape and settles escrow before calling):

    :plurality    — %{candidate_id: id}
    :approval     — %{choice: :approve | :reject}
    :stake_pledge — %{candidate_id: id, pct: 0..100, stake: number}
                    (stake pre-computed from the pledger's income rate)
    :stake_bid    — %{candidate_id: id, stake: number}
                    (stake = NEW TOTAL; the agent escrowed the delta)
  """
  def cast_vote(%Government{} = government, voter_id, ballot_id, payload, ctx) do
    with %Ballot{} = ballot <- find_ballot(government, ballot_id) || {:error, :ballot_not_found},
         true <- roster_member?(ctx, voter_id) || {:error, :not_a_member},
         {:ok, vote, ballot} <- build_vote(ballot, voter_id, payload, ctx),
         {:ok, ballot} <- Ballot.cast_vote(ballot, voter_id, vote) do
      government =
        government
        |> put_ballot(ballot)
        |> refresh_group_quorum(ballot, ctx)

      {:ok, government, [%{type: :vote_cast, ballot_id: ballot.id, seat: ballot.seat}]}
    else
      {:error, reason} -> {:error, reason}
      false -> {:error, :invalid}
    end
  end

  defp build_vote(%Ballot{kind: :plurality} = ballot, _voter_id, %{candidate_id: id}, _ctx) do
    if Ballot.candidate?(ballot, id),
      do: {:ok, %{choice: id}, ballot},
      else: {:error, :not_a_candidate}
  end

  defp build_vote(%Ballot{kind: :approval} = ballot, _voter_id, %{choice: choice}, _ctx)
       when choice in [:approve, :reject],
       do: {:ok, %{choice: choice}, ballot}

  defp build_vote(
         %Ballot{kind: :stake_pledge} = ballot,
         _voter_id,
         %{candidate_id: id, pct: pct, stake: stake},
         _ctx
       )
       when pct >= 0 and pct <= 100 and stake >= 0 do
    if Ballot.candidate?(ballot, id),
      do: {:ok, %{choice: id, pct: pct, stake: stake}, ballot},
      else: {:error, :not_a_candidate}
  end

  # Bidding on a roster member who isn't a candidate yet nominates them
  # (auction candidacy), self included.
  defp build_vote(%Ballot{kind: :stake_bid} = ballot, _voter_id, %{candidate_id: id, stake: stake}, ctx)
       when stake > 0 do
    cond do
      Ballot.candidate?(ballot, id) ->
        {:ok, %{choice: id, stake: stake}, ballot}

      candidate = Rules.roster_candidate(ctx.players, id) ->
        case Ballot.add_candidate(ballot, candidate) do
          {:ok, ballot} -> {:ok, %{choice: id, stake: stake}, ballot}
          error -> error
        end

      true ->
        {:error, :candidate_not_found}
    end
  end

  defp build_vote(_ballot, _voter_id, _payload, _ctx), do: {:error, :invalid_payload}

  # After a pledge lands, refresh the staged progress indicator on every
  # ballot of the group. The bucketed stage is the ONLY quorum signal
  # that ever reaches clients while a Cardan vote runs.
  defp refresh_group_quorum(government, %Ballot{quorum: nil}, _ctx), do: government

  defp refresh_group_quorum(government, %Ballot{group: group}, ctx) do
    group_ballots = Enum.filter(government.ballots, &(&1.group == group))
    stage = group_quorum_stage(group_ballots, ctx)

    Enum.reduce(group_ballots, government, fn ballot, government ->
      ballot =
        %{ballot | meta: Map.put(ballot.meta, :quorum_stage, stage)}
        |> Ballot.refresh_public()

      put_ballot(government, ballot)
    end)
  end

  @doc "Current total the voter has staked on a ballot (ARK escrow delta base)."
  def voter_stake(%Government{} = government, ballot_id, voter_id) do
    case find_ballot(government, ballot_id) do
      nil -> {:error, :ballot_not_found}
      ballot -> {:ok, Ballot.voter_stake(ballot, voter_id), ballot.kind}
    end
  end

  def appoint(%Government{} = government, actor_id, seat, appointee_id, ctx) do
    rules = Rules.module_for(ctx.faction_key)

    cond do
      government.phase != :running ->
        {:error, :government_not_formed}

      not roster_member?(ctx, appointee_id) ->
        {:error, :candidate_not_found}

      seat_holder?(government, appointee_id) ->
        {:error, :already_seated}

      true ->
        appointee = Rules.roster_candidate(ctx.players, appointee_id)
        rules.appoint(government, actor_id, seat, appointee, ctx)
    end
  end

  @doc """
  Any member may call a by-election for a VACANT elected seat with no
  ballot already open — covers "nobody ran", "nobody voted", and the
  Cardan round cap, and prevents a dead faction from soft-locking its
  own government.
  """
  def call_by_election(%Government{} = government, actor_id, seat, ctx) do
    rules = Rules.module_for(ctx.faction_key)

    cond do
      government.phase != :running ->
        {:error, :government_not_formed}

      not roster_member?(ctx, actor_id) ->
        {:error, :not_a_member}

      Map.get(government.seats, seat) != nil ->
        {:error, :seat_not_vacant}

      open_ballot_for_seat?(government, seat) ->
        {:error, :ballot_already_open}

      true ->
        case rules.by_election_ballots(seat, ctx) do
          [] ->
            {:error, :not_available}

          specs ->
            {government, events} = open_ballots(government, specs)
            {:ok, government, [%{type: :elections_opened, seats: [seat], renewal: true} | events]}
        end
    end
  end

  # ----------------------------------------------------------------
  # Treasury economy: taxes, faction research, laws
  # ----------------------------------------------------------------

  defp seat_holder_id(%Government{seats: seats}, seat) do
    case Map.get(seats, seat) do
      nil -> nil
      holder -> holder.player_id
    end
  end

  @doc """
  Income tax rates (percent per resource), set by the Head of Economy
  and hard-capped by `government_tax_cap` — the cap is engine policy,
  not a government choice. Rates are public to the whole faction.
  """
  def set_tax_rates(%Government{} = government, actor_id, rates, ctx) do
    cap = ctx.constants.government_tax_cap

    cond do
      government.phase != :running ->
        {:error, :government_not_formed}

      seat_holder_id(government, :economy) != actor_id ->
        {:error, :not_head_of_economy}

      not valid_rates?(rates, cap) ->
        {:error, :tax_above_cap}

      true ->
        government = %{government | tax_rates: Map.take(rates, [:credit, :technology, :ideology])}
        {:ok, government, [%{type: :taxes_changed, rates: government.tax_rates, by: actor_id}]}
    end
  end

  defp valid_rates?(rates, cap) do
    Enum.all?([:credit, :technology, :ideology], fn key ->
      rate = Map.get(rates, key)
      is_number(rate) and rate >= 0 and rate <= cap
    end)
  end

  @doc "Faction research, bought with treasury TECHNOLOGY by the Head of Economy."
  def purchase_patent(%Government{} = government, actor_id, key, ctx) do
    purchase(government, actor_id, key, ctx, %{
      seat: :economy,
      seat_error: :not_head_of_economy,
      data_module: Data.Game.FactionPatent,
      resource: :technology,
      owned_key: :faction_patents,
      event: :patent_purchased
    })
  end

  @doc "Faction law, bought with treasury IDEOLOGY by the Leader (enacting is separate)."
  def purchase_lex(%Government{} = government, actor_id, key, ctx) do
    purchase(government, actor_id, key, ctx, %{
      seat: :leader,
      seat_error: :not_leader,
      data_module: Data.Game.FactionLex,
      resource: :ideology,
      owned_key: :faction_lexes,
      event: :lex_purchased
    })
  end

  defp purchase(government, actor_id, key, ctx, spec) do
    owned = Map.get(government, spec.owned_key, [])
    node = Data.Querier.one(spec.data_module, ctx.instance_id, key)

    cond do
      government.phase != :running ->
        {:error, :government_not_formed}

      seat_holder_id(government, spec.seat) != actor_id ->
        {:error, spec.seat_error}

      node == nil ->
        {:error, :unknown_key}

      Enum.member?(owned, key) ->
        {:error, :already_owned}

      node.ancestor != nil and not Enum.member?(owned, node.ancestor) ->
        {:error, :ancestor_not_owned}

      Map.get(government.treasury, spec.resource, 0) < node.cost ->
        {:error, :treasury_insufficient}

      true ->
        government = %{
          government
          | treasury: Map.update!(government.treasury, spec.resource, &(&1 - node.cost))
        }

        government = Map.put(government, spec.owned_key, owned ++ [key])

        {:ok, government, [%{type: spec.event, key: key, cost: node.cost, by: actor_id}]}
    end
  end

  @doc """
  Enact a set of owned lexes as the faction's active laws — the
  faction-level mirror of the player policy slots: limited to
  `government_max_laws`, with a change cooldown.
  """
  def update_laws(%Government{} = government, actor_id, keys, ctx) do
    owned = Map.get(government, :faction_lexes, [])

    cond do
      government.phase != :running ->
        {:error, :government_not_formed}

      seat_holder_id(government, :leader) != actor_id ->
        {:error, :not_leader}

      CooldownValue.locked?(government.law_cooldown) ->
        {:error, :laws_on_cooldown}

      length(keys) > ctx.constants.government_max_laws ->
        {:error, :too_many_laws}

      not Enum.all?(keys, &Enum.member?(owned, &1)) ->
        {:error, :lex_not_owned}

      Enum.uniq(keys) != keys ->
        {:error, :duplicate_laws}

      true ->
        government = %{
          government
          | active_laws: keys,
            law_cooldown: CooldownValue.set(government.law_cooldown, ctx.constants.government_law_cooldown)
        }

        {:ok, government, [%{type: :laws_changed, laws: keys, by: actor_id}]}
    end
  end

  @doc """
  The payload pushed to every member Player.Agent: the faction-wide
  bonuses currently in force (all purchased patents + enacted laws) and
  the tax rates. Cached player-side and injected into extract_bonus
  like faction traditions.
  """
  def effects(%Government{} = government, ctx) do
    patent_bonuses =
      government
      |> Map.get(:faction_patents, [])
      |> Enum.flat_map(fn key ->
        case Data.Querier.one(Data.Game.FactionPatent, ctx.instance_id, key) do
          nil -> []
          node -> Enum.map(node.bonus, &%{key: key, bonus: &1})
        end
      end)

    law_bonuses =
      government
      |> Map.get(:active_laws, [])
      |> Enum.flat_map(fn key ->
        case Data.Querier.one(Data.Game.FactionLex, ctx.instance_id, key) do
          nil -> []
          node -> Enum.map(node.bonus, &%{key: key, bonus: &1})
        end
      end)

    %{
      bonuses: patent_bonuses ++ law_bonuses,
      tax_rates: Map.get(government, :tax_rates, %{credit: 0, technology: 0, ideology: 0})
    }
  end

  @doc "Treasury deposit (tax remittances, auction pools)."
  def deposit(%Government{} = government, amounts) do
    treasury =
      Enum.reduce([:credit, :technology, :ideology], government.treasury, fn key, treasury ->
        amount = Map.get(amounts, key, 0)

        if is_number(amount) and amount > 0,
          do: Map.update!(treasury, key, &(&1 + amount)),
          else: treasury
      end)

    %{government | treasury: treasury}
  end

  @doc "Per-viewer ballot entries for the get_government RPC reply."
  def own_votes(%Government{} = government, player_id) do
    government.ballots
    |> Enum.reduce(%{}, fn ballot, acc ->
      case Ballot.own_vote(ballot, player_id) do
        nil -> acc
        vote -> Map.put(acc, ballot.id, vote)
      end
    end)
  end

  defp put_ballot(%Government{} = government, %Ballot{} = ballot) do
    ballots =
      Enum.map(government.ballots, fn existing ->
        if existing.id == ballot.id, do: ballot, else: existing
      end)

    %{government | ballots: ballots}
  end
end

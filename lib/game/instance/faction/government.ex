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

  # :tithes is server-internal — its debit map is per-pledger, and Cardan
  # pledges stay secret even after settlement (players see only their own
  # tithe, through their income tooltip). The withdrawal ledger is
  # per-member usage bookkeeping, likewise not broadcast.
  def jason(), do: [except: [:pending_events, :meta, :rev, :tithes, :withdrawal_ledger]]

  typedstruct enforce: true do
    # Monotonic durability revision — bumped by the agent on every
    # persisted mutation, compared on hydration after a process restart
    # (RC.Instances.GovernmentStates). Server-internal.
    field(:rev, integer(), default: 0)
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
    # Periodic seat-holder health sweep: AFK, eliminated, or departed
    # holders are marked Incapacitated, vacated, and their election
    # re-opens immediately (user decision 2026-07-07).
    field(:incapacity_check, %CooldownValue{})
    # Faction-wide cooldown after a FAILED deposition attempt — a rebuffed
    # coup buys the incumbent a quiet spell.
    field(:depose_cooldown, %CooldownValue{})
    # Live Cardan tithe settlements: each entry debits its pledgers'
    # ideology income and credits every member evenly until the cooldown
    # runs out. [%{debits: %{player_id => rate}, credit_per_member: rate,
    # cooldown: %CooldownValue{}}]
    field(:tithes, [map()], default: [])
    # The open ARK bid-to-challenge, PUBLIC by design (it's economic
    # brinkmanship — everyone watches the pot): %{challenger_id,
    # challenger_name, stake, matched: [%{player_id, amount}],
    # treasury_matched, remaining} or nil.
    field(:challenge, map() | nil, default: nil)
    # Member self-service withdrawals: max percent of each treasury pool
    # one member may take per 24h (0 = disabled; the Head of Economy
    # sets it, and may always GRANT freely past it).
    field(:withdraw_cap_pct, number(), default: 0)
    # Rolling usage ledger for the cap: [%{player_id, resource, pct,
    # cooldown}] — entries expire after the 24h window. Server-internal.
    field(:withdrawal_ledger, [map()], default: [])
    # Tyranny ledger: each time the leader acts in another seat's stead
    # (rules-gated, Tetrarchy only), the whole faction eats an income
    # malus until the entry expires. PUBLIC by design — members should
    # see what their monarch's impatience costs them.
    # [%{malus: pct, action: atom, cooldown: %CooldownValue{}}]
    field(:overreach, [map()], default: [])
  end

  # Interval of the effects self-heal push, in game-time units
  # (~1h wall at Legacy speed, ~30s at :fast).
  @effects_sync_interval 20

  # Seat-holder health sweep cadence (game-time units; ~45 wall-minutes
  # at Legacy speed). The AFK threshold itself is 1920 ut, so sweep
  # precision is not the bottleneck.
  @incapacity_interval 15

  # Below this many ACTIVE members, nomination/candidacy restrictions are
  # entirely lifted: anyone may take any seat, or several seats (user
  # decision 2026-07-07 — a skeleton faction must still be governable).
  @relaxed_threshold 4

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
      effects_sync: CooldownValue.new(@effects_sync_interval),
      incapacity_check: CooldownValue.new(@incapacity_interval),
      depose_cooldown: CooldownValue.new(),
      tithes: [],
      challenge: nil,
      withdraw_cap_pct: 0,
      withdrawal_ledger: [],
      overreach: []
    }
  end

  # Fields added after the first government snapshots existed — back-fill
  # restored structs at the tick/ops boundary so pre-field shapes never
  # dot-access-crash (same convention as :meta and ensure_government).
  def backfill(government) do
    government
    |> Map.put_new(:rev, 0)
    |> Map.put_new(:meta, %{})
    |> Map.put_new(:tax_rates, %{credit: 0, technology: 0, ideology: 0})
    |> Map.put_new(:faction_patents, [])
    |> Map.put_new(:faction_lexes, [])
    |> Map.put_new(:active_laws, [])
    |> Map.put_new(:law_cooldown, CooldownValue.new())
    |> Map.put_new(:effects_sync, CooldownValue.new(@effects_sync_interval))
    |> Map.put_new(:incapacity_check, CooldownValue.new(@incapacity_interval))
    |> Map.put_new(:depose_cooldown, CooldownValue.new())
    |> Map.put_new(:tithes, [])
    |> Map.put_new(:challenge, nil)
    |> Map.put_new(:withdraw_cap_pct, 0)
    |> Map.put_new(:withdrawal_ledger, [])
    |> Map.put_new(:overreach, [])
  end

  @doc "Nomination restrictions lift entirely below the active-member floor."
  def relaxed?(ctx), do: ctx.active_player_count.() < @relaxed_threshold

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
      faction_credit_total: fn -> faction_credit_total(faction_state) end,
      active_player_ids: fn -> active_player_ids(faction_state) end,
      active_player_count: fn -> length(active_player_ids(faction_state)) end,
      seat_holder_status: fn player_id -> seat_holder_status(faction_state, player_id) end
    }
  end

  # Incapacity signals, strongest first: departed the faction entirely,
  # eliminated (owns no systems — the AFK detector's `is_active` stays
  # true for a spectating corpse), or AFK per the engine's own
  # last-connection tracking. An UNREACHABLE agent reports :ok — a laggy
  # process must never depose anyone.
  defp seat_holder_status(faction_state, player_id) do
    if Enum.any?(faction_state.players, &(&1.id == player_id)) do
      case Game.call(faction_state.instance_id, :player, player_id, :get_state) do
        {:ok, player} ->
          cond do
            Map.get(player, :stellar_systems, [nil]) == [] -> :eliminated
            Map.get(player, :is_active) == false -> :afk
            true -> :ok
          end

        _ ->
          :ok
      end
    else
      :gone
    end
  end

  # Faction-wide credit on hand (ARK challenge floor) over ACTIVE members
  # only — an AFK hoard must not price challenges out of reach. Fan-out
  # read like faction_ideology_income; unreachable players count 0.
  defp faction_credit_total(faction_state) do
    faction_state.players
    |> Task.async_stream(
      fn player ->
        case Game.call(faction_state.instance_id, :player, player.id, :get_state) do
          {:ok, %{is_active: active, credit: %{value: value}}} ->
            if active != false, do: value, else: 0

          _ ->
            0
        end
      end,
      on_timeout: :kill_task
    )
    |> Enum.reduce(0, fn
      {:ok, value}, acc -> acc + max(value, 0)
      _, acc -> acc
    end)
  end

  # The ACTIVE roster (quorum bases, redistribution recipients, candidacy
  # eligibility). Inactive players must never distort government math —
  # user rule 2026-07-07: no seat, no share, no weight, no quorum drag.
  # Fan-out; if every agent is unreachable (or genuinely nobody is
  # active), fall back to the full roster rather than soft-locking every
  # vote and distribution behind an empty electorate.
  defp active_player_ids(faction_state) do
    ids =
      faction_state.players
      |> Task.async_stream(
        fn player ->
          case Game.call(faction_state.instance_id, :player, player.id, :get_state) do
            {:ok, %{is_active: active}} -> {player.id, active != false}
            _ -> {player.id, false}
          end
        end,
        on_timeout: :kill_task
      )
      |> Enum.flat_map(fn
        {:ok, {id, true}} -> [id]
        _ -> []
      end)

    if ids == [], do: Enum.map(faction_state.players, & &1.id), else: ids
  end

  # Faction-wide ideology income rate (Cardan quorum base) over ACTIVE
  # members only — a half-dead faction's quorum must not be inflated by
  # income nobody is playing with. Unreachable players count 0 — an
  # election must not crash on a dead agent.
  defp faction_ideology_income(faction_state) do
    faction_state.players
    |> Task.async_stream(
      fn player ->
        case Game.call(faction_state.instance_id, :player, player.id, :get_state) do
          {:ok, %{is_active: active, ideology: %{change: change}}} ->
            if active != false, do: change, else: 0

          _ ->
            0
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
        law_cooldown: CooldownValue.next_tick(government.law_cooldown, elapsed_time),
        depose_cooldown: CooldownValue.next_tick(government.depose_cooldown, elapsed_time)
    }

    government = tick_withdrawal_ledger(government, elapsed_time)

    {government, close_events} = close_expired(government, ctx)
    {government, term_events} = tick_term(government, elapsed_time, ctx)
    {government, incapacity_events} = tick_incapacity(government, elapsed_time, ctx)
    {government, tithe_events} = tick_tithes(government, elapsed_time)
    {government, overreach_events} = tick_overreach(government, elapsed_time)
    {government, rules_events} = tick_rules(government, elapsed_time, ctx)
    {government, sync_events} = tick_effects_sync(government, elapsed_time)

    {government,
     close_events ++
       term_events ++
       incapacity_events ++ tithe_events ++ overreach_events ++ rules_events ++ sync_events}
  end

  # Optional per-faction time-driven behavior (Synelle's nomination
  # window, ARK's challenge countdown and lockouts).
  defp tick_rules(%Government{} = government, elapsed_time, ctx) do
    rules = Rules.module_for(ctx.faction_key)

    if function_exported?(rules, :tick, 3),
      do: rules.tick(government, elapsed_time, ctx),
      else: {government, []}
  end

  # ----------------------------------------------------------------
  # Seat incapacitation (AFK / eliminated / departed)
  # ----------------------------------------------------------------

  defp tick_incapacity(%Government{} = government, elapsed_time, ctx) do
    check = CooldownValue.next_tick(government.incapacity_check, elapsed_time)

    if CooldownValue.locked?(check) do
      {%{government | incapacity_check: check}, []}
    else
      government = %{government | incapacity_check: CooldownValue.set(check, @incapacity_interval)}
      sweep_incapacitated(government, ctx)
    end
  end

  # An incapacitated holder is vacated on the spot and the seat's
  # election cycle re-opens immediately (elected seats; appointed seats
  # simply free up for the leader). One sweep handles any number of
  # simultaneous casualties.
  defp sweep_incapacitated(%Government{} = government, ctx) do
    government.seats
    |> Map.keys()
    |> Enum.reduce({government, []}, fn seat, {government, events} ->
      with %{player_id: player_id, name: name} <- Map.get(government.seats, seat),
           reason when reason != :ok <- ctx.seat_holder_status.(player_id) do
        {government, vacate_events} = vacate_seat(government, seat)

        incapacitated = %{
          type: :seat_incapacitated,
          seat: seat,
          player_id: player_id,
          name: name,
          reason: reason
        }

        {government, open_events} =
          if open_ballot_for_seat?(government, seat) do
            {government, []}
          else
            case Rules.module_for(ctx.faction_key).by_election_ballots(seat, ctx) do
              [] ->
                {government, []}

              specs ->
                {government, opened} = open_ballots(government, specs)
                {government, [%{type: :elections_opened, seats: [seat], renewal: true} | opened]}
            end
          end

        {government, events ++ [incapacitated] ++ vacate_events ++ open_events}
      else
        _ -> {government, events}
      end
    end)
  end

  # ----------------------------------------------------------------
  # Tithe settlements (Cardan)
  # ----------------------------------------------------------------

  defp tick_tithes(%Government{tithes: []} = government, _elapsed_time), do: {government, []}

  defp tick_tithes(%Government{} = government, elapsed_time) do
    ticked =
      Enum.map(government.tithes, fn tithe ->
        %{tithe | cooldown: CooldownValue.next_tick(tithe.cooldown, elapsed_time)}
      end)

    {live, expired} = Enum.split_with(ticked, &CooldownValue.locked?(&1.cooldown))
    government = %{government | tithes: live}

    # An expired settlement changes member incomes — re-push effects.
    if expired == [],
      do: {government, []},
      else: {government, [%{type: :sync_effects}]}
  end

  @doc "Record a settled tithe (Cardan rules module, on winner close)."
  def add_tithe(%Government{} = government, tithe),
    do: %{government | tithes: Map.get(government, :tithes, []) ++ [tithe]}

  # ----------------------------------------------------------------
  # Overreach — the tyranny ledger (Tetrarchy)
  # ----------------------------------------------------------------

  # Entries age out with their 24h window; an expiry changes member
  # incomes, so re-push effects (same contract as tithes).
  defp tick_overreach(%Government{} = government, elapsed_time) do
    case Map.get(government, :overreach, []) do
      [] ->
        {government, []}

      entries ->
        ticked =
          Enum.map(entries, fn entry ->
            %{entry | cooldown: CooldownValue.next_tick(entry.cooldown, elapsed_time)}
          end)

        {live, expired} = Enum.split_with(ticked, &CooldownValue.locked?(&1.cooldown))
        government = Map.put(government, :overreach, live)

        if expired == [],
          do: {government, []},
          else: {government, [%{type: :sync_effects}]}
    end
  end

  # Seat authorization with the royal-prerogative escape hatch: the
  # holder acts natively; the LEADER may act in a council seat's stead
  # when the faction's rules put a price on it (user design: "Tetrarch
  # acts as a council seat → −10 faction stability for 24h", surfaced
  # as a faction-wide income malus via the bonus pipeline).
  defp seat_access(government, ctx, seat, actor_id) do
    cond do
      seat_holder_id(government, seat) == actor_id ->
        :native

      seat != :leader and seat_holder_id(government, :leader) == actor_id and
          overreach_malus(ctx) != nil ->
        :overreach

      true ->
        :denied
    end
  end

  defp overreach_malus(ctx) do
    rules = Rules.module_for(ctx.faction_key)
    if function_exported?(rules, :overreach_malus, 0), do: rules.overreach_malus(), else: nil
  end

  # Bill the prerogative: append a tyranny entry and announce it — the
  # event card is the accountability half of the mechanic.
  defp apply_overreach(government, _ctx, :native, _seat, _action), do: {government, []}

  defp apply_overreach(government, ctx, :overreach, seat, action) do
    malus = overreach_malus(ctx)

    entry = %{
      malus: malus,
      action: action,
      cooldown: CooldownValue.new(ctx.constants.government_approval_duration)
    }

    government =
      Map.put(government, :overreach, Map.get(government, :overreach, []) ++ [entry])

    {government,
     [
       %{
         type: :leader_overreach,
         seat: seat,
         action: action,
         malus: malus,
         by: seat_holder_id(government, :leader),
         name: seat_holder_name(government, :leader)
       },
       %{type: :sync_effects}
     ]}
  end

  @doc "Total live tyranny malus (percent), clamped — the effects payload scalar."
  def overreach_total(%Government{} = government) do
    government
    |> Map.get(:overreach, [])
    |> Enum.map(&Map.get(&1, :malus, 0))
    |> Enum.sum()
    |> min(100)
  end

  # Periodic :sync_effects heartbeat — the agent re-pushes the current
  # effects payload to every member Player.Agent, healing missed casts
  # and post-restart caches.
  defp tick_effects_sync(%Government{} = government, elapsed_time) do
    sync = CooldownValue.next_tick(government.effects_sync, elapsed_time)

    if CooldownValue.locked?(sync) do
      {%{government | effects_sync: sync}, []}
    else
      {%{government | effects_sync: CooldownValue.set(sync, @effects_sync_interval)}, [%{type: :sync_effects}]}
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

        {%{government | counter: government.counter + 1, ballots: government.ballots ++ [ballot]}, [ballot | opened]}
      end)

    events =
      Enum.map(opened, fn ballot ->
        %{type: :ballot_opened, ballot_id: ballot.id, seat: ballot.seat, question: ballot.question}
      end)

    {government, events}
  end

  @doc """
  Seat a player. A player never holds two seats — except under the
  small-faction relaxation (`opts[:keep_other_seats]`), where one member
  may chair the whole government.
  """
  def fill_seat(%Government{} = government, seat, %{player_id: player_id, name: name}, opts \\ []) do
    holder = %{player_id: player_id, name: name}

    seats =
      if Keyword.get(opts, :keep_other_seats, false) do
        government.seats
      else
        Map.new(government.seats, fn {key, current} ->
          if current != nil and current.player_id == player_id,
            do: {key, nil},
            else: {key, current}
        end)
      end

    {%{government | seats: Map.put(seats, seat, holder)},
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
         true <- candidate_id in ctx.active_player_ids.() || {:error, :candidate_inactive},
         :ok <- check_candidacy(government, ballot, actor_id, candidate_id, ctx),
         {:ok, ballot} <- Ballot.add_candidate(ballot, candidate) do
      {:ok, put_ballot(government, ballot),
       [%{type: :candidate_added, ballot_id: ballot.id, seat: ballot.seat, name: candidate.name}]}
    else
      {:error, reason} -> {:error, reason}
      false -> {:error, :invalid}
    end
  end

  defp check_candidacy(government, ballot, actor_id, candidate_id, ctx) do
    if relaxed?(ctx) and ballot.open_candidacy != nil do
      # Below the active-member floor every restriction lifts: any member
      # may put anyone (self included) up for any seat.
      :ok
    else
      check_candidacy(government, ballot, actor_id, candidate_id)
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

      {government, close_events} = maybe_instant_close(government, ballot, ctx)

      {:ok, government, [%{type: :vote_cast, ballot_id: ballot.id, seat: ballot.seat} | close_events]}
    else
      {:error, reason} -> {:error, reason}
      false -> {:error, :invalid}
    end
  end

  # Instant-trigger ballots (Cardan's loss-of-faith pledge: "instant
  # trigger when reached") close the moment their quorum fills instead of
  # waiting out the deadline. The whole quorum group closes together,
  # same as a timed close.
  defp maybe_instant_close(%Government{} = government, %Ballot{} = casted, ctx) do
    ballot = find_ballot(government, casted.id)

    if ballot != nil and Map.get(ballot.meta, :instant, false) do
      group =
        case ballot.group do
          nil -> [ballot]
          group -> Enum.filter(government.ballots, &(&1.group == group))
        end

      if group_quorum_stage(group, ctx) == 3 do
        ids = MapSet.new(group, & &1.id)
        government = %{government | ballots: Enum.reject(government.ballots, &MapSet.member?(ids, &1.id))}

        Enum.reduce(group, {government, []}, fn expired, {government, events} ->
          result = ballot_result(expired, true, ctx)
          {government, close_events} = apply_close(government, expired, result, ctx)
          {government, events ++ close_events}
        end)
      else
        {government, []}
      end
    else
      {government, []}
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
  # (auction candidacy), self included — but never an INACTIVE member:
  # buying a chair for someone who isn't playing just feeds the
  # incapacitation sweep.
  defp build_vote(%Ballot{kind: :stake_bid} = ballot, _voter_id, %{candidate_id: id, stake: stake}, ctx)
       when stake > 0 do
    cond do
      Ballot.candidate?(ballot, id) ->
        {:ok, %{choice: id, stake: stake}, ballot}

      id not in ctx.active_player_ids.() ->
        {:error, :candidate_inactive}

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

      appointee_id not in ctx.active_player_ids.() ->
        {:error, :candidate_inactive}

      seat_holder?(government, appointee_id) and not relaxed?(ctx) ->
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
  # Mid-term accountability: deposition, snaps, the ARK challenge
  # ----------------------------------------------------------------

  @doc """
  Open a deposition vote against a sitting seat holder. Availability and
  shape are faction rules (`deposition_ballot/3`); the engine owns the
  shared gates: a sitting target, no competing ballot, and the
  faction-wide cooldown a failed attempt arms.
  """
  def depose(%Government{} = government, actor_id, seat, ctx) do
    rules = Rules.module_for(ctx.faction_key)

    cond do
      government.phase != :running ->
        {:error, :government_not_formed}

      not roster_member?(ctx, actor_id) ->
        {:error, :not_a_member}

      Map.get(government.seats, seat) == nil ->
        {:error, :seat_vacant}

      open_ballot_for_seat?(government, seat) ->
        {:error, :ballot_already_open}

      CooldownValue.locked?(government.depose_cooldown) ->
        {:error, :deposition_on_cooldown}

      not function_exported?(rules, :deposition_ballot, 3) ->
        {:error, :not_available}

      true ->
        case rules.deposition_ballot(government, seat, ctx) do
          nil ->
            {:error, :not_available}

          spec ->
            {government, events} = open_ballots(government, [spec])
            {:ok, government, [%{type: :deposition_started, seat: seat, by: actor_id} | events]}
        end
    end
  end

  @doc "Arm the faction-wide post-failure deposition cooldown (rules helper)."
  def arm_depose_cooldown(%Government{} = government, ctx) do
    %{
      government
      | depose_cooldown: CooldownValue.set(government.depose_cooldown, ctx.constants.government_lockout_duration)
    }
  end

  @doc """
  Faction-specific snap actions (Synelle: leader dissolves the cabinet /
  the cabinet jointly dissolves the leader). Everything is rules-side;
  the engine only guards the phase.
  """
  def snap(%Government{} = government, actor_id, target, ctx) do
    rules = Rules.module_for(ctx.faction_key)

    cond do
      government.phase != :running ->
        {:error, :government_not_formed}

      not function_exported?(rules, :snap, 4) ->
        {:error, :not_available}

      true ->
        rules.snap(government, actor_id, target, ctx)
    end
  end

  @doc """
  ARK bid-to-challenge (Option B sealed match). The agent escrows the
  challenger's stake BEFORE this op (refunding on error, same contract
  as auction bids); resolution refunds ride `:refund` events.
  """
  def challenge(%Government{} = government, actor_id, stake, ctx) do
    rules = Rules.module_for(ctx.faction_key)

    cond do
      government.phase != :running ->
        {:error, :government_not_formed}

      not roster_member?(ctx, actor_id) ->
        {:error, :not_a_member}

      not function_exported?(rules, :challenge, 4) ->
        {:error, :not_available}

      true ->
        rules.challenge(government, actor_id, stake, ctx)
    end
  end

  @doc "Sitting oligarchs answer a challenge. Escrow contract as above."
  def challenge_match(%Government{} = government, actor_id, amount, use_treasury, ctx) do
    rules = Rules.module_for(ctx.faction_key)

    cond do
      government.phase != :running ->
        {:error, :government_not_formed}

      not function_exported?(rules, :challenge_match, 5) ->
        {:error, :not_available}

      true ->
        rules.challenge_match(government, actor_id, amount, use_treasury, ctx)
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

  defp seat_holder_name(%Government{seats: seats}, seat) do
    case Map.get(seats, seat) do
      nil -> nil
      holder -> holder.name
    end
  end

  @doc """
  Income tax rates (percent per resource), set by the Head of Economy
  and hard-capped by `government_tax_cap` — the cap is engine policy,
  not a government choice. Rates are public to the whole faction.
  """
  def set_tax_rates(%Government{} = government, actor_id, rates, ctx) do
    cap = ctx.constants.government_tax_cap
    access = seat_access(government, ctx, :economy, actor_id)

    cond do
      government.phase != :running ->
        {:error, :government_not_formed}

      access == :denied ->
        {:error, :not_head_of_economy}

      not valid_rates?(rates, cap) ->
        {:error, :tax_above_cap}

      true ->
        government = %{government | tax_rates: Map.take(rates, [:credit, :technology, :ideology])}
        {government, over_events} = apply_overreach(government, ctx, access, :economy, :set_taxes)

        {:ok, government, [%{type: :taxes_changed, rates: government.tax_rates, by: actor_id} | over_events]}
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
      event: :patent_purchased,
      cost_mod: :patent_cost
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
      event: :lex_purchased,
      cost_mod: :lex_cost
    })
  end

  # Faction identity modifiers apply at purchase time: the primary cost
  # scales by the faction's multiplier, and ARK's credit surcharge bills
  # the treasury at the UNMODIFIED base cost × factor (user design
  # 2026-07-09: "initial tech/ideo cost x 10").
  defp purchase(government, actor_id, key, ctx, spec) do
    owned = Map.get(government, spec.owned_key, [])
    node = Data.Querier.one(spec.data_module, ctx.instance_id, key)
    mods = Rules.economy_mods(ctx.faction_key)
    cost = if node, do: round(node.cost * Map.get(mods, spec.cost_mod, 1.0)), else: 0
    credit_cost = if node, do: round(node.cost * Map.get(mods, :credit_cost_factor, 0)), else: 0
    access = seat_access(government, ctx, spec.seat, actor_id)

    cond do
      government.phase != :running ->
        {:error, :government_not_formed}

      access == :denied ->
        {:error, spec.seat_error}

      node == nil ->
        {:error, :unknown_key}

      Enum.member?(owned, key) ->
        {:error, :already_owned}

      node.ancestor != nil and not Enum.member?(owned, node.ancestor) ->
        {:error, :ancestor_not_owned}

      Map.get(government.treasury, spec.resource, 0) < cost ->
        {:error, :treasury_insufficient}

      credit_cost > 0 and Map.get(government.treasury, :credit, 0) < credit_cost ->
        {:error, :treasury_insufficient}

      true ->
        treasury =
          government.treasury
          |> Map.update!(spec.resource, &(&1 - cost))
          |> Map.update!(:credit, &(&1 - credit_cost))

        government = %{government | treasury: treasury}
        government = Map.put(government, spec.owned_key, owned ++ [key])
        {government, over_events} = apply_overreach(government, ctx, access, spec.seat, spec.event)

        {:ok, government,
         [
           %{type: spec.event, key: key, cost: cost, credit_cost: credit_cost, by: actor_id}
           | over_events
         ]}
    end
  end

  @doc """
  Enact a set of owned lexes as the faction's active laws — the
  faction-level mirror of the player policy slots: limited to
  `government_max_laws`, with a change cooldown.
  """
  def update_laws(%Government{} = government, actor_id, keys, ctx) do
    owned = Map.get(government, :faction_lexes, [])
    rules = Rules.module_for(ctx.faction_key)

    referendum? =
      function_exported?(rules, :laws_referendum?, 0) and rules.laws_referendum?()

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

      referendum? and open_ballot_for_seat?(government, :laws) ->
        {:error, :ballot_already_open}

      referendum? ->
        # Direct democracy (Myrmezir): the leader PROPOSES the law set,
        # the faction disposes by referendum — a 24h approval ballot at
        # the standard half-of-actives bar. The set applies on approval
        # (rules.after_close), not here.
        spec = %{
          kind: :approval,
          seat: :laws,
          question: :laws,
          candidates: [],
          open_candidacy: nil,
          duration: ctx.constants.government_approval_duration,
          meta: %{keys: keys}
        }

        {government, events} = open_ballots(government, [spec])
        {:ok, government, [%{type: :laws_proposed, laws: keys, by: actor_id} | events]}

      true ->
        {government, events} = apply_laws(government, keys, ctx)
        {:ok, government, events ++ [%{type: :laws_changed, laws: keys, by: actor_id}]}
    end
  end

  @doc """
  Apply an (already validated) law set and arm the change cooldown —
  scaled by the faction's identity modifier (Myrmezir deliberates
  longer, Cardan swaps doctrine faster).
  """
  def apply_laws(%Government{} = government, keys, ctx) do
    mods = Rules.economy_mods(ctx.faction_key)
    cooldown = round(ctx.constants.government_law_cooldown * Map.get(mods, :law_cooldown, 1.0))

    government = %{
      government
      | active_laws: keys,
        law_cooldown: CooldownValue.set(government.law_cooldown, cooldown)
    }

    {government, []}
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
      tax_rates: Map.get(government, :tax_rates, %{credit: 0, technology: 0, ideology: 0}),
      tithes: tithe_effects(government),
      # Faction-wide tyranny malus (percent) from live overreach entries.
      overreach_malus: overreach_total(government)
    }
  end

  # Live Cardan settlements folded into one payload: per-pledger ideology
  # income debits, the even redistribution rate, and the recipient set
  # (ACTIVE members snapshotted at each settlement). Overlapping
  # settlements with different snapshots merge as a union — a short-lived
  # over-credit at the margins, preferable to per-entry payload shapes.
  defp tithe_effects(government) do
    government
    |> Map.get(:tithes, [])
    |> Enum.reduce(%{debits: %{}, credit_per_member: 0, recipients: []}, fn tithe, acc ->
      debits =
        Enum.reduce(tithe.debits, acc.debits, fn {player_id, rate}, debits ->
          Map.update(debits, player_id, rate, &(&1 + rate))
        end)

      %{
        debits: debits,
        credit_per_member: acc.credit_per_member + tithe.credit_per_member,
        recipients: Enum.uniq(acc.recipients ++ (Map.get(tithe, :recipients) || []))
      }
    end)
  end

  @doc """
  Live faction-wide tax income (per game-time unit): the sum of every
  member's current remit rates. Fan-out read, same pattern as
  faction_ideology_income — used for the treasury income display.
  """
  def tax_income(faction_state) do
    zero = %{credit: 0, technology: 0, ideology: 0}

    faction_state.players
    |> Task.async_stream(
      fn player ->
        case Game.call(faction_state.instance_id, :player, player.id, :get_state) do
          {:ok, player_state} -> Map.get(player_state, :tax_remit_rates) || %{}
          _ -> %{}
        end
      end,
      on_timeout: :kill_task
    )
    |> Enum.reduce(zero, fn
      {:ok, rates}, acc ->
        Map.new(acc, fn {key, value} -> {key, value + Map.get(rates, key, 0)} end)

      _, acc ->
        acc
    end)
  end

  @doc """
  Fair-split distribution: the Head of Economy hands `pct` percent of
  the treasury back to the ACTIVE members, split evenly per resource —
  AFK players don't soak shares (user rule 2026-07-07). Shares are
  floored; the remainder stays in the treasury. The actual
  `add_resources` casts are settled by the agent from the :grant events.
  """
  def distribute_treasury(%Government{} = government, actor_id, pct, ctx) do
    recipients = ctx.active_player_ids.()
    member_count = length(recipients)
    access = seat_access(government, ctx, :economy, actor_id)

    cond do
      government.phase != :running ->
        {:error, :government_not_formed}

      access == :denied ->
        {:error, :not_head_of_economy}

      not is_number(pct) or pct <= 0 or pct > 100 ->
        {:error, :invalid_percent}

      member_count == 0 ->
        {:error, :no_members}

      true ->
        shares =
          Map.new(government.treasury, fn {resource, amount} ->
            {resource, trunc(amount * pct / 100 / member_count)}
          end)

        if Enum.all?(shares, fn {_resource, share} -> share <= 0 end) do
          {:error, :nothing_to_distribute}
        else
          treasury =
            Map.new(government.treasury, fn {resource, amount} ->
              {resource, amount - Map.get(shares, resource, 0) * member_count}
            end)

          grants =
            Enum.map(recipients, fn player_id ->
              %{
                type: :grant,
                player_id: player_id,
                credit: Map.get(shares, :credit, 0),
                technology: Map.get(shares, :technology, 0),
                ideology: Map.get(shares, :ideology, 0)
              }
            end)

          government = %{government | treasury: treasury}

          {government, over_events} =
            apply_overreach(government, ctx, access, :economy, :distribute_treasury)

          {:ok, government,
           [%{type: :treasury_distributed, pct: pct, shares: shares, by: actor_id} | grants] ++
             over_events}
        end
    end
  end

  # Withdrawal-usage entries age out with their 24h window.
  defp tick_withdrawal_ledger(%Government{withdrawal_ledger: []} = government, _elapsed_time),
    do: government

  defp tick_withdrawal_ledger(%Government{} = government, elapsed_time) do
    ledger =
      government.withdrawal_ledger
      |> Enum.map(fn entry ->
        %{entry | cooldown: CooldownValue.next_tick(entry.cooldown, elapsed_time)}
      end)
      |> Enum.filter(&CooldownValue.locked?(&1.cooldown))

    %{government | withdrawal_ledger: ledger}
  end

  @doc "The Head of Economy sets the member self-service withdrawal cap."
  def set_withdraw_cap(%Government{} = government, actor_id, pct, ctx) do
    access = seat_access(government, ctx, :economy, actor_id)

    cond do
      government.phase != :running ->
        {:error, :government_not_formed}

      access == :denied ->
        {:error, :not_head_of_economy}

      not is_number(pct) or pct < 0 or pct > 100 ->
        {:error, :invalid_percent}

      true ->
        government = %{government | withdraw_cap_pct: pct}

        {government, over_events} =
          apply_overreach(government, ctx, access, :economy, :set_withdraw_cap)

        {:ok, government, [%{type: :withdraw_cap_changed, pct: pct, by: actor_id} | over_events]}
    end
  end

  @doc """
  Member self-service withdrawal, capped and taxed (user design
  2026-07-09): any member may take up to `withdraw_cap_pct` percent of
  each treasury pool per rolling 24h window, measured as
  percent-of-pool-at-withdrawal-time. The payout is taxed at the market
  rate — the tax is sunk, which is the friction that makes the Head of
  Economy's free `grant/5` the preferred channel.
  """
  def withdraw(%Government{} = government, actor_id, amounts, ctx) do
    cap = Map.get(government, :withdraw_cap_pct, 0)
    window = ctx.constants.government_approval_duration
    tax = Map.get(ctx.constants, :market_taxe, 0)

    requested =
      [:credit, :technology, :ideology]
      |> Enum.map(fn resource -> {resource, Map.get(amounts, resource, 0)} end)
      |> Enum.filter(fn {_resource, amount} -> is_number(amount) and amount > 0 end)

    over_cap? =
      Enum.any?(requested, fn {resource, amount} ->
        pool = Map.get(government.treasury, resource, 0)
        used = ledger_used(government, actor_id, resource)
        pool <= 0 or used + amount / pool * 100 > cap
      end)

    cond do
      government.phase != :running ->
        {:error, :government_not_formed}

      not roster_member?(ctx, actor_id) ->
        {:error, :not_a_member}

      cap <= 0 ->
        {:error, :withdrawals_disabled}

      requested == [] ->
        {:error, :invalid_payload}

      Enum.any?(requested, fn {resource, amount} ->
        Map.get(government.treasury, resource, 0) < amount
      end) ->
        {:error, :treasury_insufficient}

      over_cap? ->
        {:error, :withdraw_cap_exceeded}

      true ->
        {treasury, ledger, net} =
          Enum.reduce(requested, {government.treasury, government.withdrawal_ledger, %{}}, fn
            {resource, amount}, {treasury, ledger, net} ->
              pct = amount / Map.get(treasury, resource, 1) * 100

              entry = %{
                player_id: actor_id,
                resource: resource,
                pct: pct,
                cooldown: CooldownValue.new(window)
              }

              {Map.update!(treasury, resource, &(&1 - amount)), [entry | ledger],
               Map.put(net, resource, trunc(amount * (1 - tax)))}
          end)

        government = %{government | treasury: treasury, withdrawal_ledger: ledger}

        payout = %{
          type: :grant,
          player_id: actor_id,
          credit: Map.get(net, :credit, 0),
          technology: Map.get(net, :technology, 0),
          ideology: Map.get(net, :ideology, 0)
        }

        {:ok, government, [%{type: :treasury_withdrawn, by: actor_id, amounts: Map.new(requested), net: net}, payout]}
    end
  end

  defp ledger_used(government, player_id, resource) do
    government
    |> Map.get(:withdrawal_ledger, [])
    |> Enum.filter(&(&1.player_id == player_id and &1.resource == resource))
    |> Enum.reduce(0, &(&1.pct + &2))
  end

  @doc """
  The Head of Economy issues treasury to a member — freely, untaxed,
  regardless of the withdrawal cap (user design 2026-07-09).
  """
  def grant(%Government{} = government, actor_id, player_id, amounts, ctx) do
    requested =
      [:credit, :technology, :ideology]
      |> Enum.map(fn resource -> {resource, Map.get(amounts, resource, 0)} end)
      |> Enum.filter(fn {_resource, amount} -> is_number(amount) and amount > 0 end)

    access = seat_access(government, ctx, :economy, actor_id)

    cond do
      government.phase != :running ->
        {:error, :government_not_formed}

      access == :denied ->
        {:error, :not_head_of_economy}

      not roster_member?(ctx, player_id) ->
        {:error, :not_a_member}

      requested == [] ->
        {:error, :invalid_payload}

      Enum.any?(requested, fn {resource, amount} ->
        Map.get(government.treasury, resource, 0) < amount
      end) ->
        {:error, :treasury_insufficient}

      true ->
        treasury =
          Enum.reduce(requested, government.treasury, fn {resource, amount}, treasury ->
            Map.update!(treasury, resource, &(&1 - amount))
          end)

        government = %{government | treasury: treasury}
        granted = Map.new(requested)

        payout = %{
          type: :grant,
          player_id: player_id,
          credit: Map.get(granted, :credit, 0),
          technology: Map.get(granted, :technology, 0),
          ideology: Map.get(granted, :ideology, 0)
        }

        {government, over_events} = apply_overreach(government, ctx, access, :economy, :grant)

        {:ok, government,
         [
           %{type: :treasury_granted, by: actor_id, player_id: player_id, amounts: granted},
           payout | over_events
         ]}
    end
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

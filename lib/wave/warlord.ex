defmodule Wave.Warlord do
  @moduledoc """
  The Rebellion's brain: pure state and pure decisions.

  All I/O lives in `Wave.Warlord.Agent`; everything here is a function of the
  struct plus plain inputs, so it is unit-testable without booting an instance.
  Per-pass targeting data (sector classes, candidates, deficits) lives in
  `Wave.Geometry`.

  ## Behaviour

  On a game-time cadence the Warlord runs one pass:

    1. keep the bot player solvent (top resources back up to their floors);
    2. **Navarchs (colonisers)** — every `hire_interval_ut`, buy a one-star
       Navarch, deploy it at the capital with a free colony ship, send idle
       colonisers to the nearest unreserved open system in a reachable sector,
       and recall + dismiss each one once its colony lands. The coloniser roster
       is capped at `idle_navarch_factor` (1.5) times the unclaimed open systems
       in reachable sectors, and at the Navarch ceiling; surplus idle
       colonisers are released.
    3. **Siderians (dominion capture)** — the roster grows with the match and
       with the humans it faces: see `agent_ceiling/2`. It never exceeds the
       capture targets. Only Siderians with capture strength (the proselyte
       skill) are bought, and any without are dismissed. An idle, rested
       Siderian rolls a sector class (frontier 80 / border 15 / internal 5) and
       tries to turn a neutral system or foreign dominion there into a
       Rebellion dominion. Siderians spread out: a target already carrying `n`
       of them is only considered with probability `capture_overlap_falloff^n`.
       Captured dominions vote for the Rebellion in sector ownership, which is
       what lets it take sectors whose neutrals outnumber their open systems.

  ## Ceilings

  One bot player faces a whole faction of humans, so its agent ceilings scale
  with them. For each agent kind a knob holds a per-player curve by match day:
  how many agents a typical human player had on board in the official Legacy
  matches (a quantile a little above the median, held non-decreasing). The
  ceiling is that value times the human players in the game.

  ## Telemetry

  Every pass observes each Siderian and charges the game time since the last
  observation to the state seen then: moving, acting (controlling or
  destabilizing), resting (cooldown) or idle (waiting for orders). Attempts
  are scored as captured, failed (the action ran, the system didn't turn) or
  aborted (it never started), with travel and action time. The agent writes
  the same events to `instance_event_log` (`wave_*` kinds) plus one
  `wave_daily` rollup per match day.

  ## Snapshot tolerance

  The Warlord is snapshotted with its instance. Fields added after the first
  release are declared with defaults AND back-filled by `upgrade/1`, which the
  agent applies before every pass, so a snapshot taken by older code restores.
  Roster entries gained keys over time too, so they are read with `Map.get`.
  """

  use TypedStruct

  @acting [:make_dominion, :encourage_hate, :conversion]
  @erased_acting [:infiltration, :sabotage, :assassination]

  @ceiling_curves %{
    siderians: "siderians_per_player_by_day",
    navarchs: "navarchs_per_player_by_day",
    erased: "erased_per_player_by_day"
  }

  def jason(), do: [except: [:instance_id]]

  typedstruct enforce: true do
    field(:instance_id, integer())
    field(:bot_faction, atom())
    # Resolved lazily on the first tick: the profile id of the bot player.
    field(:player_id, integer() | nil)
    # ut accumulated toward the next Navarch hire.
    field(:hire_accum, float())
    # %{character_id => %{stage: :idle | :dispatched, target: system_id | nil, since: float()}}
    field(:colonisers, map())
    field(:connected, boolean())
    field(:elapsed, float())
    field(:stats, map())

    # --- added 2026-09-15 (back-filled by upgrade/1) ---
    # %{character_id => %{stage:, target:, since:, observed:, observed_at:, time:, dispatched_at:, started_at:, ...}}
    field(:siderians, map(), default: %{})
    # ut accumulated toward the next Siderian hire.
    field(:siderian_accum, float(), default: 0.0)
    field(:passes, integer(), default: 0)
    # Last-pass readings (candidate counts, caps, human players, agents left without a target).
    field(:gauges, map(), default: %{})
    # Pass cost: count, total/last/max microseconds and reductions.
    field(:perf, map(), default: %{})
    # Behaviour telemetry: ut per Siderian state, attempt durations, last daily rollup.
    field(:telemetry, map(), default: %{})

    # --- added 2026-09-18 (back-filled by upgrade/1) ---
    # %{character_id => %{theatre:, duty:, stage:, target:, target_character:,
    #   target_key:, action:, train_target:, since:, observed:, observed_at:, time:, ...}}
    field(:erased, map(), default: %{})
    # ut accumulated toward the next Erased hire.
    field(:erased_accum, float(), default: 0.0)
    # Game time of the last hostile reading (`Wave.Recon`). The view itself is
    # never kept — it holds live engine structs and would bloat every snapshot
    # — so a pass either takes a fresh one or leaves the Erased waiting.
    field(:erased_recon_at, float() | nil, default: nil)
  end

  @added_fields %{
    siderians: %{},
    siderian_accum: 0.0,
    passes: 0,
    gauges: %{},
    perf: %{},
    telemetry: %{},
    erased: %{},
    erased_accum: 0.0,
    erased_recon_at: nil
  }

  def new(instance_id, bot_faction) do
    %__MODULE__{
      instance_id: instance_id,
      bot_faction: bot_faction,
      player_id: nil,
      hire_accum: 0.0,
      colonisers: %{},
      connected: false,
      elapsed: 0.0,
      stats: %{
        hired: 0,
        deployed: 0,
        dispatched: 0,
        colonised: 0,
        released: 0,
        dismissed: 0,
        siderians_hired: 0,
        siderians_released: 0,
        siderians_lost: 0,
        captures_attempted: 0,
        capture_started: 0,
        capture_overlaps: 0,
        captured: 0,
        capture_failed: 0,
        capture_aborted: 0,
        erased_hired: 0,
        erased_released: 0,
        erased_lost: 0,
        erased_graduated: 0,
        removals_attempted: 0,
        removals_succeeded: 0,
        sabotages_attempted: 0,
        infiltrations_attempted: 0,
        erased_started: 0,
        erased_resolved: 0,
        erased_aborted: 0,
        erased_overlaps: 0,
        erased_roams: 0,
        refused: %{}
      }
    }
  end

  @doc "Back-fill fields a snapshot from older code doesn't carry."
  def upgrade(%__MODULE__{} = state) do
    Enum.reduce(@added_fields, state, fn {key, default}, acc ->
      if Map.has_key?(acc, key), do: acc, else: Map.put(acc, key, default)
    end)
  end

  @doc """
  Wake often enough to serve whichever comes first: the standing management
  cadence or the next Navarch hire. Floored so a mis-set knob can never produce
  a zero-interval spin.
  """
  def compute_next_tick_interval(%__MODULE__{} = state) do
    cadence = positive(Wave.Config.knob(state.instance_id, "tick_interval_ut", 1.0), 1.0)
    until_hire = hire_interval(state) - state.hire_accum

    # A hire held "due" because the roster is at its cap must not pull the
    # interval down to the floor — the next pass can't hire either, and at
    # high game speed the floor is a busy spin. Wake on the normal cadence.
    candidates = if until_hire > 0, do: [cadence, until_hire], else: [cadence]

    candidates
    |> Enum.min()
    |> max(0.05)
  end

  def compute_next_tick_interval(_), do: 1.0

  @doc "Advance the internal clocks by one tick's worth of game time."
  def advance(%__MODULE__{} = state, elapsed_time) when is_number(elapsed_time) do
    state = upgrade(state)

    %{
      state
      | hire_accum: state.hire_accum + elapsed_time,
        siderian_accum: state.siderian_accum + elapsed_time,
        erased_accum: state.erased_accum + elapsed_time,
        elapsed: state.elapsed + elapsed_time
    }
  end

  def advance(state, _), do: state

  @doc "Match day (1-based) from game time: elapsed ut over `ut_per_day`."
  def match_day(%__MODULE__{} = state) do
    trunc(state.elapsed / positive(Wave.Config.knob(state.instance_id, "ut_per_day", 480.0), 480.0)) + 1
  end

  # --- agent ceilings -------------------------------------------------------------

  @doc """
  Today's ceiling for one agent kind (`:siderians`, `:navarchs` or `:erased`):
  the per-player curve value for the match day times `scale_players/1`,
  rounded, and never below 1 so the Rebellion always has one on hand.
  """
  def agent_ceiling(%__MODULE__{} = state, kind) do
    state.instance_id
    |> Wave.Config.knob(Map.fetch!(@ceiling_curves, kind), [])
    |> curve_value(match_day(state))
    |> scaled_ceiling(scale_players(state))
  end

  @doc "All three ceilings, for the readouts."
  def ceilings(%__MODULE__{} = state), do: Map.new(Map.keys(@ceiling_curves), &{&1, agent_ceiling(state, &1)})

  @doc """
  The human players the ceilings scale with: the count from the last galaxy
  reading (`human_players` gauge), never below `scale_players_min`. Test games
  with a single human raise that floor to an official match's size.
  """
  def scale_players(%__MODULE__{} = state) do
    floor =
      case Wave.Config.knob(state.instance_id, "scale_players_min", 1) do
        n when is_number(n) and n >= 1 -> trunc(n)
        _ -> 1
      end

    max(Map.get(state.gauges, :human_players, 0), floor)
  end

  @doc "Day `day` of a per-player curve (index 0 is day 1); days past the end keep the last value."
  def curve_value([_ | _] = curve, day) when is_integer(day) do
    curve |> Enum.at(day |> max(1) |> min(length(curve)) |> Kernel.-(1)) |> Kernel.*(1.0)
  end

  def curve_value(_curve, _day), do: 0.0

  @doc "A per-player value scaled to `players`, rounded, and at least 1."
  def scaled_ceiling(per_player, players) when is_number(per_player) and is_integer(players),
    do: max(round(per_player * players), 1)

  # --- sector pace ------------------------------------------------------------------

  @doc """
  How many sectors the Rebellion may hold before it stops opening new fronts:
  the `sector_share_by_day` value `sector_pace_lead_days` ahead of today, times
  the map's sector count, rounded, at least 1. It looks ahead because flipping
  a sector takes time once work on it starts.
  """
  def sector_allowance(%__MODULE__{} = state, total_sectors) when is_integer(total_sectors) do
    ut_per_day = positive(Wave.Config.knob(state.instance_id, "ut_per_day", 480.0), 480.0)

    lead =
      case Wave.Config.knob(state.instance_id, "sector_pace_lead_days", 1.0) do
        days when is_number(days) and days >= 0 -> days
        _ -> 1.0
      end

    day = trunc((state.elapsed + lead * ut_per_day) / ut_per_day) + 1

    state.instance_id
    |> Wave.Config.knob("sector_share_by_day", [])
    |> curve_value(day)
    |> Kernel.*(total_sectors)
    |> round()
    |> max(1)
  end

  # --- Navarch hiring -----------------------------------------------------------

  @doc "Configured Navarch hire cadence in ut."
  def hire_interval(%__MODULE__{instance_id: instance_id}) do
    positive(Wave.Config.knob(instance_id, "hire_interval_ut", 120.0), 120.0)
  end

  @doc "True when enough game time has accumulated to buy the next Navarch."
  def hire_due?(%__MODULE__{} = state), do: state.hire_accum >= hire_interval(state)

  @doc "Reset the hire clock, keeping any overshoot so the cadence doesn't drift."
  def consume_hire(%__MODULE__{} = state) do
    %{state | hire_accum: max(state.hire_accum - hire_interval(state), 0.0)}
  end

  @doc """
  The most colonisers worth keeping: `factor` times the unclaimed open systems
  in reachable sectors (rounded down), never above `ceiling`. With nothing left
  to colonize the cap is zero — hiring stops and idle colonisers are released.
  """
  def coloniser_cap(unclaimed, factor, ceiling)
      when is_integer(unclaimed) and is_number(factor) and is_integer(ceiling) do
    (unclaimed * factor)
    |> Float.floor()
    |> trunc()
    |> min(ceiling)
    |> max(0)
  end

  # --- Siderian hiring ----------------------------------------------------------

  @doc "Configured Siderian hire cadence in ut."
  def siderian_interval(%__MODULE__{instance_id: instance_id}) do
    positive(Wave.Config.knob(instance_id, "siderian_hire_interval_ut", 120.0), 120.0)
  end

  @doc "Configured wait before looking at the market again after it had no capable Siderian."
  def siderian_retry(%__MODULE__{instance_id: instance_id}) do
    positive(Wave.Config.knob(instance_id, "siderian_retry_ut", 10.0), 10.0)
  end

  @doc """
  The first Siderian is hired at once; each further one waits a full interval.
  `defer_siderian_hire/1` pushes either threshold back.
  """
  def siderian_hire_due?(%__MODULE__{} = state) do
    state.siderian_accum >= siderian_threshold(state)
  end

  @doc """
  The market had no Siderian worth buying: look again after `siderian_retry_ut`
  rather than on every pass, since a due hire makes each pass read the galaxy.
  """
  def defer_siderian_hire(%__MODULE__{} = state) do
    %{state | siderian_accum: siderian_threshold(state) - siderian_retry(state)}
  end

  defp siderian_threshold(state), do: if(map_size(state.siderians) == 0, do: 0.0, else: siderian_interval(state))

  @doc "Siderians worth keeping: one per capture target, up to `ceiling`."
  def siderian_cap(capture_targets, ceiling) when is_integer(capture_targets) and is_integer(ceiling),
    do: capture_targets |> min(ceiling) |> max(0)

  @doc """
  A Siderian's own dominion-capture strength: the `speaker_make_dominion`
  bonus its skill points grant, per the speaker `specializations`. Faction and
  doctrine bonuses only multiply this, so a Siderian at zero can never win a
  capture roll — and the market's cheapest speaker is often a scholar or a
  philosopher.
  """
  def capture_strength(skills, specializations) when is_list(skills) and is_list(specializations) do
    for %{index: index, bonus: bonuses} <- specializations,
        %{to: :speaker_make_dominion, type: :add, value: value} <- bonuses,
        reduce: 0 do
      acc -> acc + value * Enum.at(skills, index, 0)
    end
  end

  def capture_strength(_skills, _specializations), do: 0

  @doc """
  Pick a market character from `by_rank` (`%{rank => [character]}`), limited to
  the `ranks` the match day has unlocked. `score` ranks candidates, and a score
  of zero or less is never bought; the best score wins, ties going to the lower
  credit cost and then the lower total cost. With the default score every
  candidate is equal, which is cheapest-first.

  Nothing outside `ranks` is ever bought. The Rebellion can afford anything, so
  without that floor it would field three-star agents on day one — see
  `unlocked_ranks/1`.
  """
  def pick_candidate(by_rank, ranks, score \\ fn _character -> 1 end) when is_map(by_rank) do
    pool =
      ranks
      |> List.wrap()
      |> Enum.flat_map(&Map.get(by_rank, &1, []))
      |> Enum.map(&{score.(&1), &1})
      |> Enum.filter(fn {s, _character} -> s > 0 end)

    case pool do
      [] -> {:error, :no_candidate}
      _ -> {:ok, pool |> Enum.min_by(fn {s, c} -> {-s, Map.get(c, :credit_cost) || 0, total_cost(c)} end) |> elem(1)}
    end
  end

  @doc """
  The market ranks the Rebellion may buy today: every rank in
  `rank_unlock_days` whose day has arrived, falling back to `hire_rank` when
  the schedule is missing or has not opened anything yet.

  The Rebellion's resource floors mean price is never a brake, so the schedule
  is what keeps early agents green: one star from the start, two stars from day
  5, three from day 8.
  """
  def unlocked_ranks(%__MODULE__{} = state) do
    day = match_day(state)
    floor = rank_atom(Wave.Config.knob(state.instance_id, "hire_rank", "common"))

    unlocked =
      state.instance_id
      |> Wave.Config.knob("rank_unlock_days", %{})
      |> case do
        schedule when is_map(schedule) -> schedule
        _ -> %{}
      end
      |> Enum.filter(fn {_rank, unlock_day} -> is_number(unlock_day) and day >= unlock_day end)
      |> Enum.map(fn {rank, _unlock_day} -> rank_atom(rank) end)
      |> Enum.reject(&is_nil/1)

    case unlocked do
      [] -> [floor] |> Enum.reject(&is_nil/1)
      ranks -> Enum.uniq(ranks)
    end
  end

  defp rank_atom(rank) when is_atom(rank) and not is_nil(rank), do: rank

  defp rank_atom(rank) when is_binary(rank) do
    String.to_existing_atom(rank)
  rescue
    ArgumentError -> nil
  end

  defp rank_atom(_rank), do: nil

  defp total_cost(character) do
    [:credit_cost, :technology_cost, :ideology_cost]
    |> Enum.map(&(Map.get(character, &1) || 0))
    |> Enum.sum()
  end

  # --- Siderian targeting ---------------------------------------------------------

  @doc """
  Colonisations and captures on their way, counted by sector: dispatched
  colonisers plus Siderians with a target. `sector_of` maps system id to sector.
  """
  def pending_by_sector(%__MODULE__{} = state, sector_of) do
    colonising =
      for {_id, %{stage: :dispatched, target: target}} when not is_nil(target) <- state.colonisers, do: target

    capturing = for {_id, %{target: target}} when not is_nil(target) <- state.siderians, do: target

    (colonising ++ capturing)
    |> Enum.map(&Map.get(sector_of, &1))
    |> Enum.reject(&is_nil/1)
    |> Enum.frequencies()
  end

  @doc "How many tracked Siderians are committed to each target, leaving out `except`."
  def commitments(%__MODULE__{} = state, except \\ nil) do
    state.siderians
    |> Enum.reject(fn {id, entry} -> id == except or entry.target == nil end)
    |> Enum.frequencies_by(fn {_id, entry} -> entry.target end)
  end

  @doc """
  The capture candidates a Siderian may consider. A target with `n` Siderians
  already committed is admitted only when `falloff^n > roll`, so a second
  Siderian joins a target at rate `falloff`, a third at `falloff²`, and a
  fourth almost never. When that leaves nothing, the least-committed targets
  are admitted.
  """
  def admit_targets(candidates, commitments, roll, falloff) do
    committed = fn candidate -> Map.get(commitments, candidate.id, 0) end

    case Enum.filter(candidates, &(:math.pow(falloff, committed.(&1)) > roll)) do
      [] when candidates != [] ->
        least = candidates |> Enum.map(committed) |> Enum.min()
        Enum.filter(candidates, &(committed.(&1) == least))

      admitted ->
        admitted
    end
  end

  # --- counters, gauges, perf -----------------------------------------------------

  @doc "Count a successful action for the harness/status readout."
  def count(%__MODULE__{} = state, key) do
    %{state | stats: Map.update(state.stats, key, 1, &(&1 + 1))}
  end

  @doc "Count a refusal, keyed by `{what, reason}`, so failures are visible."
  def refuse(%__MODULE__{} = state, what, reason) do
    refused =
      state.stats
      |> Map.get(:refused, %{})
      |> Map.update({what, reason}, 1, &(&1 + 1))

    %{state | stats: Map.put(state.stats, :refused, refused)}
  end

  @doc "Record a last-pass reading."
  def gauge(%__MODULE__{} = state, key, value), do: %{state | gauges: Map.put(state.gauges, key, value)}

  @doc "Accumulate one pass's cost: wall microseconds and reductions."
  def record_pass(%__MODULE__{} = state, microseconds, reductions) do
    perf = state.perf

    perf = %{
      passes: Map.get(perf, :passes, 0) + 1,
      total_us: Map.get(perf, :total_us, 0) + microseconds,
      last_us: microseconds,
      max_us: max(Map.get(perf, :max_us, 0), microseconds),
      total_reductions: Map.get(perf, :total_reductions, 0) + reductions,
      last_reductions: reductions
    }

    %{state | perf: perf, passes: state.passes + 1}
  end

  # --- coloniser bookkeeping ------------------------------------------------------

  def track(%__MODULE__{} = state, character_id) do
    %{state | colonisers: Map.put(state.colonisers, character_id, %{stage: :idle, target: nil, since: state.elapsed})}
  end

  def forget(%__MODULE__{} = state, character_id) do
    %{state | colonisers: Map.delete(state.colonisers, character_id)}
  end

  def dispatched(%__MODULE__{} = state, character_id, target) do
    entry = %{stage: :dispatched, target: target, since: state.elapsed}
    %{state | colonisers: Map.put(state.colonisers, character_id, entry)}
  end

  def released(%__MODULE__{} = state, character_id) do
    case Map.get(state.colonisers, character_id) do
      nil -> state
      entry -> %{state | colonisers: Map.put(state.colonisers, character_id, %{entry | stage: :idle, target: nil})}
    end
  end

  @doc "System ids already claimed by a coloniser — never double-target."
  def reserved_targets(%__MODULE__{} = state), do: targets(state.colonisers)

  def active_coloniser_count(%__MODULE__{} = state), do: map_size(state.colonisers)

  # --- Siderian bookkeeping -------------------------------------------------------

  def track_siderian(%__MODULE__{} = state, character_id) do
    entry = %{stage: :idle, target: nil, since: state.elapsed, time: %{}}
    %{state | siderians: Map.put(state.siderians, character_id, entry), siderian_accum: 0.0}
  end

  def forget_siderian(%__MODULE__{} = state, character_id) do
    %{state | siderians: Map.delete(state.siderians, character_id)}
  end

  @doc "Record a dispatch. `info` (class, sector, hops, overlap, from) rides along to the attempt's score."
  def siderian_dispatched(%__MODULE__{} = state, character_id, target, info \\ %{}) do
    entry =
      state.siderians
      |> Map.get(character_id, %{time: %{}})
      |> Map.merge(info)
      |> Map.merge(%{
        stage: :dispatched,
        target: target,
        since: state.elapsed,
        dispatched_at: state.elapsed,
        started_at: nil
      })

    %{state | siderians: Map.put(state.siderians, character_id, entry)}
  end

  def siderian_released(%__MODULE__{} = state, character_id) do
    case Map.get(state.siderians, character_id) do
      nil -> state
      entry -> %{state | siderians: Map.put(state.siderians, character_id, %{entry | stage: :idle, target: nil})}
    end
  end

  @doc "Systems a Siderian is already working on."
  def siderian_targets(%__MODULE__{} = state), do: targets(state.siderians)

  # --- Erased hiring and bookkeeping -----------------------------------------------

  @doc "Configured Erased hire cadence in ut."
  def erased_interval(%__MODULE__{instance_id: instance_id}) do
    positive(Wave.Config.knob(instance_id, "erased_hire_interval_ut", 120.0), 120.0)
  end

  @doc "Configured wait before looking at the market again after it had no capable Erased."
  def erased_retry(%__MODULE__{instance_id: instance_id}) do
    positive(Wave.Config.knob(instance_id, "erased_retry_ut", 10.0), 10.0)
  end

  @doc "The first Erased is hired at once; each further one waits a full interval."
  def erased_hire_due?(%__MODULE__{} = state), do: state.erased_accum >= erased_threshold(state)

  @doc "The market had no Erased worth buying: look again after `erased_retry_ut`."
  def defer_erased_hire(%__MODULE__{} = state) do
    %{state | erased_accum: erased_threshold(state) - erased_retry(state)}
  end

  defp erased_threshold(state), do: if(map_size(state.erased) == 0, do: 0.0, else: erased_interval(state))

  @doc """
  True when the last hostile reading has aged out. A pass that takes one
  stamps `mark_recon/1`; in between, idle Erased simply wait — which is what
  they do anyway.
  """
  def recon_due?(%__MODULE__{} = state, interval) when is_number(interval) do
    case state.erased_recon_at do
      nil -> true
      at -> state.elapsed - at >= interval
    end
  end

  def mark_recon(%__MODULE__{} = state), do: %{state | erased_recon_at: state.elapsed}

  @doc """
  Track a freshly hired Erased under the posting it rolled. `posting` carries
  `theatre`, `duty` and, for a trainee, `train_target`.
  """
  def track_erased(%__MODULE__{} = state, character_id, posting) do
    entry =
      Map.merge(
        %{
          stage: :idle,
          target: nil,
          target_character: nil,
          target_key: nil,
          action: nil,
          train_target: nil,
          since: state.elapsed,
          time: %{}
        },
        posting
      )

    %{state | erased: Map.put(state.erased, character_id, entry), erased_accum: 0.0}
  end

  def forget_erased(%__MODULE__{} = state, character_id) do
    %{state | erased: Map.delete(state.erased, character_id)}
  end

  @doc "Re-post an Erased — a graduating trainee taking its permanent duty."
  def repost_erased(%__MODULE__{} = state, character_id, theatre, duty) do
    case Map.get(state.erased, character_id) do
      nil ->
        state

      entry ->
        entry = Map.merge(entry, %{theatre: theatre, duty: duty, train_target: nil, reposted_at: state.elapsed})
        %{state | erased: Map.put(state.erased, character_id, entry)}
    end
  end

  @doc "Record a dispatch; `info` (action, target_key, odds, hops, overlap, …) rides into the attempt's score."
  def erased_dispatched(%__MODULE__{} = state, character_id, target, info) do
    entry =
      state.erased
      |> Map.get(character_id, %{time: %{}})
      |> Map.merge(info)
      |> Map.merge(%{
        stage: :dispatched,
        target: target,
        since: state.elapsed,
        dispatched_at: state.elapsed,
        started_at: nil
      })

    %{state | erased: Map.put(state.erased, character_id, entry)}
  end

  @doc """
  Send an Erased to look rather than to strike. It holds a slot on the system
  the same way a strike would, so roamers spread out instead of crowding the
  same blind corner — but the stage is `:roaming`, so arriving there scores
  nothing.
  """
  def erased_roaming(%__MODULE__{} = state, character_id, target, info) do
    entry =
      state.erased
      |> Map.get(character_id, %{time: %{}})
      |> Map.merge(info)
      |> Map.merge(%{stage: :roaming, target: target, since: state.elapsed, dispatched_at: nil, started_at: nil})

    %{state | erased: Map.put(state.erased, character_id, entry)}
  end

  @doc "Free an Erased's slot without scoring an attempt."
  def erased_released(%__MODULE__{} = state, character_id) do
    case Map.get(state.erased, character_id) do
      nil ->
        state

      entry ->
        entry =
          Map.merge(entry, %{
            stage: :idle,
            target: nil,
            target_character: nil,
            target_key: nil,
            target_name: nil,
            action: nil
          })

        %{state | erased: Map.put(state.erased, character_id, entry)}
    end
  end

  @doc "How many Erased are committed to each target key, leaving out `except`."
  def erased_commitments(%__MODULE__{} = state, except \\ nil), do: Wave.Erased.commitments(state.erased, except)

  @doc """
  Observe an Erased this pass, charging the game time since its last sighting
  to the state it was in then. A dispatched Erased seen performing its action
  marks the attempt started. Returns `{state, events}`.
  """
  def observe_erased(%__MODULE__{} = state, character_id, bucket, action_status) do
    case Map.get(state.erased, character_id) do
      nil ->
        {state, []}

      entry ->
        now = state.elapsed
        previous = Map.get(entry, :observed)
        dt = max(now - Map.get(entry, :observed_at, now), 0.0)

        {time, telemetry} =
          if previous,
            do:
              {Map.update(Map.get(entry, :time, %{}), previous, dt, &(&1 + dt)),
               add_erased_ut(state.telemetry, previous, dt)},
            else: {Map.get(entry, :time, %{}), state.telemetry}

        started? =
          Map.get(entry, :stage) == :dispatched and Map.get(entry, :started_at) == nil and
            action_status in @erased_acting

        entry =
          entry
          |> Map.merge(%{observed: bucket, observed_at: now, time: time})
          |> then(&if(started?, do: Map.put(&1, :started_at, now), else: &1))

        state = %{state | erased: Map.put(state.erased, character_id, entry), telemetry: telemetry}

        if started? do
          payload = %{
            target: Map.get(entry, :target),
            target_character: Map.get(entry, :target_character),
            action: action_status,
            duty: Map.get(entry, :duty),
            theatre: Map.get(entry, :theatre),
            day: match_day(state),
            travel_ut: round1(now - Map.get(entry, :dispatched_at, Map.get(entry, :since, now)))
          }

          {count(state, :erased_started), [{:started, character_id, payload}]}
        else
          {state, []}
        end
    end
  end

  @doc """
  Score a concluded Erased attempt and free its slot. `effect` is whatever the
  caller could determine about the result (`%{removed: true}`, a tile delta, a
  visibility gain) and rides into the payload; an attempt that never started is
  still `:aborted`.

  Returns `{state, payload}`, or `{state, nil}` for an untracked Erased.
  """
  def resolve_erased(%__MODULE__{} = state, character_id, effect \\ %{}) do
    case Map.get(state.erased, character_id) do
      nil ->
        {state, nil}

      entry ->
        now = state.elapsed
        dispatched_at = Map.get(entry, :dispatched_at) || Map.get(entry, :since, now)
        started_at = Map.get(entry, :started_at)

        # Infiltration takes time, so a pass catches it mid-action and stamps
        # `started_at`. Removal and sabotage resolve inside the tick that starts
        # them and are never seen running — but every spy action costs cover,
        # and cover only ever climbs back on its own. A drop since the dispatch
        # is proof the strike happened.
        outcome =
          if started_at != nil or spent_cover?(entry, Map.get(effect, :cover_after)),
            do: :performed,
            else: :aborted

        payload =
          entry
          |> Map.take([:action, :duty, :theatre, :odds, :odds_class, :hops, :overlap, :from, :target_character])
          |> Map.put(:cover_before, Map.get(entry, :cover))
          |> Map.merge(effect)
          |> Map.merge(%{
            target: Map.get(entry, :target),
            outcome: outcome,
            day: match_day(state),
            total_ut: round1(now - dispatched_at),
            travel_ut: started_at && round1(started_at - dispatched_at),
            action_ut: started_at && round1(now - started_at)
          })

        telemetry =
          state.telemetry
          |> Map.update(:erased_resolved, 1, &(&1 + 1))
          |> then(fn t ->
            if started_at do
              t
              |> Map.update(:erased_travel_ut, started_at - dispatched_at, &(&1 + started_at - dispatched_at))
              |> Map.update(:erased_started_resolved, 1, &(&1 + 1))
            else
              t
            end
          end)

        entry = Map.drop(entry, [:odds, :odds_class, :hops, :overlap, :from, :cover])

        state =
          %{state | erased: Map.put(state.erased, character_id, entry), telemetry: telemetry}
          |> count(if(outcome == :aborted, do: :erased_aborted, else: :erased_resolved))
          |> then(&if(Map.get(effect, :removed) == true, do: count(&1, :removals_succeeded), else: &1))
          |> erased_released(character_id)

        {state, payload}
    end
  end

  # Cover recovers on its own, so any loss since the dispatch was paid for by an
  # action. The epsilon keeps a float round-trip from reading as a strike.
  defp spent_cover?(entry, after_value) when is_number(after_value) do
    case Map.get(entry, :cover) do
      before when is_number(before) -> after_value < before - 0.001
      _ -> false
    end
  end

  defp spent_cover?(_entry, _after_value), do: false

  defp add_erased_ut(telemetry, bucket, dt) do
    Map.update(telemetry, :erased_ut, %{bucket => dt}, fn buckets -> Map.update(buckets, bucket, dt, &(&1 + dt)) end)
  end

  # --- Siderian telemetry -----------------------------------------------------------

  @doc "Telemetry bucket for an observed Siderian: its action status and whether its cooldown runs."
  def siderian_bucket(action_status, locked?) do
    cond do
      action_status in [:moving, :docking] -> :moving
      action_status in @acting -> :acting
      action_status == :idle and locked? -> :resting
      action_status == :idle -> :idle
      true -> :other
    end
  end

  @doc """
  Observe a Siderian this pass. The game time since its last observation is
  charged to the bucket seen then (per Siderian and in total). A dispatched
  Siderian seen performing an action marks its attempt started. Returns
  `{state, events}`; events are `{:started, character_id, payload}`.
  """
  def observe_siderian(%__MODULE__{} = state, character_id, bucket, action_status) do
    case Map.get(state.siderians, character_id) do
      nil ->
        {state, []}

      entry ->
        now = state.elapsed
        previous = Map.get(entry, :observed)
        dt = max(now - Map.get(entry, :observed_at, now), 0.0)

        {time, telemetry} =
          if previous,
            do:
              {Map.update(Map.get(entry, :time, %{}), previous, dt, &(&1 + dt)),
               add_siderian_ut(state.telemetry, previous, dt)},
            else: {Map.get(entry, :time, %{}), state.telemetry}

        started? = entry.stage == :dispatched and Map.get(entry, :started_at) == nil and action_status in @acting

        entry =
          entry
          |> Map.merge(%{observed: bucket, observed_at: now, time: time})
          |> then(&if(started?, do: Map.put(&1, :started_at, now), else: &1))

        state = %{state | siderians: Map.put(state.siderians, character_id, entry), telemetry: telemetry}

        if started? do
          payload = %{
            target: entry.target,
            action: action_status,
            day: match_day(state),
            travel_ut: round1(now - Map.get(entry, :dispatched_at, entry.since))
          }

          {count(state, :capture_started), [{:started, character_id, payload}]}
        else
          {state, []}
        end
    end
  end

  @doc """
  Score a concluded attempt and free the Siderian: `:captured`, `:failed` (the
  action ran but the system didn't turn) or `:aborted` (it never started —
  cancelled, or the target became invalid on the way). Returns
  `{state, payload}`, the payload carrying travel/action/total ut and the
  dispatch info; `nil` for an untracked Siderian.
  """
  def resolve_siderian(%__MODULE__{} = state, character_id, captured?) do
    case Map.get(state.siderians, character_id) do
      nil ->
        {state, nil}

      entry ->
        now = state.elapsed
        dispatched_at = Map.get(entry, :dispatched_at) || entry.since
        started_at = Map.get(entry, :started_at)

        outcome =
          cond do
            captured? -> :captured
            started_at != nil -> :failed
            true -> :aborted
          end

        payload =
          entry
          |> Map.take([:class, :sector, :hops, :overlap, :from])
          |> Map.merge(%{
            target: entry.target,
            outcome: outcome,
            day: match_day(state),
            total_ut: round1(now - dispatched_at),
            travel_ut: started_at && round1(started_at - dispatched_at),
            action_ut: started_at && round1(now - started_at)
          })

        telemetry = Map.update(state.telemetry, :resolved, 1, &(&1 + 1))

        telemetry =
          if started_at do
            telemetry
            |> Map.update(:started_resolved, 1, &(&1 + 1))
            |> Map.update(:travel_ut, started_at - dispatched_at, &(&1 + started_at - dispatched_at))
            |> Map.update(:action_ut, now - started_at, &(&1 + now - started_at))
          else
            telemetry
          end

        entry =
          entry
          |> Map.drop([:class, :sector, :hops, :overlap, :from])
          |> Map.merge(%{dispatched_at: nil, started_at: nil})

        counter = %{captured: :captured, failed: :capture_failed, aborted: :capture_aborted}[outcome]

        state =
          %{state | siderians: Map.put(state.siderians, character_id, entry), telemetry: telemetry}
          |> count(counter)
          |> siderian_released(character_id)

        {state, payload}
    end
  end

  @doc "True once per match day, until `mark_daily_reported/1` records the rollup."
  def daily_report_due?(%__MODULE__{} = state), do: match_day(state) > Map.get(state.telemetry, :reported_day, 0)

  def mark_daily_reported(%__MODULE__{} = state),
    do: %{state | telemetry: Map.put(state.telemetry, :reported_day, match_day(state))}

  @doc "The `wave_daily` rollup: cumulative counters, gauges, ceilings and Siderian time, merged with `extra`."
  def daily_payload(%__MODULE__{} = state, extra \\ %{}) do
    summary = summary(state)

    Map.merge(
      %{
        day: summary.match_day,
        elapsed_ut: summary.elapsed_ut,
        ceilings: summary.ceilings,
        scale_players: summary.scale_players,
        siderians: map_size(state.siderians),
        colonisers: map_size(state.colonisers),
        erased: map_size(state.erased),
        erased_postings: erased_postings(state),
        stats: summary.stats,
        gauges: state.gauges,
        telemetry: summary.telemetry,
        pass_avg_us: summary.perf.avg_us
      },
      extra
    )
  end

  @doc "The Erased roster by posting, as `%{\"home/removal\" => n}` — the shape of the force at a glance."
  def erased_postings(%__MODULE__{} = state) do
    Enum.frequencies_by(Map.values(state.erased), fn entry ->
      "#{Map.get(entry, :theatre, :unposted)}/#{Map.get(entry, :duty, :unposted)}"
    end)
  end

  defp add_siderian_ut(telemetry, bucket, dt) do
    Map.update(telemetry, :siderian_ut, %{bucket => dt}, fn buckets -> Map.update(buckets, bucket, dt, &(&1 + dt)) end)
  end

  # --- orders -----------------------------------------------------------------------

  @doc """
  One jump action per lane, then the terminal action (`colonization`,
  `make_dominion`, `assassination`, …). `extra` carries the fields an action
  needs beyond its target system — `"target_character"` for the two Erased
  attacks that name a victim.
  """
  def itinerary(hops, action_type, target_id, extra \\ %{}) do
    jumps = Enum.map(hops, fn {from, to} -> %{"type" => "jump", "data" => %{"source" => from, "target" => to}} end)
    jumps ++ [%{"type" => action_type, "data" => Map.merge(%{"target" => target_id}, extra)}]
  end

  @doc "JSON-able snapshot for the harness status endpoint."
  def summary(%__MODULE__{} = state) do
    state = upgrade(state)
    perf = state.perf
    passes = Map.get(perf, :passes, 0)

    %{
      bot_faction: state.bot_faction,
      player_id: state.player_id,
      elapsed_ut: Float.round(state.elapsed / 1, 1),
      match_day: match_day(state),
      next_hire_in_ut: Float.round(max(hire_interval(state) - state.hire_accum, 0.0) / 1, 1),
      scale_players: scale_players(state),
      ceilings: ceilings(state),
      colonisers: roster_view(state.colonisers),
      siderians: siderian_view(state.siderians),
      erased: erased_view(state.erased),
      gauges: state.gauges,
      telemetry: telemetry_view(state.telemetry),
      perf: %{
        passes: passes,
        avg_us: if(passes > 0, do: div(Map.get(perf, :total_us, 0), passes), else: 0),
        last_us: Map.get(perf, :last_us, 0),
        max_us: Map.get(perf, :max_us, 0),
        avg_reductions: if(passes > 0, do: div(Map.get(perf, :total_reductions, 0), passes), else: 0),
        last_reductions: Map.get(perf, :last_reductions, 0)
      },
      stats:
        Map.update(state.stats, :refused, %{}, fn refused ->
          Map.new(refused, fn {{what, reason}, n} -> {"#{what}:#{inspect(reason)}", n} end)
        end)
    }
  end

  defp roster_view(roster), do: Map.new(roster, fn {id, entry} -> {id, %{stage: entry.stage, target: entry.target}} end)

  defp siderian_view(roster) do
    Map.new(roster, fn {id, entry} ->
      {id,
       %{
         stage: entry.stage,
         target: entry.target,
         observed: Map.get(entry, :observed),
         overlap: Map.get(entry, :overlap),
         time_ut: entry |> Map.get(:time, %{}) |> round_values()
       }}
    end)
  end

  defp erased_view(roster) do
    Map.new(roster, fn {id, entry} ->
      {id,
       %{
         theatre: Map.get(entry, :theatre),
         duty: Map.get(entry, :duty),
         stage: Map.get(entry, :stage),
         target: Map.get(entry, :target),
         target_character: Map.get(entry, :target_character),
         action: Map.get(entry, :action),
         odds: Map.get(entry, :odds),
         train_target: Map.get(entry, :train_target),
         observed: Map.get(entry, :observed),
         time_ut: entry |> Map.get(:time, %{}) |> round_values()
       }}
    end)
  end

  defp telemetry_view(telemetry) do
    started = Map.get(telemetry, :started_resolved, 0)
    erased_started = Map.get(telemetry, :erased_started_resolved, 0)

    %{
      siderian_ut: telemetry |> Map.get(:siderian_ut, %{}) |> round_values(),
      resolved_attempts: Map.get(telemetry, :resolved, 0),
      avg_travel_ut: average(Map.get(telemetry, :travel_ut, 0.0), started),
      avg_action_ut: average(Map.get(telemetry, :action_ut, 0.0), started),
      erased_ut: telemetry |> Map.get(:erased_ut, %{}) |> round_values(),
      erased_resolved_attempts: Map.get(telemetry, :erased_resolved, 0),
      erased_avg_travel_ut: average(Map.get(telemetry, :erased_travel_ut, 0.0), erased_started),
      reported_day: Map.get(telemetry, :reported_day, 0)
    }
  end

  defp round_values(map), do: Map.new(map, fn {k, v} -> {k, round1(v)} end)

  defp average(_total, 0), do: nil
  defp average(total, n), do: round1(total / n)

  defp round1(value) when is_number(value), do: Float.round(value / 1, 1)

  defp targets(roster) do
    roster
    |> Map.values()
    |> Enum.map(& &1.target)
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  defp positive(value, _fallback) when is_number(value) and value > 0, do: value * 1.0
  defp positive(_value, fallback), do: fallback
end

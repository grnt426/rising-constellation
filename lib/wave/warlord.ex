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
       in reachable sectors; surplus idle colonisers are released.
    3. **Siderians (dominion capture)** — keep up to `max_siderians` Siderians,
       never more than there are capture targets. An idle, rested Siderian
       rolls a sector class (frontier 80 / border 15 / internal 5) and tries to
       turn a neutral system or foreign dominion there into a Rebellion
       dominion. Captured dominions vote for the Rebellion in sector ownership,
       which is what lets it take sectors whose neutrals outnumber their open
       systems.

  ## Snapshot tolerance

  The Warlord is snapshotted with its instance. Fields added after the first
  release are declared with defaults AND back-filled by `upgrade/1`, which the
  agent applies before every pass, so a snapshot taken by older code restores.
  """

  use TypedStruct

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
    # %{character_id => %{stage: :idle | :dispatched, target: system_id | nil, since: float()}}
    field(:siderians, map(), default: %{})
    # ut accumulated toward the next Siderian hire.
    field(:siderian_accum, float(), default: 0.0)
    field(:passes, integer(), default: 0)
    # Last-pass readings (candidate counts, caps, agents left without a target).
    field(:gauges, map(), default: %{})
    # Pass cost: count, total/last/max microseconds and reductions.
    field(:perf, map(), default: %{})
  end

  @added_fields %{siderians: %{}, siderian_accum: 0.0, passes: 0, gauges: %{}, perf: %{}}

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
        captures_attempted: 0,
        captured: 0,
        capture_failed: 0,
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
    until_hire = max(hire_interval(state) - state.hire_accum, 0.0)

    [cadence, until_hire]
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
        elapsed: state.elapsed + elapsed_time
    }
  end

  def advance(state, _), do: state

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

  @doc "The first Siderian is hired at once; each further one waits a full interval."
  def siderian_hire_due?(%__MODULE__{} = state) do
    map_size(state.siderians) == 0 or state.siderian_accum >= siderian_interval(state)
  end

  @doc "Siderians worth keeping: one per capture target, up to `ceiling`."
  def siderian_cap(capture_targets, ceiling) when is_integer(capture_targets) and is_integer(ceiling),
    do: capture_targets |> min(ceiling) |> max(0)

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
    entry = %{stage: :idle, target: nil, since: state.elapsed}
    %{state | siderians: Map.put(state.siderians, character_id, entry), siderian_accum: 0.0}
  end

  def forget_siderian(%__MODULE__{} = state, character_id) do
    %{state | siderians: Map.delete(state.siderians, character_id)}
  end

  def siderian_dispatched(%__MODULE__{} = state, character_id, target) do
    entry = %{stage: :dispatched, target: target, since: state.elapsed}
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

  # --- orders -----------------------------------------------------------------------

  @doc "One jump action per lane, then the terminal action (`colonization`, `make_dominion`, …)."
  def itinerary(hops, action_type, target_id) do
    jumps = Enum.map(hops, fn {from, to} -> %{"type" => "jump", "data" => %{"source" => from, "target" => to}} end)
    jumps ++ [%{"type" => action_type, "data" => %{"target" => target_id}}]
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
      next_hire_in_ut: Float.round(max(hire_interval(state) - state.hire_accum, 0.0) / 1, 1),
      colonisers: roster_view(state.colonisers),
      siderians: roster_view(state.siderians),
      gauges: state.gauges,
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

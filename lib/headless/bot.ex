defmodule Headless.Bot do
  @moduledoc """
  In-process bot driver: one process per player. On a game-time cadence it
  builds a `Headless.Bot.View`, asks its `Headless.Bot.Policy` to decide,
  and executes the returned abstract actions via `Headless.Bot.Act`.

  Timing accounting separates the three costs that matter for AI-evaluation
  capacity planning: view build (reading the game), decide (thinking), and
  act (calling the engine). All are reported in `stats/1` in microseconds,
  plus per-action success/refusal tallies and milestone timestamps the
  validation harness reads (e.g. first colonized system).
  """

  use GenServer

  require Logger

  alias Headless.Bot.View

  defstruct [
    :instance_id,
    :player_id,
    :policy,
    :policy_mem,
    :interval_ms,
    decisions: 0,
    view_us: 0,
    decide_us: 0,
    act_us: 0,
    ok: %{},
    refused: %{},
    initial_systems: nil,
    start_ut: nil,
    first_colony_ut: nil,
    # Golden-line benchmark: economic snapshots at 25/50/75% of game time
    # (elapsed = 1 - ut_time_left/initial), keyed 25/50/75. Lets the
    # dashboard measure bots against a human's development pace.
    initial_utl: nil,
    checkpoints: %{},
    # Colonization funnel: the furthest stage on the path to a first colony
    # this bot ever reached (0..6). Diagnoses WHERE a zero-colony bot gets
    # stuck — see colony_stage/2.
    funnel: 0
  ]

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "Timing + action tallies + milestones."
  def stats(pid), do: GenServer.call(pid, :stats)

  @impl true
  def init(opts) do
    # Policy spec: a module, or {module, params} for parameterized policies
    # (params reach the policy via init ctx — e.g. a Tunable genome).
    {policy, params} =
      case Keyword.fetch!(opts, :policy) do
        {mod, params} when is_atom(mod) -> {mod, params}
        mod when is_atom(mod) -> {mod, %{}}
      end

    state = %__MODULE__{
      instance_id: Keyword.fetch!(opts, :instance_id),
      player_id: Keyword.fetch!(opts, :player_id),
      policy: policy,
      policy_mem: policy.init(%{player_id: Keyword.fetch!(opts, :player_id), params: params}),
      interval_ms: Keyword.get(opts, :interval_ms, 250)
    }

    # Present as a connected client (the same call PlayerChannel makes on
    # join). The engine's activity model only sees channel connections:
    # without this a driver-run player flips is_active=false at
    # @delay_before_inactivity, and inactivity WARPS VICTORY MATH —
    # Victory.reset_player_count counts only active players, and a
    # zero-active-player faction's population-track thresholds collapse
    # to ~index (`min(_, 400*coeff*player_count+index)`), handing the bot
    # a free maxed track (observed live in instance 7, 2026-07-07). The
    # result is ignored: the driver acts either way.
    Game.call(state.instance_id, :player, state.player_id, {:update_client_status, :connect})

    schedule(state)
    {:ok, state}
  end

  @impl true
  def terminate(_reason, state) do
    # Balance init's :connect so a permanently undriven bot player can go
    # inactive like any abandoned account. Crash exits skip terminate and
    # leave the count high — acceptable: a driver the overseer/runner
    # will respawn should keep reading as connected.
    Game.call(state.instance_id, :player, state.player_id, {:update_client_status, :disconnect})
    :ok
  end

  @impl true
  def handle_call(:stats, _from, state) do
    {:reply,
     %{
       policy: state.policy,
       policy_mem: state.policy_mem,
       decisions: state.decisions,
       view_us: state.view_us,
       decide_us: state.decide_us,
       act_us: state.act_us,
       ok: state.ok,
       refused: state.refused,
       first_colony_ut: state.first_colony_ut,
       checkpoints: state.checkpoints,
       funnel: state.funnel
     }, state}
  end

  @impl true
  def handle_info(:act, state) do
    state =
      case timed(fn -> View.build(state.instance_id, state.player_id) end) do
        {{:ok, view}, view_us} ->
          {{actions, mem}, decide_us} = timed(fn -> state.policy.decide(view, state.policy_mem) end)
          {results, act_us} = timed(fn -> Enum.map(actions, &execute(state, &1)) end)

          %{
            state
            | policy_mem: mem,
              decisions: state.decisions + 1,
              view_us: state.view_us + view_us,
              decide_us: state.decide_us + decide_us,
              act_us: state.act_us + act_us
          }
          |> tally(actions, results)
          |> track_milestones(view)
          |> track_checkpoints(view)
          |> track_funnel(view)

        {_error, view_us} ->
          # Instance may be mid-teardown at game end; just skip this tick.
          %{state | view_us: state.view_us + view_us}
      end

    schedule(state)
    {:noreply, state}
  end

  defp schedule(state), do: Process.send_after(self(), :act, state.interval_ms)

  defp timed(fun) do
    t0 = System.monotonic_time(:microsecond)
    result = fun.()
    {result, System.monotonic_time(:microsecond) - t0}
  end

  defp execute(state, action) do
    Headless.Bot.Act.execute(state.instance_id, state.player_id, action)
  end

  # Per-action-kind success/refusal counters, keyed by the action's tag atom.
  defp tally(state, actions, results) do
    Enum.zip(actions, results)
    |> Enum.reduce(state, fn {action, result}, acc ->
      kind =
        case action do
          # Distinguish mission KINDS (raid vs infiltrate vs …) and the
          # exact patent/lex/building/ship KEYS in tallies — per-key usage
          # telemetry (user request 2026-07-06): every purchase and order
          # is attributable, so "which lexes do winners actually buy" is a
          # query, not an inference.
          {:queue_travel_action, _, _, type, _} -> {:mission, type}
          {:queue_travel_character_action, _, _, type, _, _} -> {:mission, type}
          {:queue_travel, _, _} -> {:mission, "reposition"}
          {:queue_mission, _, _, _} -> {:mission, "colonization"}
          {:purchase_patent, key} -> {:patent, key}
          {:purchase_doctrine, key} -> {:doctrine, key}
          {:order_building, _sys, _body, _tile, key} -> {:build, key}
          {:order_ship, _sys, _char, _tile, key} -> {:ship, key}
          {:activate_character, _, mode, _} -> {:activate, mode}
          other -> elem(other, 0)
        end

      case result do
        {:error, reason} -> %{acc | refused: Map.update(acc.refused, {kind, reason}, 1, &(&1 + 1))}
        _ -> %{acc | ok: Map.update(acc.ok, kind, 1, &(&1 + 1))}
      end
    end)
  end

  # Milestones the validation harness cares about. `initial_systems` is
  # captured on the first view; the first time owned-system count exceeds it
  # we stamp game time — that's "time to first colony" for the race metric.
  defp track_milestones(state, view) do
    owned = length(view.player.stellar_systems)

    cond do
      state.initial_systems == nil ->
        %{state | initial_systems: owned, start_ut: view.now_ut}

      state.first_colony_ut == nil and owned > state.initial_systems ->
        # Elapsed game-days from the bot's first observation — the race metric.
        %{state | first_colony_ut: view.now_ut && state.start_ut && Float.round(view.now_ut - state.start_ut, 1)}

      true ->
        state
    end
  end

  # Snapshot the economy the first time the game crosses each 25/50/75%
  # elapsed mark (elapsed = 1 - ut_time_left/initial_ut_time_left). The
  # victory clock (2400 UT → 0) is the reliable game-time; view.now_ut is a
  # date clock, so we normalize against the first ut_time_left we observe.
  defp track_checkpoints(state, view) do
    utl = view.victory && Map.get(view.victory, :ut_time_left)

    cond do
      not is_number(utl) ->
        state

      state.initial_utl == nil ->
        %{state | initial_utl: utl}

      true ->
        total = state.initial_utl
        elapsed = if total > 0, do: 1.0 - utl / total, else: 0.0

        Enum.reduce([{0.25, 25}, {0.50, 50}, {0.75, 75}], state, fn {frac, key}, st ->
          if elapsed >= frac and not Map.has_key?(st.checkpoints, key) do
            %{st | checkpoints: Map.put(st.checkpoints, key, econ_snapshot(view))}
          else
            st
          end
        end)
    end
  end

  defp econ_snapshot(view) do
    p = view.player
    chars = Map.values(view.characters)
    by = fn t -> Enum.count(chars, &(&1.type == t)) end

    pop =
      view.systems
      |> Map.values()
      |> Enum.map(fn s -> s.population.value end)
      |> Enum.sum()
      |> round()

    %{
      "sys" => length(p.stellar_systems),
      "pop" => pop,
      "income" => round(p.credit.change),
      "tech" => round(p.technology.change),
      "hoarded" => round(p.credit.value),
      "navarch" => by.(:admiral),
      "erased" => by.(:spy),
      "siderian" => by.(:speaker)
    }
  end

  # Furthest stage on the road to a first colony (user's blocker ranking).
  # A STRICT prerequisite funnel: the stage is the FIRST unmet link in the
  # chain, so a bot that has a Navarch home but never bought the cap lex is
  # reported at the lex (stage 2), not hidden behind the later Navarch rungs.
  # HARD blockers (0..3): 0 the root patent (citadel), 1 the colony-ship
  # patent (transport_1), 2 the system-expansion lex (system_1 — raises the
  # cap so a 2nd system is claimable), 3 ever having a Navarch. SOFT (4..7):
  # 4 a Navarch on-board at home, 5 a colony ship actually built, 6 that ship
  # dispatched to a target, 7 dispatched but the colony never landed. This
  # split isolates the two things a stalled bot might be missing: the lex
  # (stage 2 — "never bought it") vs. the ship order (stage 5 — "has an open
  # slot but never enqueued the transport").
  defp track_funnel(state, view) do
    %{state | funnel: max(state.funnel, colony_stage(view, state.ok))}
  end

  defp colony_stage(view, ok) do
    p = view.player
    admirals = view.characters |> Map.values() |> Enum.filter(&(&1.type == :admiral))

    has_navarch? =
      admirals != [] or
        Enum.any?(Map.get(p, :character_deck, []), &match?(%{character: %{type: :admiral}}, &1))

    navarch_home? = Enum.any?(admirals, &(&1.status == :on_board))

    cond do
      :citadel not in p.patents -> 0
      :transport_1 not in p.patents -> 1
      :system_1 not in Map.get(p, :doctrines, []) -> 2
      not has_navarch? -> 3
      not navarch_home? -> 4
      Map.get(ok, {:ship, :transport_1}, 0) == 0 -> 5
      Map.get(ok, {:mission, "colonization"}, 0) == 0 -> 6
      true -> 7
    end
  end
end

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
    first_colony_ut: nil
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

    schedule(state)
    {:ok, state}
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
       first_colony_ut: state.first_colony_ut
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
          # Distinguish mission KINDS (raid vs infiltrate vs …) in tallies.
          {:queue_travel_action, _, _, type, _} -> {:mission, type}
          {:queue_travel_character_action, _, _, type, _, _} -> {:mission, type}
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
end

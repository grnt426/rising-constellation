defmodule Instance.Character.Action do
  use TypedStruct

  alias Instance.Character
  alias Instance.Character.Action

  def jason(), do: []

  typedstruct enforce: true do
    field(:type, atom())
    field(:data, %{})
    field(:total_time, float() | atom())
    field(:remaining_time, float() | atom())
    field(:started_at, integer() | nil)
    field(:cumulated_pauses, integer() | nil)
  end

  def new({type, data, time}) do
    %Character.Action{
      type: type,
      data: data,
      total_time: time,
      remaining_time: time,
      started_at: nil,
      cumulated_pauses: nil
    }
  end

  def reset_time(%Action{} = action, time) do
    %{action | total_time: time, remaining_time: time}
  end

  def start(%Action{} = action, cumulated_pauses) do
    %{action | started_at: Instance.Time.Time.now(cumulated_pauses), cumulated_pauses: cumulated_pauses}
  end

  def compute_remaining_time(%Action{} = action, time_since_last_tick, cumulated_pauses) do
    cond do
      is_nil(action.started_at) and action.total_time == action.remaining_time ->
        action = start(action, cumulated_pauses)
        {:start, action}

      action.remaining_time >= time_since_last_tick ->
        {:unfinished, %{action | remaining_time: action.remaining_time - time_since_last_tick}}

      true ->
        {:finished, time_since_last_tick - action.remaining_time}
    end
  end

  @doc """
  Computes the current progress of an Action as a value in [0.0, 1.0].

  Clock-based: `(now - started_at) * factor / (180_000 * total_time)`.

  Clock-based progress is needed so the result advances *continuously* between
  the rare moments the engine actually updates `remaining_time`. A moving
  character's `compute_next_tick_interval` schedules its next tick at action
  COMPLETION, so `remaining_time` is frozen at its starting value for the
  entire jump as far as the player snapshot is concerned. A
  remaining-time-based formula would return 0 for the whole flight and only
  pop to 1 at arrival — exactly the "all my agents look like they just left"
  symptom Granite reported in prod 2026-06-14.

  Across a BEAM restart the OLD monotonic-time form broke because each
  action's snapshotted `started_at` is anchored in the dead BEAM's monotonic
  frame; the new BEAM's clock has a different origin and `now - started_at`
  goes nonsense. `Character.Agent` now rebases every in-flight action's
  `started_at` to the live monotonic frame at `:start` time (see
  `rebase_started_at/2`), so this formula reads consistent values regardless
  of how many restarts the action has survived. The rebase also makes
  deploys NOT credit progress for downtime — exactly per the engine's
  "no simulation while the server is stopped" contract.
  """
  def compute_progress(%Action{} = action, factor) do
    %Action{
      started_at: started_at,
      remaining_time: remaining_time,
      total_time: total_time,
      cumulated_pauses: cumulated_pauses
    } = action

    cond do
      is_nil(started_at) ->
        0.0

      remaining_time <= 0 ->
        1.0

      true ->
        now = Instance.Time.Time.now(cumulated_pauses)

        (factor * (now - started_at) / (180_000 * total_time))
        |> Float.round(5)
    end
  end

  @doc """
  Rebases `started_at` to the live monotonic clock frame so
  `compute_progress` reads back the same fraction that `remaining_time /
  total_time` currently encodes.

  Called by `Character.Agent` on `:start` for every in-flight action. Handles
  two scenarios with the same arithmetic:

    * **BEAM restart after a snapshot.** The action's `started_at` is from
      the dead BEAM's monotonic frame and is meaningless against the new
      clock. The rebase recovers a coherent `started_at` in the new frame.

    * **Engine pause/resume.** Between stop and start no character ticks
      fired, so `remaining_time` is intact; rebasing `started_at` to the
      live clock makes the formula resume from exactly the pre-pause
      progress fraction — i.e. the pause does not credit progress, which
      matches the "no simulation while paused" contract.

  Actions without `started_at` (queued but not yet started) are left
  untouched; their `started_at` will be set the normal way on first tick.

  Actions whose duration is not yet resolved (`total_time` /
  `remaining_time` still `:unknown_yet` — an infiltrate that
  `process_next_action` has stamped `started_at` on but whose
  `ActionImpl.start` has not yet run `reset_time`, or crashed before it
  could) are ALSO left untouched. The arithmetic below does
  `total_time - remaining_time`; on `:unknown_yet` atoms that raises
  `ArithmeticError`, which crashes `Character.Agent`'s `:start` for the
  WHOLE agent on every restart/resume/deploy. That froze Kika & Fugiko
  on 2026-06-15: their half-stamped infiltrate made them un-restorable,
  the tick never started, and the stale `:locked` head left them
  "traveling" with an identical ~5h timer and no clickable position.
  There is no elapsed progress to rebase on an unresolved action, so the
  no-op is also semantically correct; `started_at` is reset the normal
  way once the duration resolves on the next successful `:to_start`.
  """
  def rebase_started_at(%Action{started_at: nil} = action, _factor, _cumulated_pauses), do: action

  def rebase_started_at(
        %Action{total_time: total_time, remaining_time: remaining_time} = action,
        _factor,
        _cumulated_pauses
      )
      when not (is_number(total_time) and is_number(remaining_time)),
      do: action

  def rebase_started_at(%Action{} = action, factor, cumulated_pauses) do
    %Action{total_time: total_time, remaining_time: remaining_time} = action
    elapsed_units = max(total_time - remaining_time, 0)
    elapsed_ms = elapsed_units * 180_000 / factor

    %{
      action
      | started_at: Instance.Time.Time.now(cumulated_pauses) - trunc(elapsed_ms),
        cumulated_pauses: cumulated_pauses
    }
  end
end

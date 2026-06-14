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

  Derived from `remaining_time / total_time` rather than `(now - started_at)`.
  `remaining_time` is decremented per tick by `compute_remaining_time/3` using
  the per-tick delta from `Core.Tick.delta/1`, so it stays correct across BEAM
  restarts. The clock-based form previously used here broke whenever an action
  outlived a restart: `started_at` was captured from the OLD BEAM's
  `System.monotonic_time` and compared against the NEW BEAM's monotonic clock,
  which has a different origin. The result was negative `progress` values, an
  extrapolated-backward position in `Character.get_position/2`, and Faction
  radar `in_disk` checks rejecting in-flight characters even though their
  rtree bbox intersected the disk.

  `_factor` is accepted for call-site compatibility but unused — progress is
  already expressed in the action's own time units.
  """
  def compute_progress(%Action{} = action, _factor) do
    %Action{
      started_at: started_at,
      remaining_time: remaining_time,
      total_time: total_time
    } = action

    cond do
      is_nil(started_at) -> 0.0
      remaining_time <= 0 -> 1.0
      total_time <= 0 -> 1.0
      true -> ((total_time - remaining_time) / total_time) |> Float.round(5)
    end
  end
end

defmodule Headless.Cpu do
  @moduledoc """
  Scheduler-time accounting for headless runs.

  Wraps `:erlang.statistics(:scheduler_wall_time)`: take a `snapshot/0`
  before and after a stretch of work, and `delta/2` returns

    * `:util` — average fraction of the online schedulers that were busy
    * `:busy_seconds` — total busy scheduler-seconds (CPU-seconds) consumed

  Busy scheduler-seconds is the unit the capacity math needs: a machine
  budgeted at `C` cores × 60 s spends `C × 60` scheduler-seconds per minute;
  divide by per-game busy-seconds to get games/minute.
  """

  def enable do
    :erlang.system_flag(:scheduler_wall_time, true)
  end

  def snapshot do
    :erlang.statistics(:scheduler_wall_time) |> Enum.sort()
  end

  def delta(s0, s1) do
    {active, total} =
      Enum.zip(s0, s1)
      |> Enum.reduce({0, 0}, fn {{_, a0, t0}, {_, a1, t1}}, {a, t} ->
        {a + (a1 - a0), t + (t1 - t0)}
      end)

    util = if total > 0, do: active / total, else: 0.0
    # `total` per scheduler ≈ elapsed wall time in native units; busy CPU-time
    # is the summed active time converted to seconds.
    busy_seconds = :erlang.convert_time_unit(active, :native, :microsecond) / 1_000_000

    %{util: Float.round(util, 3), busy_seconds: Float.round(busy_seconds, 1)}
  end
end

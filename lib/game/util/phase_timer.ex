defmodule Util.PhaseTimer do
  @moduledoc """
  Wall-clock phase timing for coarse-grained boot instrumentation.

  Instance creation for a large galaxy is a multi-second, CPU-heavy
  pipeline (system generation → edge graph → agent spawns); these logs
  attribute that cost per phase so a slow boot in dev or prod is
  diagnosable from the log stream alone.
  """

  require Logger

  @doc """
  Runs `fun`, logs `[boot-timing] <label>: <ms>` at info level, and
  returns `fun`'s result.
  """
  def timed(label, fun) do
    {us, result} = :timer.tc(fun)
    # :warning so the line clears dev's console level (:warning) — these fire
    # a handful of times per instance boot, so there's no log-volume concern.
    Logger.warning("[boot-timing] #{label}: #{Float.round(us / 1000, 1)} ms")
    result
  end
end

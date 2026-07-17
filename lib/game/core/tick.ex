defmodule Core.Tick do
  use TypedStruct

  alias Core.Tick
  alias Instance.Time.Time

  # set the UNIT TIME to 1 day in normal speed
  @unit_time_divider 180_000

  typedstruct enforce: true do
    field(:time, integer())
    field(:cumulated_pauses, integer() | nil, default: nil)
    field(:factor, integer())
    field(:ref, reference(), enforce: false)
    field(:running?, boolean(), default: false)
  end

  # SPEEDUP is a dev/headless-only multiplier on game speed (prod leaves it
  # unset → 1). Read at runtime on first use and cached for the BEAM's
  # lifetime, so headless tooling (mix headless.run) can vary it per run
  # without recompiling. It was previously a compile-time module attribute,
  # which silently kept the old value when the env var changed — and on
  # bind-mounted dev checkouts source-mtime flakiness made the required
  # recompile unreliable.
  def speedup do
    case :persistent_term.get({__MODULE__, :speedup}, nil) do
      nil ->
        value = System.get_env("SPEEDUP", "1") |> String.to_integer()
        :persistent_term.put({__MODULE__, :speedup}, value)
        value

      value ->
        value
    end
  end

  defp millisecond_padding, do: (50 / speedup()) |> Kernel.round() |> Kernel.max(1)

  def new(factor) do
    %Core.Tick{time: Time.now(), factor: factor * speedup(), cumulated_pauses: nil}
  end

  # The SPEEDUP env multiplier baked into every factor by new/1. Exposed so
  # runtime factor rewrites (the speed cheat) can preserve it:
  # effective_factor = speed.factor * cheat_multiplier * env_speedup().
  # Merge fix 2026-07-17: master returned the compile-time @speedup
  # attribute; this branch made SPEEDUP runtime (speedup/0), so the
  # attribute no longer exists — returning it was `nil` and would have
  # crashed the first cheat-driven factor rewrite.
  def env_speedup, do: speedup()

  def start(%Tick{cumulated_pauses: cumulated_pauses} = state) do
    ref = Process.send_after(self(), :tick, 0)
    %{state | time: Time.now(cumulated_pauses), ref: ref, running?: true}
  end

  def next(%Tick{cumulated_pauses: cumulated_pauses} = state, :never) do
    unless state.ref == nil,
      do: Process.cancel_timer(state.ref)

    %{state | time: Time.now(cumulated_pauses), ref: nil}
  end

  def next(%Tick{cumulated_pauses: cumulated_pauses} = state, interval) do
    unless state.ref == nil,
      do: Process.cancel_timer(state.ref)

    ref = Process.send_after(self(), :tick, interval)
    %{state | time: Time.now(cumulated_pauses), ref: ref}
  end

  def stop(%Tick{} = state) do
    unless state.ref == nil,
      do: Process.cancel_timer(state.ref)

    %{state | ref: nil, running?: false}
  end

  def delta(%Tick{cumulated_pauses: cumulated_pauses} = state) do
    (Time.now(cumulated_pauses) - state.time) * state.factor / @unit_time_divider
  end

  # TODO: set a "max milisecond" time when never
  def unit_time_to_millisecond(_state, :never),
    do: :never

  def unit_time_to_millisecond(state, unit_time) do
    millisecond =
      (unit_time / state.factor * @unit_time_divider)
      |> Float.ceil()
      |> Kernel.trunc()

    millisecond + millisecond_padding()
  end

  def millisecond_to_unit_time(milliseconds, factor) do
    milliseconds * factor / @unit_time_divider
  end
end

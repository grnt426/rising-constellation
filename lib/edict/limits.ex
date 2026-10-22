defmodule Edict.Limits do
  @moduledoc """
  Every hard limit an Edict script runs under, in one place.

  The limits come in three layers, and each one stops a different kind of
  runaway script without relying on the others:

    * **Source limits** stop a script before it is parsed: bytes, tokens,
      nesting depth, node count, name and text length.
    * **Fuel** stops a script while it runs: every evaluation step costs one
      unit, and list or text builtins cost one per element. A pulse that runs
      out of fuel is cut off with an error, deterministically, at the same
      step on every machine.
    * **Process limits** (`Edict.Sandbox`) are the backstop: the evaluation
      runs in its own process with a capped heap and a wall-clock timeout, so
      a bug in the interpreter itself cannot take memory or time from the
      game.

  Values have caps of their own (`max_list`, `max_map`, `max_string`,
  `max_state_bytes`) so a script cannot grow its state across pulses either.
  """

  # --- source ----------------------------------------------------------------
  def max_source_bytes, do: 64 * 1024
  def max_tokens, do: 20_000
  def max_identifier, do: 64
  def max_depth, do: 48
  def max_nodes, do: 8_000

  # --- values ----------------------------------------------------------------
  def max_string, do: 4_096
  def max_list, do: 10_000
  def max_map, do: 1_000
  # serialized size of all `var` state together, checked after every pulse
  def max_state_bytes, do: 256 * 1024
  # the largest magnitude a number may reach (beyond it is an error, not
  # infinity)
  def max_number, do: 1.0e15

  # --- running ---------------------------------------------------------------
  def fuel_per_pulse, do: 200_000
  def fuel_for_setup, do: 20_000
  def max_call_depth, do: 64
  def max_effects_per_pulse, do: 50

  # --- process backstop ------------------------------------------------------
  # in words (8 bytes each on a 64-bit BEAM): about 16 MB, counting the
  # shared binaries (text) the process holds. The heaviest pulse measured
  # needs 6.3 MB (test/edict/resource_bench_test.exs).
  def max_heap_words, do: 2 * 1024 * 1024
  def timeout_ms, do: 2_000
end

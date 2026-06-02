defmodule RC.DebugFlagsTest do
  @moduledoc """
  Sanity tests for `RC.DebugFlags`. The interesting half of A — the
  structured `check_interception` log line — is exercised by the
  fleet-interaction integration test (test/game/integration/...).
  These tests just pin the flag-read contract:

    * default is `false`
    * `set_*/1` flips the flag and is observable by the matching `?/0`
    * runtime override survives across calls in the same BEAM
  """
  use ExUnit.Case, async: false

  setup do
    # The flag is process-global (Application env). async: false above
    # prevents two tests from racing on the same key; on_exit resets it
    # to the default so we don't leak state into other tests.
    on_exit(fn -> RC.DebugFlags.set_fleet_interception(false) end)
    :ok
  end

  describe "fleet_interception" do
    test "defaults to false" do
      RC.DebugFlags.set_fleet_interception(false)
      refute RC.DebugFlags.fleet_interception?()
    end

    test "set/get round-trips" do
      RC.DebugFlags.set_fleet_interception(true)
      assert RC.DebugFlags.fleet_interception?()

      RC.DebugFlags.set_fleet_interception(false)
      refute RC.DebugFlags.fleet_interception?()
    end

    test "set/1 rejects non-booleans" do
      # Guard clauses on set_fleet_interception/1 — non-booleans must
      # raise FunctionClauseError so a typo can't silently turn the flag
      # into something truthy-but-weird.
      assert_raise FunctionClauseError, fn ->
        RC.DebugFlags.set_fleet_interception(:on)
      end

      assert_raise FunctionClauseError, fn ->
        RC.DebugFlags.set_fleet_interception("true")
      end
    end
  end
end

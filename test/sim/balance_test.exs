defmodule Sim.BalanceTest do
  use ExUnit.Case, async: true

  test "presets include a baseline control and the corvette rework" do
    presets = Sim.Balance.presets()

    assert presets.baseline == %{}
    assert :corvette_rework in Sim.Balance.names()

    rework = Sim.Balance.changes(:corvette_rework)
    assert rework.corvette_1.unit_explosive_strikes == [30]
    assert rework.corvette_1.unit_raid_coef == 0.0
    assert rework.corvette_3.unit_hull == 175
    assert rework.corvette_3.unit_interception == 0
  end

  test "changes/1 raises on an unknown preset" do
    assert_raise KeyError, fn -> Sim.Balance.changes(:nope) end
  end
end

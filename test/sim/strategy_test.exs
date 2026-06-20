defmodule Sim.StrategyTest do
  use ExUnit.Case, async: false

  setup_all do
    Sim.Setup.ensure_installed()
    :ok
  end

  test "strategies are defined with objectives and a champion picker" do
    ss = Sim.Strategy.strategies()
    assert length(ss) == 4
    assert Enum.all?(ss, fn s -> is_list(s.objectives) and is_function(s.pick, 1) end)
  end

  test "champions + cross_play produce a full N x N matrix" do
    champs = Sim.Strategy.champions(:early, pop_size: 10, generations: 3, battles: 4)
    assert length(champs) == 4

    matrix = Sim.Strategy.cross_play(champs, :early, battles: 6)
    assert length(matrix) == 16
    assert Enum.all?(matrix, fn r -> r.att_win >= 0.0 and r.att_win <= 1.0 end)
  end

  test "archetype returns dominant base-types" do
    :rand.seed(:exrop, {1, 2, 3})
    assert is_list(Sim.Strategy.archetype(Sim.Genome.random(), :early))
  end
end

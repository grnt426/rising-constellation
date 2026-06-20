defmodule Sim.LevelBreakTest do
  use ExUnit.Case, async: false

  setup_all do
    Sim.Setup.ensure_installed()
    :ok
  end

  test "type_matrix reports a break level (int >= 1 or :none) per pair" do
    matrix = Sim.LevelBreak.type_matrix([:fighter_1, :fighter_4, :corvette_1], battles: 12, max_boost: 8)

    assert length(matrix) == 3

    Enum.each(matrix, fn r ->
      assert r.break_level == :none or (is_integer(r.break_level) and r.break_level >= 1)
      assert r.base_winner in [:fighter_1, :fighter_4, :corvette_1]
      assert r.base_loser in [:fighter_1, :fighter_4, :corvette_1]
    end)
  end

  test "tide_turn_counters returns non-negative fractional type weights" do
    :rand.seed(:exrop, {7, 8, 9})
    pairs = for _ <- 1..4, do: {Sim.Genome.random(), Sim.Genome.random()}

    counters = Sim.LevelBreak.tide_turn_counters(pairs, :early, battles: 8)

    assert is_map(counters)
    assert Enum.all?(Map.values(counters), fn v -> v >= 0.0 end)
  end
end

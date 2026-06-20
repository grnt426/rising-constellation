defmodule Daily.MutatorGenTest do
  use ExUnit.Case, async: true

  # Pure logic for the world-generation (on_galaxy_spawn) mutators. The engine
  # wiring lives in Instance.StellarSystem.StellarBody.new/5; here we lock the
  # decision functions that wiring delegates to.

  alias Data.Game.Mutator

  describe "gen_factor_override/2" do
    test "worlds_of_plenty maxes planet factors, leaves orbitals alone" do
      assert Mutator.gen_factor_override([:worlds_of_plenty], :primary) == :max
      assert Mutator.gen_factor_override([:worlds_of_plenty], :secondary) == nil
    end

    test "hardscrabble_worlds bottoms planet factors, leaves orbitals alone" do
      assert Mutator.gen_factor_override([:hardscrabble_worlds], :primary) == :min
      assert Mutator.gen_factor_override([:hardscrabble_worlds], :secondary) == nil
    end

    test "gilded_orbitals maxes orbital factors, leaves planets alone" do
      assert Mutator.gen_factor_override([:gilded_orbitals], :secondary) == :max
      assert Mutator.gen_factor_override([:gilded_orbitals], :primary) == nil
    end

    test "no world-gen mutator means roll normally" do
      assert Mutator.gen_factor_override([], :primary) == nil
      assert Mutator.gen_factor_override([:empire_of_wealth], :secondary) == nil
    end
  end

  describe "apply_factor/3" do
    test "nil keeps the rolled value" do
      assert Mutator.apply_factor(3, nil, 1..5) == 3
    end

    test ":max and :min clamp to the range extremes (per stat, not a hardcoded 5)" do
      assert Mutator.apply_factor(3, :max, 1..5) == 5
      assert Mutator.apply_factor(3, :min, 1..5) == 1
      # activity ranges only go to 4 — clamp respects that
      assert Mutator.apply_factor(2, :max, 1..4) == 4
    end
  end

  describe "extra_tiles/1" do
    test "frontier mutators add building tiles" do
      assert Mutator.extra_tiles([:sprawling_frontier]) == 2
      assert Mutator.extra_tiles([:open_frontier]) == 1
      assert Mutator.extra_tiles([]) == 0
    end

    test "the bigger frontier wins if both are somehow active" do
      assert Mutator.extra_tiles([:open_frontier, :sprawling_frontier]) == 2
    end
  end

  test "the five world-gen mutators are now wired (implemented)" do
    for key <- [
          :worlds_of_plenty,
          :hardscrabble_worlds,
          :gilded_orbitals,
          :sprawling_frontier,
          :open_frontier
        ] do
      assert Mutator.get(key).implemented, "#{key} should be implemented"
    end
  end
end

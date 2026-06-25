defmodule Sim.GATest do
  @moduledoc "NSGA-II primitives + small end-to-end evolution runs."
  use ExUnit.Case, async: false

  setup_all do
    Sim.Setup.ensure_installed()
    :ok
  end

  describe "NSGA-II primitives" do
    test "dominance is strict Pareto on max-oriented objectives" do
      a = %{obj: [3.0, 3.0]}
      b = %{obj: [2.0, 2.0]}
      c = %{obj: [3.0, 1.0]}

      assert Sim.GA.dominates?(a, b)
      refute Sim.GA.dominates?(b, a)
      # a equals c on obj1 and beats it on obj2 -> a dominates c
      assert Sim.GA.dominates?(a, c)
      # b and c are mutually non-dominated (each wins one objective)
      refute Sim.GA.dominates?(b, c)
      refute Sim.GA.dominates?(c, b)
    end

    test "non-dominated sort puts the strictly-best individual alone on front 0" do
      inds = [
        %{obj: [3.0, 3.0], genome: 1},
        %{obj: [2.0, 2.0], genome: 2},
        %{obj: [3.0, 1.0], genome: 3},
        %{obj: [1.0, 1.0], genome: 4}
      ]

      [front0 | _] = Sim.GA.non_dominated_sort(inds)
      genomes = Enum.map(front0, & &1.genome)

      assert genomes == [1]
    end

    test "front of two mutually non-dominated points contains both" do
      inds = [%{obj: [2.0, 1.0], genome: :a}, %{obj: [1.0, 2.0], genome: :b}]
      [front0 | _] = Sim.GA.non_dominated_sort(inds)
      assert MapSet.new(Enum.map(front0, & &1.genome)) == MapSet.new([:a, :b])
    end
  end

  describe "evolution" do
    test "a small run yields a Pareto front of valid early-stage fleets" do
      res = Sim.GA.run(:early, pop_size: 10, generations: 3, battles: 4, base_seed: 7)

      assert length(res.front) >= 1

      Enum.each(res.front, fn ind ->
        assert length(ind.genome) == Sim.Genome.slots() + length(Sim.Genome.class_order())
        assert is_number(ind.metrics.credit)
        assert ind.metrics.win_rate >= 0.0 and ind.metrics.win_rate <= 1.0
      end)
    end

    test "a run is reproducible for a fixed base_seed" do
      a = Sim.GA.run(:early, pop_size: 10, generations: 3, battles: 4, base_seed: 9)
      b = Sim.GA.run(:early, pop_size: 10, generations: 3, battles: 4, base_seed: 9)

      assert Enum.map(a.front, & &1.genome) == Enum.map(b.front, & &1.genome)
    end

    test "the front is genuinely non-dominated (no member dominates another)" do
      res = Sim.GA.run(:early, pop_size: 12, generations: 3, battles: 4, base_seed: 4)

      for x <- res.front, y <- res.front, x.genome != y.genome do
        refute Sim.GA.dominates?(x, y)
      end
    end

    test "objectives are pluggable — antagonistic 'deny enemy bombing power'" do
      res =
        Sim.GA.run(:mid,
          pop_size: 10,
          generations: 2,
          battles: 4,
          base_seed: 3,
          objectives: [{:deny, :min, & &1.enemy_bomb}, {:credit, :min, & &1.credit}]
        )

      assert res.objective_names == [:deny, :credit]
      assert length(res.front) >= 1
    end

    test "Hall-of-Fame co-evolution returns a front, per-gen history, and a growing archive" do
      res = Sim.GA.coevolve(:early, pop_size: 10, generations: 3, battles: 4, sample: 3, base_seed: 2)

      assert length(res.front) >= 1
      assert length(res.history) == 3
      # the seed archetypes always survive in the HoF
      assert length(res.hall_of_fame) >= 3
      assert Enum.all?(res.history, fn h -> h.hof_size >= 3 end)
    end

    test "bomb-retention objective builds and runs" do
      objectives = [Sim.GA.retain_bomb(40), {:credit, :min, & &1.credit}]
      res = Sim.GA.run(:mid, pop_size: 8, generations: 2, battles: 4, base_seed: 1, objectives: objectives)

      assert :retain_bomb_40 in res.objective_names
      assert length(res.front) >= 1
    end

    test "antagonistic siege arena returns siege + denial fronts and an arms-race history" do
      res = Sim.GA.antagonize(:mid, 40, pop_size: 10, generations: 3, battles: 4, sample: 3, base_seed: 1)

      assert res.threshold == 40
      assert length(res.siege_front) >= 1
      assert length(res.denial_front) >= 1
      assert length(res.history) == 3

      Enum.each(res.history, fn h ->
        assert h.siege_best_retain >= 0.0 and h.siege_best_retain <= 1.0
        assert h.denial_best_deny >= 0.0 and h.denial_best_deny <= 1.0
      end)
    end

    test "antagonize rejects a non-multiple-of-20 threshold" do
      assert_raise ArgumentError, fn -> Sim.GA.antagonize(:mid, 35, generations: 1) end
    end
  end

  describe "hard constraints" do
    test "retain_bomb_constraint violation is 0 when satisfied, positive when short" do
      c = Sim.GA.retain_bomb_constraint(40, 0.8)
      assert c.(%{bomb_ge: %{40 => 0.9}}) == 0.0
      assert c.(%{bomb_ge: %{40 => 0.8}}) == 0.0
      assert c.(%{bomb_ge: %{40 => 0.5}}) > 0.0
    end

    test "feasibility-first domination: if any feasible design exists, the front is all feasible" do
      res =
        Sim.GA.run(:mid,
          pop_size: 12,
          generations: 4,
          battles: 6,
          base_seed: 1,
          objectives: [{:credit, :min, & &1.credit}],
          constraints: [Sim.GA.retain_bomb_constraint(40, 0.7)]
        )

      assert Enum.all?(res.front, fn i -> Map.has_key?(i, :violation) end)

      if Enum.any?(res.front, fn i -> i.violation == 0.0 end) do
        assert Enum.all?(res.front, fn i -> i.violation == 0.0 end)
      end
    end

    test "describe_ordered renders tiles in deployment order" do
      :rand.seed(:exrop, {1, 2, 3})
      ordered = Sim.GA.describe_ordered(Sim.Genome.random(), :mid)
      assert is_binary(ordered)
    end
  end
end

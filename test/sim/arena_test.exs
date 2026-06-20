defmodule Sim.ArenaTest do
  @moduledoc """
  Milestone-1/2 tests for the headless battle simulator. No DB or running
  game instance — everything runs off the cached :sim dataset.
  """
  use ExUnit.Case, async: false

  alias Instance.Character.Army

  setup_all do
    Sim.Setup.ensure_installed()
    :ok
  end

  describe "reproducibility" do
    test "the same (fleets, seed) yields an identical battle result" do
      att = Sim.Fleet.mono(:fighter_4, 6, id: 1)
      def_ = Sim.Fleet.mono(:corvette_1, 6, id: 2)

      assert Sim.Arena.battle(att, def_, 123) == Sim.Arena.battle(att, def_, 123)
    end
  end

  describe "no-log sim path" do
    test "silent mode produces identical outcomes to logged mode (and empty logs)" do
      att = Sim.Fleet.mono(:corvette_1, 8, id: 1)
      def_ = Sim.Fleet.mono(:fighter_4, 8, id: 2)

      run = fn silent ->
        Process.put(:rc_sim_rand_state, :rand.seed_s(:exrop, 7))
        if silent, do: Process.put(:rc_sim_silent, true), else: Process.delete(:rc_sim_silent)

        {{[{_, _, ac}], [{_, _, dc}]}, logs, _meta, victory} = Fight.Manager.fight([att], [def_])
        {victory, trunc(Army.compute_total_pv(ac.army)), trunc(Army.compute_total_pv(dc.army)), logs}
      end

      {v_silent, ap_silent, dp_silent, logs_silent} = run.(true)
      {v_logged, ap_logged, dp_logged, logs_logged} = run.(false)
      Process.delete(:rc_sim_silent)

      assert v_silent == v_logged
      assert ap_silent == ap_logged
      assert dp_silent == dp_logged
      assert logs_silent == [], "silent mode must not accumulate replay logs"
      assert logs_logged != [], "normal mode still builds logs (production path unchanged)"
    end
  end

  describe "matchup aggregation" do
    test "outcomes sum to n and rates are well-formed" do
      att = Sim.Fleet.mono(:fighter_4, 6, id: 1)
      def_ = Sim.Fleet.mono(:corvette_1, 6, id: 2)

      s = Sim.Arena.matchup(att, def_, n: 40)

      assert s.n == 40
      assert s.attacker_wins + s.defender_wins + s.draws == 40
      assert s.attacker_win_rate >= 0.0 and s.attacker_win_rate <= 1.0
      assert s.pre.attacker.ships == 6
    end

    test "a parallel matchup matches a serial one (CRN determinism across schedulers)" do
      att = Sim.Fleet.mono(:fighter_4, 6, id: 1)
      def_ = Sim.Fleet.mono(:corvette_1, 6, id: 2)

      par = Sim.Arena.matchup(att, def_, n: 30, parallel: true)
      ser = Sim.Arena.matchup(att, def_, n: 30, parallel: false)

      assert par.attacker_wins == ser.attacker_wins
      assert par.defender_wins == ser.defender_wins
    end
  end

  describe "cost model" do
    test "unlock cost rises with tech depth (capital > early fighter)" do
      assert Sim.Cost.unlock_cost([:capital_1]) > Sim.Cost.unlock_cost([:fighter_1])
    end

    test "a shared prerequisite is counted once" do
      one = Sim.Cost.unlock_cost([:fighter_1])
      two = Sim.Cost.unlock_cost([:fighter_1, :fighter_2])
      assert two >= one
      assert two < one + Sim.Cost.unlock_cost([:fighter_2])
    end

    test "build cost scales with fleet size" do
      one = Sim.Cost.build_cost([:corvette_1]).credit
      three = Sim.Cost.build_cost([:corvette_1, :corvette_1, :corvette_1]).credit
      assert three == one * 3
    end

    test "ship level adds 5% credit + production per level" do
      base = Sim.Cost.build_cost([{:corvette_1, 0}])
      lvl10 = Sim.Cost.build_cost([{:corvette_1, 10}])

      assert lvl10.credit == round(base.credit * 1.5)
      assert lvl10.production == round(base.production * 1.5)
      # tech/maintenance are not affected by veterancy
      assert lvl10.technology == base.technology
      assert lvl10.maintenance == base.maintenance
    end
  end

  describe "stage pools" do
    test "are strictly nested early ⊂ mid ⊂ late" do
      early = MapSet.new(Sim.Setup.stage_ship_keys(:early))
      mid = MapSet.new(Sim.Setup.stage_ship_keys(:mid))
      late = MapSet.new(Sim.Setup.stage_ship_keys(:late))

      assert MapSet.subset?(early, mid)
      assert MapSet.subset?(mid, late)
      refute MapSet.equal?(early, late)
    end

    test "early pool caps fighters and corvettes at 4x" do
      by_key = Map.new(Sim.Setup.ships(), fn s -> {s.key, s} end)

      Enum.each(Sim.Setup.stage_ship_keys(:early), fn key ->
        ship = Map.fetch!(by_key, key)

        case ship.class do
          :fighter -> assert ship.unit_count <= 4
          :corvette -> assert ship.unit_count <= 4
          other -> flunk("unexpected class #{other} in early pool: #{key}")
        end
      end)
    end
  end

  describe "genome encoding" do
    test "every random genome decodes to a legal, stage-valid fleet (clamping)" do
      :rand.seed(:exrop, {11, 22, 33})
      max_lvl = Sim.Genome.max_build_level()

      for stage <- [:early, :mid, :late] do
        allowed = MapSet.new(Sim.Setup.stage_ship_keys(stage))

        for _ <- 1..200 do
          slots = Sim.Genome.decode(Sim.Genome.random(), stage)
          tiles = Enum.map(slots, fn {t, _k, _l} -> t end)

          assert length(slots) <= Sim.Genome.slots()
          assert tiles == Enum.uniq(tiles)
          assert Enum.all?(tiles, fn t -> t >= 1 and t <= Sim.Genome.slots() end)

          Enum.each(slots, fn {_t, key, level} ->
            assert MapSet.member?(allowed, key), "#{key} not allowed in #{stage}"
            assert level >= 0 and level <= max_lvl
          end)
        end
      end
    end

    test "levels are uniform within each ship class (a system builds a class at one level)" do
      :rand.seed(:exrop, {4, 5, 6})
      by_key = Sim.Setup.ship_index()

      for _ <- 1..50 do
        Sim.Genome.decode(Sim.Genome.random(), :late)
        |> Enum.group_by(fn {_t, key, _l} -> by_key[key].class end, fn {_t, _k, l} -> l end)
        |> Enum.each(fn {_class, levels} -> assert length(Enum.uniq(levels)) == 1 end)
      end
    end

    test "a decoded genome builds into a runnable fleet" do
      :rand.seed(:exrop, {1, 2, 3})
      att = Sim.Fleet.from_genome(Sim.Genome.random(), :late, id: 1)
      def_ = Sim.Fleet.mono(:corvette_1, 6, id: 2)

      assert Sim.Arena.battle(att, def_, 1).victory in [:left, :right, :draw]
    end
  end

  describe "balance overrides (sim-only)" do
    test "stat overrides apply to all stack variants of a base type, leaving others untouched" do
      on_exit(fn -> Sim.Setup.install() end)

      Sim.Setup.install([speed: :fast, mode: :prod], %{corvette_1: %{unit_raid_coef: 0.0, unit_shield: 35}})
      idx = Sim.Setup.ship_index()

      for variant <- [:corvette_1, :corvette_1v2, :corvette_1v3] do
        assert idx[variant].unit_raid_coef == 0.0
        assert idx[variant].unit_shield == 35
      end

      assert idx[:corvette_2].unit_raid_coef > 0.0
    end
  end
end

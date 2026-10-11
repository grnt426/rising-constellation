defmodule Wave.PressureTest do
  use ExUnit.Case, async: true

  alias Wave.Pressure

  @fade 240.0

  describe "stacks" do
    test "every order adds its weight, and a stack wears off per fade" do
      entry = nil |> Pressure.add(1.0, 0.0, @fade) |> Pressure.add(1.0, 0.0, @fade) |> Pressure.add(0.5, 0.0, @fade)

      assert Pressure.stacks(entry, 0.0, @fade) == 2.5
      assert Pressure.stacks(entry, 240.0, @fade) == 1.5
      assert Pressure.stacks(entry, 480.0, @fade) == 0.5
      # Never below nothing, however long it is left alone.
      assert Pressure.stacks(entry, 5_000.0, @fade) == 0.0
    end

    test "an order on a half-rested system builds on what is left, not on what it once held" do
      entry = nil |> Pressure.add(2.0, 0.0, @fade) |> Pressure.add(1.0, 360.0, @fade)

      assert Pressure.stacks(entry, 360.0, @fade) == 1.5
    end

    test "a system nobody has touched holds nothing" do
      assert Pressure.stacks(nil, 100.0, @fade) == 0.0
      assert Pressure.stacks(%{}, 100.0, @fade) == 0.0
    end

    test "worn-off entries are pruned from the ledger" do
      ledger = %{1 => Pressure.add(nil, 1.0, 0.0, @fade), 2 => Pressure.add(nil, 3.0, 0.0, @fade)}

      assert ledger |> Pressure.prune(300.0, @fade) |> Map.keys() == [2]
    end
  end

  describe "weights" do
    test "the strikes an owner feels count whole, an infiltration half, anything else nothing" do
      assert Pressure.weight("encourage_hate") == 1.0
      assert Pressure.weight("conversion") == 1.0
      assert Pressure.weight("assassination") == 1.0
      assert Pressure.weight("sabotage") == 1.0
      assert Pressure.weight("infiltrate") == 0.5
      assert Pressure.weight("make_dominion") == 0.0
      assert Pressure.weight("roam") == 0.0
    end

    test "the knob overrides a weight, and 0 switches an action off" do
      assert Pressure.weight("infiltrate", %{"infiltrate" => 1}) == 1.0
      assert Pressure.weight("sabotage", %{"sabotage" => 0}) == 0.0
      assert Pressure.weight("conversion", %{"infiltrate" => 1}) == 1.0
    end
  end

  describe "the debuff" do
    test "stacks: each order on the same system makes it count for less" do
      assert Pressure.debuff(0.0, 0.7) == 1.0
      assert_in_delta Pressure.debuff(1.0, 0.7), 0.7, 1.0e-9
      assert_in_delta Pressure.debuff(2.0, 0.7), 0.49, 1.0e-9
      assert_in_delta Pressure.debuff(4.0, 0.7), 0.2401, 1.0e-9
      # A falloff of 1 switches it off.
      assert Pressure.debuff(4.0, 1.0) == 1.0
    end

    test "a system at the cap is closed; no cap never closes" do
      assert Pressure.open?(4.9, 5.0)
      refute Pressure.open?(5.0, 5.0)
      assert Pressure.open?(50.0, nil)
    end
  end

  describe "admission" do
    # system id => stacks
    @held %{1 => 0.0, 2 => 1.0, 3 => 3.0, 4 => 6.0}

    defp admitted(roll), do: Pressure.admit([1, 2, 3, 4], &Map.fetch!(@held, &1), roll, 0.7, 5.0)

    test "a rested system is always considered, and the most pressed drop out first" do
      # 0.7^1 = 0.7, 0.7^3 = 0.343
      assert admitted(0.0) == [1, 2, 3]
      assert admitted(0.3) == [1, 2, 3]
      assert admitted(0.5) == [1, 2]
      assert admitted(0.9) == [1]
    end

    test "a system at the cap is out whatever the roll" do
      refute 4 in admitted(0.0)
    end
  end
end

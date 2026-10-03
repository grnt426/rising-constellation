defmodule Wave.SiderianTest do
  use ExUnit.Case, async: true

  alias Wave.Siderian

  # The speaker table from Data.Game.Content.Character: proselyte 0, agitator
  # 1, seducer 2, then the three that feed no Siderian action.
  defp speaker_specs do
    [
      %{
        key: :proselyte,
        index: 0,
        bonus: [%Core.Bonus{from: :direct, value: 10, type: :add, to: :speaker_make_dominion}]
      },
      %{
        key: :agitator,
        index: 1,
        bonus: [%Core.Bonus{from: :direct, value: 14, type: :add, to: :speaker_encourage_hate}]
      },
      %{key: :seducer, index: 2, bonus: [%Core.Bonus{from: :direct, value: 13, type: :add, to: :speaker_conversion}]},
      %{key: :leader, index: 3, bonus: [%Core.Bonus{from: :direct, value: 6, type: :add, to: :sys_happiness}]},
      %{key: :scholar, index: 4, bonus: []},
      %{key: :philosopher, index: 5, bonus: []}
    ]
  end

  @weights %{capture: 40, destab: 30, seduce: 30}

  describe "roles" do
    test "each role's strength is the bonus its own skill grants" do
      skills = [1, 7, 3, 0, 0, 0]

      assert Siderian.strength(skills, speaker_specs(), :capture) == 10
      assert Siderian.strength(skills, speaker_specs(), :destab) == 98
      assert Siderian.strength(skills, speaker_specs(), :seduce) == 39
      # A convert with no trade has no strength anywhere.
      assert Siderian.strength(skills, speaker_specs(), nil) == 0
    end

    test "a convert's role is rolled only among the trades it has points in" do
      agitator_only = [0, 2, 0, 3, 0, 0]
      assert Siderian.role(0.0, @weights, agitator_only) == :destab
      assert Siderian.role(0.99, @weights, agitator_only) == :destab

      leader_only = [0, 0, 0, 5, 0, 0]
      assert Siderian.role(0.5, @weights, leader_only) == nil
    end

    test "the roll is weighted by points: a strong seducer is mostly a seducer" do
      skills = [1, 0, 6, 0, 0, 0]
      # capture 40 × 2 = 80, seduce 30 × 7 = 210.
      assert Siderian.role(0.2, @weights, skills) == :capture
      assert Siderian.role(0.5, @weights, skills) == :seduce
    end
  end

  describe "quotas" do
    test "with nothing to capture the whole ceiling goes to the other trades" do
      assert Siderian.quotas(9, @weights, 0) == %{capture: 0, destab: 5, seduce: 4}
    end

    test "capture takes its share only up to the targets there are, and the quotas add up to the ceiling" do
      assert Siderian.quotas(9, @weights, 11) == %{capture: 4, destab: 3, seduce: 2}
      assert Siderian.quotas(9, @weights, 2) == %{capture: 2, destab: 4, seduce: 3}

      for ceiling <- 1..20, targets <- [0, 1, 5, 50] do
        quotas = Siderian.quotas(ceiling, @weights, targets)
        assert quotas |> Map.values() |> Enum.sum() == ceiling
      end
    end

    test "with no human in reach only the capped seducers are kept, and capture takes the places while it has targets" do
      # i185 on day 5: ceiling 10, ten neutrals to capture, humans ten sectors away.
      assert Siderian.quotas(10, @weights, 10, 1) == %{capture: 6, destab: 3, seduce: 1}
      # Two targets: capture can only absorb what it has targets for.
      assert Siderian.quotas(10, @weights, 2, 1) == %{capture: 2, destab: 4, seduce: 1}
      # Nothing to capture: the freed places stay empty rather than fill with trainees.
      assert Siderian.quotas(10, @weights, 0, 1) == %{capture: 0, destab: 5, seduce: 1}
      assert Siderian.quotas(10, @weights, 0, 0) == %{capture: 0, destab: 5, seduce: 0}
    end

    test "the cap only ever lowers seduction, and no cap leaves the split alone" do
      assert Siderian.quotas(10, @weights, 10, nil) == Siderian.quotas(10, @weights, 10)
      assert Siderian.quotas(10, @weights, 10, 8) == Siderian.quotas(10, @weights, 10)

      for ceiling <- 1..20, targets <- [0, 1, 5, 50], cap <- [0, 1, 3] do
        quotas = Siderian.quotas(ceiling, @weights, targets, cap)
        assert quotas.seduce <= cap
        assert quotas.capture <= targets
        assert quotas |> Map.values() |> Enum.sum() <= ceiling
      end
    end

    test "hiring goes to the role most short of its quota" do
      quotas = %{capture: 0, destab: 5, seduce: 4}

      assert Siderian.hire_order(%{}, quotas) == [:destab, :seduce]
      assert Siderian.hire_order(%{destab: 4, seduce: 1}, quotas) == [:seduce, :destab]
      assert Siderian.hire_order(%{destab: 5, seduce: 4, capture: 1}, quotas) == []
    end
  end

  describe "stability readings" do
    @decay 0.01

    test "a positive report anchors the reading; our own penalties then decay away" do
      reading = Siderian.record_destab(nil, 6.0, 15, 100.0, @decay, -30)

      assert Siderian.estimate(reading, 100.0, @decay) == -9.0
      # 500 ut later the 15 has decayed by 5.
      assert Siderian.estimate(reading, 600.0, @decay) == -4.0
      assert Siderian.estimate(nil, 600.0, @decay) == nil
    end

    test "a report of 0 only says 'at or below 0', so the ledger carries on" do
      reading =
        nil
        |> Siderian.record_destab(6.0, 15, 0.0, @decay, -30)
        |> Siderian.record_destab(0, 20, 0.0, @decay, -30)

      assert Siderian.estimate(reading, 0.0, @decay) == -29.0
    end

    test "a system driven to the floor is held: then one agitator tops it up past the margin" do
      reading =
        nil
        |> Siderian.record_destab(6.0, 20, 0.0, @decay, -30)
        |> Siderian.record_destab(0, 20, 0.0, @decay, -30)

      assert reading.held
      assert Siderian.destab_need(reading, 0.0, @decay, -30, 10, 5) == 0
      # 1,100 ut later each 20 has decayed to 9: back to -12, above -30 + 10.
      assert Siderian.destab_need(reading, 1_100.0, @decay, -30, 10, 5) == 1
      assert Siderian.destab_need(nil, 0.0, @decay, -30, 10, 5) == 5
    end

    test "above the floor and never held, a system takes the whole focus" do
      reading = Siderian.record_destab(nil, 20.0, 15, 0.0, @decay, -30)
      assert Siderian.destab_need(reading, 0.0, @decay, -30, 10, 5) == 5
    end

    test "the penalty is read off the cooldown the Siderian came back with" do
      assert Siderian.penalty_from_cooldown(120) == 0
      assert Siderian.penalty_from_cooldown(100) == 5
      assert Siderian.penalty_from_cooldown(40) == 15
      assert Siderian.penalty_from_cooldown(30) == 20
      assert Siderian.penalty_from_cooldown(0) == nil
    end
  end

  describe "targets" do
    defp target(id, opts),
      do:
        Map.merge(
          %{id: id, committed: 0, working_sector?: false, population: nil, estimate: nil, travel: 100.0},
          Map.new(opts)
        )

    test "agitators converge: the system already worked comes first" do
      order =
        [target(1, working_sector?: true, population: 90), target(2, committed: 2), target(3, estimate: -5)]
        |> Enum.sort_by(&Siderian.destab_priority/1)
        |> Enum.map(& &1.id)

      assert order == [2, 1, 3]
    end

    test "then sectors the Rebellion works, then the biggest it can see, then the unhappiest, then the nearest" do
      order =
        [
          target(1, population: 50),
          target(2, population: 90),
          target(3, working_sector?: true),
          target(4, population: 50, estimate: -10),
          target(5, population: 50, estimate: -10, travel: 20.0)
        ]
        |> Enum.sort_by(&Siderian.destab_priority/1)
        |> Enum.map(& &1.id)

      assert order == [3, 2, 5, 4, 1]
    end

    test "practice grounds: neutrals the capturers want, then the unhappiest, then the nearest" do
      order =
        [
          %{id: 1, capture_candidate?: false, estimate: -20.0, travel: 10.0},
          %{id: 2, capture_candidate?: true, estimate: nil, travel: 50.0},
          %{id: 3, capture_candidate?: true, estimate: 5.0, travel: 90.0}
        ]
        |> Enum.sort_by(&Siderian.ground_priority/1)
        |> Enum.map(& &1.id)

      assert order == [3, 2, 1]
    end

    test "practice grounds: a border sector beats everything, then the Rebellion's other sectors" do
      order =
        [
          %{id: 1, sector_class: :frontier, capture_candidate?: true, estimate: -20.0, travel: 10.0},
          %{id: 2, sector_class: :internal, capture_candidate?: true, estimate: 2.0, travel: 20.0},
          %{id: 3, sector_class: :border, capture_candidate?: false, estimate: nil, travel: 300.0},
          %{id: 4, sector_class: :border, capture_candidate?: true, estimate: nil, travel: 400.0}
        ]
        |> Enum.sort_by(&Siderian.ground_priority/1)
        |> Enum.map(& &1.id)

      assert order == [4, 3, 2, 1]
      assert Siderian.sector_rank(:border) < Siderian.sector_rank(:internal)
      assert Siderian.sector_rank(:internal) < Siderian.sector_rank(:frontier)
      assert Siderian.sector_rank(:frontier) == Siderian.sector_rank(nil)
    end
  end

  describe "seduction" do
    defp hostile(opts),
      do: Map.merge(%{type: :admiral, name: "Ediya", level: 3, discovered?: nil, governor?: false}, Map.new(opts))

    test "an undercover Erased cannot be seduced; a governor or a discovered one can" do
      refute Siderian.seducible?(hostile(type: :spy, discovered?: false))
      assert Siderian.seducible?(hostile(type: :spy, discovered?: true))
      assert Siderian.seducible?(hostile(type: :spy, governor?: true))
      assert Siderian.seducible?(hostile(type: :speaker))
    end

    test "a level-1 stand-in commander is left alone" do
      refute Siderian.seducible?(hostile(name: "CMO #12", level: 1))
      assert Siderian.seducible?(hostile(name: "CMO #12", level: 2))
    end

    test "the defence is determination, plus home happiness in its own faction's system" do
      assert Siderian.seduction_defence(nil, false, nil) == nil
      assert Siderian.seduction_defence(26, false, nil) == 26
      # Standing at home, the happiness term is needed and may be unknown.
      assert Siderian.seduction_defence(26, true, nil) == nil
      assert Siderian.seduction_defence(26, true, 8.0) == 34.0
      # Mass destabilization pays twice: an unhappy home lowers the defence.
      assert Siderian.seduction_defence(26, true, -13.0) == 13.0
      assert Siderian.seduction_defence(26, true, -40.0) == 0
    end
  end

  describe "evasion" do
    test "a resting Siderian keeps moving outside rebel space and rests in the backline" do
      assert Siderian.evade?(true, false)
      refute Siderian.evade?(true, true)
      refute Siderian.evade?(false, false)
    end

    test "the hop is a random neighbour, never straight back while there is another" do
      assert Siderian.evasion_hop([4, 7, 9], 7, 0.0) == 4
      assert Siderian.evasion_hop([4, 7, 9], 7, 0.99) == 9
      # A dead end: back is the only way.
      assert Siderian.evasion_hop([7], 7, 0.5) == 7
      assert Siderian.evasion_hop([], nil, 0.5) == nil
    end
  end
end

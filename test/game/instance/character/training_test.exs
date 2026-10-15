defmodule Instance.Character.TrainingTest do
  @moduledoc """
  The rules of agent training (docs/agent-training.md) on their own: how a
  course advances, what it costs, and which skill reallocations are legal.
  """
  use ExUnit.Case, async: true

  alias Instance.Character.Training

  # the Legacy values (constant-slow.ex)
  @c %{
    polytech_xp_factor: 1.0,
    university_xp_factor: 2.0,
    university_settle_time: 80,
    university_reallocation_interval: 480,
    university_max_reallocations: 5,
    university_fee_credit: 20,
    university_fee_technology: 2,
    university_fee_ideology: 2,
    training_defense_factor: 0.5
  }

  describe "host buildings" do
    test "every agent type shares the Polytech and has its own university" do
      for type <- [:admiral, :spy, :speaker] do
        assert Training.host_building(:polytech, type) == :university_open
      end

      assert Training.school_of(:university_open) == {:polytech, nil}
      assert Training.school_of(:monument_dome) == {:university, :speaker}
      # the Citadel and the Holodome seat nobody
      assert Training.school_of(:ideo_open) == nil
      assert Training.school_of(:ideo_dome) == nil
      assert Training.school_of(:infra_open) == nil

      assert Training.passive?(:polytech)
      refute Training.passive?(:university)
      assert Training.schools() == [:polytech, :university]

      assert Training.host_building(:university, :speaker) == :monument_dome
      assert Training.host_building(:university, :spy) == :counterintelligence_open
      assert Training.host_building(:university, :admiral) == :military_school_dome
    end
  end

  describe "a Polytech" do
    test "trains from the first tick, for as long as the agent stays, and costs nothing" do
      training = Training.new(:polytech, @c)

      assert Training.xp_factor(training, @c) == 1.0
      assert Training.fee(:spy, 10, training, @c) == nil
      assert Training.next_event(training, @c) == :never
      assert Training.enrolled?(training)

      assert {^training, 0, 5_000, []} = Training.advance(training, 0, 5_000, @c)
    end
  end

  describe "places" do
    test "a Polytech seats one agent whatever its level; a university one at levels 1 and 2, two at 3 and 4, three at 5" do
      for level <- 1..5, do: assert(Training.seats(:polytech, level) == 1)

      assert Enum.map(1..5, &Training.seats(:university, &1)) == [1, 1, 2, 2, 3]
    end
  end

  describe "defence" do
    test "a university student keeps 40% of its own at level 1, ten points more per level, 80% at level 5" do
      factors =
        for level <- 1..5 do
          training = Training.set_conditions(Training.new(:university, @c), %{school_level: level})
          Training.defense_factor(training, @c)
        end

      assert factors == [0.4, 0.5, 0.6, 0.7, 0.8]
    end

    test "a Polytech student keeps half, and so does a university student from before the level was known" do
      assert Training.defense_factor(Training.new(:polytech, @c), @c) == 0.5
      assert Training.defense_factor(%{school: :university, phase: :active, elapsed: 0.0, ended: nil}, @c) == 0.5
    end
  end

  describe "the conditions of the system" do
    test "are none for a new course, and for a map from before they existed" do
      assert Training.conditions(Training.new(:university, @c)) == %{
               xp_bonus: 0.0,
               time_factor: 1.0,
               cost_factor: 1.0,
               school_level: nil
             }

      old = %{school: :university, phase: :active, elapsed: 100.0, ended: nil}
      assert Training.conditions(old) == %{xp_bonus: 0.0, time_factor: 1.0, cost_factor: 1.0, school_level: nil}
      assert Training.xp_factor(old, @c) == 2.0
      assert Training.reallocation_interval(old, @c) == 480
      assert Training.fee(:spy, 10, old, @c) == {:credit, 200}
    end

    test "add their percent to the experience of every school" do
      conditions = %{xp_bonus: 15.0, time_factor: 1.0, school_level: nil}

      for school <- [:polytech] do
        assert_in_delta Training.xp_factor(Training.set_conditions(Training.new(school, @c), conditions), @c),
                        1.15,
                        1.0e-9
      end

      {active, 0, _, _} = Training.advance(Training.new(:university, @c), 0, 100, @c)
      assert_in_delta Training.xp_factor(Training.set_conditions(active, conditions), @c), 2.3, 1.0e-9

      # still nothing while settling in
      assert Training.xp_factor(Training.set_conditions(Training.new(:university, @c), conditions), @c) == 0.0
    end

    test "shorten the time a rewire takes" do
      # a Citadel of level 5: -7.5%
      training =
        Training.set_conditions(Training.new(:university, @c), %{xp_bonus: 0.0, time_factor: 0.925, school_level: 1})

      assert Training.reallocation_interval(training, @c) == 444.0
      assert Training.time_left(training, 0, @c) == 80 + 5 * 444.0

      assert {%{phase: :active, elapsed: 0.0}, 1, _xp_time, [:settled, :reallocation]} =
               Training.advance(training, 0, 80 + 444, @c)

      assert {%{phase: :graduated}, 5, _xp_time, events} = Training.advance(training, 0, 80 + 5 * 444, @c)
      assert List.last(events) == :graduated

      # settling in takes as long as ever
      assert Training.next_event(training, @c) == 80
    end

    test "keep the share of a rewire already earned when the pace changes" do
      # half of a day of course done
      {half, 0, _, _} = Training.advance(Training.new(:university, @c), 0, 80 + 240, @c)
      assert half.elapsed == 240.0

      faster = Training.set_conditions(half, %{xp_bonus: 0.0, time_factor: 0.5, school_level: 1})
      assert faster.elapsed == 120.0
      assert Training.next_event(faster, @c) == 120.0

      # and back
      assert Training.set_conditions(faster, %{xp_bonus: 0.0, time_factor: 1.0, school_level: 1}).elapsed == 240.0

      # a student that is settling in has no rewire under way
      settling = Training.new(:university, @c)
      assert Training.set_conditions(settling, %{xp_bonus: 0.0, time_factor: 0.5, school_level: 1}).elapsed == 0.0
    end
  end

  describe "a university course" do
    test "starts with a settling-in period that earns nothing" do
      training = Training.new(:university, @c)

      assert training.phase == :settling
      assert Training.xp_factor(training, @c) == 0.0
      assert Training.next_event(training, @c) == 80

      assert {%{phase: :settling, elapsed: 40.0}, 0, xp_time, []} = Training.advance(training, 0, 40, @c)
      assert xp_time == 0
    end

    test "then pays twice the governor's experience" do
      {training, 0, xp_time, events} = Training.advance(Training.new(:university, @c), 0, 100, @c)

      assert training.phase == :active
      assert training.elapsed == 20.0
      # only the 20 ut after settling in count
      assert xp_time == 20.0
      assert events == [:settled]
      assert Training.xp_factor(training, @c) == 2.0
      assert Training.next_event(training, @c) == 460.0
    end

    test "earns one reallocation per interval and ends at the maximum" do
      {training, reallocations, xp_time, events} =
        Training.advance(Training.new(:university, @c), 0, 80 + 5 * 480 + 1_000, @c)

      assert training.phase == :graduated
      assert training.ended == :completed
      assert reallocations == 5
      # the time after the last reallocation is not spent in class
      assert xp_time == 2_400.0
      assert events == [:settled, :reallocation, :reallocation, :reallocation, :reallocation, :reallocation, :graduated]

      refute Training.enrolled?(training)
      assert Training.xp_factor(training, @c) == 0.0
      assert Training.next_event(training, @c) == :never
      assert {^training, 5, xp_time, []} = Training.advance(training, 5, 1_000, @c)
      assert xp_time == 0
    end

    test "is the same course played tick by tick" do
      {training, reallocations, xp_time} =
        Enum.reduce(1..300, {Training.new(:university, @c), 0, 0.0}, fn _, {training, reallocations, total} ->
          {training, reallocations, xp_time, _events} = Training.advance(training, reallocations, 10, @c)
          {training, reallocations, total + xp_time}
        end)

      assert training.phase == :graduated
      assert reallocations == 5
      assert_in_delta xp_time, 2_400.0, 0.001
    end

    # Not reachable in play (an agent spends its reallocations before any new duty), kept as a floor.
    test "still ends at the maximum for an agent that entered with reallocations" do
      {training, reallocations, xp_time, _events} = Training.advance(Training.new(:university, @c), 3, 10_000, @c)

      assert training.phase == :graduated
      assert reallocations == 5
      assert xp_time == 960.0
    end

    test "charges per level of the agent and per level of its university, in the resource of the agent's type" do
      training =
        Training.set_conditions(Training.new(:university, @c), %{xp_bonus: 0.0, time_factor: 1.0, school_level: 5})

      # 2 * (level of agent + level of uni); 20 times that sum in credits
      assert Training.fee(:speaker, 10, training, @c) == {:ideology, 30}
      assert Training.fee(:admiral, 10, training, @c) == {:technology, 30}
      assert Training.fee(:spy, 10, training, @c) == {:credit, 300}

      first = Training.set_conditions(training, %{xp_bonus: 0.0, time_factor: 1.0, school_level: 1})
      assert Training.fee(:spy, 5, first, @c) == {:credit, 120}

      assert Training.fee(:spy, 10, Training.finish(training, :unpaid), @c) == nil
    end

    test "charges less in a system whose Holodomes cut the fee" do
      # Holodomes of levels 5 and 2: -15% and -3.75%
      training =
        Training.set_conditions(Training.new(:university, @c), %{cost_factor: 0.8125, school_level: 5})

      assert {:ideology, fee} = Training.fee(:speaker, 10, training, @c)
      assert_in_delta fee, 24.375, 1.0e-9
      assert {:credit, fee} = Training.fee(:spy, 10, training, @c)
      assert_in_delta fee, 243.75, 1.0e-9

      # nothing else changes with it
      assert Training.xp_factor(%{training | phase: :active}, @c) == 2.0
      assert Training.reallocation_interval(training, @c) == 480
    end

    test "stops where it stands when the owner cannot pay" do
      {training, 2, _xp_time, _events} = Training.advance(Training.new(:university, @c), 0, 80 + 2 * 480 + 100, @c)
      ended = Training.finish(training, :unpaid)

      assert ended.phase == :graduated
      assert ended.ended == :unpaid
      refute Training.penalized?(ended)
    end
  end

  describe "the time a student still has to sit" do
    test "is the rest of its course, and the longest a queued agent waits" do
      fresh = Training.new(:university, @c)
      assert Training.time_left(fresh, 0, @c) == 80 + 5 * 480

      {settling, 0, _, _} = Training.advance(fresh, 0, 30, @c)
      assert Training.time_left(settling, 0, @c) == 50 + 5 * 480

      {active, 2, _, _} = Training.advance(fresh, 0, 80 + 2 * 480 + 100, @c)
      assert Training.time_left(active, 2, @c) == 380 + 2 * 480

      {last, 4, _, _} = Training.advance(fresh, 0, 80 + 4 * 480 + 470, @c)
      assert_in_delta Training.time_left(last, 4, @c), 10, 1.0e-6

      assert Training.time_left(Training.finish(active, :unpaid), 2, @c) == 0.0
    end

    test "has no end at a Polytech" do
      assert Training.time_left(Training.new(:polytech, @c), 0, @c) == nil
    end
  end

  describe "reallocation" do
    # main skill at index 0
    @skills [5, 3, 1, 0, 2, 0]

    test "moves one point per reallocation" do
      assert Training.check_reallocation(@skills, [6, 2, 1, 0, 2, 0], 0, 5, 12) == {:ok, 1}
      assert Training.check_reallocation(@skills, [8, 0, 1, 0, 2, 0], 0, 5, 12) == {:ok, 3}
      assert Training.check_reallocation(@skills, [5, 3, 0, 1, 1, 1], 0, 5, 12) == {:ok, 2}
    end

    test "adds a point outright for two reallocations" do
      assert Training.check_reallocation(@skills, [6, 3, 1, 0, 2, 0], 0, 5, 12) == {:ok, 2}
      assert Training.check_reallocation(@skills, [7, 3, 1, 0, 2, 0], 0, 5, 12) == {:ok, 4}
      assert Training.check_reallocation(@skills, [5, 3, 1, 1, 2, 1], 0, 5, 12) == {:ok, 4}

      # five buy two points, never three
      assert Training.check_reallocation(@skills, [8, 3, 1, 0, 2, 0], 0, 5, 12) == {:error, :not_enough_reallocations}
      assert Training.check_reallocation(@skills, [6, 3, 1, 0, 2, 0], 0, 1, 12) == {:error, :not_enough_reallocations}
    end

    test "bills a point gained as a move whenever another skill gave one up" do
      # one moved (1) and one added (2)
      assert Training.check_reallocation(@skills, [7, 2, 1, 0, 2, 0], 0, 5, 12) == {:ok, 3}
      # two moved, one added
      assert Training.check_reallocation(@skills, [8, 2, 1, 0, 1, 0], 0, 5, 12) == {:ok, 4}
      assert Training.reallocation_cost(@skills, [8, 2, 1, 0, 1, 0]) == 4
      assert Training.reallocation_cost(@skills, @skills) == 0
    end

    test "holds an added point to the limits of a moved one" do
      assert Training.check_reallocation(@skills, [5, 6, 1, 0, 2, 0], 0, 6, 12) == {:error, :skill_over_main}

      assert Training.check_reallocation([12, 5, 0, 0, 0, 0], [13, 5, 0, 0, 0, 0], 0, 5, 12) ==
               {:error, :skill_over_maximum}

      # the main skill itself can be raised, and the others then follow it
      assert Training.check_reallocation(@skills, [6, 3, 1, 0, 2, 0], 0, 2, 12) == {:ok, 2}
    end

    test "needs a reallocation for every point" do
      assert Training.check_reallocation(@skills, [8, 0, 1, 0, 2, 0], 0, 2, 12) ==
               {:error, :not_enough_reallocations}

      assert Training.check_reallocation(@skills, @skills, 0, 5, 12) == {:error, :nothing_to_reallocate}
    end

    test "places every point taken and refuses anything but six whole, positive values" do
      assert Training.check_reallocation(@skills, [5, 2, 1, 0, 2, 0], 0, 5, 12) == {:error, :skill_points_mismatch}
      assert Training.check_reallocation(@skills, [6, 1, 1, 0, 2, 0], 0, 5, 12) == {:error, :skill_points_mismatch}
      assert Training.check_reallocation(@skills, [5, 3, 1, 0, 2], 0, 5, 12) == {:error, :invalid_skills}
      assert Training.check_reallocation(@skills, [7, 3, 1, 0, 2, -2], 0, 5, 12) == {:error, :invalid_skills}
      assert Training.check_reallocation(@skills, [5.5, 2.5, 1, 0, 2, 0], 0, 5, 12) == {:error, :invalid_skills}
      assert Training.check_reallocation(@skills, "654321", 0, 5, 12) == {:error, :invalid_skills}
    end

    test "never lifts a skill over the maximum" do
      skills = [11, 5, 0, 0, 0, 0]

      assert Training.check_reallocation(skills, [12, 4, 0, 0, 0, 0], 0, 5, 12) == {:ok, 1}
      assert Training.check_reallocation(skills, [13, 3, 0, 0, 0, 0], 0, 5, 12) == {:error, :skill_over_maximum}
    end

    test "never lifts another skill over the main one, as it ends up" do
      # 3 → 5 would pass the main skill
      assert Training.check_reallocation(@skills, [5, 6, 0, 0, 0, 0], 0, 5, 12) == {:error, :skill_over_main}
      # taking from the main skill lowers the bar for the others
      assert Training.check_reallocation(@skills, [4, 4, 1, 0, 2, 0], 0, 5, 12) == {:ok, 1}
      assert Training.check_reallocation(@skills, [3, 5, 1, 0, 2, 0], 0, 5, 12) == {:error, :skill_over_main}
    end
  end
end

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
    university_fee_credit: 50,
    university_fee_technology: 5,
    university_fee_ideology: 5
  }

  describe "host buildings" do
    test "every agent type shares the Polytech and has its own university" do
      for type <- [:admiral, :spy, :speaker] do
        assert Training.host_building(:polytech, type) == :university_open
      end

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

    test "charges per level in the resource of the agent's type, while it is in class" do
      training = Training.new(:university, @c)

      assert Training.fee(:speaker, 10, training, @c) == {:ideology, 50}
      assert Training.fee(:admiral, 10, training, @c) == {:technology, 50}
      assert Training.fee(:spy, 10, training, @c) == {:credit, 500}

      assert Training.fee(:spy, 10, Training.finish(training, :unpaid), @c) == nil
    end

    test "stops where it stands when the owner cannot pay" do
      {training, 2, _xp_time, _events} = Training.advance(Training.new(:university, @c), 0, 80 + 2 * 480 + 100, @c)
      ended = Training.finish(training, :unpaid)

      assert ended.phase == :graduated
      assert ended.ended == :unpaid
      refute Training.penalized?(ended)
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

    test "needs a reallocation for every point" do
      assert Training.check_reallocation(@skills, [8, 0, 1, 0, 2, 0], 0, 2, 12) ==
               {:error, :not_enough_reallocations}

      assert Training.check_reallocation(@skills, @skills, 0, 5, 12) == {:error, :nothing_to_reallocate}
    end

    test "keeps the total and refuses anything but six whole, positive values" do
      assert Training.check_reallocation(@skills, [6, 3, 1, 0, 2, 0], 0, 5, 12) == {:error, :skill_points_mismatch}
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

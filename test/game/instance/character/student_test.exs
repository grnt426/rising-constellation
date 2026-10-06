defmodule Instance.Character.StudentTest do
  @moduledoc """
  A `:student` character (docs/agent-training.md) at Legacy values: what it
  earns per tick in each school, when it ticks next, how it defends itself
  while in class, and how its reallocations are spent.
  """
  use ExUnit.Case, async: true

  alias Instance.Character.Character
  alias Instance.Character.Training
  alias Test.FleetScenario

  @system 100

  setup do
    instance_id = FleetScenario.unique_instance_id()
    FleetScenario.load_game_data(instance_id, speed: :slow, mode: :prod)
    # level-ups draw the skill that gains a point
    FleetScenario.spawn_fake_rand(self(), instance_id: instance_id)

    {:ok, instance_id: instance_id, constant: Data.Querier.one(Data.Game.Constant, instance_id, :main)}
  end

  defp student(instance_id, school, opts \\ []) do
    constant = Data.Querier.one(Data.Game.Constant, instance_id, :main)

    FleetScenario.build_character(
      [instance_id: instance_id, character_id: 1, faction: :tetrarchy, system: @system, status: :student] ++ opts
    )
    |> Map.merge(%{army: nil, actions: nil, action_status: nil, protection: 101, determination: 61})
    |> Map.put(:training, Training.new(school, constant))
    |> Character.recompute_bonus()
  end

  defp tick(character, elapsed), do: Character.next_tick(character, elapsed, 0)

  describe "at a Polytech" do
    test "an agent earns the governor's experience: 24 a Legacy day", %{instance_id: instance_id} do
      {change, _notifs, character} = tick(student(instance_id, :polytech), 480)

      assert_in_delta character.experience.value, 24.0, 0.001
      assert character.level > 1
      assert MapSet.member?(change, :player_update)
      assert Character.reallocations(character) == 0
    end

    test "ticks next for its next level", %{instance_id: instance_id} do
      # level 1 → 2 at 21 experience, earned at 0.05 per ut
      assert_in_delta Character.compute_next_tick_interval(student(instance_id, :polytech)), 420.0, 0.001
    end
  end

  describe "at a university" do
    test "an agent earns nothing while it settles in", %{instance_id: instance_id, constant: c} do
      character = student(instance_id, :university)
      assert Character.compute_next_tick_interval(character) == c.university_settle_time

      {_change, _notifs, character} = tick(character, c.university_settle_time - 1)

      assert character.training.phase == :settling
      assert character.experience.value == 0
    end

    test "then earns twice the governor's experience and a reallocation a day", %{instance_id: instance_id, constant: c} do
      {change, [], character} = tick(student(instance_id, :university), c.university_settle_time)
      assert character.training.phase == :active
      assert MapSet.member?(change, :system_update)

      {_change, notifs, character} = tick(character, c.university_reallocation_interval)

      assert_in_delta character.experience.value, 48.0, 0.001
      assert Character.reallocations(character) == 1
      assert Enum.any?(notifs, &(&1.key == :character_course_reallocation))
    end

    test "leaves with five reallocations and stops earning", %{instance_id: instance_id, constant: c} do
      course = c.university_settle_time + c.university_max_reallocations * c.university_reallocation_interval

      {change, notifs, character} = tick(student(instance_id, :university), course + 500)

      assert character.training.phase == :graduated
      assert character.training.ended == :completed
      assert Character.reallocations(character) == 5
      # 5 days at 48 a day; the time after the course earns nothing
      assert_in_delta character.experience.value, 240.0, 0.001
      assert Enum.any?(notifs, &(&1.key == :character_course_completed))
      assert MapSet.member?(change, :system_update)

      assert Character.compute_next_tick_interval(character) == :never

      {_change, [], later} = tick(character, 1_000)
      assert later.experience.value == character.experience.value
      assert Character.reallocations(later) == 5
    end

    test "can be ended early, with the reallocations earned so far", %{instance_id: instance_id, constant: c} do
      {_change, _notifs, character} =
        tick(student(instance_id, :university), c.university_settle_time + 2 * c.university_reallocation_interval + 10)

      assert {:ok, ended} = Character.end_course(character, :unpaid)
      assert ended.training.phase == :graduated
      assert ended.training.ended == :unpaid
      assert Character.reallocations(ended) == 2

      # nothing left to end
      assert Character.end_course(ended, :unpaid) == {:error, :not_on_a_course}
      assert Character.end_course(student(instance_id, :polytech), :unpaid) == {:error, :not_on_a_course}
    end
  end

  describe "defence" do
    test "protection and determination are halved in class", %{instance_id: instance_id} do
      for school <- [:polytech, :university] do
        character = student(instance_id, school)

        assert Character.effective_protection(character) == 50
        assert Character.effective_determination(character) == 30
        # the agent's own values are untouched
        assert character.protection == 101
      end
    end

    test "are whole again once the course is over, and for everyone else", %{instance_id: instance_id} do
      {:ok, ended} = Character.end_course(student(instance_id, :university), :unpaid)
      assert Character.effective_protection(ended) == 101
      assert Character.effective_determination(ended) == 61

      governor = %{student(instance_id, :polytech) | status: :governor}
      assert Character.effective_protection(governor) == 101
    end

    test "the system lists a student with the values an attacker meets", %{instance_id: instance_id} do
      listed = Instance.StellarSystem.Character.convert(student(instance_id, :university))

      assert listed.protection == 50
      assert listed.determination == 30
      assert listed.training.school == :university
      assert listed.reallocations == 0
    end

    test "the system's entry follows the reallocations a student earns", %{instance_id: instance_id, constant: c} do
      {_change, _notifs, character} =
        tick(student(instance_id, :university), c.university_settle_time + 2 * c.university_reallocation_interval)

      listed = Instance.StellarSystem.Character.convert(character)
      assert listed.reallocations == 2

      # a faction with full visibility sees them, a scout does not
      assert Instance.StellarSystem.Character.obfuscate(listed, 5).reallocations == 2
      assert Instance.StellarSystem.Character.obfuscate(listed, 4).reallocations == nil
    end
  end

  describe "recall" do
    test "clears the school but keeps the reallocations", %{instance_id: instance_id} do
      FleetScenario.spawn_spatial(self(), instance_id: instance_id)
      character = student(instance_id, :university) |> Map.put(:reallocations, 3)

      recalled = Character.deactivate(character)

      assert recalled.status == :in_deck
      assert recalled.training == nil
      assert Character.reallocations(recalled) == 3
    end
  end

  describe "reallocation" do
    # :strategist is the admiral's first skill
    defp graduate(instance_id, skills, reallocations) do
      student(instance_id, :polytech, skills: skills, specialization: :strategist)
      |> Map.merge(%{status: :in_deck, training: nil, reallocations: reallocations})
    end

    test "moves points and spends a reallocation for each", %{instance_id: instance_id} do
      character = graduate(instance_id, [5, 3, 1, 0, 2, 0], 5)

      assert {:ok, moved} = Character.reallocate_skills(character, [8, 3, 0, 0, 0, 0])
      assert moved.skills == [8, 3, 0, 0, 0, 0]
      assert Character.reallocations(moved) == 2
    end

    test "refuses a move without the reallocations, or past the limits", %{instance_id: instance_id} do
      character = graduate(instance_id, [5, 3, 1, 0, 2, 0], 1)

      assert Character.reallocate_skills(character, [8, 3, 0, 0, 0, 0]) == {:error, :not_enough_reallocations}
      assert Character.reallocate_skills(character, [5, 3, 1, 0, 2, 1]) == {:error, :skill_points_mismatch}

      assert Character.reallocate_skills(%{character | skills: [5, 5, 1, 0, 0, 0]}, [5, 6, 0, 0, 0, 0]) ==
               {:error, :skill_over_main}

      full = graduate(instance_id, [12, 3, 0, 0, 0, 0], 5)
      assert Character.reallocate_skills(full, [13, 2, 0, 0, 0, 0]) == {:error, :skill_over_maximum}
    end

    test "an agent that never went to university has nothing to spend", %{instance_id: instance_id} do
      character = graduate(instance_id, [5, 3, 1, 0, 2, 0], 0) |> Map.delete(:reallocations)

      assert Character.reallocations(character) == 0
      assert Character.reallocate_skills(character, [6, 2, 1, 0, 2, 0]) == {:error, :not_enough_reallocations}
    end
  end
end

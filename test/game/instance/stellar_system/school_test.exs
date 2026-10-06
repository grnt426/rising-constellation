defmodule Instance.StellarSystem.SchoolTest do
  @moduledoc """
  The schools of a system (docs/agent-training.md): slots from its
  buildings, who may enrol, and who leaves when a school shrinks or the
  system changes hands.
  """
  use ExUnit.Case, async: true

  alias Instance.Character.Training
  alias Instance.StellarSystem.School

  @c %{university_settle_time: 80, university_guest_min_level: 5}

  @owner %{id: 1, faction_id: 10}
  @mate %{id: 2, faction_id: 10}
  @enemy %{id: 3, faction_id: 20}

  defp tile(key, level, status \\ :built), do: %{building_key: key, building_level: level, building_status: status}

  # a planet with a moon: buildings on both count
  defp system(planet_tiles, moon_tiles \\ [], overrides \\ %{}) do
    Map.merge(
      %{
        status: :inhabited_player,
        owner: @owner,
        siege: nil,
        students: [],
        bodies: [%{tiles: planet_tiles, bodies: [%{tiles: moon_tiles, bodies: []}]}]
      },
      overrides
    )
  end

  defp student(id, type, school, owner, opts \\ []) do
    %{
      id: id,
      type: type,
      level: Keyword.get(opts, :level, 8),
      owner: owner,
      training: Keyword.get(opts, :training, Training.new(school, @c))
    }
  end

  defp seat(system, student), do: %{system | students: system.students ++ [student]}

  describe "capacity" do
    test "a Polytech gives one slot, whatever its level, to every agent type" do
      system = system([tile(:university_open, 4)], [tile(:university_open, 1)])

      assert School.capacity(system, :polytech, :spy) == 2
      assert School.capacity(system, :polytech, :admiral) == 2
    end

    test "a university gives one slot per level, to its own agent type" do
      system = system([tile(:monument_dome, 3), tile(:counterintelligence_open, 5)], [tile(:military_school_dome, 2)])

      assert School.capacity(system, :university, :speaker) == 3
      assert School.capacity(system, :university, :spy) == 5
      assert School.capacity(system, :university, :admiral) == 2
    end

    test "several academies in one system add up" do
      system = system([tile(:military_school_dome, 2)], [tile(:military_school_dome, 4)])

      assert School.capacity(system, :university, :admiral) == 6
    end

    test "a damaged or unfinished building seats nobody" do
      system = system([tile(:monument_dome, 3, :damaged), tile(:university_open, nil, :empty)])

      assert School.capacity(system, :university, :speaker) == 0
      assert School.capacity(system, :polytech, :speaker) == 0
    end
  end

  describe "enrolment" do
    test "needs a school of the right kind in a player's system" do
      polytech = student(1, :spy, :polytech, @owner)

      assert School.check_enrollment(system([tile(:university_open, 1)]), polytech, @c) == :ok
      assert School.check_enrollment(system([tile(:monument_dome, 5)]), polytech, @c) == {:error, :no_school}

      dominion = system([tile(:university_open, 1)], [], %{status: :inhabited_dominion})
      assert School.check_enrollment(dominion, polytech, @c) == {:error, :no_school}

      # a Monolith trains Siderians only
      erased = student(2, :spy, :university, @owner)
      assert School.check_enrollment(system([tile(:monument_dome, 5)]), erased, @c) == {:error, :no_school}
    end

    test "is refused during a siege, and to another faction" do
      school = system([tile(:university_open, 1), tile(:monument_dome, 1)])

      assert School.check_enrollment(%{school | siege: %{}}, student(1, :spy, :polytech, @owner), @c) ==
               {:error, :no_character_activation_under_siege}

      assert School.check_enrollment(school, student(1, :speaker, :university, @enemy), @c) ==
               {:error, :school_of_another_faction}
    end

    test "a Polytech takes its owner's agents only, from level 1, one per building" do
      school = system([tile(:university_open, 1)])

      assert School.check_enrollment(school, student(1, :admiral, :polytech, @owner, level: 1), @c) == :ok

      assert School.check_enrollment(school, student(1, :admiral, :polytech, @mate), @c) ==
               {:error, :school_for_owner_only}

      full = seat(school, student(1, :admiral, :polytech, @owner))
      assert School.check_enrollment(full, student(2, :spy, :polytech, @owner), @c) == {:error, :school_full}
      assert School.check_enrollment(full, student(1, :admiral, :polytech, @owner), @c) == {:error, :already_enrolled}
    end

    test "a university takes as many students as it has levels" do
      school = system([tile(:monument_dome, 2)])
      one = seat(school, student(1, :speaker, :university, @owner))
      two = seat(one, student(2, :speaker, :university, @owner))

      assert School.check_enrollment(one, student(3, :speaker, :university, @owner), @c) == :ok
      assert School.check_enrollment(two, student(3, :speaker, :university, @owner), @c) == {:error, :school_full}
    end

    test "a faction-mate's agent must be level 5, and each mate gets one seat per building" do
      school = system([tile(:monument_dome, 3)])

      assert School.check_enrollment(school, student(1, :speaker, :university, @mate, level: 5), @c) == :ok

      assert School.check_enrollment(school, student(1, :speaker, :university, @mate, level: 4), @c) ==
               {:error, :character_level_too_low}

      # the owner's own agents have no level gate
      assert School.check_enrollment(school, student(1, :speaker, :university, @owner, level: 1), @c) == :ok

      taken = seat(school, student(1, :speaker, :university, @mate))

      assert School.check_enrollment(taken, student(2, :speaker, :university, @mate), @c) ==
               {:error, :one_student_per_school}

      # another mate, and the owner, still get in
      assert School.check_enrollment(taken, student(2, :speaker, :university, %{id: 4, faction_id: 10}), @c) == :ok
      assert School.check_enrollment(taken, student(2, :speaker, :university, @owner), @c) == :ok
    end

    test "a student whose course is over holds no slot" do
      done = Training.finish(Training.new(:university, @c), :completed)
      school = seat(system([tile(:monument_dome, 1)]), student(1, :speaker, :university, @owner, training: done))

      assert School.check_enrollment(school, student(2, :speaker, :university, @owner), @c) == :ok
    end
  end

  describe "settle" do
    test "keeps everyone while the schools stand" do
      students = [student(1, :spy, :polytech, @owner), student(2, :speaker, :university, @mate)]
      system = system([tile(:university_open, 1), tile(:monument_dome, 1)])

      assert School.settle(system, students) == {students, []}
    end

    test "turns out the latest arrivals of a school that lost slots" do
      [first, second, third] = for id <- 1..3, do: student(id, :speaker, :university, @owner)
      erased = student(4, :spy, :university, @owner)

      # the Monolith fell from level 3 to 1; the Orb-INTEL is gone
      system = system([tile(:monument_dome, 1)])

      assert {[^first], evicted} = School.settle(system, [first, second, third, erased])
      assert Enum.sort_by(evicted, & &1.id) == [second, third, erased]
    end

    test "turns everyone out of a system that is no longer a player's" do
      students = [student(1, :spy, :polytech, @owner), student(2, :speaker, :university, @mate)]
      schools = [tile(:university_open, 1), tile(:monument_dome, 1)]

      assert School.settle(system(schools, [], %{status: :inhabited_dominion}), students) == {[], students}
      assert School.settle(system(schools, [], %{status: :inhabited_neutral, owner: nil}), students) == {[], students}
    end

    test "after a conquest, only the new owner's faction stays, and nobody in the Polytech" do
      polytech = student(1, :spy, :polytech, @owner)
      mate = student(2, :speaker, :university, @mate)
      schools = [tile(:university_open, 1), tile(:monument_dome, 2)]

      # taken by a faction-mate: the university student stays
      assert School.settle(system(schools, [], %{owner: @mate}), [polytech, mate]) == {[mate], [polytech]}
      # taken by the enemy
      assert School.settle(system(schools, [], %{owner: @enemy}), [polytech, mate]) == {[], [polytech, mate]}
    end

    test "leaves a student who finished its course waiting, even with the school gone" do
      done =
        student(1, :speaker, :university, @owner, training: Training.finish(Training.new(:university, @c), :completed))

      assert School.settle(system([]), [done]) == {[done], []}
    end
  end

  describe "summary" do
    test "counts slots and seats taken per school" do
      system =
        system([tile(:university_open, 1), tile(:monument_dome, 2)])
        |> seat(student(1, :spy, :polytech, @owner))
        |> seat(student(2, :speaker, :university, @owner))

      assert School.summary(system) == %{
               polytech: %{slots: 1, used: 1},
               speaker: %{slots: 2, used: 1},
               spy: %{slots: 0, used: 0},
               admiral: %{slots: 0, used: 0}
             }
    end
  end
end

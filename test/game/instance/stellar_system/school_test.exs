defmodule Instance.StellarSystem.SchoolTest do
  @moduledoc """
  The schools of a system (docs/agent-training.md): slots from its
  buildings, who may enrol or wait in line, and who leaves when a school
  shrinks or the system changes hands.
  """
  use ExUnit.Case, async: true

  alias Instance.Character.Training
  alias Instance.StellarSystem.School

  @c %{
    university_settle_time: 80,
    university_guest_min_level: 5,
    university_reallocation_interval: 480,
    university_max_reallocations: 5
  }

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
        school_queue: [],
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

  # a deck agent, as the queue sees it
  defp agent(id, type, owner, opts \\ []),
    do: %{id: id, name: "Agent #{id}", type: type, level: Keyword.get(opts, :level, 8), owner: owner}

  defp queued(id, type, school, owner, behind, called \\ false),
    do: Map.merge(agent(id, type, owner), %{school: school, behind: behind, called: called})

  defp line(system, entry), do: %{system | school_queue: system.school_queue ++ [entry]}

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

    test "a faction-mate's agent must be level 5, and the faction shares the seats" do
      school = system([tile(:monument_dome, 3)])

      assert School.check_enrollment(school, student(1, :speaker, :university, @mate, level: 5), @c) == :ok

      assert School.check_enrollment(school, student(1, :speaker, :university, @mate, level: 4), @c) ==
               {:error, :character_level_too_low}

      # the owner's own agents have no level gate
      assert School.check_enrollment(school, student(1, :speaker, :university, @owner, level: 1), @c) == :ok

      # one mate may fill every seat the owner leaves
      two =
        school
        |> seat(student(1, :speaker, :university, @mate))
        |> seat(student(2, :speaker, :university, @mate))

      assert School.check_enrollment(two, student(3, :speaker, :university, @mate), @c) == :ok

      full = seat(two, student(3, :speaker, :university, @mate))
      assert School.check_enrollment(full, student(4, :speaker, :university, @owner), @c) == {:error, :school_full}
    end

    test "a seat held for the queue is taken by nobody else" do
      school =
        system([tile(:monument_dome, 2)])
        |> seat(student(1, :speaker, :university, @owner))
        |> line(queued(5, :speaker, :university, @mate, 9, true))

      assert School.free_seats(school, :university, :speaker) == 0
      assert School.check_enrollment(school, student(6, :speaker, :university, @owner), @c) == {:error, :school_full}
      # the agent it is held for walks in
      assert School.check_enrollment(school, student(5, :speaker, :university, @mate), @c) == :ok
    end

    test "a student whose course is over holds no slot" do
      done = Training.finish(Training.new(:university, @c), :completed)
      school = seat(system([tile(:monument_dome, 1)]), student(1, :speaker, :university, @owner, training: done))

      assert School.check_enrollment(school, student(2, :speaker, :university, @owner), @c) == :ok
    end
  end

  describe "the queue" do
    test "takes one agent behind each student of a school that is full" do
      school =
        system([tile(:monument_dome, 2)])
        |> seat(student(1, :speaker, :university, @owner))
        |> seat(student(2, :speaker, :university, @mate))

      assert {:ok, entry, ahead} = School.check_queue(school, agent(5, :speaker, @mate), :university, 2, @c)
      assert entry == queued(5, :speaker, :university, @mate, 2)
      assert ahead.id == 2

      waiting = line(school, entry)

      assert School.check_queue(waiting, agent(6, :speaker, @owner), :university, 2, @c) == {:error, :queue_taken}
      assert {:ok, %{behind: 1}, _ahead} = School.check_queue(waiting, agent(6, :speaker, @owner), :university, 1, @c)
      # no student named: the first one nobody waits for
      assert {:ok, %{behind: 1}, _ahead} = School.check_queue(waiting, agent(6, :speaker, @owner), :university, nil, @c)

      both = line(waiting, queued(6, :speaker, :university, @owner, 1))
      assert School.check_queue(both, agent(7, :speaker, @owner), :university, nil, @c) == {:error, :queue_taken}
      assert School.check_queue(both, agent(5, :speaker, @mate), :university, 1, @c) == {:error, :character_queued}
    end

    test "is not for a school with a free seat, nor for a student who is not there" do
      school = seat(system([tile(:monument_dome, 2)]), student(1, :speaker, :university, @owner))

      assert School.check_queue(school, agent(5, :speaker, @mate), :university, 1, @c) ==
               {:error, :school_has_free_seat}

      full = seat(school, student(2, :speaker, :university, @owner))
      assert School.check_queue(full, agent(5, :speaker, @mate), :university, 9, @c) == {:error, :student_not_found}
      assert School.check_queue(full, agent(1, :speaker, @owner), :university, 2, @c) == {:error, :already_enrolled}
    end

    test "asks what a seat asks: no siege, the right faction, the owner at a Polytech, level 5 for a guest" do
      school =
        system([tile(:university_open, 1), tile(:monument_dome, 1)])
        |> seat(student(1, :spy, :polytech, @owner))
        |> seat(student(2, :speaker, :university, @owner))

      assert School.check_queue(%{school | siege: %{}}, agent(5, :speaker, @mate), :university, 2, @c) ==
               {:error, :no_character_activation_under_siege}

      assert School.check_queue(school, agent(5, :speaker, @enemy), :university, 2, @c) ==
               {:error, :school_of_another_faction}

      assert School.check_queue(school, agent(5, :spy, @mate), :polytech, 1, @c) == {:error, :school_for_owner_only}

      assert {:ok, %{school: :polytech, behind: 1}, _} =
               School.check_queue(school, agent(5, :admiral, @owner), :polytech, 1, @c)

      assert School.check_queue(school, agent(5, :speaker, @mate, level: 4), :university, 2, @c) ==
               {:error, :character_level_too_low}

      # a damaged building has no seat to wait for
      damaged = system([tile(:monument_dome, 1, :damaged)])
      assert School.check_queue(damaged, agent(5, :speaker, @owner), :university, 2, @c) == {:error, :no_school}
    end
  end

  describe "settle" do
    defp settled(system, leaver_id \\ nil) do
      result = School.settle(system, leaver_id)
      ids = fn list -> Enum.map(list, & &1.id) end

      %{
        students: ids.(result.students),
        evicted: Enum.sort(ids.(result.evicted)),
        queue: Enum.map(result.queue, fn e -> {e.id, e.called} end),
        cleared: Enum.sort(ids.(result.cleared)),
        called: ids.(result.called)
      }
    end

    test "keeps everyone while the schools stand" do
      system =
        system([tile(:university_open, 1), tile(:monument_dome, 1)])
        |> seat(student(1, :spy, :polytech, @owner))
        |> seat(student(2, :speaker, :university, @mate))
        |> line(queued(5, :speaker, :university, @owner, 2))

      assert settled(system) == %{students: [1, 2], evicted: [], queue: [{5, false}], cleared: [], called: []}
    end

    test "turns out the latest arrivals of a school that lost slots" do
      # the Monolith fell from level 3 to 1; the Orb-INTEL is gone
      system =
        system([tile(:monument_dome, 1)])
        |> seat(student(1, :speaker, :university, @owner))
        |> seat(student(2, :speaker, :university, @owner))
        |> seat(student(3, :speaker, :university, @owner))
        |> seat(student(4, :spy, :university, @owner))

      assert %{students: [1], evicted: [2, 3, 4]} = settled(system)
    end

    test "turns everyone out of a system that is no longer a player's" do
      schools = [tile(:university_open, 1), tile(:monument_dome, 1)]

      for overrides <- [%{status: :inhabited_dominion}, %{status: :inhabited_neutral, owner: nil}] do
        system =
          system(schools, [], overrides)
          |> seat(student(1, :spy, :polytech, @owner))
          |> seat(student(2, :speaker, :university, @mate))
          |> line(queued(5, :speaker, :university, @owner, 2))

        assert settled(system) == %{students: [], evicted: [1, 2], queue: [], cleared: [5], called: []}
      end
    end

    test "after a conquest, only the new owner's faction stays, and nobody in the Polytech" do
      schools = [tile(:university_open, 1), tile(:monument_dome, 2)]

      taken = fn owner ->
        system(schools, [], %{owner: owner})
        |> seat(student(1, :spy, :polytech, @owner))
        |> seat(student(2, :speaker, :university, @mate))
        |> seat(student(3, :speaker, :university, @owner))
        |> line(queued(5, :admiral, :polytech, @owner, 1))
        |> line(queued(6, :speaker, :university, @owner, 2))
      end

      # taken by a faction-mate: the university keeps its students and its line
      assert settled(taken.(@mate)) ==
               %{students: [2, 3], evicted: [1], queue: [{6, false}], cleared: [5], called: []}

      # taken by the enemy
      assert %{students: [], evicted: [1, 2, 3], queue: [], cleared: [5, 6]} = settled(taken.(@enemy))
    end

    test "leaves a student whose course just ended to its owner, even with the school gone" do
      done =
        student(1, :speaker, :university, @owner, training: Training.finish(Training.new(:university, @c), :completed))

      assert %{students: [1], evicted: []} = settled(seat(system([]), done))
    end

    test "holds the seat a student leaves for the agent waiting behind it" do
      # students 1 and 2 were seated, 5 waits behind 1 and 6 behind 2; 2 has just left
      system =
        system([tile(:monument_dome, 2)])
        |> seat(student(1, :speaker, :university, @owner))
        |> line(queued(5, :speaker, :university, @mate, 1))
        |> line(queued(6, :speaker, :university, @owner, 2))

      assert settled(system, 2) == %{
               students: [1],
               evicted: [],
               queue: [{5, false}, {6, true}],
               cleared: [],
               called: [6]
             }
    end

    test "gives a seat nobody waited behind to the first in line" do
      system =
        system([tile(:monument_dome, 2)])
        |> seat(student(1, :speaker, :university, @owner))
        |> line(queued(5, :speaker, :university, @mate, 1))

      assert %{queue: [{5, true}], called: [5]} = settled(system, 2)
      # and one that a new level opened
      assert %{queue: [{5, true}], called: [5]} = settled(system)
    end

    test "calls nobody twice, and nobody into a siege" do
      held =
        system([tile(:monument_dome, 2)])
        |> seat(student(1, :speaker, :university, @owner))
        |> line(queued(5, :speaker, :university, @mate, 2, true))
        |> line(queued(6, :speaker, :university, @owner, 1))

      assert %{queue: [{5, true}, {6, false}], called: []} = settled(held)

      besieged =
        system([tile(:monument_dome, 2)], [], %{siege: %{}})
        |> seat(student(1, :speaker, :university, @owner))
        |> line(queued(5, :speaker, :university, @mate, 2))

      assert %{queue: [{5, false}], called: [], cleared: []} = settled(besieged, 2)
      assert %{queue: [{5, true}], called: [5]} = settled(%{besieged | siege: nil})
    end

    test "clears the place of an agent whose seat is lost with the student ahead" do
      # the Monolith fell from level 2 to 1: student 2 is turned out, and 6 waited behind it
      shrunk =
        system([tile(:monument_dome, 1)])
        |> seat(student(1, :speaker, :university, @owner))
        |> seat(student(2, :speaker, :university, @owner))
        |> line(queued(5, :speaker, :university, @mate, 1))
        |> line(queued(6, :speaker, :university, @mate, 2))

      assert settled(shrunk) == %{students: [1], evicted: [2], queue: [{5, false}], cleared: [6], called: []}

      # demolished or damaged: nobody is seated, nobody waits, no seat is held
      gone =
        system([tile(:monument_dome, 1, :damaged)])
        |> seat(student(1, :speaker, :university, @owner))
        |> line(queued(5, :speaker, :university, @mate, 1))
        |> line(queued(6, :speaker, :university, @mate, 2, true))

      assert settled(gone) == %{students: [], evicted: [1], queue: [], cleared: [5, 6], called: []}
    end

    test "gives up a held seat the school no longer has" do
      # level 2 to 1 while a seat was held for 5: student 1 keeps the only seat
      system =
        system([tile(:monument_dome, 1)])
        |> seat(student(1, :speaker, :university, @owner))
        |> line(queued(5, :speaker, :university, @mate, 2, true))

      assert settled(system) == %{students: [1], evicted: [], queue: [], cleared: [5], called: []}
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

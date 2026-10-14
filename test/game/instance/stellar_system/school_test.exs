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
    university_min_level: 5,
    university_reallocation_interval: 480,
    university_max_reallocations: 5
  }

  @owner %{id: 1, faction_id: 10}
  @mate %{id: 2, faction_id: 10}
  @enemy %{id: 3, faction_id: 20}
  @third %{id: 4, faction_id: 10}
  @fourth %{id: 5, faction_id: 10}
  @fifth %{id: 6, faction_id: 10}

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

    test "a Citadel gives one slot, whatever its level, to every agent type, beside the Polytech's" do
      system = system([tile(:ideo_open, 5), tile(:university_open, 1)], [tile(:ideo_open, 1)])

      assert School.capacity(system, :citadel, :spy) == 2
      assert School.capacity(system, :citadel, :admiral) == 2
      assert School.capacity(system, :polytech, :spy) == 1
      # a Holodome is a school of its own
      assert School.capacity(system([tile(:ideo_dome, 5)]), :citadel, :spy) == 0
    end

    test "a Holodome gives one slot, whatever its level, to every agent type" do
      system = system([tile(:ideo_open, 1)], [tile(:ideo_dome, 4)])

      assert School.capacity(system, :holodome, :spy) == 1
      assert School.capacity(system, :holodome, :speaker) == 1
      assert School.capacity(system, :citadel, :spy) == 1
      assert School.capacity(system, :polytech, :spy) == 0

      # its owner's agents alone, from level 1
      assert School.check_enrollment(system, student(1, :admiral, :holodome, @owner, level: 1), @c) == :ok

      assert School.check_enrollment(system, student(1, :admiral, :holodome, @mate), @c) ==
               {:error, :school_for_owner_only}

      full = seat(system, student(1, :admiral, :holodome, @owner))
      assert School.check_enrollment(full, student(2, :spy, :holodome, @owner), @c) == {:error, :school_full}
      assert School.check_enrollment(full, student(2, :spy, :citadel, @owner), @c) == :ok
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

    test "a Citadel takes its owner's agents only, from level 1, one per building, like a Polytech" do
      school = system([tile(:ideo_open, 3), tile(:university_open, 1)])

      assert School.check_enrollment(school, student(1, :speaker, :citadel, @owner, level: 1), @c) == :ok

      assert School.check_enrollment(school, student(1, :speaker, :citadel, @mate), @c) ==
               {:error, :school_for_owner_only}

      # its own seat: the Polytech's student does not fill it
      taken = seat(school, student(1, :admiral, :polytech, @owner))
      assert School.check_enrollment(taken, student(2, :spy, :citadel, @owner), @c) == :ok

      full = seat(taken, student(2, :spy, :citadel, @owner))
      assert School.check_enrollment(full, student(3, :speaker, :citadel, @owner), @c) == {:error, :school_full}

      # and the queue behind it
      assert {:ok, %{school: :citadel, behind: 2}, _ahead} =
               School.check_queue(full, agent(3, :speaker, @owner), :citadel, 2, @c)

      assert School.check_queue(full, agent(3, :speaker, @mate), :citadel, 2, @c) == {:error, :school_for_owner_only}
    end

    test "a university takes as many students as it has levels" do
      school = system([tile(:monument_dome, 2)])
      one = seat(school, student(1, :speaker, :university, @owner))
      two = seat(one, student(2, :speaker, :university, @mate))

      assert School.check_enrollment(one, student(3, :speaker, :university, @third), @c) == :ok
      assert School.check_enrollment(two, student(3, :speaker, :university, @third), @c) == {:error, :school_full}
    end

    test "a university seats one agent per player and per building, the owner included" do
      school = system([tile(:monument_dome, 5)])
      owned = seat(school, student(1, :speaker, :university, @owner))
      mates = seat(school, student(1, :speaker, :university, @mate))

      # four seats are free, and none of them is for a second agent
      assert School.free_seats(owned, :university, :speaker) == 4

      assert School.check_enrollment(owned, student(2, :speaker, :university, @owner), @c) ==
               {:error, :one_agent_per_building}

      assert School.check_enrollment(mates, student(2, :speaker, :university, @mate), @c) ==
               {:error, :one_agent_per_building}

      # another player walks in, and so does the same player at another university
      assert School.check_enrollment(owned, student(2, :speaker, :university, @mate), @c) == :ok

      both = seat(system([tile(:monument_dome, 5), tile(:counterintelligence_open, 5)]), hd(owned.students))
      assert School.check_enrollment(both, student(2, :spy, :university, @owner), @c) == :ok

      # a student whose course is over holds no place
      done = Training.finish(Training.new(:university, @c), :completed)
      over = seat(school, student(1, :speaker, :university, @owner, training: done))
      assert School.check_enrollment(over, student(2, :speaker, :university, @owner), @c) == :ok
    end

    test "a second building of the same university gives a second seat" do
      # an academy on the planet and one on its moon
      school = system([tile(:military_school_dome, 3)], [tile(:military_school_dome, 1)])
      one = seat(school, student(1, :admiral, :university, @owner))
      two = seat(one, student(2, :admiral, :university, @owner))

      assert School.player_seats(school, :university, :admiral) == 2
      assert School.check_enrollment(one, student(2, :admiral, :university, @owner), @c) == :ok

      assert School.check_enrollment(two, student(3, :admiral, :university, @owner), @c) ==
               {:error, :one_agent_per_building}

      # a damaged building gives no seat
      damaged = system([tile(:military_school_dome, 3)], [tile(:military_school_dome, 1, :damaged)])
      assert School.player_seats(damaged, :university, :admiral) == 1
    end

    test "a Polytech asks no such limit of its owner" do
      school = system([tile(:university_open, 1)], [tile(:university_open, 1)])
      one = seat(school, student(1, :spy, :polytech, @owner))

      assert School.player_seats(school, :polytech, nil) == nil
      assert School.check_enrollment(one, student(2, :admiral, :polytech, @owner), @c) == :ok
    end

    test "a university takes agents of level 5 or more, the owner's included, and the faction shares the seats" do
      school = system([tile(:monument_dome, 3)])

      assert School.check_enrollment(school, student(1, :speaker, :university, @mate, level: 5), @c) == :ok

      assert School.check_enrollment(school, student(1, :speaker, :university, @mate, level: 4), @c) ==
               {:error, :character_level_too_low}

      # the owner's own agents are held to the same level
      assert School.check_enrollment(school, student(1, :speaker, :university, @owner, level: 5), @c) == :ok

      assert School.check_enrollment(school, student(1, :speaker, :university, @owner, level: 4), @c) ==
               {:error, :character_level_too_low}

      # the mates may fill every seat the owner leaves
      two =
        school
        |> seat(student(1, :speaker, :university, @mate))
        |> seat(student(2, :speaker, :university, @third))

      assert School.check_enrollment(two, student(3, :speaker, :university, @fourth), @c) == :ok

      full = seat(two, student(3, :speaker, :university, @fourth))
      assert School.check_enrollment(full, student(4, :speaker, :university, @owner), @c) == {:error, :school_full}
    end

    test "a seat held for the queue is taken by nobody else" do
      school =
        system([tile(:monument_dome, 2)])
        |> seat(student(1, :speaker, :university, @owner))
        |> line(queued(5, :speaker, :university, @mate, 9, true))

      assert School.free_seats(school, :university, :speaker) == 0
      assert School.check_enrollment(school, student(6, :speaker, :university, @third), @c) == {:error, :school_full}
      # the agent it is held for walks in: its place in line is not held against it
      assert School.check_enrollment(school, student(5, :speaker, :university, @mate), @c) == :ok

      # and no other agent of its owner takes the seat in its stead
      assert School.check_enrollment(school, student(7, :speaker, :university, @mate), @c) ==
               {:error, :one_agent_per_building}
    end

    test "an agent called to a seat is refused when its owner sits there already" do
      # in line since before the limit, behind a student who has just left
      school =
        system([tile(:monument_dome, 2)])
        |> seat(student(1, :speaker, :university, @owner))
        |> line(queued(5, :speaker, :university, @owner, 2, true))

      assert School.check_enrollment(school, student(5, :speaker, :university, @owner), @c) ==
               {:error, :one_agent_per_building}
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

      assert {:ok, entry, ahead} = School.check_queue(school, agent(5, :speaker, @third), :university, 2, @c)
      assert entry == queued(5, :speaker, :university, @third, 2)
      assert ahead.id == 2

      waiting = line(school, entry)

      assert School.check_queue(waiting, agent(6, :speaker, @fourth), :university, 2, @c) == {:error, :queue_taken}
      assert {:ok, %{behind: 1}, _ahead} = School.check_queue(waiting, agent(6, :speaker, @fourth), :university, 1, @c)
      # no student named: the first one nobody waits for
      assert {:ok, %{behind: 1}, _ahead} =
               School.check_queue(waiting, agent(6, :speaker, @fourth), :university, nil, @c)

      both = line(waiting, queued(6, :speaker, :university, @fourth, 1))
      assert School.check_queue(both, agent(7, :speaker, @fifth), :university, nil, @c) == {:error, :queue_taken}
      assert School.check_queue(both, agent(5, :speaker, @third), :university, 1, @c) == {:error, :character_queued}
    end

    test "lines up a player's next agent behind its own student, and behind nobody else's" do
      school =
        system([tile(:monument_dome, 2)])
        |> seat(student(1, :speaker, :university, @mate))
        |> seat(student(2, :speaker, :university, @owner))

      assert {:ok, %{behind: 2}, _ahead} = School.check_queue(school, agent(5, :speaker, @owner), :university, 2, @c)
      # no student named: its own, not the first of the school
      assert {:ok, %{behind: 2}, _ahead} = School.check_queue(school, agent(5, :speaker, @owner), :university, nil, @c)

      # behind another player's student it would end up with a second seat
      assert School.check_queue(school, agent(5, :speaker, @owner), :university, 1, @c) ==
               {:error, :one_agent_per_building}

      # its own student already has someone behind it
      waiting = line(school, queued(5, :speaker, :university, @owner, 2))
      assert School.check_queue(waiting, agent(6, :speaker, @owner), :university, nil, @c) == {:error, :queue_taken}
    end

    test "is open to a player seated in a school that has free seats: none of them is for its second agent" do
      school = seat(system([tile(:monument_dome, 5)]), student(1, :speaker, :university, @owner))

      assert {:ok, %{behind: 1}, _ahead} = School.check_queue(school, agent(5, :speaker, @owner), :university, 1, @c)
      # anyone else just enrols
      assert School.check_queue(school, agent(5, :speaker, @mate), :university, 1, @c) ==
               {:error, :school_has_free_seat}
    end

    test "takes one agent per seat a player may still hold" do
      school =
        system([tile(:monument_dome, 2)])
        |> seat(student(1, :speaker, :university, @owner))
        |> seat(student(2, :speaker, :university, @mate))
        |> line(queued(5, :speaker, :university, @third, 1))

      # in line for the one seat it may hold: no second agent behind another student
      assert School.check_queue(school, agent(6, :speaker, @third), :university, 2, @c) ==
               {:error, :one_agent_per_building}

      # two academies: a seat in one, in line for the other, and the next agent behind its own student
      academies =
        system([tile(:military_school_dome, 1)], [tile(:military_school_dome, 1)])
        |> seat(student(1, :admiral, :university, @owner))
        |> seat(student(2, :admiral, :university, @mate))

      assert {:ok, entry, _ahead} = School.check_queue(academies, agent(5, :admiral, @owner), :university, 2, @c)
      waiting = line(academies, entry)

      assert {:ok, %{behind: 1}, _ahead} =
               School.check_queue(waiting, agent(6, :admiral, @owner), :university, 1, @c)
    end

    test "is not for a school with a free seat, nor for a student who is not there" do
      school = seat(system([tile(:monument_dome, 2)]), student(1, :speaker, :university, @owner))

      assert School.check_queue(school, agent(5, :speaker, @mate), :university, 1, @c) ==
               {:error, :school_has_free_seat}

      full = seat(school, student(2, :speaker, :university, @owner))
      assert School.check_queue(full, agent(5, :speaker, @mate), :university, 9, @c) == {:error, :student_not_found}
      assert School.check_queue(full, agent(1, :speaker, @owner), :university, 2, @c) == {:error, :already_enrolled}
    end

    test "asks what a seat asks: no siege, the right faction, the owner at a Polytech, level 5 at a university" do
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

      assert School.check_queue(school, agent(5, :speaker, @owner, level: 4), :university, 2, @c) ==
               {:error, :character_level_too_low}

      # a Polytech asks no level of its owner's agents
      assert {:ok, _entry, _ahead} = School.check_queue(school, agent(5, :admiral, @owner, level: 1), :polytech, 1, @c)

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

    test "keeps a student seated under the level a university now asks" do
      # seated before the owner's agents were held to level 5
      system = system([tile(:monument_dome, 1)]) |> seat(student(1, :speaker, :university, @owner, level: 2))

      assert settled(system) == %{students: [1], evicted: [], queue: [], cleared: [], called: []}
    end

    test "keeps the students a player seated twice before the limit per building" do
      system =
        system([tile(:monument_dome, 3)])
        |> seat(student(1, :speaker, :university, @owner))
        |> seat(student(2, :speaker, :university, @owner))

      assert settled(system) == %{students: [1, 2], evicted: [], queue: [], cleared: [], called: []}
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

    test "nobody stays in a Citadel that changed owner, and its student leaves with its building" do
      taken =
        system([tile(:ideo_open, 1)], [], %{owner: @mate})
        |> seat(student(1, :spy, :citadel, @owner))
        |> line(queued(5, :admiral, :citadel, @owner, 1))

      assert settled(taken) == %{students: [], evicted: [1], queue: [], cleared: [5], called: []}

      gone = seat(system([tile(:ideo_open, 1, :damaged)]), student(1, :spy, :citadel, @owner))
      assert %{students: [], evicted: [1]} = settled(gone)
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
        |> line(queued(6, :speaker, :university, @third, 2))

      assert settled(system, 2) == %{
               students: [1],
               evicted: [],
               queue: [{5, false}, {6, true}],
               cleared: [],
               called: [6]
             }
    end

    test "calls nobody whose owner holds its seat: an agent behind its own student waits for that seat" do
      # 5 waits behind its owner's student 1, 6 behind a mate's student 2; student 3 has just left
      system =
        system([tile(:monument_dome, 3)])
        |> seat(student(1, :speaker, :university, @owner))
        |> seat(student(2, :speaker, :university, @mate))
        |> line(queued(5, :speaker, :university, @owner, 1))
        |> line(queued(6, :speaker, :university, @third, 2))

      assert %{queue: [{5, false}, {6, true}], called: [6]} = settled(system, 3)

      # alone in line, it leaves the free seat to whoever enrols
      alone = %{system | school_queue: Enum.take(system.school_queue, 1)}
      assert %{queue: [{5, false}], called: []} = settled(alone, 3)

      # its own student leaves: the seat is its own
      assert %{queue: [{5, true}], called: [5]} = settled(%{alone | students: tl(alone.students)}, 1)
    end

    test "calls one agent per seat its owner may still hold" do
      # two seats came free; 5 and 6 are the same player's, in line since before the limit
      system =
        system([tile(:monument_dome, 3)])
        |> seat(student(1, :speaker, :university, @owner))
        |> line(queued(5, :speaker, :university, @mate, 2))
        |> line(queued(6, :speaker, :university, @mate, 3))
        |> line(queued(7, :speaker, :university, @third, 1))

      assert %{queue: [{5, true}, {6, false}, {7, true}], called: [5, 7]} = settled(system)
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

  describe "conditions" do
    # what the bonus pipeline sums over the system's buildings
    defp trained(system, xp, time, cost \\ 0.0),
      do:
        Map.merge(system, %{training_xp: %{value: xp}, reallocation_time: %{value: time}, training_cost: %{value: cost}})

    test "are the system's training experience, its rewire time, its fee and the level of the university" do
      # Delta Polytechs of levels 5 and 2, Citadels of levels 5 and 2, Holodomes of levels 5 and 3
      system = trained(system([tile(:monument_dome, 4)]), 15.0 + 6.0, -7.5 - 3.0, -10.0 - 6.0)

      assert School.conditions(system, :university, :speaker) == %{
               xp_bonus: 21.0,
               time_factor: 0.895,
               cost_factor: 0.84,
               school_level: 4
             }

      # the same experience and pace in every school of the system
      assert School.conditions(system, :polytech, :spy) == %{
               xp_bonus: 21.0,
               time_factor: 0.895,
               cost_factor: 0.84,
               school_level: nil
             }

      assert School.conditions(system, :citadel, :spy) == %{
               xp_bonus: 21.0,
               time_factor: 0.895,
               cost_factor: 0.84,
               school_level: nil
             }

      assert School.conditions(system, :holodome, :spy) == %{
               xp_bonus: 21.0,
               time_factor: 0.895,
               cost_factor: 0.84,
               school_level: nil
             }
    end

    test "are none in a system that gives nothing, or whose snapshot predates them" do
      bare = system([tile(:monument_dome, 1)])

      assert School.conditions(bare, :university, :speaker) == %{
               xp_bonus: 0.0,
               time_factor: 1.0,
               cost_factor: 1.0,
               school_level: 1
             }

      assert School.conditions(trained(bare, 0, 0), :university, :speaker) ==
               %{xp_bonus: 0.0, time_factor: 1.0, cost_factor: 1.0, school_level: 1}
    end

    test "never take a rewire under a quarter of its time, nor a course under a quarter of its fee, nor make anything worse" do
      assert %{time_factor: 0.25, cost_factor: 0.25} =
               School.conditions(trained(system([]), 0.0, -90.0, -120.0), :polytech, :spy)

      assert %{xp_bonus: 0.0, time_factor: 1.0, cost_factor: 1.0} =
               School.conditions(trained(system([]), -5.0, 12.0, 30.0), :polytech, :spy)
    end

    test "the level of a university is its highest building's, damaged ones left out" do
      academies = system([tile(:military_school_dome, 2)], [tile(:military_school_dome, 4)])
      assert School.school_level(academies, :university, :admiral) == 4

      damaged = system([tile(:military_school_dome, 2)], [tile(:military_school_dome, 4, :damaged)])
      assert School.school_level(damaged, :university, :admiral) == 2

      assert School.school_level(academies, :university, :spy) == nil
      assert School.school_level(academies, :polytech, :admiral) == nil
    end

    test "name the students whose course runs under other conditions" do
      system = trained(system([tile(:monument_dome, 2), tile(:university_open, 1)]), 3.0, 0.0)
      conditions = School.conditions(system, :university, :speaker)

      current =
        student(1, :speaker, :university, @owner,
          training: Training.set_conditions(Training.new(:university, @c), conditions)
        )

      stale = student(2, :speaker, :university, @mate)

      done =
        student(3, :speaker, :university, @third, training: Training.finish(Training.new(:university, @c), :completed))

      resident = student(4, :spy, :polytech, @owner)

      seated = system |> seat(current) |> seat(stale) |> seat(done) |> seat(resident)

      assert [
               {%{id: 2}, ^conditions},
               {%{id: 4}, %{xp_bonus: 3.0, time_factor: 1.0, cost_factor: 1.0, school_level: nil}}
             ] =
               School.outdated(seated)

      assert School.outdated(seat(system, current)) == []
    end
  end

  describe "summary" do
    test "counts slots and seats taken per school" do
      system =
        system([tile(:university_open, 1), tile(:monument_dome, 2), tile(:ideo_open, 3)])
        |> seat(student(1, :spy, :polytech, @owner))
        |> seat(student(2, :speaker, :university, @owner))

      assert School.summary(system) == %{
               polytech: %{slots: 1, used: 1, per_player: nil},
               citadel: %{slots: 1, used: 0, per_player: nil},
               holodome: %{slots: 0, used: 0, per_player: nil},
               speaker: %{slots: 2, used: 1, per_player: 1},
               spy: %{slots: 0, used: 0, per_player: 0},
               admiral: %{slots: 0, used: 0, per_player: 0}
             }
    end
  end
end

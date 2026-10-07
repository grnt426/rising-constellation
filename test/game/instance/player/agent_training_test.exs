defmodule Player.AgentTrainingTest do
  @moduledoc """
  Agent training end to end (docs/agent-training.md), through the calls the
  client makes: a deck agent sent to a Delta Polytech or to the university
  of its type, the course itself and the way home, the skill points moved
  with the reallocations it earned, and the queue behind a seated student.

  Each test boots a full instance through the dev agent-fixture (real
  player, galaxy, system and character agents), as
  `Player.AdministrativeOperationsSiegeTest` does, at Flash speed with the
  speed cheat on top so that a whole course fits in a few seconds:

      MIX_ENV=test mix test test/game/instance/player/agent_training_test.exs
  """
  use Portal.APIConnCase, async: false

  alias Instance.Character.Character
  alias Instance.Player.Player
  alias RC.Accounts.Profile

  @moduletag timeout: 300_000
  @moduletag :dev_fixture

  @path "/api/harness/dev/agent-fixture"
  @secret "dev-fixture-test-secret"

  setup do
    prev_env = Application.get_env(:rc, :environment)
    prev_secret = Application.get_env(:rc, :bot_harness_secret)
    Application.put_env(:rc, :environment, :dev)
    Application.put_env(:rc, :bot_harness_secret, @secret)

    on_exit(fn ->
      Application.put_env(:rc, :environment, prev_env)
      Application.put_env(:rc, :bot_harness_secret, prev_secret)
    end)

    # the controller's default caller and its two hard-wired puppets
    accounts =
      Map.new(1..3, fn n ->
        {:ok, account} =
          RC.Fixtures.create_account(%{
            email: "user#{n}@abc",
            hashed_password: "some hashed_password",
            password: "some password",
            name: "fixture user #{n}",
            role: :user,
            status: :active
          })

        {n, account}
      end)

    {:ok, user1: accounts[1]}
  end

  describe "a Delta Polytech" do
    test "seats one agent of its owner, which earns experience until it is recalled",
         %{conn: conn, user1: account} do
      with_empire(conn, account, fn %{iid: iid, pid: pid, home: home} ->
        erased = hire(iid, pid, :spy)

        # no school yet
        assert {:error, :no_school} == Game.call(iid, :player, pid, {:enroll_character, erased.id, :polytech, home})
        assert erased.id in deck_ids(player_state(iid, pid))

        put_building(iid, home, :university_open, 1)

        assert :ok == Game.call(iid, :player, pid, {:enroll_character, erased.id, :polytech, home})

        # on the roster (so it holds an agent slot and draws wages), out of the deck
        player = player_state(iid, pid)
        refute erased.id in deck_ids(player)
        assert %{status: :student, training: %{school: :polytech, phase: :active}} = on_roster(player, erased.id)
        refute Player.character_available_slots?(player, :spy)

        # in the school, in plain sight, with half its protection
        assert [%{id: id, protection: protection, training: %{school: :polytech}}] = system_state(iid, home).students
        assert id == erased.id
        assert protection == trunc(erased.protection / 2)

        # nobody else fits: one slot per Polytech
        another = %{live(iid, erased.id) | id: 999_999}
        assert {:error, :school_full} == Game.call(iid, :stellar_system, home, {:enroll_student, another})

        speed_up(iid)

        wait_until("the student has earned experience", fn ->
          live(iid, erased.id).experience.value > erased.experience.value
        end)

        # no reallocations at a Polytech, however long it stays
        assert Character.reallocations(live(iid, erased.id)) == 0

        assert %Player{} = Game.call(iid, :player, pid, {:deactivate_character, erased.id})
        assert erased.id in deck_ids(player_state(iid, pid))
        assert system_state(iid, home).students == []
        wait_until("the student's agent is gone", fn -> agent_gone?(iid, erased.id) end)
      end)
    end

    test "sends its student home when it is demolished", %{conn: conn, user1: account} do
      with_empire(conn, account, fn %{iid: iid, pid: pid, home: home} ->
        erased = hire(iid, pid, :spy)
        navarch = hire(iid, pid, :admiral)
        {body_uid, tile_id} = put_building(iid, home, :university_open, 1)
        assert :ok == Game.call(iid, :player, pid, {:enroll_character, erased.id, :polytech, home})
        assert :ok == Game.call(iid, :player, pid, {:queue_character, navarch.id, :polytech, home, erased.id})

        assert %Player{} = Game.call(iid, :player, pid, {:remove_building, home, {body_uid, tile_id}})

        wait_until("the student is back in the deck", fn -> erased.id in deck_ids(player_state(iid, pid)) end)
        assert system_state(iid, home).students == []
        refute on_roster(player_state(iid, pid), erased.id)

        # the seat is gone: the agent that waited for it does not take it
        wait_until("the queued agent lost its place", fn -> queue_of(player_state(iid, pid), navarch.id) == nil end)
        assert system_state(iid, home).school_queue == []
        assert navarch.id in deck_ids(player_state(iid, pid))
        refute on_roster(player_state(iid, pid), navarch.id)
      end)
    end

    test "keeps its student during a siege", %{conn: conn, user1: account} do
      with_empire(conn, account, fn %{iid: iid, pid: pid, home: home} ->
        erased = hire(iid, pid, :spy)
        navarch = hire(iid, pid, :admiral)
        put_building(iid, home, :university_open, 1)
        assert :ok == Game.call(iid, :player, pid, {:enroll_character, erased.id, :polytech, home})
        assert :ok == Game.call(iid, :player, pid, {:queue_character, navarch.id, :polytech, home, erased.id})

        besiege(iid, home)

        # no recall, by its owner or by the owner of the system (here the same)
        for order <- [{:deactivate_character, erased.id}, {:eject_student, home, erased.id}] do
          assert {:error, :no_character_deactivation_under_siege} == Game.call(iid, :player, pid, order)
        end

        assert %{status: :student} = on_roster(player_state(iid, pid), erased.id)
        assert [%{id: id}] = system_state(iid, home).students
        assert id == erased.id

        # an agent in the line never left the deck: it can be pulled out
        assert :ok == Game.call(iid, :player, pid, {:leave_school_queue, navarch.id})
        assert queue_of(player_state(iid, pid), navarch.id) == nil
        wait_until("the line is empty", fn -> system_state(iid, home).school_queue == [] end)

        # but nobody joins a line during a siege
        assert {:error, :no_character_activation_under_siege} ==
                 Game.call(iid, :player, pid, {:queue_character, navarch.id, :polytech, home, erased.id})

        assert {:ok, _system, _logs} = Game.call(iid, :stellar_system, home, {:release_siege, 0, 0, :none})
        assert %Player{} = Game.call(iid, :player, pid, {:deactivate_character, erased.id})
        assert erased.id in deck_ids(player_state(iid, pid))
      end)
    end
  end

  describe "the queue" do
    test "seats the agent waiting behind a student as soon as that student leaves",
         %{conn: conn, user1: account} do
      with_empire(conn, account, fn %{iid: iid, pid: pid, home: home} ->
        erased = hire(iid, pid, :spy)
        navarch = hire(iid, pid, :admiral)
        put_building(iid, home, :university_open, 1)

        # a free seat is taken, not waited for
        assert {:error, :school_has_free_seat} ==
                 Game.call(iid, :player, pid, {:queue_character, navarch.id, :polytech, home, nil})

        assert :ok == Game.call(iid, :player, pid, {:enroll_character, erased.id, :polytech, home})

        assert {:error, :student_not_found} ==
                 Game.call(iid, :player, pid, {:queue_character, navarch.id, :polytech, home, 999_999})

        assert :ok == Game.call(iid, :player, pid, {:queue_character, navarch.id, :polytech, home, erased.id})

        # still in the deck, with its place written on its card; a Polytech
        # student never has to leave, so the wait has no end
        player = player_state(iid, pid)
        assert navarch.id in deck_ids(player)
        refute on_roster(player, navarch.id)
        assert queue_of(player, navarch.id) == %{system_id: home, school: :polytech, wait: nil}

        assert [%{id: id, behind: behind, called: false, school: :polytech}] = system_state(iid, home).school_queue
        assert {id, behind} == {navarch.id, erased.id}

        # it holds its agent slot, and takes no other duty
        refute Player.character_available_slots?(player, :admiral)

        for order <- [
              {:activate_character, navarch.id, :governor, home},
              {:activate_character, navarch.id, :on_board, home},
              {:enroll_character, navarch.id, :polytech, home},
              {:queue_character, navarch.id, :polytech, home, erased.id}
            ] do
          assert {:error, :character_queued} == Game.call(iid, :player, pid, order)
        end

        # nor can it be sold
        offer = %{"type" => "character_deck", "data" => %{"character_id" => navarch.id}, "price" => 20}
        assert {:error, :character_queued} == Game.call(iid, :player, pid, {:create_offer, offer})

        # one agent behind each student
        other = %{navarch | id: 999_999}

        assert {:error, :queue_taken} ==
                 Game.call(iid, :stellar_system, home, {:join_school_queue, other, :polytech, erased.id})

        # the student leaves: the seat is the queued agent's at once
        assert %Player{} = Game.call(iid, :player, pid, {:deactivate_character, erased.id})

        wait_until("the queued agent is seated", fn ->
          match?(%{status: :student, training: %{school: :polytech}}, on_roster(player_state(iid, pid), navarch.id))
        end)

        refute navarch.id in deck_ids(player_state(iid, pid))
        assert [%{id: seated}] = system_state(iid, home).students
        assert seated == navarch.id
        assert system_state(iid, home).school_queue == []
      end)
    end

    test "is left by an agent that is dismissed, and emptied by the owner of the system",
         %{conn: conn, user1: account} do
      with_empire(conn, account, fn %{iid: iid, pid: pid, home: home} ->
        erased = hire(iid, pid, :spy)
        navarch = hire(iid, pid, :admiral)
        put_building(iid, home, :university_open, 1)
        assert :ok == Game.call(iid, :player, pid, {:enroll_character, erased.id, :polytech, home})
        assert :ok == Game.call(iid, :player, pid, {:queue_character, navarch.id, :polytech, home, erased.id})

        # only the owner of the system turns agents out
        assert {:error, :not_system_owner} ==
                 Game.call(iid, :stellar_system, home, {:eject_student, navarch.id, 999_999})

        assert {:error, :student_not_found} == Game.call(iid, :player, pid, {:eject_student, home, 999_999})

        # an agent waiting: it loses its place and stays in the deck
        assert :ok == Game.call(iid, :player, pid, {:eject_student, home, navarch.id})
        wait_until("the queued agent lost its place", fn -> queue_of(player_state(iid, pid), navarch.id) == nil end)
        assert system_state(iid, home).school_queue == []
        assert navarch.id in deck_ids(player_state(iid, pid))

        # back in line, then dismissed: the place is free for someone else
        assert :ok == Game.call(iid, :player, pid, {:queue_character, navarch.id, :polytech, home, erased.id})
        assert %Player{} = Game.call(iid, :player, pid, {:dismiss_character, navarch.id})
        refute navarch.id in deck_ids(player_state(iid, pid))
        wait_until("the line is empty", fn -> system_state(iid, home).school_queue == [] end)

        # a seated student: home it goes
        assert :ok == Game.call(iid, :player, pid, {:eject_student, home, erased.id})
        wait_until("the student is back in the deck", fn -> erased.id in deck_ids(player_state(iid, pid)) end)
        assert system_state(iid, home).students == []
        refute on_roster(player_state(iid, pid), erased.id)
      end)
    end

    test "tells how long the student ahead still has to sit", %{conn: conn, user1: account} do
      with_empire(conn, account, fn %{iid: iid, pid: pid, home: home} ->
        erased = hire(iid, pid, :spy)
        put_building(iid, home, :counterintelligence_open, 1)
        assert :ok == Game.call(iid, :player, pid, {:enroll_character, erased.id, :university, home})

        constant = Data.Querier.one(Data.Game.Constant, iid, :main)

        course =
          constant.university_settle_time +
            constant.university_max_reallocations * constant.university_reallocation_interval

        # a faction-mate's Erased (the player's own second one would need a second slot)
        mate = %{live(iid, erased.id) | id: 999_999, level: constant.university_guest_min_level}

        assert {:ok, wait} = Game.call(iid, :stellar_system, home, {:join_school_queue, mate, :university, erased.id})
        assert wait > 0 and wait <= course
      end)
    end
  end

  describe "a university" do
    test "runs a paid course that ends with five reallocations, spent after the recall",
         %{conn: conn, user1: account} do
      with_empire(conn, account, fn %{iid: iid, pid: pid, home: home} ->
        erased = hire(iid, pid, :spy)
        put_building(iid, home, :counterintelligence_open, 1)

        assert :ok == Game.call(iid, :player, pid, {:enroll_character, erased.id, :university, home})

        # the Orb-INTEL trains Erased only
        siderian = %{live(iid, erased.id) | id: 999_999, type: :speaker}
        assert {:error, :no_school} == Game.call(iid, :stellar_system, home, {:enroll_student, siderian})

        # the fee is in the income from the first tick, settling in included
        player = player_state(iid, pid)
        assert %{status: :student, training: %{school: :university}} = on_roster(player, erased.id)
        constant = Data.Querier.one(Data.Game.Constant, iid, :main)
        fee = constant.university_fee_credit * erased.level

        assert Enum.any?(Player.extract_bonus(player, [:player]), fn entry ->
                 entry.reason == {:character_tuition, erased.name} and entry.bonus.value == -fee
               end)

        # a seat per level: the Orb-INTEL is full
        assert Instance.StellarSystem.School.summary(system_state(iid, home)).spy == %{slots: 1, used: 1}

        # the reallocations can only be spent from the deck
        assert {:error, :character_not_in_deck} ==
                 Game.call(iid, :player, pid, {:reallocate_skills, erased.id, erased.skills})

        speed_up(iid)

        # the fifth reallocation ends the course and brings the agent home
        # by itself: nobody recalls it
        wait_until(
          "the course is over and the agent home",
          fn -> erased.id in deck_ids(player_state(iid, pid)) end,
          600
        )

        recalled = in_deck(player_state(iid, pid), erased.id)
        assert recalled.status == :in_deck
        assert recalled.training == nil
        assert Character.reallocations(recalled) == constant.university_max_reallocations
        assert recalled.experience.value > erased.experience.value

        # out of class: the seat is free, the fee is gone, the agent is gone
        refute on_roster(player_state(iid, pid), erased.id)
        assert system_state(iid, home).students == []
        assert Instance.StellarSystem.School.summary(system_state(iid, home)).spy == %{slots: 1, used: 0}
        wait_until("the student's agent is gone", fn -> agent_gone?(iid, erased.id) end)

        refute Enum.any?(
                 Player.extract_bonus(player_state(iid, pid), [:player]),
                 &match?({:character_tuition, _}, &1.reason)
               )

        # with reallocations to spend it cannot be sold
        offer = %{"type" => "character_deck", "data" => %{"character_id" => erased.id}, "price" => 20}

        wait_until("the agent has rested", fn ->
          Game.call(iid, :player, pid, {:create_offer, offer}) != {:error, :character_on_cooldown}
        end)

        assert {:error, :reallocations_unspent} == Game.call(iid, :player, pid, {:create_offer, offer})

        # nor does it take any duty, not even another course or a place in a line
        for order <- [
              {:activate_character, erased.id, :governor, home},
              {:activate_character, erased.id, :on_board, home},
              {:enroll_character, erased.id, :university, home},
              {:enroll_character, erased.id, :polytech, home},
              {:queue_character, erased.id, :polytech, home, nil}
            ] do
          assert {:error, :reallocations_unspent} == Game.call(iid, :player, pid, order)
        end

        {from, to} = movable(iid, recalled)
        skills = recalled.skills |> List.update_at(from, &(&1 - 1)) |> List.update_at(to, &(&1 + 1))

        assert :ok == Game.call(iid, :player, pid, {:reallocate_skills, erased.id, skills})
        moved = in_deck(player_state(iid, pid), erased.id)
        assert moved.skills == skills
        assert Character.reallocations(moved) == constant.university_max_reallocations - 1

        assert {:error, :skill_points_mismatch} ==
                 Game.call(iid, :player, pid, {:reallocate_skills, erased.id, List.update_at(skills, 0, &(&1 + 1))})

        # one left is still one too many
        spend(iid, pid, erased.id, constant.university_max_reallocations - 2)

        assert {:error, :reallocations_unspent} ==
                 Game.call(iid, :player, pid, {:enroll_character, erased.id, :university, home})

        # the last one can be given up instead: the skills stay, and it can
        # go back to school, as often as wanted
        before_discard = in_deck(player_state(iid, pid), erased.id)
        assert :ok == Game.call(iid, :player, pid, {:discard_reallocations, erased.id})
        discarded = in_deck(player_state(iid, pid), erased.id)
        assert Character.reallocations(discarded) == 0
        assert discarded.skills == before_discard.skills

        assert {:error, :nothing_to_discard} == Game.call(iid, :player, pid, {:discard_reallocations, erased.id})
        assert {:error, :character_not_in_deck} == Game.call(iid, :player, pid, {:discard_reallocations, 999_999})

        wait_until("the agent has rested", fn ->
          Game.call(iid, :player, pid, {:enroll_character, erased.id, :university, home}) == :ok
        end)

        assert %{status: :student, training: %{school: :university}} = on_roster(player_state(iid, pid), erased.id)
      end)
    end

    test "sends a student out of class when its owner can no longer pay", %{conn: conn, user1: account} do
      with_empire(conn, account, fn %{iid: iid, pid: pid, home: home} ->
        erased = hire(iid, pid, :spy)
        put_building(iid, home, :counterintelligence_open, 1)
        assert :ok == Game.call(iid, :player, pid, {:enroll_character, erased.id, :university, home})

        # ruin the player: the Erased fee is paid in credits
        credit = player_state(iid, pid).credit.value
        assert :ok == Game.call(iid, :player, pid, {:add_resources, -credit - 1_000, 0, 0})

        # the course stops there and the agent comes home, with what it earned
        wait_until("the student is sent home", fn -> erased.id in deck_ids(player_state(iid, pid)) end)

        player = player_state(iid, pid)
        refute on_roster(player, erased.id)
        refute Enum.any?(Player.extract_bonus(player, [:player]), &match?({:character_tuition, _}, &1.reason))
        assert system_state(iid, home).students == []
        assert in_deck(player, erased.id).training == nil
      end)
    end
  end

  # ------------------------------------------------------------- fixture

  defp with_empire(conn, account, fun) do
    body =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-harness-secret", @secret)
      |> post(
        @path,
        Jason.encode!(%{
          "email" => "user1@abc",
          "speed" => "fast",
          # the empire option slots the lexes that give one agent slot per type
          "empire" => %{"destabilize" => false},
          "grant" => %{"credit" => 5_000_000, "technology" => 1_000_000, "ideology" => 1_000_000}
        })
      )
      |> json_response(200)

    iid = body["instance_id"]

    try do
      fun.(%{
        iid: iid,
        pid: RC.Repo.get_by!(Profile, account_id: account.id).id,
        home: body["empire"]["home"]
      })
    after
      destroy(iid)
    end
  end

  # Hire an agent of `type` from the market, through the call the Agents
  # panel uses. The fixture fills every agent slot the player has (one per
  # type), so the agent on board is removed first, the way an
  # assassination removes it.
  defp hire(iid, pid, type) do
    own = Enum.find(player_state(iid, pid).characters, &(&1.type == type)) || flunk("the player has no #{type}")
    assert :ok == Game.call(iid, :player, pid, {:assassinate_character, own.id})

    {:ok, market} = Game.call(iid, :character_market, :master, :get_state)

    on_offer =
      for %{data: ranks} <- market.slots,
          %{data: slots} <- ranks,
          %{character: %{} = character} <- slots,
          do: character

    hire = Enum.find(on_offer, &(&1.type == type)) || flunk("no #{type} on the market")

    assert %Player{} = Game.call(iid, :player, pid, {:hire_character, hire.id})
    in_deck(player_state(iid, pid), hire.id)
  end

  # Put a finished building on a free tile of home's inhabited planet (the
  # help-manual fixture's dev call); returns {body_uid, tile_id}.
  defp put_building(iid, system_id, key, level) do
    planet =
      Enum.find(system_state(iid, system_id).bodies, fn body ->
        body.type == :habitable_planet and Enum.any?(body.tiles, &(&1.id == 1 and &1.building_status == :built))
      end) || flunk("no inhabited habitable planet in system #{system_id}")

    tile =
      Enum.find(planet.tiles, &(&1.id > 1 and &1.building_status == :empty and &1.construction_status == :none)) ||
        flunk("no free tile on #{planet.uid}")

    assert {:ok, _system} =
             Game.call(iid, :stellar_system, system_id, {:dev_put_building, planet.uid, tile.id, key, level, :built})

    {planet.uid, tile.id}
  end

  # A legal one-point move for this agent, as {from_index, to_index}.
  defp movable(iid, character) do
    type_data = Data.Querier.one(Data.Game.Character, iid, character.type)
    main = Enum.find_index(type_data.specializations, &(&1.key == character.specialization))

    moves =
      for from <- 0..5, to <- 0..5, from != to, Enum.at(character.skills, from) > 0 do
        skills = character.skills |> List.update_at(from, &(&1 - 1)) |> List.update_at(to, &(&1 + 1))
        {Instance.Character.Training.check_reallocation(character.skills, skills, main, 1, 12), {from, to}}
      end

    case Enum.find(moves, &match?({{:ok, 1}, _}, &1)) do
      {_, move} -> move
      nil -> flunk("no legal move for skills #{inspect(character.skills)}")
    end
  end

  # Spend `count` reallocations of a deck agent, one legal move at a time.
  defp spend(iid, pid, character_id, count) do
    for _ <- 1..count//1 do
      character = in_deck(player_state(iid, pid), character_id)
      {from, to} = movable(iid, character)
      skills = character.skills |> List.update_at(from, &(&1 - 1)) |> List.update_at(to, &(&1 + 1))
      assert :ok == Game.call(iid, :player, pid, {:reallocate_skills, character_id, skills})
    end
  end

  # A siege in the name of an agent that is in the system: a siege whose
  # besieger is not there is released on the next tick.
  defp besiege(iid, system_id) do
    besieger = List.first(system_state(iid, system_id).characters) || flunk("no agent on board in system #{system_id}")
    Game.cast(iid, :stellar_system, system_id, {:besiege, :conquest, 100_000, besieger.id})
    wait_until("the system is under siege", fn -> system_state(iid, system_id).siege != nil end)
  end

  defp queue_of(player, character_id) do
    Enum.find_value(player.character_deck, fn entry ->
      if entry.character.id == character_id, do: Player.school_queue(entry)
    end)
  end

  # Flash already runs 120 ut per three minutes; a whole course is 103 ut.
  defp speed_up(iid), do: assert({:ok, :speedup_set, _} = Instance.Manager.call(iid, {:cheat_set_speedup, 30}))

  defp live(iid, character_id) do
    {:ok, character} = Game.call(iid, :character, character_id, :get_state)
    character
  end

  defp on_roster(player, character_id), do: Enum.find(player.characters, &(&1.id == character_id))

  defp in_deck(player, character_id) do
    Enum.find_value(player.character_deck, fn %{character: c} -> if c.id == character_id, do: c end) ||
      flunk("agent #{character_id} is not in the deck")
  end

  defp deck_ids(player), do: Enum.map(player.character_deck, & &1.character.id)

  defp agent_gone?(iid, character_id),
    do: Game.get_pid({iid, :character, character_id}) == {:error, :process_not_found}

  defp player_state(iid, pid) do
    {:ok, player} = Game.call(iid, :player, pid, :get_state)
    player
  end

  defp system_state(iid, system_id) do
    {:ok, system} = Game.call(iid, :stellar_system, system_id, :get_state)
    system
  end

  defp wait_until(what, fun, attempts \\ 100) do
    cond do
      fun.() -> :ok
      attempts > 1 -> Process.sleep(50) && wait_until(what, fun, attempts - 1)
      true -> flunk("timed out waiting until #{what}")
    end
  end

  defp destroy(iid) do
    Instance.Manager.destroy(iid)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end
end

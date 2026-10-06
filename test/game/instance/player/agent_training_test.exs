defmodule Player.AgentTrainingTest do
  @moduledoc """
  Agent training end to end (docs/agent-training.md), through the calls the
  client makes: a deck agent sent to a Delta Polytech or to the university
  of its type, the course itself, the recall, and the skill points moved
  with the reallocations it earned.

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
        {body_uid, tile_id} = put_building(iid, home, :university_open, 1)
        assert :ok == Game.call(iid, :player, pid, {:enroll_character, erased.id, :polytech, home})

        assert %Player{} = Game.call(iid, :player, pid, {:remove_building, home, {body_uid, tile_id}})

        wait_until("the student is back in the deck", fn -> erased.id in deck_ids(player_state(iid, pid)) end)
        assert system_state(iid, home).students == []
        refute on_roster(player_state(iid, pid), erased.id)
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

        speed_up(iid)
        wait_until("the course is over", fn -> live(iid, erased.id).training.phase == :graduated end, 600)

        graduate = live(iid, erased.id)
        assert graduate.training.ended == :completed
        assert Character.reallocations(graduate) == constant.university_max_reallocations
        assert graduate.experience.value > erased.experience.value

        # out of class: the seat is free, the fee is gone, the defence is whole
        wait_until("the school sees the seat free", fn ->
          Instance.StellarSystem.School.summary(system_state(iid, home)).spy == %{slots: 1, used: 0}
        end)

        wait_until("the fee is gone", fn ->
          not Enum.any?(
            Player.extract_bonus(player_state(iid, pid), [:player]),
            &match?({:character_tuition, _}, &1.reason)
          )
        end)

        assert [%{protection: protection}] = system_state(iid, home).students
        assert protection == graduate.protection

        # the reallocations can only be spent from the deck
        assert {:error, :character_not_in_deck} ==
                 Game.call(iid, :player, pid, {:reallocate_skills, erased.id, graduate.skills})

        assert %Player{} = Game.call(iid, :player, pid, {:deactivate_character, erased.id})
        recalled = in_deck(player_state(iid, pid), erased.id)
        assert recalled.training == nil
        assert Character.reallocations(recalled) == constant.university_max_reallocations

        # with reallocations to spend it takes no duty, not even another course
        for order <- [
              {:activate_character, erased.id, :governor, home},
              {:activate_character, erased.id, :on_board, home},
              {:enroll_character, erased.id, :university, home},
              {:enroll_character, erased.id, :polytech, home}
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

        wait_until("the student is sent out of class", fn ->
          match?(%{phase: :graduated, ended: :unpaid}, live(iid, erased.id).training)
        end)

        # the owner's roster follows, and with it the fee leaves the income
        wait_until("the owner sees the course ended", fn ->
          match?(%{training: %{ended: :unpaid}}, on_roster(player_state(iid, pid), erased.id))
        end)

        player = player_state(iid, pid)
        refute Enum.any?(Player.extract_bonus(player, [:player]), &match?({:character_tuition, _}, &1.reason))
        assert [%{training: %{ended: :unpaid}}] = system_state(iid, home).students
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

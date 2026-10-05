defmodule Player.AdministrativeOperationsSiegeTest do
  @moduledoc """
  Liberate (`{:transform_system_to_dominion, _}`), Administer
  (`{:transform_dominion_to_system, _}`) and Abandon (`{:abandon_system, _}`)
  on a besieged system.

  The rule (decided 2026-10-05): a siege blocks none of the three. A governor
  cannot be recalled during a siege, but he leaves with a system that is
  liberated or abandoned, back to the deck.

  Liberate and Abandon used to change the system through the galaxy first and
  withdraw the governor second. During a siege the withdrawal was refused, so
  the order failed after the system had already become a dominion (or
  autonomous) on the system and galaxy agents. The player kept it in
  `stellar_systems` with a summary that never updated again: its governor
  could no longer be recalled and the order could not be retried, siege over
  or not.

  Both handlers now ask whether the governor can be withdrawn before they
  tell the galaxy, so an order that is refused leaves every agent as it was.

  Each test boots a full instance through the dev agent-fixture (real
  player, galaxy, system and character agents), as
  `Portal.DevFixtureControllerTest` does:

      MIX_ENV=test mix test test/game/instance/player/administrative_operations_siege_test.exs
  """
  use Portal.APIConnCase, async: false

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

  describe "a besieged system with a governor" do
    test "Liberate goes through and the governor returns to the deck; Administer goes through too",
         %{conn: conn, user1: account} do
      with_empire(conn, account, fn %{iid: iid, pid: pid, home: home} ->
        governor_id = deploy_governor(iid, pid, home)
        besiege(iid, pid, home)
        before = player_state(iid, pid)

        # the siege still blocks a plain recall
        assert {:error, :no_character_deactivation_under_siege} ==
                 Game.call(iid, :player, pid, {:deactivate_character, governor_id})

        assert :ok == Game.call(iid, :player, pid, {:transform_system_to_dominion, home})

        # the siege goes on, against a dominion now
        assert %{status: :inhabited_dominion, owner: %{id: ^pid}, governor: nil, siege: %{}} = system_state(iid, home)
        assert galaxy_status(iid, home) == :inhabited_dominion

        player = player_state(iid, pid)
        refute home in ids(player.stellar_systems)
        assert home in ids(player.dominions)
        assert owned(iid, pid, home).siege != nil
        assert player.transformed_system_count == before.transformed_system_count + 1
        assert player.ideology.value < before.ideology.value

        assert_governor_in_deck(iid, player, governor_id)

        # and back: a besieged dominion can be administered
        assert :ok == Game.call(iid, :player, pid, {:transform_dominion_to_system, home})

        assert %{status: :inhabited_player, owner: %{id: ^pid}, governor: nil, siege: %{}} = system_state(iid, home)
        assert galaxy_status(iid, home) == :inhabited_player

        player = player_state(iid, pid)
        assert home in ids(player.stellar_systems)
        refute home in ids(player.dominions)
        assert player.transformed_system_count == before.transformed_system_count + 2
      end)
    end

    test "Abandon goes through and the governor returns to the deck", %{conn: conn, user1: account} do
      with_empire(conn, account, fn %{iid: iid, pid: pid, home: home} ->
        governor_id = deploy_governor(iid, pid, home)
        besiege(iid, pid, home)
        before = player_state(iid, pid)

        assert :ok == Game.call(iid, :player, pid, {:abandon_system, home})

        # the siege goes on, against an autonomous system now
        assert %{status: :inhabited_neutral, owner: nil, governor: nil, siege: %{}} = system_state(iid, home)
        assert galaxy_status(iid, home) == :inhabited_neutral

        player = player_state(iid, pid)
        refute home in ids(player.stellar_systems)
        refute home in ids(player.dominions)
        assert player.ideology.value < before.ideology.value

        assert_governor_in_deck(iid, player, governor_id)
      end)
    end
  end

  describe "a governor that cannot be withdrawn" do
    # Whatever refuses the withdrawal must refuse it before the galaxy is
    # told. Here the governor's agent is gone, which nothing else in these
    # handlers checks for.
    test "Liberate and Abandon are refused and change nothing", %{conn: conn, user1: account} do
      with_empire(conn, account, fn %{iid: iid, pid: pid, home: home} ->
        governor_id = deploy_governor(iid, pid, home)
        Instance.Manager.kill_child(iid, {iid, :character, governor_id})
        wait_until("the governor's agent is gone", fn -> agent_gone?(iid, governor_id) end)
        before = snapshot(iid, pid, home)

        liberate = Game.call(iid, :player, pid, {:transform_system_to_dominion, home})
        assert snapshot(iid, pid, home) == before
        assert liberate == {:error, :character_not_found}

        abandon = Game.call(iid, :player, pid, {:abandon_system, home})
        assert snapshot(iid, pid, home) == before
        assert abandon == {:error, :character_not_found}
      end)
    end
  end

  # ------------------------------------------------------------- fixture

  # Two systems and a dominion for user1 (so `home` is not the last system),
  # hostile Navarchs parked in `home`, and enough of every resource for an
  # agent, a Liberate and an Abandon.
  defp with_empire(conn, account, fun) do
    body =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-harness-secret", @secret)
      |> post(
        @path,
        Jason.encode!(%{
          "email" => "user1@abc",
          "empire" => %{"destabilize" => false},
          "grant" => %{"credit" => 1_000_000, "technology" => 1_000_000, "ideology" => 1_000_000}
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

  # Hire an agent from the market and deploy it as governor, through the
  # player-agent calls the Agents panel uses.
  defp deploy_governor(iid, pid, system_id) do
    # The fixture fills every agent slot the player has (one per type), so
    # one is freed first, the way an assassination frees it.
    own_spy = Enum.find(player_state(iid, pid).characters, &(&1.type == :spy)) || flunk("the player has no Erased")
    assert :ok == Game.call(iid, :player, pid, {:assassinate_character, own_spy.id})

    player = player_state(iid, pid)
    {:ok, market} = Game.call(iid, :character_market, :master, :get_state)

    on_offer =
      for %{data: ranks} <- market.slots,
          %{data: slots} <- ranks,
          %{character: %{} = character} <- slots,
          do: character

    hire =
      Enum.find(on_offer, &Player.character_available_slots?(player, &1.type)) ||
        flunk("no agent on the market fits a free agent slot")

    assert %Player{} = Game.call(iid, :player, pid, {:hire_character, hire.id})
    assert %Player{} = Game.call(iid, :player, pid, {:activate_character, hire.id, :governor, system_id})
    assert %{governor: %{id: governor_id}} = system_state(iid, system_id)
    assert governor_id == hire.id

    governor_id
  end

  # The cast a Navarch's conquest sends when it starts (Conquest.start/2),
  # in the name of one of the hostile Navarchs already in the system: a
  # siege whose besieger is not there is released on the next tick.
  defp besiege(iid, pid, system_id) do
    besieger =
      Enum.find(system_state(iid, system_id).characters, &(&1.type == :admiral and &1.owner.id != pid)) ||
        flunk("no hostile Navarch in system #{system_id}")

    Game.cast(iid, :stellar_system, system_id, {:besiege, :conquest, 100_000, besieger.id})

    # the system tells its owner with a cast
    wait_until("the owner sees the siege", fn -> owned(iid, pid, system_id).siege != nil end)
  end

  # Everything a refused order must leave alone, on every agent involved.
  defp snapshot(iid, pid, system_id) do
    system = system_state(iid, system_id)
    player = player_state(iid, pid)

    %{
      system_status: system.status,
      system_owner: system.owner && system.owner.id,
      system_governor: system.governor && system.governor.id,
      galaxy_status: galaxy_status(iid, system_id),
      player_systems: Enum.sort(ids(player.stellar_systems)),
      player_dominions: Enum.sort(ids(player.dominions)),
      player_characters: Enum.sort(ids(player.characters)),
      player_deck: Enum.sort(deck_ids(player)),
      transformed_system_count: player.transformed_system_count
    }
  end

  # Recalled for good: off the roster, in the deck, and its agent stopped.
  defp assert_governor_in_deck(iid, player, governor_id) do
    assert governor_id in deck_ids(player)
    refute governor_id in ids(player.characters)
    wait_until("the governor's agent is gone", fn -> agent_gone?(iid, governor_id) end)
  end

  # The registry drops a stopped agent a moment after it stops.
  defp agent_gone?(iid, character_id),
    do: Game.get_pid({iid, :character, character_id}) == {:error, :process_not_found}

  defp ids(list), do: Enum.map(list, & &1.id)
  defp deck_ids(player), do: Enum.map(player.character_deck, & &1.character.id)

  defp owned(iid, pid, system_id) do
    player = player_state(iid, pid)
    Enum.find(player.stellar_systems ++ player.dominions, &(&1.id == system_id))
  end

  defp player_state(iid, pid) do
    {:ok, player} = Game.call(iid, :player, pid, :get_state)
    player
  end

  defp system_state(iid, system_id) do
    {:ok, system} = Game.call(iid, :stellar_system, system_id, :get_state)
    system
  end

  defp galaxy_status(iid, system_id) do
    {:ok, galaxy} = Game.call(iid, :galaxy, :master, :get_state)
    Enum.find(galaxy.stellar_systems, &(&1.id == system_id)).status
  end

  defp wait_until(what, fun, attempts \\ 40) do
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

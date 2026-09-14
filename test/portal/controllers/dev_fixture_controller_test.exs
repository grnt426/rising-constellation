defmodule Portal.DevFixtureControllerTest do
  @moduledoc """
  POST /api/harness/dev/agent-fixture: its two guards, and the `empire`
  option that grows the fixture player into two systems and a dominion
  (next to an autonomous and an uninhabited system, home destabilized)
  for the help-manual screenshots.

  The `empire` tests boot a full instance each (tag `:dev_fixture`):

      MIX_ENV=test mix test test/portal/controllers/dev_fixture_controller_test.exs
  """
  use Portal.APIConnCase, async: false

  alias RC.Accounts.Profile

  @moduletag timeout: 300_000

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

  describe "guards" do
    test "refuses outside :dev", %{conn: conn} do
      Application.put_env(:rc, :environment, :prod)

      assert %{"error" => "dev_only"} = conn |> post_fixture(%{}) |> json_response(403)
    end

    test "refuses without the harness secret", %{conn: conn} do
      assert conn |> post_fixture(%{}, nil) |> response(401)
    end
  end

  describe "empire option" do
    @describetag :dev_fixture

    test "absent: no empire block, the player keeps one system", %{conn: conn, user1: account} do
      body = conn |> post_fixture(%{"email" => "user1@abc"}) |> json_response(200)
      iid = body["instance_id"]

      try do
        assert body["empire"] == nil

        {:ok, player} = Game.call(iid, :player, profile_id(account), :get_state)
        assert length(player.stellar_systems) == 1
        assert player.dominions == []
      after
        destroy(iid)
      end
    end

    test "true: two systems, a dominion, an autonomous and an uninhabited neighbour, home destabilized",
         %{conn: conn, user1: account} do
      body = conn |> post_fixture(%{"email" => "user1@abc", "empire" => true}) |> json_response(200)
      iid = body["instance_id"]
      pid = profile_id(account)

      try do
        empire = body["empire"]
        home = body["system"]["id"]
        owned2 = empire["owned2"]
        dominion = empire["dominion"]

        assert empire["home"] == home
        ids = Enum.map(~w(home owned2 dominion autonomous uninhabited), &empire[&1])
        assert Enum.all?(ids, &is_integer/1)
        assert length(Enum.uniq(ids)) == 5

        {:ok, player} = Game.call(iid, :player, pid, :get_state)

        # limits come from slotted Lexes, not from a bypass
        assert :system_1 in player.policies
        assert :dominion_1 in player.policies
        assert :system_1 in player.doctrines and :dominion_1 in player.doctrines
        assert player.max_systems.value >= 2
        assert player.max_dominions.value >= 1
        assert empire["max_systems"] == player.max_systems.value
        assert empire["max_dominions"] == player.max_dominions.value
        assert Enum.sort(empire["lexes"]) == player.policies |> Enum.map(&Atom.to_string/1) |> Enum.sort()

        # the player's own lists
        assert Enum.sort(Enum.map(player.stellar_systems, & &1.id)) == Enum.sort([home, owned2])
        assert Enum.map(player.dominions, & &1.id) == [dominion]
        assert Enum.sort(empire["systems"]) == Enum.sort([home, owned2])
        assert empire["dominions"] == [dominion]

        # the systems themselves
        assert %{status: :inhabited_player, owner: %{id: ^pid}} = system_state(iid, owned2)
        assert %{status: :inhabited_dominion, owner: %{id: ^pid}} = system_state(iid, dominion)
        assert %{status: :inhabited_neutral, owner: nil} = system_state(iid, empire["autonomous"])
        assert %{status: :uninhabited, owner: nil} = system_state(iid, empire["uninhabited"])

        # the galaxy's summaries agree (map colours, sector ownership)
        {:ok, galaxy} = Game.call(iid, :galaxy, :master, :get_state)
        galaxy_status = fn id -> Enum.find(galaxy.stellar_systems, &(&1.id == id)).status end
        assert galaxy_status.(owned2) == :inhabited_player
        assert galaxy_status.(dominion) == :inhabited_dominion

        # both claims respected the sector rule
        for id <- [owned2, dominion] do
          assert {:ok, :takeable} ==
                   Game.call(iid, :galaxy, :master, {:check_system_takeability, id, player.faction})
        end

        # home left Normal through a Destabilization penalty
        home_state = system_state(iid, home)
        assert empire["destabilized"] == home
        assert home_state.population_status != :normal
        assert empire["population_status"] == Atom.to_string(home_state.population_status)
        assert [%{reason: :encourage_hate}] = home_state.happiness_penalties
        assert home_state.happiness.value <= 0
      after
        destroy(iid)
      end
    end

    test "destabilize: false leaves home without a penalty", %{conn: conn} do
      body =
        conn
        |> post_fixture(%{"email" => "user1@abc", "empire" => %{"destabilize" => false}})
        |> json_response(200)

      iid = body["instance_id"]

      try do
        empire = body["empire"]
        assert empire["destabilized"] == nil
        assert length(empire["systems"]) == 2
        assert length(empire["dominions"]) == 1
        assert system_state(iid, body["system"]["id"]).happiness_penalties == []
      after
        destroy(iid)
      end
    end
  end

  defp post_fixture(conn, body, secret \\ @secret) do
    conn = put_req_header(conn, "content-type", "application/json")
    conn = if secret, do: put_req_header(conn, "x-harness-secret", secret), else: conn
    post(conn, @path, Jason.encode!(body))
  end

  defp profile_id(account), do: RC.Repo.get_by!(Profile, account_id: account.id).id

  defp system_state(iid, system_id) do
    {:ok, system} = Game.call(iid, :stellar_system, system_id, :get_state)
    system
  end

  defp destroy(iid) do
    Instance.Manager.destroy(iid)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end
end

defmodule Edict.MatchTest do
  @moduledoc """
  Scripts in a real match, end to end: a script saved to an account is
  attached to a Forge scenario through the scenario API (checked against the
  map on save), a two-faction Flash match is created from the scenario, two
  players join, and the match starts. Then the real runner (`Edict.Match`,
  started by the instance Manager) runs the script once per player: the
  setup's grants reach every player, each gets their own on start, their
  own messages and their own finish. Its state survives the runner being
  stopped and started again (no second on start), and when the match is won
  the standings go to everyone.
  """
  use Portal.APIConnCase, async: false

  import RC.Fixtures
  import RC.ScenarioFixtures

  alias Portal.Controllers.GlobalChannel
  alias RC.Accounts.Profile
  alias RC.Repo

  @moduletag timeout: 180_000

  @script """
  setup {
    name = "Match test"
    description = "Three seconds to glory."
    factions = 2
    grant_patents = ["precision_cranes"]
  }

  var pulses = 0

  score pulses

  on start {
    give("credit", 12345)
    notify(str(len(factions)) + " factions in this " + scenario.mode + " match")
  }

  every 1s {
    pulses = pulses + 1
  }

  when pulses >= 3 {
    finish("done")
  }
  """

  defp account!(name, role \\ "user") do
    {:ok, account} =
      create_account(%{
        "email" => "#{name}-#{System.unique_integer([:positive])}@user",
        "name" => "#{name}#{System.unique_integer([:positive])}",
        "role" => role,
        "password" => "a long enough password",
        "hashed_password" => "x",
        "status" => "active"
      })

    account
  end

  defp profile!(account) do
    {:ok, profile} =
      Repo.insert(Profile.changeset(%Profile{}, %{avatar: "x", name: account.name, account_id: account.id}))

    profile
  end

  defp credit(iid, pid) do
    {:ok, player} = Game.call(iid, :player, pid, :get_state)
    player.credit.value
  end

  defp eventually(fun, tries \\ 60) do
    case fun.() do
      falsy when falsy in [nil, false] and tries > 0 ->
        Process.sleep(250)
        eventually(fun, tries - 1)

      result ->
        result
    end
  end

  # A two-faction Flash match from `scenario`: created, published, one
  # player per faction registered, started (its runner starts with it).
  # Subscribed to both players' channels and the global one.
  defp start_match(conn, owner, owner_conn, scenario) do
    {:ok, %{instance: instance}} =
      RC.Instances.create_instance(
        %{
          "description" => "d",
          "name" => "Scripted match",
          "opening_date" => "2010-04-17T14:00:00Z",
          "registration_type" => "pre_registration",
          "registration_status" => "open",
          "game_type" => "official",
          "public" => true,
          "start_setting" => "auto",
          "factions" => [%{"key" => "tetrarchy", "capacity" => 10}, %{"key" => "myrmezir", "capacity" => 10}]
        },
        scenario,
        owner.id
      )

    iid = instance.id
    registered = RC.Instances.get_instance_with_registration(iid)
    assert json_response(put(owner_conn, Routes.instance_path(owner_conn, :publish, iid)), 200)

    players =
      for {faction, name} <- Enum.zip(registered.factions, ["ann", "bo"]) do
        account = account!(name)
        profile = profile!(account)

        assert json_response(
                 post(login(build_conn(), account), Routes.registration_path(conn, :join, profile.id), %{
                   instance_id: iid,
                   faction_id: faction.id
                 }),
                 200
               )

        profile
      end

    for p <- players, do: Portal.Endpoint.subscribe("instance:player:#{iid}:#{p.id}")
    Portal.Endpoint.subscribe(GlobalChannel.topic(iid))

    Process.sleep(100)
    assert json_response(put(owner_conn, Routes.instance_path(owner_conn, :start, iid)), 200)
    on_exit(fn -> Instance.Manager.destroy(iid) end)
    {iid, players, instance}
  end

  # a scenario that attaches `source`, saved by `owner`
  defp scripted_scenario(owner, source) do
    {:ok, script} = RC.Scripts.create(owner.id, %{"source" => source})
    scenario = valid_scenario_fixture()
    game_data = Map.put(scenario.game_data, "scripts", RC.Scripts.attach([script.id], owner.id))
    {:ok, scenario} = RC.Scenarios.update_scenario(scenario, %{game_data: game_data})
    scenario
  end

  test "a scenario's script runs once per player in a real match, and survives a restart", %{conn: conn} do
    owner = account!("owner", "admin")
    owner_conn = login(conn, owner)
    {:ok, script} = RC.Scripts.create(owner.id, %{"source" => @script})

    # --- attach it through the scenario editor's save ---------------------------
    scenario = valid_scenario_fixture()

    body =
      owner_conn
      |> put("/api/scenarios/#{scenario.id}", %{
        scenario: %{
          game_data: Map.put(scenario.game_data, "scripts", [%{"id" => script.id, "source" => "score 666"}]),
          game_metadata: scenario.game_metadata
        }
      })
      |> json_response(200)

    assert body["game_metadata"]["scripted"] == true
    assert [%{"name" => "Match test"}] = body["game_metadata"]["scripts"]
    # the map has two factions and a Flash tree: nothing to warn about
    assert [%{"name" => "Match test", "diagnostics" => []}] = body["script_checks"]
    # the server froze the saved text, never the client's
    scenario = RC.Scenarios.get_scenario(scenario.id)
    assert [%{"source" => source}] = scenario.game_data["scripts"]
    assert source == script.source

    # --- the match ---------------------------------------------------------------------
    {iid, players, instance} = start_match(conn, owner, owner_conn, scenario)
    assert instance.game_data["edict"]["setup"]["grant_patents"] == [Edict.Catalog.patent_key("precision_cranes")]

    # the grants reached every player as they were created
    assert Instance.Mutators.match_scripted?(iid)

    for p <- players do
      {:ok, state} = Game.call(iid, :player, p.id, :get_state)
      assert :shipyard_2 in state.patents
    end

    # the runner may already have run on start: count from the starting stock
    %{player_starting_credit: start} = Data.Querier.one(Data.Game.Constant, iid, :main)

    # --- the runner, started by the Manager, runs one copy per player -------------
    for p <- players do
      assert eventually(fn -> credit(iid, p.id) >= start + 10_000 end)

      assert_receive %Phoenix.Socket.Broadcast{
                       topic: "instance:player:" <> _,
                       payload: %{scenario_message: %{text: "Match test: 2 factions in this flash match", tone: "info"}}
                     },
                     5_000
    end

    for _ <- players do
      assert_receive %Phoenix.Socket.Broadcast{
                       payload: %{scenario_message: %{text: "Match test: done. Your score: " <> _, tone: "good"}}
                     },
                     15_000
    end

    assert_receive %Phoenix.Socket.Broadcast{payload: %{scenario_status: %{kind: "match", entries: [entry]}}}, 15_000
    assert %{name: "Match test", description: "Three seconds to glory.", of: 2} = entry

    # --- its state is saved, and a restarted runner picks it up -------------------------
    saved = eventually(fn -> Edict.Match.load(iid)[:runs] end)
    assert saved |> Map.values() |> hd() |> map_size() == 2

    # (stopped, not killed: a kill mid-save would take the test's shared
    # database connection with it; the state was saved right after on start)
    :ok = Edict.Match.stop(iid)
    assert eventually(fn -> :global.whereis_name({Edict.Match, iid}) == :undefined end)

    credits = Map.new(players, &{&1.id, credit(iid, &1.id)})
    :ok = Edict.Match.start(iid)
    assert eventually(fn -> is_pid(:global.whereis_name({Edict.Match, iid})) end)
    Process.sleep(2_500)
    # no second on start: nobody got the 12,345 again
    for p <- players, do: assert(credit(iid, p.id) < credits[p.id] + 12_000)

    # --- the match is won: standings for everyone --------------------------------------
    Game.cast(iid, :victory, :master, :force_time_up)

    assert_receive %Phoenix.Socket.Broadcast{
                     topic: "instance:global:" <> _,
                     payload: %{scenario_message: %{text: "Match test, final standings: 1. " <> _}}
                   },
                   20_000

    assert eventually(fn -> Edict.Match.load(iid)[:ended] end)
  end

  @claim """
  setup {
    name = "Claim"
  }

  shared var champion = ""

  var points = 1

  score points

  when champion == "" {
    champion = player.name
    points = 100
  }

  every 3s {
    end_match("Claimed by " + champion + ".", winner: player.faction)
  }
  """

  test "a shared var lets exactly one player claim, end_match names the winner, the board ranks everyone",
       %{conn: conn} do
    owner = account!("owner", "admin")
    {iid, players, _instance} = start_match(conn, owner, login(conn, owner), scripted_scenario(owner, @claim))
    names = Map.new(players, &{&1.id, &1.name})

    # the leaderboard: one player claimed (100), the other didn't (1)
    assert_receive %Phoenix.Socket.Broadcast{
                     topic: "instance:global:" <> _,
                     payload: %{scenario_board: [%{name: "Claim", race: false, rows: [first, second]}]}
                   },
                   15_000

    assert {first.score, second.score} == {100.0, 1.0}
    assert first.name == names[first.player_id] and second.name == names[second.player_id]

    # the claimer's run ends the match, naming their faction the winner
    assert_receive %Phoenix.Socket.Broadcast{
                     topic: "instance:global:" <> _,
                     payload: %{scenario_message: %{text: "Claim: the match ends. Claimed by " <> claimer}}
                   },
                   15_000

    assert claimer == first.name <> "."

    {:ok, victory} =
      eventually(fn ->
        case Game.call(iid, :victory, :master, :get_state) do
          {:ok, %{winner: w}} = ok when w != nil -> ok
          _ -> nil
        end
      end)

    assert Atom.to_string(victory.winner) == first.faction
    assert %{victory_type: "scenario"} = eventually(fn -> RC.Repo.get_by(RC.Instances.Victory, instance_id: iid) end)

    # every run is finished, and the shared var was saved with them
    saved = eventually(fn -> if Edict.Match.load(iid)[:ended], do: Edict.Match.load(iid) end)
    assert [%{"champion" => champion}] = Map.values(saved.shared)
    assert champion == first.name
  end
end

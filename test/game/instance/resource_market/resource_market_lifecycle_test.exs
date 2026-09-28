defmodule Game.ResourceMarketLifecycleTest do
  @moduledoc """
  The galactic value index runs in every instance: a fresh start spawns its
  `Instance.ResourceMarket.Agent`, which accepts income reports,
  and an instance restored from a snapshot taken before the index existed
  (no agent in `agents_data`) gets a new one, started with the rest.

  Same publish -> register -> start -> snapshot -> destroy -> restart shape as
  Game.PlayerSnapshotLifecycleTest.
  """
  use Portal.APIConnCase, async: false

  import RC.Fixtures
  import RC.ScenarioFixtures

  alias RC.Accounts.Profile
  alias RC.Instances
  alias RC.Repo

  test "fresh instances get the market; old snapshots get one on restore", %{conn: conn} do
    %{instance: instance, account: account} = valid_instance_fixture()
    signed_in = login(conn, account)
    iid = instance.id

    assert json_response(put(signed_in, Routes.instance_path(conn, :publish, iid)), 200)

    {:ok, profile} =
      Repo.insert(Profile.changeset(%Profile{}, %{avatar: "x", name: account.name, account_id: account.id}))

    faction = hd(instance.factions)

    assert json_response(
             post(signed_in, Routes.registration_path(conn, :join, profile.id), %{
               instance_id: iid,
               faction_id: faction.id
             }),
             200
           )

    :timer.sleep(100)
    assert json_response(put(signed_in, Routes.instance_path(conn, :start, iid)), 200)
    :timer.sleep(500)

    # fresh start: the agent exists, sized to the instance's factions, and
    # accepts income reports
    assert {:ok, market} = Game.call(iid, :resource_market, :master, :get_state)
    assert market.faction_count == length(instance.factions)

    Game.cast(
      iid,
      :resource_market,
      :master,
      {:report_income, profile.id, faction.id, %{credit: 900.0, technology: 60.0, ideology: 70.0}}
    )

    assert {:ok, %{reports: reports}} = Game.call(iid, :resource_market, :master, :get_state)
    assert Map.has_key?(reports, profile.id)
    assert {:ok, %{prices: %{technology: _, ideology: _}}} = Game.call(iid, :resource_market, :master, :get_public)

    # snapshot, then strip the market out of it: a pre-index snapshot
    assert {:ok, %RC.Instances.InstanceSnapshot{name: name}} =
             Instance.Manager.call(iid, :make_snapshot, 300_000)

    {:ok, snapshot} = Util.Storage.load(name)
    assert Enum.any?(snapshot.agents_data, &match?(%{module: Instance.ResourceMarket.Agent}, &1))

    stripped = %{
      snapshot
      | agents_data: Enum.reject(snapshot.agents_data, &match?(%{module: Instance.ResourceMarket.Agent}, &1))
    }

    Util.Storage.store(stripped, name)

    {:ok, :killed} = Instance.Manager.destroy(iid)
    :timer.sleep(15_000)
    RC.Instances.update_instances_state_if_needed(true)
    assert Instances.get_instance(iid).state == "not_running"

    body = json_response(put(signed_in, Routes.instance_path(conn, :start, iid)), 200)
    assert body["message"] == "instance_restarted"
    :timer.sleep(500)

    assert {:ok, restored} = Game.call(iid, :resource_market, :master, :get_state)
    assert restored.faction_count == length(instance.factions)
    # ...and started along with every other agent
    assert %Core.GenState{tick: %Core.Tick{running?: true}} = Game.call(iid, :resource_market, :master, :get_full_state)

    {:ok, :killed} = Instance.Manager.destroy(iid)
  end
end

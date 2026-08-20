defmodule Game.PlayerSnapshotLifecycleTest do
  @moduledoc """
  End-to-end guard for the notification-replay hotfix.

  Drives a real instance through the actual snapshot -> destroy -> restore
  pipeline with a player whose client connects/disconnects, and asserts that:

    1. connected_clients tracks connect/disconnect on a live agent;
    2. a snapshot taken WHILE a client is attached comes back from restore
       with connected_clients == 0 (the fix) — the restart severed every
       socket, so the snapshot's count is stale and must not survive; and
    3. with the count honest again, an offline report is queued for replay
       and flushed on the next reconnect.

  Without the manager.ex fix, step 2 fails: the agent restores believing a
  client is still attached, push_notifs never queues anything for replay,
  and the player logs back in to an empty feed — the bug this guards.

  Mirrors the proven restore round-trip in InstanceControllerTest (same
  publish -> register -> start -> snapshot -> destroy -> restart shape, same
  15s graceful-terminate wait). Shared-sandbox (async: false) lets the
  instance's agent processes reach the DB.
  """
  use Portal.APIConnCase, async: false

  import RC.Fixtures
  import RC.ScenarioFixtures

  alias RC.Accounts.Profile
  alias RC.Instances
  alias RC.Repo

  defp connected_clients(instance_id, player_id) do
    {:ok, player} = Game.call(instance_id, :player, player_id, :get_state)
    player.connected_clients
  end

  defp pending_count(instance_id, player_id) do
    {:ok, player} = Game.call(instance_id, :player, player_id, :get_state)
    length(player.pending_notifications)
  end

  test "snapshot restore resets connected_clients; offline replay still works", %{conn: conn} do
    %{instance: instance, account: account} = valid_instance_fixture()
    signed_in = login(conn, account)

    # publish -> register a player -> start the instance
    assert json_response(put(signed_in, Routes.instance_path(conn, :publish, instance.id)), 200)

    {:ok, profile} =
      Repo.insert(Profile.changeset(%Profile{}, %{avatar: "x", name: account.name, account_id: account.id}))

    faction = hd(instance.factions)

    assert json_response(
             post(signed_in, Routes.registration_path(conn, :join, profile.id), %{
               instance_id: instance.id,
               faction_id: faction.id
             }),
             200
           )

    :timer.sleep(100)
    assert json_response(put(signed_in, Routes.instance_path(conn, :start, instance.id)), 200)
    :timer.sleep(500)

    player_id = profile.id

    # Fresh agent: no client attached yet.
    assert connected_clients(instance.id, player_id) == 0

    # A client connects — the counter goes up.
    Game.call(instance.id, :player, player_id, {:update_client_status, :connect})
    assert connected_clients(instance.id, player_id) == 1

    # Snapshot taken WHILE the client is attached, so the persisted count is 1.
    assert {:ok, %RC.Instances.InstanceSnapshot{}} =
             Instance.Manager.call(instance.id, :make_snapshot, 300_000)

    # Tear the instance down — exactly what a deploy/restart does to the sockets.
    {:ok, :killed} = Instance.Manager.destroy(instance.id)
    :timer.sleep(15_000)
    RC.Instances.update_instances_state_if_needed(true)
    assert Instances.get_instance(instance.id).state == "not_running"

    # Restore from the snapshot (a snapshot exists, so this goes through
    # create_from_snapshot, not a fresh start).
    body = json_response(put(signed_in, Routes.instance_path(conn, :start, instance.id)), 200)
    assert body["message"] == "instance_restarted"
    refute body["fresh_start"] == true
    :timer.sleep(500)

    # THE FIX: the snapshot held connected_clients == 1, but no socket survived
    # the restart, so the restored agent must come back at 0.
    assert connected_clients(instance.id, player_id) == 0

    # connect/disconnect still tracks correctly after a restore.
    Game.call(instance.id, :player, player_id, {:update_client_status, :connect})
    assert connected_clients(instance.id, player_id) == 1
    Game.call(instance.id, :player, player_id, {:update_client_status, :disconnect})
    assert connected_clients(instance.id, player_id) == 0

    # With the count honest, an offline report (keep? == true) is queued for
    # replay-on-login rather than broadcast into the void...
    notif = Notification.Notification.new(:text, :character_lvlup, true, nil, %{character: "x", level: 2}, nil)
    Game.cast(instance.id, :player, player_id, {:push_notifs, notif})
    assert pending_count(instance.id, player_id) == 1

    # ...and the next reconnect flushes the queue.
    Game.call(instance.id, :player, player_id, {:update_client_status, :connect})
    assert connected_clients(instance.id, player_id) == 1
    assert pending_count(instance.id, player_id) == 0

    {:ok, :killed} = Instance.Manager.destroy(instance.id)
  end
end

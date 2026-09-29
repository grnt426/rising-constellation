defmodule Portal.Channels.SyncProbeTest do
  @moduledoc """
  The Help → Debug report's desync probes: `get_sync_state` (global
  channel) and `get_faction` (faction channel) re-serve structs the client
  otherwise only receives on join and via broadcasts, in their join
  shapes, so the report can diff the store's copies against them.

  Boots a real persisted daily (live supervision tree) and joins its
  channels the way the client does.
  """
  use Portal.ChannelCase, async: false

  alias Portal.Controllers.{FactionChannel, GlobalChannel}

  # A live boot + graceful teardown is slow but bounded.
  @moduletag timeout: 180_000

  setup do
    {:ok, account} =
      RC.Accounts.create_account(%{
        email: "sync-probe-test@tetrarchyfalls.local",
        password: "sync-probe-test-password",
        name: "SyncProber",
        role: :user,
        status: :active
      })

    {:ok, profile} =
      RC.Accounts.create_profile(%{account_id: account.id, name: "SyncProber", avatar: "todo"})

    {:ok, %{instance_id: iid}} = Daily.Boot.boot_persisted(profile, Daily.today())
    on_exit(fn -> Instance.Manager.destroy(iid) end)

    registration = RC.Repo.get_by!(RC.Instances.Registration, profile_id: profile.id)

    {:ok, jwt, _} = RC.Guardian.encode_and_sign(account, %{})
    {:ok, socket} = connect(Portal.Socket, %{"token" => jwt})

    %{iid: iid, socket: socket, registration: registration}
  end

  test "get_sync_state re-serves time, victory and market, with a fresh clock", ctx do
    {:ok, join, socket} =
      subscribe_and_join(ctx.socket, GlobalChannel, "instance:global:#{ctx.iid}", %{
        "registration" => ctx.registration.token
      })

    ref = push(socket, "get_sync_state", %{})

    assert_reply(
      ref,
      :ok,
      %{
        global_time: time,
        global_victory: victory,
        global_character_market: market,
        global_speedup: %{multiplier: multiplier}
      },
      10_000
    )

    assert is_integer(time.now_monotonic)
    assert time.now_monotonic >= join.global_time.now_monotonic
    assert time.speed == join.global_time.speed
    assert victory.__struct__ == join.global_victory.__struct__
    assert market.__struct__ == join.global_character_market.__struct__
    assert multiplier == join.global_instance.speedup
  end

  test "get_faction re-serves the join's faction struct", ctx do
    faction_id = ctx.registration.faction_id

    {:ok, join, socket} =
      subscribe_and_join(ctx.socket, FactionChannel, "instance:faction:#{ctx.iid}:#{faction_id}", %{
        "registration" => ctx.registration.token
      })

    ref = push(socket, "get_faction", %{})
    assert_reply(ref, :ok, %{faction_faction: faction}, 10_000)

    assert faction.id == join.faction_faction.id
    assert Map.keys(faction) == Map.keys(join.faction_faction)
  end
end

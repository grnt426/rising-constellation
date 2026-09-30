defmodule Portal.Channels.PortalBuildJoinTest do
  @moduledoc """
  The `portal:user:*` join reply carries the live server's build
  (RC.Build), so every rejoin after a restart tells the client which
  server it reached without polling GET /api/version.
  """
  use Portal.ChannelCase, async: false

  import RC.Fixtures

  alias Portal.Controllers.PortalChannel
  alias RC.Repo

  test "join reply includes the build, same as GET /api/version" do
    {:ok, account} = fixture(:user) |> Ecto.Changeset.change(status: :active) |> Repo.update()
    {:ok, jwt, _} = RC.Guardian.encode_and_sign(account, %{})
    {:ok, socket} = connect(Portal.Socket, %{"token" => jwt})

    assert {:ok, %{build: build, deploy_flag: _}, _socket} =
             subscribe_and_join(socket, PortalChannel, "portal:user:*")

    assert build == RC.Build.info()
    assert %{version: version, live_since: %DateTime{}, deploying: deploying} = build
    assert is_binary(version)
    assert is_boolean(deploying)
  end
end

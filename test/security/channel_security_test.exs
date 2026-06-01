defmodule RC.Security.ChannelTest do
  @moduledoc """
  Regression test for Stage 3 #2 (HIGH): the `portal:instance:<iid>`
  channel topic used to accept any authenticated socket and stash the
  topic-supplied instance_id into `socket.assigns`. `handle_in("start", ...)`
  then trusted that assign without re-validation and force-started any
  instance an attacker named.

  Fix: `PortalChannel.join("portal:instance:" <> iid, ...)` now requires
  either admin role or `Instances.own_instance?/2`.

  Tutorial-channel and registration-token-binding tests live in
  `RC.Security.RegistrationsTest` (data-layer) — the full game-channel
  join path is integration-heavy and exercised by the Stage 4 audit.
  """
  use Portal.ChannelCase, async: false

  import RC.Fixtures
  import RC.ScenarioFixtures

  alias RC.Repo
  alias Portal.Socket
  alias Portal.Controllers.PortalChannel

  defp connected_socket(account) do
    {:ok, jwt, _} = RC.Guardian.encode_and_sign(account, %{})
    {:ok, socket} = connect(Socket, %{"token" => jwt})
    socket
  end

  defp instance_owned_by(account) do
    %{instance: instance} = instance_fixture()

    {:ok, instance} =
      Ecto.Changeset.change(instance, account_id: account.id) |> Repo.update()

    instance
  end

  describe "Stage 3 #2 — portal:instance:<iid> requires admin or instance ownership" do
    test "owner can join their own instance" do
      owner = fixture(:user) |> activate!()
      instance = instance_owned_by(owner)
      socket = connected_socket(owner)

      assert {:ok, _reply, _socket} =
               subscribe_and_join(socket, PortalChannel, "portal:instance:#{instance.id}")
    end

    test "stranger CANNOT join someone else's instance" do
      owner = fixture(:user) |> activate!()
      stranger = fixture(:user2) |> activate!()
      instance = instance_owned_by(owner)
      socket = connected_socket(stranger)

      assert {:error, %{reason: "unauthorized"}} =
               subscribe_and_join(socket, PortalChannel, "portal:instance:#{instance.id}")
    end

    test "admin CAN join any instance (admin bypass preserved)" do
      owner = fixture(:user) |> activate!()
      admin = fixture(:admin) |> activate!()
      instance = instance_owned_by(owner)
      socket = connected_socket(admin)

      assert {:ok, _reply, _socket} =
               subscribe_and_join(socket, PortalChannel, "portal:instance:#{instance.id}")
    end

    test "malformed instance_id is rejected, not crashed" do
      account = fixture(:user) |> activate!()
      socket = connected_socket(account)

      # `String.to_integer/1` used to raise here, taking down the channel
      # process. The fix uses Integer.parse/1 with strict {int, ""} match.
      assert {:error, %{reason: "unauthorized"}} =
               subscribe_and_join(socket, PortalChannel, "portal:instance:not-a-number")
    end
  end

  defp activate!(account) do
    {:ok, a} = Ecto.Changeset.change(account, status: :active) |> Repo.update()
    a
  end
end

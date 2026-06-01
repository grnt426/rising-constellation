defmodule RC.Security.AdminTest do
  @moduledoc """
  Regression tests for the Stage 6 Cluster A/B/C/E fixes:

    * A  (Portal.AdminAuth on_mount) — on_mount/4 admits active admins
      and halts non-admins / banned admins.
    * B  (Account.changeset_admin + admin-on-admin block) —
      `Accounts.admin_update_account/3` rejects peer-admin operations
      and uses the changeset that omits :password and :steam_id.
    * C  (Restricted Group.changeset) — `Group.changeset/2` no longer
      cast_assocs nested accounts/instances, so a `POST /api/groups`
      with a nested `accounts` list can't mass-insert a backdoor
      admin account.
    * E  (Snapshot safety) — `Util.Storage.load` decodes with `:safe`
      (rejects new-atom blobs); `Manager.init_from_snapshot` allow-lists
      `module` against `@snapshot_allowed_modules`; LiveView snapshot
      handlers verify `snapshot.instance_id` matches the target.
  """
  use Portal.APIConnCase, async: false

  alias Portal.AdminAuth
  alias RC.Accounts
  alias RC.Accounts.Account
  alias RC.Groups
  alias RC.Groups.Group
  alias RC.Repo
  alias Util.Storage

  defp encode_session_for(account) do
    {:ok, token, _claims} = RC.Guardian.encode_and_sign(account, %{}, token_type: "access")
    %{"guardian_default_token" => token}
  end

  defp activate(account, role) do
    {:ok, a} =
      account
      |> Ecto.Changeset.change(role: role, status: :active)
      |> Repo.update()

    a
  end

  describe "Stage 6 #A — Portal.AdminAuth.on_mount/4" do
    test "active admin is admitted" do
      account = fixture_for(:admin)
      session = encode_session_for(account)

      assert {:cont, socket} = AdminAuth.on_mount(:ensure_admin, %{}, session, %Phoenix.LiveView.Socket{})
      assert socket.assigns.current_user.id == account.id
    end

    test "non-admin user is halted" do
      account = fixture_for(:user)
      session = encode_session_for(account)

      assert {:halt, _socket} = AdminAuth.on_mount(:ensure_admin, %{}, session, %Phoenix.LiveView.Socket{})
    end

    test "banned admin is halted (even though their JWT is still cryptographically valid)" do
      account = fixture_for(:admin)
      session = encode_session_for(account)

      {:ok, _} = account |> Ecto.Changeset.change(status: :banned) |> Repo.update()

      assert {:halt, _socket} = AdminAuth.on_mount(:ensure_admin, %{}, session, %Phoenix.LiveView.Socket{})
    end

    test "missing session token is halted" do
      assert {:halt, _socket} = AdminAuth.on_mount(:ensure_admin, %{}, %{}, %Phoenix.LiveView.Socket{})
    end

    defp fixture_for(role) do
      import RC.Fixtures

      base =
        case role do
          :admin -> fixture(:admin)
          :user -> fixture(:user)
        end

      activate(base, if(role == :admin, do: :admin, else: :user))
    end
  end

  describe "Stage 6 #B — Accounts.admin_update_account/3" do
    test "admin can update a regular user's role, status, name, email" do
      admin = fixture_admin()
      user = fixture_user()

      assert {:ok, updated} =
               Accounts.admin_update_account(
                 user,
                 %{"name" => "renamed", "status" => "banned"},
                 admin
               )

      assert updated.name == "renamed"
      assert updated.status == :banned
    end

    test "admin CANNOT update a peer admin (returns :cannot_modify_peer_admin)" do
      admin_a = fixture_admin()
      admin_b = fixture_admin_other()

      assert {:error, :cannot_modify_peer_admin} =
               Accounts.admin_update_account(admin_b, %{"role" => "user"}, admin_a)

      reloaded = Accounts.get_account!(admin_b.id)
      assert reloaded.role == :admin
      assert reloaded.status == :active
    end

    test "admin CAN update their own account through this path" do
      admin = fixture_admin()

      assert {:ok, updated} =
               Accounts.admin_update_account(admin, %{"name" => "self renamed"}, admin)

      assert updated.name == "self renamed"
    end

    test "even on a non-admin target, :password is stripped (changeset_admin omits it)" do
      admin = fixture_admin()
      user = fixture_user()
      original_hash = user.hashed_password

      assert {:ok, updated} =
               Accounts.admin_update_account(
                 user,
                 %{"name" => "ok", "password" => "attacker-chosen-password"},
                 admin
               )

      assert updated.hashed_password == original_hash,
             "admin must not be able to directly write a peer's hashed_password"
    end

    test "even on a non-admin target, :steam_id is stripped" do
      admin = fixture_admin()
      user = fixture_user()

      assert {:ok, updated} =
               Accounts.admin_update_account(
                 user,
                 %{"name" => "ok", "steam_id" => "12345"},
                 admin
               )

      assert updated.steam_id == user.steam_id,
             "admin must not be able to directly rebind a peer's Steam account"
    end

    defp fixture_admin do
      import RC.Fixtures
      activate(fixture(:admin), :admin)
    end

    defp fixture_admin_other do
      uniq = Integer.to_string(:erlang.unique_integer([:positive]))

      {:ok, account} =
        RC.Accounts.create_account(%{
          email: "admin2-" <> uniq <> "@adm",
          password: "some admin password",
          name: "another admin " <> uniq,
          role: :admin,
          status: :active
        })

      activate(account, :admin)
    end

    defp fixture_user do
      import RC.Fixtures
      activate(fixture(:user), :user)
    end
  end

  describe "Stage 6 #C — Group.changeset no longer cast_assocs nested accounts/instances" do
    test "create_group ignores nested accounts list (no admin-account smuggling)" do
      before_count = Repo.aggregate(Account, :count, :id)

      {:ok, group} =
        Groups.create_group(%{
          "name" => "no-smuggling-here",
          "accounts" => [
            %{
              "email" => "smuggled@attacker.invalid",
              "name" => "Smuggled",
              "role" => "admin",
              "status" => "active",
              "password" => "hunter2hunter2"
            }
          ]
        })

      after_count = Repo.aggregate(Account, :count, :id)

      assert after_count == before_count,
             "Group.changeset must not insert a new Account row through the nested key"

      # The group itself still creates successfully (the nested key is just ignored).
      assert %Group{name: "no-smuggling-here"} = Repo.get!(Group, group.id)
    end

    test "update_group ignores nested accounts list (no peer-admin overwrite)" do
      group = make_test_group()

      victim_admin = fixture_admin_for_group()
      original_email = victim_admin.email

      {:ok, _updated_group} =
        Groups.update_group(group, %{
          "name" => group.name,
          "accounts" => [
            %{"id" => victim_admin.id, "email" => "attacker-wins@x", "role" => "user"}
          ]
        })

      reloaded = Repo.get!(Account, victim_admin.id)
      assert reloaded.email == original_email,
             "Group.changeset must not overwrite an existing Account via the nested key"

      assert reloaded.role == :admin,
             "Group.changeset must not demote a peer admin via the nested key"
    end

    defp make_test_group do
      {:ok, group} = Groups.create_group(%{"name" => "test-group-" <> Integer.to_string(:erlang.unique_integer([:positive]))})
      group
    end

    defp fixture_admin_for_group do
      uniq = Integer.to_string(:erlang.unique_integer([:positive]))

      {:ok, account} =
        RC.Accounts.create_account(%{
          email: "victim-admin-" <> uniq <> "@xyz",
          password: "some password",
          name: "victim-" <> uniq,
          role: :admin,
          status: :active
        })

      activate(account, :admin)
    end
  end

  describe "Stage 6 #E — snapshot deserialisation hardening" do
    test "Util.Storage safe-decodes a binary that contains only existing atoms" do
      # `:ok` is universally loaded; this should round-trip cleanly.
      data = %{module: Spatial.Supervisor, state: %{ok: true}}
      binary = :erlang.term_to_binary(data)

      # Calling the private safe_decode via load-from-disk is overkill;
      # we just confirm :safe was set by exercising it directly. The
      # function is module-private; we test it via the local-storage
      # path with a real tmp file.
      tmp = Path.join(System.tmp_dir!(), "rc-safe-decode-test-#{:erlang.unique_integer([:positive])}.bin")
      File.write!(tmp, binary)

      # Bypass the env switch by calling load_local via the public entry
      # (Util.Storage.load is env-gated; in test env it dispatches to
      # load_local). The dev/test storage_dir is "./priv/_storage/" — we
      # cleanly mirror that pattern by writing the file there.
      storage_dir = "./priv/_storage/"
      File.mkdir_p!(storage_dir)
      filename = "safe-decode-test-#{:erlang.unique_integer([:positive])}.bin"
      File.write!(Path.join(storage_dir, filename), binary)

      assert {:ok, %{module: Spatial.Supervisor, state: %{ok: true}}} = Storage.load(filename)

      File.rm(tmp)
      File.rm(Path.join(storage_dir, filename))
    end

    test "Util.Storage rejects a binary that references a never-loaded atom" do
      # We can't construct a real \"new atom\" binary from within the
      # current BEAM (every atom we type is already loaded), so we
      # forge the binary at the external-term-format level. ATOM_EXT
      # tag is 100, ATOM_UTF8_EXT is 118. We use SMALL_ATOM_UTF8_EXT
      # (119) with a fresh random name guaranteed not to exist.
      storage_dir = "./priv/_storage/"
      File.mkdir_p!(storage_dir)
      filename = "unsafe-decode-test-#{:erlang.unique_integer([:positive])}.bin"

      fresh_name = "definitelynotanatom" <> Integer.to_string(:erlang.unique_integer([:positive]))
      atom_size = byte_size(fresh_name)
      # 131 = version tag, 119 = SMALL_ATOM_UTF8_EXT, <<atom_size>>, name
      bad_binary = <<131, 119, atom_size, fresh_name::binary>>

      File.write!(Path.join(storage_dir, filename), bad_binary)

      assert {:error, :unsafe_snapshot} = Storage.load(filename)

      File.rm(Path.join(storage_dir, filename))
    end
  end
end

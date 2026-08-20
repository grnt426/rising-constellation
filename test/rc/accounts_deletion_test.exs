defmodule RC.AccountsDeletionTest do
  use RC.DataCase, async: true

  import Ecto.Query

  alias RC.Accounts
  alias RC.Accounts.Account
  alias RC.Accounts.AccountToken
  alias RC.Accounts.Deletion
  alias RC.Accounts.DeletionRequest
  alias RC.Repo

  @password "correct horse battery staple"

  defp create_account(email \\ "deleteme@email", name \\ "DeleteMe") do
    {:ok, account} =
      Accounts.create_account(%{
        email: email,
        password: @password,
        hashed_password: "placeholder",
        name: name,
        lang: "en",
        settings: %{},
        role: :user,
        status: :active
      })

    {:ok, account} =
      account
      |> Ecto.Changeset.change(hashed_password: Argon2.hash_pwd_salt(@password))
      |> Repo.update()

    account
  end

  defp deletion_token(account) do
    Repo.get_by!(AccountToken, account_id: account.id, type: :account_deletion)
  end

  defp backdate_token(token, seconds) do
    past = DateTime.add(DateTime.utc_now(), -seconds, :second)

    from(t in AccountToken, where: t.id == ^token.id)
    |> Repo.update_all(set: [inserted_at: past])
  end

  describe "request_deletion/2" do
    test "creates a 1h token, an audit row, and sends the confirmation email" do
      account = create_account()

      assert {:ok, %{token: token}} = Deletion.request_deletion(account, @password)
      assert token.type == :account_deletion

      assert %DeletionRequest{confirmed_at: nil} =
               Repo.get_by(DeletionRequest, account_id: account.id)

      assert_received {:email, %Swoosh.Email{subject: subject, html_body: html}}
      assert subject =~ "Confirm account deletion"
      assert html =~ "login/?action=confirm-deletion&token=#{token.value}"
      assert html =~ "1 hour"
    end

    test "rejects a wrong password" do
      account = create_account()
      assert {:error, :invalid_password} = Deletion.request_deletion(account, "nope")
    end

    test "rejects password-less (Steam) accounts" do
      account = create_account()
      account = %{account | hashed_password: nil}
      assert {:error, :steam_account} = Deletion.request_deletion(account, @password)
    end

    test "rejects when a deletion is already pending" do
      account = create_account()
      account = %{account | deletion_requested_at: DateTime.utc_now()}
      assert {:error, :deletion_pending} = Deletion.request_deletion(account, @password)
    end
  end

  describe "confirm_deletion/1" do
    test "starts the grace period, revokes sessions, records confirmation" do
      account = create_account()
      {:ok, _} = Deletion.request_deletion(account, @password)
      token = deletion_token(account)

      assert {:ok, %{account: updated}} = Deletion.confirm_deletion(token.value)

      assert updated.deletion_requested_at != nil
      assert updated.token_version == account.token_version + 1
      assert Repo.aggregate(from(t in AccountToken, where: t.account_id == ^account.id), :count) == 0
      assert %DeletionRequest{confirmed_at: confirmed} = Repo.get_by(DeletionRequest, account_id: account.id)
      assert confirmed != nil
    end

    test "rejects an unknown token" do
      assert {:error, :invalid_token} = Deletion.confirm_deletion("no-such-token")
    end

    test "rejects a token older than the 1h deletion validity" do
      account = create_account()
      {:ok, _} = Deletion.request_deletion(account, @password)
      token = deletion_token(account)
      backdate_token(token, 3601)

      assert {:error, :invalid_token} = Deletion.confirm_deletion(token.value)
    end
  end

  describe "cancel_deletion/1" do
    test "clears the pending state and stamps the audit row" do
      account = create_account()
      {:ok, _} = Deletion.request_deletion(account, @password)
      token = deletion_token(account)
      {:ok, %{account: pending}} = Deletion.confirm_deletion(token.value)

      assert {:ok, %{account: cancelled}} = Deletion.cancel_deletion(pending)
      assert cancelled.deletion_requested_at == nil
      assert %DeletionRequest{cancelled_at: at} = Repo.get_by(DeletionRequest, account_id: account.id)
      assert at != nil
    end

    test "errors when nothing is pending" do
      account = create_account()
      assert {:error, :not_pending} = Deletion.cancel_deletion(account)
    end
  end

  describe "purge" do
    test "days_until_purge counts down from grace_days" do
      account = create_account()
      assert Deletion.days_until_purge(account) == nil

      pending = %{account | deletion_requested_at: DateTime.utc_now()}
      assert Deletion.days_until_purge(pending) == Deletion.grace_days()

      overdue = %{account | deletion_requested_at: DateTime.add(DateTime.utc_now(), -20 * 86_400, :second)}
      assert Deletion.days_until_purge(overdue) == 0
    end

    test "purge_due_accounts scrubs overdue accounts, renames profiles, keeps fresh ones" do
      overdue = create_account("overdue@email", "Overdue")
      fresh = create_account("fresh@email", "Fresh")

      {:ok, profile} =
        Accounts.create_profile(%{
          "account_id" => overdue.id,
          "avatar" => "some avatar",
          "name" => "DoomedPilot",
          "full_name" => "Doomed Pilot",
          "description" => "desc",
          "long_description" => "long desc",
          "age" => 30
        })

      for {account, days_ago} <- [{overdue, 15}, {fresh, 2}] do
        {:ok, _} = Deletion.request_deletion(account, @password)
        {:ok, _} = Deletion.confirm_deletion(deletion_token(account).value)

        past = DateTime.add(DateTime.utc_now(), -days_ago * 86_400, :second)

        from(a in Account, where: a.id == ^account.id)
        |> Repo.update_all(set: [deletion_requested_at: past])
      end

      Deletion.purge_due_accounts()

      scrubbed = Repo.get!(Account, overdue.id)
      assert scrubbed.status == :deleted
      assert scrubbed.email == "erased-#{overdue.id}@erased.invalid"
      assert scrubbed.name == "Erased-#{overdue.id}"
      assert scrubbed.steam_id == nil
      refute Argon2.verify_pass(@password, scrubbed.hashed_password)

      renamed = Repo.get!(RC.Accounts.Profile, profile.id)
      assert renamed.name == "Erased-#{profile.id}"
      assert renamed.full_name == nil
      assert renamed.avatar == nil

      assert %DeletionRequest{purged_at: purged_at} = Repo.get_by(DeletionRequest, account_id: overdue.id)
      assert purged_at != nil

      # Final notice went to the real address before the scrub.
      assert_received {:email, %Swoosh.Email{subject: "Your account has been deleted - Tetrarchy Falls", to: to}}
      assert {_, "overdue@email"} = hd(to)

      untouched = Repo.get!(Account, fresh.id)
      assert untouched.status != :deleted
      assert untouched.email == "fresh@email"
    end
  end

  describe "Portal.Plug.DeletionLock" do
    import Plug.Test

    defp locked_conn(method, path, account) do
      conn(method, path)
      |> Plug.Conn.put_private(:guardian_default_resource, account)
      |> Portal.Plug.DeletionLock.call([])
    end

    test "blocks non-allowlisted API calls for pending accounts" do
      account = %Account{id: 1, deletion_requested_at: DateTime.utc_now()}
      conn = locked_conn(:post, "/api/instances", account)

      assert conn.halted
      assert conn.status == 403
      assert conn.resp_body =~ "deletion_pending"
    end

    test "allows the lockout page's three routes" do
      account = %Account{id: 1, deletion_requested_at: DateTime.utc_now()}

      refute locked_conn(:get, "/api/account", account).halted
      refute locked_conn(:get, "/api/account/deletion", account).halted
      refute locked_conn(:post, "/api/account/deletion/cancel", account).halted
    end

    test "passes accounts with no pending deletion" do
      account = %Account{id: 1, deletion_requested_at: nil}
      refute locked_conn(:post, "/api/instances", account).halted
    end
  end
end

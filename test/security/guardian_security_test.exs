defmodule RC.Security.GuardianTest do
  @moduledoc """
  Regression tests for the Stage 1 fixes inside `RC.Guardian`:

    * Stage 1 #4 (HIGH) — `resource_from_claims/1` rejects accounts whose
      `status` is not `:active`. A JWT issued before a ban must immediately
      stop authenticating.
    * Stage 1 #2 (HIGH) — per-account JWT revocation via the `tv` claim
      and `accounts.token_version`. `RC.Accounts.invalidate_sessions/1`
      bumps the version; every previously-issued token then fails verify.

  These are unit-level — we drive Guardian directly with crafted claims
  so we don't pay HTTP / channel setup cost.
  """
  use Portal.APIConnCase, async: false

  import RC.Fixtures

  alias RC.Accounts
  alias RC.Accounts.Account

  describe "Stage 1 #4 — banned/inactive accounts can no longer authenticate" do
    test "active account passes resource_from_claims" do
      account = fixture(:user) |> activate!()

      {:ok, _jwt, claims} = RC.Guardian.encode_and_sign(account, %{})

      assert {:ok, %Account{id: aid}} = RC.Guardian.resource_from_claims(claims)
      assert aid == account.id
    end

    test "banned account is rejected even with an otherwise-valid JWT" do
      account = fixture(:user) |> activate!()

      # Issue the JWT while still active — attacker has captured it.
      {:ok, _jwt, claims} = RC.Guardian.encode_and_sign(account, %{})

      # Admin bans the account out of band.
      {:ok, _} = Ecto.Changeset.change(account, status: :banned) |> RC.Repo.update()

      # The previously-valid JWT no longer resolves to a resource.
      assert {:error, :account_inactive} = RC.Guardian.resource_from_claims(claims)
    end

    test "deleted and inactive accounts are also rejected" do
      for status <- [:deleted, :inactive, :registered] do
        account = fixture(:user) |> activate!()
        {:ok, _jwt, claims} = RC.Guardian.encode_and_sign(account, %{})

        {:ok, _} = Ecto.Changeset.change(account, status: status) |> RC.Repo.update()

        assert {:error, :account_inactive} = RC.Guardian.resource_from_claims(claims),
               "expected #{status} account to be rejected"

        # Cleanup so each iteration uses a fresh email.
        RC.Repo.delete(account)
      end
    end
  end

  describe "Stage 1 #2 — invalidate_sessions revokes outstanding tokens" do
    test "JWT with stale 'tv' claim is rejected after invalidate_sessions" do
      account = fixture(:user) |> activate!()

      # Issue the JWT — embeds tv=0 (the default).
      {:ok, _jwt, claims} = RC.Guardian.encode_and_sign(account, %{})
      assert claims["tv"] == 0

      # Initially valid.
      assert {:ok, _account} = RC.Guardian.resource_from_claims(claims)

      # User clicks logout (or password is reset, etc.). token_version is bumped.
      {:ok, updated} = Accounts.invalidate_sessions(account)
      assert updated.token_version == 1

      # The captured JWT now fails.
      assert {:error, :token_revoked} = RC.Guardian.resource_from_claims(claims)
    end

    test "new tokens issued after invalidate_sessions carry the bumped 'tv'" do
      account = fixture(:user) |> activate!()
      {:ok, _updated} = Accounts.invalidate_sessions(account)

      # Reload so encode_and_sign sees the bumped version.
      account = Accounts.get_account!(account.id)
      assert account.token_version == 1

      {:ok, _jwt, claims} = RC.Guardian.encode_and_sign(account, %{})
      assert claims["tv"] == 1
      assert {:ok, _account} = RC.Guardian.resource_from_claims(claims)
    end

    test "backwards-compat: legacy tokens (no 'tv' claim) work for tv=0 accounts and fail after bump" do
      account = fixture(:user) |> activate!()
      {:ok, _jwt, claims} = RC.Guardian.encode_and_sign(account, %{})

      # Strip the 'tv' claim to simulate a token issued before the column existed.
      legacy_claims = Map.delete(claims, "tv")

      # tv=0 account: legacy token still works.
      assert {:ok, _} = RC.Guardian.resource_from_claims(legacy_claims)

      # After invalidate_sessions, legacy tokens for that account are killed too.
      {:ok, _} = Accounts.invalidate_sessions(account)
      assert {:error, :token_revoked} = RC.Guardian.resource_from_claims(legacy_claims)
    end
  end

  # The user fixture creates accounts in `:registered` status — flip to
  # `:active` so they pass the new status gate in resource_from_claims.
  defp activate!(account) do
    {:ok, account} = Ecto.Changeset.change(account, status: :active) |> RC.Repo.update()
    account
  end
end

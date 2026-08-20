defmodule RC.AccountsUnverifiedExpiryTest do
  use RC.DataCase, async: true

  import Ecto.Query

  alias RC.Accounts
  alias RC.Accounts.Account
  alias RC.Repo

  defp create(email, status) do
    {:ok, account} =
      Accounts.create_account(%{
        email: email,
        password: "some password",
        hashed_password: "placeholder",
        name: "Expiry#{System.unique_integer([:positive])}",
        lang: "en",
        settings: %{},
        role: :user,
        status: status
      })

    account
  end

  defp backdate(account, days) do
    past = DateTime.add(DateTime.utc_now(), -days * 86_400, :second)

    from(a in Account, where: a.id == ^account.id)
    |> Repo.update_all(set: [inserted_at: past])

    account
  end

  test "purges stale :registered accounts with their profiles, keeps fresh and active ones" do
    stale = create("stale@email", :registered) |> backdate(8)
    fresh = create("fresh@email", :registered) |> backdate(2)
    veteran = create("veteran@email", :active) |> backdate(400)

    {:ok, profile} =
      Accounts.create_profile(%{
        "account_id" => stale.id,
        "avatar" => "some avatar",
        "name" => "StaleSquatter",
        "full_name" => "Stale Squatter",
        "description" => "d",
        "long_description" => "ld",
        "age" => 30
      })

    Accounts.purge_stale_unverified_accounts()

    assert Repo.get(Account, stale.id) == nil
    assert Repo.get(RC.Accounts.Profile, profile.id) == nil
    assert Repo.get(Account, fresh.id)
    assert Repo.get(Account, veteran.id)
  end

  test "bots are never purged" do
    bot = create("bot@email", :registered) |> backdate(30)
    {:ok, _} = Ecto.Changeset.change(bot, is_bot: true) |> Repo.update()

    Accounts.purge_stale_unverified_accounts()

    assert Repo.get(Account, bot.id)
  end
end

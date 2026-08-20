defmodule RC.Discord.PlayerCardTest do
  use RC.DataCase

  # /player card assembly: the opt-in gate, the not-found path, and the
  # privacy boundary (no account fields in the card data). Rendering is
  # smoke-tested against the SVG composer; rasterization is covered by
  # the shared render pipeline tests.

  alias RC.Discord.PlayerCard

  defp account!(n, attrs \\ %{}) do
    {:ok, account} =
      RC.Accounts.create_account(%{
        email: "player-card-#{n}@test.local",
        password: "player-card-#{n}",
        name: "PCard#{n}",
        role: :user,
        status: :active
      })

    # Preference flags aren't in the signup changeset — flip them through
    # the same path the settings UI uses.
    case attrs do
      empty when empty == %{} -> account
      attrs -> RC.Accounts.update_account(account, attrs) |> then(fn {:ok, account} -> account end)
    end
  end

  defp profile!(account, name, attrs \\ %{}) do
    {:ok, profile} =
      RC.Accounts.create_profile(Map.merge(%{account_id: account.id, name: name, avatar: "todo"}, attrs))

    profile
  end

  test "unknown username" do
    assert PlayerCard.for_username("nobody-here") == {:error, :not_found}
  end

  test "opt-out account stays hidden" do
    account = account!(1)
    profile!(account, "HiddenPlayer")

    assert PlayerCard.for_username("HiddenPlayer") == {:error, :hidden}
  end

  test "opt-in account gets card data, case-insensitive lookup, no account fields" do
    account = account!(2, %{show_profile_in_discord: true})

    profile!(account, "ShownPlayer", %{
      full_name: "Shown P. Layer",
      description: "A maxim",
      favorite_faction: "cardan",
      favorite_icon: "marker/flag"
    })

    assert {:ok, data} = PlayerCard.for_username("shownplayer")

    assert data.name == "ShownPlayer"
    assert data.favorite_faction == "cardan"
    assert data.favorite_icon == "marker/flag"
    assert %{legacy: _, daily: _, factions: _} = data.stats

    # Privacy boundary: nothing account-shaped may ride along.
    refute Map.has_key?(data, :email)
    refute Map.has_key?(data, :discord_id)
    refute Map.has_key?(data, :timezone)

    # And the composed SVG contains only what the card intends to show.
    svg = RC.Discord.Render.Cards.player_profile(data)
    assert svg =~ "SHOWNPLAYER"
    assert svg =~ "A maxim"
    refute svg =~ account.email
  end

  test "bot profiles are not discoverable" do
    account = account!(3, %{show_profile_in_discord: true})
    profile = profile!(account, "BotPlayer")
    Repo.update!(Ecto.Changeset.change(profile, %{is_bot: true}))

    assert PlayerCard.for_username("BotPlayer") == {:error, :not_found}
  end

  test "invalid avatar strings never resolve to a file" do
    account = account!(4, %{show_profile_in_discord: true})
    profile!(account, "TraversalPlayer", %{avatar: "../../mix.exs"})

    assert {:ok, data} = PlayerCard.for_username("TraversalPlayer")
    assert data.avatar_jpeg == nil
  end
end

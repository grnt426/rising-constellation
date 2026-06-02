# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs
#
# Inside the script, you can read and write to any of your
# repositories directly:
#
#     RC.Repo.insert!(%RC.SomeSchema{})
#
# We recommend using the bang functions (`insert!`, `update!`
# and so on) as they will fail if something goes wrong.

data =
  case Application.get_env(:rc, :environment) do
    :dev ->
      # Passwords are 8+ chars because `Account.changeset_password/2`
      # validates min: 8 (Stage 5 #B1.2 — Argon2 unbounded-input fix).
      # Previous "admin" / "user1" values silently worked only because
      # the running container held stale pre-validation bytecode.
      [
        {"admin@abc", "admindev", "Admin", :admin, :active},
        {"user1@abc", "user1dev", "User1", :user, :active},
        {"user2@abc", "user2dev", "User2", :user, :active},
        {"user3@abc", "user3dev", "User3", :user, :active},
        {"user4@abc", "user4dev", "User4", :admin, :active},
        {"user5@abc", "user5dev", "User5", :user, :active},
        {"user6@abc", "user6dev", "User6", :user, :active},
        {"user7@abc", "user7dev", "User7", :user, :active},
        {"user8@abc", "user8dev", "User registered", :user, :registered},
        {"user9@abc", "user9dev", "User inactive", :user, :inactive}
      ]

    :prod ->
      [
        {"gil.clavien@gmail.com", "change-that", "Abdelaz3r", :admin, :active},
        {"victor@draft.li", "change-that", "vhf", :admin, :active},
        {"cabrini.vincent@gmail.com", "change-that", "Dan-Djuna", :admin, :active}
      ]
  end

Enum.each(data, fn {email, pwd, pseudo, role, status} ->
  {:ok, account} =
    %RC.Accounts.Account{}
    |> RC.Accounts.Account.changeset_password(%{
      email: email,
      password: pwd,
      name: pseudo,
      role: role,
      status: status,
      # Explicitly mark as paid account
      is_free: false
    })
    # Ensure account is marked as paid
    |> RC.Accounts.Account.changeset_is_free(false)
    |> RC.Repo.insert()

  if role == :admin do
    {:ok, _profile} =
      RC.Accounts.create_profile(%{
        name: account.name,
        avatar: "avatarM_001.jpg",
        age: 40,
        description: "",
        full_name: "",
        long_description: "",
        account_id: account.id
      })
  end

  {:ok, _log} =
    RC.Logs.create_log(
      %{action: :create_account},
      account
    )
end)

if Application.get_env(:rc, :environment) == :dev and
     RC.Repo.aggregate(RC.Scenarios.Scenario, :count) == 0 do
  seed_path = fn name -> Path.join([File.cwd!(), "priv", "repo", "seeds_data", name]) end

  map_game_data = seed_path.("map_game_data.json") |> File.read!() |> Jason.decode!()
  map_game_metadata = seed_path.("map_game_metadata.json") |> File.read!() |> Jason.decode!()

  {:ok, _map} =
    RC.Scenarios.create_map(
      %{
        game_data: map_game_data,
        game_metadata: map_game_metadata,
        is_map: true,
        is_official: true
      },
      :no_thumbnail
    )

  IO.puts("Seeded the Dev Map from priv/repo/seeds_data/.")
end

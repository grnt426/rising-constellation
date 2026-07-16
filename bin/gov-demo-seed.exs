# Dev-only bootstrap for a faction-government demo game. Creates (or
# reuses) dev accounts, builds an instance from the test scenario, puts
# three players in Tetrarchy and one in Myrmezir.
#
#   docker compose exec -u rc rc mix run bin/gov-demo-seed.exs [speed] [registration]
#
#   speed:        fast (default) | slow  — slow builds a LEGACY game with
#                 a real timer (10 days) and the production 14-VP bar, so
#                 the demo world survives inspection.
#   registration: pre (default) | late  — late lets more players join
#                 AFTER the game starts (join-and-look-around demos).
#
# Then start it via PUT /api/instances/<id>/start as an admin (the
# script runs in its own BEAM; the server must build the live tree),
# and fast-forward founding with POST /api/harness/gov-debug/advance.
require Logger
alias RC.Repo

{speed, registration} =
  case System.argv() do
    [s, r | _] -> {s, r}
    [s] -> {s, "pre"}
    _ -> {"fast", "pre"}
  end

game_data = "test/support/scenario_game_data.json" |> File.read!() |> Jason.decode!()
game_metadata = "test/support/scenario_game_metadata.json" |> File.read!() |> Jason.decode!()

game_data =
  if speed == "slow" do
    game_data
    |> Map.put("speed", "slow")
    # the fixture is tuned for fast tests (120 wall-minutes, 2 VP): a
    # Legacy demo needs to outlive a look-around and not end on the
    # first conquest
    |> Map.put("time_limit", 14_400)
    |> Map.put("victory_points", 14)
  else
    game_data
  end

users =
  for i <- 1..4 do
    email = "user#{i}@abc"

    account =
      case RC.Accounts.get_account_by_email(email) do
        {:ok, %RC.Accounts.Account{} = account} ->
          account

        _ ->
          {:ok, account} =
            %RC.Accounts.Account{}
            |> RC.Accounts.Account.changeset_password(%{
              email: email,
              password: "user#{i}dev",
              name: "User#{i}",
              role: :user,
              status: :active
            })
            |> RC.Accounts.Account.changeset_is_free(false)
            |> Repo.insert()

          account
      end

    profile =
      case Repo.get_by(RC.Accounts.Profile, account_id: account.id) do
        nil ->
          {:ok, profile} =
            RC.Accounts.create_profile(%{
              avatar: "todo",
              name: account.name,
              account_id: account.id
            })

          profile

        profile ->
          profile
      end

    {account, profile}
  end

[{owner, p1}, {_a2, p2}, {_a3, p3}, {_a4, p4}] = users

{:ok, scenario} =
  %RC.Scenarios.Scenario{}
  |> RC.Scenarios.Scenario.changeset(%{
    game_data: game_data,
    game_metadata: game_metadata,
    is_map: false
  })
  |> Repo.insert()

instance_attrs = %{
  "name" => if(speed == "slow", do: "Gov demo (Legacy)", else: "Gov demo"),
  "description" => "Faction government demo",
  "opening_date" => DateTime.to_iso8601(DateTime.utc_now()),
  "registration_type" =>
    if(registration == "late", do: "late_registration", else: "pre_registration"),
  "game_type" => "private",
  # the lobby query shows non-admins only PUBLIC instances (or shared
  # groups) — even players registered in the game don't see a private
  # one listed. Demo games are for joining and looking around.
  "public" => true,
  "start_setting" => "auto",
  "factions" => [
    %{"key" => "tetrarchy", "capacity" => 10},
    %{"key" => "myrmezir", "capacity" => 10}
  ]
}

{:ok, %{instance: instance}} = RC.Instances.create_instance(instance_attrs, scenario, owner.id)
{:ok, _} = RC.Instances.publish_instance(instance, owner.id)

tetrarchy = Enum.find(instance.factions, &(&1.faction_ref == "tetrarchy"))
myrmezir = Enum.find(instance.factions, &(&1.faction_ref == "myrmezir"))

registrations =
  for {faction, profile} <- [{tetrarchy, p1}, {tetrarchy, p2}, {tetrarchy, p3}, {myrmezir, p4}] do
    {:ok, %{registration: registration}} = RC.Registrations.register_profile(faction, profile)
    {faction, profile, registration}
  end

# NOTE: no create_from_model / start here — this script runs in its own
# transient BEAM. The live supervision tree must be built by the RUNNING
# server: PUT /api/instances/#{instance.id}/start as an admin.

IO.puts("=== GOV DEMO READY ===")
IO.puts("instance_id=#{instance.id}")

Enum.each(registrations, fn {faction, profile, registration} ->
  IO.puts(
    "player=#{profile.name} profile_id=#{profile.id} faction=#{faction.faction_ref} " <>
      "faction_id=#{faction.id} token=#{registration.token}"
  )
end)

defmodule RC.Security.RegistrationsTest do
  @moduledoc """
  Regression tests for the channel-identity binding (Stage 3 #1, CRITICAL)
  and registration-token rotation (Stage 3 #4, HIGH):

    * `RC.Registrations.valid?/3` only returns a registration when the
      profile's account_id matches the calling account. A captured token
      cannot be redeemed from any other account.
    * On `resigned`/`dead` state transitions, the token is rotated to a
      fresh value — the captured one becomes invalid forever.
    * `RegistrationView` index template omits `:token` so the listing
      endpoint no longer leaks per-player credentials.
  """
  use Portal.APIConnCase, async: false

  import RC.Fixtures
  import RC.ScenarioFixtures

  alias RC.Accounts.Profile
  alias RC.Instances.Registration
  alias RC.Registrations
  alias RC.Repo

  defp registered_setup(_) do
    %{instance: instance} = instance_fixture()
    owner = fixture(:user)

    Machinery.transition_to(
      Map.put(instance, :account_id, owner.id),
      RC.Instances.InstanceStateMachine,
      "open"
    )

    {:ok, profile} =
      Repo.insert(
        Profile.changeset(%Profile{}, %{
          avatar: "x",
          name: "owner profile",
          account_id: owner.id
        })
      )

    [faction | _] = instance.factions

    {:ok, %{registration: registration}} = Registrations.register_profile(faction, profile)

    {:ok, instance: instance, faction: faction, owner: owner, profile: profile, registration: registration}
  end

  describe "Stage 3 #1 — valid?/3 requires the token AND the calling account" do
    setup [:registered_setup]

    test "owner account passes", %{instance: instance, registration: reg, owner: owner} do
      assert {:ok, found} = Registrations.valid?(instance.id, reg.token, owner.id)
      assert found.id == reg.id
    end

    test "stranger account is rejected even with the legitimate token",
         %{instance: instance, registration: reg} do
      stranger = fixture(:user2)

      assert {:error, :registration_not_valid} =
               Registrations.valid?(instance.id, reg.token, stranger.id)
    end

    test "wrong token is rejected for the owner too",
         %{instance: instance, owner: owner} do
      assert {:error, :registration_not_valid} =
               Registrations.valid?(instance.id, "not-a-real-token", owner.id)
    end

    test "right token in the wrong instance is rejected",
         %{registration: reg, owner: owner} do
      # Spawn a second instance and try the first instance's token against it.
      %{instance: other_instance} = instance_fixture()

      assert {:error, :registration_not_valid} =
               Registrations.valid?(other_instance.id, reg.token, owner.id)
    end
  end

  describe "Stage 3 #4 — registration token rotates on terminal state transitions" do
    setup [:registered_setup]

    test "token survives the joined -> playing transition (still live)",
         %{registration: reg} do
      original_token = reg.token

      {:ok, _} = Registrations.transition_to(reg, "playing")
      reloaded = Repo.get!(Registration, reg.id)

      assert reloaded.token == original_token
    end

    test "token is rotated on transition to 'resigned'",
         %{instance: instance, owner: owner, registration: reg} do
      original_token = reg.token

      {:ok, reg} = Registrations.transition_to(reg, "playing")
      {:ok, _} = Registrations.transition_to(reg, "resigned")

      reloaded = Repo.get!(Registration, reg.id)

      assert reloaded.token != original_token,
             "expected resigned registration to have a fresh token; old one is now a permanent bearer credential"

      # And the captured-pre-resign token no longer authenticates.
      assert {:error, :registration_not_valid} =
               Registrations.valid?(instance.id, original_token, owner.id)
    end

    test "token is rotated on transition to 'dead'",
         %{instance: instance, owner: owner, registration: reg} do
      original_token = reg.token

      {:ok, reg} = Registrations.transition_to(reg, "playing")
      {:ok, _} = Registrations.transition_to(reg, "dead")

      reloaded = Repo.get!(Registration, reg.id)
      assert reloaded.token != original_token

      assert {:error, :registration_not_valid} =
               Registrations.valid?(instance.id, original_token, owner.id)
    end
  end

  describe "Stage 2 #7 — registration listing endpoint omits :token" do
    setup [:registered_setup]

    test "GET /api/instances/:iid/registrations does not leak the per-player token",
         %{conn: conn, instance: instance, owner: owner, registration: reg} do
      owner = activate!(owner)

      response =
        conn
        |> login(owner)
        |> get(Routes.registration_path(conn, :index_by_instance, instance.id))
        |> json_response(200)

      assert is_list(response)
      assert length(response) >= 1

      Enum.each(response, fn entry ->
        refute Map.has_key?(entry, "token"),
               "registration listing must NOT include :token (Stage 2 #7); got #{inspect(entry)}"
      end)

      # Sanity: the seeded registration is actually present in the response.
      assert Enum.any?(response, &(&1["id"] == reg.id))
    end
  end

  defp activate!(account) do
    {:ok, a} = Ecto.Changeset.change(account, status: :active) |> Repo.update()
    a
  end
end

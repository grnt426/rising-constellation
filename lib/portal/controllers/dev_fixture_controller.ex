defmodule Portal.DevFixtureController do
  @moduledoc """
  Dev-only harness endpoint that fabricates a small two-faction game with
  real opposing agents parked in the caller's starting system — for
  exercising the system-view agent display (fan, squadrons, hover cards,
  per-agent action buttons) without orchestrating a real multiplayer game.

      POST /api/harness/dev/agent-fixture
      body: {"email": "user1@abc"}   (optional; defaults to user1@abc)

  The agents are engine-real: each one goes through the same
  `{:convert_character, ...}` player call the seduction action uses, so it
  lives in its owner's roster, has a live `Instance.Character.Agent`, and is
  a valid target for fight / removal / sabotage / seduction.

  Gated twice: the harness pipeline's shared secret AND `:environment ==
  :dev` — it must never respond on a prod node.
  """
  use Portal, :controller

  require Logger

  alias Instance.Character.Character, as: GameCharacter
  alias RC.Accounts
  alias RC.Accounts.Profile

  # Seeded dev accounts that lend their profiles to the hostile faction.
  @puppets ["user2@abc", "user3@abc"]

  def agent_fixture(conn, params) do
    if Application.get_env(:rc, :environment) == :dev do
      case build(params["email"] || "user1@abc") do
        {:ok, summary} ->
          json(conn, summary)

        {:error, reason} ->
          conn |> put_status(500) |> json(%{error: inspect(reason)})
      end
    else
      conn |> put_status(403) |> json(%{error: "dev_only"})
    end
  end

  defp build(email) do
    with {:ok, account} <- Accounts.get_account_by_email(email) do
      profile = ensure_profile(account)
      [p2, p3] = Enum.map(@puppets, &ensure_puppet/1)

      # The test-suite scenario: two factions (tetrarchy / myrmezir), each
      # owning a sector. Lifted limits so the fixture neither times out nor
      # ends by victory points while it sits around waiting to be tested.
      game_data =
        "test/support/scenario_game_data.json"
        |> File.read!()
        |> Jason.decode!()
        |> Map.merge(%{"time_limit" => 100_000, "victory_points" => 999_999})

      game_metadata =
        "test/support/scenario_game_metadata.json" |> File.read!() |> Jason.decode!()

      {:ok, scenario} =
        %RC.Scenarios.Scenario{}
        |> RC.Scenarios.Scenario.changeset(%{
          game_data: game_data,
          game_metadata: game_metadata,
          is_map: false
        })
        |> RC.Repo.insert()

      instance_attrs = %{
        "name" => "Agent fixture — #{DateTime.utc_now() |> DateTime.truncate(:second)}",
        "description" => "Dev fixture: opposing agents in #{profile.name}'s starting system",
        "opening_date" => DateTime.to_iso8601(DateTime.utc_now()),
        "registration_type" => "pre_registration",
        "game_type" => "private",
        "public" => false,
        "start_setting" => "auto",
        "factions" => [
          %{"key" => "tetrarchy", "capacity" => 1},
          %{"key" => "myrmezir", "capacity" => 2}
        ]
      }

      {:ok, %{instance: instance}} = RC.Instances.create_instance(instance_attrs, scenario, account.id)
      {:ok, _} = RC.Instances.publish_instance(instance, account.id)

      tetrarchy = Enum.find(instance.factions, &(&1.faction_ref == "tetrarchy"))
      myrmezir = Enum.find(instance.factions, &(&1.faction_ref == "myrmezir"))

      {:ok, _} = RC.Registrations.register_profile(tetrarchy, profile)
      {:ok, _} = RC.Registrations.register_profile(myrmezir, p2)
      {:ok, _} = RC.Registrations.register_profile(myrmezir, p3)

      loaded = RC.Instances.get_instance_with_registration(instance.id)

      with {:ok, :instantiated} <- Instance.Manager.create_from_model(loaded, nil),
           {:ok, _} <- RC.Instances.start_instance(loaded, account.id),
           {:ok, :started, _} <- Instance.Manager.call(instance.id, :start),
           {:ok, player} <- Game.call(instance.id, :player, profile.id, :get_state) do
        system = hd(player.stellar_systems)

        # Own hand: one agent of each type on board, so every kind of
        # action button has a source to be selected.
        for {type, rank} <- [admiral: :remarkable, spy: :common, speaker: :common] do
          place(instance.id, profile.id, type, rank, system.id)
        end

        # Puppet 1: a four-agent squadron — exercises the cluster badge,
        # the unfurl, and the action buttons inside the fan. Mostly
        # always-visible types; the one spy starts discovered (cover 0)
        # but will fade from view as its cover rebuilds.
        for {type, rank} <- [admiral: :exceptional, admiral: :common, speaker: :remarkable, spy: :common] do
          place(instance.id, p2.id, type, rank, system.id)
        end

        # Puppet 2: a lone hostile navarch — exercises the single-badge path.
        place(instance.id, p3.id, :admiral, :remarkable, system.id)

        Logger.info("[dev-fixture] instance=#{instance.id} system=#{system.id} (#{system.name})")

        {:ok,
         %{
           instance_id: instance.id,
           system: %{id: system.id, name: system.name},
           enter_url: "/portal/instance/#{instance.id}",
           agents: %{own: 3, hostile_squadron: 4, hostile_lone: 1}
         }}
      end
    end
  end

  # Mint a real character and hand it to `owner` inside `system_id` through
  # the same player-agent call the seduction action uses — no shortcuts, so
  # the character is fully owned, supervised, and targetable.
  defp place(instance_id, owner_profile_id, type, rank, system_id) do
    {:ok, tmp_id} = Game.call(instance_id, :character_market, :master, :get_next_character_id)
    character = GameCharacter.new(tmp_id, type, rank, 1, instance_id)
    :ok = Game.call(instance_id, :player, owner_profile_id, {:convert_character, character, system_id})
  end

  defp ensure_profile(account) do
    case RC.Repo.get_by(Profile, account_id: account.id) do
      nil ->
        {:ok, profile} =
          Accounts.create_profile(%{account_id: account.id, name: account.name, avatar: "todo"})

        profile

      profile ->
        profile
    end
  end

  defp ensure_puppet(email) do
    {:ok, account} = Accounts.get_account_by_email(email)
    ensure_profile(account)
  end
end

defmodule Wave.LobbyTest do
  use RC.DataCase, async: false

  alias RC.Scenarios.Scenario

  @wave_game_data %{
    "speed" => "slow",
    "game_mode_type" => "wave",
    "sectors" => [
      %{"key" => 0, "faction" => "tetrarchy", "systems" => []},
      %{"key" => 1, "faction" => "rebellion", "systems" => []},
      %{"key" => 2, "faction" => nil, "systems" => []}
    ],
    "factions" => [%{"key" => "tetrarchy", "sector_number" => 1}, %{"key" => "rebellion", "sector_number" => 1}]
  }

  describe "validate_scenario/1" do
    test "accepts one human faction and the Rebellion at Legacy speed" do
      assert :ok = Wave.Lobby.validate_scenario(@wave_game_data)
    end

    test "leaves non-wave scenarios alone" do
      assert :ok = Wave.Lobby.validate_scenario(%{"speed" => "fast", "factions" => []})
    end

    test "refuses a wave scenario that is not Legacy" do
      assert {:error, :wave_requires_legacy_speed} =
               Wave.Lobby.validate_scenario(Map.put(@wave_game_data, "speed", "fast"))
    end

    test "refuses a wave scenario without the Rebellion" do
      data = %{@wave_game_data | "factions" => [%{"key" => "tetrarchy"}, %{"key" => "myrmezir"}]}
      assert {:error, :wave_requires_rebel_faction} = Wave.Lobby.validate_scenario(data)
    end

    test "refuses a second human faction" do
      data = %{@wave_game_data | "factions" => @wave_game_data["factions"] ++ [%{"key" => "myrmezir"}]}
      assert {:error, :wave_requires_one_human_faction} = Wave.Lobby.validate_scenario(data)
    end

    test "refuses a Rebellion with no sector" do
      sectors = Enum.map(@wave_game_data["sectors"], &Map.put(&1, "faction", if(&1["key"] == 0, do: "tetrarchy")))
      assert {:error, :wave_rebellion_has_no_sector} = Wave.Lobby.validate_scenario(%{@wave_game_data | "sectors" => sectors})
    end

    test "the scenario changeset carries the refusal" do
      changeset =
        Scenario.changeset(%Scenario{}, %{
          game_data: Map.put(@wave_game_data, "speed", "fast"),
          game_metadata: %{},
          is_map: false
        })

      refute changeset.valid?
      assert {"wave_requires_legacy_speed", _} = changeset.errors[:game_data]
    end
  end

  describe "prepare_instance/2" do
    test "forces the mode, government off and one Rebellion seat" do
      attrs = %{
        "game_mode_type" => "casual",
        "faction_gov_enabled" => true,
        "factions" => [%{"key" => "tetrarchy", "capacity" => 12}, %{"key" => "rebellion", "capacity" => 12}]
      }

      {attrs, game_data} = Wave.Lobby.prepare_instance(attrs, @wave_game_data)

      assert attrs["game_mode_type"] == "wave"
      assert attrs["faction_gov_enabled"] == false
      assert attrs["factions"] == [%{"key" => "tetrarchy", "capacity" => 12}, %{"key" => "rebellion", "capacity" => 1}]
      assert game_data["wave"] == %{"bot_faction" => "rebellion", "human_faction" => "tetrarchy"}
    end

    test "keeps knob overrides the scenario carries" do
      data = Map.put(@wave_game_data, "wave", %{"hire_interval_ut" => 60, "bot_faction" => "tetrarchy"})
      {_attrs, game_data} = Wave.Lobby.prepare_instance(%{}, data)

      assert game_data["wave"]["hire_interval_ut"] == 60
      assert game_data["wave"]["bot_faction"] == "rebellion"
    end

    test "a non-wave scenario cannot be turned into a wave game" do
      {attrs, game_data} = Wave.Lobby.prepare_instance(%{"game_mode_type" => "wave"}, %{"speed" => "slow"})
      assert attrs["game_mode_type"] == "casual"
      refute Map.has_key?(game_data, "wave")
    end
  end

  describe "the lobby path" do
    setup do
      {:ok, account} =
        RC.Accounts.create_account(%{
          email: "wave-lobby-owner@test",
          password: "correct horse battery",
          name: "Owner",
          role: :user,
          status: :active
        })

      scenario =
        %Scenario{}
        |> Scenario.changeset(%{game_data: @wave_game_data, game_metadata: %{"speed" => "slow"}, is_map: false})
        |> RC.Repo.insert!()

      %{account: account, scenario: scenario}
    end

    test "create → publish seats the bot once", %{account: account, scenario: scenario} do
      attrs = %{
        "name" => "Rebel Defense",
        "description" => "test",
        "opening_date" => DateTime.to_iso8601(DateTime.utc_now()),
        "registration_type" => "late_registration",
        "game_type" => "public",
        "public" => true,
        "start_setting" => "manual",
        "game_mode_type" => "casual",
        "factions" => [%{"key" => "tetrarchy", "capacity" => 8}, %{"key" => "rebellion", "capacity" => 8}]
      }

      {:ok, %{instance: instance}} = RC.Instances.create_instance(attrs, scenario, account.id)

      assert instance.game_data["game_mode_type"] == "wave"
      assert instance.game_data["faction_gov_enabled"] == false
      assert Enum.find(instance.factions, &(&1.faction_ref == "rebellion")).capacity == 1

      {:ok, published} = RC.Instances.publish_instance(instance, account.id)
      assert {:ok, :registered} = Wave.Lobby.ensure_rebellion_registered(published)
      assert {:ok, :already_registered} = Wave.Lobby.ensure_rebellion_registered(published)

      loaded = RC.Instances.get_instance_with_registration(instance.id)
      rebels = Enum.find(loaded.factions, &(&1.faction_ref == "rebellion"))
      assert [%{profile_id: profile_id}] = rebels.registrations
      assert profile_id == Wave.Boot.rebellion_profile().id

      assert Wave.locked_faction?(loaded, rebels)
      refute Wave.locked_faction?(loaded, Enum.find(loaded.factions, &(&1.faction_ref == "tetrarchy")))
    end
  end
end

defmodule Wave.BootTest do
  use ExUnit.Case, async: true

  @game_data %{
    "speed" => "fast",
    "time_limit" => 120,
    "sectors" => [
      %{"key" => 0, "faction" => "myrmezir", "systems" => []},
      %{"key" => 1, "faction" => "tetrarchy", "systems" => []},
      %{"key" => 2, "faction" => "cardan", "systems" => []},
      %{"key" => 3, "faction" => nil, "systems" => []}
    ],
    "factions" => [%{"key" => "tetrarchy"}, %{"key" => "myrmezir"}, %{"key" => "cardan"}]
  }

  describe "prepare_game_data/3" do
    test "hands one rival start sector to the Rebellion and frees the rest" do
      assert {:ok, data} = Wave.Boot.prepare_game_data(@game_data, "tetrarchy")

      owners = Map.new(data["sectors"], &{&1["key"], &1["faction"]})
      assert owners == %{0 => "rebellion", 1 => "tetrarchy", 2 => nil, 3 => nil}

      assert data["factions"] == [
               %{"key" => "tetrarchy", "sector_number" => 1},
               %{"key" => "rebellion", "sector_number" => 1}
             ]
    end

    test "forces Legacy wave play and records the faction roles" do
      assert {:ok, data} = Wave.Boot.prepare_game_data(@game_data, "tetrarchy", %{"hire_interval_ut" => 5})

      assert data["speed"] == "slow"
      assert data["game_mode_type"] == "wave"
      assert data["wave"]["bot_faction"] == "rebellion"
      assert data["wave"]["human_faction"] == "tetrarchy"
      assert data["wave"]["hire_interval_ut"] == 5
      # untouched knobs keep their defaults
      assert data["wave"]["credit_floor"] == Wave.defaults()["credit_floor"]
    end

    test "a caller cannot rename the bot faction through the knobs" do
      assert {:ok, data} = Wave.Boot.prepare_game_data(@game_data, "tetrarchy", %{bot_faction: "tetrarchy"})
      assert data["wave"]["bot_faction"] == "rebellion"
    end

    test "refuses maps that can't seat both sides" do
      assert {:error, {:no_sector_for_human_faction, "synelle"}} =
               Wave.Boot.prepare_game_data(@game_data, "synelle")

      solo = %{@game_data | "sectors" => [%{"key" => 1, "faction" => "tetrarchy"}]}
      assert {:error, :no_sector_for_rebellion} = Wave.Boot.prepare_game_data(solo, "tetrarchy")
    end
  end

  describe "locked_faction?/2" do
    @wave_instance %{game_data: %{"game_mode_type" => "wave", "wave" => %{"bot_faction" => "rebellion"}}}

    test "locks the bot faction of a wave instance only" do
      assert Wave.locked_faction?(@wave_instance, %{faction_ref: "rebellion"})
      refute Wave.locked_faction?(@wave_instance, %{faction_ref: "tetrarchy"})
    end

    test "never locks a faction outside wave games" do
      refute Wave.locked_faction?(%{game_data: %{"game_mode_type" => "casual"}}, %{faction_ref: "rebellion"})
      refute Wave.locked_faction?(%{game_data: nil}, %{faction_ref: "rebellion"})
    end
  end
end

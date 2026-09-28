defmodule Player.CheatRecallAnywhereTest do
  @moduledoc """
  The "recall from anywhere" cheat toggle (`Instance.Cheats.recall_anywhere?/1`):
  `Player.deactivate_character/2` drops its home/siege requirement for an
  on-board agent, and only that — busy agents still stay put, and the flag
  means nothing on an instance without cheat access.
  """
  use ExUnit.Case, async: true

  alias Instance.Player.Player
  alias Test.FleetScenario

  @player_id 42
  @character_id 7
  # a system the player owns neither as a system nor as a dominion
  @foreign_system 900

  defp setup_instance(metadata) do
    instance_id = FleetScenario.unique_instance_id()
    FleetScenario.load_game_data(instance_id, [speed: :fast, mode: :dev] ++ metadata)
    FleetScenario.spawn_spatial(self(), instance_id: instance_id)
    instance_id
  end

  defp player(instance_id) do
    struct(Player, %{
      id: @player_id,
      instance_id: instance_id,
      characters: [%{id: @character_id, type: :admiral}],
      stellar_systems: [],
      dominions: [],
      character_deck: []
    })
  end

  defp away_agent(instance_id, opts \\ []) do
    FleetScenario.build_character(
      [
        instance_id: instance_id,
        character_id: @character_id,
        faction: :myrmezir,
        system: @foreign_system,
        owner_id: @player_id
      ] ++ opts
    )
    |> Map.put(:on_sold, false)
  end

  test "without the toggle an agent away from home can't be recalled" do
    instance_id = setup_instance(cheats_enabled: true)

    assert Player.deactivate_character(player(instance_id), away_agent(instance_id)) ==
             {:error, :character_not_at_home}
  end

  test "with the toggle an idle agent is recalled from a foreign system" do
    instance_id = setup_instance(cheats_enabled: true, cheat_recall_anywhere: true)

    assert {:ok, data, character} = Player.deactivate_character(player(instance_id), away_agent(instance_id))
    assert character.status == :in_deck
    assert data.characters == []
    assert [%{character: %{id: @character_id}}] = data.character_deck
  end

  test "the toggle still refuses an agent in the middle of an action" do
    instance_id = setup_instance(cheats_enabled: true, cheat_recall_anywhere: true)
    busy = away_agent(instance_id, action_status: :moving)

    assert Player.deactivate_character(player(instance_id), busy) == {:error, :character_must_be_idle}
  end

  test "the flag is ignored on an instance without cheat access" do
    instance_id = setup_instance(cheat_recall_anywhere: true)

    assert Player.deactivate_character(player(instance_id), away_agent(instance_id)) ==
             {:error, :character_not_at_home}
  end
end

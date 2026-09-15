defmodule Character.CheatTransferableTest do
  @moduledoc """
  Guards of the Cheats tab agent transfer
  (`Instance.Manager {:cheat_transfer_character, ...}`): only an idle,
  on-board agent with an empty order queue and no armada may change hands.
  """
  use ExUnit.Case, async: true

  alias Instance.Character.ActionQueue
  alias Instance.Character.Character
  alias Test.FleetScenario

  defp agent(opts \\ []) do
    FleetScenario.build_character([instance_id: 1, character_id: 7, faction: :myrmezir, system: 1] ++ opts)
  end

  test "an idle agent standing in a system can be transferred" do
    for type <- [:admiral, :spy, :speaker] do
      assert Character.cheat_transferable(agent(type: type)) == :ok
    end
  end

  test "governors and deck agents are refused" do
    for status <- [:governor, :in_deck] do
      assert Character.cheat_transferable(agent(status: status)) == {:error, :character_not_on_board}
    end
  end

  test "agents busy moving, docking or attached are refused" do
    for action_status <- [:moving, :docking, :attached] do
      assert Character.cheat_transferable(agent(action_status: action_status)) == {:error, :character_not_idle}
    end
  end

  test "an idle agent with queued orders is refused" do
    character = agent()
    actions = ActionQueue.add(character.actions, {:jump, %{"source" => 1, "target" => 2}, 0})

    assert Character.cheat_transferable(%{character | actions: actions}) == {:error, :character_not_idle}
  end

  test "market listings and armada members are refused" do
    assert Character.cheat_transferable(Map.put(agent(), :on_sold, true)) == {:error, :character_on_sold}

    armada = %{id: 1, name: "a", member_ids: [7, 8]}
    assert Character.cheat_transferable(Map.put(agent(), :armada, armada)) == {:error, :character_in_armada}
  end
end

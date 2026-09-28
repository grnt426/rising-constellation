defmodule Wave.GovernmentGuardTest do
  @moduledoc """
  Rebel Defense with the Faction Government beta on: the bot-held faction never
  gets a government, and diplomacy aimed at it is refused. The faction agent is
  driven through its real `on_call` clause with a synthetic, stopped-clock state.
  """
  use RC.DataCase, async: false

  alias Instance.Diplomacy.Diplomacy
  alias Instance.Faction.Faction
  alias Test.FleetScenario

  setup do
    wave = System.unique_integer([:positive])
    plain = System.unique_integer([:positive])

    FleetScenario.load_game_data(wave,
      speed: :slow,
      mode: :prod,
      wave: true,
      wave_config: %{"bot_faction" => "rebellion"},
      faction_gov_enabled: true
    )

    FleetScenario.load_game_data(plain, speed: :slow, mode: :prod, faction_gov_enabled: true)

    {:ok, wave: wave, plain: plain}
  end

  defp agent_state(faction_ref, iid, government \\ nil) do
    data = %{Faction.new(%{id: 7, faction_ref: faction_ref}, iid) | government: government}
    %{data: data, speed: :slow, tick: %{running?: false}, channel: "test", instance_id: iid}
  end

  describe "faction government" do
    test "the Rebellion has none, and one it picked up earlier is dropped", %{wave: wave} do
      stale = %{phase: :founding, seats: %{leader: nil, economy: nil, military: nil}}

      assert {:reply, {:error, :government_disabled}, state} =
               Instance.Faction.Agent.on_call({:get_government, 1}, self(), agent_state("rebellion", wave, stale))

      assert state.data.government == nil
    end

    test "the human faction in the same game still gets one", %{wave: wave} do
      assert {:reply, {:ok, %{government: government}}, _state} =
               Instance.Faction.Agent.on_call({:get_government, 1}, self(), agent_state("myrmezir", wave))

      assert government.phase == :founding
    end
  end

  describe "diplomacy" do
    defp factions, do: [%{id: 1, key: :myrmezir}, %{id: 2, key: :rebellion}, %{id: 3, key: :tetrarchy}]

    test "nobody can declare on, or propose to, the Rebellion", %{wave: wave} do
      state = Diplomacy.new(factions(), wave)

      assert {:error, :bot_faction} = Diplomacy.declare_war(state, 1, 2)
      assert {:error, :bot_faction} = Diplomacy.propose(state, 1, 2, :non_aggression)
      assert {:error, :bot_faction} = Diplomacy.declare_war(state, 2, 3)
      assert {:ok, _, _} = Diplomacy.declare_war(state, 1, 3)
    end

    test "outside Rebel Defense the same faction key is an ordinary rival", %{plain: plain} do
      assert {:ok, _, _} = Diplomacy.declare_war(Diplomacy.new(factions(), plain), 1, 2)
    end
  end
end

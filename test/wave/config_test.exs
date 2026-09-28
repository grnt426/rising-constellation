defmodule Wave.ConfigTest do
  @moduledoc """
  The runtime switches that scope every Wave Defense bypass to the bot faction.
  Each test registers real per-instance metadata (the same cache the engine
  reads) so the reads go through `Data.Data`, not a stub.
  """
  use ExUnit.Case, async: true

  alias Instance.StellarSystem.{ProductionQueue, StellarSystem}
  alias Test.FleetScenario

  setup do
    wave_iid = System.unique_integer([:positive])
    plain_iid = System.unique_integer([:positive])

    FleetScenario.load_game_data(wave_iid,
      speed: :slow,
      mode: :prod,
      wave: true,
      wave_config: %{"bot_faction" => "rebellion", "max_systems_bonus" => 7, "ai_interval_ut" => 2.5}
    )

    FleetScenario.load_game_data(plain_iid, speed: :slow, mode: :prod)

    {:ok, wave: wave_iid, plain: plain_iid}
  end

  test "only the wave instance reports wave mode and a bot faction", %{wave: wave, plain: plain} do
    assert Wave.Config.enabled?(wave)
    refute Wave.Config.enabled?(plain)
    refute Wave.Config.enabled?(System.unique_integer([:positive]))

    assert Wave.Config.bot_faction(wave) == :rebellion
    assert Wave.Config.bot_faction(plain) == nil
  end

  test "knobs merge the instance's values over the shipped defaults", %{wave: wave} do
    assert Wave.Config.knob(wave, "max_systems_bonus") == 7
    assert Wave.Config.knob(wave, "hire_interval_ut") == Wave.defaults()["hire_interval_ut"]
    assert Wave.Config.knob(wave, "not_a_knob", :fallback) == :fallback
  end

  test "cap bonuses lift systems, dominions and every agent type", %{wave: wave} do
    by_target = Map.new(Wave.Config.player_bonuses(wave), &{&1.bonus.to, &1.bonus})

    assert %Core.Bonus{from: :direct, type: :add, value: 7} = by_target[:player_system]
    assert by_target[:player_dominion].value == Wave.defaults()["max_dominions_bonus"]
    assert Map.keys(by_target) |> Enum.sort() ==
             Enum.sort([:player_system, :player_dominion, :player_admiral, :player_spy, :player_speaker])
  end

  test "bankruptcy immunity is the bot faction's alone", %{wave: wave, plain: plain} do
    assert Wave.Config.bankruptcy_exempt?(%{instance_id: wave, faction: :rebellion})
    refute Wave.Config.bankruptcy_exempt?(%{instance_id: wave, faction: :tetrarchy})
    refute Wave.Config.bankruptcy_exempt?(%{instance_id: plain, faction: :rebellion})
  end

  describe "system AI routing" do
    test "rebel systems and dominions run the Rebel Dominion tree on the fast cadence", %{wave: wave} do
      assert Wave.Config.system_ai(system(wave, :inhabited_player, :rebellion), 50) == {:rebel_dominion, 2.5}
      assert Wave.Config.system_ai(system(wave, :inhabited_dominion, :rebellion), 50) == {:rebel_dominion, 2.5}
    end

    test "everything else keeps the vanilla behaviour", %{wave: wave, plain: plain} do
      assert Wave.Config.system_ai(system(wave, :inhabited_neutral, nil), 50) == {:dominion, 50}
      assert Wave.Config.system_ai(system(wave, :inhabited_dominion, :tetrarchy), 50) == {:dominion, 50}
      assert Wave.Config.system_ai(system(wave, :inhabited_player, :tetrarchy), 50) == nil
      assert Wave.Config.system_ai(system(wave, :uninhabited, nil), 50) == nil

      # a faction called "rebellion" outside a wave game gets no special treatment
      assert Wave.Config.system_ai(system(plain, :inhabited_player, :rebellion), 50) == nil
    end

    test "an idle rebel system still wakes for its next AI turn", %{wave: wave} do
      rebel = %{system(wave, :inhabited_player, :rebellion) | ai_next_action: Core.DynamicValue.new(0.5)}
      assert StellarSystem.compute_next_tick_interval(rebel) == 2.0

      # vanilla scheduling is untouched: an idle neutral system with a flat
      # population still never wakes on its own
      neutral = system(wave, :inhabited_neutral, nil)
      assert StellarSystem.compute_next_tick_interval(neutral) == :never
    end
  end

  defp system(instance_id, status, faction) do
    struct(StellarSystem, %{
      id: 1,
      instance_id: instance_id,
      status: status,
      owner: faction && %{id: 1, name: "owner", faction: faction, faction_id: 1},
      queue: ProductionQueue.new(),
      population: Core.DynamicValue.new(0.0),
      production: %Core.Value{value: 10, details: %{}},
      ai_next_action: Core.DynamicValue.new(0.0),
      bodies: []
    })
  end
end

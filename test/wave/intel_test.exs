defmodule Wave.IntelTest do
  use ExUnit.Case, async: true

  alias Wave.Intel

  describe "visibility" do
    test "a stored contact carries through untouched on neutral ground" do
      assert Intel.visibility(3) == 3
      assert Intel.visibility(nil) == 0
    end

    test "an agent standing in a system is worth two, and owning it is worth everything" do
      assert Intel.visibility(0, own_agent?: true) == 2
      assert Intel.visibility(4, own_agent?: true) == 4
      assert Intel.visibility(0, own_system?: true) == 5
    end

    test "war fogs an enemy system by one and a pact opens it by one" do
      assert Intel.visibility(3, stance: :war) == 2
      assert Intel.visibility(3, stance: :non_aggression) == 4
      assert Intel.visibility(0, stance: :war) == 0
      assert Intel.visibility(5, stance: :non_aggression) == 5
    end

    test "our own systems ignore the stance — this is the Erased's one reliable window" do
      assert Intel.visibility(0, own_system?: true, stance: :war) == 5
    end

    test "an agent alone in an enemy system at war still can't read the room" do
      # The engine applies the war modifier after the agent minimum, so a lone
      # Erased sees 1 — below the tier where a system's character list exists.
      assert Intel.visibility(0, own_agent?: true, stance: :war) == 1
      refute Intel.visible?(:identity, 1)
      assert Intel.visible?(:identity, 2)
    end
  end

  describe "visible?" do
    test "matches the engine's own obfuscation tiers" do
      assert Intel.visible?(:identity, 2)
      refute Intel.visible?(:protection, 4)
      assert Intel.visible?(:protection, 5)
      assert Intel.visible?(:ship_keys, 4)
      refute Intel.visible?(:ship_keys, 3)
      # Faction.StellarSystem.obfuscate/4: happiness one tier before Intelligence.
      assert Intel.visible?(:happiness, 3)
      refute Intel.visible?(:happiness, 2)
      refute Intel.visible?(:determination, 3)
    end

    test "an unknown field is never legible" do
      refute Intel.visible?(:whatever, 5)
      refute Intel.visible?(:identity, nil)
    end
  end

  describe "success_chance" do
    test "an even match with no level bonus is a coin flip" do
      assert_in_delta Intel.success_chance(100, 0, 100), 0.5, 1.0e-9
    end

    test "a hopeless attack is certain failure and an overwhelming one certain success" do
      assert Intel.success_chance(1, 0, 1000) == 0.0
      assert Intel.success_chance(1000, 0, 1) == 1.0
    end

    test "level shifts the whole band up" do
      even = Intel.success_chance(100, 0, 100)
      levelled = Intel.success_chance(100, 10, 100)
      assert levelled > even
    end

    test "a band with both defences at zero is the engine's 0.5 ratio" do
      assert_in_delta Intel.success_chance(0, 0, 0), 0.5, 1.0e-9
    end
  end

  describe "attempt_chance" do
    test "an unreadable defence is a flat gamble" do
      assert Intel.attempt_chance(nil) == 0.2
      assert Intel.attempt_chance(nil, %{"unknown" => 0.35}) == 0.35
    end

    test "an even chance is an even appetite, and it climbs steeply either side" do
      assert_in_delta Intel.attempt_chance(0.5), 0.5, 1.0e-9
      assert Intel.attempt_chance(0.65) > 0.8
      assert Intel.attempt_chance(0.35) < 0.2
      assert Intel.attempt_chance(0.9) > 0.99
    end

    test "steepness is a knob" do
      flat = Intel.attempt_chance(0.6, %{"steepness" => 1.0})
      steep = Intel.attempt_chance(0.6, %{"steepness" => 30.0})
      assert steep > flat
    end

    test "atom-keyed knobs work too — a map built in code never round-tripped through jsonb" do
      assert Intel.attempt_chance(nil, %{unknown: 0.4}) == 0.4
    end
  end

  test "odds_class labels a chance for the logs" do
    assert Intel.odds_class(nil) == :unknown
    assert Intel.odds_class(0.1) == :poor
    assert Intel.odds_class(0.5) == :even
    assert Intel.odds_class(0.9) == :good
  end
end

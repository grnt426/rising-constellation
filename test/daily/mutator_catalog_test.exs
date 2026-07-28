defmodule Daily.MutatorCatalogTest do
  use ExUnit.Case, async: true

  # Shape and integrity checks for the mutator catalog after the daily
  # expansion batch (docs/daily-challenge-ideas.md): every entry carries the
  # generator tags (polarity / daily_eligible / axis), every wired on_bonus
  # entry routes through real pipeline keys, and the boon/bane pairs the
  # axis-conflict rule exists to separate actually share an axis.

  alias Data.Game.Mutator

  @wired_boons ~w(
    prosperous_masses joyful_industry festival_days panopticon
    veteran_shipwrights open_court expansion_charter field_docks
    cheap_steel silver_tongues ghost_protocols
  )a

  @wired_banes ~w(
    hungry_mouths crowded_slums sullen_populace blind_watch
    porous_borders brittle_hulls
  )a

  test "every catalog entry carries the generator tags" do
    for entry <- Mutator.catalog() do
      assert entry.polarity in [:positive, :negative], "#{entry.key} has no polarity"
      assert is_boolean(entry.daily_eligible), "#{entry.key} has no daily_eligible"
      assert is_atom(entry.axis) and not is_nil(entry.axis), "#{entry.key} has no axis"
      assert is_atom(entry.hook)
      assert is_boolean(entry.implemented)
    end
  end

  test "the daily expansion batch is wired and in the rotation" do
    for key <- @wired_boons ++ @wired_banes do
      entry = Mutator.get(key)
      assert entry, "#{key} missing from catalog"
      assert entry.implemented, "#{key} should be implemented"
      assert entry.daily_eligible, "#{key} should be daily-eligible"
      assert entry.hook == :on_bonus
      assert Mutator.bonuses(key) != [], "#{key} should inject at least one bonus"
    end

    polarity = fn keys -> Enum.map(keys, &Mutator.get(&1).polarity) |> Enum.uniq() end
    assert polarity.(@wired_boons) == [:positive]
    assert polarity.(@wired_banes) == [:negative]
  end

  test "every bonus of every implemented mutator uses real pipeline keys" do
    in_keys = Enum.map(Data.Game.BonusPipelineIn.Content.data(), & &1.key)
    out_keys = Enum.map(Data.Game.BonusPipelineOut.Content.data(), & &1.key)

    for entry <- Mutator.implemented() do
      bonuses = Mutator.bonuses(entry.key)

      if entry.hook == :on_bonus do
        assert bonuses != [], "#{entry.key} is a wired on_bonus mutator with no bonus"
      end

      for bonus <- bonuses do
        assert %Core.Bonus{} = bonus, "#{entry.key}: non-Core.Bonus entry"
        assert bonus.from in in_keys, "#{entry.key}: unknown pipeline input #{bonus.from}"
        assert bonus.to in out_keys, "#{entry.key}: unknown pipeline output #{bonus.to}"
        assert bonus.type in [:add, :mul]
        assert is_number(bonus.value)
      end
    end
  end

  test "on_cost mutators are wired and in the rotation" do
    for key <- [:subsidized_yards, :open_science, :lost_sciences] do
      entry = Mutator.get(key)
      assert entry.implemented, "#{key} should be implemented"
      assert entry.daily_eligible
      assert entry.hook == :on_cost
    end

    # open_science (boon) and lost_sciences (bane) share the :patent_cost axis,
    # so the generator can never roll both — the pairing rule holds.
    assert Mutator.get(:open_science).axis == :patent_cost
    assert Mutator.get(:lost_sciences).axis == :patent_cost
  end

  test "on_xp mutators are wired and in the rotation" do
    for key <- [:prodigies, :inexperienced_court] do
      entry = Mutator.get(key)
      assert entry.implemented, "#{key} should be implemented"
      assert entry.daily_eligible
      assert entry.hook == :on_xp
    end

    # boon + bane share the :agent_xp axis, so they never roll together
    assert Mutator.get(:prodigies).axis == :agent_xp
    assert Mutator.get(:inexperienced_court).axis == :agent_xp
  end

  describe "xp_multiplier/2" do
    test "Prodigies doubles XP for every character status" do
      assert Mutator.xp_multiplier([:prodigies], :on_board) == 2.0
      assert Mutator.xp_multiplier([:prodigies], :governor) == 2.0
    end

    test "Inexperienced Court slows only governors" do
      assert Mutator.xp_multiplier([:inexperienced_court], :governor) == 0.5
      assert Mutator.xp_multiplier([:inexperienced_court], :on_board) == 1.0
    end

    test "no on_xp mutator means no change" do
      assert Mutator.xp_multiplier([], :governor) == 1.0
      assert Mutator.xp_multiplier([:bull_market], :on_board) == 1.0
    end

    test "the boon and bane compose (never rolled together, but the math holds)" do
      assert Mutator.xp_multiplier([:prodigies, :inexperienced_court], :governor) == 1.0
      assert Mutator.xp_multiplier([:prodigies, :inexperienced_court], :on_board) == 2.0
    end
  end

  describe "cost_multiplier/2" do
    test "each on_cost mutator scales its own cost kind" do
      assert Mutator.cost_multiplier([:open_science], :patent) == 0.5
      assert Mutator.cost_multiplier([:lost_sciences], :patent) == 2.0
      assert Mutator.cost_multiplier([:subsidized_yards], :ship_production) == 0.5
    end

    test "a mutator that doesn't touch this kind leaves the cost alone" do
      assert Mutator.cost_multiplier([:subsidized_yards], :patent) == 1.0
      assert Mutator.cost_multiplier([:open_science], :ship_production) == 1.0
      assert Mutator.cost_multiplier([:bull_market], :patent) == 1.0
    end

    test "no active mutators means no change" do
      assert Mutator.cost_multiplier([], :patent) == 1.0
      assert Mutator.cost_multiplier([], :ship_production) == 1.0
    end

    test "multiple matching mutators compose multiplicatively" do
      # they'd never roll together (shared axis), but the math must still hold
      assert Mutator.cost_multiplier([:open_science, :lost_sciences], :patent) == 1.0
    end
  end

  test "the_bequest_estate is a pinned package mutator, never rolled at random" do
    entry = Mutator.get(:the_bequest_estate)
    assert entry.implemented
    refute entry.daily_eligible
    # the fortune override + the drain bonus
    assert Mutator.credit_override([:the_bequest_estate]) == 100_000_000
    assert Mutator.credit_override([:bull_market]) == nil
    assert [%Core.Bonus{to: :player_credit, type: :add, value: value}] = Mutator.bonuses(:the_bequest_estate)
    assert value < 0
  end

  test "bonuses/1 normalizes single- and multi-lever entries" do
    # single `bonus:` field → list of one
    assert [%Core.Bonus{}] = Mutator.bonuses(:bull_market)
    assert Mutator.bonuses(:bull_market) == [Mutator.bonus(:bull_market)]

    # multi-lever entries carry several
    assert length(Mutator.bonuses(:panopticon)) == 2
    assert length(Mutator.bonuses(:veteran_shipwrights)) == 4
    assert length(Mutator.bonuses(:open_court)) == 3

    # no pipeline effect / unknown key → []
    assert Mutator.bonuses(:worlds_of_plenty) == []
    assert Mutator.bonuses(:no_such_mutator) == []

    # accepts the string form game_data jsonb delivers
    assert length(Mutator.bonuses("panopticon")) == 2
  end

  test "opposing boon/bane pairs share an axis, so the roll can never pair them" do
    pairs = [
      {:enlightened_age, :luddite_backlash},
      {:zealous_fervor, :crisis_of_faith},
      {:bull_market, :heavy_tithes},
      {:prosperous_masses, :hungry_mouths},
      {:industrial_surge, :failing_reactors},
      {:joyful_industry, :failing_reactors},
      {:festival_days, :sullen_populace},
      {:panopticon, :blind_watch},
      {:field_docks, :brittle_hulls},
      {:open_court, :closed_borders},
      {:prodigies, :inexperienced_court},
      {:open_science, :lost_sciences},
      {:worlds_of_plenty, :hardscrabble_worlds}
    ]

    for {boon, bane} <- pairs do
      b = Mutator.get(boon)
      n = Mutator.get(bane)
      assert b.polarity == :positive and n.polarity == :negative
      assert b.axis == n.axis, "#{boon} and #{bane} should share an axis"
    end
  end

  test "teeming_masses stays a forge roadmap entry, out of the daily rotation" do
    entry = Mutator.get(:teeming_masses)
    refute entry.daily_eligible
    refute entry.implemented
  end
end

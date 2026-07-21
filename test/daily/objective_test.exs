defmodule Daily.ObjectiveTest do
  use ExUnit.Case, async: true

  alias Daily.Objective

  test "catalog covers the ten goals and has unique keys" do
    keys = Objective.keys()
    assert length(keys) == 10
    assert length(Enum.uniq(keys)) == 10
  end

  test "the_bequest scores stored credit, ties break on credit income" do
    stats = %{stored_credit: 99_850_000, output_credit: 120}
    assert %{score: 99_850_000.0, tiebreak: 120.0} = Objective.evaluate(:the_bequest, stats)

    # its package pins the estate mutator instead of the usual roll
    assert Objective.get(:the_bequest).package_mutators == [:the_bequest_estate]
  end

  test "every objective declares a scoring mode" do
    for o <- Objective.catalog() do
      assert o.mode in [:max_stat, :composite, :race], "#{o.key} has no valid mode"
      if o.mode == :max_stat, do: assert(is_atom(o.stat_field) and o.stat_field != nil)
      if o.mode == :race, do: assert(is_map(o.race) and map_size(o.race) > 0)
    end
  end

  test "get/1 resolves atoms and strings, nil otherwise" do
    assert Objective.get(:coffers_of_the_realm).resource == :credit
    assert Objective.get("coffers_of_the_realm").resource == :credit
    assert Objective.get(:nope) == nil
    assert Objective.get(nil) == nil
  end

  test "total objectives read the stored balance" do
    stats = %{stored_credit: 12_345, output_credit: 7}
    assert Objective.score(:coffers_of_the_realm, stats) == 12_345
  end

  test "income objectives read the per-tick rate" do
    stats = %{output_technology: 88, stored_technology: 9000}
    assert Objective.score(:tide_of_invention, stats) == 88
  end

  test "production objective reads best_prod" do
    assert Objective.score(:forge_unceasing, %{best_prod: 42}) == 42
  end

  test "string-keyed stats also work" do
    assert Objective.score(:golden_flow, %{"output_credit" => 5}) == 5
  end

  test "missing data and unknown objectives score 0, never crash" do
    assert Objective.score(:coffers_of_the_realm, %{}) == 0
    assert Objective.score(:does_not_exist, %{stored_credit: 1}) == 0
    assert Objective.score(nil, %{stored_credit: 1}) == 0
  end

  describe "the_triumvirate (composite)" do
    test "scores the lowest of the three incomes, ties break on the sum" do
      stats = %{output_credit: 500, output_technology: 60, output_ideology: 45}
      assert %{score: 45.0, tiebreak: 605.0} = Objective.evaluate(:the_triumvirate, stats)
    end

    test "a missing income is a zero score no matter how big the others are" do
      stats = %{output_credit: 9_999, output_technology: 9_999}
      assert %{score: 0.0} = Objective.evaluate(:the_triumvirate, stats)
    end
  end

  # The race predicate reads per-system income summaries; any map with a
  # stellar_systems list works (same shape as Instance.Player.StellarSystem).
  defp player_with(systems), do: %{stellar_systems: systems}

  describe "charter_of_prosperity (race)" do
    test "completes only when a SINGLE system meets all three thresholds at once" do
      objective = Objective.get(:charter_of_prosperity)

      met = player_with([%{credit: 800.0, technology: 50.0, ideology: 40.0}])
      assert Objective.race_completed?(objective, met)

      # empire-wide totals meeting the bar across two systems do not count
      split =
        player_with([
          %{credit: 900.0, technology: 60.0, ideology: 10.0},
          %{credit: 100.0, technology: 5.0, ideology: 45.0}
        ])

      refute Objective.race_completed?(objective, split)
    end

    test "progress is the best system's bottleneck ratio, clamped to 1" do
      objective = Objective.get(:charter_of_prosperity)

      # 400/800 = 0.5 is the bottleneck even though the others exceed target
      player = player_with([%{credit: 400.0, technology: 200.0, ideology: 200.0}])
      assert Objective.race_progress(objective, player) == 0.5

      assert Objective.race_progress(objective, player_with([])) == 0.0
      assert Objective.race_progress(objective, nil) == 0.0
    end

    test "the deadline path scores 0 with progress as the tiebreak" do
      objective = Objective.get(:charter_of_prosperity)
      player = player_with([%{credit: 200.0, technology: 50.0, ideology: 40.0}])

      assert %{score: 0.0, tiebreak: 0.25} = Objective.evaluate(objective, %{}, player)
    end

    test "non-race objectives never complete a race" do
      refute Objective.race_completed?(Objective.get(:golden_flow), player_with([]))
      refute Objective.race_completed?(nil, player_with([]))
    end
  end
end

defmodule Daily.ObjectiveTest do
  use ExUnit.Case, async: true

  alias Daily.Objective

  test "catalog covers the seven goals and has unique keys" do
    keys = Objective.keys()
    assert length(keys) == 7
    assert length(Enum.uniq(keys)) == 7
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
end

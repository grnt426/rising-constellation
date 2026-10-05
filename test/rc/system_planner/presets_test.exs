defmodule RC.SystemPlanner.PresetsTest do
  use ExUnit.Case, async: false

  alias RC.SystemPlanner
  alias RC.SystemPlanner.Presets

  # What the page posts to /api/system-planner/compute for a plan
  # (computePayload in front/src/portal/planner/plan.js).
  defp payload(plan) do
    plan
    |> Map.take(~w(speed faction capital population bodies governor))
    |> Map.put("lexes", plan["active_lexes"] || [])
  end

  defp compute!(name) do
    {:ok, plan} = Presets.fetch(name)
    {:ok, %{system: system}} = SystemPlanner.compute(payload(plan))
    system
  end

  test "the help manual's three example systems are there" do
    assert Presets.names() == ~w(basics-early basics-late basics-mid)
    assert Presets.fetch("nope") == :error
    assert Presets.fetch(nil) == :error
  end

  test "every preset is a plan the page imports and the game computes" do
    for name <- Presets.names() do
      {:ok, plan} = Presets.fetch(name)
      assert plan["format"] == "tf-system-plan", name
      assert plan["version"] == 1, name
      assert is_binary(plan["name"]), name
      assert is_list(plan["patents"]), name
      assert {:ok, %{system: system}} = SystemPlanner.compute(payload(plan)), name
      assert system.population_status == :normal, name
    end
  end

  # The Basics of Play pages (priv/help/en/basics/) describe the example
  # system in words: these are the figures those sentences rest on. If a
  # balance change moves them, reread the three "example system" sections.
  test "the example system is what the manual says about it" do
    early = compute!("basics-early")
    mid = compute!("basics-mid")
    late = compute!("basics-late")

    # "Technology has doubled since day five", "nearly doubled again"
    assert mid.technology.value >= 2 * early.technology.value
    assert late.technology.value >= 1.9 * mid.technology.value
    # "Ideology has grown even more"
    assert mid.ideology.value / early.ideology.value > mid.technology.value / early.technology.value
    # "Only 64 of 90 workforce is in use"
    assert {late.used_workforce, late.workforce} == {64, 90}

    {:ok, plan} = Presets.fetch("basics-late")
    # the governor is a Siderian with 11 points in Knowledge (the "scholar" skill)
    assert %{"type" => "speaker", "skills" => [_, _, _, _, 11, _]} = plan["governor"]
  end
end

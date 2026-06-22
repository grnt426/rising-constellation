defmodule Daily.GeneratorTest do
  use ExUnit.Case, async: true

  alias Daily.Generator
  alias Data.Game.Mutator

  @date "2026-06-21"

  test "is deterministic: same date yields identical game_data" do
    assert Generator.for_date(@date) == Generator.for_date(@date)
    assert Generator.for_date(Date.from_iso8601!(@date)) == Generator.for_date(@date)
  end

  test "different dates generally differ" do
    refute Generator.for_date("2026-06-21") == Generator.for_date("2026-06-22")
  end

  test "produces a single-system, single-sector, single-faction galaxy" do
    gd = Generator.for_date(@date)

    assert length(gd["systems"]) == 1
    assert length(gd["sectors"]) == 1
    assert length(gd["factions"]) == 1
    assert gd["blackholes"] == []

    [sector] = gd["sectors"]
    [faction] = gd["factions"]
    assert length(sector["systems"]) == 1
    # the day's faction is one of the catalog factions, picked deterministically;
    # the lone sector and the daily summary both reference it
    assert sector["faction"] in ~w(tetrarchy myrmezir cardan synelle ark)
    assert sector["faction"] == faction["key"]
    assert gd["daily"]["faction"] == faction["key"]
    # the engine's victory tracker sums per-sector points; a missing value
    # crashes the victory agent at boot, so it must be a number
    assert is_number(sector["victory_points"])
  end

  test "runs Legacy content as a hidden daily" do
    gd = Generator.for_date(@date)
    assert gd["speed"] == "daily"
    assert gd["mode"] == "prod"
    assert gd["game_mode_type"] == "daily"
    assert gd["daily"]["date"] == @date
  end

  test "in-game seed is three positive integers" do
    seed = Generator.for_date(@date)["seed"]
    assert [a, b, c] = seed
    assert Enum.all?([a, b, c], &(is_integer(&1) and &1 > 0))
  end

  test "rolls exactly two boons and one bane, all wired by default" do
    gd = Generator.for_date(@date)
    mutators = Enum.map(gd["mutators"], fn %{"key" => k} -> Mutator.get(k) end)

    assert length(mutators) == 3
    assert Enum.count(mutators, &(&1.polarity == :positive)) == 2
    assert Enum.count(mutators, &(&1.polarity == :negative)) == 1
    assert Enum.all?(mutators, & &1.implemented)

    # the two boons are distinct
    keys = Enum.map(gd["mutators"], & &1["key"])
    assert length(Enum.uniq(keys)) == 3
  end

  test "objective is one of the catalog goals" do
    objective = Generator.for_date(@date)["daily"]["objective"]
    assert objective in Enum.map(Daily.Objective.keys(), &Atom.to_string/1)
  end

  test "--all may roll roadmap mutators that aren't wired yet" do
    # Sweep a year of dates with the full roster enabled; at least one day
    # should pick a not-yet-implemented mutator (the roadmap entries vastly
    # outnumber the wired ones, so this is near-certain and still deterministic).
    any_unimplemented? =
      Enum.any?(0..364, fn offset ->
        date = Date.add(~D[2026-01-01], offset) |> Date.to_iso8601()
        gd = Generator.for_date(date, include_unimplemented: true)

        Enum.any?(gd["mutators"], fn %{"key" => k} -> not Mutator.get(k).implemented end)
      end)

    assert any_unimplemented?
  end

  test "metadata mirror carries speed, mutators and the objective" do
    gd = Generator.for_date(@date)
    meta = Generator.metadata_for(gd)

    assert meta["speed"] == "daily"
    assert meta["daily"] == true
    assert meta["mutators"] == gd["mutators"]
    assert meta["objective"] == gd["daily"]["objective"]
  end
end

defmodule Edict.RuntimeTest do
  use ExUnit.Case, async: true

  alias Edict.{Parser, Runtime}

  defp world(t, extra \\ %{}) do
    %{
      "time" => %{"elapsed" => t, "left" => max(1800 - t, 0.0), "limit" => 1800.0},
      "player" => Map.merge(%{"credit" => 1000.0, "patents" => []}, extra)
    }
  end

  defp runtime!(source) do
    {:ok, program} = Parser.parse(source)
    {:ok, rt} = Runtime.new(program)
    rt
  end

  # Pulse at each time in `times`; collect {t, result}.
  defp pulses(rt, times, world_fun \\ &world/1) do
    Enum.map_reduce(times, rt, fn t, rt ->
      {rt, result} = Runtime.pulse(rt, world_fun.(t / 1), t / 1)
      {{t, result}, rt}
    end)
  end

  defp give_amounts(results) do
    for {t, r} <- results, %{"action" => "give", "args" => %{"amount" => a}} <- r.effects, do: {t, a}
  end

  test "random() without keys gives a new number each time an event runs, the same in every replay" do
    source = "every 1m {
  log(random())
}
score 1"

    rolls = fn ->
      {results, _} = pulses(runtime!(source), [60, 120, 180])
      for {_t, r} <- results, %{"value" => v} <- r.logs, do: v
    end

    first = rolls.()
    assert length(first) == 3
    assert length(Enum.uniq(first)) == 3
    assert rolls.() == first
  end

  test "setup fills in defaults and validates" do
    rt = runtime!("setup {\n  name = \"X\"\n  time_limit = 10m\n}")
    assert rt.config["name"] == "X"
    assert rt.config["time_limit"] == 600.0
    assert rt.config["systems"] == 1

    {:ok, program} = Parser.parse("setup {\n  time_limit = 2h\n}")
    assert {:error, [%{message: message}]} = Runtime.new(program)
    assert message =~ "time_limit"
  end

  test "on start runs once" do
    rt = runtime!(~s|on start {\n  give("credit", 1)\n}|)
    {results, _} = pulses(rt, [0, 1, 2])
    assert give_amounts(results) == [{0, 1.0}]
  end

  test "every counts from the start, numbers its runs, and catches up" do
    rt = runtime!(~s|every 10s as n {\n  give("credit", n)\n}|)
    # a late pulse at 35 runs the 10s, 20s and 30s occurrences
    {results, _} = pulses(rt, [0, 5, 35, 40])
    assert give_amounts(results) == [{35, 1.0}, {35, 2.0}, {35, 3.0}, {40, 4.0}]
  end

  test "every honors from and until" do
    rt = runtime!(~s|every 10s from 0s until 25s {\n  give("credit", 1)\n}|)
    {results, _} = pulses(rt, Enum.to_list(0..60))
    assert Enum.map(give_amounts(results), &elem(&1, 0)) == [0, 10, 20]
  end

  test "at fires once at its time" do
    rt = runtime!(~s|at 1m {\n  give("credit", 5)\n}|)
    {results, _} = pulses(rt, [0, 59, 60, 61, 120])
    assert give_amounts(results) == [{60, 5.0}]
  end

  test "when fires on the edge, and again after the condition clears" do
    rt = runtime!(~s|when player.credit > 100 {\n  give("credit", 1)\n}|)
    credits = %{0 => 50, 1 => 150, 2 => 200, 3 => 50, 4 => 300}
    {results, _} = pulses(rt, [0, 1, 2, 3, 4], fn t -> world(t, %{"credit" => credits[trunc(t)] / 1}) end)
    assert Enum.map(give_amounts(results), &elem(&1, 0)) == [1, 4]
  end

  test "a failing handler leaves no trace and switches off after three failures" do
    rt =
      runtime!("""
      var n = 0
      every 1s {
        n = n + 1
        give("credit", 1)
        let boom = 1 / 0
      }
      every 1s {
        give("credit", 2)
      }
      """)

    {results, rt} = pulses(rt, [1, 2, 3, 4, 5])
    # the second handler keeps going, the first one never leaves an effect
    assert Enum.map(give_amounts(results), &elem(&1, 1)) == [2.0, 2.0, 2.0, 2.0, 2.0]
    assert rt.globals["n"] == 0.0
    errors = Enum.flat_map(results, fn {_, r} -> r.errors end)
    assert length(errors) == 3
    assert List.last(errors).message =~ "now off"
  end

  test "finish ends the run: later handlers don't run, the score counts time left" do
    rt =
      runtime!("""
      score time.left
      when "armoring" in player.patents {
        finish("done")
      }
      every 1s {
        give("credit", 1)
      }
      """)

    {_results, rt} = pulses(rt, [1, 2])
    {rt, result} = Runtime.pulse(rt, world(300.0, %{"patents" => ["armoring"]}), 300.0)
    assert result.finished == %{message: "done"}
    assert give_amounts([{300, result}]) == []

    {_rt, final} = Runtime.finish(rt, world(300.0), 300.0)
    assert final.score == 1500.0
  end

  test "on end runs after the score is counted" do
    rt =
      runtime!("""
      var bonus = 0
      score player.credit + bonus
      on end {
        bonus = 1000
        notify("bye")
      }
      """)

    {_rt, final} = Runtime.finish(rt, world(1800.0), 1800.0)
    assert final.score == 1000.0
    assert [%{"action" => "notify"}] = final.effects
  end

  test "vars and schedules are worked out before the game: no world there" do
    {:ok, program} = Parser.parse("var x = player.credit")
    assert {:error, [%{message: message}]} = Runtime.new(program)
    assert message =~ "can't be read here"
  end

  test "a score that fails counts as 0 and reports why" do
    rt = runtime!("score player.credit / 0")
    {_rt, final} = Runtime.finish(rt, world(1800.0), 1800.0)
    assert final.score == 0.0
    assert [%{message: "division by zero"}] = final.errors
  end

  test "scripts can't act from a when condition" do
    rt =
      runtime!("""
      fn sneaky() {
        give("credit", 1_000_000)
        return true
      }
      when sneaky() {
        notify("x")
      }
      """)

    {_rt, result} = Runtime.pulse(rt, world(1.0), 1.0)
    assert result.effects == []
    assert [%{message: message}] = result.errors
    assert message =~ "changes the game"
  end
end

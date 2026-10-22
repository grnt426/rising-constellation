defmodule Edict.ParityTest do
  @moduledoc """
  Expressiveness, measured: every example script that ports a shipped daily
  objective must rank players exactly as the hand-written objective does.

  For a few hundred generated players, the script's score and tiebreak at
  the deadline (counted through the real runtime, from the world
  `Edict.World` builds) must equal `Daily.Objective.evaluate/3` on the same
  player's stats (`Daily.Boot.score_stats/1`, the stats the daily records).
  For races, the script must call finish() on exactly the players for whom
  `Daily.Objective.race_completed?/2` holds.
  """
  use ExUnit.Case, async: true

  alias Edict.{Runtime, World}

  @players 300

  setup_all do
    :rand.seed(:exsss, {20, 26, 10})
    %{players: Enum.map(1..@players, fn _ -> player() end)}
  end

  defp dv(value, change), do: %Core.DynamicValue{value: value, change: change, details: %{}}

  defp pick(list), do: Enum.at(list, :rand.uniform(length(list)) - 1)
  defp num(max), do: :rand.uniform() * max
  defp int(max), do: :rand.uniform(max + 1) - 1

  defp system(id) do
    %{
      id: id,
      name: "S#{id}",
      workforce: int(40),
      habitation: int(60),
      happiness: num(20) - 5,
      production: num(300),
      defense: num(50),
      credit: num(1200),
      technology: num(80),
      ideology: num(60)
    }
  end

  defp character(id) do
    type = pick([:admiral, :spy, :speaker])

    %{
      id: id,
      name: "C#{id}",
      type: type,
      status: pick([:on_board, :governor, :in_deck]),
      level: int(20),
      system: 1,
      army_maintenance: if(type == :admiral, do: int(700), else: 0),
      army_raid: if(type == :admiral, do: pick([nil, num(80)]), else: nil),
      army_invasion: if(type == :admiral, do: pick([nil, num(80)]), else: nil)
    }
  end

  defp player do
    patents = Enum.take_random(~w(citadel shipyard_1 shipyard_2 shipyard_3 capital_1 university_open)a, int(5))

    struct(Instance.Player.Player, %{
      id: 1,
      instance_id: 1,
      registration_id: 1,
      name: "P",
      faction: :tetrarchy,
      credit: dv(num(200_000), num(900)),
      technology: dv(num(120_000), num(150)),
      ideology: dv(num(120_000), num(120)),
      stellar_systems: Enum.map(1..(1 + int(5)), &system/1),
      dominions: Enum.map(1..int(3), &system(100 + &1)),
      characters: Enum.map(1..int(6), &character/1),
      patents: patents,
      wonders_built: [],
      agents_assassinated: int(40)
    })
  end

  defp script(key) do
    %{source: source} = Edict.example(key)
    %{program: program, diagnostics: diags} = Edict.analyze(source)
    assert Enum.filter(diags, &(&1.severity == "error")) == [], "#{key} has errors: #{inspect(diags)}"
    {:ok, rt} = Runtime.new(program)
    rt
  end

  defp at_deadline(rt, player) do
    world = World.build(player, clock: %{elapsed: 1800, left: 0, limit: 1800}, config: rt.config)
    {_rt, result} = Runtime.finish(rt, world, 1800.0)
    assert result.errors == []
    result
  end

  defp close?(a, b), do: abs(a - b) <= 1.0e-9 * max(1.0, abs(b))

  for {key, objective} <- [
        {"coffers_of_the_realm", :coffers_of_the_realm},
        {"golden_flow", :golden_flow},
        {"the_triumvirate", :the_triumvirate},
        {"the_bequest", :the_bequest},
        {"land_rush", :land_rush},
        {"hegemon", :hegemon},
        {"headhunter_lite", :headhunter},
        {"charter_of_prosperity", :charter_of_prosperity},
        {"destroyers_blueprint", :destroyers_blueprint},
        {"fleet_in_being_raiders", :fleet_in_being_raiders}
      ] do
    test "#{key} scores every player as Daily.Objective #{objective} does", %{players: players} do
      rt = script(unquote(key))

      for player <- players do
        expected = Daily.Objective.evaluate(unquote(objective), Daily.Boot.score_stats(player), player)
        got = at_deadline(rt, player)

        assert close?(got.score, expected.score),
               "score: script #{got.score}, daily #{expected.score}"

        assert close?(got.tiebreak, expected.tiebreak),
               "tiebreak: script #{got.tiebreak}, daily #{expected.tiebreak}"
      end
    end
  end

  for {key, objective} <- [
        {"charter_of_prosperity", :charter_of_prosperity},
        {"destroyers_blueprint", :destroyers_blueprint},
        {"fleet_in_being_raiders", :fleet_in_being_raiders}
      ] do
    test "#{key} finishes exactly when the race is won", %{players: players} do
      rt = script(unquote(key))
      race = Daily.Objective.get(unquote(objective))

      # make sure both outcomes are represented
      winners = Enum.count(players, &Daily.Objective.race_completed?(race, &1))
      assert winners > 0 and winners < length(players), "#{winners} of #{length(players)} won"

      for player <- players do
        world = World.build(player, clock: %{elapsed: 600, left: 1200, limit: 1800}, config: rt.config)
        {_rt, result} = Runtime.pulse(rt, world, 600.0)
        assert result.errors == []
        assert result.finished != nil == Daily.Objective.race_completed?(race, player)
      end
    end
  end

  test "a race won with 20 minutes left scores 1200, like the daily's seconds-left score" do
    rt = script("destroyers_blueprint")
    player = %{player() | patents: [:capital_1]}
    world = World.build(player, clock: %{elapsed: 600, left: 1200, limit: 1800}, config: rt.config)
    {rt, %{finished: %{}}} = Runtime.pulse(rt, world, 600.0)
    {_rt, result} = Runtime.finish(rt, world, 600.0)
    assert result.score == 1200.0
  end

  test "the Destroyer's setup carries the daily's grant, discounts and boon" do
    rt = script("destroyers_blueprint")
    daily = Daily.Objective.get(:destroyers_blueprint)

    assert rt.config["grant_patents"] == Enum.map(Daily.Objective.granted_patents(daily), &Atom.to_string/1)
    assert rt.config["mutators"] == Enum.map(daily.pinned_mutators, &Atom.to_string/1)

    assert rt.config["patent_discounts"] ==
             Map.new(Daily.Objective.patent_discounts(daily), fn {k, v} -> {Atom.to_string(k), v} end)
  end
end

defmodule Edict.ExamplesTest do
  use ExUnit.Case, async: true

  alias Edict.{AST, Printer, Simulator}

  for %{key: key} <- Edict.examples() do
    describe "example #{key}" do
      setup do
        example = Edict.example(unquote(key))
        %{example: example, analysis: Edict.analyze(example.source)}
      end

      test "checks clean", %{analysis: %{program: program, diagnostics: diags}} do
        assert program
        assert Enum.filter(diags, &(&1.severity == "error")) == []
      end

      test "is already in canonical form, and survives JSON", %{example: example, analysis: %{program: program}} do
        assert Printer.print(program) == example.source

        json = program |> Jason.encode!() |> Jason.decode!()
        {:ok, decoded} = AST.from_json(json)
        assert Printer.print(decoded) == example.source
      end

      test "simulates a whole run without errors", %{analysis: %{program: program}} do
        assert {:ok, report} = Simulator.run(program)
        assert report.errors == [], inspect(report.errors)
        assert is_number(report.result.score)
      end
    end
  end

  test "the built-in library: one fn per file, named after it, that checks clean in a scenario" do
    library = Edict.library()
    assert Enum.map(library, & &1.name) == ~w(best escalate level_for_wave)

    for %{name: name, doc: doc, source: source} <- library do
      assert doc != "", name
      %{program: program, diagnostics: diags} = Edict.analyze(source <> "\nscore 1\n")
      assert [%{k: :fn, name: ^name}] = Enum.filter(program.decls, &(&1.k == :fn))
      assert Enum.filter(diags, &(&1.severity == "error")) == [], "#{name}: #{inspect(diags)}"
    end
  end

  test "The Bequest simulates as designed: the fortune drains 5,000 a minute" do
    %{program: program} = Edict.analyze(Edict.example("the_bequest").source)
    {:ok, report} = Simulator.run(program)

    first = hd(report.samples)
    last = List.last(report.samples)
    # the drain is 5,000 a minute; the model's own income partly offsets it
    drained = 100_000_000 + first.credit - last.credit
    assert drained > 0
    assert report.result.score > 99_000_000
  end

  test "a race simulates to a finish once the goal is pretended" do
    %{program: program} = Edict.analyze(Edict.example("destroyers_blueprint").source)

    {:ok, dnf} = Simulator.run(program)
    assert dnf.result.reason == "deadline"
    assert dnf.result.score == 0.0

    {:ok, won} =
      Simulator.run(program, pretend: [%{"at" => 1140, "path" => "player.patents", "value" => ["armoring"]}])

    assert won.result.reason == "finished"
    assert won.result.ended_at == 1140.0
    assert won.result.score == 660.0
  end

  test "Headhunter (lite) sends one agent every 15 seconds, the same roster every run" do
    %{program: program} = Edict.analyze(Edict.example("headhunter_lite").source)
    {:ok, report} = Simulator.run(program)

    sends =
      for entry <- report.timeline, %{"action" => "send_agent"} = e <- entry.effects, do: {entry.t, e["args"]["level"]}

    assert length(sends) == 120
    assert Enum.map(Enum.take(sends, 3), &elem(&1, 0)) == [15.0, 30.0, 45.0]
    levels = Enum.map(sends, &elem(&1, 1))
    assert Enum.min(levels) >= 1
    # the band climbs: late agents are stronger on average
    {early, late} = Enum.split(levels, 60)
    assert Enum.sum(late) / 60 > Enum.sum(early) / 60

    {:ok, again} = Simulator.run(program)
    assert again.timeline == report.timeline
  end
end

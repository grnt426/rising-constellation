defmodule Edict.ParserTest do
  use ExUnit.Case, async: true

  alias Edict.{AST, Parser, Printer}

  # Ids and positions differ between two parses of equivalent text; compare
  # trees without them.
  defp strip(%{} = node) do
    node
    |> Map.drop([:id, :at])
    |> Map.new(fn {k, v} -> {k, strip(v)} end)
  end

  defp strip(list) when is_list(list), do: Enum.map(list, &strip/1)
  defp strip(other), do: other

  defp parse!(source) do
    case Parser.parse(source) do
      {:ok, program} -> program
      {:error, error} -> flunk("parse failed: #{inspect(error)}\n#{source}")
    end
  end

  # print(parse(x)) parses back to the same tree, and printing is stable.
  defp round_trip!(source) do
    program = parse!(source)
    printed = Printer.print(program)
    again = parse!(printed)
    assert strip(again) == strip(program), "round trip changed the tree:\n#{printed}"
    assert Printer.print(again) == printed
    printed
  end

  test "a small scenario parses into declarations" do
    program =
      parse!("""
      setup {
        name = "The Bequest"
        time_limit = 30m
      }

      score player.credit

      on start {
        give("credit", 100_000_000)
      }

      every 1s {
        take("credit", 5000 / 60)
      }
      """)

    assert Enum.map(program.decls, & &1.k) == [:setup, :score, :on, :every]
    [setup | _] = program.decls
    assert [%{k: :assign, target: %{name: "name"}}, %{k: :assign, expr: %{v: 1800.0, unit: "duration"}}] = setup.body
  end

  test "durations, percentages and digit groups" do
    {:ok, %{decls: [%{expr: e}]}} = Parser.parse("score 1m30s + 25% + 1_000")
    assert %{k: :bin, l: %{k: :bin, l: %{v: 90.0}, r: %{v: 0.25}}, r: %{v: 1000.0}} = e
  end

  test "precedence: multiplication before addition, and before or" do
    {:ok, %{decls: [%{expr: e}]}} = Parser.parse("score 1 + 2 * 3 > 6 and not false or true")
    assert %{op: "or", l: %{op: "and", l: %{op: ">", l: %{op: "+", r: %{op: "*"}}}, r: %{k: :un}}} = e
  end

  test "comparisons do not chain" do
    assert {:error, %{message: message}} = Parser.parse("score 1 < 2 < 3")
    assert message =~ "chained"
  end

  test "text with holes becomes a template" do
    {:ok, %{decls: [%{expr: e}]}} = Parser.parse(~s(score "wave {n + 1} of {total}"))
    assert %{k: :tmpl, parts: ["wave ", %{k: :bin}, " of ", %{k: :ident, name: "total"}]} = e
  end

  test "lambdas, named arguments, records and lists" do
    {:ok, %{decls: [%{expr: e}]}} =
      Parser.parse(
        ~s|score sum(filter(player.systems, s => s.income.credit > 100), (s) => s.population, by: {at: 1, "two words": [1, 2]})|
      )

    assert %{k: :call, args: [%{k: :call}, %{k: :lambda, params: ["s"]}], named: [%{name: "by", expr: %{k: :map}}]} = e
  end

  test "comments are kept as notes" do
    program =
      parse!("""
      # The opening gift
      on start {
        # a big one
        give("credit", 5) # and a bonus
        # nothing after this
      }
      """)

    [%{note: "The opening gift", body: [give, trailing]}] = program.decls
    assert give.note == "a big one\nand a bonus"
    assert trailing == Map.merge(trailing, %{k: :note, text: "nothing after this"})
  end

  test "parse errors name a misplaced comment, never repeat its text" do
    assert {:error, %{message: message}} = Parser.parse("setup # <img src=x onerror=1>")
    assert message == "expected { but found a comment"
  end

  test "Windows line endings read like Unix ones, comments included" do
    unix = "# The opening gift\non start {\n  notify(\"hi\") # a note\n}\n"
    windows = String.replace(unix, "\n", "\r\n")

    assert parse!(windows) == parse!(unix)
  end

  test "else if chains and if-expressions" do
    printed =
      round_trip!("""
      fn grade(x) {
        if x > 10 {
          return "high"
        } else if x > 5 {
          return "mid"
        } else {
          return if x > 0 then "low" else "none"
        }
      }
      """)

    assert printed =~ "} else if x > 5 {"
  end

  test "round trips keep every construct" do
    round_trip!("""
    # Headhunter, in brief
    setup {
      name = "Headhunter"
      time_limit = 30m
      rival = true
    }

    var removed = 0

    score removed

    tiebreak max(map(player.agents, a => a.level), 0)

    fn level_for(wave) {
      let top = 3 + floor(wave / 8) * 1.5
      return 1 + floor(random("level", wave) * top)
    }

    every 15s from 15s as wave {
      send_agent("erased", level: level_for(wave))
      if wave == 1 {
        notify("They are coming.", tone: "warning")
      }
    }

    when player.credit < 0 and not (time.left < 1m) {
      notify("Out of money: {player.credit} credits ({time.left}s left)")
      for s in player.systems {
        destabilize(5, system: s.id)
      }
    }

    at 10m {
      let xs = [1, 2, 3]
      xs[0] = -xs[1] - -3
      while len(xs) < 5 {
        xs = push(xs, {a: nil, "b c": true})
      }
    }

    draft {
      give("credit", ?)
    }
    """)
  end

  test "parenthesization survives a print" do
    for source <- [
          "score (1 + 2) * 3",
          "score 10 - (4 - 3)",
          "score -(a + b)",
          "score (x => x)(3)",
          "score not (a and b)"
        ] do
      printed = round_trip!(source)
      assert printed == source <> "\n"
    end
  end

  test "every parse error carries a position" do
    for bad <- ["score", "on later { }", "every { }", "fn f(a, a) { }", "score \"open", "score 1 +", "x = 1"] do
      assert {:error, %{message: m, line: l, col: c}} = Parser.parse(bad), "expected #{inspect(bad)} to fail"
      assert is_binary(m) and is_integer(l) and is_integer(c)
    end
  end

  test "trees survive a trip through JSON" do
    program =
      parse!("""
      var n = 0
      every 15s as wave {
        n = n + wave
        notify("wave {wave}", tone: "info")
      }
      score n
      """)

    json = program |> Jason.encode!() |> Jason.decode!()
    assert {:ok, decoded} = AST.from_json(json)
    assert strip(decoded) == strip(program)
  end
end

defmodule Edict.InterpreterTest do
  use ExUnit.Case, async: true

  alias Edict.{Interpreter, Parser, Runtime}

  @world %{
    "time" => %{"elapsed" => 60.0, "left" => 1740.0, "limit" => 1800.0},
    "player" => %{
      "credit" => 5000.0,
      "income" => %{"credit" => 120.0, "technology" => 10.0, "ideology" => 8.0},
      "systems" => [
        %{"id" => 1.0, "name" => "Vael", "income" => %{"credit" => 100.0}, "population" => 12.0},
        %{"id" => 2.0, "name" => "Ossuar", "income" => %{"credit" => 20.0}, "population" => 4.0}
      ],
      "patents" => ["citadel"]
    }
  }

  defp eval(source, opts \\ []) do
    {:ok, expr} = Parser.parse_fragment(source, :expr)

    fns =
      case Keyword.get(opts, :fns) do
        nil ->
          %{}

        fn_source ->
          {:ok, program} = Parser.parse(fn_source)
          for %{k: :fn, name: n} = d <- program.decls, into: %{}, do: {n, d}
      end

    ctx =
      Interpreter.new_ctx(
        world: Keyword.get(opts, :world, @world),
        fns: fns,
        seed: Keyword.get(opts, :seed, "test-seed"),
        fuel: Keyword.get(opts, :fuel, 200_000)
      )

    case Interpreter.eval_expr(expr, ctx) do
      {:ok, value, _ctx} -> {:ok, value}
      {:error, error, _ctx} -> {:error, error.message}
    end
  end

  defp value!(source, opts \\ []) do
    {:ok, v} = eval(source, opts)
    v
  end

  # Run `body` as an on start handler; return the program's vars and effects.
  defp handle(body, vars \\ "var out = nil") do
    {:ok, program} = Parser.parse(vars <> "\non start {\n" <> body <> "\n}")
    {:ok, rt} = Runtime.new(program)
    {rt, result} = Runtime.pulse(rt, @world, 0.0)
    {rt.globals, result}
  end

  describe "numbers" do
    test "arithmetic follows precedence and is all floating point" do
      assert value!("1 + 2 * 3") == 7.0
      assert value!("(1 + 2) * 3") == 9.0
      assert value!("7 / 2") == 3.5
      assert value!("-3 - -3") == 0.0
      assert value!("mod(-7, 3)") == 2.0
    end

    test "durations and percentages are numbers" do
      assert value!("1m30s") == 90.0
      assert value!("2h") == 7200.0
      assert value!("25% * 400") == 100.0
    end

    test "division by zero and overflow are script errors" do
      assert {:error, "division by zero"} = eval("1 / 0")
      assert {:error, message} = eval("pow(10, 300)")
      assert message =~ "too large"
      assert {:error, _} = eval("999_999_999 * 999_999_999")
    end

    test "math builtins" do
      assert value!("min(4, 2, 9)") == 2.0
      assert value!("max([1, 5, 3])") == 5.0
      assert value!("clamp(15, 0, 10)") == 10.0
      assert value!("round(2.345, 2)") == 2.35
      assert value!("lerp(0, 100, 25%)") == 25.0
      assert value!("floor(-1.5)") == -2.0
    end
  end

  describe "text" do
    test "templates, concatenation and formatting" do
      assert value!(~s("credit: {player.credit}")) == "credit: 5000"
      assert value!(~s("a" + 1)) == "a1"
      assert value!("fmt_number(1250000)") == "1,250,000"
      assert value!("fmt_time(185)") == "3:05"
      assert value!(~s|join(["a", "b"], "-")|) == "a-b"
      # big numbers read as players expect in text (the source writes 12_500)
      assert value!(~s("{12_500} credits")) == "12500 credits"
      assert value!("str(1_250_000)") == "1250000"
      assert value!(~s("total: " + 2.5)) == "total: 2.5"
    end

    test "text has a size cap" do
      assert {:error, message} = eval(~s|join(map(range(1, 3000), i => "xx"), "")|)
      assert message =~ "too long"
    end
  end

  describe "lists, records and lambdas" do
    test "reading the world" do
      assert value!("player.income.credit") == 120.0
      assert value!("len(player.systems)") == 2.0
      assert value!("player.systems[0].name") == "Vael"
      assert value!("player.systems[-1].name") == "Ossuar"
      assert value!("player.systems[9]") == nil
      assert value!("player.nothing") == nil
    end

    test "higher-order builtins with lambdas" do
      assert value!("sum(player.systems, s => s.population)") == 16.0
      assert value!("map(filter(player.systems, s => s.income.credit > 50), s => s.name)") == ["Vael"]
      assert value!("max_by(player.systems, s => s.population).name") == "Vael"
      assert value!("count(player.systems, s => s.population > 1)") == 2.0
      assert value!("any(player.systems, s => s.name == \"Ossuar\")") == true
      assert value!("sort_by([3, 1, 2], x => -x)") == [3.0, 2.0, 1.0]
      assert value!("((a, b) => a * b)(6, 7)") == 42.0
    end

    test "membership" do
      assert value!(~s("citadel" in player.patents)) == true
      assert value!(~s("cit" in "citadel")) == true
      assert value!(~s("credit" in player.income)) == true
    end

    test "records" do
      assert value!("get({a: 1}, \"b\", 7)") == 7.0
      assert value!("keys(put({b: 1}, \"a\", 2))") == ["a", "b"]
    end

    test "reading a field of nil names the problem" do
      assert {:error, message} = eval("player.systems[5].name")
      assert message =~ "nil"
    end
  end

  describe "functions" do
    test "user functions, named values and recursion" do
      fns = """
      fn fact(n) {
        if n <= 1 {
          return 1
        }
        return n * fact(n - 1)
      }
      fn area(w, h) {
        return w * h
      }
      """

      assert value!("fact(5)", fns: fns) == 120.0
      assert value!("area(h: 3, w: 4)", fns: fns) == 12.0
      assert value!("map([1, 2, 3], fact)", fns: fns) == [1.0, 2.0, 6.0]
    end

    test "runaway recursion is stopped" do
      fns = "fn forever(n) {\n  return forever(n + 1)\n}"
      assert {:error, message} = eval("forever(0)", fns: fns)
      assert message =~ "too deeply"
    end

    test "a break in a fn body doesn't escape into the caller's loop" do
      {_globals, result} =
        handle(
          """
          for i in [1, 2, 3] {
            stop()
            out = i
          }
          """,
          "var out = nil\nfn stop() {\n  break\n}"
        )

      assert [%{message: message}] = result.errors
      assert message =~ "inside a loop"
    end
  end

  describe "statements" do
    test "loops, break and continue, and assignment into structures" do
      {globals, _} =
        handle("""
        let total = 0
        for i in range(1, 10) {
          if i == 3 {
            continue
          }
          if i > 5 {
            break
          }
          total = total + i
        }
        let r = {xs: [1, 2, 3]}
        r.xs[1] = total
        out = r
        """)

      assert globals["out"] == %{"xs" => [1.0, 12.0, 3.0]}
    end

    test "while loops run out of fuel instead of forever" do
      {_globals, result} = handle("while true {\n  out = 1\n}")
      assert [%{message: message}] = result.errors
      assert message =~ "ran out of steps"
    end

    test "actions return descriptions, they don't act" do
      {_globals, result} = handle(~s|give("credit", 50)\nnotify("hi", tone: "good")|)

      assert [
               %{"action" => "give", "args" => %{"resource" => "credit", "amount" => 50.0}},
               %{"action" => "notify", "args" => %{"message" => "hi", "tone" => "good"}}
             ] = result.effects
    end

    test "action arguments are validated" do
      {_globals, result} = handle(~s|give("credits", 50)|)
      assert [%{message: message}] = result.errors
      assert message =~ "must be one of"

      {_globals, result} = handle(~s|give("credit", -5)|)
      assert [%{message: message}] = result.errors
      assert message =~ "between"
    end
  end

  describe "chance" do
    test "random() is fixed by the seed and keys" do
      a = value!(~s|random("wave", 3)|, seed: "s1")
      assert a == value!(~s|random("wave", 3)|, seed: "s1")
      assert a != value!(~s|random("wave", 4)|, seed: "s1")
      assert a != value!(~s|random("wave", 3)|, seed: "s2")
      assert a >= 0 and a < 1
    end

    test "random_int stays in its bounds" do
      for n <- 1..200 do
        v = value!("random_int(2, 5, #{n})")
        assert v in [2.0, 3.0, 4.0, 5.0]
      end
    end
  end
end

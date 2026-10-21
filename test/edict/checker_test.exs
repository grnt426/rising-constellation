defmodule Edict.CheckerTest do
  use ExUnit.Case, async: true

  defp diags(source) do
    %{program: program, diagnostics: diags} = Edict.analyze(source)
    assert program, "did not parse: #{inspect(diags)}"
    diags
  end

  defp errors(source), do: source |> diags() |> Enum.filter(&(&1.severity == "error")) |> Enum.map(& &1.message)
  defp warnings(source), do: source |> diags() |> Enum.filter(&(&1.severity == "warning")) |> Enum.map(& &1.message)

  defp assert_error(source, pattern) do
    errs = errors(source)
    assert Enum.any?(errs, &(&1 =~ pattern)), "expected an error matching #{inspect(pattern)}, got #{inspect(errs)}"
  end

  test "a clean scenario has no errors" do
    assert errors("""
           setup {
             name = "x"
           }
           var n = 0
           score player.credit + n
           every 1m as k {
             n = n + k
             give("credit", 10 * k)
           }
           """) == []
  end

  test "typos get a suggestion" do
    assert_error("score player.credt", "did you mean credit")
    assert_error("score playr.credit", "did you mean player")
    assert_error(~s|on start {\n  notfy("x")\n}|, "did you mean notify")
    assert_error(~s|on start {\n  give("credits", 5)\n}|, ~s|did you mean credit|)
  end

  test "fields are checked through lists and lambdas" do
    assert_error("score sum(player.systems, s => s.income.credt)", "did you mean credit")
    assert_error("score max(map(player.agents, a => a.fleet.raids))", "did you mean raid")
    assert errors("score sum(player.systems, s => s.income.credit)") == []
  end

  test "actions are refused where the game can't be changed" do
    assert_error(~s|score give("credit", 5)|, "can't be used")
    assert_error(~s|when give("credit", 5) {\n}|, "can't be used")
    assert_error(~s|var x = notify("hi")|, "can't be used")

    assert_error(
      """
      fn pay() {
        give("credit", 5)
        return 1
      }
      score pay()
      """,
      "changes the game"
    )
  end

  test "the world can't be read before the game starts" do
    assert_error("var x = player.credit", "can't be read here")
    assert_error(~s|every player.credit {\n}|, "can't be read here")
  end

  test "structural mistakes" do
    assert_error(~s|on start {\n  return 1\n}|, "inside a fn")
    assert_error(~s|on start {\n  break\n}|, "inside a loop")
    assert_error(~s|on start {\n  x = 1\n}|, "make it with let")
    assert_error(~s|on start {\n  player.credit = 1\n}|, "can't be changed directly")
    assert_error(~s|on start {\n  give("credit", ?)\n}|, "missing")
    assert_error("fn give(x) {\n}", "already a name")
    assert_error("score 1\nscore 2", "one score at most")
    assert_error("var a = 1\nvar a = 2", "defined twice")
  end

  test "arity and named values" do
    assert_error(~s|on start {\n  give("credit")\n}|, "needs 2")
    assert_error(~s|on start {\n  notify("x", colour: "red")\n}|, "has no colour:")
    assert_error(~s|on start {\n  notify("x", tone: "angry")\n}|, "must be one of")
    assert_error("fn f(a, b) {\n}\non start {\n  f(1)\n}", "needs a, b")
  end

  test "type slips the checker can see" do
    assert_error("score player.systems * 2", "works on numbers")
    assert_error("on start {\n  if player.credit {\n  }\n}", "needs true or false")
    assert_error("score player.name", "must be a number")
    assert_error("on start {\n  for s in player.credit {\n  }\n}", "needs a list")
  end

  test "setup fields are validated as written" do
    assert_error("setup {\n  colour = 1\n}", "isn't a setup field")
    assert_error("setup {\n  time_limit = 3h\n}", "time_limit")
    assert_error("setup {\n  systems = 12\n}", "systems")
    assert_error(~s|setup {\n  faction = "elves"\n}|, "faction")
    assert_error(~s|setup {\n  mutators = ["no_such_mutator"]\n}|, ~s("no_such_mutator" isn't a mutator))
    assert_error(~s|setup {\n  grant_patents = ["no_such_patent"]\n}|, ~s("no_such_patent" isn't a patent))
  end

  # Messages reach the editor's tooltips and toasts and, once scripts are
  # shared, other players: they quote keys, never markup.
  test "messages quote a script's text only when it is a plain key" do
    errs = errors(~s|setup {\n  mutators = ["<svg onload=alert(2)>"]\n  grant_patents = ["<img src=x>"]\n}|)
    assert Enum.any?(errs, &(&1 =~ "this text isn't a mutator"))
    assert Enum.any?(errs, &(&1 =~ "this text isn't a patent"))

    for message <-
          errors(~s|setup {\n  patent_discounts = {"<b>": 50%}\n}\nscore 1\non start {\n  give("<i>x</i>", 5)\n}|) do
      refute message =~ "<", message
    end

    # a name shows on one line wherever it appears
    assert_error("setup {\n  name = \"two\\nlines\"\n}\nscore 1", "must fit on one line")
  end

  test "comparisons against impossible choices warn" do
    assert Enum.any?(warnings(~s|score count(player.agents, a => a.type == "admiral")|), &(&1 =~ "never equal"))
  end

  test "send_agent without a rival court warns" do
    assert Enum.any?(warnings(~s|on start {\n  send_agent("erased", level: 2)\n}\nscore 1|), &(&1 =~ "rival"))
    assert warnings(~s|setup {\n  rival = true\n}\non start {\n  send_agent("erased", level: 2)\n}\nscore 1|) == []
  end

  test "drafts are not checked, only flagged as never running" do
    source = "score 1\ndraft {\n  give(?, nonsense)\n}"
    assert errors(source) == []
    assert Enum.any?(warnings(source), &(&1 =~ "never runs"))
  end

  test "a typo comes with a one-click fix aimed at the misspelled node" do
    %{program: program, diagnostics: [d | _]} = Edict.analyze("score player.credt")
    [%{expr: field}] = program.decls
    assert d.fix == %{target: field.id, field: "name", value: "credit"}

    %{program: program, diagnostics: diags} =
      Edict.analyze(~s|on start {\n  give("credits", 5)\n  levl(1)\n}\nfn level(x) {\n}\nscore 1|)

    [%{body: [%{expr: give}, %{expr: call}]} | _] = program.decls
    assert Enum.any?(diags, &(&1[:fix] == %{target: hd(give.args).id, field: "v", value: "credit"}))
    assert Enum.any?(diags, &(&1[:fix] == %{target: call.fn.id, field: "name", value: "level"}))
  end

  test "a single choice reads as one" do
    assert_error(~s|setup {\n  rival = true\n}\non start {\n  send_agent("spy")\n}|, ~s|must be "erased"|)
  end

  test "diagnostics point at the node" do
    [d | _] = diags("score player.credt")
    assert d.node_id
    assert d.at == [1, 13]
  end
end

defmodule Edict.DocsTest do
  use ExUnit.Case, async: true

  alias Edict.{Catalog, Checker, Docs, Interpreter, Lexer, Parser, Runtime}

  # A world shaped like Edict.World's output: two systems, three agents, a
  # rival court, five minutes into a 30-minute run.
  @world %{
    "time" => %{"elapsed" => 300.0, "left" => 1500.0, "limit" => 1800.0},
    "player" => %{
      "name" => "Vela",
      "faction" => "cardan",
      "credit" => 12_500.0,
      "technology" => 3400.0,
      "ideology" => 850.0,
      "income" => %{"credit" => 1250.0, "technology" => 310.0, "ideology" => 95.0},
      "systems" => [
        %{
          "id" => 101.0,
          "name" => "Vael",
          "home" => true,
          "population" => 14.0,
          "housing" => 18.0,
          "stability" => 62.0,
          "production" => 40.0,
          "intelligence" => 25.0,
          "defense" => 30.0,
          "income" => %{"credit" => 900.0, "technology" => 220.0, "ideology" => 60.0}
        },
        %{
          "id" => 102.0,
          "name" => "Ossuar",
          "home" => false,
          "population" => 6.0,
          "housing" => 10.0,
          "stability" => 41.0,
          "production" => 15.0,
          "intelligence" => 5.0,
          "defense" => 10.0,
          "income" => %{"credit" => 350.0, "technology" => 90.0, "ideology" => 35.0}
        }
      ],
      "systems_owned" => 2.0,
      "dominions" => 1.0,
      "population" => 23.0,
      "agents" => [
        %{
          "id" => 7.0,
          "name" => "Orsa Kell",
          "type" => "navarch",
          "level" => 4.0,
          "status" => "board",
          "system" => 101.0,
          "fleet" => %{"raid" => 120.0, "invasion" => 80.0, "upkeep" => 35.0}
        },
        %{
          "id" => 9.0,
          "name" => "Mire",
          "type" => "erased",
          "level" => 3.0,
          "status" => "board",
          "system" => 102.0,
          "fleet" => %{"raid" => 0.0, "invasion" => 0.0, "upkeep" => 0.0}
        },
        %{
          "id" => 12.0,
          "name" => "Talo Venn",
          "type" => "siderian",
          "level" => 2.0,
          "status" => "governor",
          "system" => 101.0,
          "fleet" => %{"raid" => 0.0, "invasion" => 0.0, "upkeep" => 0.0}
        }
      ],
      "patents" => ["armoring", "precision_cranes"],
      "wonders" => ["monument_dome"],
      "agents_removed" => 2.0
    },
    "rival" => %{"present" => true, "faction" => "myrmezir", "agents_sent" => 5.0, "agents_left" => 3.0},
    "scenario" => %{"name" => "Frontier Watch", "systems" => 2.0, "time_limit" => 1800.0}
  }

  # A scenario with no name or seed in its setup rolls with this seed, so
  # the chance examples show what a fresh scenario would roll.
  @seed "name:Untitled scenario"

  @node_kinds ~w(let set if for_each while return unused_value call field item_at list record lambda
                 template if_then_else note draft code setup score tiebreak var fn)
  @operators ~w(+ - * / == != < <= > >= in and or not negate)
  @events ~w(on_start on_end every at when)

  # Scripts name patents by the snake_case of their English name; these are
  # the ones the docs use.
  @patent_names ~w(armoring advanced_armoring precision_cranes assembly_lines urbanization monumental_architecture)

  defp expected_keys do
    Enum.map(Catalog.builtin_names(), &"builtin:#{&1}") ++
      Enum.map(Catalog.action_names(), &"action:#{&1}") ++
      Enum.map(@events, &"event:#{&1}") ++
      Enum.map(Lexer.keywords(), &"keyword:#{&1}") ++
      Enum.map(@operators, &"operator:#{&1}") ++
      Enum.map(Catalog.setup_names(), &"setup:#{&1}") ++
      Enum.map(Map.keys(Catalog.to_json().world_docs), &"world:#{&1}") ++
      Enum.map(@node_kinds, &"node:#{&1}")
  end

  defp examples do
    for {key, entry} <- Docs.all(), example <- entry.examples, do: {key, entry, example}
  end

  describe "coverage" do
    test "every name a script can use has an entry, and nothing else does" do
      keys = Map.keys(Docs.all())
      assert expected_keys() -- keys == []
      assert keys -- expected_keys() == []
    end

    test "the patent names the docs use are real ones" do
      assert @patent_names -- Catalog.patent_names() == []
    end

    test "get/1 finds an entry by key" do
      assert %{title: "in", kind: "operator"} = Docs.get("operator:in")
      assert Docs.get("builtin:nope") == nil
    end
  end

  describe "entries" do
    test "every entry has every field, with the right types" do
      for {key, e} <- Docs.all() do
        assert Enum.sort(Map.keys(e)) ==
                 Enum.sort([:title, :kind, :summary, :details, :usage, :inputs, :output, :examples, :see_also]),
               key

        for field <- [:title, :kind, :summary, :usage], do: assert(text?(e[field]), "#{key}: #{field}")
        for field <- [:details, :output], do: assert(e[field] == nil or text?(e[field]), "#{key}: #{field}")

        assert is_list(e.inputs), key

        for input <- e.inputs do
          assert Map.keys(input) |> Enum.sort() == [:doc, :name], key
          assert text?(input.name) and text?(input.doc), key
        end

        assert e.examples != [] and length(e.examples) <= 3, "#{key}: one to three examples"

        for ex <- e.examples do
          assert Map.keys(ex) |> Enum.sort() == [:code, :note, :result], key
          assert text?(ex.code), key
          assert ex.result == nil or text?(ex.result), key
          assert ex.note == nil or text?(ex.note), key
        end

        assert is_list(e.see_also) and Enum.all?(e.see_also, &is_binary/1), key
      end
    end

    test "see_also points at entries that exist" do
      all = Docs.all()

      dangling =
        for {key, e} <- all, other <- e.see_also, not Map.has_key?(all, other), do: {key, other}

      assert dangling == []
    end

    test "a builtin's or action's inputs follow the catalog's parameters" do
      for name <- Catalog.builtin_names() ++ Catalog.action_names() do
        sig = Catalog.builtin(name) || Catalog.action(name)
        prefix = if Catalog.builtin(name), do: "builtin:", else: "action:"
        params = Enum.map(sig.params ++ sig.named, & &1.name)
        assert Enum.map(Docs.get(prefix <> name).inputs, & &1.name) == params, name
      end
    end

    test "entries stay short enough for a hover card" do
      long =
        for {key, e} <- Docs.all(),
            {field, max} <- [summary: 25, details: 60],
            text = e[field],
            text != nil and words(text) > max,
            do: {key, field, words(text)}

      assert long == []
    end
  end

  describe "examples" do
    test "every example with a result gives exactly that result" do
      failures =
        for {key, _entry, %{result: result} = ex} <- examples(), result != nil, (got = run(ex.code)) != result do
          "#{key}: #{ex.code}\n    expected #{result}\n    got      #{got}"
        end

      assert failures == [], Enum.join(failures, "\n")
    end

    test "every example with a result passes the checker as a value" do
      failures =
        for {key, _entry, %{result: result} = ex} <- examples(),
            result != nil,
            errors = check("on start {\n  log(#{ex.code})\n}"),
            errors != [] do
          "#{key}: #{ex.code}\n    #{Enum.join(errors, "\n    ")}"
        end

      assert failures == [], Enum.join(failures, "\n")
    end

    test "every example without a result passes the checker and runs its first second cleanly" do
      failures =
        for {key, entry, %{result: nil} = ex} <- examples(),
            source = wrap(entry, ex.code),
            problems = check(source) ++ first_second(source),
            problems != [] do
          "#{key}:\n#{source}\n    #{Enum.join(problems, "\n    ")}"
        end

      assert failures == [], Enum.join(failures, "\n\n")
    end
  end

  # --- helpers -------------------------------------------------------------------

  defp text?(v), do: is_binary(v) and String.trim(v) != ""

  defp words(text), do: text |> String.split() |> length()

  # Evaluate `code` as one value against @world and print it the way Edict
  # prints a list's items: text in quotes, everything else as to_text/1.
  defp run(code) do
    case Parser.parse_fragment(code, :expr) do
      {:ok, expr} ->
        ctx = Interpreter.new_ctx(world: @world, seed: @seed)

        case Interpreter.eval_expr(expr, ctx) do
          {:ok, value, _ctx} -> shown(value)
          {:error, error, _ctx} -> "error: " <> error.message
        end

      {:error, error} ->
        "parse error: #{error.message}"
    end
  end

  defp shown(value) do
    text = Interpreter.to_text([value])
    String.slice(text, 1, String.length(text) - 2)
  end

  # A whole program stays as it is; steps go inside on start, setup lines
  # inside setup.
  defp wrap(entry, code) do
    case Parser.parse(code) do
      {:ok, _} -> code
      {:error, _} when entry.kind == "setup field" -> "setup {\n#{indent(code)}\n}"
      {:error, _} -> "on start {\n#{indent(code)}\n}"
    end
  end

  defp indent(code), do: code |> String.split("\n") |> Enum.map_join("\n", &("  " <> &1))

  # The checker's errors (warnings, such as a missing score, are fine).
  defp check(source) do
    case Parser.parse(source) do
      {:ok, program} ->
        program
        |> Checker.check()
        |> Enum.filter(&(&1.severity == "error"))
        |> Enum.map(& &1.message)

      {:error, error} ->
        ["parse error at #{error.line}:#{error.col}: #{error.message}"]
    end
  end

  # Set the scenario up and run its first second (t = 0) against @world.
  defp first_second(source) do
    with {:ok, program} <- Parser.parse(source),
         {:ok, rt} <- Runtime.new(program) do
      {_rt, result} = Runtime.pulse(rt, @world, 0.0)
      Enum.map(result.errors, &("at run time: " <> &1.message))
    else
      {:error, errors} when is_list(errors) -> Enum.map(errors, & &1.message)
      {:error, error} -> [error.message]
    end
  end
end

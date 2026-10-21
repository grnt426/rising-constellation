defmodule Edict.Docs do
  @moduledoc """
  The player-facing reference for Edict: one entry for every builtin, action,
  event, keyword, operator, setup field, world value and visual-editor node.

  The editor shows an entry when a player hovers or clicks a node or a name,
  and lists them all in its reference. Most readers have never programmed and
  work in the visual editor, so entries use plain words and say what flows
  out of each node along its wire.

  Entries are plain data (maps, lists and strings, ready to serve as JSON),
  keyed by kind and name: `"builtin:sum"`, `"action:give"`, `"event:every"`,
  `"keyword:in"`, `"operator:in"`, `"setup:time_limit"`,
  `"world:player.patents"`, `"node:for_each"`. Each entry has:

    * `title`: the name as the player sees it;
    * `kind`: a short label ("math", "action", "event", "world value" …);
    * `summary`: one sentence;
    * `details`: nil or a few short sentences;
    * `usage`: the form as written in text;
    * `inputs`: `%{name, doc}` for each input or wire into the node;
    * `output`: what flows out along the wire, or nil when nothing does;
    * `examples`: `%{code, result, note}`; `result` is the value as Edict
      prints it (text in quotes), or nil for steps and whole parts;
    * `see_also`: other keys.

  test/edict/docs_test.exs checks that every name in `Edict.Catalog` has an
  entry and that every example gives the result it claims (or, without one,
  passes the checker).
  """

  @step "Nothing: a step, it changes the game."

  # --- builtins: math -----------------------------------------------------------

  @math %{
    "builtin:abs" => %{
      title: "abs",
      kind: "math",
      summary: "The number without its minus sign.",
      details: nil,
      usage: "abs(x)",
      inputs: [%{name: "x", doc: "Any number."}],
      output: "A number, 0 or more, like 3.",
      examples: [
        %{code: "abs(-3)", result: "3", note: nil},
        %{code: "abs(player.credit - 10_000)", result: "2500", note: "how far from 10,000, either way"}
      ],
      see_also: ["operator:negate"]
    },
    "builtin:floor" => %{
      title: "floor",
      kind: "math",
      summary: "Rounds a number down to a whole number.",
      details: "Down means toward the smaller number, so floor(-2.5) is -3. To just drop the fraction, use trunc.",
      usage: "floor(x)",
      inputs: [%{name: "x", doc: "Any number."}],
      output: "A whole number, like 2.",
      examples: [
        %{code: "floor(2.7)", result: "2", note: nil},
        %{code: "floor(-2.5)", result: "-3", note: nil},
        %{code: "floor(time.elapsed / 60)", result: "5", note: "whole minutes played"}
      ],
      see_also: ["builtin:ceil", "builtin:trunc", "builtin:round"]
    },
    "builtin:ceil" => %{
      title: "ceil",
      kind: "math",
      summary: "Rounds a number up to a whole number.",
      details: "Up means toward the larger number, so ceil(-2.5) is -2.",
      usage: "ceil(x)",
      inputs: [%{name: "x", doc: "Any number."}],
      output: "A whole number, like 3.",
      examples: [
        %{code: "ceil(2.1)", result: "3", note: nil},
        %{code: "ceil(time.left / 60)", result: "25", note: "minutes left, counting a started one"}
      ],
      see_also: ["builtin:floor", "builtin:round"]
    },
    "builtin:trunc" => %{
      title: "trunc",
      kind: "math",
      summary: "Drops the fraction and keeps the whole part.",
      details: "It always moves toward 0: trunc(2.7) is 2 and trunc(-2.7) is -2. Handy for a score in whole numbers.",
      usage: "trunc(x)",
      inputs: [%{name: "x", doc: "Any number."}],
      output: "A whole number, like 2.",
      examples: [
        %{code: "trunc(2.7)", result: "2", note: nil},
        %{code: "trunc(-2.7)", result: "-2", note: nil}
      ],
      see_also: ["builtin:floor", "builtin:round"]
    },
    "builtin:round" => %{
      title: "round",
      kind: "math",
      summary: "Rounds to the nearest whole number, or to a number of decimals.",
      details: "A half rounds away from 0, so round(2.5) is 3. With digits, round(3.14159, 2) keeps two decimals.",
      usage: "round(x, [digits])",
      inputs: [
        %{name: "x", doc: "Any number."},
        %{name: "digits", doc: "Optional. How many decimals to keep, from 0 to 10. Left out, 0."}
      ],
      output: "A number, like 3 or 3.14.",
      examples: [
        %{code: "round(2.5)", result: "3", note: nil},
        %{code: "round(3.14159, 2)", result: "3.14", note: nil}
      ],
      see_also: ["builtin:floor", "builtin:ceil", "builtin:trunc", "builtin:fmt_number"]
    },
    "builtin:sqrt" => %{
      title: "sqrt",
      kind: "math",
      summary: "The square root of a number: the number that, times itself, gives it.",
      details: "The number can't be below 0; that is an error, and the event's steps stop there.",
      usage: "sqrt(x)",
      inputs: [%{name: "x", doc: "A number, 0 or more."}],
      output: "A number, like 4.",
      examples: [
        %{code: "sqrt(16)", result: "4", note: nil},
        %{code: "sqrt(2.25)", result: "1.5", note: nil}
      ],
      see_also: ["builtin:pow"]
    },
    "builtin:pow" => %{
      title: "pow",
      kind: "math",
      summary: "x to the power y: x multiplied by itself y times.",
      details:
        "y can be a fraction or below 0: pow(9, 0.5) is 3 and pow(2, -1) is 0.5. A result above a million billion is an error.",
      usage: "pow(x, y)",
      inputs: [
        %{name: "x", doc: "The number to multiply."},
        %{name: "y", doc: "The power: how many times. It can be a fraction or below 0."}
      ],
      output: "A number, like 8.",
      examples: [
        %{code: "pow(2, 3)", result: "8", note: "2 * 2 * 2"},
        %{code: "pow(9, 0.5)", result: "3", note: nil}
      ],
      see_also: ["builtin:sqrt", "operator:*"]
    },
    "builtin:min" => %{
      title: "min",
      kind: "math",
      summary: "The smallest of some numbers, or of a list of numbers.",
      details:
        "Give two or more numbers, or a single list. min(x, 10_000) is a handy cap: never more than 10,000. An empty list is an error.",
      usage: "min(a, b, …) or min(list)",
      inputs: [%{name: "values", doc: "Two or more numbers, or one list of numbers."}],
      output: "A number, like 3.",
      examples: [
        %{code: "min(3, 5)", result: "3", note: nil},
        %{code: "min([4, 2, 8])", result: "2", note: nil},
        %{code: "min(player.credit, 10_000)", result: "10000", note: "never more than 10,000"}
      ],
      see_also: ["builtin:max", "builtin:clamp", "builtin:min_by"]
    },
    "builtin:max" => %{
      title: "max",
      kind: "math",
      summary: "The largest of some numbers, or of a list of numbers.",
      details:
        "Give two or more numbers, or a single list. An empty list is an error; adding a 0 avoids it: max([0] + levels).",
      usage: "max(a, b, …) or max(list)",
      inputs: [%{name: "values", doc: "Two or more numbers, or one list of numbers."}],
      output: "A number, like 5.",
      examples: [
        %{code: "max(3, 5)", result: "5", note: nil},
        %{code: "max(player.income.credit, player.income.technology)", result: "1250", note: nil},
        %{code: "max([0] + map(player.agents, a => a.level))", result: "4", note: "0 when there are no agents"}
      ],
      see_also: ["builtin:min", "builtin:clamp", "builtin:max_by"]
    },
    "builtin:clamp" => %{
      title: "clamp",
      kind: "math",
      summary: "Keeps a number between a low and a high limit.",
      details:
        "Below low gives low, above high gives high, and anything between is left alone. low can't be above high.",
      usage: "clamp(x, low, high)",
      inputs: [
        %{name: "x", doc: "The number to keep in range."},
        %{name: "low", doc: "The smallest number allowed."},
        %{name: "high", doc: "The largest number allowed."}
      ],
      output: "A number from low to high, like 100.",
      examples: [
        %{code: "clamp(150, 0, 100)", result: "100", note: nil},
        %{code: "clamp(-20, 0, 100)", result: "0", note: nil},
        %{code: "clamp(42, 0, 100)", result: "42", note: nil}
      ],
      see_also: ["builtin:min", "builtin:max"]
    },
    "builtin:mod" => %{
      title: "mod",
      kind: "math",
      summary: "The remainder after dividing x by y: mod(17, 5) is 2.",
      details:
        "Good for every-other-time patterns: mod(n, 2) == 0 is true on even runs. The result takes the sign of y, so mod(-7, 3) is 2. y can't be 0.",
      usage: "mod(x, y)",
      inputs: [
        %{name: "x", doc: "The number to divide."},
        %{name: "y", doc: "The number to divide by; not 0."}
      ],
      output: "A number from 0 up to (not including) y, like 2.",
      examples: [
        %{code: "mod(17, 5)", result: "2", note: nil},
        %{code: "mod(4, 2) == 0", result: "true", note: "4 is even"},
        %{code: "mod(-7, 3)", result: "2", note: nil}
      ],
      see_also: ["operator:/", "builtin:floor"]
    },
    "builtin:lerp" => %{
      title: "lerp",
      kind: "math",
      summary: "The point a fraction of the way from one number to another.",
      details:
        "t is the fraction: 0 gives from, 1 gives to, 25% a quarter of the way. Good for something that grows over the run: lerp(1, 10, time.elapsed / time.limit).",
      usage: "lerp(from, to, t)",
      inputs: [
        %{name: "from", doc: "Where to start (when t is 0)."},
        %{name: "to", doc: "Where to end (when t is 1)."},
        %{name: "t", doc: "How far along: 0 to 1, or a percentage like 25%. Outside that, it goes past the ends."}
      ],
      output: "A number, like 25.",
      examples: [
        %{code: "lerp(0, 100, 25%)", result: "25", note: nil},
        %{
          code: "lerp(1, 10, time.elapsed / time.limit)",
          result: "2.5",
          note: "5 minutes into a 30-minute run"
        }
      ],
      see_also: ["builtin:clamp", "world:time.elapsed"]
    }
  }

  # --- builtins: text -----------------------------------------------------------

  @text %{
    "builtin:str" => %{
      title: "str",
      kind: "text",
      summary: "Writes any value as text.",
      details:
        "Numbers are written in plain digits (str(12500) is \"12500\"); use fmt_number for 12,500. Values in a text's {holes} and after a + with text are written the same way.",
      usage: "str(value)",
      inputs: [%{name: "value", doc: "Any value."}],
      output: "Text, like \"42\".",
      examples: [
        %{code: "str(42)", result: ~S|"42"|, note: nil},
        %{code: "str(12500)", result: ~S|"12500"|, note: nil},
        %{code: "str(true)", result: ~S|"true"|, note: nil}
      ],
      see_also: ["builtin:fmt_number", "builtin:fmt_time", "node:template"]
    },
    "builtin:upper" => %{
      title: "upper",
      kind: "text",
      summary: "The text in capital letters.",
      details: nil,
      usage: "upper(text)",
      inputs: [%{name: "text", doc: "Any text."}],
      output: "Text, like \"ARK\".",
      examples: [%{code: ~S|upper("ark")|, result: ~S|"ARK"|, note: nil}],
      see_also: ["builtin:lower"]
    },
    "builtin:lower" => %{
      title: "lower",
      kind: "text",
      summary: "The text in lowercase letters.",
      details: "Handy before comparing, since capitals matter: lower(name) == \"vael\" matches Vael and VAEL.",
      usage: "lower(text)",
      inputs: [%{name: "text", doc: "Any text."}],
      output: "Text, like \"vael\".",
      examples: [%{code: ~S|lower("Vael")|, result: ~S|"vael"|, note: nil}],
      see_also: ["builtin:upper"]
    },
    "builtin:join" => %{
      title: "join",
      kind: "text",
      summary: "Writes a list's items one after another as one text, with a separator between them.",
      details:
        "Left out, the separator is nothing at all, so join([\"a\", \"b\"]) is \"ab\". Items that aren't text are written as text first.",
      usage: "join(list, [separator])",
      inputs: [
        %{name: "list", doc: "The items to write."},
        %{name: "separator", doc: "Optional. Text to put between the items, like \", \". Left out, nothing."}
      ],
      output: "Text, like \"Vael, Ossuar\".",
      examples: [
        %{code: ~S|join(map(player.systems, s => s.name), ", ")|, result: ~S|"Vael, Ossuar"|, note: nil},
        %{code: ~S|join([1, 2, 3], " + ")|, result: ~S|"1 + 2 + 3"|, note: nil}
      ],
      see_also: ["builtin:str", "builtin:map"]
    },
    "builtin:fmt_time" => %{
      title: "fmt_time",
      kind: "text",
      summary: "Writes a number of seconds as a clock: minutes, a colon, then seconds.",
      details:
        "Fractions of a second are dropped and anything below 0 shows as 0:00. There is no hour part, so 1h reads 60:00.",
      usage: "fmt_time(seconds)",
      inputs: [%{name: "seconds", doc: "A number of seconds, like time.left or 3m."}],
      output: "Text, like \"3:05\".",
      examples: [
        %{code: "fmt_time(185)", result: ~S|"3:05"|, note: nil},
        %{code: "fmt_time(time.left)", result: ~S|"25:00"|, note: nil},
        %{code: "fmt_time(1h)", result: ~S|"60:00"|, note: nil}
      ],
      see_also: ["world:time.left", "world:time.elapsed", "builtin:fmt_number"]
    },
    "builtin:fmt_number" => %{
      title: "fmt_number",
      kind: "text",
      summary: "Writes a number rounded to a whole number, with commas between the thousands.",
      details:
        "The way to show a big number to a player: \"{fmt_number(player.credit)} credits\" reads 12,500 credits, where {player.credit} alone would read 12500.",
      usage: "fmt_number(x)",
      inputs: [%{name: "x", doc: "Any number."}],
      output: "Text, like \"1,250,000\".",
      examples: [
        %{code: "fmt_number(1250000)", result: ~S|"1,250,000"|, note: nil},
        %{code: "fmt_number(player.credit)", result: ~S|"12,500"|, note: nil},
        %{code: "fmt_number(2.6)", result: ~S|"3"|, note: nil}
      ],
      see_also: ["builtin:str", "node:template", "builtin:round"]
    }
  }

  # --- builtins: lists ----------------------------------------------------------

  @lists %{
    "builtin:len" => %{
      title: "len",
      kind: "list",
      summary: "How many items a list has, characters a text has, or fields a record has.",
      details: "To count only the items that pass a test, use count.",
      usage: "len(value)",
      inputs: [%{name: "value", doc: "A list, a text or a record."}],
      output: "A whole number, like 3.",
      examples: [
        %{code: "len(player.systems)", result: "2", note: nil},
        %{code: ~S|len("Vael")|, result: "4", note: nil},
        %{code: "len(player.patents)", result: "2", note: nil}
      ],
      see_also: ["builtin:count", "operator:in"]
    },
    "builtin:first" => %{
      title: "first",
      kind: "list",
      summary: "The first item of a list.",
      details:
        "An empty list gives nil (nothing), and reading a field of nil is an error, so check len(list) > 0 first when the list might be empty.",
      usage: "first(list)",
      inputs: [%{name: "list", doc: "Any list."}],
      output: "The item, whatever it is: for player.systems, a system. nil when the list is empty.",
      examples: [
        %{code: "first([10, 20, 30])", result: "10", note: nil},
        %{code: "first(player.systems).name", result: ~S|"Vael"|, note: nil},
        %{code: "first([])", result: "nil", note: nil}
      ],
      see_also: ["builtin:last", "node:item_at", "keyword:nil"]
    },
    "builtin:last" => %{
      title: "last",
      kind: "list",
      summary: "The last item of a list.",
      details: "An empty list gives nil (nothing).",
      usage: "last(list)",
      inputs: [%{name: "list", doc: "Any list."}],
      output: "The item, whatever it is. nil when the list is empty.",
      examples: [
        %{code: "last([10, 20, 30])", result: "30", note: nil},
        %{code: "last(player.systems).name", result: ~S|"Ossuar"|, note: nil}
      ],
      see_also: ["builtin:first", "node:item_at"]
    },
    "builtin:range" => %{
      title: "range",
      kind: "list",
      summary: "A list of whole numbers counting up from one number to another.",
      details:
        "Both ends are included. With one number, it counts from 1: range(3) is [1, 2, 3]. If to is below from, the list is empty. Handy with for each: for i in range(1, 5) { … }.",
      usage: "range(from, [to])",
      inputs: [
        %{name: "from", doc: "The first number; or, given alone, the last one, counting from 1."},
        %{name: "to", doc: "Optional. The last number, included."}
      ],
      output: "A list of numbers, like [1, 2, 3].",
      examples: [
        %{code: "range(1, 3)", result: "[1, 2, 3]", note: nil},
        %{code: "range(3)", result: "[1, 2, 3]", note: nil},
        %{code: "range(5, 7)", result: "[5, 6, 7]", note: nil}
      ],
      see_also: ["node:for_each", "builtin:slice"]
    },
    "builtin:push" => %{
      title: "push",
      kind: "list",
      summary: "A copy of a list with one more item at the end.",
      details: "The list you gave is left as it was; set it to keep the new one: seen = push(seen, n).",
      usage: "push(list, item)",
      inputs: [
        %{name: "list", doc: "Any list."},
        %{name: "item", doc: "The value to add at the end."}
      ],
      output: "A list one item longer, like [1, 2, 3].",
      examples: [
        %{code: "push([1, 2], 3)", result: "[1, 2, 3]", note: nil},
        %{
          code: ~s|var seen = []\n\nevery 1m as n {\n  seen = push(seen, n)\n}|,
          result: nil,
          note: "keeps the longer list in the var"
        }
      ],
      see_also: ["builtin:concat", "operator:+", "node:set"]
    },
    "builtin:concat" => %{
      title: "concat",
      kind: "list",
      summary: "Two lists joined into one: the first, then the second.",
      details: "list + list does the same.",
      usage: "concat(a, b)",
      inputs: [
        %{name: "a", doc: "The list that comes first."},
        %{name: "b", doc: "The list that comes after it."}
      ],
      output: "A list, like [1, 2, 3, 4].",
      examples: [%{code: "concat([1, 2], [3, 4])", result: "[1, 2, 3, 4]", note: nil}],
      see_also: ["builtin:push", "operator:+"]
    },
    "builtin:reverse" => %{
      title: "reverse",
      kind: "list",
      summary: "The list back to front.",
      details: nil,
      usage: "reverse(list)",
      inputs: [%{name: "list", doc: "Any list."}],
      output: "A list with the same items in the opposite order, like [3, 2, 1].",
      examples: [
        %{code: "reverse([1, 2, 3])", result: "[3, 2, 1]", note: nil},
        %{code: "reverse(sort([2, 9, 4]))", result: "[9, 4, 2]", note: "largest first"}
      ],
      see_also: ["builtin:sort"]
    },
    "builtin:slice" => %{
      title: "slice",
      kind: "list",
      summary: "A run of items from a list: count items, starting at position start.",
      details:
        "Positions count from 0, so slice(xs, 0, 3) is the first three. Left out, count takes everything to the end. Asking for more than there is gives what there is.",
      usage: "slice(list, start, [count])",
      inputs: [
        %{name: "list", doc: "Any list."},
        %{name: "start", doc: "Where to start: 0 is the first item."},
        %{name: "count", doc: "Optional. How many items to take. Left out, all the rest."}
      ],
      output: "A list, like [20, 30].",
      examples: [
        %{code: "slice([10, 20, 30, 40], 1, 2)", result: "[20, 30]", note: nil},
        %{code: "slice([10, 20, 30, 40], 2)", result: "[30, 40]", note: nil}
      ],
      see_also: ["node:item_at", "builtin:first"]
    },
    "builtin:contains" => %{
      title: "contains",
      kind: "list",
      summary: "Whether a list holds an item, or a text holds a smaller text.",
      details:
        "The in operator with its two sides swapped: contains(player.patents, \"armoring\") is \"armoring\" in player.patents. Unlike in, it can't look in a record; use has for that.",
      usage: "contains(in, item)",
      inputs: [
        %{name: "in", doc: "Where to look: a list or a text."},
        %{name: "item", doc: "What to look for: an exact item of the list, or a piece of the text."}
      ],
      output: "True or false.",
      examples: [
        %{code: ~S|contains(player.patents, "armoring")|, result: "true", note: nil},
        %{code: ~S|contains("armoring", "arm")|, result: "true", note: nil},
        %{code: "contains([1, 2, 3], 4)", result: "false", note: nil}
      ],
      see_also: ["operator:in", "builtin:has"]
    },
    "builtin:unique" => %{
      title: "unique",
      kind: "list",
      summary: "The list with repeated items removed, keeping the first of each.",
      details: nil,
      usage: "unique(list)",
      inputs: [%{name: "list", doc: "Any list."}],
      output: "A list, like [1, 2, 3].",
      examples: [%{code: "unique([1, 2, 2, 3, 1])", result: "[1, 2, 3]", note: nil}],
      see_also: ["builtin:sort"]
    },
    "builtin:sort" => %{
      title: "sort",
      kind: "list",
      summary: "The list ordered from smallest to largest.",
      details:
        "Works on a list of numbers or a list of texts (alphabetical, capitals before lowercase). To order records such as systems, use sort_by. For largest first, reverse(sort(xs)).",
      usage: "sort(list)",
      inputs: [%{name: "list", doc: "A list of numbers, or a list of texts."}],
      output: "A list with the same items in order, like [1, 2, 3].",
      examples: [
        %{code: "sort([3, 1, 2])", result: "[1, 2, 3]", note: nil},
        %{code: ~S|sort(["Vael", "Ossuar"])|, result: ~S|["Ossuar", "Vael"]|, note: nil}
      ],
      see_also: ["builtin:sort_by", "builtin:reverse"]
    },
    "builtin:sum" => %{
      title: "sum",
      kind: "list",
      summary: "The total of a list of numbers, or of a number worked out for each item.",
      details:
        "With a short function, it adds up what the function gives for each item: sum(player.systems, s => s.population) is the population of all the player's systems. An empty list sums to 0.",
      usage: "sum(list, [x => …])",
      inputs: [
        %{name: "list", doc: "A list of numbers, or of anything when a function is given."},
        %{name: "fn", doc: "Optional. A short function giving a number for each item, like s => s.population."}
      ],
      output: "A number, like 20.",
      examples: [
        %{code: "sum([1, 2, 3])", result: "6", note: nil},
        %{code: "sum(player.systems, s => s.population)", result: "20", note: nil},
        %{code: "sum(player.systems, s => s.income.credit)", result: "1250", note: nil}
      ],
      see_also: ["builtin:count", "builtin:map", "node:lambda"]
    },
    "builtin:count" => %{
      title: "count",
      kind: "list",
      summary: "How many items a list has, or how many of them pass a test.",
      details: "With a short function, only the items for which it gives true are counted.",
      usage: "count(list, [x => …])",
      inputs: [
        %{name: "list", doc: "Any list."},
        %{name: "fn", doc: "Optional. A test for each item, giving true or false, like a => a.level >= 3."}
      ],
      output: "A whole number, like 2.",
      examples: [
        %{code: "count(player.agents)", result: "3", note: nil},
        %{code: "count(player.agents, a => a.level >= 3)", result: "2", note: nil},
        %{code: "count(player.systems, s => s.stability < 50)", result: "1", note: nil}
      ],
      see_also: ["builtin:len", "builtin:filter", "node:lambda"]
    },
    "builtin:map" => %{
      title: "map",
      kind: "list",
      summary: "A new list made by working something out for each item of a list.",
      details:
        "The short function is used on each item in turn, and its results come out in the same order: map(player.systems, s => s.name) turns systems into their names.",
      usage: "map(list, x => …)",
      inputs: [
        %{name: "list", doc: "Any list."},
        %{name: "fn", doc: "A short function used on each item, like s => s.name."}
      ],
      output: "A list of whatever the function gives, like [\"Vael\", \"Ossuar\"].",
      examples: [
        %{code: "map([1, 2, 3], x => x * 2)", result: "[2, 4, 6]", note: nil},
        %{code: "map(player.systems, s => s.name)", result: ~S|["Vael", "Ossuar"]|, note: nil}
      ],
      see_also: ["builtin:filter", "builtin:sum", "node:lambda"]
    },
    "builtin:filter" => %{
      title: "filter",
      kind: "list",
      summary: "The items of a list that pass a test.",
      details:
        "The test is a short function giving true or false for each item; the items that give true are kept, in their order.",
      usage: "filter(list, x => …)",
      inputs: [
        %{name: "list", doc: "Any list."},
        %{name: "fn", doc: "A test for each item, like a => a.type == \"erased\"."}
      ],
      output: "A list of the items kept: the same kind of items as the list given.",
      examples: [
        %{code: "filter([1, 5, 8, 2], x => x > 3)", result: "[5, 8]", note: nil},
        %{
          code: ~S|map(filter(player.agents, a => a.type == "erased"), a => a.name)|,
          result: ~S|["Mire"]|,
          note: "the names of the Erased"
        }
      ],
      see_also: ["builtin:count", "builtin:find", "builtin:map", "node:lambda"]
    },
    "builtin:find" => %{
      title: "find",
      kind: "list",
      summary: "The first item of a list that passes a test.",
      details:
        "Gives nil (nothing) when no item passes, and reading a field of nil is an error, so check before using it: if s != nil { … }.",
      usage: "find(list, x => …)",
      inputs: [
        %{name: "list", doc: "Any list."},
        %{name: "fn", doc: "A test for each item, like s => s.stability < 50."}
      ],
      output: "The item found, whatever it is, or nil.",
      examples: [
        %{code: "find([3, 8, 12], x => x > 5)", result: "8", note: nil},
        %{code: "find(player.systems, s => s.stability < 50).name", result: ~S|"Ossuar"|, note: nil},
        %{code: "find(player.agents, a => a.level > 10)", result: "nil", note: "no agent passes"}
      ],
      see_also: ["builtin:filter", "builtin:any", "keyword:nil"]
    },
    "builtin:any" => %{
      title: "any",
      kind: "list",
      summary: "Whether at least one item of a list passes a test.",
      details: "An empty list gives false. Without a function, the list itself must hold true/false values.",
      usage: "any(list, [x => …])",
      inputs: [
        %{name: "list", doc: "Any list (of true/false values when no function is given)."},
        %{name: "fn", doc: "Optional. A test for each item, like s => s.stability < 50."}
      ],
      output: "True or false.",
      examples: [
        %{code: "any(player.systems, s => s.stability < 50)", result: "true", note: nil},
        %{code: "any([false, false])", result: "false", note: nil}
      ],
      see_also: ["builtin:all", "builtin:find"]
    },
    "builtin:all" => %{
      title: "all",
      kind: "list",
      summary: "Whether every item of a list passes a test.",
      details:
        "An empty list gives true, since no item fails. Without a function, the list itself must hold true/false values.",
      usage: "all(list, [x => …])",
      inputs: [
        %{name: "list", doc: "Any list (of true/false values when no function is given)."},
        %{name: "fn", doc: "Optional. A test for each item, like s => s.population > 5."}
      ],
      output: "True or false.",
      examples: [
        %{code: "all(player.systems, s => s.population > 5)", result: "true", note: nil},
        %{code: "all(player.agents, a => a.level >= 3)", result: "false", note: nil}
      ],
      see_also: ["builtin:any"]
    },
    "builtin:sort_by" => %{
      title: "sort_by",
      kind: "list",
      summary: "The list ordered by a number (or text) worked out for each item, smallest first.",
      details: "For largest first, put a minus in front: sort_by(player.systems, s => -s.population).",
      usage: "sort_by(list, x => …)",
      inputs: [
        %{name: "list", doc: "Any list."},
        %{name: "fn", doc: "A short function giving what to order by, like s => s.population."}
      ],
      output: "A list with the same items in order.",
      examples: [
        %{code: ~S|sort_by(["ccc", "a", "bb"], t => len(t))|, result: ~S|["a", "bb", "ccc"]|, note: nil},
        %{
          code: "map(sort_by(player.systems, s => s.population), s => s.name)",
          result: ~S|["Ossuar", "Vael"]|,
          note: "least populated first"
        }
      ],
      see_also: ["builtin:sort", "builtin:max_by", "builtin:min_by"]
    },
    "builtin:max_by" => %{
      title: "max_by",
      kind: "list",
      summary: "The item with the largest number worked out by a short function.",
      details:
        "It gives the whole item, not the number: max_by(player.systems, s => s.population) is a system, so add .name to read its name. An empty list gives nil.",
      usage: "max_by(list, x => …)",
      inputs: [
        %{name: "list", doc: "Any list."},
        %{name: "fn", doc: "A short function giving the number to compare, like s => s.population."}
      ],
      output: "The winning item, whatever it is, or nil.",
      examples: [
        %{code: "max_by(player.systems, s => s.population).name", result: ~S|"Vael"|, note: nil},
        %{code: "max_by(player.agents, a => a.level).level", result: "4", note: nil}
      ],
      see_also: ["builtin:min_by", "builtin:max", "builtin:sort_by"]
    },
    "builtin:min_by" => %{
      title: "min_by",
      kind: "list",
      summary: "The item with the smallest number worked out by a short function.",
      details: "It gives the whole item, not the number. An empty list gives nil.",
      usage: "min_by(list, x => …)",
      inputs: [
        %{name: "list", doc: "Any list."},
        %{name: "fn", doc: "A short function giving the number to compare, like s => s.stability."}
      ],
      output: "The winning item, whatever it is, or nil.",
      examples: [
        %{code: "min_by(player.systems, s => s.stability).name", result: ~S|"Ossuar"|, note: nil},
        %{code: "min_by(player.agents, a => a.level).name", result: ~S|"Talo Venn"|, note: nil}
      ],
      see_also: ["builtin:max_by", "builtin:min", "builtin:sort_by"]
    }
  }

  # --- builtins: records --------------------------------------------------------

  @records %{
    "builtin:keys" => %{
      title: "keys",
      kind: "record",
      summary: "The names of a record's fields, as a list of text.",
      details: "They come in alphabetical order, whatever order the record was written in.",
      usage: "keys(record)",
      inputs: [%{name: "record", doc: "Any record."}],
      output: "A list of text, like [\"credit\", \"ideology\", \"technology\"].",
      examples: [
        %{code: "keys(player.income)", result: ~S|["credit", "ideology", "technology"]|, note: nil},
        %{code: "keys({b: 2, a: 1})", result: ~S|["a", "b"]|, note: nil}
      ],
      see_also: ["builtin:values", "builtin:has"]
    },
    "builtin:values" => %{
      title: "values",
      kind: "record",
      summary: "The values of a record's fields, as a list.",
      details: "They come in the alphabetical order of the field names, matching keys(record) item for item.",
      usage: "values(record)",
      inputs: [%{name: "record", doc: "Any record."}],
      output: "A list, like [1250, 95, 310].",
      examples: [
        %{code: "values(player.income)", result: "[1250, 95, 310]", note: "credit, ideology, technology"},
        %{code: "sum(values(player.income))", result: "1655", note: nil}
      ],
      see_also: ["builtin:keys"]
    },
    "builtin:get" => %{
      title: "get",
      kind: "record",
      summary: "The value of a field, or a fallback when the record has no such field.",
      details:
        "Like record.name, except the name can be text worked out as the script runs, such as get(player.income, resource), and a missing field gives the fallback instead of nil.",
      usage: "get(record, key, [default])",
      inputs: [
        %{name: "record", doc: "Any record."},
        %{name: "key", doc: "The field's name, as text, like \"credit\"."},
        %{name: "default", doc: "Optional. What to give when the field is missing. Left out, nil."}
      ],
      output: "The field's value, whatever it is, like 1250.",
      examples: [
        %{code: ~S|get(player.income, "credit")|, result: "1250", note: nil},
        %{code: ~S|get({a: 1}, "b", 0)|, result: "0", note: "no field b, so the fallback"}
      ],
      see_also: ["builtin:put", "builtin:has", "node:field"]
    },
    "builtin:put" => %{
      title: "put",
      kind: "record",
      summary: "A copy of a record with one field set to a new value.",
      details:
        "The record you gave is left as it was; set it to keep the copy: r = put(r, \"wins\", 3). A field of a var can also be set directly: tally.wins = 3.",
      usage: "put(record, key, value)",
      inputs: [
        %{name: "record", doc: "Any record."},
        %{name: "key", doc: "The field's name, as text."},
        %{name: "value", doc: "The field's new value."}
      ],
      output: "A record, like {a: 1, b: 2}.",
      examples: [
        %{code: ~S|put({a: 1}, "b", 2)|, result: "{a: 1, b: 2}", note: nil},
        %{code: ~S|put({a: 1}, "a", 5)|, result: "{a: 5}", note: nil}
      ],
      see_also: ["builtin:get", "node:set"]
    },
    "builtin:has" => %{
      title: "has",
      kind: "record",
      summary: "Whether a record has a field with that name.",
      details: "The same test as key in record.",
      usage: "has(record, key)",
      inputs: [
        %{name: "record", doc: "Any record."},
        %{name: "key", doc: "The field's name, as text."}
      ],
      output: "True or false.",
      examples: [
        %{code: ~S|has(player.income, "credit")|, result: "true", note: nil},
        %{code: ~S|has({a: 1}, "b")|, result: "false", note: nil}
      ],
      see_also: ["operator:in", "builtin:get"]
    }
  }

  # --- builtins: chance ---------------------------------------------------------

  @chance %{
    "builtin:random" => %{
      title: "random",
      kind: "chance",
      summary: "A number from 0 up to (not including) 1, fixed by the keys you give it.",
      details:
        "The same keys give the same number in every run of this scenario, so every player faces the same rolls; change a key for a new roll. Without keys each call gets a new number, but what a player gets then depends on what they did, so prefer keys for anything that should be fair.",
      usage: "random(keys…)",
      inputs: [%{name: "keys", doc: "Values that name this roll, like \"wave\" and the wave number."}],
      output: "A number from 0 to just under 1, like 0.42.",
      examples: [
        %{code: ~S|round(random("wave", 3), 2)|, result: "0.96", note: "one scenario's roll"},
        %{code: ~S|1 + floor(random("level", 3) * 5)|, result: "5", note: "a whole number from 1 to 5"}
      ],
      see_also: ["builtin:random_int", "builtin:chance", "builtin:pick", "setup:seed"]
    },
    "builtin:random_int" => %{
      title: "random_int",
      kind: "chance",
      summary: "A whole number from low to high, both included, fixed by the keys.",
      details: "Like random(), the same keys give the same number for every player: random_int(1, 6, \"die\", n).",
      usage: "random_int(low, high, keys…)",
      inputs: [
        %{name: "low", doc: "The smallest possible number."},
        %{name: "high", doc: "The largest possible number."},
        %{name: "keys", doc: "Values that name this roll, like \"die\" and the run number."}
      ],
      output: "A whole number from low to high, like 4.",
      examples: [
        %{code: ~S|random_int(1, 6, "die", 1)|, result: "6", note: "one scenario's roll"},
        %{code: ~S|random_int(1, 6, "die", 2)|, result: "4", note: "another key, another roll"}
      ],
      see_also: ["builtin:random", "builtin:pick"]
    },
    "builtin:chance" => %{
      title: "chance",
      kind: "chance",
      summary: "True with a given probability, fixed by the keys.",
      details:
        "p is how likely: 25% is true one time in four, on average. The same keys give the same answer for every player, so name each roll with something that changes, like the run number from as n.",
      usage: "chance(p, keys…)",
      inputs: [
        %{name: "p", doc: "How likely: 0 (never) to 1 (always). 25% is one time in four."},
        %{name: "keys", doc: "Values that name this roll, like \"storm\" and the run number."}
      ],
      output: "True or false.",
      examples: [
        %{code: ~S|chance(25%, "storm", 1)|, result: "false", note: "one scenario's roll"},
        %{
          code: ~s|every 1m as n {\n  if chance(25%, "storm", n) {\n    take("credit", 500)\n  }\n}|,
          result: nil,
          note: "a storm about one minute in four"
        }
      ],
      see_also: ["builtin:random", "keyword:as"]
    },
    "builtin:pick" => %{
      title: "pick",
      kind: "chance",
      summary: "One item of a list, chosen at random but fixed by the keys.",
      details: "Every item is as likely as any other. An empty list gives nil.",
      usage: "pick(list, keys…)",
      inputs: [
        %{name: "list", doc: "The items to choose from."},
        %{name: "keys", doc: "Values that name this roll."}
      ],
      output: "One of the items, whatever it is.",
      examples: [
        %{code: ~S|pick(["north", "south", "east"], "gate", 1)|, result: ~S|"north"|, note: "one scenario's roll"},
        %{code: ~S|pick(player.systems, "raid", 1).name|, result: ~S|"Ossuar"|, note: nil}
      ],
      see_also: ["builtin:random_int", "builtin:random"]
    }
  }

  # --- actions ------------------------------------------------------------------

  @actions %{
    "action:give" => %{
      title: "give",
      kind: "action",
      summary: "Gives the player an amount of credit, technology or ideology.",
      details:
        "The amount is from 0 to 1,000,000,000. The gift lands once the event's steps finish, so player.credit shows it from the next second.",
      usage: "give(resource, amount)",
      inputs: [
        %{name: "resource", doc: "Which resource: \"credit\", \"technology\" or \"ideology\"."},
        %{name: "amount", doc: "How much: a number from 0 to 1,000,000,000."}
      ],
      output: @step,
      examples: [
        %{code: ~S|give("credit", 500)|, result: nil, note: nil},
        %{
          code: ~s|every 2m as gift {\n  give("credit", 500 * gift)\n}|,
          result: nil,
          note: "500, then 1,000, then 1,500 …"
        }
      ],
      see_also: ["action:take", "event:every"]
    },
    "action:take" => %{
      title: "take",
      kind: "action",
      summary: "Takes an amount of credit, technology or ideology from the player.",
      details:
        "The player's stock can go below zero; nothing stops it. The amount is from 0 to 1,000,000,000, and it lands once the event's steps finish.",
      usage: "take(resource, amount)",
      inputs: [
        %{name: "resource", doc: "Which resource: \"credit\", \"technology\" or \"ideology\"."},
        %{name: "amount", doc: "How much: a number from 0 to 1,000,000,000."}
      ],
      output: @step,
      examples: [
        %{code: ~S|take("ideology", 50)|, result: nil, note: nil},
        %{
          code: ~s|every 1s {\n  take("credit", 5000 / 60)\n}|,
          result: nil,
          note: "5,000 a minute, a little each second"
        }
      ],
      see_also: ["action:give"]
    },
    "action:notify" => %{
      title: "notify",
      kind: "action",
      summary: "Shows the player a message.",
      details:
        "tone: colors it: \"info\" (the default), \"good\" or \"warning\". Put values in with {holes}. Messages are cut at 280 characters, and a player gets 20 a minute at most; extras are dropped.",
      usage: "notify(message, [tone: …])",
      inputs: [
        %{name: "message", doc: "The text to show."},
        %{name: "tone", doc: "Optional. \"info\", \"good\" or \"warning\". Left out, \"info\"."}
      ],
      output: @step,
      examples: [
        %{code: ~S|notify("Welcome to the frontier.")|, result: nil, note: nil},
        %{
          code: ~S|notify("You hold {fmt_number(player.credit)} credits.", tone: "good")|,
          result: nil,
          note: nil
        }
      ],
      see_also: ["node:template", "builtin:fmt_number"]
    },
    "action:finish" => %{
      title: "finish",
      kind: "action",
      summary: "Ends the run now.",
      details:
        "The score is counted at once, with time.left as the time that was left: that is how a race scores. Then the on end steps run. The message, if given, is shown to the player.",
      usage: "finish([message])",
      inputs: [%{name: "message", doc: "Optional. Text to show the player as the run ends."}],
      output: @step,
      examples: [
        %{
          code: ~s|when "armoring" in player.patents {\n  finish("Armoring researched: the Destroyer is yours.")\n}|,
          result: nil,
          note: nil
        }
      ],
      see_also: ["event:on_end", "world:time.left", "node:score"]
    },
    "action:destabilize" => %{
      title: "destabilize",
      kind: "action",
      summary: "Lowers the stability of one of the player's systems.",
      details:
        "amount is from 0 to 100. Without system:, it hits the player's first system; system: takes a system's id, like player.systems[1].id.",
      usage: "destabilize(amount, [system: id])",
      inputs: [
        %{name: "amount", doc: "How much stability to remove: 0 to 100."},
        %{name: "system", doc: "Optional. The id of one of the player's own systems. Left out, their first system."}
      ],
      output: @step,
      examples: [
        %{code: "destabilize(10)", result: nil, note: "the first system"},
        %{code: ~s|for s in player.systems {\n  destabilize(5, system: s.id)\n}|, result: nil, note: "every system"}
      ],
      see_also: ["world:player.systems[].stability", "world:player.systems[].id"]
    },
    "action:send_agent" => %{
      title: "send_agent",
      kind: "action",
      summary: "The rival court sends an enemy agent into one of the player's systems.",
      details:
        "Needs rival = true in setup. The only type is \"erased\". level: is 1 to 30, and 1 if left out; system: picks the target, else the player's first system.",
      usage: "send_agent(\"erased\", [level: n], [system: id])",
      inputs: [
        %{name: "type", doc: "The agent's type: \"erased\"."},
        %{name: "level", doc: "Optional. The agent's level, 1 to 30. Left out, 1."},
        %{name: "system", doc: "Optional. The id of one of the player's systems. Left out, their first system."}
      ],
      output: @step,
      examples: [
        %{
          code: ~s|setup {\n  rival = true\n}\n\nevery 1m as wave {\n  send_agent("erased", level: min(wave, 30))\n}|,
          result: nil,
          note: "a stronger agent each minute"
        }
      ],
      see_also: ["setup:rival", "world:rival.agents_sent", "world:player.agents_removed"]
    },
    "action:log" => %{
      title: "log",
      kind: "action",
      summary: "Writes a value to the simulator's timeline, to check what the script sees.",
      details: "Players never see it, and it doesn't count toward the limit of 50 actions a second.",
      usage: "log(value)",
      inputs: [%{name: "value", doc: "Any value."}],
      output: "Nothing: a step that only writes to the simulator's timeline.",
      examples: [
        %{code: "log(player.credit)", result: nil, note: nil},
        %{code: "log(map(player.systems, s => s.stability))", result: nil, note: nil}
      ],
      see_also: ["action:notify"]
    }
  }

  # --- events -------------------------------------------------------------------

  @events %{
    "event:on_start" => %{
      title: "on start",
      kind: "event",
      summary: "Runs its steps once, as the run begins.",
      details: "The place for opening gifts and a welcome message.",
      usage: "on start { … }",
      inputs: [],
      output: "Nothing flows out: it starts the chain of steps below it.",
      examples: [
        %{
          code: ~s|on start {\n  give("credit", 1000)\n  notify("Welcome! Your patron sends 1,000 credits.")\n}|,
          result: nil,
          note: nil
        }
      ],
      see_also: ["event:on_end", "event:at"]
    },
    "event:on_end" => %{
      title: "on end",
      kind: "event",
      summary: "Runs its steps once, when the run ends, after the score is counted.",
      details:
        "It runs at the deadline or after finish(). The score is already counted, so changes made here come too late to matter for it.",
      usage: "on end { … }",
      inputs: [],
      output: "Nothing flows out: it starts the chain of steps below it.",
      examples: [
        %{
          code: ~s|on end {\n  notify("The run is over: {fmt_number(player.credit)} credits banked.")\n}|,
          result: nil,
          note: nil
        }
      ],
      see_also: ["event:on_start", "action:finish", "node:score"]
    },
    "event:every" => %{
      title: "every",
      kind: "event",
      summary: "Runs its steps again and again, on a fixed schedule.",
      details:
        "Times are seconds, written with units: 15s, 2m, 1m30s, 1h (a bare 90 is 90 seconds). The first run comes one interval in, unless from says when. until is the last moment it may run. as n counts the runs: 1, 2, 3 …",
      usage: "every 15s [from 1m] [until 20m] [as n] { … }",
      inputs: [
        %{name: "interval", doc: "How often: a time of at least 1s, like 15s or 2m."},
        %{name: "from", doc: "Optional. When the first run happens, like 5m. Left out, one interval in."},
        %{name: "until", doc: "Optional. The last time it may run, like 20m. A run due exactly then still happens."},
        %{name: "as", doc: "Optional. A name for the run counter: 1 on the first run, 2 on the second, and so on."}
      ],
      output:
        "Nothing flows out: it starts the chain of steps below it, each time it runs. With as, those steps can use the counter.",
      examples: [
        %{
          code: ~s|every 2m as gift {\n  give("credit", 500 * gift)\n}|,
          result: nil,
          note: "at 2m, 4m, 6m …: 500, 1,000, 1,500 …"
        },
        %{
          code: ~s|every 30s from 5m until 20m {\n  take("ideology", 50)\n}|,
          result: nil,
          note: "from 5m to 20m only"
        }
      ],
      see_also: ["event:at", "event:when", "keyword:as", "keyword:from", "keyword:until"]
    },
    "event:at" => %{
      title: "at",
      kind: "event",
      summary: "Runs its steps once, when the run's clock reaches a time.",
      details:
        "The time counts from the start of the run, written with units: 45s, 10m, 1m30s. It can't read the game (player, time …): times are worked out before the run starts.",
      usage: "at 10m { … }",
      inputs: [%{name: "time", doc: "When to run, from the start of the run, like 10m."}],
      output: "Nothing flows out: it starts the chain of steps below it.",
      examples: [
        %{
          code: ~s|at 25m {\n  notify("Five minutes left!", tone: "warning")\n}|,
          result: nil,
          note: "in a 30-minute run"
        }
      ],
      see_also: ["event:every", "event:when", "world:time.elapsed"]
    },
    "event:when" => %{
      title: "when",
      kind: "event",
      summary: "Runs its steps each time a condition turns true.",
      details:
        "The condition is checked every second. After it fires, it waits for the condition to turn false again before it can fire again, so it fires once per crossing, not every second. The condition can read the game but can't use actions.",
      usage: "when condition { … }",
      inputs: [%{name: "condition", doc: "True or false, like player.credit > 50_000."}],
      output: "Nothing flows out: it starts the chain of steps below it.",
      examples: [
        %{
          code: ~s|when "armoring" in player.patents {\n  finish("Armoring researched!")\n}|,
          result: nil,
          note: nil
        },
        %{
          code:
            ~s|when player.credit > 50_000 {\n  notify("A fortune! Spend it before raiders come.", tone: "warning")\n}|,
          result: nil,
          note: nil
        }
      ],
      see_also: ["event:every", "event:at", "operator:in"]
    }
  }

  # --- keywords -----------------------------------------------------------------

  @keywords %{
    "keyword:setup" => %{
      title: "setup",
      kind: "keyword",
      summary: "Starts the scenario's setup: the world the run begins in.",
      details: nil,
      usage: "setup { field = value … }",
      inputs: [],
      output: nil,
      examples: [%{code: ~s|setup {\n  name = "Land Rush"\n  time_limit = 30m\n}|, result: nil, note: nil}],
      see_also: ["node:setup"]
    },
    "keyword:score" => %{
      title: "score",
      kind: "keyword",
      summary: "Starts the score: the number players are ranked by, higher first.",
      details: nil,
      usage: "score number",
      inputs: [],
      output: nil,
      examples: [%{code: "score player.credit", result: nil, note: nil}],
      see_also: ["node:score", "keyword:tiebreak"]
    },
    "keyword:tiebreak" => %{
      title: "tiebreak",
      kind: "keyword",
      summary: "Starts the tiebreak: the number that ranks players with equal scores.",
      details: nil,
      usage: "tiebreak number",
      inputs: [],
      output: nil,
      examples: [%{code: "tiebreak trunc(player.income.credit)", result: nil, note: nil}],
      see_also: ["node:tiebreak", "keyword:score"]
    },
    "keyword:var" => %{
      title: "var",
      kind: "keyword",
      summary: "Makes a value the scenario keeps from one event to the next.",
      details: nil,
      usage: "var name = starting value",
      inputs: [],
      output: nil,
      examples: [%{code: ~s|var raids = 0\n\nevery 2m {\n  raids = raids + 1\n}|, result: nil, note: nil}],
      see_also: ["node:var", "keyword:let"]
    },
    "keyword:let" => %{
      title: "let",
      kind: "keyword",
      summary: "Gives a value a name, for the steps after it in the same block.",
      details: nil,
      usage: "let name = value",
      inputs: [],
      output: nil,
      examples: [
        %{code: ~s|let bonus = 500 * len(player.systems)\ngive("credit", bonus)|, result: nil, note: nil}
      ],
      see_also: ["node:let", "keyword:var"]
    },
    "keyword:fn" => %{
      title: "fn",
      kind: "keyword",
      summary: "Makes a function of your own: named steps you can use from anywhere.",
      details: nil,
      usage: "fn name(a, b) { … }",
      inputs: [],
      output: nil,
      examples: [%{code: ~s|fn double(x) {\n  return x * 2\n}\n\nscore double(player.credit)|, result: nil, note: nil}],
      see_also: ["node:fn", "node:call", "keyword:return"]
    },
    "keyword:return" => %{
      title: "return",
      kind: "keyword",
      summary: "Inside a fn, stops it and gives back a value.",
      details: nil,
      usage: "return [value]",
      inputs: [],
      output: nil,
      examples: [%{code: ~s|fn double(x) {\n  return x * 2\n}|, result: nil, note: nil}],
      see_also: ["node:return", "keyword:fn"]
    },
    "keyword:if" => %{
      title: "if",
      kind: "keyword",
      summary: "Runs steps only when a condition is true; also picks between two values.",
      details: "As a step: if condition { … } else { … }. As a value: if condition then a else b.",
      usage: "if condition { … } else { … }",
      inputs: [],
      output: nil,
      examples: [
        %{code: ~s|if player.credit < 1000 {\n  give("credit", 500)\n}|, result: nil, note: nil},
        %{code: ~S|if player.credit > 10_000 then "rich" else "poor"|, result: ~S|"rich"|, note: nil}
      ],
      see_also: ["node:if", "node:if_then_else", "keyword:else"]
    },
    "keyword:then" => %{
      title: "then",
      kind: "keyword",
      summary: "Part of the value form of if: if condition then a else b.",
      details: "The if step doesn't use then; it uses { }.",
      usage: "if condition then a else b",
      inputs: [],
      output: nil,
      examples: [%{code: ~S|if 3 > 2 then "yes" else "no"|, result: ~S|"yes"|, note: nil}],
      see_also: ["node:if_then_else", "keyword:if"]
    },
    "keyword:else" => %{
      title: "else",
      kind: "keyword",
      summary: "The other branch of an if: what happens, or what you get, when the condition is false.",
      details: "else if checks another condition in turn.",
      usage: "if condition { … } else { … }",
      inputs: [],
      output: nil,
      examples: [
        %{
          code:
            ~s|if player.credit < 1000 {\n  give("credit", 500)\n} else if player.credit < 5000 {\n  give("credit", 100)\n} else {\n  notify("You need no help.")\n}|,
          result: nil,
          note: nil
        }
      ],
      see_also: ["keyword:if", "node:if"]
    },
    "keyword:for" => %{
      title: "for",
      kind: "keyword",
      summary: "Runs steps once for each item of a list.",
      details: nil,
      usage: "for item in list { … }",
      inputs: [],
      output: nil,
      examples: [%{code: ~s|for s in player.systems {\n  log(s.name)\n}|, result: nil, note: nil}],
      see_also: ["node:for_each", "keyword:in"]
    },
    "keyword:in" => %{
      title: "in",
      kind: "keyword",
      summary: "Two uses: naming the list in a for each, and testing whether a value is in a list, text or record.",
      details: nil,
      usage: "for item in list { … }  or  value in list",
      inputs: [],
      output: nil,
      examples: [
        %{code: ~s|for s in player.systems {\n  log(s.name)\n}|, result: nil, note: nil},
        %{code: ~S|"armoring" in player.patents|, result: "true", note: nil}
      ],
      see_also: ["operator:in", "node:for_each"]
    },
    "keyword:while" => %{
      title: "while",
      kind: "keyword",
      summary: "Repeats steps as long as a condition stays true.",
      details: nil,
      usage: "while condition { … }",
      inputs: [],
      output: nil,
      examples: [%{code: ~s|let n = 1\nwhile n < 100 {\n  n = n * 2\n}|, result: nil, note: nil}],
      see_also: ["node:while", "keyword:break"]
    },
    "keyword:break" => %{
      title: "break",
      kind: "keyword",
      summary: "Leaves a loop at once; the steps after the loop carry on.",
      details: "Only inside a for each or a while.",
      usage: "break",
      inputs: [],
      output: nil,
      examples: [
        %{
          code:
            ~s|for s in player.systems {\n  if s.stability < 50 {\n    notify("{s.name} is restless.")\n    break\n  }\n}|,
          result: nil,
          note: "stops at the first restless system"
        }
      ],
      see_also: ["keyword:continue", "node:for_each", "node:while"]
    },
    "keyword:continue" => %{
      title: "continue",
      kind: "keyword",
      summary: "Skips the rest of a loop's steps for this item and moves on to the next.",
      details: "Only inside a for each or a while.",
      usage: "continue",
      inputs: [],
      output: nil,
      examples: [
        %{
          code: ~s|for s in player.systems {\n  if s.home {\n    continue\n  }\n  destabilize(5, system: s.id)\n}|,
          result: nil,
          note: "spares the home system"
        }
      ],
      see_also: ["keyword:break", "node:for_each"]
    },
    "keyword:on" => %{
      title: "on",
      kind: "keyword",
      summary: "Starts on start { … } or on end { … }.",
      details: nil,
      usage: "on start { … }  or  on end { … }",
      inputs: [],
      output: nil,
      examples: [%{code: ~s|on start {\n  notify("Welcome!")\n}|, result: nil, note: nil}],
      see_also: ["event:on_start", "event:on_end"]
    },
    "keyword:every" => %{
      title: "every",
      kind: "keyword",
      summary: "Starts steps that run again and again on a schedule.",
      details: nil,
      usage: "every 15s [from 1m] [until 20m] [as n] { … }",
      inputs: [],
      output: nil,
      examples: [%{code: ~s|every 15s {\n  give("credit", 100)\n}|, result: nil, note: nil}],
      see_also: ["event:every"]
    },
    "keyword:at" => %{
      title: "at",
      kind: "keyword",
      summary: "Starts steps that run once, at a set time into the run.",
      details: nil,
      usage: "at 10m { … }",
      inputs: [],
      output: nil,
      examples: [%{code: ~s|at 10m {\n  notify("Ten minutes in.")\n}|, result: nil, note: nil}],
      see_also: ["event:at"]
    },
    "keyword:when" => %{
      title: "when",
      kind: "keyword",
      summary: "Starts steps that run each time a condition turns true.",
      details: nil,
      usage: "when condition { … }",
      inputs: [],
      output: nil,
      examples: [%{code: ~s|when player.credit > 50_000 {\n  notify("Rich at last.")\n}|, result: nil, note: nil}],
      see_also: ["event:when"]
    },
    "keyword:as" => %{
      title: "as",
      kind: "keyword",
      summary: "Names the run counter of an every: as n counts 1, 2, 3 …",
      details: nil,
      usage: "every 1m as n { … }",
      inputs: [],
      output: nil,
      examples: [%{code: ~s|every 1m as n {\n  give("credit", 100 * n)\n}|, result: nil, note: nil}],
      see_also: ["event:every"]
    },
    "keyword:from" => %{
      title: "from",
      kind: "keyword",
      summary: "When an every starts: every 30s from 5m first runs at 5m.",
      details: nil,
      usage: "every 30s from 5m { … }",
      inputs: [],
      output: nil,
      examples: [%{code: ~s|every 30s from 5m {\n  take("credit", 200)\n}|, result: nil, note: nil}],
      see_also: ["event:every", "keyword:until"]
    },
    "keyword:until" => %{
      title: "until",
      kind: "keyword",
      summary: "When an every stops: every 30s until 20m runs for the last time at 20m.",
      details: nil,
      usage: "every 30s until 20m { … }",
      inputs: [],
      output: nil,
      examples: [%{code: ~s|every 30s until 20m {\n  give("technology", 50)\n}|, result: nil, note: nil}],
      see_also: ["event:every", "keyword:from"]
    },
    "keyword:draft" => %{
      title: "draft",
      kind: "keyword",
      summary: "Holds steps that aren't connected yet; they never run and aren't checked.",
      details: nil,
      usage: "draft { … }",
      inputs: [],
      output: nil,
      examples: [%{code: ~s|draft {\n  give("credit", 1000)\n}|, result: nil, note: nil}],
      see_also: ["node:draft"]
    },
    "keyword:and" => %{
      title: "and",
      kind: "keyword",
      summary: "True only when the conditions on both sides are true.",
      details: nil,
      usage: "a and b",
      inputs: [],
      output: nil,
      examples: [%{code: "true and false", result: "false", note: nil}],
      see_also: ["operator:and"]
    },
    "keyword:or" => %{
      title: "or",
      kind: "keyword",
      summary: "True when the condition on either side is true.",
      details: nil,
      usage: "a or b",
      inputs: [],
      output: nil,
      examples: [%{code: "true or false", result: "true", note: nil}],
      see_also: ["operator:or"]
    },
    "keyword:not" => %{
      title: "not",
      kind: "keyword",
      summary: "Turns true into false and false into true.",
      details: nil,
      usage: "not condition",
      inputs: [],
      output: nil,
      examples: [%{code: ~S|not "armoring" in player.patents|, result: "false", note: nil}],
      see_also: ["operator:not"]
    },
    "keyword:true" => %{
      title: "true",
      kind: "value",
      summary: "Yes: one of the two values a condition can have.",
      details: "Conditions in if, while and when must be true or false; a number or nil doesn't count as either.",
      usage: "true",
      inputs: [],
      output: "True.",
      examples: [
        %{code: "true", result: "true", note: nil},
        %{code: "3 > 2", result: "true", note: nil}
      ],
      see_also: ["keyword:false", "operator:not"]
    },
    "keyword:false" => %{
      title: "false",
      kind: "value",
      summary: "No: one of the two values a condition can have.",
      details: nil,
      usage: "false",
      inputs: [],
      output: "False.",
      examples: [
        %{code: "false", result: "false", note: nil},
        %{code: "not true", result: "false", note: nil}
      ],
      see_also: ["keyword:true", "operator:not"]
    },
    "keyword:nil" => %{
      title: "nil",
      kind: "value",
      summary: "Nothing: the value of something that isn't there.",
      details:
        "You get nil from first([]), a find with no match, a position past the end of a list, a missing field, or a fn that gives back nothing. Reading a field of nil is an error, so test x != nil first.",
      usage: "nil",
      inputs: [],
      output: "nil.",
      examples: [
        %{code: "first([])", result: "nil", note: nil},
        %{code: "first([]) == nil", result: "true", note: nil},
        %{code: "[1, 2][5]", result: "nil", note: "no item at position 5"}
      ],
      see_also: ["builtin:find", "builtin:first", "node:item_at"]
    }
  }

  # --- operators ----------------------------------------------------------------

  @operators %{
    "operator:+" => %{
      title: "+",
      kind: "operator",
      summary: "Adds two numbers, or joins two texts or two lists end to end.",
      details:
        "With text on either side, the other side is written as text too: \"Wave \" + 3 is \"Wave 3\". Numbers are written in plain digits (12500); use fmt_number for 12,500.",
      usage: "a + b",
      inputs: [
        %{name: "a", doc: "A number, a text or a list."},
        %{name: "b", doc: "The same kind as a; with text on either side, anything goes."}
      ],
      output: "A number, a text or a list, the same kind as the sides.",
      examples: [
        %{code: "2 + 3", result: "5", note: nil},
        %{code: ~S|"Wave " + 3|, result: ~S|"Wave 3"|, note: nil},
        %{code: "[1, 2] + [3]", result: "[1, 2, 3]", note: nil}
      ],
      see_also: ["operator:-", "builtin:concat", "node:template"]
    },
    "operator:-" => %{
      title: "-",
      kind: "operator",
      summary: "Subtracts the second number from the first.",
      details: "Numbers only. For a minus sign in front of a single value, see negate.",
      usage: "a - b",
      inputs: [
        %{name: "a", doc: "A number."},
        %{name: "b", doc: "The number to take away."}
      ],
      output: "A number, like 6.",
      examples: [
        %{code: "10 - 4", result: "6", note: nil},
        %{code: "time.limit - time.elapsed", result: "1500", note: "the same as time.left"}
      ],
      see_also: ["operator:+", "operator:negate"]
    },
    "operator:*" => %{
      title: "*",
      kind: "operator",
      summary: "Multiplies two numbers.",
      details: "Numbers only. A percentage is a number too: 25% * 400 is 100.",
      usage: "a * b",
      inputs: [
        %{name: "a", doc: "A number."},
        %{name: "b", doc: "A number."}
      ],
      output: "A number, like 12.",
      examples: [
        %{code: "3 * 4", result: "12", note: nil},
        %{code: "25% * 400", result: "100", note: nil}
      ],
      see_also: ["operator:/", "builtin:pow"]
    },
    "operator:/" => %{
      title: "/",
      kind: "operator",
      summary: "Divides the first number by the second.",
      details:
        "The answer keeps its fraction: 7 / 2 is 3.5. Use floor, trunc or round for a whole number. Dividing by 0 is an error, and the event's steps stop there.",
      usage: "a / b",
      inputs: [
        %{name: "a", doc: "The number to divide."},
        %{name: "b", doc: "The number to divide by; not 0."}
      ],
      output: "A number, like 3.5.",
      examples: [
        %{code: "7 / 2", result: "3.5", note: nil},
        %{code: "time.elapsed / 60", result: "5", note: "minutes played"}
      ],
      see_also: ["operator:*", "builtin:mod", "builtin:floor"]
    },
    "operator:==" => %{
      title: "==",
      kind: "operator",
      summary: "Whether two values are the same.",
      details:
        "Works on any two values. Capitals matter, and values of different kinds are never equal: 1 == \"1\" is false. Write two = signs; a single = sets a variable.",
      usage: "a == b",
      inputs: [
        %{name: "a", doc: "Any value."},
        %{name: "b", doc: "Any value."}
      ],
      output: "True or false.",
      examples: [
        %{code: "2 + 2 == 4", result: "true", note: nil},
        %{code: ~S|"credit" == "Credit"|, result: "false", note: nil},
        %{code: "[1, 2] == [1, 2]", result: "true", note: nil}
      ],
      see_also: ["operator:!=", "node:set"]
    },
    "operator:!=" => %{
      title: "!=",
      kind: "operator",
      summary: "Whether two values are different.",
      details: "The opposite of ==. x != nil is the usual test that something was found.",
      usage: "a != b",
      inputs: [
        %{name: "a", doc: "Any value."},
        %{name: "b", doc: "Any value."}
      ],
      output: "True or false.",
      examples: [
        %{code: ~S|player.faction != "ark"|, result: "true", note: nil},
        %{code: "find(player.agents, a => a.level > 3) != nil", result: "true", note: nil}
      ],
      see_also: ["operator:==", "keyword:nil"]
    },
    "operator:<" => %{
      title: "<",
      kind: "operator",
      summary: "Whether the first number is less than the second.",
      details:
        "Works on two numbers or two texts (alphabetical). Comparisons don't chain: instead of 1 < x < 5, write 1 < x and x < 5.",
      usage: "a < b",
      inputs: [
        %{name: "a", doc: "A number or a text."},
        %{name: "b", doc: "The same kind as a."}
      ],
      output: "True or false.",
      examples: [
        %{code: "3 < 5", result: "true", note: nil},
        %{code: ~S|"apple" < "banana"|, result: "true", note: "alphabetical"}
      ],
      see_also: ["operator:<=", "operator:>", "operator:and"]
    },
    "operator:<=" => %{
      title: "<=",
      kind: "operator",
      summary: "Whether the first number is less than or equal to the second.",
      details: "Works on two numbers or two texts (alphabetical).",
      usage: "a <= b",
      inputs: [
        %{name: "a", doc: "A number or a text."},
        %{name: "b", doc: "The same kind as a."}
      ],
      output: "True or false.",
      examples: [
        %{code: "5 <= 5", result: "true", note: nil},
        %{code: "time.left <= 5m", result: "false", note: "25 minutes are left"}
      ],
      see_also: ["operator:<", "operator:>="]
    },
    "operator:>" => %{
      title: ">",
      kind: "operator",
      summary: "Whether the first number is greater than the second.",
      details: "Works on two numbers or two texts (alphabetical). Comparisons don't chain.",
      usage: "a > b",
      inputs: [
        %{name: "a", doc: "A number or a text."},
        %{name: "b", doc: "The same kind as a."}
      ],
      output: "True or false.",
      examples: [
        %{code: "player.credit > 10_000", result: "true", note: nil},
        %{code: "time.elapsed > 10m", result: "false", note: "five minutes in"}
      ],
      see_also: ["operator:>=", "operator:<"]
    },
    "operator:>=" => %{
      title: ">=",
      kind: "operator",
      summary: "Whether the first number is greater than or equal to the second.",
      details: "Works on two numbers or two texts (alphabetical).",
      usage: "a >= b",
      inputs: [
        %{name: "a", doc: "A number or a text."},
        %{name: "b", doc: "The same kind as a."}
      ],
      output: "True or false.",
      examples: [
        %{code: "len(player.systems) >= 2", result: "true", note: nil},
        %{code: "4 >= 5", result: "false", note: nil}
      ],
      see_also: ["operator:>", "operator:<="]
    },
    "operator:in" => %{
      title: "in",
      kind: "operator",
      summary: "Whether a value is one of a list's items, a piece of a text, or a field name of a record.",
      details:
        "The right side decides the test. A list needs an exact item: \"armor\" in player.patents is false. A text looks for the smaller text anywhere inside it. A record checks its field names. For the opposite, put not in front: not \"armoring\" in player.patents.",
      usage: "value in list  ·  text in text  ·  name in record",
      inputs: [
        %{
          name: "value",
          doc: "What to look for: an item, for a list; a piece of text, for a text; a field name, for a record."
        },
        %{name: "in", doc: "Where to look: a list, a text or a record."}
      ],
      output: "True or false.",
      examples: [
        %{code: ~S|"armoring" in player.patents|, result: "true", note: "a list: is it one of the items?"},
        %{code: ~S|"arm" in "armoring"|, result: "true", note: "a text: is it inside?"},
        %{code: ~S|"credit" in player.income|, result: "true", note: "a record: is it a field name?"}
      ],
      see_also: ["builtin:contains", "builtin:has", "operator:not", "keyword:in"]
    },
    "operator:and" => %{
      title: "and",
      kind: "operator",
      summary: "True only when the conditions on both sides are true.",
      details:
        "Both sides must be true or false; a number or nil is an error. If the left side is false, the right side isn't looked at, so x != nil and x.level > 3 is safe.",
      usage: "a and b",
      inputs: [
        %{name: "a", doc: "True or false."},
        %{name: "b", doc: "True or false."}
      ],
      output: "True or false.",
      examples: [
        %{code: "true and false", result: "false", note: nil},
        %{code: "player.credit > 10_000 and len(player.systems) >= 2", result: "true", note: nil}
      ],
      see_also: ["operator:or", "operator:not"]
    },
    "operator:or" => %{
      title: "or",
      kind: "operator",
      summary: "True when the condition on either side is true.",
      details: "Both sides must be true or false. If the left side is true, the right side isn't looked at.",
      usage: "a or b",
      inputs: [
        %{name: "a", doc: "True or false."},
        %{name: "b", doc: "True or false."}
      ],
      output: "True or false.",
      examples: [
        %{code: "false or true", result: "true", note: nil},
        %{code: ~S|player.faction == "ark" or player.faction == "cardan"|, result: "true", note: nil}
      ],
      see_also: ["operator:and", "operator:not"]
    },
    "operator:not" => %{
      title: "not",
      kind: "operator",
      summary: "Turns true into false and false into true.",
      details:
        "It applies to the whole test after it: not \"armoring\" in player.patents means not (\"armoring\" in player.patents).",
      usage: "not condition",
      inputs: [%{name: "condition", doc: "True or false."}],
      output: "True or false.",
      examples: [
        %{code: "not true", result: "false", note: nil},
        %{code: ~S|not "armoring" in player.patents|, result: "false", note: nil},
        %{code: "not len(player.agents) > 5", result: "true", note: nil}
      ],
      see_also: ["operator:and", "operator:or", "operator:in"]
    },
    "operator:negate" => %{
      title: "negate",
      kind: "operator",
      summary: "Flips a number's sign: a minus in front of a single value.",
      details: "Handy for ordering largest first: sort_by(player.systems, s => -s.population).",
      usage: "-x",
      inputs: [%{name: "x", doc: "A number."}],
      output: "A number, like -12500.",
      examples: [
        %{code: "-(3 - 5)", result: "2", note: nil},
        %{code: "-player.credit", result: "-12500", note: nil}
      ],
      see_also: ["operator:-", "builtin:abs"]
    }
  }

  # --- setup fields -------------------------------------------------------------

  @setup %{
    "setup:name" => %{
      title: "name",
      kind: "setup field",
      summary: "The scenario's title, as players see it.",
      details:
        "Up to 60 characters, on one line. Without a seed, the name also fixes the random rolls, so renaming a scenario changes them.",
      usage: "name = \"Land Rush\"",
      inputs: [%{name: "name", doc: "Text, up to 60 characters. Left out, \"Untitled scenario\"."}],
      output: nil,
      examples: [%{code: ~S|name = "Land Rush"|, result: nil, note: nil}],
      see_also: ["setup:description", "setup:seed"]
    },
    "setup:description" => %{
      title: "description",
      kind: "setup field",
      summary: "One or two sentences telling the player what to do.",
      details: "Up to 500 characters. Say how the score works, so players know what to aim for.",
      usage: "description = \"…\"",
      inputs: [%{name: "description", doc: "Text, up to 500 characters. Left out, empty."}],
      output: nil,
      examples: [
        %{
          code: ~S|description = "Bank as many credits as you can. A patron chips in every two minutes."|,
          result: nil,
          note: nil
        }
      ],
      see_also: ["setup:name"]
    },
    "setup:time_limit" => %{
      title: "time_limit",
      kind: "setup field",
      summary: "How long a run lasts.",
      details: "A time from 5m to 45m, written with units: 30m, or 22m30s. A bare number counts seconds: 1800 is 30m.",
      usage: "time_limit = 30m",
      inputs: [%{name: "time_limit", doc: "A time from 5m to 45m. Left out, 30m."}],
      output: nil,
      examples: [%{code: "time_limit = 30m", result: nil, note: nil}],
      see_also: ["world:time.limit", "world:time.left"]
    },
    "setup:faction" => %{
      title: "faction",
      kind: "setup field",
      summary: "The player's faction.",
      details:
        "One of \"tetrarchy\", \"myrmezir\", \"cardan\", \"synelle\" or \"ark\". Left out, the scenario picks one from its seed, the same for every player.",
      usage: "faction = \"synelle\"",
      inputs: [
        %{
          name: "faction",
          doc: "\"tetrarchy\", \"myrmezir\", \"cardan\", \"synelle\" or \"ark\". Left out, picked from the seed."
        }
      ],
      output: nil,
      examples: [%{code: ~S|faction = "synelle"|, result: nil, note: nil}],
      see_also: ["world:player.faction", "setup:seed"]
    },
    "setup:systems" => %{
      title: "systems",
      kind: "setup field",
      summary: "How many systems the starting sector holds; the player starts in one.",
      details: "A whole number from 1 to 8. neighbors says what the other systems are.",
      usage: "systems = 6",
      inputs: [%{name: "systems", doc: "A whole number from 1 to 8. Left out, 1."}],
      output: nil,
      examples: [%{code: "systems = 6", result: nil, note: nil}],
      see_also: ["setup:neighbors", "world:scenario.systems"]
    },
    "setup:neighbors" => %{
      title: "neighbors",
      kind: "setup field",
      summary: "What the sector's other systems are: empty, to colonize, or neutral, to conquer or win over.",
      details: "Only matters when systems is more than 1.",
      usage: "neighbors = \"neutral\"",
      inputs: [%{name: "neighbors", doc: "\"empty\" or \"neutral\". Left out, \"empty\"."}],
      output: nil,
      examples: [%{code: ~s|systems = 4\nneighbors = "neutral"|, result: nil, note: nil}],
      see_also: ["setup:systems"]
    },
    "setup:rival" => %{
      title: "rival",
      kind: "setup field",
      summary: "Adds a rival court: an enemy faction whose agents the scenario can send in.",
      details: "send_agent only works with rival = true.",
      usage: "rival = true",
      inputs: [%{name: "rival", doc: "true or false. Left out, false."}],
      output: nil,
      examples: [%{code: "rival = true", result: nil, note: nil}],
      see_also: ["action:send_agent", "world:rival.present"]
    },
    "setup:mutators" => %{
      title: "mutators",
      kind: "setup field",
      summary: "Daily mutators to apply, the boons and banes of the daily challenge, by key.",
      details: "A list of up to 6 mutator keys, like \"lean_years\". The editor lists the ones you can use.",
      usage: "mutators = [\"lean_years\"]",
      inputs: [%{name: "mutators", doc: "A list of mutator keys, up to 6. Left out, none."}],
      output: nil,
      examples: [%{code: ~S|mutators = ["lean_years"]|, result: nil, note: nil}],
      see_also: ["setup:grant_patents"]
    },
    "setup:grant_patents" => %{
      title: "grant_patents",
      kind: "setup field",
      summary: "Patents the player starts with, each with the patents it needs.",
      details:
        "A list of up to 30 patent names: the English name in lowercase with _ for spaces, so Precision Cranes is \"precision_cranes\".",
      usage: "grant_patents = [\"precision_cranes\"]",
      inputs: [%{name: "grant_patents", doc: "A list of patent names, up to 30. Left out, none."}],
      output: nil,
      examples: [%{code: ~S|grant_patents = ["precision_cranes"]|, result: nil, note: nil}],
      see_also: ["setup:patent_discounts", "world:player.patents"]
    },
    "setup:patent_discounts" => %{
      title: "patent_discounts",
      kind: "setup field",
      summary: "Price cuts for single patents: each patent's name with the share of its price to charge.",
      details:
        "A record of up to 30 patent names, each with a factor from 5% to 100%: {armoring: 20%} sells Armoring at a fifth of its price.",
      usage: "patent_discounts = {armoring: 20%}",
      inputs: [
        %{name: "patent_discounts", doc: "A record: patent name, then a factor from 5% to 100%. Left out, none."}
      ],
      output: nil,
      examples: [
        %{code: "patent_discounts = {armoring: 20%, advanced_armoring: 50%}", result: nil, note: nil}
      ],
      see_also: ["setup:grant_patents", "world:player.patents"]
    },
    "setup:seed" => %{
      title: "seed",
      kind: "setup field",
      summary: "Fixes the generated world and the random rolls.",
      details:
        "Left out, the seed comes from the scenario's name. Set one to keep the same world and rolls while you rename the scenario, or change it to reshuffle them.",
      usage: "seed = \"spring-cup\"",
      inputs: [%{name: "seed", doc: "A number, or text up to 64 characters. Left out, the scenario's name."}],
      output: nil,
      examples: [%{code: ~S|seed = "spring-cup"|, result: nil, note: nil}],
      see_also: ["builtin:random", "setup:name"]
    }
  }

  # --- the world ----------------------------------------------------------------

  @world_values %{
    "world:time.elapsed" => %{
      title: "time.elapsed",
      kind: "world value",
      summary: "Seconds since the run began.",
      details: "Counts up from 0. Compare it with times written in units: time.elapsed > 10m.",
      usage: "time.elapsed",
      inputs: [],
      output: "A number of seconds, like 300 (five minutes in).",
      examples: [
        %{code: "time.elapsed", result: "300", note: nil},
        %{code: "fmt_time(time.elapsed)", result: ~S|"5:00"|, note: nil}
      ],
      see_also: ["world:time.left", "builtin:fmt_time"]
    },
    "world:time.left" => %{
      title: "time.left",
      kind: "world value",
      summary: "Seconds until the deadline; 0 at the deadline.",
      details:
        "A race scores time.left and calls finish() when the goal is met, so the score is the time that was left.",
      usage: "time.left",
      inputs: [],
      output: "A number of seconds, like 1500 (25 minutes).",
      examples: [
        %{code: "time.left", result: "1500", note: nil},
        %{code: "fmt_time(time.left)", result: ~S|"25:00"|, note: nil},
        %{code: "time.left < 1m", result: "false", note: nil}
      ],
      see_also: ["world:time.elapsed", "action:finish", "node:score"]
    },
    "world:time.limit" => %{
      title: "time.limit",
      kind: "world value",
      summary: "The run's full length, in seconds.",
      details: nil,
      usage: "time.limit",
      inputs: [],
      output: "A number of seconds, like 1800 (30 minutes).",
      examples: [
        %{code: "time.limit", result: "1800", note: nil},
        %{code: "time.limit == 30m", result: "true", note: nil}
      ],
      see_also: ["setup:time_limit", "world:time.left"]
    },
    "world:player.name" => %{
      title: "player.name",
      kind: "world value",
      summary: "The player's name.",
      details: nil,
      usage: "player.name",
      inputs: [],
      output: "Text, like \"Vela\".",
      examples: [
        %{code: "player.name", result: ~S|"Vela"|, note: nil},
        %{code: ~S|"Welcome, {player.name}."|, result: ~S|"Welcome, Vela."|, note: nil}
      ],
      see_also: ["world:player.faction"]
    },
    "world:player.faction" => %{
      title: "player.faction",
      kind: "world value",
      summary: "The player's faction.",
      details: nil,
      usage: "player.faction",
      inputs: [],
      output: "Text: \"tetrarchy\", \"myrmezir\", \"cardan\", \"synelle\" or \"ark\".",
      examples: [
        %{code: "player.faction", result: ~S|"cardan"|, note: nil},
        %{code: ~S|player.faction == "cardan"|, result: "true", note: nil}
      ],
      see_also: ["setup:faction"]
    },
    "world:player.credit" => %{
      title: "player.credit",
      kind: "world value",
      summary: "The credits the player holds.",
      details: "Gifts from give() show here from the next second. Can be below 0 after a take().",
      usage: "player.credit",
      inputs: [],
      output: "A number, like 12,500.",
      examples: [
        %{code: "player.credit", result: "12500", note: nil},
        %{code: "fmt_number(player.credit)", result: ~S|"12,500"|, note: nil}
      ],
      see_also: ["world:player.income.credit", "action:give", "action:take"]
    },
    "world:player.technology" => %{
      title: "player.technology",
      kind: "world value",
      summary: "The technology the player holds.",
      details: nil,
      usage: "player.technology",
      inputs: [],
      output: "A number, like 3400.",
      examples: [%{code: "player.technology", result: "3400", note: nil}],
      see_also: ["world:player.income.technology"]
    },
    "world:player.ideology" => %{
      title: "player.ideology",
      kind: "world value",
      summary: "The ideology the player holds.",
      details: nil,
      usage: "player.ideology",
      inputs: [],
      output: "A number, like 850.",
      examples: [%{code: "player.ideology", result: "850", note: nil}],
      see_also: ["world:player.income.ideology"]
    },
    "world:player.income" => %{
      title: "player.income",
      kind: "world value",
      summary: "The player's income per game day, one number for each resource.",
      details: "Read one resource with .credit, .technology or .ideology.",
      usage: "player.income",
      inputs: [],
      output: "A record with credit, technology and ideology, like {credit: 1250, ideology: 95, technology: 310}.",
      examples: [
        %{code: "player.income", result: "{credit: 1250, ideology: 95, technology: 310}", note: nil},
        %{code: "player.income.credit", result: "1250", note: nil}
      ],
      see_also: ["world:player.income.credit", "world:player.systems[].income"]
    },
    "world:player.income.credit" => %{
      title: "player.income.credit",
      kind: "world value",
      summary: "The player's credit income, per game day.",
      details: nil,
      usage: "player.income.credit",
      inputs: [],
      output: "A number, like 1250.",
      examples: [%{code: "player.income.credit", result: "1250", note: nil}],
      see_also: ["world:player.credit", "world:player.income"]
    },
    "world:player.income.technology" => %{
      title: "player.income.technology",
      kind: "world value",
      summary: "The player's technology income, per game day.",
      details: nil,
      usage: "player.income.technology",
      inputs: [],
      output: "A number, like 310.",
      examples: [%{code: "player.income.technology", result: "310", note: nil}],
      see_also: ["world:player.technology", "world:player.income"]
    },
    "world:player.income.ideology" => %{
      title: "player.income.ideology",
      kind: "world value",
      summary: "The player's ideology income, per game day.",
      details: nil,
      usage: "player.income.ideology",
      inputs: [],
      output: "A number, like 95.",
      examples: [%{code: "player.income.ideology", result: "95", note: nil}],
      see_also: ["world:player.ideology", "world:player.income"]
    },
    "world:player.systems" => %{
      title: "player.systems",
      kind: "world value",
      summary: "The player's systems, home system first. Dominions aren't included.",
      details:
        "Go through them with for each, or with map, filter and sum. Each system's fields are listed under s.name, s.population and so on.",
      usage: "player.systems",
      inputs: [],
      output:
        "A list of systems; each is a record with id, name, home, population, housing, stability, production, intelligence, defense and income.",
      examples: [
        %{code: "len(player.systems)", result: "2", note: nil},
        %{code: "map(player.systems, s => s.name)", result: ~S|["Vael", "Ossuar"]|, note: nil},
        %{code: "player.systems[0].population", result: "14", note: "the home system"}
      ],
      see_also: ["world:player.systems[].name", "node:for_each", "builtin:map"]
    },
    "world:player.systems_owned" => %{
      title: "player.systems_owned",
      kind: "world value",
      summary: "How many systems the player owns.",
      details: "The same as len(player.systems). Dominions are counted apart, in player.dominions.",
      usage: "player.systems_owned",
      inputs: [],
      output: "A whole number, like 2.",
      examples: [%{code: "player.systems_owned", result: "2", note: nil}],
      see_also: ["world:player.dominions", "world:player.systems"]
    },
    "world:player.dominions" => %{
      title: "player.dominions",
      kind: "world value",
      summary: "How many dominions the player holds.",
      details: "Dominions aren't in player.systems; they count here and in player.population.",
      usage: "player.dominions",
      inputs: [],
      output: "A whole number, like 1.",
      examples: [
        %{code: "player.dominions", result: "1", note: nil},
        %{code: "player.systems_owned + player.dominions", result: "3", note: "everything the player holds"}
      ],
      see_also: ["world:player.systems_owned"]
    },
    "world:player.population" => %{
      title: "player.population",
      kind: "world value",
      summary: "The player's total population, systems and dominions together.",
      details: nil,
      usage: "player.population",
      inputs: [],
      output: "A number, like 23.",
      examples: [%{code: "player.population", result: "23", note: nil}],
      see_also: ["world:player.systems[].population"]
    },
    "world:player.agents" => %{
      title: "player.agents",
      kind: "world value",
      summary: "The player's own agents: Navarchs, Siderians and Erased.",
      details: "Includes agents still in the deck; check a.status to tell them apart.",
      usage: "player.agents",
      inputs: [],
      output: "A list of agents; each is a record with id, name, type, level, status, system and fleet.",
      examples: [
        %{code: "map(player.agents, a => a.name)", result: ~S|["Orsa Kell", "Mire", "Talo Venn"]|, note: nil},
        %{code: ~S|count(player.agents, a => a.type == "navarch")|, result: "1", note: nil}
      ],
      see_also: ["world:player.agents[].type", "world:player.agents[].status", "builtin:filter"]
    },
    "world:player.patents" => %{
      title: "player.patents",
      kind: "world value",
      summary: "The patents the player has, by name.",
      details:
        "A patent's name is its English name in lowercase, with _ for spaces: Precision Cranes is \"precision_cranes\". Test for one with in.",
      usage: "player.patents",
      inputs: [],
      output: "A list of patent names, like [\"armoring\", \"precision_cranes\"].",
      examples: [
        %{code: "player.patents", result: ~S|["armoring", "precision_cranes"]|, note: nil},
        %{code: ~S|"armoring" in player.patents|, result: "true", note: nil},
        %{code: "len(player.patents)", result: "2", note: nil}
      ],
      see_also: ["operator:in", "setup:grant_patents"]
    },
    "world:player.wonders" => %{
      title: "player.wonders",
      kind: "world value",
      summary: "The wonders the player has built, by key.",
      details: nil,
      usage: "player.wonders",
      inputs: [],
      output: "A list of wonder keys, like [\"monument_dome\"] for The Monolith.",
      examples: [
        %{code: "player.wonders", result: ~S|["monument_dome"]|, note: nil},
        %{code: ~S|"monument_dome" in player.wonders|, result: "true", note: nil}
      ],
      see_also: ["operator:in"]
    },
    "world:player.agents_removed" => %{
      title: "player.agents_removed",
      kind: "world value",
      summary: "How many enemy agents the player's Erased have removed.",
      details: nil,
      usage: "player.agents_removed",
      inputs: [],
      output: "A whole number, like 2.",
      examples: [%{code: "player.agents_removed", result: "2", note: nil}],
      see_also: ["action:send_agent", "world:rival.agents_left"]
    },
    "world:rival.present" => %{
      title: "rival.present",
      kind: "world value",
      summary: "Whether the scenario has a rival court (rival = true in setup).",
      details: nil,
      usage: "rival.present",
      inputs: [],
      output: "True or false.",
      examples: [%{code: "rival.present", result: "true", note: nil}],
      see_also: ["setup:rival", "action:send_agent"]
    },
    "world:rival.faction" => %{
      title: "rival.faction",
      kind: "world value",
      summary: "The rival court's faction.",
      details: "nil when the scenario has no rival court.",
      usage: "rival.faction",
      inputs: [],
      output: "Text, like \"myrmezir\", or nil.",
      examples: [%{code: "rival.faction", result: ~S|"myrmezir"|, note: nil}],
      see_also: ["world:rival.present"]
    },
    "world:rival.agents_sent" => %{
      title: "rival.agents_sent",
      kind: "world value",
      summary: "How many agents the rival court has sent so far.",
      details: nil,
      usage: "rival.agents_sent",
      inputs: [],
      output: "A whole number, like 5.",
      examples: [%{code: "rival.agents_sent", result: "5", note: nil}],
      see_also: ["action:send_agent", "world:rival.agents_left"]
    },
    "world:rival.agents_left" => %{
      title: "rival.agents_left",
      kind: "world value",
      summary: "How many of the rival court's agents are still in play.",
      details: nil,
      usage: "rival.agents_left",
      inputs: [],
      output: "A whole number, like 3.",
      examples: [
        %{code: "rival.agents_left", result: "3", note: nil},
        %{code: "rival.agents_sent - rival.agents_left", result: "2", note: "the ones gone"}
      ],
      see_also: ["world:rival.agents_sent", "world:player.agents_removed"]
    },
    "world:scenario.name" => %{
      title: "scenario.name",
      kind: "world value",
      summary: "This scenario's name, as setup gives it.",
      details: nil,
      usage: "scenario.name",
      inputs: [],
      output: "Text, like \"Frontier Watch\".",
      examples: [%{code: "scenario.name", result: ~S|"Frontier Watch"|, note: nil}],
      see_also: ["setup:name"]
    },
    "world:scenario.systems" => %{
      title: "scenario.systems",
      kind: "world value",
      summary: "How many systems the starting sector holds, as setup gives it.",
      details: nil,
      usage: "scenario.systems",
      inputs: [],
      output: "A whole number from 1 to 8, like 2.",
      examples: [%{code: "scenario.systems", result: "2", note: nil}],
      see_also: ["setup:systems", "world:player.systems_owned"]
    },
    "world:scenario.time_limit" => %{
      title: "scenario.time_limit",
      kind: "world value",
      summary: "The scenario's run length in seconds, as setup gives it.",
      details: nil,
      usage: "scenario.time_limit",
      inputs: [],
      output: "A number of seconds, like 1800 (30 minutes).",
      examples: [%{code: "scenario.time_limit", result: "1800", note: nil}],
      see_also: ["setup:time_limit", "world:time.limit"]
    },
    # each system of player.systems
    "world:player.systems[].id" => %{
      title: "player.systems[].id",
      kind: "world value",
      summary: "The system's id: the number destabilize and send_agent take as system:.",
      details: nil,
      usage: "s.id, for a system s of player.systems",
      inputs: [],
      output: "A number, like 101.",
      examples: [
        %{code: "player.systems[0].id", result: "101", note: nil},
        %{code: "map(player.systems, s => s.id)", result: "[101, 102]", note: nil}
      ],
      see_also: ["action:destabilize", "action:send_agent"]
    },
    "world:player.systems[].name" => %{
      title: "player.systems[].name",
      kind: "world value",
      summary: "The system's name.",
      details: nil,
      usage: "s.name, for a system s of player.systems",
      inputs: [],
      output: "Text, like \"Vael\".",
      examples: [
        %{code: "player.systems[0].name", result: ~S|"Vael"|, note: nil},
        %{code: "map(player.systems, s => s.name)", result: ~S|["Vael", "Ossuar"]|, note: nil}
      ],
      see_also: ["world:player.systems"]
    },
    "world:player.systems[].home" => %{
      title: "player.systems[].home",
      kind: "world value",
      summary: "Whether this is the player's first system, their home.",
      details: nil,
      usage: "s.home, for a system s of player.systems",
      inputs: [],
      output: "True or false.",
      examples: [
        %{code: "player.systems[0].home", result: "true", note: nil},
        %{code: "find(player.systems, s => not s.home).name", result: ~S|"Ossuar"|, note: nil}
      ],
      see_also: ["world:player.systems"]
    },
    "world:player.systems[].population" => %{
      title: "player.systems[].population",
      kind: "world value",
      summary: "The system's population.",
      details: nil,
      usage: "s.population, for a system s of player.systems",
      inputs: [],
      output: "A number, like 14.",
      examples: [
        %{code: "player.systems[0].population", result: "14", note: nil},
        %{code: "sum(player.systems, s => s.population)", result: "20", note: nil}
      ],
      see_also: ["world:player.systems[].housing", "world:player.population"]
    },
    "world:player.systems[].housing" => %{
      title: "player.systems[].housing",
      kind: "world value",
      summary: "How much population the system can house.",
      details: nil,
      usage: "s.housing, for a system s of player.systems",
      inputs: [],
      output: "A number, like 18.",
      examples: [
        %{code: "player.systems[0].housing", result: "18", note: nil},
        %{code: "player.systems[0].housing - player.systems[0].population", result: "4", note: "room to grow"}
      ],
      see_also: ["world:player.systems[].population"]
    },
    "world:player.systems[].stability" => %{
      title: "player.systems[].stability",
      kind: "world value",
      summary: "The system's stability.",
      details: "destabilize lowers it.",
      usage: "s.stability, for a system s of player.systems",
      inputs: [],
      output: "A number, like 62.",
      examples: [
        %{code: "player.systems[1].stability", result: "41", note: nil},
        %{code: "min_by(player.systems, s => s.stability).name", result: ~S|"Ossuar"|, note: "the least stable"}
      ],
      see_also: ["action:destabilize"]
    },
    "world:player.systems[].production" => %{
      title: "player.systems[].production",
      kind: "world value",
      summary: "The system's production.",
      details: nil,
      usage: "s.production, for a system s of player.systems",
      inputs: [],
      output: "A number, like 40.",
      examples: [
        %{code: "player.systems[0].production", result: "40", note: nil},
        %{code: "sum(player.systems, s => s.production)", result: "55", note: nil}
      ],
      see_also: ["world:player.systems"]
    },
    "world:player.systems[].intelligence" => %{
      title: "player.systems[].intelligence",
      kind: "world value",
      summary: "The system's Intelligence: how well it resists enemy agents.",
      details: nil,
      usage: "s.intelligence, for a system s of player.systems",
      inputs: [],
      output: "A number, like 25.",
      examples: [%{code: "player.systems[0].intelligence", result: "25", note: nil}],
      see_also: ["action:send_agent"]
    },
    "world:player.systems[].defense" => %{
      title: "player.systems[].defense",
      kind: "world value",
      summary: "The system's defense.",
      details: nil,
      usage: "s.defense, for a system s of player.systems",
      inputs: [],
      output: "A number, like 30.",
      examples: [%{code: "player.systems[0].defense", result: "30", note: nil}],
      see_also: ["world:player.systems"]
    },
    "world:player.systems[].income" => %{
      title: "player.systems[].income",
      kind: "world value",
      summary: "The system's own income per game day, one number for each resource.",
      details: "Read one resource with .credit, .technology or .ideology.",
      usage: "s.income, for a system s of player.systems",
      inputs: [],
      output: "A record with credit, technology and ideology, like {credit: 900, ideology: 60, technology: 220}.",
      examples: [
        %{code: "player.systems[0].income", result: "{credit: 900, ideology: 60, technology: 220}", note: nil}
      ],
      see_also: ["world:player.systems[].income.credit", "world:player.income"]
    },
    "world:player.systems[].income.credit" => %{
      title: "player.systems[].income.credit",
      kind: "world value",
      summary: "The system's credit income, per game day.",
      details: nil,
      usage: "s.income.credit, for a system s of player.systems",
      inputs: [],
      output: "A number, like 900.",
      examples: [
        %{code: "player.systems[0].income.credit", result: "900", note: nil},
        %{code: "max_by(player.systems, s => s.income.credit).name", result: ~S|"Vael"|, note: "the richest"}
      ],
      see_also: ["world:player.income.credit"]
    },
    "world:player.systems[].income.technology" => %{
      title: "player.systems[].income.technology",
      kind: "world value",
      summary: "The system's technology income, per game day.",
      details: nil,
      usage: "s.income.technology, for a system s of player.systems",
      inputs: [],
      output: "A number, like 220.",
      examples: [%{code: "player.systems[0].income.technology", result: "220", note: nil}],
      see_also: ["world:player.income.technology"]
    },
    "world:player.systems[].income.ideology" => %{
      title: "player.systems[].income.ideology",
      kind: "world value",
      summary: "The system's ideology income, per game day.",
      details: nil,
      usage: "s.income.ideology, for a system s of player.systems",
      inputs: [],
      output: "A number, like 60.",
      examples: [%{code: "player.systems[0].income.ideology", result: "60", note: nil}],
      see_also: ["world:player.income.ideology"]
    },
    # each agent of player.agents
    "world:player.agents[].id" => %{
      title: "player.agents[].id",
      kind: "world value",
      summary: "The agent's id number.",
      details: nil,
      usage: "a.id, for an agent a of player.agents",
      inputs: [],
      output: "A number, like 7.",
      examples: [%{code: "player.agents[0].id", result: "7", note: nil}],
      see_also: ["world:player.agents"]
    },
    "world:player.agents[].name" => %{
      title: "player.agents[].name",
      kind: "world value",
      summary: "The agent's name.",
      details: nil,
      usage: "a.name, for an agent a of player.agents",
      inputs: [],
      output: "Text, like \"Orsa Kell\".",
      examples: [%{code: "player.agents[0].name", result: ~S|"Orsa Kell"|, note: nil}],
      see_also: ["world:player.agents"]
    },
    "world:player.agents[].type" => %{
      title: "player.agents[].type",
      kind: "world value",
      summary: "What kind of agent it is: a Navarch, a Siderian or an Erased.",
      details: nil,
      usage: "a.type, for an agent a of player.agents",
      inputs: [],
      output: "Text: \"navarch\", \"siderian\" or \"erased\".",
      examples: [
        %{code: "player.agents[0].type", result: ~S|"navarch"|, note: nil},
        %{code: ~S|count(player.agents, a => a.type == "erased")|, result: "1", note: nil}
      ],
      see_also: ["world:player.agents", "builtin:filter"]
    },
    "world:player.agents[].level" => %{
      title: "player.agents[].level",
      kind: "world value",
      summary: "The agent's level.",
      details: nil,
      usage: "a.level, for an agent a of player.agents",
      inputs: [],
      output: "A whole number, like 4.",
      examples: [
        %{code: "player.agents[0].level", result: "4", note: nil},
        %{code: "max(map(player.agents, a => a.level))", result: "4", note: "the highest level"}
      ],
      see_also: ["builtin:max_by"]
    },
    "world:player.agents[].status" => %{
      title: "player.agents[].status",
      kind: "world value",
      summary: "Where the agent is: in the deck, on the board, or governing a system.",
      details: nil,
      usage: "a.status, for an agent a of player.agents",
      inputs: [],
      output: "Text: \"deck\" (not in play), \"board\" (on the board) or \"governor\".",
      examples: [
        %{code: "player.agents[2].status", result: ~S|"governor"|, note: nil},
        %{code: ~S|count(player.agents, a => a.status == "board")|, result: "2", note: nil}
      ],
      see_also: ["world:player.agents[].system"]
    },
    "world:player.agents[].system" => %{
      title: "player.agents[].system",
      kind: "world value",
      summary: "The id of the system the agent is in.",
      details: "nil for an agent who isn't in a system, such as one still in the deck.",
      usage: "a.system, for an agent a of player.agents",
      inputs: [],
      output: "A number, like 101, or nil.",
      examples: [%{code: "player.agents[0].system", result: "101", note: nil}],
      see_also: ["world:player.systems[].id", "world:player.agents[].status"]
    },
    "world:player.agents[].fleet" => %{
      title: "player.agents[].fleet",
      kind: "world value",
      summary: "A Navarch's fleet: its raid and invasion strength and its upkeep.",
      details: "All three are 0 for Siderians and Erased.",
      usage: "a.fleet, for an agent a of player.agents",
      inputs: [],
      output: "A record with raid, invasion and upkeep, like {invasion: 80, raid: 120, upkeep: 35}.",
      examples: [%{code: "player.agents[0].fleet", result: "{invasion: 80, raid: 120, upkeep: 35}", note: nil}],
      see_also: ["world:player.agents[].fleet.raid"]
    },
    "world:player.agents[].fleet.raid" => %{
      title: "player.agents[].fleet.raid",
      kind: "world value",
      summary: "The fleet's raid strength.",
      details: nil,
      usage: "a.fleet.raid, for an agent a of player.agents",
      inputs: [],
      output: "A number, like 120.",
      examples: [
        %{code: "player.agents[0].fleet.raid", result: "120", note: nil},
        %{code: "max(map(player.agents, a => a.fleet.raid))", result: "120", note: "the strongest raider"}
      ],
      see_also: ["world:player.agents[].fleet"]
    },
    "world:player.agents[].fleet.invasion" => %{
      title: "player.agents[].fleet.invasion",
      kind: "world value",
      summary: "The fleet's invasion strength.",
      details: nil,
      usage: "a.fleet.invasion, for an agent a of player.agents",
      inputs: [],
      output: "A number, like 80.",
      examples: [%{code: "player.agents[0].fleet.invasion", result: "80", note: nil}],
      see_also: ["world:player.agents[].fleet"]
    },
    "world:player.agents[].fleet.upkeep" => %{
      title: "player.agents[].fleet.upkeep",
      kind: "world value",
      summary: "The fleet's upkeep.",
      details: nil,
      usage: "a.fleet.upkeep, for an agent a of player.agents",
      inputs: [],
      output: "A number, like 35.",
      examples: [
        %{code: "player.agents[0].fleet.upkeep", result: "35", note: nil},
        %{code: "sum(player.agents, a => a.fleet.upkeep)", result: "35", note: "all fleets together"}
      ],
      see_also: ["world:player.agents[].fleet"]
    }
  }

  # --- the graph's nodes --------------------------------------------------------

  @nodes %{
    "node:let" => %{
      title: "let",
      kind: "step",
      summary: "Gives a value a name, so the steps after it can use it.",
      details:
        "The name lasts until the end of its chain (the steps inside the same { }). Change it later with a set step. For a value kept from one event to the next, use a var.",
      usage: "let name = value",
      inputs: [
        %{name: "name", doc: "The new name: letters, digits and _, starting with a letter."},
        %{name: "be", doc: "The value to name: anything."}
      ],
      output: "Nothing flows out; the steps after it can use the name.",
      examples: [
        %{
          code: ~s|let bonus = 500 * len(player.systems)\ngive("credit", bonus)\nnotify("Bonus: {bonus} credits.")|,
          result: nil,
          note: nil
        }
      ],
      see_also: ["node:set", "node:var", "keyword:let"]
    },
    "node:set" => %{
      title: "set",
      kind: "step",
      summary: "Changes the value of a let or a var, or of one field or item inside one.",
      details:
        "The name must exist already, made by a let or a var. A var can be changed only by an event's steps (on, every, at, when), never by a score or a condition. The game itself (player, time …) can't be set; use an action such as give.",
      usage: "name = value",
      inputs: [
        %{name: "target", doc: "What to change: a name, or a field or item of one, like tally.raids or xs[0]."},
        %{name: "to", doc: "The new value."}
      ],
      output: "Nothing flows out; a step.",
      examples: [
        %{code: ~s|var waves = 0\n\nevery 1m {\n  waves = waves + 1\n}|, result: nil, note: nil},
        %{
          code: ~s|var tally = {raids: 0}\n\nevery 2m {\n  tally.raids = tally.raids + 1\n}|,
          result: nil,
          note: "one field of a var"
        }
      ],
      see_also: ["node:let", "node:var", "builtin:put"]
    },
    "node:if" => %{
      title: "if",
      kind: "step",
      summary: "Runs one chain of steps when a condition is true, and another, if you want, when it's false.",
      details:
        "The condition must be true or false: a comparison, a test such as \"armoring\" in player.patents, or several joined with and, or, not. The steps after the if run either way.",
      usage: "if condition { … } else { … }",
      inputs: [%{name: "condition", doc: "True or false, like player.credit < 1000."}],
      output:
        "Nothing flows out. Its exits: true runs when the condition holds, false when it doesn't, and after runs next either way.",
      examples: [
        %{
          code: ~s|if player.credit < 1000 {\n  give("credit", 500)\n} else {\n  notify("You're doing fine.")\n}|,
          result: nil,
          note: nil
        }
      ],
      see_also: ["node:if_then_else", "keyword:else", "operator:and"]
    },
    "node:for_each" => %{
      title: "for each",
      kind: "step",
      summary: "Runs a chain of steps once for each item of a list.",
      details:
        "The name you give holds the current item each time round: s in for s in player.systems is one system, then the next. It needs a list; for a record, go through keys(r). To count, use range(1, 10).",
      usage: "for item in list { … }",
      inputs: [
        %{name: "name", doc: "The name for the current item, like s."},
        %{name: "in", doc: "The list to go through, like player.systems."}
      ],
      output: "Nothing flows out. Its exits: each runs once per item, and after runs when the list is done.",
      examples: [
        %{
          code:
            ~s|for s in player.systems {\n  if s.stability < 50 {\n    notify("{s.name} is restless.", tone: "warning")\n  }\n}|,
          result: nil,
          note: nil
        },
        %{code: ~s|for i in range(1, 3) {\n  give("credit", 100 * i)\n}|, result: nil, note: "100, 200, then 300"}
      ],
      see_also: ["keyword:break", "keyword:continue", "builtin:range", "node:while"]
    },
    "node:while" => %{
      title: "while",
      kind: "step",
      summary: "Repeats a chain of steps as long as a condition stays true.",
      details:
        "The condition is checked before each pass, so something in the chain must make it false. A loop that never ends stops when the script runs out of steps (200,000 a second). A for each is usually simpler.",
      usage: "while condition { … }",
      inputs: [%{name: "condition", doc: "True or false; checked before each pass."}],
      output: "Nothing flows out. Its exits: repeat runs while the condition holds, and after runs when it stops.",
      examples: [
        %{code: ~s|let n = 1\nwhile n < 100 {\n  n = n * 2\n}\nlog(n)|, result: nil, note: "logs 128"}
      ],
      see_also: ["node:for_each", "keyword:break"]
    },
    "node:return" => %{
      title: "return",
      kind: "step",
      summary: "Inside a fn, stops it and gives a value back to the place that used it.",
      details: "The value flows out of the fn's call. A fn that ends without return gives nil. Only inside a fn.",
      usage: "return value",
      inputs: [%{name: "value", doc: "Optional. What the fn gives back."}],
      output: "Nothing flows on: the fn stops here.",
      examples: [
        %{
          code:
            ~s|fn bonus_for(wave) {\n  return 100 * wave\n}\n\nevery 1m as wave {\n  give("credit", bonus_for(wave))\n}|,
          result: nil,
          note: nil
        }
      ],
      see_also: ["node:fn", "node:call"]
    },
    "node:unused_value" => %{
      title: "unused value",
      kind: "step",
      summary: "A value standing on its own, plugged into nothing, so it does nothing.",
      details:
        "A value only matters once it goes somewhere: into a score, a condition, an action's input or a let. Often it's a half-typed name such as player. left on its own; finish it and wire it in, or delete it.",
      usage: "a value on a line of its own",
      inputs: [%{name: "value", doc: "The value that isn't used."}],
      output: "Nothing: the value is worked out and thrown away.",
      examples: [
        %{code: "let doubled = player.credit * 2", result: nil, note: "named, so later steps can use it"},
        %{code: ~S|give("credit", player.income.credit * 2)|, result: nil, note: "plugged into an action"}
      ],
      see_also: ["node:let", "node:score", "node:if"]
    },
    "node:call" => %{
      title: "call",
      kind: "step",
      summary: "Uses a fn you wrote: runs its steps with the inputs you give it.",
      details:
        "Inputs go in the fn's order, or by name: area(h: 3, w: 4). If the fn gives back a value with return, it flows out and can be wired into another input.",
      usage: "name(a, b)",
      inputs: [%{name: "inputs", doc: "One for each name in the fn's ( ), in that order."}],
      output: "What the fn gives back with return, or nil when it gives back nothing.",
      examples: [
        %{
          code: ~s|fn area(w, h) {\n  return w * h\n}\n\non start {\n  give("credit", area(h: 3, w: 4))\n}|,
          result: nil,
          note: "gives 12"
        }
      ],
      see_also: ["node:fn", "node:return"]
    },
    "node:field" => %{
      title: ".name",
      kind: "value",
      summary: "Reads one field of a record: the .population of a system, the .credit of an income.",
      details:
        "The record comes in through of. A field the record doesn't have gives nil, and reading a field of nil is an error, which happens when first, find or a position found nothing.",
      usage: "record.field",
      inputs: [%{name: "of", doc: "The record to read, like one system."}],
      output: "The field's value: a number, a text, a list or a record, depending on the field.",
      examples: [
        %{code: "player.systems[0].name", result: ~S|"Vael"|, note: nil},
        %{code: "{credit: 500, ideology: 50}.credit", result: "500", note: nil}
      ],
      see_also: ["builtin:get", "node:record"]
    },
    "node:item_at" => %{
      title: "item at",
      kind: "value",
      summary: "The item at a position in a list, counting from 0.",
      details:
        "0 is the first item and 1 the second; -1 is the last. A position past the end gives nil. On a record, text in the [ ] reads that field: r[\"two words\"].",
      usage: "list[position]",
      inputs: [
        %{name: "of", doc: "The list."},
        %{name: "position", doc: "A whole number: 0 for the first item, -1 for the last."}
      ],
      output: "The item, whatever it holds, or nil when the position is outside the list.",
      examples: [
        %{code: "[10, 20, 30][0]", result: "10", note: nil},
        %{code: "[10, 20, 30][-1]", result: "30", note: nil},
        %{code: "player.systems[1].name", result: ~S|"Ossuar"|, note: nil}
      ],
      see_also: ["builtin:first", "builtin:last", "builtin:slice"]
    },
    "node:list" => %{
      title: "list",
      kind: "value",
      summary: "Several values in order, written [a, b, c].",
      details:
        "Items can be anything, even lists or records. Positions count from 0. A list never changes: push, concat and + make new ones.",
      usage: "[a, b, c]",
      inputs: [%{name: "items", doc: "The items, in order: 0, 1, 2 …"}],
      output: "A list, like [1, 2, 3].",
      examples: [
        %{code: "[1, 2, 3]", result: "[1, 2, 3]", note: nil},
        %{code: ~S|len(["credit", "technology"])|, result: "2", note: nil}
      ],
      see_also: ["node:item_at", "builtin:len", "builtin:push"]
    },
    "node:record" => %{
      title: "record",
      kind: "value",
      summary: "Named values grouped together, written {credit: 500, ideology: 50}.",
      details:
        "Read a field with .name (r.credit) or get(r, \"credit\"). A name with spaces needs quotes: {\"two words\": 2}. The game's own data comes as records: each system, each agent, player.income.",
      usage: "{name: value, …}",
      inputs: [%{name: "fields", doc: "One input for each field, labeled with its name."}],
      output: "A record, like {credit: 500, ideology: 50}.",
      examples: [
        %{code: "{credit: 500, ideology: 50}", result: "{credit: 500, ideology: 50}", note: nil},
        %{code: "keys({credit: 500, ideology: 50})", result: ~S|["credit", "ideology"]|, note: nil}
      ],
      see_also: ["node:field", "builtin:get", "builtin:keys"]
    },
    "node:lambda" => %{
      title: "short function",
      kind: "value",
      summary: "A small rule, written x => …, that a list function uses on each item.",
      details:
        "x => x * 2 means: given x, give back x * 2. The name before => stands for each item in turn, so in sum(player.systems, s => s.population), s is one system at a time. It shows as code inside the input.",
      usage: "x => …  or  (a, b) => …",
      inputs: [],
      output: "A function, for the fn input of map, filter, sum, count, find, any, all, sort_by, max_by or min_by.",
      examples: [
        %{code: "map([1, 2, 3], x => x * 2)", result: "[2, 4, 6]", note: nil},
        %{code: "count(player.agents, a => a.level >= 3)", result: "2", note: nil}
      ],
      see_also: ["builtin:map", "builtin:filter", "builtin:sum"]
    },
    "node:template" => %{
      title: "text with {holes}",
      kind: "value",
      summary: "Text with values filled in, like \"Wave {n} of 10\".",
      details:
        "Each {…} holds a short formula, worked out and written as text; it can't contain quotes or braces. Numbers show in plain digits (12500); wrap them in fmt_number for 12,500.",
      usage: "\"text {value} text\"",
      inputs: [],
      output: "Text, like \"You hold 12,500 credits\".",
      examples: [
        %{
          code: ~S|"You hold {fmt_number(player.credit)} credits"|,
          result: ~S|"You hold 12,500 credits"|,
          note: nil
        },
        %{
          code: ~S|"You hold {player.credit} credits"|,
          result: ~S|"You hold 12500 credits"|,
          note: "without fmt_number"
        },
        %{code: ~S|"Systems: {len(player.systems)}"|, result: ~S|"Systems: 2"|, note: nil}
      ],
      see_also: ["builtin:fmt_number", "builtin:str", "action:notify"]
    },
    "node:if_then_else" => %{
      title: "if … then … else",
      kind: "value",
      summary: "Picks one of two values, depending on a condition.",
      details:
        "Gives the then value when the condition is true and the else value when it's false; only the chosen side is worked out. Unlike the if step, it's a value, and it always needs both.",
      usage: "if condition then a else b",
      inputs: [
        %{name: "if", doc: "True or false."},
        %{name: "then", doc: "The value when true."},
        %{name: "else", doc: "The value when false."}
      ],
      output: "Whichever value was picked, like \"rich\".",
      examples: [
        %{code: ~S|if player.credit > 10_000 then "rich" else "poor"|, result: ~S|"rich"|, note: nil},
        %{code: ~S|if "armoring" in player.patents then 0 else 1|, result: "0", note: nil}
      ],
      see_also: ["node:if", "keyword:then"]
    },
    "node:note" => %{
      title: "note",
      kind: "part",
      summary: "A comment: words for people reading the scenario, ignored when it runs.",
      details:
        "In text, a line starting with #. A comment right above a part or a step becomes its note and shows on its node; one followed by a blank line stands alone.",
      usage: "# your words",
      inputs: [],
      output: nil,
      examples: [
        %{code: ~s|# Players are ranked by the credits they hold.\nscore player.credit|, result: nil, note: nil}
      ],
      see_also: ["node:draft"]
    },
    "node:draft" => %{
      title: "draft",
      kind: "part",
      summary: "Loose nodes, connected to nothing: they never run and aren't checked.",
      details:
        "A place for half-finished ideas. A loose node gets a warning that it never runs, so a mistake in it isn't taken for working code. In text, loose nodes sit inside draft { … }.",
      usage: "draft { … }",
      inputs: [],
      output: nil,
      examples: [%{code: ~s|draft {\n  give("credit", 1000)\n}|, result: nil, note: nil}],
      see_also: ["node:note", "keyword:draft"]
    },
    "node:code" => %{
      title: "code",
      kind: "part",
      summary: "A part shown as a line of code instead of as nodes.",
      details:
        "Any node can switch: right-click it and choose Show as code; ⤢ turns it back into nodes. Long formulas (over twelve parts) start as code, and short functions and text with {holes} always show as code.",
      usage: "any value or steps, written as text",
      inputs: [],
      output: "Whatever the code gives: a value for the input it sits in, or nothing when it's a step.",
      examples: [
        %{code: "sum(player.systems, s => s.income.credit)", result: "1250", note: "one line instead of three nodes"}
      ],
      see_also: ["node:lambda", "node:template"]
    },
    "node:setup" => %{
      title: "Scenario setup",
      kind: "part",
      summary: "The world the run starts in: its name, length, faction, sector, rival, mutators and patents.",
      details:
        "Each row sets one setup field; fields left out keep their defaults. Setup is worked out before the game starts, so it can't read player or time, and can't use actions.",
      usage: "setup { field = value … }",
      inputs: [%{name: "fields", doc: "One row for each field: name, description, time_limit and the rest."}],
      output: nil,
      examples: [
        %{
          code:
            ~s|setup {\n  name = "Land Rush"\n  description = "Colonize as many systems as you can."\n  time_limit = 30m\n  systems = 6\n}|,
          result: nil,
          note: nil
        }
      ],
      see_also: ["setup:name", "setup:time_limit", "setup:systems", "keyword:setup"]
    },
    "node:score" => %{
      title: "score",
      kind: "part",
      summary: "The number players are ranked by when the run ends; higher ranks first.",
      details:
        "It is counted once, at the deadline or when finish() is called. It can read the game and your vars, but can't use actions. A race scores time.left and calls finish() at the goal.",
      usage: "score number",
      inputs: [%{name: "value", doc: "A number, like player.credit."}],
      output: nil,
      examples: [
        %{code: "score player.credit", result: nil, note: nil},
        %{code: "score trunc(min(player.income.credit, player.income.technology))", result: nil, note: nil}
      ],
      see_also: ["node:tiebreak", "action:finish", "world:time.left"]
    },
    "node:tiebreak" => %{
      title: "tiebreak",
      kind: "part",
      summary: "A second number that ranks players whose scores are equal; higher ranks first.",
      details: "Counted at the same moment as the score, with the same rules.",
      usage: "tiebreak number",
      inputs: [%{name: "value", doc: "A number, like len(player.patents)."}],
      output: nil,
      examples: [%{code: ~s|score time.left\n\ntiebreak len(player.patents)|, result: nil, note: nil}],
      see_also: ["node:score"]
    },
    "node:var" => %{
      title: "var",
      kind: "part",
      summary: "A value the scenario keeps from one event to the next, like a counter.",
      details:
        "starts at sets its value as the run begins; it can't read the game yet. Events change it with a set step, while scores and conditions can only read it. If an event's steps fail, their changes are undone.",
      usage: "var name = starting value",
      inputs: [
        %{name: "name", doc: "The var's name: letters, digits and _, starting with a letter."},
        %{name: "starts at", doc: "Its value when the run begins, like 0 or []."}
      ],
      output: nil,
      examples: [
        %{
          code:
            ~s|var raids = 0\n\nevery 2m {\n  raids = raids + 1\n  notify("Raid {raids} hits.", tone: "warning")\n}|,
          result: nil,
          note: nil
        }
      ],
      see_also: ["node:set", "node:let"]
    },
    "node:fn" => %{
      title: "fn",
      kind: "part",
      summary: "A function of your own: a named chain of steps you can use from anywhere.",
      details:
        "List its inputs' names in the ( ); give back a value with return. A fn that uses an action or changes a var works only in events (on, every, at, when), not in a score or a condition. Ctrl+G groups selected steps into a new fn.",
      usage: "fn name(a, b) { … }",
      inputs: [
        %{name: "name", doc: "The fn's name."},
        %{name: "params", doc: "The names of its inputs, separated by commas."}
      ],
      output: nil,
      examples: [
        %{
          code:
            ~s|fn richest() {\n  return max_by(player.systems, s => s.income.credit)\n}\n\nscore richest().income.credit|,
          result: nil,
          note: nil
        }
      ],
      see_also: ["node:call", "node:return", "keyword:fn"]
    }
  }

  @entries [
             @math,
             @text,
             @lists,
             @records,
             @chance,
             @actions,
             @events,
             @keywords,
             @operators,
             @setup,
             @world_values,
             @nodes
           ]
           |> Enum.reduce(%{}, &Map.merge(&2, &1))

  @doc "Every entry, by key (`\"builtin:sum\"`, `\"world:player.patents\"`, `\"node:for_each\"` …)."
  def all, do: @entries

  @doc "One entry by key, or nil."
  def get(key), do: Map.get(@entries, key)
end

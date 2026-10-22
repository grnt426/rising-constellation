# Edict for VS Code

Write [Tetrarchy Falls](https://tetrarchyfalls.com) scenarios in Edict, the
game's scenario language, with:

- highlighting for `.edict` files
- completion for builtins, actions, world fields (`player.income.` lists
  `credit`, `technology`, `ideology`), setup fields, the values a place takes
  (`give("` offers the resources), names in scope, and snippets for every
  part of a scenario
- hover docs and signature help
- an outline of the scenario, and go to definition
- the game's checks for text it can't read (unclosed quotes and brackets,
  unknown escapes, hidden text-direction characters)

The names, docs and signatures come from the game's own catalog (version
{{version}}), so they match what the game accepts.

The full check (names, types, setup values) runs in the game: in the
Scenario Workshop, **File > Link a file** (Chrome and Edge) keeps the
workshop in step with the file as you save it here.

The extension only reads the documents you're editing. It makes no network
calls.

## The language, if you program

Edict is a small language made for this game, not a cut-down version of
another one. If you program, it reads like Python written with braces,
borrowing a few things from others:

| From | In Edict |
|---|---|
| Python | `# comments`, `and` `or` `not`, `for x in xs { }`, `len(xs)`, `str(n)`, `1_000_000` |
| JavaScript | `{ … }` blocks, `x => x * 2`, `{key: 1}` records, `let` and `var` |
| Swift, Go | `if x > 1 { }` without parentheses, `nil`, named arguments `notify("Hi", tone: "good")` |
| Rust | `fn total(a, b) { return a + b }` |

Where it differs from what you might expect:

- No `;`: one statement per line.
- Conditions must be `true` or `false`; there is no truthy `0` or `""`.
- Every number is a decimal and `/` never truncates. `%` makes a percent
  (`25%` is `0.25`), so the remainder is `mod(17, 5)`. Durations are
  numbers of seconds: `15s`, `1m30s`, `1h`.
- Values, not references: `let b = a` copies, and `push(xs, 4)` returns a
  new list.
- Functions, not methods: `map(xs, f)`, `len(xs)`, `sort_by(xs, f)`. Text
  takes holes, `"wave {n}"`; the inline if is `if c then a else b`.
- Lists start at `0`; `range(1, 3)` is `[1, 2, 3]`.
- No classes, imports, exceptions or files. A script declares a `setup`, a
  `score`, `var`s and `fn`s, and reacts to events (`on start`,
  `every 15s`, `at 10m`, `when …`, `on end`); it changes the game only
  through actions such as `give()` and `notify()`, within a step budget
  each second.


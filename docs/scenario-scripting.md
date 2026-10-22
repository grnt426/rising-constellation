# Scenario scripting (Edict) and the Scenario Workshop

Players design their own daily-style challenges in a scripting language
called **Edict**, in a portal page called the **Scenario Workshop**
(`/portal/scenario-workshop`, under the top bar's **Sandbox** menu). A
scenario says what the world looks like, how players are ranked, and what
happens while they play. Authors build it as a graph of nodes or write it as
text; both are views of one program, and either can be edited at any time.

This document is the design and the record of what the MVP built: the
language, how the visual and textual layers stay one program, the security
model, how a script runs (simulated and live), how it was validated, and
what comes next.

Status (2026-10-22): scripts also run in Legacy, Tactic and Flash matches:
players save them to their account (ten each), publish them, and attach them
to Forge scenarios, where each is checked against the map and runs once per
player in every match (see "Scripts in matches"). A `shared var` holds one
value for the whole match, `end_match()` ends it with a named winner, and
the in-game leaderboard ranks every player by each script's score.

Status (2026-10-21): the MVP is built and tested end to end. Ten of the
shipped daily objectives are rebuilt as scripts and rank players exactly as
the hand-written versions do; a script can be simulated in the editor and
played in a real game ("Playtest"). Sharing scripts with other players is
the next phase, and the security model was designed for it. Scripts open
from and save to `.edict` files, a file can stay linked while it's edited
elsewhere, and generated editor kits bring the language to VS Code,
JetBrains IDEs, Notepad++ and any LSP editor. What scripts cost the server
is measured and bounded (see "What scripts cost"), and script text never
renders as HTML (see "Script text in the browser"). Every function,
action, event, operator and world value has plain-language docs with tested
examples, on hover and in the Help tab, and the code view suggests what fits.
Tests: about 240 in `test/edict/`, `test/rc/scripts_test.exs` and the two API
controller tests (Node tests of the editor kits and two real two-faction
matches included), 18 browser tests; two rounds of synthetic usability sessions
shaped the editor (see the study section).

## Contents

1. [Why a new language](#why-a-new-language)
2. [What a scenario is](#what-a-scenario-is)
3. [The language](#the-language)
4. [One program, three views](#one-program-three-views)
5. [Files and other editors](#files-and-other-editors)
6. [Help while writing](#help-while-writing)
7. [Security model](#security-model)
8. [Running a scenario](#running-a-scenario)
9. [Scripts in matches](#scripts-in-matches)
10. [What scripts cost](#what-scripts-cost)
11. [Validation](#validation)
12. [Roadmap](#roadmap)
13. [Where things are](#where-things-are)

## Why a new language

The obvious alternative was a culled general-purpose language: Lua through
Luerl (Lua implemented on the BEAM, with a sandbox mode), or JavaScript in
an isolate. Edict is a small synthetic language instead, for two reasons.

**Allowlist by construction, not denylist by removal.** A culled language
is safe to the extent that everything dangerous was found and removed:
`load` and `eval`, `string.rep` and pattern matching (memory and CPU
bombs), metatables, coroutines, `os`, `io`, debug hooks, and whatever the
next version adds. Edict's interpreter can only do what is written into it.
There is no module system, no reflection, no dynamic call, and no path from
a name a script writes to anything outside a fixed catalog. The attack
surface is the catalog, and the catalog is a reviewed list (a test fails
when it grows).

**The visual layer needs a closed grammar.** The workshop's promise is that
the nodes and the text are the same program, so an author can start
visually and move to text, or the reverse, without losing anything. That
requires every construct of the language to have a drawing. In Lua, most of
what makes it powerful (closures over mutable upvalues, multiple returns,
varargs, metatables, `goto`) has no sensible node, so a visual editor over
Lua becomes a toy subset with "opaque code" boxes for real scripts. Edict
was designed the other way around: a construct only got into the language
if it could be drawn, or if it is small enough to sit in a node as a line of
code (a lambda such as `s => s.population`).

The visual model borrows from Unreal Engine's Blueprints (event nodes,
execution wires separate from value wires, pure value nodes, collapsing a
selection into a function) and from Scratch/Blockly (a tree, not an
arbitrary graph, so it always has a textual form). Where they differ:
Blueprint graphs can merge execution wires freely, which has no structured
text equivalent; Edict's execution wires form chains, and branches and
loops send their inner chains off to the side, which is exactly structured
code.

## What a scenario is

A scenario has five kinds of top-level parts:

| Part | Purpose |
|---|---|
| `setup { … }` | The world: name, description, time limit, faction, the sector's size and neighbors, a rival court, mutators, granted and discounted patents. |
| `score` / `tiebreak` | How players are ranked: a number counted when the run ends, higher is better. |
| `var` | State the scenario keeps between events (a counter, the next tithe). |
| `fn` | A named function, callable from anywhere. |
| events | What happens: `on start`, `every 15s [from …] [until …] [as n]`, `at 10m`, `when <condition>`, `on end`. |

The Bequest daily, as a script:

```
setup {
  name = "The Bequest"
  description = "Inherit a fortune of 100,000,000 credits, bleeding away 5,000 a minute."
  time_limit = 30m
}

score trunc(player.credit)

tiebreak trunc(player.income.credit)

on start {
  give("credit", 100_000_000)
  notify("The estate is yours: 100,000,000 credits. It costs 5,000 a minute to keep.")
}

# 5,000 a minute, taken every second.
every 1s {
  take("credit", 5000 / 60)
}
```

A **race** is not a special mode: it scores `time.left` and calls
`finish()` when the goal is met. At the deadline `time.left` is 0, so a
player who never gets there scores 0 and the tiebreak ranks how close they
came, which is how the daily's races already score.

```
score time.left
tiebreak len(player.patents)

when "armoring" in player.patents {
  finish("Armoring researched: the Destroyer is yours.")
}
```

### Semantics an author can rely on

- **Snapshot reads.** The world is read once per pulse (once a second).
  Effects apply after the pulse, so a handler doesn't see its own `give()`
  in `player.credit` until the next second.
- **Atomic handlers.** A handler that fails leaves no trace: its effects
  are dropped and its `var` changes undone. A handler that fails three
  times is switched off, and the rest of the scenario carries on.
- **Catch-up.** `every` counts from the run's start, so a late pulse runs
  the occurrences it missed (up to ten at once) and every run sees the same
  sequence; `as n` numbers them 1, 2, 3 …
- **Edges.** `when` fires on the pulse its condition turns true, then waits
  for it to turn false before it can fire again.
- **Order.** Handlers run in the order they are written. After `finish()`,
  no further handler runs that pulse; then the score is counted and the
  `on end` handlers run.
- **Same rolls for everyone.** `random("wave", n)` is fixed by the
  scenario's seed and its keys, so every player of a scenario faces the same
  roster. The seed is the setup's `seed`, or else the scenario's name (not
  a digest of the whole script: authors iterating on a description
  shouldn't see every roll change).

## The language

Edict is expression-oriented, with statements in blocks and no semicolons.

**For programmers**, the question is usually "which language is it like?"
It reads like Python written with braces: Python's `#` comments,
`and`/`or`/`not`, `for x in xs` and free functions (`len(xs)`, `str(n)`);
JavaScript's arrow functions (`x => x * 2`) and record literals
(`{key: 1}`); Swift's and Go's conditions without parentheses
(`if x > 1 { }`), `nil` and named arguments (`tone: "good"`); Rust's `fn`.
What surprises programmers: conditions must be real booleans (no truthy
`0`), every number is a decimal and `%` is a percent (the remainder is
`mod()`), values are copied rather than shared (`push()` returns a new
list), and there are no classes, imports or exceptions. The workshop's Help
tab ("For programmers"), the tour's code card and the editor kits' READMEs
say the same.

- **Values:** numbers (all floating point; there is no integer type, so no
  bignum arithmetic to blow up), text, `true`/`false`, `nil`, lists,
  records (`{credit: 5, "two words": 2}`), functions.
- **Number forms:** `1_000_000`, durations `15s`, `2m`, `1m30s`, `1h`
  (seconds), percentages `25%` (0.25).
- **Text:** `"Wave {n} of {total}"` holes take simple expressions.
- **Operators:** `+ - * /`, `== != < <= > >=` (comparisons don't chain),
  `and or not`, `in` (membership in a list, text or record), and
  `if a then b else c` as a value.
- **Statements:** `let x = …`, `x = …` (also `x.field = …`, `x[i] = …`),
  `if … { } else if … { } else { }`, `for item in list { }`, `while … { }`,
  `return`, `break`, `continue`, and a call on its own line.
- **Functions:** `fn name(a, b) { … }`, called positionally or by name
  (`area(h: 3, w: 4)`). Lambdas: `s => s.population`, `(a, b) => a * b`.
- **Comments** (`# …`) are kept: a comment above a part becomes its note
  (shown on the node), a comment followed by a blank line stands alone.
- **Drafts:** `draft { … }` holds code that isn't wired into anything yet
  (the canvas's loose nodes). It never runs and is never checked.

### The catalog

Everything a script can name lives in one table, `Edict.Catalog`, which the
checker validates against, the interpreter dispatches on, and the editor
builds its node list from (`GET /api/edict/catalog`). Adding a function or
an action there, with its implementation, is how the language grows.

- **Builtins (48, pure):** math (`abs floor ceil trunc round sqrt pow min
  max clamp mod lerp`), text (`str upper lower join fmt_time fmt_number`),
  lists (`len first last range push concat reverse slice contains unique
  sort sum count map filter find any all sort_by max_by min_by`), records
  (`keys values get put has`), chance (`random random_int chance pick`).
- **Actions (7, the only way to change the game):** `give(resource,
  amount)`, `take(resource, amount)`, `notify(message, tone:)`,
  `finish(message?)`, `destabilize(amount, system:)`,
  `send_agent("erased", level:, system:)` (needs a rival court), `log(value)`
  (simulator only).
- **The world (read-only):** `time.elapsed/left/limit`;
  `player.credit/technology/ideology`, `player.income.*`, `player.systems`
  (each with population, housing, stability, production, intelligence,
  defense, income), `player.systems_owned`, `player.dominions`,
  `player.population`, `player.agents` (type, level, status, system, fleet
  raid/invasion/upkeep), `player.patents`, `player.wonders`,
  `player.agents_removed`; `rival.present/faction/agents_sent/agents_left`;
  `scenario.name/systems/time_limit`.
- **Setup fields:** `name`, `description`, `time_limit` (5m to 45m),
  `faction`, `systems` (1 to 8), `neighbors` (`"empty"` or `"neutral"`),
  `rival`, `mutators`, `grant_patents`, `patent_discounts`, `seed`. Content
  keys are checked against the game's own catalogs.
- **Patents by name.** Scripts name patents the way players read them: the
  English name in snake_case (`"armoring"`, `"precision_cranes"`,
  `"slsd_captors"`), read from the English locale at compile time
  (`Edict.Catalog.patent_names/0`). `player.patents` lists those names; setup
  turns them back into the engine's keys. The internal keys (`capital_1`)
  still work, with a warning whose fix rewrites them.

### Mistakes, caught early

`Edict.Checker` runs on every edit and reports errors and warnings on the
node (graph view) or the line (text view): unknown names and fields with a
"did you mean" (`player.credt`, `give("credits", …)`), wrong arity or
unknown `name:` values, actions where the game can't be changed (a score, a
`when` condition, a var's starting value, including through a `fn` that
acts), `return` outside a fn, `break` outside a loop, assigning to
something that isn't a variable, missing values (`?`), impossible setup
values, and type slips visible without running anything (multiplying a
list, an `if` on a number). It infers types through the world schema,
lists and lambdas, so `sum(player.systems, s => s.income.credt)` is caught.

When the checker knows the right answer, the diagnostic carries a
structured fix aimed at the exact node (`%{target, field, value}`): the
Problems tab and the node's `!` badge turn it into a one-click repair, and
a choice outside an action's list stays visible on the node as "(not
allowed)" rather than a blank dropdown. Parts left unconnected on the canvas
get a warning ("not connected to anything, so it never runs"), so a loose
node with a typo in it isn't mistaken for working code.

## One program, three views

The canonical form of a script is its tree (`Edict.AST`): JSON-shaped
nodes with ids. Text and graph are views of it.

- **Text.** `Edict.Parser` builds the tree, `Edict.Printer` prints the one
  canonical layout. Printing parses back to the same tree (a tested
  property), comments included.
- **Graph.** The editor draws the tree and edits it directly
  (`front/src/portal/workshop/`). The mapping is one-to-one:

| In the tree | On the canvas |
|---|---|
| a top-level part (setup, score, var, an event, a fn) | a header node; a fn is also a framed box around its nodes |
| a statement | a node in a chain; exec wires run top to bottom, in the order the text reads |
| `if` / `for` / `while` | a node whose inner chains leave from its right side (true/false, each/repeat), with the chain continuing below it ("after") |
| a call on its own line | the call's node, with exec pins |
| an expression | a value node feeding an input on the left side of the node that uses it |
| a plain value | typed straight into the input (numbers read `15s`, `2m`, `25%`; choices are dropdowns) |
| `player.income.credit` | one path node, editable as text |
| a lambda, a text template, a long formula | an editable line of code inside the input |
| `draft { }` | loose nodes on the canvas |

Editing the graph produces a new tree; the server checks it and returns the
canonical text, each node's line in it, and the text of nodes shown as code
(`POST /api/edict/analyze`). Editing the text sends the text; the server
returns the tree, and the editor carries node ids (and so the layout)
across the re-parse by matching the new tree against the old one by
position and kind. The client never parses, prints or runs Edict: the
language has exactly one implementation.

### The bridge between visual and textual

The user's complaint about visual languages was that they don't bridge the
gap between ease of use and the power of text. The workshop's answer:

- **Any node can be shown as code**, in place, without leaving the graph
  (right-click → "Show as code"); any code line expands back to nodes.
  Expressions over twelve parts start as code (a long formula drawn as
  nodes sprawls and reads worse than the text) and expand with ⤢.
- **Lambdas stay code inside nodes**, so `filter(player.agents, a => a.type
  == "erased")` is one `filter` node with the condition written in its
  input: the text layer's power, used visually.
- **Both views side by side** ("Both"): selecting a node highlights its
  line; clicking a line selects its node.
- **A syntax error doesn't lose the graph**: the nodes keep the last
  version that read correctly, and a banner names the line.

### Functions

Select a run of steps in one chain (shift-click or shift-drag a box) and
press Ctrl+G (or right-click → "Group into a function"). The steps move
into a new named `fn`, drawn in a frame; a call takes their place; names
the steps read from around them become the fn's parameters. Grouping
refuses (with the reason) when the steps change a local variable the
surrounding code still uses, since a fn can't hand it back.

A fn can be saved to the author's library (right-click its frame) and
inserted into any scenario from the node list, where three built-in
helpers also live (`best`, `escalate`, `level_for_wave`, written in Edict in
`priv/edict/library/`, each checked by a test).
Insertion copies the fn, so a scenario never depends on a library entry
that might change. In the MVP the library is per browser (local storage);
shared libraries are part of the sharing phase.

## Files and other editors

A script is a plain text file (`.edict`, UTF-8), so it can live outside
the workshop: in a folder, in version control, in a message to a friend,
in an IDE.

**In the workshop** (the toolbar's **File** menu, or drop a file on the
page):

- **Open file** (Ctrl+O) reads a `.edict` file into the workshop; undo
  brings back what was there. **Save as file** (Ctrl+S) downloads the
  canonical text, named after the scenario (`the-bequest.edict`).
- **Link a file** keeps the workshop in step with a file that another
  editor changes: saving it there reloads it here within a second (or at
  once when the workshop's window regains focus), exactly as if the text had
  been typed into the code view, so the author's own layout and comments
  stay as written and node positions survive. Changes made in the workshop
  go back to the file on Save (Ctrl+S), which then shows "linked" again;
  when both sides changed, the workshop asks which to keep. Linking uses
  the browser's File System Access API, so it works in Chrome and Edge;
  other browsers open and save.
- **Export my functions** writes the function library as one `.edict` file
  of `fn` declarations; **Import functions** reads any `.edict` file and
  adds its functions to the library (asking before replacing a different
  function of the same name). This moves a library between browsers until
  libraries are stored server-side, and lets authors share helpers today.

**Editor kits.** The Help tab (or File > Use your own editor) offers
downloads that add Edict to other editors:

| Editor | What it gets | How |
|---|---|---|
| VS Code, Cursor, VSCodium | highlighting, completion, hover docs, signature help, outline, go to definition, the lexer's checks | a `.vsix` extension (Install from VSIX) |
| JetBrains IDEs | highlighting; the rest through the language server | the TextMate bundle (Settings > Editor > TextMate Bundles), and the language server with the free LSP4IJ plugin |
| Neovim, Sublime Text, Zed, Helix, Emacs | the same, through the language server | `node lsp/edict-lsp.js --stdio`, mapped to `*.edict` |
| Notepad++ | highlighting (a light and a dark color scheme), name completion, call tips with each function's doc | a user-defined language and an auto-completion file |

How it is built:

- **One source of truth.** `Edict.EditorKit` generates every kit from
  `Edict.Catalog` (the table the checker and interpreter use) at request
  time: `catalog.json` (builtins, actions, world fields, setup fields,
  keywords, with docs and types), the TextMate grammar, the Notepad++ word
  lists. A builtin added to the catalog appears in every editor with the
  next download; nothing is maintained twice. `mix edict.editors DIR`
  writes the kit unpacked.
- **One engine, two adapters.** `priv/edict/editors/core.js` does the
  language work for every editor (completion, hover, signature help,
  outline, definitions, lexer checks) from `catalog.json`. `extension.js`
  adapts it to VS Code's API; `edict-lsp.js` serves it over the Language
  Server Protocol (stdio, no dependencies). Both read only the text being
  edited: no files, no network.
- **Context-aware completion.** Fields follow the world schema through
  paths, `for` loops, lambdas and `let`s (`for s in player.systems` makes
  `s.` offer a system's fields, with their docs); text offers the values
  its place takes (`give("` the resources, `tone: "` the tones,
  `grant_patents = ["` the patent keys, `a.type == "` an agent's types);
  setup offers the fields not set yet; a handler's body offers actions and
  statements, a value doesn't; `return`, `break` and `continue` appear only
  where they're allowed.
- **The full check stays in the game.** The editors run only the lexer's
  checks (unclosed quotes and brackets, unknown escapes, hidden
  text-direction characters, with the game's own wording). Names, types
  and setup values are checked by the server, which a linked workshop shows
  as the author saves: the workshop is the IDE's problems panel.

Validated by: Node tests of the engine, the language server (a full
JSON-RPC session over stdio, with and without snippet support) and the VS
Code adapter (against a stand-in `vscode` module), run from ExUnit so CI
covers them (`test/edict/editor_kit_test.exs`, `test/edict/editors/`);
the grammar tokenized by VS Code's own TextMate engine (`vscode-textmate`
with Oniguruma) over every example, with no line left inside a string; the
`.vsix` installed by a real VS Code-family editor (Cursor's command line,
into a throwaway profile); and browser tests for open, save, link (a
stand-in file handle, since the real picker is native), conflict,
function export and import, and the kit downloads. Not yet tried by hand:
LSP4IJ in a JetBrains IDE, and the Notepad++ files in Notepad++.

## Help while writing

Players are assumed to know little or no programming, so the language
explains itself where they work.

- **Docs for everything** (`Edict.Docs`): 188 entries, one per builtin,
  action, event, keyword, operator, setup field, world value and kind of
  node. Each says, in plain words, what it is, how to write it, what goes
  in, what comes out along the wire ("a list of systems; each is a record
  with id, name, home…"), with short examples. Every example with a result
  is run by `test/edict/docs_test.exs` against the interpreter, so the docs
  can't drift from what the game does. They ship with the catalog to the
  workshop and to the editor kits (VS Code and LSP hovers show them too).
- **Where they show.** Hovering a node's header shows a short card;
  double-clicking a node opens the full entry in the Help tab, and so does a
  click on a name in the node list (a double-click, a drag or Enter adds
  it); in the code
  view, hovering a name shows its card and the name under the caret fills
  the Help tab. The reference lists every entry, each name on its own line
  above its summary; clicking one opens it at the top. "How the workshop
  works" and "Use your own editor" fold away.
- **Plain answers for mistakes.** A name the game doesn't know shows "isn't
  something the game knows" with the checker's "did you mean"; a value left
  standing alone (often a half-typed `player.`) is an "unused value" node
  that explains itself.
- **Suggestions in the code view.** The same engine as the editor kits
  (`priv/edict/editors/core.js`, imported by the workshop) offers what fits
  where the caret is: fields after a `.`, the choices inside `"…"`, actions
  and statements in a handler, setup fields in setup. ↑/↓ choose, Esc
  closes, Ctrl+Space opens the list on demand. **Settings → Scenario
  editor** picks the key that accepts a suggestion (Tab, Enter,
  Shift+Enter or Shift+Tab: Tab is also how keyboard and screen-reader
  users move between controls) and turns suggesting-as-you-type off.
- **Undo is visible.** Deleting an event or a fn takes its steps with it;
  the toast says how many and has an Undo button.

## Security model

The threat: once scripts are shared, a hostile author writes a scenario
that other players run, on our server, inside their game session. The
author may try to read or change things outside the game, take the server
down, reach other players, or attack the players who run the scenario. The
same defenses also protect authors from their own mistakes.

**Scripts only ever run on the server.** The client sends text or trees;
it never evaluates them.

| Layer | What it stops |
|---|---|
| **Closed interpreter** (`Edict.Interpreter`) | Escapes. Explicit clauses for every node kind, builtin and action; no `apply`, no dynamic module or function names, no processes, files, network, clock or game access. A test inspects the compiled modules' import tables and fails if the language core calls `File`, `System`, `Port`, `Code`, `:os`, `:erlang.apply`, `send`, `spawn`, `binary_to_term`, `String.to_atom`, `Game`, the repo, … |
| **Effects as data** | Unchecked actions. An action call only appends a description (`%{"action" => "give", …}`); the host applies effects after the script finishes, so evaluation is a pure function of (tree, world, state). |
| **The effect gate** (`Edict.Effects`) | Interpreter bugs becoming game actions. Each effect is checked again against the world it was produced for: only catalog actions, targets only among the player's **own** systems, amounts in range, a rival court required for agents, message text cleaned and capped, at most 20 messages a minute. |
| **Read-only world snapshot** (`Edict.World`) | Information leaks. The script reads plain data built from the player's own state, exactly the catalog's fields (a test checks the key set against the catalog, with a player full of private fields). |
| **Fuel** | Endless loops and runaway recursion, deterministically: every step costs one unit (200,000 per pulse), list and text builtins one per element; function calls nest 64 deep at most. |
| **Value caps** | Memory growth: text 4 KB, lists 10,000 items, records 1,000 keys, numbers ±10¹⁵ (overflow is an error, not infinity), `var` state 256 KB between pulses. |
| **Source limits** | Parser bombs: 64 KB of source, 20,000 tokens, nesting 48 deep, 8,000 tree nodes. |
| **Process sandbox** (`Edict.Sandbox`) | Bugs in all of the above. Each evaluation runs in a fresh, unlinked, low-priority process with a capped heap (set at spawn) and a wall-clock deadline; the caller gets a result or an error tuple, never an exit. |
| **Atom safety** | Exhausting the BEAM's atom table (never garbage-collected, its exhaustion crashes the node). Nothing a script contains becomes an atom: identifiers and keywords stay binaries, kinds come from fixed tables, setup content keys are mapped to existing atoms by lookup. A test parses, checks, runs and JSON-decodes 300 scripts full of unique names and asserts the atom count doesn't move. |
| **The JSON gate** (`Edict.AST.from_json/1`) | Forged trees from the editor. Trees are rebuilt from a fixed table of kinds and fields; unknown kinds, kinds out of place, bad names, unclean text, out-of-range numbers, oversize or deep trees are refused; ids are sanitized. A tree that passes is a tree the parser could have produced. |
| **Text hygiene** | Trojan-source tricks (bidirectional overrides) are rejected in source and in tree text; raw control characters too. |
| **Plain-text rendering** | Attacks on whoever sees a script's text: the players who run it, and the author's friends, since a `.edict` file can be sent around and opened. Script text is only ever shown as text; see "Script text in the browser" below. |
| **Rate and concurrency limits** | One account hogging the CPU: per-account limits on analyze, simulate (bounded at 10 million steps and 15 s a run) and playtest; simulate and analyze also run at most two at once per account, and simulations one per scheduler across everyone (`Edict.Slots`). |
| **Determinism** | Unfair leaderboards: no clock, no randomness but the seeded kind, no map-order dependence; the same script against the same world does the same thing (tested). |

The adversarial suite is `test/edict/sandbox_escape_test.exs`, organized
by attack class: reaching the host (Elixir/Erlang module names, `eval`,
`load`, `__proto__`-style lookups, Erlang syntax), denial of service
(infinite loops, recursion, exponential work, growing lists/text/records,
state across pulses, number blowups, action floods, parser bombs, the
process backstop), the atom table, the JSON trust boundary, the effect gate,
and what a script can see.

### Script text in the browser

The question: can a script's author get HTML, styles, JavaScript or links
into someone else's browser? Text a script controls includes its strings,
its comments, its setup name and description, `notify()`, `finish()` and
`log()` text, and (since files) a file's name. Two of the app's libraries
render HTML by default, and that was where the risk was: **vue-toasted**
sets every toast's `innerHTML`, and **v-tooltip** (2.1.2) ships with
`defaultHtml: true`. vue-i18n doesn't escape `$t` parameters either. Since
master's #217, the app shows every toast and tooltip as text unless the
call asks for markup (`{ html: true }`, with `$escape`/`$thtml` for what it
interpolates), and #216 escaped the raw `v-html` spots, the lobby page's
description among them.

An audit of every path (two passes, one by an independent agent) found
these, all fixed:

| Path | Who it hit | Fix |
|---|---|---|
| A setup check quoted the author's text (`unknown mutator "<…>"`) into the node's `!` tooltip, which v-tooltip rendered as HTML | anyone who opens a `.edict` file someone sent and hovers the `!` | tooltips are text (app-wide since #217); messages quote a script's text only when it is a plain key (`Edict.AST.quoted/1`), "this text" otherwise |
| Parse errors repeated a misplaced comment's whole text, and Import functions showed the first error in a toast | anyone who imports functions from a file | parse errors say "a comment"; toasts are text (app-wide since #217) |
| Toasts carried the file's name (`Opened …`, `Linked …`), and file names can hold `<` and `>` on macOS and Linux | anyone who opens or links such a file | the same: toasts are text |
| The playtest's instance name and description were "Scenario playtest — <the script's name>", and the lobby page (`Instance.vue`) renders the description with `v-html` through an `nl2br` that escaped nothing | anyone who opens the playtest's lobby page (share link, admins) | the instance is just "Scenario playtest"; the lobby page escapes before `nl2br` (#216) |
| `finish()`'s message and the in-game status skipped the cleaner that `notify()` text goes through; a name with a line break crashed the playtest's boot | the player (rendered as text, but uncapped) | both cleaned and capped; a setup name must be one line |
| An editor kit's hover showed a function's comment as Markdown (links, remote images) | someone who opens a shared file in VS Code or an LSP editor | comments are escaped to plain text in hovers and signature help |

Checked and safe: `ScenarioFeed.vue` and the result banner (plain text),
the Problems tab, the syntax banner, the simulator panel, the palette,
node titles, notes and inputs (all `{{ }}`), the code view's highlighting
(escapes every segment and wraps it in fixed spans), the screen-reader
announcer (an inert DOMParser document, then `textContent`), admin
LiveViews and share-page meta tags (escaped), the news ticker (escaped,
public instances only), saved file names (reduced to `a-z0-9-`).

Regression tests: a browser test opens, imports, hovers, views and
simulates a file with markup in its name, strings, comments and logs, and
fails if any of it runs (it did fail with toast escaping removed);
checker, parser and editor-kit tests pin the message and hover rules.

Still open: when shared scenarios reach Discord
(community leaderboards), the posts must escape names and set
`allowed_mentions`. The lobby's `instance_full.json` includes `game_data`,
so a playtest's share link exposes the script's source to whoever holds
it.

### Side findings

Problems that turned up during this work:

- **Keyless `random()`, `chance()` and `pick()` repeated every second.**
  The counter standing in for keys restarted each pulse, so `every 1m { if
  chance(30%) {…} }` had the same outcome every minute. The counter now
  carries on from one second to the next (still the same in every replay).
  Found while writing the docs.
- **Big numbers in text read `12_500`.** Text used the source printer's
  digit grouping; it now writes `12500` (`fmt_number` gives `12,500`).

- **Windows line endings broke every script with a comment.** The lexer
  read a comment to the `\n` and kept the `\r` before it, then refused it
  as a control character; a file saved by Notepad++ or VS Code on Windows
  (CRLF by default) couldn't be read. The lexer now reads `\r\n` as `\n`
  (tested). Found while building file import.

- **Stored XSS through markdown in notifications.** `renderMd` (`$tmd`)
  HTML-escapes its input and then runs `marked` 2.0.1, which renders
  `[x](javascript:…)` as a live link. Profile names may contain brackets,
  parentheses and colons, and names are interpolated into notifications
  (`receive_resources`, `foreign_agent_stopped`), so a player named
  `[x](javascript:alert(1))` puts a clickable script link in other players'
  notification feeds; the session token is a JS-readable cookie. Verified
  against the installed `marked`. The fix belongs in `renderMd` (drop link
  hrefs that aren't http(s), relative or mailto). Not fixed on this branch.
- **The daily result banner's "Leave now" couldn't be clicked.** The
  loading screen's global `.exit-button` rule (`position: absolute;
  bottom: 0`) also matched the banner's button and pulled it under the
  bottom navbar; players had to wait for the 15-second auto-exit. Fixed
  here by renaming the banner's class.

## Running a scenario

Both ways of running a script drive the same runtime (`Edict.Runtime`):
`new/2` works out the setup, the starting `var`s and the schedule;
`pulse/3` runs whatever is due at a time against a world; `finish/3`
counts the score and runs `on end`. So what the editor simulates is what
the game runs.

### The simulator

`POST /api/edict/simulate` runs a whole scenario in about a second against
a **model player**: one home system, incomes that rise in a straight line
over the run (60 → 800 credits a day for a "typical" economy; slow and
strong halve and double it), and the script's own effects on top. It
returns the score, a score-over-time chart, a timeline of what fired and
what it did, and every error with when it first happened and how often.
The model never researches patents, builds fleets or removes agents, so
authors can **pretend**: "from 10:00, `player.patents` is `["armoring"]`"
makes a race finish in the simulation. The whole run is sandboxed with a
total step budget.

### Playtest: a script runs a real game

`POST /api/edict/playtest` checks the script, builds the day from its setup
and boots a persisted single-player instance the way a daily does; the
workshop then enters it like the daily page does. The daily's machinery
carries it from there (the clock starts on first connect), and the script's
runner (`Edict.Live`) starts with the clock.

- **Building the world.** `Daily.Generator.for_script/3` reuses the
  daily's whole world-building (the procedural home system, the sector of
  empty or neutral neighbors, the rival court as a puppet faction, mutators)
  and writes the script's grants, discounts and source into
  `game_data["daily"]["setup"]`. `Instance.Mutators.daily_granted_patents/1`
  and its siblings read that setup when present and fall back to the
  catalog objective otherwise, so catalog dailies are unchanged (the daily
  suite passes as before).
- **The runner** is a task outside the instance's supervision tree, like
  the Headhunter's Director: nothing in the game waits on it, and if it
  fails the game carries on. Once a second it reads the clock and the
  player, builds the world, runs the due handlers in the sandbox, passes the
  effects through the gate and applies them with the engine's own calls:
  `{:add_resources, …}`, the game's Destabilization penalty, enemy agents
  minted the way the Headhunter's arrivals are, and messages on the
  instance's global channel. Script errors go to the same feed, since in a
  playtest the player is the author.
- **What the player sees.** A panel under the top bar names the scenario
  and shows its score as it stands (the runner counts it each second,
  sandboxed). Below it, the script's messages, its errors, and echoes of
  what it did that the game wouldn't announce on its own: an agent slipping
  in, a stability hit, a larger gift or take ("Scenario: an enemy Erased of
  level 3 slipped into Vael"). All plain text.
- **The end.** `finish()` counts the score and stops the clock through the
  Victory agent's `:force_time_up`, as a won daily race does; at the
  deadline `Daily.Boot.finalize/1` hands over to the runner. The player sees
  the daily's result banner in a "scenario" variant (score, message), and
  every way out of the game (the banner, the menu's Quit) returns to the
  workshop. A scripted run never writes to the daily leaderboard
  (`Daily.Boot.record_for/2` stands aside; tested).

## Scripts in matches

A script also runs in Legacy, Tactic and Flash matches (Rebel Defense
included): its author saves it to their account, attaches it to a Forge
scenario, and every match made from that scenario runs it. Nothing restricts
which mode a script may join; the checks below warn when a script's setup
doesn't suit the map.

### One run per player

A match has many players, and a script was written for "the player". The
rule that keeps every script meaningful in both places: **in a match, a
script runs once for every player, as if each had their own copy.**

| In a script | In a daily | In a match |
|---|---|---|
| `player` | the one player | the player this copy runs for |
| `var` | the run's state | that player's state; each player has their own |
| `shared var` | an ordinary var | one value for the whole match: every player's run reads and changes the same one |
| `on start` | the run begins | the player's run begins: the match's start, or when a late joiner first appears |
| `at 10m`, `every 1h` | the run's clock | the match's clock (running time, pauses excluded); a late joiner skips an `at` already past, and an `every` picks up at its next occurrence, numbered as if it had counted since the start |
| `give`, `take`, `destabilize` | the player | that player, their own systems |
| `notify` | the player | that player alone |
| `finish()` | ends the run | ends that player's run (score counted, `on end` run); the match goes on |
| `end_match(message, winner: faction)` | ends the run, like `finish()` | ends the match for everyone; the named faction wins (left out, the match's own rules pick) |
| `score` | ranks the day | each player's own score, shown to them with their place and to everyone on the leaderboard's Scenario tab |
| `send_agent` | the rival court | refused: a match has no rival court |
| `time_limit` (setup) | the run's length | the match's length, when shorter than the map's (see below) |
| `time.limit` | the setup's | the match's time limit |

So a daily script keeps its meaning when attached to a match, and a script
written for matches simulates in the workshop as one player's run.

**Shared state and the end of a match.** Two parts exist for matches. A
`shared var` holds one value for everyone; each second the players' runs
take turns in a fixed order, each turn starting from the value the turns
before it left, so exactly one player can claim something. `end_match()`
ends the match for everyone and can name the winning faction; the first
call wins. Together they make "first to X wins":

```
shared var champion = ""

when champion == "" and player.systems_owned >= 30 {
  champion = player.name
  end_match(player.name + " holds thirty systems.", winner: player.faction)
}
```

The engine records the result as a `"scenario"` victory
(`Instance.Victory.Agent` `{:scripted_end, faction}`): the named faction
first in the final ranking, then the standings as they were. Rankings,
the archive and the Discord victory post follow as for any other victory.

Three world values describe the match around the player (`Edict.World`):

- `scenario.mode`: `"daily"` (a daily or a playtest), `"legacy"`,
  `"tactic"` or `"flash"`;
- `factions`: the factions in play, leader first, each with `name`,
  `players`, `systems`, `dominions`, `victory_points` and `rank`;
- `players`: everyone playing, with what the match shows openly: `name`,
  `faction`, `systems_owned`, `dominions`, `population`. Stocks, incomes and
  research stay private; `player` has the player's own.

In a daily, `factions` holds the player's faction (and the rival court's)
and `players` holds the player. For example, a tithe on the leaders:

```
setup {
  name = "Tithe of the Leaders"
  factions = 2
}

score player.credit

every 6h {
  if find(factions, f => f.name == player.faction).rank == 1 {
    take("credit", player.credit * 5%)
    notify("Your faction leads: 5% of your credit goes to the tithe.", tone: "warning")
  }
}
```

The workshop's **New… → Rules for a match** starts from this.

### Saving and publishing

Scripts are saved to the player's account (`RC.Scripts`, table
`edict_scripts`), from the workshop's **Scripts** tab or File menu (Ctrl+S
saves there when the open script is the account's):

- **Ten per account.** The eleventh save is refused until one is deleted.
- **The server derives everything.** The client sends the tree (or text)
  and the editor's layout; the name, description, canonical text, its
  SHA-256 digest and the checker's error count are worked out on the server.
- **Publishing is a flag, not a copy.** A published script is always
  exactly the version its author last saved. Publishing needs a script with
  no mistakes, and saving a published script keeps it that way.
- **No duplicates.** No two published scripts share a digest (a partial
  unique index), so publishing an unchanged copy of someone's script is
  refused, naming the original.
- **Others** find published scripts in the Scripts tab (search by name),
  open them read-only, and save a copy to change them (it counts toward
  their ten). Deleting an account deletes its scripts.

### Attaching to a scenario

The Forge scenario editor's last step has a **Scripts** section: up to three
scripts, picked from the author's own and the published ones.

**Frozen copies.** Saving the scenario keeps a copy of each script (text,
digest, name, author) in its `game_data["scripts"]`, taken from the
version saved at that moment (`RC.Scripts.attach/3`). A match runs that
copy, so a script edited, unpublished or deleted later never changes or
breaks a scenario that uses it; saving the scenario again picks up the
latest version. A script that is no longer available keeps the copy the
scenario had. Only ids come from the client: text it sends is never kept.
Anyone who can open the scenario can read its scripts (the scenario page
lists them, text included), since they are the rules of its matches.

**Checks against the map** (`Edict.Attachment`). The point is not to prove a
script does what its author meant, only that it starts correctly on this
map. They run as scripts are picked (`POST /api/edict/check-scenario`) and
again on save; all are warnings or notes, and the scenario still saves.

- *The setup against the map.* The setup describes the world a script was
  written for, and in a match the map makes that world, so the two must
  agree: `factions = 5` on a two-faction map, a `faction` the map doesn't
  have, a `time_limit` that differs from the match's length, `rival = true`, the
  daily-only `systems` and `neighbors`, and granted or discounted patents
  that the speed's patent tree lacks (Flash and Tactic trees are smaller).
- *A dry start.* The script starts once for a model player of every faction
  on the map (the speed's starting stocks, one home system, the map's
  factions and size), runs its first two seconds, counts its score and
  runs `on end`. An error there is reported: `factions[4].name` on a
  two-faction map fails with "can't read .name of nothing".
- *Between scripts.* Two scripts that discount the same patent differently
  are flagged (the lower price applies).

It can't catch the opposite case: a script that hard-codes two factions in a
way that can't tell a five-faction map apart.

**A script can set the match's length.** A `time_limit` written in a
script's setup, shorter than the map's, becomes the length of every match
made from the scenario; with several, the shortest wins. It is applied when
the match is created: the match's own `time_limit` is shortened (the map's
and the script's name are kept in `game_data["edict"]["time_limit"]`), so
the game's clock, its time-up victory and every script's `time.left` agree,
and the runner needs no special case. Nothing about it is hidden: the
Forge check says so as a note ("Matches of this scenario will last 15m
instead of the map's 2h: this script's time_limit sets their length"), the
scripted badge and the scenario's page say "Matches last 15m", and a second
script timed differently gets a warning naming the one that sets it. It was
made explicit this way because every daily script sets a `time_limit`
(5–45 minutes), so attaching one to a long map shortens it: the author must
be able to see that before players join.

**What a match boots with.** Creating a match from the scenario
(`RC.Instances.create_instance/3`) merges the attached scripts' setups into
`game_data["edict"]["setup"]`: every granted patent (each player gets them
when they join, with their ancestors), the lowest discount per patent, and
the scripts' mutators added to the map's own. The engine reads it through
`Instance.Mutators.script_setup/1`, the same path a scripted daily uses.

### The match runner

`Edict.Match` runs the scripts, a task outside the instance's supervision
tree like the daily's runner. `Instance.Manager` starts it whenever the
instance starts (a no-op when it already runs), so a resume, a restart, a
deploy's restore or the autosave cycle's stop/start all bring it back.

- **Once a second** it reads the clock and the standings (one call to the
  Victory agent), refreshes the roster from the factions every 15 seconds
  (players join a Legacy match all along), and pulses each player whose run
  has something due: a timer, a `when` (checked every second) or the score
  refresh every 10 seconds. A run with nothing due costs nothing: no world
  read, no sandbox.
- **Every pulse** is sandboxed like a playtest's, and the match shares a
  budget of 500,000 steps a second among the runs due (5,000 at least
  each; a typical pulse takes tens).
- **State survives restarts.** Every run's vars, timers and score are saved
  to `edict_match_runs` every few seconds, and at once after any `on start`
  (which must never run twice), and read back when the runner starts.
- **What players see.** The in-game scenario panel (folded to one line, a
  Legacy match runs for weeks) lists each script with the player's score
  and place; messages arrive as in a playtest, and a player who was away
  gets their last five on arrival. A script problem shows to the player
  whose run hit it, once per problem.
- **The leaderboard.** Every 10 seconds the runner sends everyone each
  script's scores (scripts that keep one), and the in-game leaderboard
  shows them in a Scenario tab. Scores are public: the scenario's author
  chose what they count, and the Forge says so when a script is attached.
- **The end.** When the match is won (by the game's rules or by
  `end_match()`), every run still going is finished (score counted, `on end`
  run, its messages sent, nothing else changed in a finished game) and each
  script's top three go to everyone.

The Rebellion of a Rebel Defense match is the game's own opponent and gets
no run. Bots seated as ordinary players do.

### What a match's scripts cost

Measured with `test/edict/resource_bench_test.exs` section 10 (the dev
container's x86 cores; the production Graviton cores are slower), per match,
for the work of one second including the 10-second score refresh:

| Script | 12 players | 60 players | 100 players |
|---|---|---|---|
| The match template (a 6-hour timer) | 0.0 ms | 0.2 ms | 0.3 ms |
| Two `when`s over all players, a 1-second timer | 0.4 ms | 5.4 ms | 12.3 ms |
| A runaway loop, every second | 28 ms | 30 ms | 32 ms |

The runaway script is held to the match's shared budget and is switched off
after three failed seconds, as in a playtest. Saved state is under 1 KB per
hundred players for these scripts (vars are capped at 256 KB per run).

**Found and fixed while measuring:** the runners copy a run's runtime into
the sandbox every pulse, and the sandbox's 16 MB cap counts that copy. The
runtime used to carry the whole program and, in each handler, its whole
declaration, so a large script (the bench's 200 `every` handlers) needed a
32 MB heap and was killed on every pulse, in a playtest as in a match. The
runtime now keeps only what a pulse uses (handler bodies, not the program),
and the same script runs in a 6 MB heap; `sandbox_escape_test.exs` keeps it
that way. A run whose pulse still kills its sandbox five times is switched
off for that player, as a playtest's script is.

### Not done yet

- **The simulator models a daily.** It runs one player for at most 45
  minutes against the model economy, with that player's faction alone in
  `factions`. A match's hours-long timers don't fire there; the attach-time
  dry start is the check that a script boots on a real map.
- **Messages to absent players** are kept only as the last five per player
  (shown on arrival); a script can't write to the faction chat.
- Script copy (panel, Forge section) is English only, like the workshop.

## What scripts cost

The question this answers: what happens to the production box (one AWS
t4g.large: 2 arm64 vCPUs, 8 GB, shared with Postgres, nginx and every game)
when a dozen player-written scenarios are being played at once, and what an
author, honest or not, can make the server do. Measured with
`test/edict/resource_bench_test.exs` (tagged `:mem_bench`, so it doesn't run
with the suite) in the dev container (x86, 12 cores) and again on 2
schedulers to stand in for prod's 2 vCPUs. A Graviton2 core is roughly 1.3
to 1.8 times slower per thread than the dev machine's, so prod numbers are
the ones below times about 1.5.

**The short answer: a dozen running scenarios cost about 1% of the box,
and about 7% if every one of them runs the most expensive script the limits
allow.** The games are dearer than the scripts, and they are the same games
a daily runs.

### A dozen scenarios being played

Twelve real scenario instances (the twelve examples), clocks running,
runners pulsing, on 2 schedulers:

| Running | CPU, above idle | Share of 2 cores | Memory of the instances |
|---|---|---|---|
| 1 instance, a typical script | ~0.00 s/s | 0.1% | 2.3 MB |
| 12 instances, the 12 examples | 0.02 s/s | 1.0% | 40 MB (3.3 MB each) |
| 12 instances, the worst sustained script | 0.15 s/s | 7.3% | 26 MB |

(Measured over 20 s after 10 s of play, with no client connected; the
whole VM grew about 65 MB for the twelve.)

- **A typical script costs microseconds a second.** Across a full run, the
  examples' pulses take 0.1 to 6 µs on average (58 µs at most) and spend 0
  to 112 steps of their 200,000. The heaviest, Charter of Prosperity, uses
  0.06% of its budget.
- **The worst a script can do is about 15 ms a second.** A pulse that
  spends all 200,000 steps (tight loops, recursion, list builtins over
  10,000 items) takes 10 to 15 ms in the sandbox, about 1.5% of one core
  at one pulse a second. A script that runs out of steps instead is
  stopped and, after three failures, switched off, so it can't sustain
  even that; the worst *sustained* script is one whose loops finish just
  under the budget every second.
- **Twelve worst-case scripts don't disturb the game.** With twelve of them
  pulsing on 2 schedulers, a normal-priority stand-in for game ticks (a
  small unit of work every 10 ms) kept its median and 99th-percentile
  latency under a millisecond, as with no scripts at all: the sandbox runs
  at low priority. Two cores would only fill with about 130 worst-case
  scripts running back to back.
- **What a run is allowed:** one live run per profile (starting a run or a
  playtest ends that profile's previous one, `Daily.Boot.reap_running_dailies/1`),
  two profiles per account, so two live runs per account, the same as
  dailies today.

Against prod's budget: a t4g.large's baseline is 30% of each vCPU (0.6 of
a vCPU sustained); above it the box spends CPU credits, and in unlimited
mode, AWS's default for T4g, bills the surplus. At these rates the
baseline holds on the order of a hundred typical runs or a few dozen
worst-case ones at once, before counting what a connected player's client
traffic costs (not measured here; it is what every daily already costs).

### The limits, measured

| Limit | Set to | Worst measured | What actually binds |
|---|---|---|---|
| Steps (fuel) per pulse | 200,000 | 10–15 ms of CPU | this one: every CPU-heavy script stops here |
| Sandbox deadline | 2 s | 17 ms | never reached: a backstop for interpreter bugs |
| Sandbox heap, text included | 16 MB (was 64 MB, text not counted) | 6.3 MB (sorting 10,000-item lists) | never reached: fuel stops growth first |
| `var` state between pulses | 256 KB | 250 KB (a script filling it on purpose) | holds; the examples keep almost none |
| Runtime state carried per run | (sum of the above) | 5–38 KB for the examples | copying it into the sandbox each second takes ~0.01 ms |
| Lists, records | 10,000 items, 1,000 keys | ~630 per pulse | fuel: `push` and `put` cost one step per item already there, so a pulse runs out long before the caps (`range` is the exception, capped at 10,000) |
| Simulation budget | 10 M steps, 15 s (was 40 M) | 0.56 s of CPU for the worst sustained script (2.4 s at 40 M) | the step budget, well before the 15 s deadline; the examples simulate in 2–17 ms |
| Concurrent simulations | 2 per account, 1 per scheduler overall | | see finding 1 |
| Concurrent analyses | 2 per account | | see finding 4 |
| Source | 64 KB, 20,000 tokens, 8,000 nodes, depth 48 | analyze in 10 ms and 5 MB at the limits | holds; typical scripts analyze in 0.2 ms |

### Where the limits were weaker than they looked

Found by the measurements, and fixed (see "Changes made"):

1. **Simulation has a rate limit but no concurrency limit.** An account
   may run 200 simulations in 5 minutes, and nothing stops it from sending
   them all at once. With the worst sustained script that is 200 × 2.4 s,
   about 480 CPU-seconds in 5 minutes, or 1.6 vCPUs held for as long as
   the account keeps it up (more on Graviton2): more than prod's whole
   CPU baseline, from one account. The simulations run at low priority, so
   game ticks stay responsive, but Postgres and nginx share those two
   vCPUs, and sustained use spends credits. This is the one finding that
   matters. Honest authors never cause it: the editor sends one
   simulation at a time and a real script simulates in milliseconds.
2. **The heap cap doesn't bound memory across concurrent sandboxes.** 64
   MB is per process; with no concurrency limit, a burst of simulations
   could in principle hold 64 MB each. In practice fuel keeps a pulse
   under 7 MB, so the realistic burst is a few hundred MB, not gigabytes.
3. **Text and lists of text live partly outside the heap cap.** Strings
   over 64 bytes are shared binaries, which `max_heap_size` doesn't count
   by default; a pulse building 3.5 KB strings churned 3.7 MB of them. Fuel
   bounds this too (a few MB a pulse).
4. **Analyze runs in the request process, not a sandbox.** Parse, check,
   print and source map at the source limits take 10 ms and 5 MB, bounded
   by the source limits and 900 requests per 5 minutes; again no
   concurrency limit.
5. **Handler bookkeeping isn't charged steps.** 200 `every` handlers cost
   550,000 reductions for 31,000 steps: walking handlers and catching up
   schedules is free in fuel terms. The handler count is bounded by the
   source limits, so it can't multiply a pulse's cost by much.

### Changes made

1. **Two simulations at a time per account, and one per scheduler across
   everyone** (`Edict.Slots`, in the controller's `action/2`). Two rather
   than one, so an author closing and reopening things quickly doesn't
   trip over their own last request. Over the limit, a request waits up to
   3 s for a slot, then gets 429 "busy". Slots are released when the work
   ends or its process dies (each holder is monitored), so a crashed or
   cut-off request can't leak one. Finding 1's worst case per account is
   now at most two simulations at once, and the whole server at most one
   per core.
2. **A 10 M-step simulation budget instead of 40 M.** The heaviest example
   spends 0.2 M steps over a whole 30-minute run, so 10 M leaves fifty
   times that; the worst simulation dropped from 2.4 s to 0.56 s of CPU
   (measured), and one account's sustained worst case within the rate
   limit from 1.6 vCPUs to about 0.4.
3. **A 16 MB sandbox heap instead of 64 MB, counting shared binaries**
   (`max_heap_size`'s `include_shared_binaries`). The worst pulse measured
   needs 6.3 MB. Findings 2 and 3: a quarter of the size, and text now
   counts against the cap.
4. **Two analyses at a time per account**, for the same reason as 1. This
   bounds finding 4's bursts; the editor already waits for each answer.

Not worth changing: the 2 s pulse deadline (a hundredfold headroom is what
a backstop should have, and a busy box can delay a low-priority process),
and the per-pulse step budget (the examples use at most 0.06% of it, and
it is the limit that does the work).

Not measured: memory growth over a full 30 to 45 minute run (the figures
above are after 30 s of play), the cost of a connected client's updates,
and the arm64 build itself.

## Validation

### Expressiveness: the shipped dailies, rebuilt as scripts

The examples in `priv/edict/examples/` include ports of ten shipped daily
objectives. `test/edict/parity_test.exs` generates 300 players (random
stocks, incomes, systems, dominions, agents, fleets, patents) and requires
each script's score and tiebreak, counted by the real runtime from the world
`Edict.World` builds, to **equal** `Daily.Objective.evaluate/3` on the same
player's daily stats. For the three races it also requires the script to
call `finish()` on exactly the players for whom
`Daily.Objective.race_completed?/2` holds. All pass.

| Daily objective | Shape | Script |
|---|---|---|
| Coffers of the Realm | max stat | `score trunc(player.credit)` |
| Golden Flow | max stat (income) | `score trunc(player.income.credit)` |
| The Triumvirate | composite | min of three incomes, sum as tiebreak |
| The Bequest | package (fixed setup) | `on start` gift + `every 1s` drain |
| Charter of Prosperity | race | `fn progress()`, `when progress() >= 1 { finish() }` |
| The Destroyer's Blueprint | race + grants/discounts/pinned boon | all in `setup` |
| Fleet in Being: Raiders | race | best fleet over Navarchs on the board |
| Land Rush | sector (empty) | `systems = 6`, `neighbors = "empty"` |
| Hegemon | sector (neutral) | `score player.dominions` |
| Headhunter (lite) | rival court + scheduled arrivals | `every 15s as wave { send_agent(…) }` |

The ports taught three things. First, the daily ranks **whole numbers**
(`PlayerStat` stores integers, and `get_stats` truncates every stat), so
exact parity needed a `trunc` builtin; it also means the daily silently
ties players whose incomes differ by less than one. Second, the
race-as-`time.left` idea needs no special mode. Third, what does **not**
yet fit:

- **The Headhunter's exposure rule** (every 25 Intelligence uncovers more
  enemy Erased) is hand-written in `Daily.Director`; the lite port leaves
  exposure to the game's usual rules. It needs an `expose(agent)` action
  and the rival's agents in the world.
- **Required bodies** (Monumental guarantees a barren world) and
  **markup-free grants as a choice** are not setup fields yet.
- **Fleets and the v2 adversary** (The Gauntlet, The Leviathan, Convoy
  Season) need NPC armies, which the engine doesn't have outside players.
- **Game events as triggers** (`on agent_removed`, `on building_built`)
  would make some scenarios simpler than polling with `when`.

One original scenario (The Tithe Collector: a growing tithe every three
minutes, unrest when you can't pay) shows state across events, decisions
and escalation, which no shipped daily needed.

### Onboarding and usability

- **The tour** opens on the First Steps example and walks through seven
  steps, four of them tasks that complete themselves when done: change a
  value, add a step, simulate, look at the code. Scripted end to end, a
  newcomer's path takes seven gestures
  (`e2e/tests/scenario-workshop.spec.js`, "a newcomer finishes the tour").
- **Browser tests** cover the promises the editor makes: the tour; text and
  nodes as one program (edits on either side show on the other, a node
  highlights its line, a syntax error keeps the graph); grouping steps into
  a function and saving and inserting it from the library; errors explained
  on the node, the line and the Problems tab; a race simulated to its finish
  with "pretend"; and a playtest that runs the script in a real game and
  comes back to the workshop.
- **A synthetic usability study.** Three fresh agents with no access to the
  code or this document, each given a persona and tasks, used the live page
  through a mouse-and-keyboard harness with full-resolution screenshots.
  This is no substitute for real players, but it caught real friction.
  Results are in [the study section](#synthetic-usability-study).

## Synthetic usability study

No real players have used the workshop yet, and the tour was written by the
same hand that wrote its test, so a scripted pass through it only proves it
works as intended. To get closer to a first-time user, fresh agents with no
access to the code, the tests or this document were each given a persona
and four tasks, and used the live page only through
`e2e/usability-harness.js`: a persistent browser driven by clicks, drags,
keys and full-resolution screenshots, the way a person works. Each
reported outcomes, every moment of confusion in order, bugs, and the three
changes they'd most want. This is a proxy with obvious limits (an agent
reads screenshots more patiently than a person, and has no real stake in
the game), so the findings are treated as leads, and the real test is
still players.

### Round 1: three participants

| Persona | Tasks | Outcome |
|---|---|---|
| A game designer who has never programmed (nodes only) | tour; build "Patron's Favor" from blank (ideology score, 2,000 credits every 3m); a timed tribute with a warning; check it in the simulator | all four completed in the node view, 65 commands |
| A hobbyist programmer | build the "Archive Sprint" race; a conditional hint every minute; prove the race finishes; group steps into a saved function | all four completed, about 80 commands; code view for logic, nodes for grouping |
| A daily-challenge player | explain Headhunter (lite) from the page; slow its arrivals and level climb; break and fix it; playtest it | all four completed, about 66 commands |

What worked, in their words: dropping an action straight onto a pin
("it connects and lines up on its own"), the `every` block's plain fields
("2m from 10m was exactly how I'd say it"), the simulator's timeline, the
tour's self-completing tasks, the node and code views staying in step
("every change showed up on the other side straight away"), and the error
help ("took me straight to the right line … clicking the problem centred
the canvas on the bad node, which I liked a lot").

What didn't, and what changed (all fixed before round 2):

| Finding | Fix |
|---|---|
| `player.ideology` vs `player.income.ideology` reads like code to a non-programmer | the node list shows plain names first ("Ideology held", "Credit income, per game day"), the path as a hint; path nodes carry the description as a tooltip |
| clicking a path node focused its text, so Delete edited the name ("playercredit") instead of deleting the node, and Escape didn't help | one click selects a node, a double-click edits a path; Escape leaves any field; a × appears on the selected node |
| replacing the score's input left the old `player.credit` loose on the canvas | a replaced plain value or path is removed; bigger pieces still go to a draft |
| a loose node with a typo showed no problem | unconnected parts are flagged: "not connected to anything, so it never runs" |
| two timers both read "every #4 · every #2" in the timeline; message tones invisible | entries name the handler as written ("every 2m from 10m #2"), with ⚠/✓ for tones |
| the chart's range labels read like time labels; headline score and chart end disagreed | y-range on the left, time on the x-axis; the chart ends on the final score; a series picker adds the player's credits, technology and ideology |
| "a day" unexplained against a 20-minute run; ideology missing from the model text | the model text gives all three incomes and says a game day passes every 0.75 s |
| "Pretend" unclear; its default was a stale `capital_1`; it collapsed on change and didn't re-run | renamed "What if…", pre-filled from what the scenario's `when` reads, stays open, re-runs on change; results edited since are marked "out of date" |
| no hint how to make a race from blank | a "blank race" template (score `time.left`, a `when … finish()`) |
| Ctrl+G refused an `if` selected with its own branch step; the view jumped away after grouping; the call showed a value pin | nested selections come along with their parent; the view stays on the call (flashed) and a toast says where the fn went; step calls only offer a result if the fn returns one |
| library entries hid their parameters and overwrote silently | entries show `name(params)`; replacing a different version asks first |
| examples labelled "(partial port)"; opened at 39% zoom; comments named internal modules | grouped "Start here / Dailies, rebuilt / Originals / Templates"; fitting never goes below a readable 60%; comments in player language |
| Headhunter's level formula hid the interval (`wave * 15`), so slowing arrivals silently slowed the climb | the level curve reads `time.elapsed`; the built-in `level_for_wave` too |
| editing a description reshuffled every random roll | the default seed is the scenario's name |
| the error column pointed at `(`; an invalid choice showed as a blank dropdown; "must be one of "erased" (did you mean erased?)" | calls sit at their name; the bad value stays visible "(not allowed)"; one-click fixes in the Problems tab and on the node; a single choice reads "must be "erased"" |
| in the playtest, nothing showed the scenario: no score, no sign of the hidden arrivals; "Quit game" went to the daily page | the in-game panel and echoes above; every exit returns to the workshop |
| the toolbar wrapped on long titles; no auto-indent in the code view; selected text invisible | fixed toolbar; Enter keeps (and after `{` deepens) the indent; a visible selection |

Two of their findings were pre-existing problems outside the workshop: the
daily result banner's unclickable "Leave now" (fixed, see "Side
findings") and, in the playtest's leaderboard, the puppet court's huge
point total, which comes from the purse the Headhunter daily funds it with
(not changed here).

### Round 2: checking the fixes

One fresh participant, a strategy-game player who has never programmed and
gives up on tools that don't explain themselves, got five tasks that cross
the friction fixed after round 1: build a "Two Million" race (finish at
2,000,000 credits, ties to credit income), make a mistake and get it fixed,
add and delete an unwanted step, check the race in the simulator, then
playtest it and come back.

All five were done in about 57 commands (round 1 took 65 to 80 for four).
The fixes held: the blank-race template ("task 1 was mostly editing
values"), plain-language search ("Credit income, per game day"), the
one-click "Fix: use credit", Delete on a selected node, the simulator's
"out of date" notice and named timeline entries, the replaced score input
disappearing, and the round trip back to the workshop.

It found a further layer, now also fixed:

| Finding | Fix |
|---|---|
| a race's simulator score read "569" with no unit; a race that never finished just said "Ran to the deadline" | race scores show as time ("9:29 left", or "not finished"), and "finish() never ran: the goal wasn't reached" says so plainly |
| the simulator started at about 2,100 credits, the real game at 300,000; its model text didn't change with the economy picked | the model starts from the game's own Legacy starting stocks and starting income; the text shows the numbers for the economy picked |
| in the playtest, a race's live score counted time left before the goal was met, and nothing showed the goal | races say "scored by the time left when you finish"; the panel shows the scenario's description |
| no obvious way out of the game | a "Back to workshop" button on the panel |
| no top-level way to start fresh | a **New** menu (blank scenario, blank race) |
| the template's tiebreak comment ("whoever came closest") went stale; nothing said which way a tiebreak goes | the comment is generic, and score and tiebreak nodes say "higher ranks first" |
| the world list cut "Whether there is a rival court (setup" at a colon, had two "Run length" entries, and an "Of those…" entry sorted before what it referred to | the three descriptions rewritten |
| unconnected-part warnings had no badge | warnings get a muted badge when there are no errors |

Still open: undo history doesn't survive the round trip to a playtest,
and the simulator can't say in advance that a goal is out of reach of the
45-minute maximum (it shows it once run, with the credits chart).

## Roadmap

**Phase 2: sharing and community dailies.**

- Done (2026-10-22): scripts saved to the account (`edict_scripts`, keyed by
  the digest of their canonical text), publishing (no duplicates, always
  the saved version), and scripts in matches (see "Scripts in matches").
- Still to do: a moderation queue for published names and messages (today
  they are cleaned of control and direction characters and shown as plain
  text, but not reviewed), and per-script leaderboards keyed on the digest.
- For matches (done 2026-10-22: `shared var`, `end_match()`, the
  leaderboard tab): simulating a match (several players, a map's factions,
  its length), messages to the faction chat.
- Shared function libraries, with copy-on-insert kept as the rule.
- Community dailies: a curated script can be a day's challenge, run through
  the same runner, recording into `daily_entries`.
- Catalog growth, each with its gate and tests: `expose()`, the rival's
  agents in the world, `grant_patent()` as a reward, a persistent status
  line (`set_status("Wave 3 of 10")`), game-event triggers, `required
  bodies` and per-system profiles in setup.
- Copy (catalog docs, node labels) in French and German; today the workshop
  chrome is English with the usual locale fallback.

**Phase 3: the same interpreter for bots and automation.**

The interpreter has no ambient authority; what a script can read and do is
decided by the catalog it is checked and run against. That makes the
language reusable under different **capability profiles**:

- the *scenario director* profile (today): the world of one player, actions
  that change the scenario;
- a *player automation* profile: the player's own view, actions limited to
  the orders the player could give in the UI, validated by the same server
  paths (the effect gate becomes the order validator);
- a *bot* profile: `Headless.Bot` policies keep their API for the heavy
  lifting (pathing, the strategist, budgets) and delegate the finer
  decisions to Edict functions (target scoring, opener steps, thresholds),
  evaluated per tick under fuel. Evolved or LLM-proposed considerations
  (docs/game-ai-v2.md) become Edict text the checker can vet before a bot
  ever runs them.

## Where things are

| Piece | Path |
|---|---|
| Language core | `lib/edict/` (`lexer`, `parser`, `ast`, `printer`, `checker`, `catalog`, `interpreter`, `runtime`, `sandbox`, `limits`, `effects`, `world`, `scenario`, `source_map`, `simulator`, `live`, `edict.ex`) |
| HTTP API | `lib/portal/controllers/edict_controller.ex` (`/api/edict/catalog`, `examples`, `editors/:kind`, `analyze`, `fragment`, `format`, `simulate`, `playtest`, `check-scenario`), `lib/portal/controllers/script_controller.ex` (`/api/edict/scripts`, `published`, `:id`, `:id/publish`) |
| Saved scripts | `lib/rc/scripts.ex`, `lib/rc/scripts/script.ex`, migration `20261022000001_create_edict_scripts` (`edict_scripts`, `edict_match_runs`) |
| Scripts in matches | `lib/edict/attachment.ex` (frozen copies, checks against a map, a match's merged setup), `lib/edict/match.ex` (the runner); started from `Instance.Manager.start/2`; `Instance.Mutators.script_setup/1`; `Portal.ScenarioController` (attach on save, `script_checks`) |
| Forge and lists | `front/src/portal/components/ScenarioScripts.vue` (the editor's Scripts section), `ScriptedBadge.vue` (Forge list, new-game picker, lobby rows, scenario page), `front/src/portal/pages/create/ScenarioDetail.vue` (the scripts' text) |
| Editor kits | `lib/edict/editor_kit.ex` (generator), `priv/edict/editors/` (`core.js` engine, `extension.js` VS Code, `edict-lsp.js` language server, kit READMEs), `mix edict.editors DIR` |
| Files in the workshop | `front/src/portal/workshop/files.js` (open, save, link) |
| Docs and suggestions | `lib/edict/docs.ex` (entries, `test/edict/docs_test.exs`), `front/src/portal/workshop/` (`DocCard.vue`, `docs.js`, `completion.js`, `md-lite.js`, `editor-settings.js`), Settings → Scenario editor (`front/src/portal/pages/settings/ScenarioEditor.vue`, `Account.settings.scenario_editor`) |
| Examples | `priv/edict/examples/*.edict` |
| Engine seam | `Instance.Mutators.daily_setup/1` and siblings; `Daily.Generator.for_script/3`; `Daily.Boot.boot_definition/3`; `Daily.Director.mint_agent/4` |
| Editor | `front/src/portal/pages/ScenarioWorkshop.vue`, `front/src/portal/workshop/` (`ast.js` edits, `graph.js` drawing, `GraphCanvas`, `GraphNode`, `CodeEditor`, `Palette`, `SimPanel`, `Tour`) |
| In game | `front/src/game/components/ScenarioFeed.vue` (playtests, and a match's standings), the scenario variant of `DailyResultBanner.vue` |
| Tests | `test/edict/` (parser, interpreter, runtime, checker, examples, parity, sandbox escape, live, attachment, match, editor kit; `editors/*.test.js` run by `editor_kit_test.exs`), `test/rc/scripts_test.exs`, `test/portal/controllers/{edict,script}_controller_test.exs`, `e2e/tests/scenario-workshop.spec.js`, `e2e/tests/scenario-scripts.spec.js` |
| Usability sessions | `e2e/usability-harness.js` (`node usability-harness.js <port> <outdir>`, then drive it with `curl -d '{"cmd":"shot"}'` …) |

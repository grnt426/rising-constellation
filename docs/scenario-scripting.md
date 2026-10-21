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

Status (2026-10-21): the MVP is built and tested end to end. Ten of the
shipped daily objectives are rebuilt as scripts and rank players exactly as
the hand-written versions do; a script can be simulated in the editor and
played in a real game ("Playtest"). Sharing scripts with other players is
the next phase, and the security model was designed for it. Scripts open
from and save to `.edict` files, a file can stay linked while it's edited
elsewhere, and generated editor kits bring the language to VS Code,
JetBrains IDEs, Notepad++ and any LSP editor. What scripts cost the server
is measured and bounded (see "What scripts cost"), and script text never
renders as HTML (see "Script text in the browser"). Tests: 184 in
`test/edict/` and the API's controller test (Node tests of the editor kits
included), 11 browser tests; two rounds of synthetic usability sessions shaped the
editor (see the study section).

## Contents

1. [Why a new language](#why-a-new-language)
2. [What a scenario is](#what-a-scenario-is)
3. [The language](#the-language)
4. [One program, three views](#one-program-three-views)
5. [Files and other editors](#files-and-other-editors)
6. [Security model](#security-model)
7. [Running a scenario](#running-a-scenario)
8. [What scripts cost](#what-scripts-cost)
9. [Validation](#validation)
10. [Roadmap](#roadmap)
11. [Where things are](#where-things-are)

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

when "capital_1" in player.patents {
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
helpers also live (`best`, `escalate`, `level_for_wave`, written in Edict).
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
| Notepad++ | highlighting, name completion, call tips with each function's doc | a user-defined language and an auto-completion file |

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
render HTML by default, and that is where the risk is: **vue-toasted** sets
every toast's `innerHTML`, and **v-tooltip** (2.1.2) ships with
`defaultHtml: true`. vue-i18n doesn't escape `$t` parameters either.

An audit of every path (two passes, one by an independent agent) found
these, all fixed on this branch:

| Path | Who it hit | Fix |
|---|---|---|
| A setup check quoted the author's text (`unknown mutator "<…>"`) into the node's `!` tooltip, which v-tooltip rendered as HTML | anyone who opens a `.edict` file someone sent and hovers the `!` | the tooltip is plain text (`html: false`); messages quote a script's text only when it is a plain key (`Edict.AST.quoted/1`), "this text" otherwise |
| Parse errors repeated a misplaced comment's whole text, and Import functions showed the first error in a toast | anyone who imports functions from a file | parse errors say "a comment"; every workshop toast is escaped (`toast/3`) |
| Toasts carried the file's name (`Opened …`, `Linked …`), and file names can hold `<` and `>` on macOS and Linux | anyone who opens or links such a file | the same escaped toasts |
| The playtest's instance name and description were "Scenario playtest — <the script's name>", and the lobby page (`Instance.vue`) renders the description with `v-html` through an `nl2br` that escaped nothing | anyone who opens the playtest's lobby page (share link, admins) | the instance is just "Scenario playtest"; the lobby page itself is fixed on `claude/vhtml-name-xss` (it escapes before `nl2br`) |
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
fails if any of it runs (it does fail with the toast escaping removed);
checker, parser and editor-kit tests pin the message and hover rules.

Still open, outside this feature: toasts and tooltips elsewhere in the
game render HTML by default too, so any of them that carries
player-controlled text is a risk; and when shared scenarios reach Discord
(community leaderboards), the posts must escape names and set
`allowed_mentions`. The lobby's `instance_full.json` includes `game_data`,
so a playtest's share link exposes the script's source to whoever holds
it.

### Side findings

Three problems turned up during this work:

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
authors can **pretend**: "from 10:00, `player.patents` is `["capital_1"]`"
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

- Scripts stored server-side (a `scenario_scripts` table: author, name,
  source, layout, visibility), identified by a digest of their canonical
  text so a leaderboard belongs to exactly one version.
- Publishing: a script goes public through review (automated checks plus a
  moderation queue for names and messages, since scenario text reaches other
  players), with per-script leaderboards keyed on the digest.
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
| HTTP API | `lib/portal/controllers/edict_controller.ex` (`/api/edict/catalog`, `examples`, `editors/:kind`, `analyze`, `fragment`, `format`, `simulate`, `playtest`) |
| Editor kits | `lib/edict/editor_kit.ex` (generator), `priv/edict/editors/` (`core.js` engine, `extension.js` VS Code, `edict-lsp.js` language server, kit READMEs), `mix edict.editors DIR` |
| Files in the workshop | `front/src/portal/workshop/files.js` (open, save, link) |
| Examples | `priv/edict/examples/*.edict` |
| Engine seam | `Instance.Mutators.daily_setup/1` and siblings; `Daily.Generator.for_script/3`; `Daily.Boot.boot_definition/3`; `Daily.Director.mint_agent/4` |
| Editor | `front/src/portal/pages/ScenarioWorkshop.vue`, `front/src/portal/workshop/` (`ast.js` edits, `graph.js` drawing, `GraphCanvas`, `GraphNode`, `CodeEditor`, `Palette`, `SimPanel`, `Tour`) |
| In game | `front/src/game/components/ScenarioFeed.vue`, the scenario variant of `DailyResultBanner.vue` |
| Tests | `test/edict/` (parser, interpreter, runtime, checker, examples, parity, sandbox escape, live, editor kit; `editors/*.test.js` run by `editor_kit_test.exs`), `test/portal/controllers/edict_controller_test.exs`, `e2e/tests/scenario-workshop.spec.js` |
| Usability sessions | `e2e/usability-harness.js` (`node usability-harness.js <port> <outdir>`, then drive it with `curl -d '{"cmd":"shot"}'` …) |

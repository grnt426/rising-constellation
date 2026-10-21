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

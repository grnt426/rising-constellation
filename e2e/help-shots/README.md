# Help-manual screenshots

Real in-game UI captured for the help manual (`docs/help-manual.md`), with
highlight boxes ("marks") stored as data so the page renderer can draw them
over the image.

- `shots.json`: the recipes (what to capture, how, and which parts to mark)
- `capture.js`: the capture script (plain node + Playwright's chromium API, not the test runner)

Outputs:

| Path | What |
| --- | --- |
| `assets/static/img/help/shots/<name>.png` | the image (source of truth, committed) |
| `priv/static/img/help/shots/<name>.png` | a copy, so the running dev server serves it at `/img/help/shots/<name>.png` without a rebuild |
| `priv/help/shots/manifest.json` | size, alt text, marks, scene and capture date per shot (keys sorted, merged on each run) |

## Setup

Playwright comes from `e2e/node_modules`. Either `npm install` in `e2e/` (plus
`npx playwright install chromium`), or, in a worktree without it, junction
another worktree's install instead of downloading again:

```powershell
New-Item -ItemType Junction -Path e2e\node_modules -Target <other-worktree>\e2e\node_modules
```

`node_modules` is gitignored at the repo root. Chromium must be in the
Playwright browser cache (`%LOCALAPPDATA%\ms-playwright`).

The Docker dev stack must be running. The script reads the Phoenix port from
`.dev-ports.json` (run `bin/rc-worktree-setup` first if it's missing).

## Running

From the repo root:

```powershell
node e2e/help-shots/capture.js                          # every enabled recipe
node e2e/help-shots/capture.js credit-tooltip           # just the named ones
node e2e/help-shots/capture.js --date=2026-09-13 system-population system-bodies
```

Flags: `--date=YYYY-MM-DD` (the manifest's `captured`, default today's local
date), `--headed` (watch it), `--base-url=http://localhost:4840`. The login
defaults to the dev seed `user1@abc` / `user1dev`, overridable with
`RC_HELP_SHOTS_EMAIL` / `RC_HELP_SHOTS_PASSWORD`.

A failing recipe (selector, mark or prepare step not found) is reported by
name, a full-page screenshot lands in `e2e/screens/help-shot-<name>-failed.png`,
the other recipes still run, and the exit code is 1. Naming a `disabled`
recipe runs it anyway (useful when you have a world where it can work).

**Recapture whenever the UI changes.** The images are pixels, and marks are
fractions of those pixels. A restyle, a new row in a tooltip or a moved button
silently makes both stale. Rerun the affected recipes and look at the
PNGs before committing.

## Scenes

A scene is a JS function in `capture.js` that boots a world and returns
`{ page, reset }`. It boots once per run, and all recipes of that scene share
the page (one login per run; repeated logins trip the auth rate limiter).
`reset()` runs before each recipe: Escape (unpins popovers), mouse to an empty
spot, clear any open build menu, reopen the system if it was closed.

- `own-system`: logs in over the API, creates a profile if the account has
  none (seeded non-admin accounts don't), calls `POST /api/daily/play` like
  the portal's Daily Challenge page, seeds the game cookies from the
  response, loads `/portal/game`, waits for the socket, and opens the
  player's first system with `store.dispatch('game/openSystem', ...)`.
  Every run boots a **new** daily instance for that profile (it runs out on
  its own timer). No portal UI login is involved, so the
  `liveSocket.connect()` workaround isn't needed. The world is today's daily,
  so numbers and names (system name, mutators) change from day to day.

The system view refetches about every 60 s and re-renders. Recipes capture
right after their prepare step, so this hasn't mattered so far.

## Adding a recipe

Append to `shots.json`:

```json
{
  "name": "system-population",
  "scene": "own-system",
  "prepare": "pin-credit-popover",
  "selector": ".system-population",
  "padding": 8,
  "alt": "The Population box of a system",
  "marks": {
    "workforce": ".system-population .box-line:not(.header) .yield-box >> nth=0"
  }
}
```

- `name`: file name and manifest key (kebab-case).
- `scene`: a key of `scenes` in `capture.js`.
- `prepare` (optional): a key of `prepares` in `capture.js`. Put UI
  choreography there (open a popover, hover a tile). Existing steps:
  - `pin-credit-popover`: clicks the system's credit yield, which pins its HoverPopover
  - `pin-stability-popover`: clicks the Population box's stability yield
  - `hover-built-building`: hovers the first built tile in the bodies list, which shows its building card
- `selector`: what to capture. It is a mark spec (below), so a union of
  several elements works too. The clip is its box plus `padding` px on
  each side, clamped to the 1440x900 viewport (deviceScaleFactor 1, default
  game theme).
- `alt`: alt text for the page renderer.
- `marks`: name → mark spec.
- `disabled` (optional): reason string. The recipe is skipped on a full run.

Selectors are Playwright selectors: CSS plus `:has-text("...")`,
`:text-is("...")`, `>> nth=N`, etc.

## Marks

A mark spec is one of:

- `"selector"`: the element's bounding box
- `{ "selector": "...", "ownText": true }`: the box of the element's own
  text nodes only, not its child elements. Use it for a word sitting next to
  an icon or a `<strong>` title.
- `{ "selector": "...", "optional": true }`: skipped (logged) when absent,
  instead of failing the recipe. Use it for rows that only exist in some
  game states.
- `[spec, spec, ...]`: the union box of several specs

Marks are measured in the prepared state, then converted to fractions of
the captured image: `x`, `y`, `w`, `h` in 0..1, rounded to 4 decimals,
relative to the padded, clamped clip. Draw them as
`left: x*100%; top: y*100%; width: w*100%; height: h*100%` over the image.
A mark partly outside the clip is cut to the clip. A mark entirely outside
fails the recipe.

## Fragile selectors

These depend on structure or English copy rather than stable classes:

- `system-population` workforce/housing/stability: `.yield-box >> nth=0/1/2`
  (order of the three yields in `Population.vue`)
- `system-bodies`: `.system-content-group:has(.system-content-group-item) >> nth=0/1`
  (first two body groups). `body-population` is the first `.potential-item`
  in a group header, i.e. the first inhabited body.
- `credit-tooltip` / `stability-tooltip`: the popover is found as
  `.tooltip.popover.open` (v-tooltip's markup). Rows are matched by English
  text (`"Taxes"`, `"Mobility bonus"`, `"Population"`, `"Buildings"`), so
  they break if the copy changes or the default locale isn't English.
- Prepare triggers: credit is the first `.system-properties .yields
  .hover-popover-trigger`, and stability is the third trigger in the Population
  box's second line.

## Known gaps

- `system-population-status` is disabled: `PopulationStatus.vue` only renders
  when `population_status !== 'normal'`, and a fresh daily system is normal.
  It needs a scene with an unstable system (a fixture with low stability).
- `credit-tooltip` in a fresh daily only has the Taxes row. The optional
  `mobility` and `buildings` marks appear once a scene provides a system with
  credit buildings and mobility.

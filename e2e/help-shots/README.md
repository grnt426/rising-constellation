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
node e2e/help-shots/capture.js dominion-properties uninhabited-state dominion-state empire-credit-tooltip system-population-status stability-tooltip-destabilized
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
spot, clear any open build menu, reopen the system if it was closed, and
switch the bodies panel back to its first (bodies) tab.

Recipes on `own-system`:

| Recipe | Captures | Marks |
| --- | --- | --- |
| `system-population` | Population box | growth, growth-bar, workforce, housing, stability |
| `system-bodies` | first two body groups | body-population |
| `credit-tooltip` | pinned credit popover | taxes, mobility?, buildings? |
| `stability-tooltip` | pinned stability popover | population, buildings |
| `building-card-mobilized` | hovered building card | mobilized |
| `system-properties` | system header square plus its hanging parts (defense, visibility, production, governor) | defense, owner, star, credit, technology, ideology |
| `production-tooltip` | pinned production popover | initial, buildings? |
| `defense-tooltip` | hovered defense popover | population, buildings? |
| `system-body` | the inhabited planet's body group | potentials, tiles, infrastructure |
| `bottombar-limits` | Systems and Dominions counters in the bottom bar | systems, dominions |
| `system-state` | state tab (claim, productivity, operations) | status, liberate, abandon |

`?` = optional mark.

- `own-system`: logs in over the API, creates a profile if the account has
  none (seeded non-admin accounts don't), calls `POST /api/daily/play` like
  the portal's Daily Challenge page, seeds the game cookies from the
  response, loads `/portal/game`, waits for the socket, and opens the
  player's first system with `store.dispatch('game/openSystem', ...)`.
  Every run boots a **new** daily instance for that profile (it runs out on
  its own timer). No portal UI login is involved, so the
  `liveSocket.connect()` workaround isn't needed. The world is today's daily,
  so numbers and names (system name, mutators) change from day to day.

Recipes on `empire` (the `System` column is the recipe's `openSystem`):

| Recipe | System | Captures | Marks |
| --- | --- | --- | --- |
| `system-population-status` | destabilized | population status bar at the top of the bodies list | current |
| `stability-tooltip-destabilized` | destabilized | pinned stability popover | temporary-penalties |
| `dominion-properties` | dominion | system header square plus its hanging parts | owner |
| `uninhabited-state` | uninhabited | state group under the bodies (single tab) | status |
| `dominion-state` | dominion | state tab (claim, productivity, operations) | status, administer, abandon |
| `empire-credit-tooltip` | home | pinned Bottombar credit popover | systems, dominions |

- `empire`: **needs the `empire` option of `POST
  /api/harness/dev/agent-fixture`** (`lib/portal/controllers/dev_fixture_controller.ex`)
  compiled into the running server; against an older build the scene fails
  with "returned no empire block". It calls the fixture with `empire: true`
  as `user1@abc` (the capture login), then enters the game like `e2e/`
  does: registration token, `game/start` payload, cookies, `/portal/game`.
  The fixture boots a **new** two-faction instance (Flash speed, cheats on,
  hostile agents parked in home, as for the other e2e specs) and, before
  placing agents, grows the player through real game paths:
  - buys the `agent` → `system_1` → `dominion_1` Lexes and the Lex slots
    for them, and slots all three: System Limit 2, Dominion Limit 3
  - claims the nearest takeable uninhabited system (`owned2`) and makes the
    nearest takeable autonomous system its dominion (`dominion`)
  - picks the nearest remaining autonomous (`autonomous`) and uninhabited
    (`uninhabited`) systems, left unclaimed
  - adds a Destabilization penalty to home (`destabilized` = `home`) that
    pushes its stability to about -15 (Demonstration), so its population
    status leaves Normal; the penalty decays slowly, so capture soon after

  The response's `empire` block holds those ids; a recipe names the one to
  open with `openSystem` (`home`, `owned2`, `dominion`, `autonomous`,
  `uninhabited`, `destabilized`; default `home`). `reset()` also switches
  systems and scrolls the bodies panel back to the top. The fixture
  instances are not retired: finish old ones from the admin instance list
  (a server boot resurrects running instances).

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
- `openSystem` (optional, `empire` scene only): which fixture system is open
  before the prepare step. `own-system` ignores it.
- `prepare` (optional): a key of `prepares` in `capture.js`. Put UI
  choreography there (open a popover, hover a tile). Existing steps:
  - `pin-credit-popover`: clicks the system's credit yield, which pins its HoverPopover
  - `pin-stability-popover`: clicks the Population box's stability yield
  - `pin-production-popover`: pins the production yield's HoverPopover by
    dispatching the click to the trigger (a real click is intercepted, see
    Fragile selectors)
  - `hover-defense-popover`: hovers the defense value (a plain
    `v-popover trigger="hover"`, no pinning), pointer stays there for the capture
  - `open-state-tab`: clicks the third tab of the bodies panel (state)
  - `hover-built-building`: hovers the first built tile in the bodies list, which shows its building card
  - `pin-empire-credit-popover`: clicks the Bottombar credit value, which pins the empire's credit HoverPopover
  - `scroll-state-into-view`: scrolls the bodies panel so the state group of a single-tab (uninhabited) system is on screen
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
- `[spec, spec, ...]`: the union box of several specs. An absent member
  marked `optional` is left out of the union; any other absent member makes
  the whole union absent.

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
- `system-properties`: the `.system-properties` box does not contain its
  absolutely positioned parts (defense and visibility asides, production box,
  governor circle), so the capture is a union of those five selectors.
  credit/technology/ideology are `.yields .yield-box >> nth=0/1/2` (template
  order in `Properties.vue`). `owner` is the `.owner` text block only; its
  diamond population-class marker is positioned outside that box.
- `production-tooltip`: at 1440x900 the bottom-anchored `.system-info`
  (z-index above `.system-content`) covers the production value, so
  `pin-production-popover` dispatches the click event to
  `.production-box .hover-popover-trigger` instead of clicking at its
  position. If the layout changes so the trigger is reachable, a real click
  also works. The `initial` row is matched by the English text
  `"Initial value"`.
- `defense-tooltip`: trigger is `.box-aside.left .v-popover .trigger`, hover
  only (no pin), so the prepare step must leave the pointer on it. The row is
  matched by the English text `"Population"`.
- `system-body`: the inhabited body group is the first
  `.system-content-group` whose header has a `.secondary .potential-item`
  (the population badge). `infrastructure` is the first `.tile.is-important`
  (`BodiesItem.vue` adds `is-important` to infrastructure tiles).
- `bottombar-limits`: `.navbar-group-buttons.left .navbar-maxed-value >> nth=0/1`
  (Systems, then Dominions, in `Bottombar.vue`). The agent-type counters on
  the right use the same component, hence the `.left` scope.
- `system-state`: `open-state-tab` clicks
  `.system-tab-item:not(.is-tool) >> nth=2` (tabs are bodies, details, state).
  liberate/abandon are `.system-content-group > .button >> nth=0/1`.
- `dominion-state`: same selectors as `system-state`. On a dominion the two
  buttons are Administer (`transform_dominion_to_system`) then Abandon, in
  `State.vue` order.
- `dominion-properties`: the `system-properties` union, but the hanging
  parts are optional members (a dominion may have no production box or
  governor circle).
- `uninhabited-state`: an uninhabited system has one tab (bodies + state,
  `Content.vue`), so the state group sits under the bodies list and is
  scrolled into view; there are no tab items to click.
- `empire-credit-tooltip`: trigger is the first `.hover-popover-trigger` in
  `.navbar.bottom .navbar-group-buttons.left` (the Systems and Dominions
  counters before it are plain v-popovers). Groups are matched by the
  English subtitles `"Systems"` and `"Dominions"` (`resource-detail.type.system`
  / `.dominion`).
- `stability-tooltip-destabilized`: the group is matched by the English
  subtitle `"Temporary penalties"` (`resource-detail.type.happiness_penalties`).
- `system-population-status`: `PopulationStatus` sits at the top of the
  bodies list (`Bodies.vue`) and only renders when the status is not Normal.

## Known gaps

- `empire` recipes: not captured yet at the time of writing (they need the
  backend option compiled). Things only a first run will confirm: that the
  autonomous and uninhabited neighbours are visible from home (otherwise
  `openSystemById` reports the system as hidden), and that the Dominions
  group shows in `empire-credit-tooltip` (the dominion's credit output is
  whatever the autonomous system produced).
- `production-tooltip` in a daily shows the day's mutator row with a raw
  i18n key as its subtitle (`RESOURCE-DETAIL.TYPE.MUTATOR`, reason
  `industrial_surge`): `resource-detail.type.mutator` is missing from the
  front locales and `ResourceDetail.vue` prints unknown reasons verbatim.
  Recapture once the key exists (or on a scene without mutators). The
  optional `buildings` mark, here and in `defense-tooltip`, needs a system
  with production or defense buildings.
- `bottombar-limits`: the counters touch the bottom of the viewport, so the
  capture has no padding below them and both marks end at the image's bottom
  edge (the outline's bottom side falls outside the image). The two marks
  also abut (Systems ends where Dominions starts).
- `system-state` on a fresh daily shows both operations disabled (hatched):
  the player's only system can't be liberated or abandoned.
- `State.vue` renders `PopulationStatus` without the `!== 'normal'` check that
  `Bodies.vue` has, so the state tab of a Normal system also shows the bar
  (`system-state`, `dominion-state` include it).
- `credit-tooltip` in a fresh daily only has the Taxes row. The optional
  `mobility` and `buildings` marks appear once a scene provides a system with
  credit buildings and mobility.

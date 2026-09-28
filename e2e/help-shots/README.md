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
node e2e/help-shots/capture.js build-menu body-tiles-actions production-queue production-box-queue foreign-tiles
```

In a worktree without `e2e/node_modules`, point Node at another worktree's
install instead of the junction (Git Bash):

```bash
NODE_PATH=F:/projects/rising-constellation/.claude/worktrees/armada-feature-proposal-bdb4c3/e2e/node_modules \
  node e2e/help-shots/capture.js build-menu
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
| `technology-empire-tooltip` | home | pinned Bottombar technology popover | systems, dominions |
| `bottombar-limits-tooltip` | home | hovered Systems counter (System Limit breakdown) | limit |
| `autonomous-state` | autonomous | state tab (claim, productivity) | status |
| `production-tooltip` | home | pinned production popover (moved here from `own-system`: a fixture world has no mutators) | initial, buildings? |
| `build-menu` | home | build menu of a free tile of the inhabited planet, with the hovered, greyed-out Delta Polytech's card beside it | locked, disabled, limited, cost |
| `body-tiles-actions` | home | the inhabited planet's body group, pointer on the idle Residential District | upgrade, destroy, damaged, repair, construction |
| `production-queue` | home | the open construction queue, first order hovered | first, finish-time, cancel |
| `production-box-queue` | home | the production box (value, countdown, progress ring) | progress, counter |
| `foreign-tiles` | autonomous | first body group with buildings, seen at visibility 2 | hidden-building |

- `empire`: **needs the `empire` option of `POST
  /api/harness/dev/agent-fixture`** (`lib/portal/controllers/dev_fixture_controller.ex`)
  and its `buildings` sub-option compiled into the running server; against
  an older build the scene fails with "returned no empire block", or (no
  `buildings`) boots with a warning and the five Buildings recipes fail in
  their prepare step. It calls the fixture with
  `{"email": "user1@abc", "speed": "slow", "empire": {"buildings": true}}`
  as `user1@abc` (the capture login), then enters the game like `e2e/`
  does: registration token, `game/start` payload, cookies, `/portal/game`.
  The fixture boots a **new** two-faction instance at **Legacy speed**
  (`speed: "slow"`, the speed the manual documents: a Flash capital starts
  at 40 production, a Legacy one at 100), cheats on, hostile agents parked
  in home as for the other e2e specs, and, before placing agents, grows the
  player through real game paths:
  - buys the `agent` → `system_1` → `dominion_1` Lexes and the Lex slots
    for them, and slots all three: System Limit 2, Dominion Limit 3
  - claims the nearest takeable uninhabited system (`owned2`) and makes the
    nearest takeable autonomous system its dominion (`dominion`)
  - picks the nearest remaining autonomous (`autonomous`) and uninhabited
    (`uninhabited`) systems, left unclaimed, and parks one of the player's
    common Siderians in each: an own agent in a system gives visibility 2
    (`Faction.resolve_system_visibility/2`); without it the SPA shows
    "No data available" instead of the bodies and state
  - adds a Destabilization penalty to the second system (`destabilized` =
    `owned2`) that pushes its stability to about -15 (Demonstration), so its
    population status leaves Normal; the penalty decays slowly, so capture
    soon after. Home is left alone, so its tooltips have no stability
    penalty rows
  - `buildings`: on home's inhabited planet (the 8-tile habitable planet of
    the Legacy starter layout, the one holding the infrastructure), grants
    the exact credit and technology, buys the patents (Legacy: Citadel,
    Urbanization, Urbanization II, the Floating Gardens' patent), and then
    - raises the infrastructure (Megapolis) to level 2
    - puts a Residential District level 1, idle, on the first free tile
      (tile 2): its Upgrade button shows, since level 2 needs no patent and
      the infrastructure is level 2
    - puts a damaged Delta Polytech level 1 on the next one (tile 3): Repair
      button; it is Limited, so a second one is greyed out in the build menu
    - orders a Floating Gardens (tile 4, 1 200 production, about 12 ticks at
      home's 100 production) and then a Residential District (tile 5)
      through the player agent: a real two-order queue. The Floating Gardens
      is Limited too, so it is also greyed out in the build menu
    - leaves tiles 6-8 free

    The finished and damaged buildings go through the dev-only
    `{:dev_put_building, body_uid, tile_id, key, level, status}` call of
    `Instance.StellarSystem.Agent` (real paths can't finish or damage a
    building on demand). Home's workforce (15) covers the 4 workers the
    Megapolis and Delta Polytech mobilize, so its production has no penalty.
    The queue lasts about 12 ticks of Legacy time; capture soon after boot.

  The response's `empire` block holds those ids (and `buildings`: body
  uid, the tile and key of each building, `queued`, `free_tiles`,
  `patents`, `queue`); a recipe names the one to
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
  - `open-state-tab`: clicks the third tab of the bodies panel (state); works with or without the operations buttons
  - `pin-empire-technology-popover`: clicks the Bottombar technology value, which pins its HoverPopover
  - `hover-systems-limit-popover`: hovers the Bottombar Systems counter (plain hover v-popover), pointer stays there
  - `hover-built-building`: hovers the first built tile in the bodies list, which shows its building card
  - `pin-empire-credit-popover`: clicks the Bottombar credit value, which pins the empire's credit HoverPopover
  - `scroll-state-into-view`: scrolls the bodies panel so the state group of a single-tab (uninhabited) system is on screen
  - `open-build-menu`: scrolls to the inhabited planet, clicks its first free
    tile (build menu), then hovers the menu's greyed tiles until the card
    shows the Delta Polytech, and tags that tile `data-help-shot="hovered"`
  - `hover-upgradable-tile`: scrolls to the inhabited planet and points at
    the right border of the tile with an Upgrade button, so its Destroy
    button shows
  - `open-production-queue`: opens the construction queue (dispatched click
    on the production box's round icon) and hovers its first order, so the
    cancel button fades in
  - `hide-system-info`: hides `.system-info` (population box and bodies
    list), which covers the lower half of the production box at 1440x900

  `open-build-menu` and `hide-system-info` hide unrelated panels that stack
  above the subject with a `visibility: hidden` style (`hideForCapture`);
  `reset()` removes it before the next recipe.
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
- `build-menu`: the menu's tiles have no per-building class
  (`Production.vue`): `.tile.is-hoverable` = buildable,
  `.tile.has-dashed-background` = patent missing (`locked` is the first of
  those), neither = greyed (Limited or Unique already used). The prepare
  finds the Delta Polytech by hovering each greyed tile and comparing the
  card title with `$t('data.building.university_open.name')`. `limited` is
  the card's badge (`.card-illustration .toast`, `BuildingCard.vue`); the
  capture is the union of `.system-production` and the card that hangs to
  its right (`right: -305px`). At 1440x900 the agent roster
  (`.navbar-panel`) covers the card's right edge and the system's agent
  display draws labels into the union's empty corners, so the prepare hides
  both; the corners then show the system map.
- `production-box-queue`: the `.production-box` box does not contain its
  absolutely positioned round icon and countdown, so the capture is the
  union of the three, and `.system-info` is hidden (it covers their lower
  half at this viewport).
- `body-tiles-actions`: the tile toasts are told apart by position classes
  (`BodiesItem.vue`): top left = Repair on a damaged tile
  (`.has-dashed-background`), otherwise Upgrade; bottom left = an order on
  the tile; bottom right = Destroy, hidden until the tile is hovered
  (`tile.scss`). `upgrade` relies on the infrastructure having no Upgrade
  button (its level 3 patent is not bought); `construction` is the first
  order's toast (the Floating Gardens). Only the infra planet's empty tiles
  are buildable, so the only dashed tile with a level badge is the damaged
  one.
- `production-queue`: `.system-production-queue .card-container >> nth=0`
  (`ClosedProductionCard.vue`); `finish-time` is its `.title-small`, which
  a Flash game does not render; `cancel` is `.card-header-toast`, at opacity
  0 until the card is hovered.
- `production-box-queue`: `.production-counter` only renders while the
  queue has an order (`ProductionBox.vue`).
- `foreign-tiles`: the first body group with a `.tile-level` badge; at
  visibility 2 to 4 that badge reads `?` (`BodiesItem.vue`).

## Known gaps

- `technology-empire-tooltip` is disabled: `ResourceDetail` drops
  zero-value lines, and no fixture system or dominion makes technology (no
  technology buildings), so the Systems and Dominions groups never appear.
  It needs a scene with technology buildings built.
- `empire` right after `docker compose restart rc`: the first page load can
  hang without connecting while the dev server warms up. `waitConnected`
  reloads once after 60 s; if it still fails, the error names the page URL
  and store state and saves `e2e/screens/help-shot-scene-connect-failed.png`.
- `empire-credit-tooltip`: the Dominions group shows because the dominion
  makes credit; a dominion with zero output would drop out of the list.
- `production-tooltip` moved to the `empire` scene: a daily shows the day's
  mutator row with a raw reason key (`industrial_surge`), a fixture world
  has no mutators. The optional `buildings` mark, here and in
  `defense-tooltip`, needs a system with production or defense buildings.
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

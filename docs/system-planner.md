# System planner

A portal page (`/portal/system-planner`) where a player tries out how to build
up one star system: buildings and their levels, population, a governor and its
skills, active lexes. It sits next to the battle simulator under the top bar's
**Sandbox** menu.

The page is freeform. There are no costs, no build times, and levels can be set
directly instead of one at a time. Patents only limit what can be built when the
player turns on **Limit to my patents**.

## Surfaces

- **Top bar**: `NavDropdown.vue` ("Sandbox") replaces the old Simulator link and
  opens a menu with the battle simulator and the system planner.
- **In game**: the system view's State tab (`State.vue`, also on phones through
  `MobileView.vue`) has a "System planner" block for any system with visible
  bodies that isn't uninhabitable.
  - **Open in the planner** opens a new tab, so the game keeps running.
  - **Copy as JSON** copies the plan. If the clipboard is blocked, it saves a
    file instead (`utils/json-export.js`).
  - The "C" hotkey still copies the system's name, sector and coordinates.
- **Planner page** (`SystemPlanner.vue` + `portal/components/planner/*`):
  - **Left rail**: game mode, faction, population (with "Fill housing" =
    housing + 0.75, where the game's growth settles), capital, governor, and
    the patents/lexes drawers.
  - **Center**: the bodies. The selected tile's editor opens under its body,
    with the in-game `BuildingCard` (a level pip builds that level), the level,
    damage and remove controls, and the build choices.
  - **Right rail**: every system output with the game's own breakdown
    popovers, and the change from the baseline.
  - **Phones**: the tile editor is a bottom sheet, a yields bar stays pinned to
    the bottom, and the drawers turn into lists.

## Example systems (presets)

`/portal/system-planner?preset=<name>` opens the planner on a ready-made
plan. The help manual's Basics of Play pages link to three of them with
`{planner:<name>|…}` (`docs/help-manual.md`): `basics-early`, `basics-mid`
and `basics-late`, the same real system on day 5, 12 and 22 of an official
Legacy match, renamed.

- A preset is a plan file in `priv/planner/presets/<name>.json`, read at
  compile time by `RC.SystemPlanner.Presets` and served by
  `GET /api/system-planner/preset/:name` (404 for an unknown name).
- The page loads it in `start()`, before the saved session, and drops the
  query so a reload keeps the reader's edits. The preset becomes the plan and
  its baseline, so the results show what the reader's changes add.
- If the saved session holds real work (edits since its baseline, or a system
  imported from a game), the page asks before replacing it (`sessionAtRisk`
  in `plan.js`).
- The route keeps the link across the sign-in round-trip
  (`onlySignedInGuard`), since manual readers may not be signed in yet.
- A preset with a `patents` list opens with "Limit to my patents" on, like
  an in-game export. The three examples carry what their player had
  researched at that point and no lexes.
- `test/rc/system_planner/presets_test.exs` computes every preset through
  `RC.SystemPlanner.compute/1`.

## Plan format

`front/src/portal/planner/plan.js` is pure and covered by node tests
(`node --test front/src/portal/planner/__tests__/plan.test.mjs`). One JSON
shape serves the export, the page's state, and the saved session:

```json
{
  "format": "tf-system-plan", "version": 1,
  "speed": "slow", "faction": "tetrarchy", "name": "Ophion",
  "capital": true, "population": 15.8,
  "bodies": [{ "type": "habitable_planet", "name": "Ophion II",
               "industrial_factor": 4, "technological_factor": 2, "activity_factor": 5,
               "tiles": [{ "building_key": "infra_open", "building_level": 2, "building_status": "built" }],
               "bodies": [] }],
  "governor": { "type": "speaker", "name": "Vela", "skills": [0, 0, 0, 6, 0, 0] },
  "patents": ["infra_open_1"], "active_lexes": ["prod_1"],
  "owned_lexes": ["prod_1"], "lex_slots": 4,
  "source": { "instance_id": 2, "system_id": 909, "sector": "Djon",
              "position": { "x": 36, "y": 18 }, "exported_at": "…" }
}
```

How the in-game export fills it:

- Only finished buildings go into the plan. Queued construction is left out,
  and damaged buildings keep their damage.
- The client is never told which system is the capital. It reads the capital
  from the production breakdown's "initial" part. A capital's base production
  differs in Legacy and Flash. In Tactic both bases are equal, so it makes no
  difference there.
- The governor's skills aren't in the system payload. `State.vue` fetches the
  governor's full character ahead of time, so the planner can open on the
  click without tripping popup blockers.
- A daily plans with Legacy data. The two have the same content.

`normalizePlan` fits any imported plan to the game data of its speed. It drops
what can't fit and reports each drop as a warning toast: unknown buildings,
wrong biome or tile type, a second copy of a unique building, out-of-range
levels, and unknown patents or lexes. Switching the game mode runs the same
normalization.

The game hands the plan to the new tab through `localStorage`
(`stashPlan`/`takeStashedPlan`). The URL only carries a one-time key, and
entries a tab never picked up are dropped after a day.

## Computing

`POST /api/system-planner/compute` (`Portal.SystemPlannerController` →
`RC.SystemPlanner`) builds a hypothetical `%StellarSystem{}` and runs
`StellarSystem.update_bonuses/3`, the same call a live system makes. Every
number and breakdown therefore matches the game. The bonuses come from the
game's own extractors:

- **Lexes and faction traditions**: `Instance.Player.Player.extract_bonus/2`
  on a stub player.
- **Governor**: `Instance.Character.Character.extract_bonus/2`, which is what
  `push_character(_, _, :governor)` does.

Population growth comes from `StellarSystem.population_growth/4` and is
returned as `system.population.change`.

Game data comes from a virtual instance id, `{:planner, speed}`.
`Data.Data.get/2` serves it the shared per-(speed, mode) content cache, so a
request never touches a registry or builds data. `GET /api/data?speed=` serves
the same content to the page. Without the parameter, the portal's boot load
keeps the Flash default.

`GET /api/system-planner/template?speed=` is the standard starting system
(`StarterStellarSystemData` + `open_system/1`'s infrastructure). The page opens
on it when there is nothing to import or restore.

The server refuses only what no system could hold:

- an unknown speed, faction, building or lex;
- a building on the wrong biome or tile type;
- a level that doesn't exist;
- a second copy of a unique building;
- an out-of-range population, factor or skill.

It also caps the payload's size. Keys are matched as strings and never turned
into atoms.

These are left out on purpose, because they are temporary or belong to the
faction: sieges, event stability penalties, faction government effects
(a beta), and station buildings.

## Tests

- `test/rc/system_planner_test.exs`: parity with a registry-backed instance,
  each input's effect, the validation errors, and the template.
- `test/portal/controllers/system_planner_controller_test.exs`: the endpoints,
  auth, and `/api/data?speed=`.
- `front/src/portal/planner/__tests__/plan.test.mjs`: export, normalization,
  building rules, patent ancestry and the stash.

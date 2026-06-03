# The Forge — Community Redesign Roadmap

## Context

The Forge (`/create` in the Vue app — `front/src/portal/pages/create/`) is where Maps and Scenarios are designed. It was built for a single audience (admins) when the game was Anthropic-run; with the game going community-run, dozens of authors will create hundreds of designs and need to find, evaluate, and remix each other's work. Today the Forge is:

- **Admin-only** (router guard, navbar hidden, backend gate on every mutating endpoint).
- **Unsearchable**. `Maps.vue` and `Scenarios.vue` render literal `<h2>TODO</h2>` filter copy to users. No search, sort, filter, pagination, or thumbnails (even though the backend has Waffle wiring and GIN indexes ready).
- **Unattributed**. Only an `is_official` boolean — no author column anywhere.
- **Disconnected from gameplay outcomes**. `instances` has no `scenario_id` FK, so "# of games from this map" or "avg time to victory per scenario" are unanswerable today.
- **Crude to author with**. A linear 6-step wizard: random Voronoi triangles → manual triangle-to-sector grouping → probabilistic system placement via density sliders → blackhole/delete tool. No custom shapes, no per-region overrides, no manual edges.
- **Static gameplay**. Every game runs the same rules. No way to introduce variants without forking the engine.

Several capabilities the user wants are *already* implemented but unsurfaced:

- Folders + likes/dislikes/favorites have full API routes (`POST /api/scenarios/:sid/folders/{likes,dislikes,favorites}`) — frontend never calls them.
- Server-side filtering by size/speed/name on map and scenario lists is already wired (`RC.Scenarios.put_map_filters/2`, `put_scenario_filters/2`).
- Thumbnails are wired through Waffle on both schemas — the frontend just never sets one.
- The bonus pipeline (`lib/data/game/content/bonus-pipeline-{in,out}.ex` + `lib/game/core/bonus.ex`) is a composable add/mul system — the natural foundation for most mutators with zero pipeline rewrites.

This plan ships the redesign in six stages, ordered easiest-to-largest. Each stage is independently shippable; later stages depend on earlier ones only where noted.

User preferences captured up front:
- **Keep "Maps" terminology** (no rename to "Galaxies").
- **Mutators before designer rewrite** — Stage 5 is mutators, Stage 6 is the designer overhaul.

---

## Stage 1 — UX polish, inline help, thumbnails

**Goal**: make the existing wizard friendly to a non-admin without changing data or permissions.

**Scope**
- Replace the literal `<h2>TODO</h2>` blocks in `Maps.vue:63-64` and `Scenarios.vue:56-58` with real empty-state copy.
- Add tooltips/info popovers to every slider and toggle in the Map and Scenario wizards explaining what the setting means in plain language. Concentrate on: triangle size, density, group density / spread / attenuation, blackhole radius, victory points per sector, time limit, game speed.
- Step descriptions: each step gets a paragraph explaining *what you're doing and why* — currently the wizard assumes you already know.
- Capture a thumbnail on save. Easiest path: server-side SVG → PNG via Mogrify/ImageMagick during `POST /api/maps` and `/api/scenarios`. Alternative: client serializes the SVG and POSTs it as a multipart field. Pick the client-side route if the backend doesn't already have an image conversion dep.
- Address the two TODO comments inline in `Map.vue:710,712` (validate every sector has ≥1 system before leaving step 3; clear stale step data on finalize).

**Files**
- `front/src/portal/pages/create/{Map,Scenario,Maps,Scenarios}.vue`
- `front/src/locales/{en,fr,de}/portal.json` — every new tooltip needs all three locales (this is a real chunk of writing time, not engineering time; budget for it).
- Optional backend: `lib/portal/controllers/scenarios/{map,scenario}_controller.ex` if thumbnails are generated server-side.

**MVP cut**: tooltips on the top 6 most-confusing settings + step-description paragraphs + remove the literal TODO blocks. Thumbnails can slip to Stage 3 if needed (lists work without them, just look bare).

**No schema changes. No permission changes.**

---

## Stage 2 — Authorship + open the gate

**Goal**: anyone logged in can create maps and scenarios; only admins can mark something "Official"; ownership is enforced.

**Scope**
- Migration: add `author_id` (references `accounts`, `on_delete: :nilify_all`), `published_at` (utc_datetime_usec, nullable) to the `scenarios` table. Add a b-tree index on `author_id` and on `published_at`. (GIN indexes on `game_metadata` only help for JSONB filters — these new top-level columns need their own indexes.)
- Backfill: leave `author_id = NULL` for all existing rows. Render the badge as "Official" when `author_id IS NULL AND is_official = true`. New community designs always set `author_id` on insert.
- Drop `:admin_authorization` from the mutating map/scenario endpoints in `lib/portal/router.ex:305-308`. Replace with a new plug that checks: owner OR admin. Keep `:admin_authorization` on any future "mark official" endpoint.
- Relax `onlyAdminGuard` in `front/src/router.js:9-15` to a generic "logged-in" guard. Move the navbar visibility check in `front/src/portal/layouts/Default.vue:21-26` to "any logged-in user."
- Display author byline on `Maps.vue`/`Scenarios.vue` row and on the editor page header. Author NULL → render "Official" pill; otherwise render the account display name (linked, if profiles exist).
- Draft/published lifecycle: while editing, `published_at IS NULL`. Saving with a "Publish" button sets it. Lists filter to `published_at IS NOT NULL` by default with a "My drafts" tab for the author.
- Rate-limit map/scenario creation (e.g., 5 per hour per account) — easy to add at the plug level. Without this, one spammer can fill the table on day one.
- Cross-author derivation: when creating a scenario from someone else's map, store `source_map_id` (already implicit via the create-from URL) and display "scenario by Alice, on map by Bob." This is just byline copy — the existing data is already there since scenarios already copy `game_data` from a map.

**Files**
- New migration under `priv/repo/migrations/`.
- `lib/rc/scenarios/{map,scenario}.ex` — schema + changeset additions (`author_id`, `published_at`).
- `lib/rc/scenarios.ex` — `put_*_filters/2`, list queries default to published-only; `create_*` set `author_id` from the connection.
- `lib/portal/router.ex` — replace `:admin_authorization` on POST/PUT/DELETE of maps/scenarios with a new pipeline (`:scenario_owner_or_admin`).
- New plug: `lib/portal/plug/authorization.ex` — add `owner_or_admin/2`.
- `front/src/router.js:9-15` and `front/src/portal/layouts/Default.vue:21-26` — relax guards.
- Frontend: Map/Scenario list rows and editor header byline; Publish button in editor; "My drafts" tab.

**MVP cut**: author_id + published_at migration + open the route + author byline + Publish button. "My drafts" tab and rate-limiting can slip a week but should not be skipped.

---

## Stage 3 — Searchability and community surfacing

**Goal**: users find what they want and signal approval; the existing folders/likes backend gets wired up.

**Scope**
- Search box (name + author) on `Maps.vue` and `Scenarios.vue`. Backend `put_*_filters/2` already supports name; extend to author.
- Filter chips: Official / Mine / Favorited / Drafts (mine only) / size / speed (scenarios) / # factions (scenarios).
- Sort dropdown: newest, most-liked, most-favorited. (Most-played sort is deferred to Stage 4 — needs the `scenario_id` FK to count.)
- Pagination — the backend already returns `total` in response headers; wire frontend page navigation.
- Wire the like/dislike/favorite buttons against the existing folder endpoints (`POST /api/scenarios/:sid/folders/{likes,dislikes,favorites}`). On every map/scenario row and on the editor page header.
- Show counts of each on each row from the existing virtual fields on the schema.
- Card-style list option in addition to the current table — once thumbnails exist, cards look nicer and scan faster.

**Files**
- `front/src/portal/pages/create/{Maps,Scenarios}.vue` — controls + cards + pagination.
- `lib/rc/scenarios.ex` — extend `put_*_filters/2` for author search; add sort options for likes/favorites counts. The like/favorite counts are already virtual fields — joining `scenarios_folders` for sorting may need a subquery or a denormalized counter; pick the simplest path.

**MVP cut**: name search + size filter + sort-by-newest + pagination + wire likes/favorites buttons. Author search, most-liked sort, and card view can ship in a follow-up.

**Depends on**: Stage 2 (filter "Mine" and "Drafts" need `author_id`/`published_at`).

---

## Stage 4 — Instance linkage and stats

**Goal**: connect finished games back to their scenario so we can compute "# games created from this map," "avg time to victory," etc.

**Scope**
- Migration: add `scenario_id` (references `scenarios`, `on_delete: :nilify_all`, nullable to preserve historical instances) to `instances`. Add a b-tree index on `scenario_id`. Also add `source_map_id` if we want to report "games run on this map" directly (cheaper than joining through scenarios).
- Set `scenario_id` in `RC.Instances.create_instance/3` (`lib/rc/instances.ex` around line 439). The scenario is already loaded by the controller at this point — just persist the id.
- Aggregate stats per scenario, computed on read (no caching for v1):
  - **games_count** — `count(*) from instances where scenario_id = ?`
  - **avg_duration** — `avg(updated_at - inserted_at) where state = 'ended' and scenario_id = ?`
  - **victory_type_distribution** — `count by victory_type` joined through `victories`
  - **player_retention** — for each instance, count factions whose `final_rank IS NOT NULL` over total registrations; average across instances. This is the "did above-avg players continue playing to the end" metric.
- Expose stats on a scenario detail endpoint and render on the scenario row and card. Add a "Stats" tab on the editor view.
- Once games_count exists, add "most-played" as a sort option in the Stage 3 list controls.

**Files**
- New migration under `priv/repo/migrations/`.
- `lib/rc/instances/instance.ex` — schema field.
- `lib/rc/instances.ex` — set `scenario_id` on insert.
- `lib/rc/scenarios.ex` or a new `lib/rc/scenarios/stats.ex` — aggregate queries.
- `lib/portal/controllers/scenarios/scenario_controller.ex` — show endpoint returns stats.
- Frontend: stats badges on rows; stats tab in editor.

**MVP cut**: migration + write-side hook + `games_count` only. Avg-duration, victory-type breakdown, and retention are real SQL work; ship them in a follow-up once we have data to validate against.

**Note**: a tiny "Stage 3.5" version of this — *just* the migration + write-side hook with no stats — can slip in alongside Stage 3 to unblock the "most-played" sort early. The full stats computation can wait.

---

## Stage 5 — Mutators

**Goal**: per-scenario gameplay variants without engine forks.

**Architecture**
- Add `mutators: [%{key: atom, params: map}]` under `game_data` on scenarios (no migration — `game_data` is already JSONB).
- Define a mutator catalog at `lib/data/game/mutator.ex` (parallel to `patent.ex`, `building.ex`) — keys, display names, descriptions, parameter schemas, and which hook they fire at.
- Single injection point: `Instance.Manager.init_from_model/4` (`lib/game/instance/manager.ex:248`) reads `game_data["mutators"]` and dispatches each.
- For mutators that change ongoing behavior (governor aura, fleet revenge), the mutator catalog entry names the hook (`:on_combat_cleanup`, `:on_governor_assign`, `:on_monument_tick`) and the relevant call sites do a lightweight `if mutator_active?(instance, :foo)` check before applying.

**Initial catalog (ship in this order — each independent)**
1. **Resource scalers** (`:starting_credit_x2`, `:production_x1_5`, etc.) — pure bonus pipeline entries appended at game start. Zero new hook points; validates the architecture. **This is the MVP.**
2. **Starting tech grants** (`:start_with_warp_drive`) — populate `player.patents` in `Player.new/*` (`lib/game/instance/player/player.ex:111`) instead of an empty list.
3. **Fleet revenge** (`:fleet_destroyed_damages_victor`) — hook `Game.Fight.Manager.do_cleaning/2` (`lib/game/fight/manager.ex:272`). When one side is fully destroyed, apply proportional damage to the survivor. **Cascade guard**: tag the damage as "non-triggering" so it can't cause another revenge burst — otherwise A→B→C cascades will eat both fleets. Add property-based tests for ordering/termination.
4. **Governor neighbor aura** (`:governor_bonus_radius_1`) — hook `push_character/3` in `lib/game/instance/stellar_system/stellar_system.ex`. After applying bonuses to the governed system, walk `Instance.Galaxy.SpatialGraph` neighbors and apply a scaled fraction (e.g., 0.5×) to each. **Risk**: this crosses process boundaries (neighbor systems are separate processes); budget a spike before implementing. The "pull on tick" alternative is cleaner but adds load on every system tick.
5. **Monument control scaling** (`:monument_control_bonus`) — when a faction owns all monuments in a sector (or globally — pick one), monuments produce more. This is a **cross-entity condition**, awkward to express as a per-entity bonus pipeline entry. Implement as a faction-level cached flag that gets recomputed when a monument changes hands, then read by the monument's production code. Don't try to force it into the pipeline.

**Frontend**
- Mutator picker in the scenario editor: list catalog entries with descriptions; checkbox + param inputs; preview ("this changes: starting credits 2×").
- Mutator chips on scenario list rows so users can see at a glance which scenarios are "vanilla" vs. "variants."

**Files**
- New: `lib/data/game/mutator.ex`, `lib/data/game/content/mutator-{fast,medium,slow}.ex` if balance varies by speed.
- `lib/game/instance/manager.ex:248` — read & dispatch.
- Hook sites (one mutator at a time): `lib/game/instance/player/player.ex`, `lib/game/fight/manager.ex:272`, `lib/game/instance/stellar_system/stellar_system.ex` (`push_character/3`).
- Frontend: `Scenario.vue` adds a mutator-picker step; `Scenarios.vue` shows mutator chips.

**MVP cut**: catalog module + dispatcher in `init_from_model/4` + one resource-scaler mutator + scenario editor picker. This validates the architecture before any hook-point work. Then ship mutators 2→5 one at a time, each independently testable.

**Risks**
- Speed-dependent balance: the bonus pipeline values differ across `lib/data/game/content/constant-{fast,medium,slow}.ex` and friends; mutator effects may need per-speed tuning to avoid breaking pace.
- "Vanilla" is no longer the only mode — mutator chips on rows become important for player expectation-setting.

---

## Stage 6 — Designer expressiveness

**Goal**: let authors build the maps they want — mirror-symmetric layouts for fair multi-faction play, shape primitives instead of laboriously combining Voronoi triangles, and per-sector control of system count.

**User-desired outcomes (driving the design)**
- **Mirror maps** for 1v1 / 2v2 / 1v1v1 / 4-faction FFA. Horizontal, vertical, or radial-{3,4,5,6,8} symmetry. *Perception* of fairness — equal travel distances and equal system counts per region — matters as much as exact balance. This is by far the top community ask.
- **Shape primitives** (rectangle, ellipse, regular N-gon, free-draw polygon) instead of grouping Voronoi triangles into rough shapes. Today, custom shapes require huge galaxy + tiny triangles + tedious grouping.
- **Composed arrangements** (barbell, whirlpool, ring, nested ring) emerge from primitives + symmetry; no presets ship — let community discover them.

**Architecture: hybrid storage**

Under `game_data` (JSONB, no migration):

```
game_data = {
  sectors: [...], systems: [...], edges: [...],   // expanded — what game/render reads
  editor_source: {                                // present only in symmetric mode
    symmetry: { kind: 'none'|'horizontal'|'vertical'|'hv'|'radial', fold: 3..8, axis_or_center: {...} },
    active_region: { sectors, systems, edges },
    seeds: { voronoi, placement },
    expanded_hash: '...',
    version: 1,
  },
  editor_source_backup: {...}                     // last source before "break symmetry"; revertable
}
```

Consumers (in-game galaxy, spatial graph) read the expanded arrays and never need to know symmetry exists. Editor reads `editor_source` if present, falls back to expanded arrays otherwise. Expansion is a pure function: `expand(editor_source) → { sectors, systems, edges }`, run in the browser at save time; the result is what gets persisted.

**System placement: invert the density knob**

Today: density 30% over polygon, count emerges from RNG → mirrored sectors get different counts → perceived imbalance.

Per-sector "place exactly **N** systems, weighted by hot-point falloff": sample candidates inside the polygon, score with the existing hot-point + attenuation formula ([editor.js:144-148](front/src/utils/editor.js:144)), take top N. The density/spread/attenuation knobs become the *shape of the distribution*, not the count. Falls back to density-emerges when count is unset (backward compatible).

Determinism for symmetry: in mirrored sectors, generate N positions in the canonical region only, then transform them to mirrored regions. Never re-roll RNG on the mirrored side.

**Symmetry mechanics**

- **MirrorCursor** wraps every placement op (sector add, system add, edge add) and fires N copies via the symmetry transform. Live mirror in the editor; expansion produces the same result deterministically at save time.
- **Snap-to-axis**: a system placed within 1 grid unit of the axis (or radial center) snaps to the axis (one system, self-mirroring). A sector polygon straddling the axis is clipped-and-mirrored, not doubled.
- **Kind switching mid-edit**: clip the active region to the new wedge; strokes outside the new region drop. Lossy but lets authors iterate without backing out of the flow. Confirmation prompt before destructive clip.
- **Break-symmetry-to-edit-asymmetrically**: explicit button. Expands `editor_source` into the full canvas, clears it, stashes the prior value into `editor_source_backup` for one-click revert. Storage isn't a concern, so the backup is kept indefinitely.
- **Drift guard**: store `editor_source.expanded_hash` at save time. On load, hash the expanded arrays and compare; mismatch prompts the author to choose canonical source (default: expanded data wins).
- **Seed persistence**: today the wizard's Voronoi and placement seeds ([Map.vue:343, 427](front/src/portal/pages/create/Map.vue:343)) are not saved — re-opening a map shows blank seed fields. Persist both inside `editor_source.seeds` so re-expansion is reproducible and "verified mirror" is a stable property.

**Shape primitives**

Rectangle (4 verts), ellipse (polygonize at 32), regular N-gon (N verts), free-draw polygon. All collapse to `sector.points` polygons — the existing system-placement pipeline ([editor.js:112-170](front/src/utils/editor.js:112)) handles arbitrary polygons unchanged. Legacy Voronoi-triangle-grouping mode stays as an alternative for authors who like it.

**Manual edges**

`game_data.edges: [{from_system, to_system, kind: 'force'|'sever'}]` applied post-process to the auto-computed proximity edges in [spatial_graph.ex](lib/game/instance/galaxy/spatial_graph.ex). Required for arrangements (barbell bulb-to-bulb, whirlpool inward paths) where the `@max_dist = 12` proximity rule won't connect distant regions. In symmetric mode, edges live in `active_region.edges` and mirror on expansion.

**Composition examples (no presets ship)**
- **Barbell**: 2 ellipses + 1 rectangle bridge, horizontal symmetry. ~2 min to author.
- **4-faction whirlpool**: 1 outer ellipse + 1 inward narrow rectangle, radial-4. Central cluster is the natural overlap.
- **Ring**: 1 rectangular arc slice, radial-6 or radial-8.
- **Nested rings**: 2 arc slices at different radii.

**Scope (each independently shippable, in this order)**
1. **Per-sector system count override**. `genSystem` accepts optional `systemCount` per sector; falls back to density-emerges when unset. Per-sector input field in the wizard. Prerequisite for symmetry feeling symmetric.
2. **Shape primitives** (rectangle, ellipse, regular N-gon, free-draw). Alternative to Voronoi-triangle grouping in step 2. Tool palette; legacy mode preserved.
3. **Hybrid storage** (`editor_source` block, seed persistence, expansion function, expanded-hash). Scaffolding; no visible features. No migration.
4. **Symmetry mode** + `MirrorCursor`: horizontal & vertical first; radial-{3,4,5,6,8} after. Snap-to-axis, clip-on-kind-switch, break-symmetry, drift hash check.
5. **Manual edges** (force/sever) post-process in `spatial_graph.ex`. Required for non-trivial arrangements.
6. **Per-sector overrides** (density/group/spread/attenuation per sector). Useful for asymmetric authors who want regional variation in the Voronoi flow.

**Files**
- Frontend: `front/src/portal/pages/create/Map.vue` — wizard restructuring, tool palette, symmetry toggle.
- `front/src/utils/editor.js` — `genSystem` count override, expansion function, MirrorCursor, shape primitives, hash.
- Backend: `lib/game/instance/galaxy/spatial_graph.ex` — manual-edge post-process (item 5).
- i18n: `front/src/locales/{en,fr,de}/portal.json`.
- No schema migration.

**MVP cut**: items 1–4 (per-sector count + shape primitives + hybrid storage + horizontal/vertical symmetry). That delivers the top community ask. Radial, manual edges, per-sector overrides ship one at a time after.

**Risks**
- Symmetry kind switching is lossy. Make the clip-and-drop behavior obvious in UI; require confirmation.
- `MirrorCursor` must handle non-trivial topology: a sector straddling the axis needs clip-and-mirror (not duplicate-and-overlap). Test with shapes that cross axis lines.
- In-game galaxy must work for all arrangements, including disconnected components after manual `sever`. The spatial graph and game-state assumptions may not survive a disconnected map; needs a smoke test before shipping item 5.

---

## Critical files (one-line index)

- **Frontend wizard**: `front/src/portal/pages/create/{Map,Scenario}.vue`
- **Frontend lists**: `front/src/portal/pages/create/{Maps,Scenarios}.vue`
- **Frontend gating**: `front/src/router.js:9-15`, `front/src/portal/layouts/Default.vue:21-26`
- **Frontend editor utils**: `front/src/utils/editor.js`
- **i18n**: `front/src/locales/{en,fr,de}/portal.json` (Forge keys under `page.create.*`)
- **Map/Scenario schemas**: `lib/rc/scenarios/{map,scenario}.ex`, `lib/rc/scenarios.ex` (context + filters)
- **Folders backend** (already built, just unsurfaced): `lib/rc/scenarios/{folder,scenario_folder}.ex`, controller at `lib/portal/controllers/folder_controller.ex`
- **API router**: `lib/portal/router.ex:175-185, 305-308`
- **Auth plugs**: `lib/portal/plug/authorization.ex`
- **Instance schema**: `lib/rc/instances/instance.ex`, context `lib/rc/instances.ex`
- **Victory schema**: `lib/rc/instances/victory.ex`
- **Mutator injection point**: `lib/game/instance/manager.ex:248` (`init_from_model/4`)
- **Combat hook (fleet revenge)**: `lib/game/fight/manager.ex:272` (`do_cleaning/2`)
- **Governor hook (neighbor aura)**: `lib/game/instance/stellar_system/stellar_system.ex` (`push_character/3`)
- **Bonus pipeline (mutators)**: `lib/data/game/content/bonus-pipeline-{in,out}.ex`, `lib/game/core/bonus.ex`
- **Spatial graph (manual edges)**: `lib/game/instance/galaxy/spatial_graph.ex`

---

## Verification

Each stage gets its own end-to-end check. None of these are unit tests; they're "did the feature actually work" walkthroughs.

**Stage 1**
- Log in as admin, open `/create/map/new`, hover every slider — tooltip appears, copy reads as written, all three locales render.
- Empty Maps/Scenarios lists show the new copy, not `<h2>TODO</h2>`.
- Save a new map; thumbnail appears in the list row.

**Stage 2**
- Log in as a non-admin community account; navbar shows the Forge link; `/create` loads.
- Create a draft map; it does not appear in the public list. Click Publish; it now appears with your name as the byline.
- Try to edit another user's map via the API directly (curl); 403.
- Existing official maps still display with the "Official" badge and no author name.
- Rapid-fire 6 create requests as a non-admin; the 6th is rate-limited.

**Stage 3**
- On `/create/maps`, type a name into search; only matching maps show. Apply "Mine" filter; only your maps show.
- Click the heart on a map; refresh; the heart is still filled and the count incremented.
- Verify pagination at page 2 returns the next batch and the count badge matches the total header.

**Stage 4**
- Create a game instance from a scenario; in the database, `instances.scenario_id` is set.
- Finish that game; the scenario row's `games_count` increments. (Stats beyond `games_count` ship in the follow-up.)

**Stage 5**
- For each shipped mutator, run a game with it enabled and verify the effect at the table/process level (e.g., starting credit doubled in `player.credit.value`).
- Run a game with NO mutators; verify behavior matches the pre-Stage-5 baseline (no regression).
- For fleet revenge: scripted combat where side A is fully destroyed; verify side B takes the expected proportional damage AND that the revenge does not cascade.

**Stage 6**
- #1 (per-sector count): create a map with two sectors, set 12 and 8 systems; regenerate; counts match exactly. Re-roll the seed; counts still 12 and 8.
- #2 (shape primitives): build a barbell map from 2 ellipses + 1 rectangle; sector polygons render; systems place inside them.
- #3 (hybrid storage): save a map with `editor_source` populated; reload; editor opens in symmetric mode with the same active region. Hash mismatch path: hand-edit the expanded arrays in the DB; reload; mismatch prompt appears.
- #4 (symmetry): with horizontal symmetry on, place 4 systems on the left side at varied positions; mirror copies appear at exact reflected positions; save+reload preserves this. Place a system within 1 grid unit of the axis; it snaps to the axis (single system, not two near-overlaps).
- #4 (kind switch): with H symmetry and 3 sectors, switch to radial-4; confirmation prompt; sectors outside the wedge drop; remaining sectors mirror to 4 quadrants.
- #4 (break symmetry): click "Convert to asymmetric"; both halves editable independently; click "Restore symmetric"; previous editor_source returns.
- #5 (manual edges): manually sever an edge between two adjacent systems; in a game from the resulting scenario, those systems are not directly connected. Manually force an edge between two distant systems; they connect.

End-to-end smoke for every stage: create a map → derive a scenario → spin a game → observe expected behavior in the live instance. The chain breaks if any stage was missed.

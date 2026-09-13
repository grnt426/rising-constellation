# In-game help manual — design

Status: **draft, 2026-09-13**. Nothing here is built yet. This doc covers
(1) what the manual is and where it shows up, (2) how content is stored and
compiled so numbers never drift from the code, and (3) the agent pipeline
that writes and verifies the content. The first-pass inventory the pipeline
starts from is `docs/help-manual-inventory.md`; §8 summarizes it with the
review verdicts of 2026-09-13.

## 1. Goals

- Explain every mechanic a player can see in the UI: every icon, term, and
  number with a formula behind it.
- Plain, flat language. Numbers and formulas over adjectives. No marketing
  voice. A page is short enough to read in under a minute.
- Linkable. Every page has a stable slug. Pages link to each other. The game
  can open a page from any card or resource line.
- Three surfaces, one content source:
  1. a **help modal** inside the game (like Search / Quick calc) for "what is
     this?" moments,
  2. the existing **Help drawer** (left panel, `H`) extended with a full
     manual: table of contents, glossary, search,
  3. a **public site** section at `/help/<slug>` that needs no login and can
     be crawled.
- Accuracy is enforced by construction: constants, catalog tables, and
  cross-reference lists are generated from the game data modules at compile
  time. Prose is written by agents and verified by other agents against the
  code before it is accepted.

Non-goals: SEO, lore, strategy advice, replacing the tutorial, translating
into fr/de in the first pass (see §5.4).

**Excluded scope (decided 2026-09-13).** Beta and unfinished features are
neither crawled nor documented until they ship: faction government
(elections, seats, treasury, income tax, tithe, tyranny, faction patents,
faction lexes and laws), faction buildings and orbital stations, armadas,
gateways / portals and the Singularity Ring (`hypergate`), inter-faction
diplomacy (stances, pacts, tension, war meters), and the account beta flags
(`agent_fan_display`, `mobile_ui`, `slim_sync`). Where a shipped mechanic
touches one of these, the page says nothing about it. The inventory keeps
those sections for later, marked excluded.

## 2. What exists today

| Piece | Where | State |
| --- | --- | --- |
| Help drawer | `front/src/game/components/panel/HelpPanel.vue` | 4 sub-panels: Hotkeys, Legend (map icons), Stances (Navarch reaction matrix), Links (external FAQ + French fandom wiki). Not linkable, no search. |
| Resource tooltips | `game.json` → `resource-description.*` (12 keys), shown as a `?` in `generic/ResourceDetail.vue` | One sentence each, no formulas. This is the closest thing to a help entry point today. Two of them (housing, workforce) are wrong; see §9. |
| Data descriptions | `data.json` → `data.building/patent/doctrine/ship.*.description` | **201 of 215 are the placeholder `—`.** Lexes are the exception (their `description` is a real one-liner). |
| Agent skill descriptions | `data.json` → `data.character.<type>.skills[]` | One sentence each. |
| Tutorial | `game.json` → `tutorial.step0..58`, `front/src/game/components/Tutorial.vue` | 59 steps of guided prose; embeds building/patent cards. Good source of existing wording. |
| Bonus cards | `card/CardComplexBonus.vue` | Renders the bonus pipeline (`from → to`, add/mul) per building level with icons. This is the machine-readable "what does it give" already shown in the UI. |
| Wiki tables | `lib/mix/tasks/{building,patent,lex}_table.ex`, `generate_wiki_tables.sh` | Generate French MediaWiki tables from the content modules for the old fandom wiki. Proof that catalog tables can be generated from `Data.Game.*`. |
| Public site | `lib/portal/live/public/*` (Landing, About, Patch notes, CGU…) | Phoenix LiveViews with `public_layout`. Earmark is already a dependency for server-side markdown. |
| Markdown in the SPA | `front/src/utils/markdown.js` (`marked` + escape), `$tmd` | Exists but only used for a few i18n strings. |
| Icons | `front/src/icons/**` (vue-svgicon JS modules, ~350 icons in 13 groups) | Only renderable inside the SPA today. |

Locale coverage: `en` and `fr` are complete for `game.json`/`data.json`;
`de` is roughly a quarter of the size and is not maintained. Steam builds
(`config.IS_STEAM`) cannot open external links, they only copy URLs, so the
in-game copy of the manual must be complete on its own and never a link-out.

## 3. Content model

### 3.1 One page per topic, markdown with a small extension syntax

Source of truth: `priv/help/en/<category>/<slug>.md`. One file per page.
`priv/` so the files ship in the release and the Phoenix side can serve them.

```markdown
---
id: mobility
title: Mobility
category: systems
icon: resource/mobility
terms: [mobility, population mobility, mobility bonus]
related: [taxes, population, credits, happiness]
sources:
  - lib/game/instance/stellar_system/stellar_system.ex:1831-1857
  - lib/game/core/bonus.ex:12-30
  - lib/data/game/content/constant-slow.ex:12-13
speed_sensitive: true
---

{icon:resource/population} Population generates [[taxes]] as
{icon:resource/credit} credits. {icon:resource/mobility} Mobility is a
multiplier on that: every point of mobility adds
{const:system_mobility_taxes_factor} credits per population point per tick.

Example (Legacy):

    100 population × {const:system_population_taxes_factor} = 200 credits/tick   (taxes)
    100 population × 45 mobility × {const:system_mobility_taxes_factor} = 450 credits/tick   (mobility bonus)
    total = 650 credits/tick

The bonus multiplies the credit subtotal after all flat bonuses. If that
subtotal is negative, the mobility bonus is skipped.

## Buildings that produce mobility

{table:buildings_by_output sys_mobility}

## What changes mobility

{table:bonus_sources sys_mobility}
```

The extension tokens are the whole point. Prose never contains a raw number
that exists in code, and never contains a hand-typed list of buildings.

| Token | Expands to | Resolved by |
| --- | --- | --- |
| `{icon:group/name}` | the SVG icon, inline, with the icon's UI name as tooltip | renderer (SPA: `svgicon`; public: sprite) |
| `{const:key}` | the value of `Data.Game.Constant.key` for the current speed | compiler, per speed |
| `{name:building.hab_open}` | the localized UI name from `data.json` | compiler, per locale |
| `[[slug]]` / `[[slug|label]]` | link to another help page; a bare plain-word slug is shown as typed (`[[taxes]]` → "taxes"), a prefixed or hyphenated slug shows the page title | compiler; broken links are lint errors |
| `{table:<generator> <args>}` | a generated table (see 3.3) | compiler, per speed + locale |
| `{ui:panel.help.stances_title}` | a UI string from `game.json`, for "the button labelled X" | compiler |

### 3.2 Page types

- **Mechanic pages** (prose + generated tables): mobility, taxes, stability,
  interception, siege, cover, victory points… ~80–120 pages. Written by
  agents.
- **Catalog pages** (generated + one prose slot): one per building (47),
  patent (64), lex (61), ship (38), mutator (56), faction (5), tradition
  (20), agent skill/specialization. The page shell (name, icon, costs, bonus
  table per level, prerequisites, unlocks, "used by") is 100% generated from
  the content modules. The prose slot is one to three sentences, written by
  agents, and is allowed to be empty.
- **Glossary**: generated from every page's `terms:` list, one line each,
  linking to the page.
- **Index pages**: one per category, generated from frontmatter.

### 3.3 Generated tables

Implemented once in Elixir (`RC.Help.Tables`) against `Data.Game.*` content
for a given speed, so the same generator feeds all three surfaces:

| Generator | Source | Example use |
| --- | --- | --- |
| `buildings_by_output <sys_key>` | `Data.Game.Building` levels' `bonus.to` | "Buildings that produce mobility", sorted by body type (habitable / sterile / orbital), level 1 → max |
| `buildings_by_input <from_key>` | `bonus.from` | "Buildings that scale with mobility" |
| `bonus_sources <sys_key>` | lexes + traditions + agent skills whose bonus hits `<sys_key>` (buildings have their own table; faction trees and mutators excluded) | "Other sources of mobility" |
| `building_levels <key>` | one building, all levels | catalog page body |
| `patent_unlocks <key>` / `unlocked_by <building|ship>` | patent → buildings/ships mapping | catalog pages |
| `ship_stats <class>` | `Data.Game.Ship` | ship class comparison |
| `constants <prefix>` | `Data.Game.Constant` fields | "All siege constants" at the bottom of a page |
| `actions <agent_type>` | action modules' metadata | Navarch / Siderian / Erased action lists |

Every table is rendered per speed (Flash / Tactic / Legacy). The daily mode
uses Legacy content.

### 3.4 Style rules (the lint the reviewers enforce)

1. Say what happens, then the formula, then one example with real numbers.
2. First sentence of a page defines the term. No preamble.
3. Use UI names only: Navarch, Siderian, Erased, Intelligence, Cybersecurity,
   Lex, S.L.S.D. Never `admiral`, `spy`, `speaker`, `doctrine`, `sys_ci`.
4. No adjectives of quality ("powerful", "crucial"). No advice ("you should").
5. A mechanic page is at most ~250 words of prose plus tables. A catalog prose
   slot is at most 3 sentences.
6. Every number that exists in code is a `{const:}` token or lives in a
   generated table.
7. Every other mechanic named in the prose is a `[[link]]` the first time it
   appears.
8. When the code has an edge case (a failed Destabilize still costs 5
   stability, Deserter arrivers escape on a flat 50 % roll), say it in one
   sentence. Do not hide it. Intentional quirks are documented as behavior,
   not apologized for.
9. Population is counted in points ("1 population"), never "1 billion
   people". Housing is a soft cap: growth slows toward it, population can
   exceed it.
10. Code comments are not evidence. A claim is true if the code does it;
    comments at best explain intent and are cited only as intent.
11. Numbers and tables always show the speed they belong to. In-game, that is
    the loaded instance's speed. On the public site, Legacy.

## 4. Surfaces

### 4.1 Help modal (`front/src/game/components/HelpOverlay.vue`)

Copies the `SearchOverlay.vue` / `QuickCalc.vue` pattern: `v-if="isOpen"`,
`f-<theme>` class, `$root.$on('toggleHelp' | 'closeHelp')` with `$off` in
`beforeDestroy`, Esc closes, backdrop click closes, mounted in `Game.vue`
next to the other two as a sibling of the panels container. Hotkeys are
`v-shortkey` entries in `Game.vue` (not v-hotkey); the root element needs the
`calc-suppress` class or single-letter hotkeys fire while typing in the
search box. `z-index` 560 like Quick calc. It does not touch the store's
overlay stack; only panels and the system view do.

- Open: `this.$root.$emit('toggleHelp', { page: 'mobility', anchor?: '…' })`.
  Also `?help=mobility` on `/game` at load (no query param is read there
  today, so this is safe), and a `help` chat-ref kind next to the existing
  `[[sys:id|label]]` refs so players can link a page in chat.
- Content: title, icon, the page body, "Related" chips. Back / forward
  history inside the modal so `[[links]]` are cheap to follow.
- Header buttons, like Quick calc: **Expand** (opens the Help drawer on the
  Manual tab at the same page, via `togglePanel('help', { page })`), **Copy
  link** (public URL, works in Steam via clipboard), **Close**.
- Size: ~520 px wide, max 70 vh, scrolls inside. Mobile (`mobile.scss`,
  768 px): full width, bottom sheet.
- Speed: the modal uses the current instance speed for `{const:}` and tables.

### 4.2 `?` entry points

A tiny `help-button` component (`?` in a circle, same look as the `info`
span in `ResourceDetail.vue`) that takes a `page` prop and emits `toggleHelp`.
First-pass placement, one per row of the surface map in the inventory's §9:

- `ResourceDetail.vue` title row → the resource's page (mobility, taxes…).
  Replaces the current one-sentence tooltip.
- Card headers: `BuildingCard`, `PatentCard`, `DoctrineCard`, `ShipCard`,
  `CharacterCard`, `SectorCard`, `TargetSystemCard`, `FactionTreeCard`,
  `ProfileCard` → the catalog page or the mechanic page.
- `CardComplexBonus.vue` rows: the `from`/`to` icon opens the resource page.
- Action menus in the system / character views: each action opens its page.
- Victory, market, character market, patent and lex mini-panels: one `?` in
  the header.
- Fight and event reports: `?` on "interception", "siege", "cover blown"…
- The Help drawer's Legend and Stances pages become manual pages themselves,
  so they get links instead of duplicating text.

### 4.3 Help drawer (existing `HelpPanel.vue`)

Add a fifth sub-panel, **Manual**, made the default, in the `is-medium`
(900 px) content shell. It has a search box (title + terms + body,
client-side, same approach as `SearchOverlay`), the category tree, the
glossary, and the page view. `HelpPanel.open(data)` is a no-op today; making
it select the Manual tab and page is the one-line deep-link hook, the same
way `EmpirePanel.open({ tab })` works for Quick calc's expand button. Hotkeys,
Legend, Stances stay as they are but Legend and Stances become thin wrappers
around manual pages (`map-legend`, `stances`), so their text is authored
once. The panel navbar has no per-tab icons today (grey squares); adding one
for Manual is new CSS.

### 4.4 Public site

`GET /help` and `GET /help/:slug`, added to the public scope in
`lib/portal/router.ex` next to `/about` and `/patch-notes`, rendered by a
`HelpLive` (or a plain controller; LiveView only for the search box). Uses
`public_layout` plus a nav link, a `<title>` per page, and a speed switch.
Legacy is the default and the only speed named in the page header; Tactic
and Flash are a small "other speeds" link under it, since they are rarely
played. The switch swaps which pre-compiled variant is shown and is
remembered in the URL (`?speed=fast`) so links stay honest. In-game surfaces
never show a switch: they always render the loaded instance's speed. Same
slugs as in-game, so the "Copy link" button in the modal yields
`https://tetrarchyfalls.com/help/mobility`. No auth, no JS requirement for
reading: the HTML is complete on first load, which is what makes it
crawlable. Server-side markdown already exists (`RC.Markdown`: Earmark +
HtmlSanitizeEx), so the compiler reuses it.

The Phoenix site and the SPA do not share CSS (`assets/css` vs
`front/src/styles`, different variables and fonts). The public pages get
their own `assets/css/views/_help.scss` matched to the existing
`pk-content` look; the manual's HTML uses a small fixed set of classes
(`help-page`, `help-body`, `help-icon`, `help-ref`) so the two
stylesheets style the same markup.

Icons on the public site come from an SVG sprite generated from
`front/src/icons/**`. The original SVG sources are not in the repo, but each
vue-svgicon module holds the raw path data, so a 50-line node script can
emit `assets/static/img/help-icons.svg` at build time.

### 4.5 Sharing one compiled artifact

```
priv/help/en/**/*.md ──┐
Data.Game.* content ───┼─► RC.Help (compile-time, @external_resource) ─► %{slug => %{meta, html: %{fast, medium, slow}, text}}
front/src/locales/*.json ┘                                                 │
                                                                            ├─► HelpLive renders html[speed]            (public site)
                                                                            └─► GET /api/help/:lang (public, cached)    (SPA modal + drawer, fetched once, lazily)
```

- The SPA fetches the bundle the first time any help surface opens, then
  keeps it in the store. ~1–2 MB of HTML for ~400 pages is fine.
- `{icon:}` compiles to `<i class="help-icon" data-icon="resource/mobility">`;
  the SPA renderer swaps those for `svgicon` after mount, the public page
  uses `<svg><use href="/help/icons.svg#resource--mobility">`.
- Search index (title, terms, plain text) is part of the same bundle.
- Dev: `mix help.check` (link, icon, const, name lint) runs in CI; the bundle
  recompiles when a `.md`, a locale file or a content module changes
  (all are `@external_resource`s of `RC.Help`). Lint never fails
  compilation, only the task, so a broken link cannot take the game down.
- The compiler disables Earmark's smart quotes and runs the same sanitizer
  as blog posts; icons and links are swapped in after sanitizing, which is
  why they can carry `class` and `data-*` attributes.

## 5. Generation pipeline (the agent process)

The manual is written by agents from the code, not from memory, and every
page is accepted only after independent verification. Runs are orchestrated
with the Workflow tool (`.claude/workflows/help-*.js`) and all intermediate
outputs are files in the repo, so a run is resumable and reviewable in a PR.

### 5.1 Categories (one workflow run each)

| # | Category | Rough page count |
| --- | --- | --- |
| 1 | Systems & dominions (resources, population, stability, bodies, colonization, sieges, dominions) | 25 mechanic |
| 2 | Buildings (queue, tiles, costs) | 7 mechanic + 45 catalog |
| 3 | Patents, lexes, traditions, cultures | 7 mechanic + ~150 catalog |
| 4 | Navarchs & fleet actions (jumps, stances, interception, raid/bombard/conquest/colonize, siege, repair) | 18 mechanic |
| 5 | Ships & battle resolution (classes, stats, XP, rounds, targeting, reports, simulator) | 10 mechanic + 38 catalog |
| 6 | Siderians | 8 mechanic |
| 7 | Erased (cover, malware, Intelligence, Cybersecurity) | 10 mechanic |
| 8 | Agents in general (ranks, XP, wages, market, deck) + player economy (income, calculator) | 12 mechanic |
| 9 | Factions (traits, traditions, chat), victory, ranking | 10 mechanic + 5 catalog |
| 10 | Galaxy & UI (map legend, detection, sectors, black holes, hotkeys, search, ruler, copy modes, settings) | 12 mechanic |
| 11 | Game modes & time (speeds, ticks, calendar, mutators, scenarios/Forge, daily, tutorial; wave defense once its branch merges) | 8 mechanic + 56 catalog |

Rough total: ~125 mechanic pages, ~300 catalog prose slots, after removing
the excluded scope (§1). The full mechanic list per category is in
`docs/help-manual-inventory.md`; its government, diplomacy, faction-tree,
station, armada and gateway sections are marked excluded and skipped by the
writers.

### 5.2 Per-category workflow

```
phase 0  Inventory      (done once, docs/help-manual-inventory.md; refreshed by an Explore agent per run)
phase 1  Write          1 writer agent per batch of ~8 pages. Inputs: inventory slice, style rules,
                        page template, the list of allowed tokens/tables, existing locale strings.
                        Output: priv/help/en/<cat>/<slug>.md with `sources:` file:line for every claim.
phase 2  Verify         per page, in parallel:
                          2a code-accuracy critic: re-reads every cited source, re-derives every
                             formula from what the code DOES (comments are intent, not evidence),
                             RUNS the numbers in the Docker `rc` container (real constructors,
                             not hand math) and diffs against the page's example. Combat and
                             damage claims are checked against the battle simulator (`lib/sim/*`,
                             `mix sim.demo`) rather than read off the code. Emits findings
                             {claim, verdict: correct|wrong|unverifiable, evidence}.
                          2b clarity critic: applies the style rules (§3.4) as a checklist, flags
                             jargon, internal keys, missing links, length.
                          2c 3 voters (independent, no shared context): score accuracy 1–5 and
                             clarity 1–5 with a one-line reason each. Voters see the page + the
                             two critics' findings.
phase 3  Decide         accept if min(accuracy) ≥ 4 and mean(clarity) ≥ 4 and no `wrong` finding.
                        Otherwise a reviser agent gets page + findings + votes, rewrites, and the
                        page goes back to phase 2. Max 2 revisions; after that it is parked in
                        help/.review/parked.md for a human.
phase 4  Lint           `mix help.check`: links resolve, icons exist, consts exist, names exist,
                        no raw internal keys, no forbidden words, length caps. Mechanical, no agents.
```

Each phase writes its record to `help/.review/<slug>.json` (findings, votes,
revision count) so the PR shows why a page was accepted.

Per-category cost, upper bound: 25 pages × (1/8 writer + 2 critics + 3 voters
+ up to 2 × (1 reviser + 5 re-reviews)) ≈ 25 × 17 = ~430 agent calls at the
worst case, ~150 typical. Critics and voters are small tasks (one page each)
and can run on a cheaper model; the writer and the code-accuracy critic
should not.

### 5.3 Cross-category pass (one workflow run after all categories)

The category writers are deliberately narrow. The second pass looks at the
seams:

1. Build the pair matrix from `related:` links and from the inventory's
   cross-link lists: e.g. Navarchs×Systems (pillage, bombard, conquest, siege,
   defense), Erased×Ships (sabotage damage), Erased×Systems (malware,
   Intelligence, Cybersecurity), Siderians×Systems (stability, dominions),
   Siderians×Navarchs (a Navarch cannot stop a Siderian takeover but can
   stop another Navarch's conquest), Patents×Buildings (unlocks),
   Patents×Ships (unlocks), Lexes×Agents (limits), Victory×Systems
   (sectors), Buildings×Ships (shipyard XP).
2. One **seam critic** per pair reads both pages' sets and reports:
   contradictions (page A says X, page B says Y), one-way links, terms named
   differently, interactions missing from both sides, and a proposed fix with
   which page owns the explanation.
3. A reviser applies the fixes; the affected pages go through phase 2 again.
4. A **glossary critic** reads the generated glossary end to end and flags
   duplicate terms, terms with no page, and pages with no terms.

### 5.4 Locales

English is the authored source. `fr` is a real locale for names and UI
strings, so `{name:}` / `{ui:}` tokens already localize; the prose does not.
Plan: ship English prose in all locales for the first release, with a
"translation pending" note; a later run adds `priv/help/fr/**` by a
translator agent + native-reader vote, using the same review record format.
`de` is out of scope.

### 5.5 Keeping it true over time

- `mix help.check` in CI fails on dangling links, unknown consts/icons/names.
- A `help_consistency_test.exs` asserts every catalog key in `Data.Game.*`
  has a page, and every page's `sources:` lines still exist.
- Content-module changes (a new building, a changed constant) regenerate
  tables and constants automatically. Prose that a constant change makes
  wrong is caught by re-running only phase 2 for pages whose `sources:` touch
  the changed files; a small script maps `git diff --name-only` to affected
  slugs.

## 6. Delivery plan

| Step | What | Depends on |
| --- | --- | --- |
| 0 | The locale and tooltip fixes in §9, so the writers do not inherit wrong text. | — |
| A | `RC.Help` compiler: frontmatter, tokens, `[[links]]`, Earmark, per-speed variants, `mix help.check`. Generated tables for buildings/bonus sources/constants first. **Landed 2026-09-13**: `lib/rc/help/*`, `mix help.check`, five draft pages under `priv/help/en/systems/`, `test/rc/help/help_test.exs`. Pending from this step: `patent_unlocks`/`unlocked_by`, `ship_stats`, `actions` generators; heading anchors. | — |
| B | Public `/help` pages + icon sprite script. **Landed 2026-09-13**: `Portal.HelpLive` (`/help`, `/help/:slug`, `?speed=`, `?lang=`, `?q=` search that also works without JS), `assets/css/views/_help.scss`, "Manual" nav link, sprite built by `npm run help-icons --prefix assets` from `front/src/icons` into `assets/static/img/help-icons.svg` (committed; `build-front.sh` regenerates it), `test/portal/live/help_live_test.exs`. Legend / stances / hotkeys pages not yet ported. | A |
| C | `GET /api/help/:lang`, `HelpOverlay.vue`, `help-button`, Manual tab in the drawer, `?help=` deep link, `?` buttons on `ResourceDetail` and the 5 main cards. Behind the beta-feature flag `help_manual` using the existing 4-touchpoint gating recipe. **Landed 2026-09-13**: `Portal.HelpController` (public, ETag), Vuex module `front/src/game/help/store.js` (lazy bundle per lang × instance speed; dailies read Legacy), `front/src/game/help/render.js` (icon markers → inline svg from the vue-svgicon registry; plain-node tests), `HelpOverlay.vue` (history, Expand, Copy link), `panel/help/Manual.vue` (search, TOC, glossary, page view; default tab when the beta is on), `HelpButton.vue` (renders only when the page exists; `fallback` keeps the old tooltip). Slugs wired: resource lines (`population`, `housing`, `stability`, `production`, `credit`, `technology`, `ideology`, `mobility`, `slsd`, `intelligence`, `cybersecurity`), cards (`building/<key>`, `patent/<key>`, `lex/<key>`, `ship/<key>`, `agent/<type>`). | A |
| D | Category workflows 1–11 (§5.2). Start with Systems and Buildings, since Mobility-style pages exercise every token and table type. Cybersecurity is the first page in category 7. | 0, A |
| E | Cross-category pass (§5.3), glossary, search index. | D |
| F | Human read-through, drop the beta flag, announce. | E |
| G | Remaining `?` placements, fr prose. | F |

A and D can start in parallel: the writers only need the token syntax agreed,
not the compiler finished, and the lint catches mismatches later.

## 7. Decisions (resolved 2026-09-13)

1. **Slug policy.** Kebab-case English; catalog pages prefixed by type with
   the internal key as the stable part (`building/hab-open`,
   `patent/citadel`, `lex/admiral-4`). Renames add an `aliases:` entry that
   compiles to a redirect.
2. **`?` on cards.** Header on full cards, none on closed cards. Good enough
   for the first iteration.
3. **`H` keeps opening the drawer.** `?` buttons open the modal; the modal's
   Expand button goes to the drawer.
4. **Speed.** Legacy is the default and the prominent choice on the public
   site; Tactic and Flash are a de-emphasized secondary link. In-game, every
   help surface renders the loaded instance's speed, no switch.
5. **Model tiering.** Writers and code-accuracy critics on the strongest
   model, clarity critics and voters on a cheaper one.
6. **Fandom wiki.** Keep the Links sub-panel entry for now. It is not a
   source: the pipeline never cites it and the manual never defers to it.
7. **Scope.** Beta and unfinished features are out (§1). Diplomacy stays out
   even though it has code, because it is unfinished; alliances are not
   planned for the finished version either, so "unallied = other faction" is
   the permanent rule and pages say so plainly.

## 8. What the first crawl found, with verdicts

The full inventory is `docs/help-manual-inventory.md` (nine sections, one
per category: mechanics with file references, formulas with Legacy
constants, UX surfaces, cross-links, gaps). Verdicts below are from the
review of 2026-09-13.

### 8.1 Confirmed mechanics the pages must state as-is

These read as surprising and a writer might "correct" them. They are
intended behavior.

- Erased sabotage damages a Navarch's **ships** only. It never touches
  buildings.
- Only **moving** fleets are radar blips. A fleet sitting in a system is
  never detected by S.L.S.D.
- **Population defends.** For a player-owned system, defense includes
  `system_base_defense (0.15) × population` as a flat bonus. Dominions and
  neutral systems get none of it; only buildings and lexes defend them.
  Verified at `stellar_system.ex:1825-1828`. The in-game tooltip files this
  under "Initial value", which is why nobody knows (see §9).
- **Agent limits start at 0.** Nothing can be deployed until the first lex is
  bought *and* activated.
- A **failed Destabilize still costs the target 5 stability** (critical
  failure costs 0).
- **Infiltration is slowest at an even matchup** and fastest when the Erased
  is hopelessly outmatched or dominant. This is the game's strangest quirk
  and it is intentional; the page states the curve and moves on.
- **No alliances**, now or planned. "Unallied" means another faction. Pacts
  are diplomacy and out of scope.
- **Cybersecurity is a rate.** One enemy malware is removed each time a
  hidden accumulator, filled at that rate, crosses 25 000. This is the
  worst-explained mechanic in the game today, so its page is written first in
  category 7 and gets a worked example with real numbers.
- **Erased arrivals are never announced** to anyone, including faction-mates.
  The code reaches this by accident (see 8.3) but it is the intended rule,
  and the manual states it as the rule.

### 8.2 Help text that is wrong today

Fixed before the writers run (§9), otherwise the pipeline reproduces it.

- Stances: the Defender / Fury trigger lists say Navarchs react to "dominion
  takeovers". They do not; a Siderian's Control action never triggers
  interception. Navarchs **do** stop another Navarch's **conquest**. The
  strings conflated the two.
- Housing: "accommodates 1 billion people" becomes "1 population" and the
  text says it is a soft cap.
- Workforce penalty: the label "Insufficient population" describes
  over-mobilization; the text is rewritten.
- Diplomacy effects text promises visibility changes that do not exist. Out
  of scope now; noted so it is not copied later.
- Tactic duration: the locale says "4-5 days"; a Tactic match is closer to
  10 wall-hours (the Forge default). The Forge value is authoritative and
  the locale string is corrected.

### 8.3 Defects the crawl surfaced

Out of scope for the manual. Pages describe live behavior, not intended
behavior, and each defect gets a one-line "known issue" only where a player
would otherwise think the page is wrong.

- 0.001-hull "zombie" units re-enter battles alive. Confirmed.
- `Army.damage/3` applies the computed damage to every unit of a ship, not
  the remaining amount. Confirmed; the battle simulator is the tool to
  validate the fix.
- `actions/jump.ex:135` passes a struct where an integer is expected, so the
  arrival notification is suppressed for every Erased. That matches intent;
  the fix is to make the suppression explicit rather than accidental.
- `hypergate` (Singularity Ring) belongs to the faction-government beta. Not
  referenced anywhere in the manual. `happy_open` and `spatioport_open` are
  locale/icon leftovers with no content row; not documented.
- Uncertain, parked, not documented until someone decides: the three marker
  kinds with strings and no icon (`danger`, `shield`, `target`); the
  `sys_visibility` reference in `Properties.vue:104` (possibly an unfinished
  daily-challenge modifier); the unused `unit_initial_level` /
  `unit_level_growth` constants.
- Comment/code mismatches (`fight/ship.ex` level scaling) are not defects in
  themselves. Comments are not truth; the code's behavior is what the page
  documents.

### 8.4 Vocabulary the manual fixes once

Internal `doctrine` = purchased Lex, `policy` = slotted Lex. `:remarkable`
renders as "Outstanding". Two different things are called "market" (player
offer board vs faction gifting). "Bombard" and "Pillage" are `raid` and
`loot` and share one `raid_coef`. Erased actions are shown as "Infiltrate
the network", "Sabotage the fleet" and "Delete"; the bonus names say
"Removal" for the last. The glossary carries one entry per UI term with the
internal key in a footnote for people reading code.

### 8.5 Surfaces and assets

No help affordance at all today: `FactionTreeCard`, `PatentMiniPanel`,
`FactionTreeMiniPanel`, `SectorCard`, `ProductionQueueCard`, every
`box-notification/*`, `FightReport.vue` (the largest unexplained-number
surface in the game), `empire/Possessions.vue` (one `?` per column covers
most system resources at once). Faction-tree surfaces are beta and skipped.

Writers can lean on: `ShipCard.vue` (a tooltip per stat, the model for
stat-to-page mapping), `system/Details.vue` (already uses the
`<span class="info">?</span>` pattern that `help-button` generalizes),
`resource-description.*` (12 keys, the seed of the slug space), the wiki
table mix tasks (proof the catalog tables generate from content modules).
Cultures are cosmetic; traditions are fixed per faction, not chosen; both
get a page saying exactly that.

## 9. Fixes to land before category runs

Small, mechanical, and independent of the compiler. One PR.

Status: landed on this branch on 2026-09-13 (`en` and `fr`; `de` has none of
these keys). The defense tooltip reuses the existing `population` reason
and label instead of adding a new key.

| Where | Change |
| --- | --- |
| `game.json` `panel.help.stances_trigger_hostile_action`, `stances_defend_desc`, `stances_note_idle` | Remove "dominion takeover(s)" / "taking a dominion" from the trigger lists. Add one sentence to the Defender and Fury descriptions: a Navarch cannot interrupt a Siderian taking control of a dominion, but it does intercept another Navarch's conquest. |
| `game.json` `resource-description.habitation` | "Housing sets the population the system grows toward. Growth slows as population approaches housing and stops above it; population is not capped." |
| `game.json` `resource-description.workforce` | Drop "billion inhabitants". "Each point of population is one unit of workforce. Buildings mobilize workforce; mobilizing more than the system has applies a penalty." |
| `game.json` `resource-detail.misc.workforce_penalties` | "Over-mobilized population" instead of "Insufficient population". |
| Defense tooltip reason | Split the population share of defense out of "Initial value" so the tooltip reads "Population", like the credit tooltip does. Needs a distinct `reason` in `collect_initial_bonuses` (`stellar_system.ex:1847`), same pattern as `population_taxes`, plus a `resource-detail.misc.*` string. |
| `data.json` `data.speed.medium.description` | Replace "4-5 days" with the Forge default (about 10 hours). |
| `fr` locale | Mirror each of the above. |

## 10. Pipeline rules added from this review

- Writers never read `docs/faction-government.md`, `docs/armadas.md`,
  `docs/faction-buildings.md` or the diplomacy modules; the inventory
  sections for them are marked `[EXCLUDED]`.
- The code-accuracy critic cites behavior, never comments. A comment that
  disagrees with the code is reported as "intent differs" and ignored for
  the verdict.
- Combat numbers come from the battle simulator, economy numbers from real
  constructors in the Docker `rc` container.
- Intended quirks (§8.1) are written as flat statements of behavior. No
  "note that", no "surprisingly".
- Every page is compiled per speed; in-game rendering picks the instance
  speed, public pages default to Legacy.

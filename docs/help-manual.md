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
| `{rate:value\|noun}` | a rate: "2 credits per tick", or "40 credits per hour" for a reader who chose hours (value = a number or a constant key) | compiler emits both units, the surface shows one |
| `{duration:value}` | a duration: "150 ticks" or "7.5 hours" | same |
| `{amount:+20}` | a per-tick amount inside a generated table or card: "+20", or "+400/h" for a reader who chose hours, as the in-game cards show income per hour. `RC.Help.Format.bonus/3` emits it for every per-tick bonus target (production, credit, technology, ideology, upkeep), so every generated bonus table follows the unit switch | same |
| `{units:tick text\|hour text}` | a phrase in each unit, for the legends of those tables | same |
| `{shot:name#mark,mark\|Caption}` | a screenshot of real in-game UI with numbered highlight boxes (§3.5) | compiler, from `priv/help/shots/manifest.json` |
| `{chart:name args\|Caption}` | a chart drawn by running the game's own code (§3.5) | compiler (`RC.Help.Charts`), both units |
| `{advanced}` … `{/advanced}` (own lines) | a folded "Advanced mechanics" section at the end of a page (rule 19) | compiler, `<details class="help-advanced">` |
| `{card:building key}` (own paragraph) | the in-game building card: illustration, workforce, bonuses, costs, with a level selector (HTML + CSS radio pips, no script) | compiler (`RC.Help.Catalog`), per speed |
| `{facts:building key}` (own paragraph) | the Unique / Limited badge (tooltip text, link to the Buildings guide section), body type, workforce, unlocking patent, level count | same |

Frontmatter also takes `kind: guide` for a topic guide and `guide: <slug>` for a
page that belongs to one (§3.2). An alias can name a section of its page:
`aliases: [bonus-stacking#how-bonuses-add-up]` makes `[[bonus-stacking]]` link
to that heading (headings get ids from their text) with the heading as the
default label; an anchor with no matching heading is a lint error. Buildings
tables print their own level-range legend, so pages never type one. A page
that is long on purpose records `length: long` and `length_reason:` (rule
18).

### 3.2 Page types and how a category is split (revised 2026-09-13)

The first pilot wrote one page per resource line. Population, housing,
stability and workforce each held a piece of the growth rule, so a reader
had to assemble it from four pages, and each page re-explained its
neighbours. Credit, taxes and mobility overlapped the same way. The manual
now has two layers.

- **Guides** (`kind: guide`). One per big question a player asks: "How
  does my population grow?", "Where do my credits come from?". A guide tells
  the whole story once, in order, with one visual (a chart or a screenshot)
  that shows the mechanism. Each section is two to four sentences and ends
  by pointing to the page with the detail. At most ~450 words of prose. A
  guide never lists every modifier; its pages do.
- **Leaf pages** (`kind: mechanic` with `guide: <slug>`). One per thing the
  UI names: a resource line, a status, a penalty. At most ~180 words of
  prose plus tables. The compiler prints "Part of the X guide" at the top
  and lists the leaves at the bottom of the guide, so a leaf never retells
  the big picture. A leaf follows one shape, with headings only where
  needed:
  1. One or two sentences: what it is, in the UI's words.
  2. A screenshot, if the thing is visible in the UI.
  3. What it does (a short list).
  4. What changes it (generated tables).
  5. Edge cases a player would otherwise think are bugs, one sentence each.

How a category is split:

1. Before anyone writes, a planner writes the category's **guide map**:
   the guides, the leaves under each, the owner of every formula, and the
   screenshots and charts each page needs. A formula lives on exactly one
   page; every other page says "See [[that page]]."
2. A leaf belongs to exactly one guide.
3. The page a `?` button opens is the leaf for that thing, or the guide when
   the thing has no separate leaf.
4. A topic that would be a one- or two-sentence leaf is a section of its
   guide instead, with an `aliases:` entry so its slug still resolves
   (Taxes is a section of the Credit guide).
5. If a reader needs three pages to understand one number, the split is
   wrong.

Other page types:

- **Mechanic pages** outside any guide (interception, siege, cover…) are
  allowed when a topic stands alone, with the leaf length cap.
- **Catalog pages** (generated + one prose slot): one per building (47),
  patent (64), lex (61), ship (38), mutator (56), faction (5), tradition
  (20), agent skill/specialization. The page shell (name, icon, costs, bonus
  table per level, prerequisites, unlocks, "used by") is 100% generated from
  the content modules. The prose slot is one to three sentences, written by
  agents, and is allowed to be empty.

  **Building pages (built 2026-09-14).** One file per building,
  `priv/help/en/building/<key>.md`, slug `building/<key>` with the internal
  key as is (`building/hab_open`), because the in-game card's `?` already
  opens that slug. The file holds only frontmatter and the prose slot. The
  title and icon default to the building's UI name and icon. For each speed,
  `RC.Help.Catalog.body/2` wraps the prose in a generated shell:
  1. `{facts:building <key>}`: a Unique or Limited badge that stands out (the
     in-game tooltip text, and a link to the Buildings guide's section through
     the aliases `unique-buildings` / `limited-buildings` once they exist),
     then body type, workforce, the unlocking patent and the level count.
  2. The prose slot.
  3. `{card:building <key>}`: the in-game card with a level selector.
  4. "Levels": credit and production cost, what each level requires (its
     patent, including the hidden `infra_orbital_N` patents of orbital levels
     2-5, and on planets the infrastructure building at that level) and the
     effects.
  5. "Unlocking": the patent and its path from the root of the patent tree.
  6. Shipyards only, "Ships built here": the ship classes the shipyard lets
     a system build, linked to `ship-class/<class>` once the Ships category
     writes those pages or aliases.
  A building absent from a speed's content says so instead. Patents, ship
  classes and bonus targets link as soon as their page exists. The lint
  warns when a prose slot has more than 3 sentences. Hypergate (beta) and
  the `happy_open` leftover get no page.
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
| `building_levels <key>` | one building, all levels: costs, requirements, effects | building page shell |
| `building_unlock <key>` | the patent unlocking level 1 and its path from the tree's root | building page shell |
| `shipyard_ships <key>` | the ship classes a shipyard lets a system build | building page shell |
| `patent_unlocks <key>` / `unlocked_by <building|ship>` | patent → buildings/ships mapping | catalog pages |
| `ship_stats <class>` | `Data.Game.Ship` | ship class comparison |
| `constants <prefix>` | `Data.Game.Constant` fields | "All siege constants" at the bottom of a page |
| `actions <agent_type>` | action modules' metadata | Navarch / Siderian / Erased action lists |
| `population_classes` (no args) | `Data.Game.PopulationClass` | class name, population it starts at, victory points |
| `population_statuses` (no args) | `Data.Game.PopulationStatus` | status name, stability range, output penalty |

Every table is rendered per speed (Flash / Tactic / Legacy). The daily mode
uses Legacy content.

### 3.4 Style rules (the lint the reviewers enforce)

Revised 2026-09-13 after the pilot review. "(lint)" marks rules
`mix help.check` warns about.

Voice

1. Write simple, friendly sentences for a player, not a programmer. "You"
   and "your system" are fine.
2. One idea per sentence. Aim for about 15 words, never more than 25 (lint).
3. No semicolons and no dashes (— or –) joining clauses (lint). Two loosely
   related facts are two sentences, or one of them belongs on another page.
   Bad: "A system starts at 15.8 population when it is colonized; a neutral
   system starts there when the galaxy is created." Good: "A new colony
   starts with 15.8 population."
4. Point instead of half-explaining: "See [[housing]]." beats a clause that
   summarizes housing. Bad: "The housing factor turns growth negative once
   population passes housing + 0.75; the housing page explains how it
   behaves." Good: "Above its housing, a system shrinks. See [[housing]]."
5. The first sentence of a page says what the thing is. No preamble.
6. UI names only: Navarch, Siderian, Erased, Intelligence, Cybersecurity,
   Lex, S.L.S.D. Never `admiral`, `spy`, `speaker`, `doctrine`, `sys_ci`
   (lint).
7. No adjectives of quality ("powerful", "crucial"). No advice ("you
   should") (lint).

Show, don't describe

8. Never describe in words where something is on screen or what a UI
   element looks like. Show it with `{shot:}` and a highlight box, then
   refer to "the highlighted readout". At most one caption sentence. Bad:
   "The system view's Population box holds the population growth bar. Below
   the bar, a separate readout shows workforce as mobilized/total."
9. Simple formulas are one example line in words and numbers: "100
   population × 2 = 200 credits per tick". Complex formulas (several
   factors, caps or thresholds; population growth is the model case) get a
   `{chart:}` of likely scenarios, one plain sentence per factor, and the
   exact formula last, in an indented block, for players who want it.
10. More than three rows of numbers is a generated table (`{table:}`), never
    typed. Prose never restates a table row. Sign words ("negative", "below
    zero") are plain language, not constants.

Numbers and time

11. Every number that exists in code is a `{const:}`, `{rate:}` or
    `{duration:}` token, or lives in a generated table or chart. A literal
    hard-coded in game code may be written as a number only with its code
    line in `sources:`.
12. Time is ticks or hours, never days, weeks or months. Every rate is a
    `{rate:}` and every duration a `{duration:}`, so the reader sees "per
    tick" or "per hour" by their own choice (lint flags typed "per tick",
    "150 ticks", "per day"). The in-game calendar is flavor. Only the
    `game-time` page mentions it, and that page explains speeds, ticks,
    hours and the calendar. In an example equation, every per-tick factor
    is a `{rate:}` too, so both sides convert: "15 workforce ×
    {rate:system_population_taxes_factor|credits} = {rate:30|credits}".
    A plain "15 × 2 = {rate:30|credits}" reads "15 × 2 = 600 credits per
    hour" for a reader who chose hours. The same holds inside indented
    formula blocks: every term that is an amount per tick is a `{rate:}`
    ("growth = {rate:-0.002|population}", "base = {rate:system_base_growth|population}"),
    and dimensionless factors (housing factor, size factor) stay plain.
    Never write "per tick" or "of one tick" around a formula.
13. Numbers and tables always show the speed they belong to. In-game, that
    is the loaded instance's speed. On the public site, Legacy.

Accuracy

14. When the code has an edge case a player would otherwise think is a bug
    (a failed Destabilize still costs 5 stability, Deserter arrivers escape
    on a flat 50 % roll), say it in one sentence. Intentional quirks are
    documented as behavior, not apologized for. Other edge cases stay out.
15. Population is counted in points ("1 population"), never "1 billion
    people". Housing is a growth target, not a cap: population grows toward
    housing + 0.75, slows as it gets close, and shrinks back toward it from
    above (faster at higher stability). Decided 2026-09-13: the shrinking is
    intended.
16. Code comments are not evidence. A claim is true if the code does it;
    comments at best explain intent and are cited only as intent.
17. Every other mechanic named in the prose is a `[[link]]` the first time
    it appears.

Length

18. Length is a signal, not a hard limit (revised 2026-09-14). Guides aim
    for about 450 words of prose, leaves and standalone mechanic pages for
    about 180; the lint warns above that. Tables, charts, screenshots and
    indented formula blocks do not count. The numbers are heuristics (about
    a minute of reading for a leaf, about one scroll of the in-game help
    window), not measured limits. A catalog prose slot is at most 3
    sentences.
    - Never cut a fact, a link or the meaning of a sentence to get under the
      number. A clear page that runs a little long beats a cryptic page that
      fits. Squeezed sentences break rules 1-4.
    - When a page runs over, first ask why. If it explains something another
      page owns, link to that page. If it has grown a second topic, split
      it: a new leaf, or a small guide with leaves. Critics report this as
      must_fix.
    - If the page's own topic simply has that many facts, it may stay long.
      Critics report its length only as nice_to_have.
    - A page that stays over on purpose records it in the frontmatter:
      `length: long` and `length_reason: <one line on why>`. The lint stops
      warning, and the reason stays visible to the next reviewer. `length:
      long` without a reason still warns.

Advanced mechanics

19. A page may end with one folded **Advanced mechanics** section, written
    between an `{advanced}` line and a `{/advanced}` line. It renders closed
    by default, is searchable, and does not count toward the length target.
    It is a rare tool (added 2026-09-14):
    - Use it only for a hidden layer most players never need to act on but
      some ask about: how the game's AI decides (self-development's
      specialties and build choices), hidden rolls, or the full formula
      behind a rule the page already states simply.
    - The page above it must stand on its own. A player who never opens the
      section still understands the mechanic and can play with it.
    - It is not for mechanics that are merely numerous or interconnected.
      Those are not advanced, the game just has a lot of rules: give them
      more pages (rule 18: split into leaves, or a small guide).
    - It is planned, not improvised. The planner proposes it in the guide
      map with a one-line reason, and the human approves it with the map.
      Writers and revisers never add one on their own, and critics report an
      unplanned section as must_fix.
    - It follows every other rule: plain sentences, tokens for numbers,
      runs the code for its claims, no excluded scope.

### 3.5 Visuals and units

**Screenshots** (`{shot:}`) are real in-game UI, captured by a script so
they can be recaptured whenever the UI changes.

- Recipes live in `e2e/help-shots/shots.json`: a scene, the CSS selector of
  the element to capture, and named marks (selectors of the parts to
  highlight), plus alt text.
- `node e2e/help-shots/capture.js [name …]` (Playwright, host-side, against
  the worktree's stack; see `e2e/help-shots/README.md`) writes
  `assets/static/img/help/shots/<name>.png`, served at `/img/help/shots/`,
  and merges `priv/help/shots/manifest.json` with each mark as fractions of
  the image.
- A page writes `{shot:system-population#workforce}` or
  `{shot:system-population#housing,stability|Caption}`. The compiler draws
  one box per mark over the image, numbered when there are several, so one
  image serves many pages. An unknown shot or mark is a lint error.
- Marks record the element's exact bounds. The surfaces draw the visible
  box a few pixels outside them (a margin set in CSS, `.help-shot-mark::before`),
  so the outline never touches the highlighted text, and put the number
  badge outside the box's top-left corner. Capture recipes therefore never
  pad marks themselves.
- Scenes today: `own-system` (a fresh daily, the player's own system).
  States a fresh daily cannot show (an unstable system's status bar, a
  Mobility line in the credit tooltip) need a new scene before a page can
  use them.

**Charts** (`{chart:}`) are SVG drawn at compile time by `RC.Help.Charts`,
which runs the game's own functions. Population growth calls
`StellarSystem.population_growth/4`, extracted from the tick code so the
game and the manual share it. A chart shows a few likely scenarios, not
every parameter, and its caption says what varies. A chart needs a
developer-written generator. A writer who wants one asks for it in the
guide map.

**Units.** Rates, durations and chart time axes are compiled in both
units (`help-unit-tick` / `help-unit-hour`), and the surface shows one. The
public site has a "Per tick | Per hour" switch in the header of every page
(pages without rates included, so the choice is always reachable). The unit
lives in the URL (`?unit=hour`, kept across links) and the browser
remembers it for the next visit. In-game, the manual follows the player's existing
"income per tick / per hour" account setting (`incomePerHour`), at every
speed. Screenshots show the UI as captured and are not converted.

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
way `EmpirePanel.open({ tab })` works for Quick calc's expand button. The
Hotkeys, Legend and Stances tabs stay as they are for everyone while the
Manual is in beta. Their text is already single-sourced: the manual pages
`hotkeys`, `map-legend` and `stances` pull the same `panel.help.*` strings
through `{ui:}` tokens, so a wording fix lands in both places. When the beta
graduates, the three Vue tabs become thin wrappers around those pages. The
panel navbar has no per-tab icons today (grey squares); adding one for
Manual is new CSS.

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
| 2 | Buildings (queue, tiles, costs) | 4 mechanic + 45 catalog |
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

### 5.2 Per-category workflow (v3, 2026-09-13)

Pilot 1 ran the original design below on seven Systems pages and parked
every page (122 agents, 10.8M tokens). Voters who saw the critics'
findings repeated them. The clarity critic never ran out of findings.
"Missing" findings grew pages past the cap. Late revisions made pages
worse, and overlapping briefs duplicated formulas. The pilot's human review
added the guide/leaf split (§3.2), visuals (§3.5) and the revised style
rules (§3.4). v3:

```
phase 0  Plan         1 planner: refresh the inventory slice, write the guide map (§3.2): guides, leaves,
                      formula owners, the screenshots (existing manifest entries or new recipes) and charts each
                      page needs. On a category's first run a human approves the map before phase 1.
phase 1  Write        1 writer per guide (the guide and its leaves together).
phase 1b Capture      1 agent adds any new shot recipes and runs e2e/help-shots/capture.js.
phase 2  Verify       per page, in parallel:
                        2a accuracy critic (runs code). Findings are must_fix (wrong behavior or number, excluded
                           scope, an item the guide map assigns to the page is absent or wrong) or nice_to_have.
                           A re-review checks the diff against the previous round's snapshot.
                        2b clarity critic. must_fix = an unambiguous style-rule violation (quote + rule number),
                           a topic the guide map gives to another page, or a page over its length cap because
                           it covers a second topic (rule 18). Length alone is nice_to_have, and a page with
                           `length: long` and a reason is not flagged. Never ask to cut meaning to fit.
                           At most 3 nice_to_have.
                        2c 2 blind voters read only the page as a player sees it and score clarity 1-5 on a fixed
                           scale. They never see the critics' findings.
phase 3  Decide       accept when neither critic has a must_fix and mean voter clarity >= 3.5. Otherwise a
                      reviser snapshots the page, fixes or rebuts each must_fix, applies nice_to_have only within
                      the cap and the guide map, and the page returns to phase 2. At most 2 revisions. A parked
                      page keeps its best-scoring round.
phase 4  Consistency  1 critic reads the guide map's pages together: contradictions, duplicates, owner breaks.
phase 5  Record       review records, backlog.md of deferred nice_to_have items, rc restart, lint.
```

Lessons from the Buildings run (2026-09-14; 40 + 64 agents, records in
`docs/help-review/buildings*`):

- **Restore-best can bring a fixed bug back.** The record step restores a
  parked page to its lowest-scoring round. That round's text can still hold
  a must_fix that a later revision fixed (production came back with "Your
  Your capital"). Read every restored page before closing the run.
- **Link-only edits need a light review.** The linking plan's pages got one
  link critic each (links resolve, labels read well, nothing else changed).
  Pages with content changes got the full review.
- **The last consistency findings are cheaper by hand.** A consistency pass
  after the revisions still found nine small cross-page issues. Applying
  them by hand, then one accuracy verifier (runs code) and one clarity
  verifier over the diffs, cost two agents instead of a third run.
- **Check the in-game surface too.** The public site passing is not enough.
  An in-game check found non-reactive settings, missing list markers and
  empty `<p>` wrappers around blocks that the public site hid.
- **A new page needs a recompile.** `RC.Help` recompiles when the set of
  page files changes (`__mix_recompile__?`). Before that fix, a restart kept
  serving the old manual.

Original design (pilot 1, superseded):

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

Each run writes its record to `docs/help-review/<category>/<slug>.json`
(findings, votes, revisions, rebuttals) so the PR shows why a page was
accepted; parked pages are listed in `docs/help-review/parked.md`.

Agents lint and read pages with `mix help.check --live`, which builds the
manual from disk at run time instead of compiling. Invoked through
`mix run --no-compile --no-deps-check --no-start -e
'Mix.Tasks.Help.Check.run(System.argv())' -- --live --only <slugs>` it never
touches `_build`, so a dozen critics can run it at once while writers edit
pages. Number checks use the same `mix run --no-compile --no-start` form on
throwaway scripts in the gitignored `tmp/help-review/`.

**No page is ever "finished" for the pipeline.** `status:` in the frontmatter
is a record, not a lock: `draft` means nobody has verified it, `reviewed`
means it passed phase 3 once. Writers rewrite every page in their category,
including hand-written seeds (the first five system pages, the ported
`hotkeys`, `map-legend` and `stances` pages), and the seam pass may revise
any page at all. Any edit puts a page back through phase 2. If a page must
not be touched by agents, that needs an explicit `locked: true` field, which
does not exist yet and should stay rare.

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
| B | Public `/help` pages + icon sprite script. **Landed 2026-09-13**: `Portal.HelpLive` (`/help`, `/help/:slug`, `?speed=`, `?lang=`, `?q=` search that also works without JS), `assets/css/views/_help.scss`, "Manual" nav link, sprite built by `npm run help-icons --prefix assets` from `front/src/icons` into `assets/static/img/help-icons.svg` (committed; `build-front.sh` regenerates it), `test/portal/live/help_live_test.exs`. The drawer's Legend / Stances / Hotkeys content was ported as `map-legend`, `stances`, `hotkeys` (sharing the panels' strings via `{ui:}`); the legend's drawn map chips stay in the Vue panel until an image token exists. | A |
| C | `GET /api/help/:lang`, `HelpOverlay.vue`, `help-button`, Manual tab in the drawer, `?help=` deep link, `?` buttons on `ResourceDetail` and the 5 main cards. Behind the beta-feature flag `help_manual` using the existing 4-touchpoint gating recipe. **Landed 2026-09-13**: `Portal.HelpController` (public, ETag), Vuex module `front/src/game/help/store.js` (lazy bundle per lang × instance speed; dailies read Legacy), `front/src/game/help/render.js` (icon markers → inline svg from the vue-svgicon registry; plain-node tests), `HelpOverlay.vue` (history, Expand, Copy link), `panel/help/Manual.vue` (search, TOC, glossary, page view; default tab when the beta is on), `HelpButton.vue` (renders only when the page exists; `fallback` keeps the old tooltip). Slugs wired: resource lines (`population`, `housing`, `stability`, `production`, `credit`, `technology`, `ideology`, `mobility`, `slsd`, `intelligence`, `cybersecurity`), cards (`building/<key>`, `patent/<key>`, `lex/<key>`, `ship/<key>`, `agent/<type>`). Resource breakdowns that carry a `?` use `generic/HoverPopover.vue` instead of v-tooltip's hover trigger: the popover lingers 350 ms after the pointer leaves, stays while hovered, and a click on the trigger pins it (click again, click outside, Esc, or opening a page unpins). Same grace-and-pin idea as the side cards' `HoverCardMixin`. | A |
| D | Category workflows 1–11 (§5.2). Start with Systems and Buildings, since Mobility-style pages exercise every token and table type. Cybersecurity is the first page in category 7. | 0, A |
| E | Cross-category pass (§5.3), glossary, search index. | D |
| F | Human read-through, drop the beta flag, announce. | E |
| G | Remaining `?` placements, fr prose. | F |

A and D can start in parallel: the writers only need the token syntax agreed,
not the compiler finished, and the lint catches mismatches later.

## 7. Decisions (resolved 2026-09-13)

1. **Slug policy.** Kebab-case English; catalog pages prefixed by type with
   the internal key as the stable part, written as the key is
   (`building/hab_open`, `patent/citadel`), since the in-game `?` buttons
   open `<type>/<key>`. Renames add an `aliases:` entry that compiles to a
   redirect.
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

Systems & Dominions verdicts (2026-09-13, guide map
`docs/help-review/systems/guide-map-rest.md` Q1-Q10):

- **The capital is lost for good.** Liberating, abandoning or losing the
  capital clears the flag and no other system becomes the capital, so its
  base production drops to that of any system.
- **Faction-mates:** whatever the code allows against a faction-mate's
  system or dominion is existing behavior (Siderian actions against a
  mate's dominion certainly work). Pages state what the code does, without
  calling it surprising.
- **Pillaging a dominion** takes the dominion's full output (times the
  pillage multiplier) from its owner, although the owner only receives a
  share of that output.
- **A dominion with negative output lowers its owner's income**, with no
  floor.
- **Abandoning keeps everything:** buildings, population and the system's
  development profile stay, so a player can build a system up, abandon it
  and take it back as a dominion.
- **Bonus stacking** is documented exactly as the code computes it today;
  the human reviews later whether that is the intended formula. Verified by
  running `Core.Bonus.apply_bonuses` (2026-09-13):
  - One resource: (base + every flat bonus) × (1 + the sum of its
    percentage bonuses). Percentages add up, they do not compound: a
    building +10 and a flat Lex +20 give 30 mobility, plus a 10 % Lex 33,
    plus another 20 % Lex 39.
  - A bonus that turns one resource into another reads the value from before
    that resource's percentages: with 30 mobility and a 10 % Lex (33 shown),
    the Mobility credit bonus still counts 30.
  - Unless a flat conversion runs between them: a building giving +2 credits
    per mobility reads 33, and the Mobility credit bonus after it also reads
    33 (credits 20 + 66 + 33 = 119).
- **Pillage yield after an attack** (changed on master by #131,
  2026-09-14): a successful conquest, bombardment or pillage lowers it by
  `raid_potential_impact`; a failed one, or a besieging Navarch that dies or
  flees before the attack resolves, lowers it by the smaller
  `raid_potential_failure_impact`. It was a known issue before; pages state
  the new rule and no longer carry the known-issue line.

Buildings verdicts (2026-09-14, guide map `docs/help-review/buildings/guide-map.md` Q1-Q8):

- **A construction queue outlives its owner.** After a conquest, Liberate or Abandon, the system's queued
  orders keep building for the new holder, nothing is refunded, and the old owner can no longer cancel
  them.
- **The time on a building card is that building's own build time** at the system's current production.
  It does not count other orders. Players work out the rest of their queue themselves.
- **Upgrading a damaged building is refused.** Repair it first. (Fixed 2026-09-14: the server used to
  accept and charge such an upgrade, which never happened.)
- **Siege targeting follows a content tag**, not a building's defense output: the buildings tagged
  `defense`, some of which make no defense, are twice as likely to be hit. Pages list them from content.
- **Content that looks odd is intended:** some higher levels cost less production than lower ones, and
  the Flash and Tactic patent trees are arranged differently from Legacy's.

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

## 11. Pilot review (2026-09-13)

Human feedback on the first seven Systems pages, and what changed:

1. **Too much text describing UI.** A paragraph explaining where a readout
   sits and what its tooltip lists is replaced by a screenshot with a
   highlight box (§3.5, rule 8).
2. **Long, stitched sentences.** Semicolons and dashes joined loosely
   related facts. Rules 1-4 ask for short, friendly sentences and "See
   [[page]]" instead of half-explanations. The lint flags semicolons,
   dashes and sentences over 25 words.
3. **Confusing time units.** "−0.002 per day" read as a real day. Players
   only ever think in ticks and hours. Every rate and duration is a token
   shown per tick or per hour by the reader's choice, the in-game calendar
   is flavor, and one `game-time` page explains speeds, ticks, hours and
   the calendar (rule 12, §3.5).
4. **Complex formulas are hard to picture.** Simple formulas stay one
   example line. Complex ones get a chart of likely scenarios generated
   from the game's code (rule 9, §3.5).
5. **Mushy, overlapping pages.** Credit, Taxes, Mobility, Workforce and
   Population were hard to navigate and overlapped. Categories are now
   split into guides that tell one story and short leaves that point back
   to them, planned up front in a guide map (§3.2).

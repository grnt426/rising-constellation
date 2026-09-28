# Buildings: guide map

Planner output, phase 0 (docs/help-manual.md §3.2, §5.2 v3). Written 2026-09-14 against the worktree
branch `claude/buildings-user-manual-e80fb8` (commit 4d092fd). Legacy values unless a speed is named. Line
references are to that commit. Every rule marked "verified" was run in the Docker `rc` container against
Legacy content (`tmp/help-review/buildings-plan-verify.exs`, `buildings-plan-data.exs`,
`buildings-plan-bonus.exs`).

## Human answers (2026-09-14, override the open questions in section 1)

- **Q1:** upgrading a damaged building is a bug, fixed in code on this branch (D9): the server refuses the
  order. Pages state it as a rule: a damaged building must be repaired before it can be upgraded.
- **Q2:** default accepted. The catalog shell prints the siege line on the buildings tagged `defense`, and
  the siege page gets `{table:buildings_by_tag defense}` in the linking run.
- **Q3:** intended. A construction queue keeps running after a conquest, Liberate or Abandon.
  `construction-queue` states it as behavior.
- **Q4:** default accepted. The Buildings guide owns the table of what other players' tiles show. "System
  visibility" stays plain text; it becomes a link once the Erased batch writes the System Visibility page.
- **Q5:** four mechanic pages approved.
- **Q6:** the three cross-chapter catalog slots are kept.
- **Q7:** the time on a building card is, by design, the time to build that building alone at the system's
  current production. Players account for the rest of their queue themselves. `construction-queue` says what
  the time counts in one plain sentence, never as a flaw. D7: only the `card.cost.production` tooltip is
  rewritten (the other D7 strings were not reviewed).
- **Q8:** intended content, including the Flash and Tactic patent trees arranged differently from Legacy.
  Pages show the content as it is, with no remark.

## Decisions already made (do not re-open)

- **Catalog pages:** one per building, slug `building/<key>` with the internal key and underscores
  (`building/hab_open`), file `priv/help/en/building/<key>.md`, `kind: catalog`. The `?` on `BuildingCard.vue:15`
  already opens that slug. The compiler generates the shell: Unique/Limited badge with the in-game tooltip,
  an HTML card with a level selector, every level's costs and effects, the body type, the patent and its
  chain to the root, per-level requirements, and the ship class for the four shipyards. Each page has a
  prose slot of 0 to 3 sentences, most of them empty.
- **Mechanic pages:** a basic Buildings page that owns a section on Unique and Limited buildings, with
  `aliases:` the badge links to, plus whatever leaves the mechanics need.
- **Excluded:** faction buildings and stations, armadas, gateways and `hypergate`, government, diplomacy,
  beta flags. `happy_open` has no content row and gets no page.

---

## 1. Summary for approval

### Guide tree

New pages, 1 guide + 3 leaves = 4 mechanic pages (directory `priv/help/en/buildings/`):

```
buildings/buildings            GUIDE  What a building is, where it goes, infrastructure first, ordering (patent, credit),
                                      Unique and Limited buildings, destroying, other players' buildings, list of all buildings
  buildings/construction-queue leaf   The system's one queue: order of work, one order per tile, time estimates,
                                      cancelling and refunds, what happens to the queue when the system changes hands
  buildings/upgrades           leaf   One level at a time, what each level needs (infrastructure patents, the
                                      infrastructure level cap on planets, orbital upgrade patents), Flash has no upgrades
  buildings/damaged-buildings  leaf   What a damaged building still does and does not do, repair cost and time,
                                      cancelling a repair
```

The doc's estimate was 7 mechanic pages. The other candidates are one to four sentences each, so by rule
3.2.4 they are sections of the guide with an alias: infrastructure prerequisite, ordering and costs, the
patent gate, Unique and Limited, destroying (UI word "Destroy", `card.building.delete`), other players'
buildings. Already owned elsewhere, linked only: production feeding the queue (`production`), which
buildings a siege damages (`siege`), tile 1 being the infrastructure tile (`stellar-bodies`), workforce
(`workforce`), local population (`housing`), how bonuses stack (`system-outputs`, `defense`, `mobility`).

### Catalog plan

45 catalog pages: every building whose biome is a real body type (`open`, `dome`, `orbital`). Legacy and
Tactic have the same 45 keys with 5 levels each. Flash has 33 of them, with 1 level each. `hypergate`
(biome `:gate`) and `happy_open` get no page. The shell carries everything that differs per level or per
speed. 11 prose slots are non-empty (section 4): the two infrastructure buildings, the four shipyards, the
Monolith, the Metamaterials Factory, the Floating Gardens, and the two mobility-to-credit buildings. The
other 34 stay empty. If Q2 is answered "no shell line", up to 11 more one-sentence slots are added for the
siege weighting.

### A developer builds first

1. **Table generators** D1 `buildings_list`, D2 `upgrade_patents`, D3 `buildings_by_tag`. They block the
   guide, `upgrades` and the siege-page fix. Writers can use the tokens before they exist, but critics
   need them to compile.
2. **Shell details** D4: the per-level requirement rules in section 5, the siege-weight line (Q2), links
   from each bonus input to its owning page, and "not in this speed" handling for Flash.
3. **Fixture option `buildings`** on the `empire` capture scene (D5) and recipes R1-R4 (D6). The pages can
   be written without the shots and get them in a second pass, as the Systems run did.
4. **Locale fixes** D7 (the production cost tooltip says "Industry" and implies the time is exact).
5. **Doc fixes** D8 (§7.1 still says kebab-case catalog slugs).
6. **Bug ticket** D9 (Q1), not manual content.

### Open questions

- **Q1 Upgrading a damaged building (defect).** The server accepts it. `order_building_production` never
  checks `building_status` on the upgrade branch (`stellar_system.ex:381-392`). `Tile.plan_building` has no
  clause for a damaged tile and returns it unchanged (`tile.ex:45-52`). So the credits are charged, the
  order sits in the queue, and a second identical order is also accepted (verified: queue 2). When it
  finishes, `Tile.put_building` again has no matching clause (`tile.ex:69-80`), so the level never changes
  and the credits and production are lost. The UI hides the upgrade button on a damaged tile
  (`BodiesItem.vue:61-76`, `v-if` repair, `v-else-if` upgrade), so only a crafted client reaches it.
  **Default:** `upgrades` and `damaged-buildings` say "Repair a damaged building before you can upgrade
  it", which is true for every player, and D9 files a bug so the server refuses the order.
- **Q2 Siege target weighting on the catalog shell.** A siege hit picks a building twice as often when
  its content `outputs` list contains `:defense` (`stellar_system.ex:1712`). That is not "makes defense":
  the Aerospace Military Academy, S.L.S.D. Network, Orb-INTEL, Convention Center and Integrated Proxy
  Systems make no defense but are weighted, 11 buildings at Legacy and Tactic, 9 at Flash (verified).
  `siege.md` today says "A [[defense]] building is twice as likely", which sends readers to a defense table
  that omits five of them. **Default:** the siege page lists them with D3 `{table:buildings_by_tag defense}`
  (linking plan), and the shell prints one generated line "A siege is twice as likely to damage it" on
  those 11 pages. If no shell line, the 11 slots get that sentence instead.
- **Q3 The queue stays when a system changes hands.** `claim/4` and `abandon/1` never touch `state.queue`
  (`stellar_system.ex:235-283`). Cancelling needs the system to be yours (`player/agent.ex:423`,
  `player.ex:770-772`). So after a conquest, Liberate or Abandon, the old orders keep building for the new
  holder, their credits are not refunded, and the old owner can no longer cancel them. Intended?
  **Default:** state it as behavior, one sentence in `construction-queue`.
- **Q4 Who owns "what you see of another player's buildings".** Tiles are filtered by visibility level
  (`tile.ex:132-149`, `faction/stellar_system.ex:83-87`, `:168-171`). Visibility itself belongs to the
  Galaxy chapter, which has no page yet. **Default:** the Buildings guide owns the four-row table of what
  tiles show at each level (the thresholds are code literals, cited in `sources:`). The future Galaxy
  visibility page links to it.
- **Q5 Four mechanic pages instead of seven.** See the guide tree. **Default:** approve.
- **Q6 Catalog slots that point into other chapters.** Three slot themes come from outside Buildings:
  the "galaxy's first" news bulletin for the Monolith and the Metamaterials Factory
  (`stellar_system.ex:1182-1195`, `news/server.ex:215-216`), the Monumental daily race for the Floating
  Gardens (`stellar_system.ex:1197-1203`, `lib/daily/objective.ex:159-173`), and the Mobility credit bonus
  counting mobility percentages when a Reflect District, Business Arch or Monolith stands
  (`mobility.md:30`, `bonus.ex:38-87`). **Default:** keep them, one sentence each, with plain text for
  chapters that have no page yet.
- **Q7 The time on a building card.** It is that level's production cost ÷ the system's current
  production, converted to real time (`BuildingCard.vue:114-116`, `store.js:204-206`). It ignores every
  item already in the queue. The tooltip `card.cost.production` says "The time shown is the estimate at
  current output" and calls production "Industry". **Default:** `construction-queue` states it in one
  sentence, and D7 rewrites the tooltip.
- **Q8 (FYI, data, not blocking).** Content oddities the shell will show as they are:
  - Some higher levels cost less production than lower ones: Legacy Orbital Link L1 4 000 → L2 2 820;
    Tactic Convention Center L1 10 000 → L2 360, Array of Excavators 200 → 160.
  - Flash patent chains look shuffled: the Central Hub needs Urbanization (`infra_open_1`), the
    Constellation of Lures needs `dome_happiness`.
  - Tactic's Integrated Proxy Systems needs `dome_academy`, Legacy's needs `dome_defense_1`.
  **Default:** document as the content says. Report to balance if unintended.

### Advanced mechanics (rule 19)

None. Nothing in this category is a hidden roll or an AI decision. The siege weighting is a table, and the
time estimate is one example line.

---

## 2. Refreshed facts

Line numbers at 4d092fd. "Inventory" means `docs/help-manual-inventory.md` §A.2.

| Rule | Code | Verified | Differs from the inventory |
| --- | --- | --- | --- |
| Order entry: dry-run the player check, then the system order, then debit | `player/agent.ex:343-364` | code | inventory said `:336` |
| Player check: level exists, credit cost (build = level credit, repair = round(credit × factor)), bankrupt refused, credit must be ≥ cost, patent of that level checked for "build" only | `player.ex:351-398` | run: exactly 1 500 credits orders a 1 500 building; 1 499 refused; bankrupt refused; repair needs no patent | none |
| Repair price comes from the building actually on the tile, not the client payload | `player/agent.ex:1428-1450` | code | new |
| System check order: building exists at this speed, siege, biome, level exists, tile exists, tile not under construction | `stellar_system.ex:347-370` | run | inventory said `:333` |
| Infrastructure tile takes only infrastructure buildings; normal tiles never take them | `stellar_system.ex:371-376`, `tile.ex:20-34` | run: `:wrong_building_type` | none |
| Other tiles of a planet need tile 1 **finished**; a queued infrastructure building does not count (planning keeps `building_status: :empty`, `tile.ex:41-42`); moons and asteroids need none | `stellar_system.ex:378-380` | run: queued infra → `:no_building_without_infra`; moon order ok | inventory said "occupied" |
| Upgrade: same building, exactly the next level, no downgrade, not the same level | `stellar_system.ex:381-385` | run | none |
| Infrastructure cap: on a planet, a non-infrastructure building's new level must be ≤ tile 1's current level; an infrastructure upgrade still in progress does not count; moons and asteroids exempt; the infrastructure building itself exempt | `stellar_system.ex:387-391` | run | in-progress detail new |
| Per-level patent: L1 = the sheet's patent; infrastructure buildings L2-5 = their own `infra_open_N` / `infra_dome_N`; orbital buildings L2-5 = hidden `infra_orbital_N`; other buildings L2-5 = none | `lib/data/game/building.ex:72-80`, `player.ex:382-387` | run: orbital L2 without `infra_orbital_2` refused; Megapolis L2 without Urbanization II refused; Floating Gardens L2 with no patent accepted | inventory said `:64-76` |
| Hidden patents are left out of the patent's `unlock` list, so `infra_orbital_2..5` unlock nothing on their own cards | `lib/data/game/patent.ex:56-62` | data dump | none |
| Uniqueness checked only when ordering level 1. `unique_body` = the tile's own body (planet, moon or asteroid); `unique_system` = every body in the system. Queued and damaged copies count | `stellar_system.ex:394-415` | run: queued, damaged and other-moon copies all refused; upgrading one of two copies accepted | queued/damaged detail new |
| Queue: items appended with id = last + 1; any item can be removed; production goes to the head item | `production_queue.ex:18-23`, `:25-42`, `:54-68` | run | none |
| An item whose remaining production equals the tick's production stays at 0 and finishes on the next tick; overflow carries | `production_item.ex:34-40` | run: 30 into a 30 item leaves 0; 50 into a 30 item finishes with 20 left | new detail, not player-facing |
| Tick: production × elapsed time; building and repair leftovers carry, ship leftovers are dropped | `stellar_system.ex:1018-1020`, `:1140-1216` | code (owned by `production`) | inventory said `:1005`, `:1126` |
| Completion: tile becomes built / level + 1, notification sound, bonuses recomputed | `tile.ex:69-74`, `stellar_system.ex:1205-1209` | code | none |
| Bonuses come only from `:built` tiles: a damaged building gives none; an upgrading building keeps its old level's bonuses | `stellar_system.ex:1300-1320`, `:1620-1631` | code | new |
| Workforce counts built and damaged tiles | `stellar_system.ex:1532-1547` | code (owned by `workforce`) | none |
| Time shown on a card = level production ÷ system production × seconds per tick | `BuildingCard.vue:106-124`, `store.js:204-206` | code | inventory cited `production_queue.ex:81-88`, which is server tick scheduling |
| Queue list: each item's finish time counts every item before it, at current production; hidden in Flash games | `Production.vue:178-187`, `ClosedProductionCard.vue:38-42` | code | new |
| Production box: first item's countdown and progress ring | `ProductionBox.vue:28-64` | code | new |
| Cancel: refused under siege; building or upgrade refunds the level's full credit; repair refunds round(credit × factor); production already spent is not returned; tile goes back to empty or its old level | `stellar_system.ex:604-649`, `stellar_system/agent.ex:61-86`, `player/agent.ex:421-449` | run: 1 950 refunded after 10 of 30 production spent; repair cancel refunds 7 500 | inventory said `:590-638`; repair refund and lost production new |
| Cancel needs the system to be yours | `player/agent.ex:423`, `player.ex:770-772` | code | new (Q3) |
| Destroy: refused under siege, refused while the tile is being built, upgraded or repaired, refused for infrastructure; instant, no refund; a damaged building can be destroyed | `stellar_system.ex:561-591`, `tile.ex:83-90`, `player/agent.ex:389-402` | run (the damaged case passes every check; the sim state then lacks fields for `compute_bonus`) | inventory said `:547-575` |
| Repair: refused under siege, refused during construction, only for damaged buildings; production = round(level production × `building_repairs_factor`) | `stellar_system.ex:508-559`, `constant-slow.ex:19` (0.5 at every speed) | run: Floating Gardens L1 repair = 600 production, 7 500 credits | inventory said `:494-545` |
| Siege damage: picks among built, non-infrastructure tiles that are idle or upgrading; `:defense` in `outputs` doubles the weight; an upgrade hit is cancelled and its credit refunded | `stellar_system.ex:1671-1764` | code + data dump (owned by `siege`) | weight comes from `outputs`, not bonuses (Q2) |
| Siege locks: order and repair `:no_production_under_siege`; destroy and cancel `:no_removal_under_siege`; ships `:455` | `stellar_system.ex:361`, `:512`, `:568`, `:606`, `:455` | run | none |
| Shipyard gate: the ship's `shipyard` must be `:built` in the system. Queued or damaged: refused. Upgrading: allowed. Transports have none. Queued ships finish even if the shipyard is later damaged or destroyed (no check at completion) | `stellar_system.ex:449-473`, `:1144-1171`, `:561-591` | run | upgrading and queued-ship details new |
| Other players' tiles by visibility: 0 no bodies; 1 tiles all hidden; 2-3 which tiles are built or damaged; 4 also which building; 5 everything, including level and construction | `faction/stellar_system.ex:83-87`, `:140-171`, `tile.ex:132-149`, `BodiesItem.vue:151-173` | code | inventory said "below contact level 5" |
| Own agent in a system gives visibility ≥ 2; your own faction's systems give 5 | `faction/faction.ex:169-183` | code | new |
| A system that changes hands keeps its queue | `stellar_system.ex:235-283` | code | new (Q3) |
| Speeds: Legacy and Tactic 45 body buildings + `hypergate`; Flash 33, one level each; missing keys refused cleanly | `building-slow.ex`, `building-medium.ex`, `building-fast.ex`, `player.ex:365`, `stellar_system.ex:358` | data dump | inventory said "fast = 33 keys"; one-level detail new |
| A new colony or capital gets a level 1 infrastructure building | `stellar_system.ex:1410-1439` | code (owned by `colonization`) | none |
| "Galaxy's first" news bulletin for the Monolith and Metamaterials Factory, shown to every player | `stellar_system.ex:1182-1195`, `news/server.ex:215-216`, `:258-270`, `portal.json:113-117`, `store.js:578-593` | code | new |
| Monumental daily race is won by finishing a Floating Gardens | `stellar_system.ex:1197-1203`, `lib/daily/objective.ex:159-173` | code | new |
| Build menu gating shown to the player: patent of level 1, Limited/Unique already used | `Production.vue:188-218` | code | none |
| Upgrade button rules in the UI | `utils/buildingValidation.js:2-29`, `BodiesItem.vue:209-232` | code | none |

Flash buildings missing (12): `mine_orbital`, `hab_open`, `factory_open`, `lift_dome`, `research_dome`,
`ideo_dome`, `monument_open`, `market_dome`, `finance_orbital`, `happy_orbital`, `removecontact_open`,
`removecontact_dome`.

---

## 3. Detailed briefs

Common rules for every writer: docs/help-manual.md §3.2 (guide about 450 words, leaf about 180), §3.4
style, §3.5 visuals. A page OWNS only what its brief lists. Everything else is one sentence plus
`See [[page]]`, or plain text when the target page does not exist yet (Ships, Navarchs, Erased, Galaxy,
Patents, Game modes). Use the UI's words: "Destroy" (not demolish, except as an alias and term),
"Upgrade", "Repair", "Construction queue", "Habitable Planets / Barren Planets / Moons and Asteroids"
(`data.patent_class.*`). Building names are `{name:building.<key>}` and patent names
`{name:patent.<key>}`. Literals that are not constants carry their code line in `sources:`.

### Group: Buildings

#### `buildings` (guide)

- File `priv/help/en/buildings/buildings.md`, `kind: guide`, title "Buildings".
- `aliases: [unique-buildings#unique-buildings, limited-buildings#limited-buildings, infrastructure-building#infrastructure-first, destroy-building#destroying-a-building, demolish#destroying-a-building, foreign-buildings#buildings-of-other-players]`
- `terms: [building, buildings, Unique, Limited, unique building, limited building, destroy, demolish, infrastructure building]`
- Headings, exactly (anchors from `RC.Help.Compiler.anchor_id/1`, `compiler.ex:179-185`):
  - `## Where buildings go`
  - `## Infrastructure first` → `infrastructure-first`
  - `## Ordering a building`
  - `## Unique and Limited buildings`, with `### Unique buildings` → `unique-buildings` and
    `### Limited buildings` → `limited-buildings`
  - `## Destroying a building` → `destroying-a-building`
  - `## Damage`
  - `## Buildings of other players` → `buildings-of-other-players`
  - `## All buildings`
- The catalog badge links: Unique → `[[unique-buildings]]`, Limited → `[[limited-buildings]]`.
- OWNS:
  1. **Intro**, two sentences: buildings go on the tiles of your systems' bodies and make the system's
     outputs. Each has its own page (the catalog), reached from the `?` on its card.
  2. **Where buildings go.** Each building fits one body type: Habitable Planets, Barren Planets, or Moons
     and Asteroids. Gas giants and asteroid belts have no tiles (→ [[stellar-bodies]]). Which one fits is
     on each building's page and in the table at the end.
  3. **Infrastructure first.**
     - Tile 1 of a planet takes only its infrastructure building (→ [[infrastructure-tile]], not re-owned).
     - The planet's other tiles take nothing until that building is finished. Ordering it is not enough.
     - Moons and asteroids have no infrastructure and need none.
     - It also caps upgrades on its planet (→ [[upgrades]]) and can never be destroyed (next section).
  4. **Ordering a building.**
     - Pick a free tile, then a building from the menu (screenshot marks).
     - Level 1 needs the building's patent, unless its page says none (patent tree: plain text, Patents).
     - The full credit cost is paid when you order. You need at least that much credit, and a bankrupt
       empire cannot order (link [[credit]] only if that page covers bankruptcy, else plain text).
     - The production cost is worked off in the system's queue (→ [[construction-queue]]).
     - You cannot order buildings in a dominion (→ [[dominions]], one clause).
  5. **Unique and Limited buildings** (the badge target, in more depth than the tooltip):
     - Intro sentence: most buildings can fill every free tile of their body type. Two kinds cannot.
     - `### Unique buildings`: one per star system, on any of its bodies. Tooltip text via
       `{ui:card.building.unique_hint}` is not repeated; the section explains what counts.
     - `### Limited buildings`: one per planet, moon or asteroid. The same building can stand on each of
       them.
     - Shared rules, stated once after the two subsections:
       - A copy that is only ordered, or that is damaged, still counts.
       - The limit is checked only when you order level 1, so upgrading your copy is never blocked by it.
       - Destroying the copy, or cancelling its order, frees the slot at once.
     - Edge (one sentence): the build menu greys out a used one with the reason on its card (shot mark).
  6. **Destroying a building.**
     - Instant. No credit or production comes back.
     - Not an infrastructure building.
     - Not while the tile is being built, upgraded or repaired. A damaged building can be destroyed.
     - Not during a siege (→ [[siege]]).
     - Its workforce is freed at once (→ [[workforce]], not re-owned).
  7. **Damage**, two sentences: a Navarch's attack can damage buildings when it resolves
     (→ [[siege]] for which ones), and a damaged building stops working until repaired
     (→ [[damaged-buildings]]).
  8. **Buildings of other players** (Q4). One sentence: what you see depends on your visibility of the
     system (plain text, Galaxy). Then a hand table in words:

     | Visibility | What its tiles show |
     | --- | --- |
     | 0 or 1 | nothing about its buildings |
     | 2 or 3 | which tiles hold a building, and which are damaged |
     | 4 | also which building stands on each tile |
     | 5 | everything, including levels and construction in progress |

     One sentence each: a system of your own faction always shows everything; an agent of yours in the
     system gives at least 2. No word about diplomacy (excluded).
  9. **All buildings:** `{table:buildings_list}` (D1). No prose around it beyond a heading.
- Does NOT own: tile counts and body types (`stellar-bodies`), queue mechanics, time estimates and
  refunds (`construction-queue`), level requirements (`upgrades`), repair (`damaged-buildings`), which
  buildings a siege hits (`siege`), workforce, self-development, patent costs.
- Tables: the visibility table above (4 rows of words), `{table:buildings_list}` (D1).
- Screenshot: NEW `build-menu#locked,disabled,limited,cost` (R1). Caption names the marks: a building
  whose patent you lack (1), a Limited building already on this planet (2), its Limited badge (3), its
  costs (4).
- Chart: none.
- Code: `stellar_system.ex:347-447`, `:561-591`, `player.ex:351-398`, `tile.ex:20-52`, `:83-90`,
  `:132-149`, `faction/stellar_system.ex:83-87`, `:140-171`, `faction/faction.ex:169-183`,
  `Production.vue:188-218`, `BuildingCard.vue:54-65`, `BodiesItem.vue:139-232`, `game.json`
  `card.building.*` (77-98), `production.*` (1391-1400).

#### `construction-queue` (leaf, guide: buildings)

- File `priv/help/en/buildings/construction-queue.md`, title `Construction queue`
  (`card.closed_system.construction_queue`), `aliases: [build-queue, cancel-order#cancelling-an-order]`,
  `terms: [construction queue, build queue, queue, cancel, refund]`.
- OWNS:
  1. Each system has one queue for new buildings, upgrades, repairs and ship orders (ships: plain text,
     Ships). Items are worked in the order they were placed. For how production fills them, see
     [[production]] (one sentence, not re-owned).
  2. One order per tile: a tile being built, upgraded or repaired takes no other order until that one
     finishes or is cancelled.
  3. **Time estimates.**
     - The time on a building card is that level's production cost divided by the system's current
       production, as if nothing else were in the queue. Example line:
       `1 200 production ÷ {rate:100|production} = {duration:12}`.
     - The queue list shows when each item should finish, counting the items before it, at the current
       production.
     - Both change whenever the system's production changes.
     - In a Flash game the queue list shows no finish times.
  4. **Cancelling an order** (`## Cancelling an order`, alias target).
     - Any item can be cancelled, not only the last.
     - A new building or an upgrade gives back its full credit cost. A repair gives back its repair
       credit cost (→ [[damaged-buildings]]).
     - Production already spent on it is lost.
     - The tile goes back to how it was: empty, or the building at its old level.
     - Ship orders also refund technology (plain text, Ships).
  5. During a [[siege]] you can neither order nor cancel.
  6. Edge (Q3): when the system is conquered, liberated or abandoned, its queue stays. The orders finish
     for the new holder, nothing is refunded, and you can no longer cancel them.
- Does NOT own: carry-over, lost ship leftovers, empty queue, zero production (`production`); ship order
  rules (Ships); siege blocks (`siege`); repair amount (`damaged-buildings`).
- Tables: none.
- Screenshot: NEW `production-queue#first,finish-time,cancel` (R3). Optional second: NEW
  `production-box-queue#progress,counter` (R4) for the countdown of the item being built.
- Code: `production_queue.ex:18-68`, `production_item.ex:34-40`, `stellar_system.ex:369`, `:517`,
  `:571`, `:604-649`, `:235-283`, `stellar_system/agent.ex:61-86`, `player/agent.ex:421-449`,
  `player.ex:770-772`, `BuildingCard.vue:106-124`, `store.js:204-206`, `Production.vue:178-187`,
  `ClosedProductionCard.vue:38-48`, `ProductionBox.vue:28-64`.

#### `upgrades` (leaf, guide: buildings)

- File `priv/help/en/buildings/upgrades.md`, title `Upgrades`, `aliases: [upgrade, building-levels]`,
  `terms: [upgrade, building level, level cap]`.
- OWNS:
  1. An upgrade raises a finished building by one level. It is ordered and paid like a new building
     (→ [[buildings]], [[construction-queue]]). Each level's costs and effects are on the building's page.
  2. One level at a time: you can only order the next level, and not while that tile has another order.
  3. While it upgrades, the building keeps working at its current level. The new level counts once the
     upgrade finishes.
  4. **What each level needs** (the core, one short list plus the table):
     - An infrastructure building needs its own patent for each level.
     - Other buildings on a planet need no patent above level 1. Their level cannot go above the planet's
       infrastructure level. An infrastructure upgrade still in progress does not count.
     - Buildings on moons and asteroids have no such cap. Their levels 2 to 5 need one shared patent per
       level.
     - Example line: `{name:building.infra_open} level 3 → buildings on that planet up to level 3`.
     - `{table:upgrade_patents}` (D2).
  5. Edge: in a Flash game every building has one level, so nothing can be upgraded.
  6. Edge (Q1 default): repair a damaged building before you can upgrade it (→ [[damaged-buildings]]).
  7. Edge: a siege hit on an upgrading building cancels the upgrade (→ [[siege]], one clause, not
     re-owned).
- Does NOT own: per-level costs and bonuses (catalog), patent prices and the tree (Patents), which
  buildings a dominion upgrades (`self-development`), workforce while upgrading (`workforce`).
- Tables: `{table:upgrade_patents}` (D2).
- Screenshot: NEW `body-tiles-actions#upgrade` (R2).
- Code: `stellar_system.ex:381-392`, `building.ex:72-80`, `player.ex:382-387`, `patent.ex:56-62`,
  `stellar_system.ex:1620-1631`, `tile.ex:45-46`, `:73-74`, `building-fast.ex` (one level),
  `buildingValidation.js:2-29`, `BodiesItem.vue:61-76`, `data.json` `patent_info.infra_*`.

#### `damaged-buildings` (leaf, guide: buildings)

- File `priv/help/en/buildings/damaged-buildings.md`, title `Damaged buildings`,
  `aliases: [repair, repairs]`, `terms: [damaged building, repair, repairs, repairs underway]`.
- OWNS:
  1. Buildings are damaged only when a Navarch's conquest, bombardment or pillage resolves
     (→ [[siege]] for which ones; how many per result: plain text, Navarchs). An Erased's sabotage never
     damages buildings (plain text, Erased; §8.1).
  2. A damaged building:
     - gives no bonuses at all, so no output, housing or stability,
     - still mobilizes its workforce (→ [[workforce]]),
     - still counts as the one Unique or Limited copy (→ [[unique-buildings]]),
     - cannot be upgraded until repaired (Q1),
     - can be destroyed (→ [[destroy-building]]),
     - a damaged shipyard does not allow ship orders (one clause, details on the shipyard pages).
  3. **Repairing.** A repair costs `{const:building_repairs_factor}` × the credit and production of the
     building's current level. Credit is paid when you order, production is worked off in the queue
     (→ [[construction-queue]]). It needs no patent and gives the building back at the same level.
     Example block with round numbers, not a real building:
     `8 000 credits × {const:building_repairs_factor} = 4 000 credits`,
     `1 000 production × {const:building_repairs_factor} = 500 production`. Amounts round to the nearest
     whole number (`stellar_system.ex:548`, `player.ex:374`).
  4. Cancelling a repair gives back its credit. The building stays damaged.
  5. During a [[siege]] you can neither order nor cancel a repair.
- Does NOT own: siege targeting and the upgrade refund (`siege`), attack results (Navarchs), queue order
  (`construction-queue`).
- Tables: none. The catalog shell shows each level's costs; the factor is one constant.
- Screenshot: NEW `body-tiles-actions#damaged,repair` (R2).
- Code: `stellar_system.ex:508-559`, `:604-649`, `:1300-1320`, `:1532-1547`, `:1620-1631`,
  `:394-415`, `:449-473`, `player.ex:371-387`, `player/agent.ex:1428-1450`, `tile.ex:93-130`,
  `constant-slow.ex:19`, `BodiesItem.vue:209-220`.

---

## 4. Catalog prose slots

One row per building. Speeds: L = Legacy, T = Tactic, F = Flash. "empty" means no slot text; the shell and
the modifier tooltips cover it. A slot never repeats the shell (costs, levels, badge, body type, patents,
requirements, ship class).

| Key | UI name | Speeds | Slot | Code for the claim |
| --- | --- | --- | --- | --- |
| infra_open | Megapolis | L T F | 3 sentences: it only goes on tile 1 of a habitable planet ([[infrastructure-tile]]); until it is finished nothing else can be built on that planet, and no building there can rise above its level ([[infrastructure-building]], [[upgrades]]); it can never be destroyed and a siege never damages it ([[destroy-building]], [[siege]]). | `stellar_system.ex:371-380`, `:387-391`, `:572`, `:1709-1710` |
| infra_dome | Central Hub | L T F | Same as `infra_open`, for a barren planet. | same |
| mine_dome | Array of Excavators | L T F | empty | |
| mine_orbital | Swarm of Self-drilling Machines | L T | empty | |
| hab_open | Residential District | L T | empty | |
| hab_dome | Capsule Cities | L T F | empty | |
| hab_open_poor | Hive Cities | L T F | empty | |
| hab_open_rich | Residential Archipelago | L T F | empty | |
| factory_open | Industrial Hub | L T | empty | |
| factory_orbital | Refining Ducts | L T F | empty | |
| high_factory_dome | Metamaterials Factory | L T F | 1 sentence (Q6): the first one finished in the galaxy is announced to every player in the news, with your faction and the system's name. | `stellar_system.ex:1182-1195`, `news/server.ex:215-216`, `:258-270`, `portal.json:113-117` |
| lift_open | Orbital Link | L T F | empty | |
| lift_dome | Space Elevator | L T | empty | |
| university_open | Delta Polytech | L T F | empty | |
| research_open | Accelerator | L T F | empty | |
| research_dome | Impact Research Center | L T | empty | |
| research_orbital | Experiment Station | L T F | empty | |
| ideo_open | Citadel | L T F | empty | |
| ideo_dome | Holodome | L T | empty | |
| monument_open | Floating Gardens | L T | 1 sentence (Q6): it is the Monument of the Monumental daily challenge, and finishing it completes that race (plain text, daily challenge). | `stellar_system.ex:1197-1203`, `lib/daily/objective.ex:159-173` |
| monument_dome | Monolith | L T F | 2 sentences (Q6): the news sentence of `high_factory_dome`; while it stands in a system, that system's Mobility credit bonus also counts percentage bonuses to mobility ([[mobility]]). | as `high_factory_dome`; `bonus.ex:38-87`, `mobility.md:30` |
| ideo_credit_open | Network of Artificial Islands | L T F | empty | |
| market_open | Commercial Artery | L T F | empty | |
| market_dome | Omnimarket | L T | empty | |
| finance_open | Reflect District | L T F | 1 sentence (Q6): the mobility sentence of `monument_dome`. | `bonus.ex:38-87`, `mobility.md:30` |
| finance_orbital | Business Arch | L T | Same as `finance_open`. | same |
| spatioport_dome | Industrial Spaceport | L T F | empty | |
| spatioport_orbital | Orbital Terminus | L T F | empty | |
| defense_global_dome | C.N.D. | L T F | empty (`defense.md:46` owns "before percentage bonuses"; the shell's input link reaches it) | |
| defense_local_open | Planetary Shield | L T F | empty | |
| defense_local_dome | Interception Tunnels | L T F | empty | |
| defense_local_orbital | Constellation of Lures | L T F | empty | |
| happy_pot_open | Preserved Ecosystem | L T F | empty | |
| happy_pot_dome | Hyperdrive Circuit | L T F | empty | |
| happy_pot_orbital | Zero-G Arena | L T F | empty | |
| happy_orbital | O.P.U. | L T | empty | |
| shipyard_1_orbital | S-01 Assembly Line | L T F | 2 sentences: you can order fighters in this system only while it is finished and not damaged; an upgrade in progress does not stop orders, and fighters already in the queue still finish if it is damaged or destroyed. | `stellar_system.ex:449-473`, `:1144-1171`, `:561-591` |
| shipyard_2_orbital | S-02 Assembly Line | L T F | Same, for corvettes. | same |
| shipyard_3_orbital | Space Dock | L T F | Same, for frigates. | same |
| shipyard_4_orbital | Assembly Superstructure | L T F | Same, for capital ships. | same |
| military_school_dome | Aerospace Military Academy | L T F | empty (Q2 fallback: siege sentence) | |
| radar_orbital | S.L.S.D. Network | L T F | empty (Q2 fallback) | |
| counterintelligence_open | Orb-INTEL | L T F | empty (Q2 fallback) | |
| removecontact_open | Convention Center | L T | empty (Q2 fallback) | |
| removecontact_dome | Integrated Proxy Systems | L T | empty (Q2 fallback) | |

Non-empty: 11. Q2 fallback, if the shell gets no siege line: the sentence "A siege is twice as likely to
damage it as most buildings. See [[siege]]." goes into all 11 weighted buildings (the 5 above plus
`defense_global_dome`, the three `defense_local_*` and `shipyard_3_orbital` / `shipyard_4_orbital`, whose
slots then grow by one sentence).

Checked and left empty on purpose: buildings scaling with local population, potentials, mobility or
population (the shell links each input, D4); no-patent buildings (shell); stability maluses (tooltips);
the C.N.D. formula (`defense`); the self-development exclusions of the Monolith and Metamaterials Factory
(`self-development`).

---

## 5. Shell checks for the developer

Facts the generated shell must get right, all verified in code or by running it.

1. **Level 1 patent** is `levels[0].patent`. `nil` means no patent: Residential District and Delta
   Polytech at Legacy and Tactic; Hive Cities and Delta Polytech at Flash (`building-*.ex`).
2. **Levels 2 to 5** (`building.ex:72-80`, checked at `player.ex:382-387` and `stellar_system.ex:387-391`):
   - `type: :infrastructure` → its own patent per level (`infra_open_2..5`, `infra_dome_2..5`). No
     infrastructure-level requirement (tile 1 is exempt).
   - `biome: :orbital` → hidden patent `infra_orbital_N` ("Pressurized Environment II-V"),
     `hide_patent?: true`. No infrastructure-level requirement. Read the building level's `patent`: the
     patent's own `unlock` list is empty for these (`patent.ex:56-62`). `data.patent_info.infra_orbital_N`
     has player text.
   - Every other building → no patent. Requirement: the planet's infrastructure building at that level or
     higher, finished. Use the wording of `card.building.level_requirements` if it helps.
3. **Moons and asteroids are exempt** from the infrastructure cap and need no infrastructure building to
   build (`stellar_system.ex:378`, `:387`).
4. **Uniqueness is checked only for level 1** (`stellar_system.ex:394-415`). `unique_body` counts the tile's
   own body only, `unique_system` every body including moons. Ordered and damaged copies count.
   Badge tooltips: `{ui:card.building.unique_hint}`, `{ui:card.building.limited_hint}`; badge links
   `[[unique-buildings]]`, `[[limited-buildings]]`.
5. **Body type** from `biome`: `open` → Habitable Planets, `dome` → Barren Planets, `orbital` → Moons and
   Asteroids (`data.patent_class.*`, `stellar-body.ex`). Infrastructure buildings go only on tile 1 of a
   planet; no other building goes there (`stellar_system.ex:371-376`).
6. **Ship class per shipyard**, identical at all three speeds (`ship-*.ex` `shipyard:`):
   - `shipyard_1_orbital` → fighter (16 ship keys: `fighter_1..4` and their `v2..v4`)
   - `shipyard_2_orbital` → corvette (9: `corvette_1..3`, `v2..v3`)
   - `shipyard_3_orbital` → frigate (8: `frigate_1..4`, `v2`)
   - `shipyard_4_orbital` → capital (3: `capital_1..3`)
   - `transport_1`, `transport_2` have `shipyard: nil`: they need no shipyard.
   The gate needs the shipyard finished and not damaged; upgrading is fine (`stellar_system.ex:458-467`).
7. **Speeds.** Render per speed from that speed's content, never from Legacy. Flash has 33 buildings with
   one level each (no level selector beyond 1, no level requirements). The 12 Flash-missing keys (section 2)
   need a "Not in Flash games" state. Every patent a building level references exists in that speed's tree
   (checked by script; only `hypergate`'s `orbital_hypergate` is missing, and it is excluded).
8. **Costs are not monotonic** (Q8). Print each level as the content says. Never derive a level from
   another.
9. **Exclude** `biome: :gate` (`hypergate`) the way `RC.Help.Tables.listed_buildings/1` does
   (`tables.ex:260-264`). `happy_open` has a locale entry and icon but no content row.
10. **Siege line (Q2):** `:defense in building.outputs` (`stellar_system.ex:1712`), not "has a
    `sys_defense` bonus". Legacy/Tactic: `defense_global_dome`, `defense_local_open`, `defense_local_dome`,
    `defense_local_orbital`, `shipyard_3_orbital`, `shipyard_4_orbital`, `military_school_dome`,
    `radar_orbital`, `counterintelligence_open`, `removecontact_open`, `removecontact_dome`. Flash: the same
    minus the two `removecontact_*`.
11. **Workforce** is per building, the same at every level (`building.workforce`).
12. **Repair cost** is not part of the shell (owned by `damaged-buildings` as one factor).
13. **Frontmatter:** `source.ex` requires `title:`. If the shell files are written by hand or a generator,
    use the English name; the shell should render `{name:building.<key>}` per locale.

---

## 6. Developer specs

**D1. `buildings_list` table** (no args), in `RC.Help.Tables`. Rows: `listed_buildings(ctx)`, sorted by body
type (open, dome, orbital) then name, like `building_table/2`. Columns:
- Building: `{icon:building/<key>}` + `link_or_name(ctx, "building/<key>", name)`
- Built on: `data_name(["patent_class", biome, "name"])`
- Limit: `{ui:card.building.unique}` for `unique_system`, `{ui:card.building.limited}` for `unique_body`,
  "—" otherwise (resolve the UI strings in the generator)
- Workforce: `building.workforce`
- Levels: `length(levels)`

Test: Legacy 45 rows, Flash 33, no `hypergate`.

**D2. `upgrade_patents` table** (no args). One row per level n from 2 to the highest level of any listed
building. Columns:
- Level
- Habitable Planets infrastructure: patent of `infra_open` level n
- Barren Planets infrastructure: patent of `infra_dome` level n
- Moons and Asteroids: the patent of orbital buildings at level n (assert every orbital building shares it;
  if not, list the distinct names)

Patent cells link `patent/<key>` when that page exists. Render the "none" placeholder when no building has
level 2 (Flash). Test: Legacy row 2 = Urbanization II / Controlled Environment II / Pressurized
Environment II.

**D3. `buildings_by_tag <outputs tag>` table** (one arg, a tag of `Data.Game.Building.outputs`: `prod`,
`credit`, `tech`, `ideo`, `hab`, `happiness`, `defense`). Columns: Building (icon + link), Built on.
Moduledoc: the tags are content labels used by siege targeting and self-development, not the bonuses a
building makes. Test: `defense` gives 11 rows at Legacy, 9 at Flash.

**D4. Shell details** (on top of the decided shell):
- (a) the level-requirement rules of section 5, items 1-4;
- (b) Q2 siege line;
- (c) bonus input links: `body_ind`, `body_tec`, `body_act` → `[[potentials]]`; `body_pop` →
  `[[local-population]]` (new alias on `housing`, linking plan); `sys_pop` → `[[workforce]]` (it reads
  workforce, `bonus-pipeline-in.ex` `from_key: :workforce`); `sys_mobility` → `[[mobility]]`;
  `sys_defense` → `[[defense]]`; `direct` → no link;
- (d) "Not in Flash games" state for the 12 missing keys.

**D5. Fixture option `buildings`** on `POST /api/harness/dev/agent-fixture` (`dev_fixture_controller.ex`),
used with `empire`. On the home system, after the empire steps:
1. Grant credits and technology with `{:cheat, :grant_resources, _}` and buy the patents needed below,
   through `{:purchase_patent, _}`, as `slot_empire_lexes/2` does for Lexes.
2. Put, on the inhabited habitable planet:
   - its infrastructure building at level 2
   - a Residential District level 1 on tile 2, left idle, so its upgrade button shows
   - a damaged Delta Polytech level 1 on tile 3, so its repair button shows and the build menu greys out
     a second one
   Real paths cannot finish or damage buildings instantly, so add a dev-only
   `{:dev_put_building, body_uid, tile_id, key, level, status}` call on `Instance.StellarSystem.Agent`
   (`Tile.force_building/3`, then set `building_status`, then `compute_bonus`), gated like the fixture
   controller (`:environment == :dev`).
3. Place two real orders through the player agent so the queue is not empty: a Floating Gardens on tile 4
   (1 200 production, about 12 ticks at 100 production), then a Residential District on tile 5.
4. Return the body uid and tile ids in the `empire` block.

**D6. Capture recipes** (`e2e/help-shots/shots.json`; new prepares in `capture.js`):

| # | Recipe | Scene / system | Selector / prepare | Marks |
| --- | --- | --- | --- | --- |
| R1 | `build-menu` | `empire`, home, with D5 | prepare NEW `open-build-menu`: click the first `.tile.is-hoverable` of the inhabited planet's `.body-tiles`, then hover the greyed Delta Polytech in `.system-production-content` (the `.tile` whose card shows `production.unique_building`). Capture the union of `.system-production` and `.system-production-building-card .card-container` | `locked`: first `.system-production-content .tile.has-dashed-background`; `disabled`: the hovered menu tile; `limited`: `.system-production-building-card .toast`; `cost`: `.system-production-building-card .card-cost` |
| R2 | `body-tiles-actions` | `empire`, home, with D5 | the inhabited planet's `.system-content-group` (same selector as `system-body`). Prepare NEW `hover-tile-corner`: move the pointer to the bottom-right corner of the Residential District tile (not its icon, which opens a card), so its hidden destroy toast shows (`tile.scss:77-102`) | `upgrade`: that tile's `.tile-toast.top.left`; `damaged`: the `.tile.has-dashed-background`; `repair`: its `.tile-toast.top.left`; `construction`: first `.tile-toast.bottom.left`; `destroy` (optional): the hovered tile's `.tile-toast.bottom.right` |
| R3 | `production-queue` | `empire`, home, with D5 | prepare NEW `open-production-queue`: dispatch a click to `.production-box .round-icon` (a real click is intercepted, as for `pin-production-popover`), then hover the first `.system-production-queue .card-container` so its cancel button shows (`cards.scss:309`). Selector `.system-production-queue` | `first`: first `.card-container`; `finish-time`: its `.title-small`; `cancel`: its `.card-header-toast` |
| R4 | `production-box-queue` (optional) | `empire`, home, with D5 | `.production-box`, no prepare | `progress`: `.round-icon`; `counter`: `.production-counter` |

Also for the guide (Q4), optional R5 `foreign-tiles`: scene `empire`, `openSystem: autonomous` (visibility 2
from the parked Siderian), selector: the first `.system-content-group` with `.body-tiles`, mark
`hidden-building`: first `.tile` whose `.tile-level` reads `?`.

**D7. Locale fixes** (`front/src/locales/en|fr/game.json`):
- `card.cost.production`: "Industry required — worked off over time by the system's industry output. The
  time shown is the estimate at current output." → "Production required, worked off by the system's
  production. The time shown assumes nothing else is in the queue." (UI name, no dash, true estimate, Q7.)
- `production.unique_building` / `production.unique_system`: "has already been constructed" is also shown
  when the copy is only ordered → "This body already has one, built or ordered." / "This star system
  already has one, built or ordered."
- `errors.json` `shipyard_not_found`: "No appropriate ship construction building found" → "This ship
  needs its shipyard, finished and not damaged, in this system."

**D8. Doc fixes.** docs/help-manual.md §7.1 says catalog slugs are kebab-case (`building/hab-open`); the
decision for buildings is the internal key with underscores (`building/hab_open`), matching the card's
`?`. Same example in the `RC.Help.Source` moduledoc (`source.ex:26-29`). §5.1 row 2: "4 mechanic + 45
catalog".

**D9. Bug ticket (Q1).** Refuse an upgrade order on a damaged tile in `order_building_production`
(`stellar_system.ex:381-392`, e.g. `if tile.building_status != :built, do: throw(:no_upgrade_while_damaged)`),
with a test. Until then, a crafted client can pay for an upgrade that never happens.

---

## 7. Formula and topic owners

"Owner" is the only page that states the rule. Every other page links to it or says one sentence.

| Rule | Owner | Code | Notes |
| --- | --- | --- | --- |
| Which body type a building fits | catalog shell; `buildings` table D1 | `building-*.ex` `biome`, `stellar-body.ex` | guide: one sentence |
| Tile 1 of a planet is the infrastructure tile | `stellar-bodies` (existing) | `tile.ex:20-34` | buildings pages link `[[infrastructure-tile]]` |
| Other tiles need a finished infrastructure building; moons and asteroids exempt | `buildings` §Infrastructure first | `stellar_system.ex:378-380` | |
| Infrastructure cannot be destroyed | `buildings` §Destroying | `:572` | infra catalog slots repeat it in one clause |
| Level 1 patent gate, credit paid up front, credit ≥ cost, bankrupt refused | `buildings` §Ordering | `player.ex:351-398` | patent tree and prices: Patents (future) |
| Patent chain of a building | catalog shell | `patent-*.ex` `ancestor` | |
| No orders in a dominion | `dominions` (existing) | `player.ex:369`, `:378` | |
| Unique and Limited: scope, queued and damaged count, level 1 only, freed by destroy or cancel | `buildings` §Unique and Limited | `stellar_system.ex:394-415` | badge links here |
| Destroy: instant, no refund, not infra, not under construction, damaged allowed | `buildings` §Destroying | `:561-591` | siege lock stays on `siege` |
| Workforce of built, damaged and upgrading buildings; freed on destroy | `workforce` (existing) | `:1532-1547` | |
| Production into the head item, carry-over, lost ship leftovers, empty queue, zero production | `production` (existing) | `:1018-1020`, `:1140-1216` | |
| One queue, order of work, one order per tile | `construction-queue` | `production_queue.ex:18-68`, `:369` | |
| Time estimates on the card and the queue list; none in Flash | `construction-queue` | `BuildingCard.vue:114-116`, `Production.vue:178-187`, `ClosedProductionCard.vue:38-42` | Q7 |
| Cancel: any item, full credit back, production lost, repair refund | `construction-queue` | `:604-649`, `player/agent.ex:421-449` | repair amount itself: `damaged-buildings` |
| Queue kept when a system changes hands | `construction-queue` | `:235-283`, `player.ex:770-772` | Q3 |
| One level at a time | `upgrades` | `:381-385` | |
| Per-level requirements: infra patents, orbital patents, infrastructure cap | `upgrades` + table D2 | `building.ex:72-80`, `player.ex:382-387`, `stellar_system.ex:387-391` | catalog shell shows them per building |
| Upgrading building keeps its current level's bonuses | `upgrades` | `:1620-1631` | |
| Damaged building gives no bonuses | `damaged-buildings` | `:1300-1320`, `:1620-1631` | `housing` keeps its one line on housing |
| Repair cost and time (`building_repairs_factor`), no patent, cancel a repair | `damaged-buildings` | `:508-559`, `:623`, `player.ex:374` | |
| Which buildings a siege damages, weights, upgrade cancelled and refunded | `siege` (existing) + D3 table | `:1671-1764` | Q2 |
| Siege blocks orders, repairs, cancels, destroys, ships | `siege` (existing) | `:361`, `:455`, `:512`, `:568`, `:606` | linking plan adds cancel and destroy |
| Buildings damaged per attack result | Navarchs (future) | `raid.ex`, `conquest.ex`, `loot.ex` | plain text |
| Erased sabotage never damages buildings | Erased (future) | `sabotage.ex` | `damaged-buildings`: one sentence |
| Shipyard gate for ship orders | shipyard catalog slots now; Ships (future) for ship ordering | `:449-473` | |
| Ship class per shipyard | catalog shell; Ships (future) | `ship-*.ex` `shipyard` | |
| Ship starting experience from `*_lvl` outputs | Ships (future) | `:1144-1152` | |
| Ship order refunds (credit + technology); ship orders dropped when a Navarch is removed | Ships / Navarchs (future) | `:611-613`, `player/agent.ex:1303-1308` | |
| Local population from housing on each planet | `housing` (existing) | `:1460-1484` | shell input link |
| How bonuses stack; C.N.D. before percentages | `system-outputs`, `defense` (existing) | `bonus.ex:38-87` | |
| Mobility credit bonus counts percentages with a Reflect District, Business Arch or Monolith | `mobility` (existing) | `bonus.ex:38-87` | three catalog slots point there |
| What autonomous systems and dominions build | `self-development` (existing) | `lib/game/system_ai/*` | |
| New colony and capital start with infrastructure level 1 | `colonization` (existing) | `:1410-1439` | |
| Visibility levels and how you get them | Galaxy (future) | `faction/faction.ex:169-183` | |
| What another player's tiles show per visibility level | `buildings` §Buildings of other players | `tile.ex:132-149`, `faction/stellar_system.ex:83-87`, `:168-171` | Q4 |
| "Galaxy's first" news bulletins | Galaxy & UI (future news page) | `news/server.ex:215-216` | two catalog slots |
| Monumental daily race | Game modes (future) | `lib/daily/objective.ex:159-173` | Floating Gardens slot |
| Per-level costs and effects | catalog shell | `building-*.ex` | never typed in prose |

---

## 8. Linking plan for existing pages

Each edit sends the page back through phase 2. Links only, except the two corrections on `siege`. Applied
by a second run after the new pages land, as in the Systems run.

| Page | Change |
| --- | --- |
| `siege` | "No one can order buildings, repairs or ships, or place or recall agents." → also "cancel orders or destroy buildings" (verified, `stellar_system.ex:568`, `:606`). "A [[defense]] building is twice as likely to be picked as any other." → "The buildings in this table are twice as likely to be picked as the others:" + `{table:buildings_by_tag defense}` (D3, Q2). "damage buildings" → [[damaged-buildings\|damage buildings]]. "cancels and refunds the upgrade" → link [[upgrades]]. Add `damaged-buildings`, `construction-queue` to `related`. |
| `production` | Move the term "build queue" from `terms` to `construction-queue`. After the first bullet list: "For the order of the queue, time estimates and cancelling, see [[construction-queue]]." Add `construction-queue`, `buildings` to `related`. |
| `stellar-bodies` | "Your buildings go on their tiles." → [[buildings\|Your buildings]]. After "Only an infrastructure building goes there.": "The planet's other tiles need it first. See [[infrastructure-building]]." |
| `workforce` | "A damaged building" → [[damaged-buildings\|A damaged building]]. "being upgraded or repaired" → [[upgrades\|upgraded]] or [[repair\|repaired]]. "Demolishing a building frees its workforce at once." → "[[destroy-building\|Destroying]] a building frees its workforce at once." (UI word). |
| `housing` | Add alias `local-population#population-on-each-body` (for D4c). "A damaged building gives no housing." → link [[damaged-buildings]]. |
| `self-development` | `[[production\|build queue]]` → `[[construction-queue\|build queue]]`. `[[siege\|damaged building]]` → `[[damaged-buildings\|damaged building]]`. `[[stellar-bodies\|infrastructure]]` → `[[infrastructure-building\|infrastructure]]`. Advanced section: "one per planet or one per system" → [[limited-buildings\|one per planet]] / [[unique-buildings\|one per system]]; "cannot rise above its infrastructure's level" → link [[upgrades]]. |
| `colonization` | "A level 1 {name:building.infra_open}" and the barren line → link [[infrastructure-building]]. |
| `dominions` | "You cannot order buildings or ships in a dominion." → [[buildings\|order buildings]]. |
| `star-systems` | "You build on the tiles of those bodies." → [[buildings\|You build]]. |
| `system-outputs` | "Buildings, some of which grow…" → [[buildings\|Buildings]]. |
| `system-limits` | "damage buildings" → [[damaged-buildings\|damage buildings]]. |
| `administrative-operations` | After "Buildings and population stay." (Q3): "Its construction queue stays too. See [[construction-queue]]." |
| `credit` | "They pay for buildings" → [[buildings\|buildings]]. |

Not changed: `defense` (already owns the C.N.D. sentence), `mobility` (already names the three buildings),
`technology`, `ideology`, `population-status`.

---

## 9. Batch plan and estimates

Previous runs: about 9 agents per mechanic page (Pilot 2: 91 agents for 10 pages), about 4-5 for a short
leaf accepted in round 0, 12-15 for a guide or an edge-case-heavy leaf.

| Order | Batch | Pages | Needs first | Estimate |
| --- | --- | --- | --- | --- |
| 0 | Developer | D1-D3 generators, D4 shell details, D7 locale, D8 docs | map approved | no agents |
| 1 | Buildings group, 1 writer | `buildings`, `construction-queue`, `upgrades`, `damaged-buildings` | Q1-Q5, Q7 answered; D1-D3 merged | guide ~14, three leaves ~9 each = ~41, + 1 consistency critic = ~42 |
| 1b | Capture | R1-R4 (R5 optional) | D5 merged | 1-2 agents; each page that gains a shot goes back through phase 2: ~4 × 3 = ~12 |
| 2 | Linking plan re-review | 13 existing pages (section 8) | batch 1 landed | ~13 × 4 = ~52 (many are one-link edits; accepted round 0) |
| 3 | Catalog prose slots | 11 non-empty slots (+11 one-sentence slots if Q2 = no) | the shell compiles; batch 1 landed (slots link to it) | see below: ~7 (or ~9) |

**Catalog verification, cheaper than mechanic pages.** Empty slots get no agent; the planner has checked
them (section 4). Non-empty slots are 1-3 sentences that each carry one code claim.
- 1 writer for all 11 slots (one batch; rule of thumb 12 per writer).
- 1 accuracy critic per batch, strongest model, runs code for every claim (shipyard gate, infrastructure
  rules, news first, daily race, mobility rebase) against the rendered shell page, and also checks that no
  slot repeats the shell.
- 1 clarity critic per batch, cheaper model, style rules only.
- Voters only for the 3-sentence slots (the two infrastructure pages): 2 blind voters, reading the whole
  catalog page. None for 1- and 2-sentence slots.
- At most 1 revision round for the batch: 1 reviser + 1 re-review by the accuracy critic on the changed
  slots only.

Estimate: 1 + 1 + 1 + 2 + 2 = **~7 agents** for the batch (**~9** with the Q2 fallback slots: +1 writer
pass, +1 critic pass).

Total: about 42 + 12 + 52 + 7 ≈ **115 agents**, most of it the linking re-review. Batch 2 can run in
parallel with batch 3. Batch 1 must land before both, because both link into it.

# Systems & Dominions: guide map for the rest of the category

Planner output, phase 0 (docs/help-manual.md §3.2, §5.2 v3). Written 2026-09-13 against the worktree
`claude/systems-dominions-pages-20e1a5` (commit a078cb3). Legacy values. Line references are to that
commit.

## Summary (for approval)

### Guide tree

Existing, approved (unchanged except for the links and one moved rule listed below):
`population` guide (housing, stability, workforce, population-class, population-status, system-penalties),
`credit` guide (mobility; `taxes` alias), `basics/game-time`.

New, 3 guides + 10 leaves = 13 pages:

```
systems/system-outputs        GUIDE  What a system makes, where each output goes, how bonuses add up (alias bonus-stacking)
  systems/production          leaf   Base production (capital vs others), how the queue consumes it, lost when the queue is empty
  systems/technology          leaf   Sources of technology, where it goes, what spends it
  systems/ideology            leaf   Sources of ideology, where it goes, what spends it
  systems/defense             leaf   Population share (moved here from population), what defense protects against, sources

systems/star-systems          GUIDE  What is in a system, who holds it (5 statuses), where you can expand, capital, losing systems
  systems/stellar-bodies      leaf   Body types, tiles, the infrastructure tile, the three potentials, star types
  systems/colonization        leaf   Which systems, requirements, duration, what a new colony gets
  systems/system-limits       leaf   System Limit and Dominion Limit: start values, sources, what they block
  systems/administrative-operations  leaf  Liberate, Administer, Abandon: cost, requirements, what the system keeps
  systems/siege               leaf   What a siege blocks, which buildings get damaged, pillage yield (hidden raid potential)

dominions/dominions           GUIDE  What a dominion is, how you get and lose one, what you can and cannot do with it
  dominions/dominion-tax-rate leaf   Your share of a dominion's credit/technology/ideology, sources of the rate
  dominions/self-development  leaf   How autonomous systems and dominions build by themselves
```

Dropped or merged: bonus stacking (a section of `system-outputs`), system status and the capital (sections
of `star-systems`), star types and tiles (sections of `stellar-bodies`), liberate/administer/abandon (one
leaf, matching the one "Administrative Operations" box in the UI), raid potential (a section of `siege`).
Not planned here: S.L.S.D., Intelligence, Cybersecurity (Galaxy, Erased), ship initial XP (Ships), governors
(Agents), building damage effects, repair and the build queue (Buildings), Navarch and Siderian action rolls
(Navarchs, Siderians).

### A developer builds first

1. **Answers to questions Q1-Q3 below.** They block `system-outputs`, `star-systems` and `dominions`.
2. **Table generator `stellar_bodies`** (no args) and **`star_types`** (no args). Specs in D2/D3. Block `stellar-bodies`.
3. **Formatter fix:** `RC.Help.Format.bonus/3` prints `dominion_rate` bonuses as percentages (`+0.2` →
   `+20 %`). Blocks `dominion-tax-rate` (D4).
4. **Capture scene `empire`** (D6): a fixture game where the player holds 2 systems and 1 dominion, next to
   an autonomous and an uninhabited system. Needed for every dominion screenshot. It also unblocks 4 shots
   parked in the pilot-2 backlog. The `dominions` group can be written without it and get its shots later.
5. **Locale fixes** (D7): four typos and wrong words in `system.status.*`.

No new charts. Six new recipes run on the existing `own-system` scene and need only new `prepare` steps.
The phase-1b capture agent can add those itself.

### Open questions

- **Q1 Bonus stacking.** A percentage bonus is not seen by later bonuses that read a value, unless a flat bonus comes after it (`bonus.ex:42-56`, `:94-96`). Example: a +10 % Mobility Lex adds nothing to the Mobility bonus unless a building also turns mobility into credits. Intended, or a defect? (Already parked in the pilot-2 backlog under mobility.)
- **Q2 Capital is lost for good.** Liberating (`stellar_system.ex:261`, `is_initial_system` false), abandoning (`:273`) or losing your capital clears the flag, and no system ever becomes the new capital. Liberate then Administer drops base production from 100 to 40 for good. Intended?
- **Q3 Faction-mates.** On the server, conquest and Control only refuse the player's *own* system (`conquest.ex:55`, `make_dominion.ex:36`, `:111`). I did not find a server check against a faction-mate's system or dominion. Is taking from a faction-mate allowed? If not, where is it blocked?
- **Q4 Every siege end drains pillage yield.** A conquest, bombardment or pillage lowers raid potential by 45 when it resolves, even on a critical failure (`stellar_system/agent.ex:203-206` → `stellar_system.ex:305-312`). So a failed bombardment shrinks the next pillage. Intended? Also, raid potential is never sent to the client (`stellar_system.ex:34`). What should the manual call it: "pillage yield"?
- **Q5 Pillaging a dominion.** It takes the dominion's full output × multiplier out of the *owner's* stock (`loot.ex:122-129`), though the owner only receives a 30 % share of that output. Intended?
- **Q6 Negative dominions.** A dominion with negative credit lowers your income, with no floor (`player.ex:1039-1053`). Intended?
- **Q7 Self-development depth and defects.** The AI never builds workforce buildings: `build_workforce` filters `body.type in [:open, :dome]`, which never matches (`system_ai/actions.ex:261-268`). It never upgrades infrastructure or housing, so planet buildings stay at level 1 (`stellar_system.ex:375`). A fully built system only repairs. Fix these first, or document them as-is? And should the hidden AI profile be documented at all?
- **Q8 Abandon keeps everything.** An abandoned system keeps its buildings, population and AI profile (`stellar_system.ex:271-279`). A player can build a system up, abandon it, then Control it back as a dominion. State it plainly, or is a fix planned?
- **Q9 Edge cases to confirm.**
  - A successful conquest at the System Limit still kills population and damages buildings, but does not take the system (`conquest.ex:140-143`).
  - Administer also raises the Liberate/Administer cost, and the counter never goes down (`player.ex:330-335`).
  - Having exactly the cost in ideology is refused (`player.ex:325`, `:340`).
- **Q10 Vocabulary and slugs.**
  - "Autonomous" (system view, `galaxy.system.properties.autonomous_system`) or "Neutral" (map legend)? I propose autonomous, with the legend's word as a term.
  - Potentials use the UI names Industrial, Scientific and Appeal Potential, not "technological/activity".
  - Approve `colonization` living here (the Navarchs planner links to it) and `siege` living here (Navarchs owns the action rolls).
  - Two leaves for technology and ideology (their `?` buttons already point at those slugs), or one page with an alias?
- **Q11 (defect, not for the manual).** If a faction sector has no uninhabited system, a player's first system can be an autonomous one (`galaxy.ex:146-153`). Then `claim` swaps in the starter bodies but skips `open_system` (`stellar_system.ex:251-254`), so the capital has no infrastructure building. Worth a bug ticket.

---

## Detailed briefs

Common rules for every writer: docs/help-manual.md §3.2 (guide ≤ ~450 words, leaf ≤ ~180), §3.4 style,
§3.5 visuals. A page OWNS only what its brief lists. Everything else is one sentence plus `See [[page]]`,
or plain text when the target page does not exist yet ("See the Navarchs chapter" is not allowed as a
link, so write the thing's name without brackets). Literals that are not constants must carry their
code line in `sources:`.

### Group 1: System outputs

#### `system-outputs` (guide)

- File `priv/help/en/systems/system-outputs.md`, `kind: guide`, title "System outputs", `aliases: [bonus-stacking]`.
- OWNS:
  1. The five outputs a system shows (Production, Credit, Technology, Ideology, Defense) and where each goes. Production stays in the system and builds its queue. Credit, technology and ideology flow into your empire's stock. Your dominions give a share. Defense stays in the system.
  2. How any output is built, in order: base values, then buildings (some scale with a body potential or with population), then Lexes, traditions and agent skills, then [[system-penalties]].
  3. **How bonuses add up** (section, anchor for the alias).
     - Flat bonuses add first.
     - Each percentage bonus adds its share of the flat subtotal. Percentages do not multiply each other.
     - A percentage on a negative subtotal adds 0.
     - One example block, run through `Core.Bonus.apply_bonuses/3` in Docker, e.g. 100 flat + 20 % + 30 % = 150.
     - Blocked by Q1: the answer decides whether a one-sentence edge case about per-value bonuses is added.
  4. One sentence each pointing to the leaves and to [[credit]].
  5. One sentence: the Details tab's other lines (Mobility → [[mobility]]; S.L.S.D., Intelligence, Cybersecurity, ship initial experience) belong to other chapters. Plain text for those.
- Does NOT own: taxes and the mobility bonus (credit, mobility), penalty sizes (system-penalties), any base number (leaves).
- Tables: none.
- Charts: none.
- Screenshot: NEW `system-properties#credit,technology,ideology,defense` (scene `own-system`, recipe R1). Caption names the highlighted outputs. Production lives in a separate box, so the guide points to [[production]] rather than marking it.
- Code: `lib/game/core/bonus.ex`, `lib/data/game/content/bonus-pipeline-in.ex` (order), `lib/game/instance/stellar_system/stellar_system.ex:1272-1392` (compute_bonus, penalties), `:1819-1868` (initial bonuses), `lib/game/instance/player/player.ex:1005-1060` (system and dominion outputs into the player), `front/src/game/components/galaxy/system/Properties.vue`.

#### `production` (leaf, guide: system-outputs)

- File `priv/help/en/systems/production.md`. The `?` in `ProductionBox.vue:22` already targets this slug.
- OWNS:
  1. Base production: {const:system_capital_base_production} in your capital, {const:system_base_production} elsewhere. It shows as "Initial value".
  2. Each tick the first item in the system's queue receives the production. When the item finishes, the rest carries to the next item.
  3. With an empty queue, production is lost. It is not stored (`production_queue.ex:54-57`).
  4. At 0 production the queue stops. Besieged systems make 0 (see [[system-penalties]], [[siege]]).
  5. Edge: production never reaches your empire. It is not part of a dominion's share.
- Does NOT own: queue order, cancel, refund and ETA display (Buildings category, plain text); the station build track (excluded, never mentioned).
- Tables: `{table:buildings_by_output sys_production}`, `{table:bonus_sources sys_production}`. Add `{table:buildings_by_input sys_production}` only if the generator returns rows.
- Screenshot: NEW `production-tooltip#initial,buildings` (R2).
- Code: `stellar_system.ex:1004-1006`, `:1100-1180` (add_production), `:1819-1840`, `production_queue.ex:54-104`, `constant-slow.ex:7-8`, `front/src/game/components/galaxy/system/ProductionBox.vue`.

#### `technology` (leaf, guide: system-outputs)

- File `priv/help/en/systems/technology.md`. The `?` buttons in `Properties.vue:148` and `Bottombar.vue:182` target it.
- OWNS:
  1. A system has no base technology. All of it comes from buildings and other sources.
  2. Your empire gains the sum of your systems' technology plus your dominions' share (see [[dominion-tax-rate]]).
  3. What spends it, one list, plain text: patents, ships, hiring agents.
  4. Edge: a pillage steals technology from your stock (see [[siege]]).
- Tables: `{table:buildings_by_output sys_technology}`, `{table:bonus_sources sys_technology}`.
- Screenshot: R1 `system-properties#technology`.
- Code: `stellar_system.ex:1819-1868` (no tech base), `player.ex:1020-1053`, `player.ex:414-466`, `:572-600` (spending), `loot.ex:121-129`.

#### `ideology` (leaf, guide: system-outputs)

- File `priv/help/en/systems/ideology.md`. Same shape as technology.
- OWNS:
  1. No base ideology.
  2. Empire sum plus dominion share.
  3. Spent on Lexes and policy slots (plain text), hiring agents, and [[administrative-operations]].
  4. Pillage edge.
- Tables: `{table:buildings_by_output sys_ideology}`, `{table:bonus_sources sys_ideology}`.
- Screenshot: R1 `system-properties#ideology`.
- Code: as technology, plus `player.ex:324-350`.

#### `defense` (leaf, guide: system-outputs)

- File `priv/help/en/systems/defense.md`.
- OWNS:
  1. **Moved from `population`:** in a system you own, each whole point of population adds {const:system_base_defense} defense. Dominions and autonomous systems get none (`stellar_system.ex:1827-1830`). Example: 20 workforce × 0.15 = 3.
  2. What it protects against, one sentence: a Navarch's conquest, bombardment and pillage are harder and slower, and cost the attacking fleet more. Plain text to the Navarchs chapter for the rolls.
  3. Edge, one sentence each: defense does nothing against a Siderian's Control (stability defends, see [[dominions]]) or against Erased (Intelligence, plain text).
- Does NOT own: dice, action durations, fleet damage formulas (Navarchs); defense buildings being hit more often (siege).
- Tables: `{table:buildings_by_output sys_defense}`, `{table:bonus_sources sys_defense}`.
- Screenshot: NEW `defense-tooltip#population,buildings` (R3). The buildings mark is optional, since a fresh daily may have no defense building.
- Code: `stellar_system.ex:1827-1850`, `conquest.ex:69`, `:119-137`, `raid.ex:51`, `:96-114`, `loot.ex:51`, `:97-115`, `make_dominion.ex:114-116`, `Properties.vue:10-30`.

### Group 2: Star systems

#### `star-systems` (guide)

- File `priv/help/en/systems/star-systems.md`, `kind: guide`, title "Star systems", `aliases: [system-status, capital, autonomous-system]`, terms include "neutral", "autonomous", "capital".
- OWNS:
  1. **What is in a system**, 2 sentences: a star, several bodies, tiles to build on. Then → [[stellar-bodies]].
  2. **Who holds it**: a hand-written table of the 5 statuses, using `{ui:}`/`{name:}` tokens where strings exist.

     | Status | Can it be colonized / conquered / Controlled / pillaged? |
     | --- | --- |
     | Uninhabitable | none |
     | Uninhabited | colonized only |
     | Autonomous | conquered, pillaged and bombarded, Controlled |
     | Dominion | conquered, pillaged and bombarded, Controlled (see [[dominions]]) |
     | A player's system | conquered, pillaged and bombarded, never Controlled |

     Autonomous systems and dominions develop themselves (→ [[self-development]]). Some systems start autonomous. The number is not given, because sectors override it. One sentence: what you see of another faction's system depends on your visibility of it (plain text).
  3. **Where you can expand**: colonization, conquest and Control only work in a sector your faction controls or next to one (`galaxy.ex:108-123`). One sentence, plain text to sectors.
  4. **Getting systems**: colonize (→ [[colonization]]), conquer (plain text, Navarchs), Control for dominions (→ [[dominions]]). Also: a conquered system keeps its buildings and the population the attack left, and a conquered dominion becomes the conqueror's system (`conquest.ex:143-154`, `stellar_system.ex:235-269`).
  5. **Your capital**: your first system. Outside a daily, every player's first system has the same bodies (`starter_stellar_system_data.ex`). It has a higher base production (→ [[production]]). It stops being your capital when liberated, abandoned or lost, and no other system replaces it. The wording waits on Q2.
  6. **Limits** → [[system-limits]]. **Giving up a system** → [[administrative-operations]]. **Under attack** → [[siege]]. If you lose your last system, you are out of the game (`player/agent.ex:1016-1023`).
- Tables: the status table above (words, no numbers).
- Screenshot: NEW `system-properties#owner,star` (R1).
- Code: `stellar_system.ex:37-83`, `:132-189`, `:235-279`, `galaxy.ex:108-160`, `player/agent.ex:960-1050`, `Properties.vue:32-94`, `State.vue`, `Content.vue:131-136`, `game.json` `system.status.*`, `galaxy.system.properties.*`, `panel.help.legend_*`.

#### `stellar-bodies` (leaf, guide: star-systems)

- File `priv/help/en/systems/stellar-bodies.md`, `aliases: [star-types, tiles, infrastructure-tile, potentials]`, terms: planet, moon, asteroid, gas giant, asteroid belt, Industrial Potential, Scientific Potential, Appeal Potential.
- OWNS:
  1. Body types and what each holds: generated table.
  2. Moons orbit planets and gas giants. Asteroids sit in belts. Gas giants and belts have no tiles.
  3. Tile 1 of every planet is the infrastructure tile. Only the infrastructure building ({name:building.infra_open} / {name:building.infra_dome}) goes there. One sentence plus a link to the building page; the rules that other tiles need it, and that upgrades cap at its level, belong to Buildings.
  4. Potentials: each body rolls three, and buildings scale their output with them. Three generated tables.
  5. Star type sets how many bodies a system has: generated table.
  6. Edge: some game modes change these rolls (plain text, mutators).
- Does NOT own: local population per body (housing), which building fits which body (Buildings), star type frequency (map data, not game code: `gen_prob_factor` is used only by `front/src/utils/editor.js:1226`).
- Tables:
  - NEW `{table:stellar_bodies}`
  - NEW `{table:star_types}`
  - `{table:buildings_by_input body_ind}`, `{table:buildings_by_input body_tec}`, `{table:buildings_by_input body_act}`
- Screenshot: NEW `system-body#potentials,tiles,infrastructure` (R4). The existing `system-bodies` image stays as is for `housing`.
- Code: `lib/data/game/content/stellar-body.ex`, `stellar-system.ex`, `lib/game/instance/stellar_system/stellar_body.ex`, `tile.ex:20-34`, `stellar_system.ex:340-380` (infra tile checks, for the one sentence), `BodiesItem.vue`, `Bodies.vue`.

#### `colonization` (leaf, guide: star-systems)

- File `priv/help/en/systems/colonization.md`. Ownership decision in Q10.
- OWNS:
  1. Only uninhabited systems can be colonized.
  2. Requirements, one list: a Navarch in the system carrying a colonization ship, a free slot under your System Limit ([[system-limits]]), the sector rule ([[star-systems]]), no siege.
  3. It takes {duration:colonization_time}. It can be intercepted (plain text).
  4. On success the ship is used up. The new colony gets a level-1 infrastructure building on its planet with the most tiles (habitable planets first, else barren) and {const:system_starting_population} population. See [[population]].
  5. Edge: if a requirement fails at the end (slot gone, system taken), it is cancelled with only a notification (`colonization.ex:116-120`).
- Tables: none.
- Screenshot: none on `own-system`. Later NEW `uninhabited-state#status` on scene `empire` (R8).
- Code: `lib/game/instance/character/actions/colonization.ex`, `stellar_system.ex:251-254`, `:1396-1425`, `player.ex:778-784`, `constant-slow.ex:47`.

#### `system-limits` (leaf, guide: star-systems)

- File `priv/help/en/systems/system-limits.md`, title "System and dominion limits", `aliases: [system-limit, dominion-limit]`.
- OWNS:
  1. System Limit starts at 1 (`player.ex:1005-1011` literal) and Dominion Limit at 0 (no initial bonus). Lexes raise them (tables).
  2. At the limit, colonization, conquest and Control are refused or cancelled. Administer needs a free system slot. Liberate needs a free dominion slot.
  3. Edge: you cannot unslot a Lex if that would put you over a limit (`player.ex:539-540`).
  4. Edge: a successful conquest at the limit still hits the system but does not take it (Q9).
- Tables: `{table:bonus_sources player_system}`, `{table:bonus_sources player_dominion}`.
- Screenshot: NEW `bottombar-limits#systems,dominions` (R5).
- Code: `player.ex:158-164`, `:207-275`, `:525-545`, `:776-784`, `:1005-1016`, `doctrine-slow.ex:15-180`, `player/agent.ex:133-182`, `Bottombar.vue:125-155`.

#### `administrative-operations` (leaf, guide: star-systems)

- File `priv/help/en/systems/administrative-operations.md`, title `{ui:system.system_state_title}` (literal "Administrative Operations" in the title field), `aliases: [liberate, administer, abandon]`.
- OWNS:
  1. The three operations, in UI words.
     - Liberate turns your system into your dominion.
     - Administer turns your dominion back into a system.
     - Abandon (system or dominion) makes it autonomous.
  2. Cost: Liberate and Administer share one price, {const:transform_initial_cost} + {const:transform_additional_cost} per operation you have done before. Example block: the 4th costs 10 000 + 3 × 1 000 = 13 000 ideology. Abandon costs {const:abandonment_cost} ideology.
  3. You need more ideology than the cost (Q9).
  4. Requirements: not your last system (Liberate, Abandon), a free slot (see [[system-limits]]).
  5. What stays and what goes.
     - Buildings and population stay.
     - The governor is removed, and ship orders for your Navarchs in that system are cleared (`player/agent.ex:1397-1418`).
     - Your capital stops being your capital (Q2).
     - An abandoned system keeps developing by itself ([[self-development]]), and anyone can then Control or conquer it (Q8 wording).
- Tables: none (the formula is one example line).
- Screenshot: NEW `system-state#status,liberate,abandon` (R6). On a daily's only system the buttons are dashed because it is the last system, and the caption says so. Later `dominion-state#administer` from scene `empire` (R9).
- Code: `State.vue`, `player/agent.ex:133-240`, `:1397-1418`, `player.ex:324-350`, `:1289-1292`, `stellar_system.ex:235-279`, `constant-slow.ex:32-34`.

#### `siege` (leaf, guide: star-systems)

- File `priv/help/en/systems/siege.md`, `aliases: [besieged, raid-potential, pillage-yield]` (final name per Q4).
- OWNS (system side only):
  1. A Navarch's conquest, bombardment or pillage puts the system under siege. It ends when the action resolves or the besieging fleet leaves (`stellar_system.ex:951-983`, `stellar_system/agent.ex:259-280`).
  2. While besieged:
     - production is 0 (see [[system-penalties]])
     - no new building orders (`stellar_system.ex:346`)
     - no colonization
     - no second conquest, bombardment or pillage
     - a Siderian's Control is not blocked
  3. When it ends, the attack can kill population and damage buildings. The amounts per outcome belong to the Navarch actions (plain text). Which buildings can be hit:
     - finished, non-infrastructure buildings, including ones being upgraded
     - defense buildings are twice as likely to be picked (`stellar_system.ex:1695-1699`)
     - an upgrade in progress is cancelled and its credits refunded
     - damaged buildings: see Buildings (plain text)
  4. **Pillage yield** (section).
     - A hidden value, maximum 100 (`stellar_system.ex:148-150`, `:936-949`).
     - It refills by {rate:system_raid_potential_growth|pillage yield}.
     - Each siege that ends removes {const:raid_potential_impact} (Q4).
     - A pillage steals a share of the system's credit, technology and ideology output that scales with it. Example line: at 55 the haul is 55 % of a full one. Multipliers per outcome: Navarchs chapter.
     - Refill example: {duration:180} to recover one siege.
- Tables: none.
- Screenshot: none now (a besieged view needs an enemy fleet in the system; out of scope for both scenes).
- Code: `siege.ex`, `stellar_system.ex:281-331`, `:936-983`, `:1657-1730`, `stellar_system/agent.ex:190-230`, `:259-310`, `conquest.ex`, `raid.ex`, `loot.ex` (finish), `colonization.ex:39`.

### Group 3: Dominions

#### `dominions` (guide)

- File `priv/help/en/dominions/dominions.md` (new category `dominions`, index page generated), `kind: guide`, title "Dominions".
- OWNS:
  1. A dominion is a system another player's population runs for you. It builds by itself (→ [[self-development]]) and pays you a share of its credit, technology and ideology (→ [[dominion-tax-rate]]).
  2. What you can and cannot do. You cannot order buildings or ships there (`player.ex:370-380`, orders look only in your systems). Your Lexes apply to it (`player/agent.ex:513-520`). It gets no defense from population (see [[defense]]). It counts for System points (see [[population-class]]).
  3. Getting one: a Siderian's Control on an autonomous system or someone else's dominion, never a player's system. Needs a free slot ([[system-limits]]) and the sector rule ([[star-systems]]). The system's stability defends it (`make_dominion.ex:114-116`; roll details plain text, Siderians). Or Liberate your own system ([[administrative-operations]]). Q3 decides the faction-mate sentence.
  4. Losing one: another Siderian's Control, a Navarch's conquest (it becomes their system), or Abandon.
  5. Edge: a Siderian's Control is never intercepted by Navarchs (§8.2 verdict). One sentence.
- Tables: none.
- Screenshot: NEW `dominion-properties#owner` (R7, scene `empire`). Until the scene exists, the page ships without a shot and the capture agent adds it later (a page edit, so phase 2 again).
- Code: `make_dominion.ex`, `player/agent.ex:133-240`, `:993-1050`, `player.ex:207-275`, `:1005-1053`, `stellar_system.ex:912-931`, `:1827-1830`, `victory/victory.ex:87-110`, `State.vue`, `Properties.vue:62-73`, `game.json` `system.status.inhabited_dominion`, `own_inhabited_dominion`.

#### `dominion-tax-rate` (leaf, guide: dominions)

- File `priv/help/en/dominions/dominion-tax-rate.md`, title `{name:bonus_pipeline_out.dominion_rate}`, terms: dominion tax rate, dominions tax rate, dominion income.
- OWNS:
  1. You receive the rate × each dominion's credit, technology and ideology output, measured after the dominion's own penalties. Example line: `{rate:500|credits} × 30 % = {rate:150|credits}`.
  2. The base rate is 30 % (`player.ex:1012-1015` literal). Lexes and traditions raise it (table).
  3. The dominion's production and defense are not shared.
  4. The income shows as a "Dominions" line in your empire's breakdowns.
  5. Edge: a dominion with negative credit lowers your income (Q6).
- Tables: `{table:bonus_sources dominion_rate}` (after D4).
- Screenshot: NEW `empire-credit-tooltip#dominions` (R10, scene `empire`).
- Code: `player.ex:1005-1060`, `lib/data/game/content/faction.ex:50`, `doctrine-slow.ex:130-180`, `Bottombar.vue:150-200`, `game.json` `resource-detail.type.dominion`.
- Existing page change: `credit.md` "Your income" links "a share of your dominions' credits" to this page.

#### `self-development` (leaf, guide: dominions)

- File `priv/help/en/dominions/self-development.md`, `aliases: [autonomous-development]`. Scope depends on Q7.
- OWNS:
  1. Autonomous systems and dominions build by themselves. Every {duration:50} (`stellar_system.ex:10`, `:912-931` literal), each system makes at most one building decision, starting at a random point in that cycle.
  2. Order of priority: wait while its queue is busy or while population is still growing into free housing, repair, missing infrastructure, stability when low, then a random building. Verify against `priv/data/system_ai/behavior_tree.json`, not the memory note.
  3. The random building follows a hidden profile (production, credit, technology, ideology or defense), picked when the galaxy is created. Its favourite category is 4 times as likely as each other (`system_ai/helper.ex:24-35`).
  4. The profile never changes, including after the system is abandoned or changes owner.
  5. Edges (per Q7): what it never builds or upgrades, and that a fully built system only repairs.
- Tables: none (5 profiles, one sentence).
- Screenshot: none.
- Code: `lib/game/system_ai/dominion.ex`, `helper.ex`, `actions.ex`, `priv/data/system_ai/behavior_tree.json`, `stellar_system.ex:152-161`, `:912-931`, `:1807-1817`.

---

## Developer specs

**D1.** Answers to Q1-Q3 recorded in docs/help-manual.md §8.1 or §8.3, as the pilot verdicts were.

**D2. `stellar_bodies` table** (no args), in `RC.Help.Tables`, data from `Data.Game.StellarBody`
(`lib/data/game/content/stellar-body.ex`; add a `Data.stellar_bodies/1` accessor in `lib/rc/help/data.ex`).
One row per body key in content order. Columns:

- Body: `data_name(["stellar_body", key, "name"])`
- Tiles: `gen_tiles_number` as "6–8", "0" when `0..0`
- Orbiting bodies: `gen_subbody_number` range + the singular name of `gen_subbody_types`, "—" for secondaries
- Industrial / Scientific / Appeal Potential: `gen_ind/tec/act_factor_number` ranges, "—" for `0..0`; headers via `pipeline_in_name(body_ind|body_tec|body_act)`

Mutators excluded (as elsewhere). Test: row count 6, habitable planet "6–8".

**D3. `star_types` table** (no args), data from `Data.Game.StellarSystem`
(`lib/data/game/content/stellar-system.ex`). Columns: Star type (`data_name(["stellar_system", key, "name"])`),
Bodies (`gen_body_number` as "4–6"). Sorted by content order. No frequency column: `gen_prob_factor` is used
only by the map editor.

**D4. Formatter.** In `RC.Help.Format.bonus/3`, a `from: :direct` bonus whose `to` is `:dominion_rate` renders
with `pct/1` (`+20 % Dominion Tax Rate`). Check that `bonus_sources player_system|player_dominion` render as
`+1 System Limit` and do not list mutators or faction trees.

**D5. Recipes on `own-system`** (the capture agent can add these; each needs a new `prepare` in `capture.js`):

| # | Recipe | Selector / prepare | Marks |
| --- | --- | --- | --- |
| R1 | `system-properties` | `.system-properties`, no prepare | `defense` (`.box-aside.left`), `owner` (`.owner`), `star` (`.star`), `credit`/`technology`/`ideology` (`.yields .yield-box` nth 0/1/2) |
| R2 | `production-tooltip` | new `pin-production-popover` (trigger in `ProductionBox.vue`) | `initial` (row "Initial value"), `buildings` (optional) |
| R3 | `defense-tooltip` | new `hover-defense-popover` (`.box-aside.left` v-popover, hover not click) | `population` (row "Population"), `buildings` (optional) |
| R4 | `system-body` | the inhabited planet's `.system-content-group` | `potentials` (`.body-info-potentials`), `tiles` (`.body-tiles`), `infrastructure` (first `.tile`) |
| R5 | `bottombar-limits` | Bottombar systems + dominions `navbar-maxed-value` union | `systems`, `dominions` |
| R6 | `system-state` | new `open-state-tab` (third `.system-tab-item`) | `status` (`.system-content-group-info`), `liberate`, `abandon` (the two `.button`s) |

**D6. Scene `empire`** in `capture.js`.

1. Boot a fixture instance with `POST /api/harness/dev/agent-fixture` (grant resources, cheats on), as `e2e/` does.
2. Add a dev-harness step (new endpoint, or an option on the fixture) that for the fixture player:
   - raises System and Dominion Limits (slot the `system_1` / `dominion_*` Lexes, or add bonuses)
   - claims a second system (`{:claim_system, id}`)
   - claims an autonomous system as a dominion (`{:claim_dominion, id}`)
   - returns the ids of one dominion, one autonomous system and one uninhabited system
   - optional: pushes an `add_happiness_penalty` on one own system, so the pilot-2 backlog shots `system-population-status` and the Destabilize tooltip line become capturable
3. Open systems through `game/openSystem` as `own-system` does.

Recipes this unlocks:

| # | Recipe | View | Marks |
| --- | --- | --- | --- |
| R7 | `dominion-properties` | dominion's Properties box | `owner` |
| R8 | `uninhabited-state` | uninhabited system, bodies+state tab | `status` |
| R9 | `dominion-state` | dominion, state tab | `administer`, `abandon` |
| R10 | `empire-credit-tooltip` | Bottombar credit popover pinned | `systems`, `dominions` (the "Systems" and "Dominions" groups) |

**D7. Locale fixes** (`front/src/locales/en|fr/game.json`, as in §9):
- `system.status.inhabited_player`: "It can pillaged" → "It can be pillaged".
- `system.status.uninhabited`: "*uninhabited**" → "**uninhabited**" (inventory gap 5, still open).
- `system.status.inhabited_neutral` / `inhabited_dominion`: "subjugated by a Siderian" → "taken by a Siderian's Control", matching the action name `galaxy.system.actions.make_dominion` = "Control".
- `system.status.own_inhabited_dominion`: missing final period.

---

## Formula and topic owners

"Owner" is the only page that states the rule. Every other page links to it or says one sentence.

| Formula / rule | Owner | Code | Notes |
| --- | --- | --- | --- |
| Population growth, housing target, size factor | `population` (existing) | `stellar_system.ex:1236-1270` | unchanged |
| Starting population of a new colony | `population` (existing) | `:1422` | colonization links |
| Local population per body | `housing` (existing) | `:1446-1533` | stellar-bodies links |
| Stability base, per-population cost, Destabilize decay | `stability` (existing) | `:1832`, `:985-1002` | gains one bullet linking dominions (stability defends against Control) |
| Workforce, over-mobilization | `workforce` (existing) | `:1332-1337` | unchanged |
| Penalties: which outputs, how they combine, negative not reduced | `system-penalties` (existing) | `:12-30`, `:1332-1392` | besieged row links siege |
| Taxes | `credit` (existing) | `:1833` | |
| Mobility bonus, negative credit skips it | `mobility` (existing) | `:1834`, `bonus.ex:21` | wording waits on Q1; add `See [[bonus-stacking]]` |
| Empire income = systems + dominion share − salaries − upkeep | `credit` (existing) | `player.ex:1005-1060` | the share's formula lives in dominion-tax-rate |
| Flat, then percentages of the flat subtotal, no compounding, percentage on negative = 0 | `system-outputs` §bonuses | `bonus.ex` | Q1 |
| Base production 40 / 100 capital | `production` | `:1822-1825` | star-systems capital section links |
| Production feeds the queue, carries over, lost when empty | `production` | `:1004-1006`, `production_queue.ex:54-68` | queue ordering and ETA: Buildings |
| No base technology or ideology, empire sum | `technology`, `ideology` | `:1819-1868`, `player.ex:1020-1053` | |
| Population defense 0.15 per workforce, owned systems only | `defense` | `:1827-1830` | **moves out of `population`**, which keeps one pointer line |
| Defense in Navarch rolls and fleet damage | Navarchs (future) | `conquest.ex:69`, `:119-137` etc. | defense: one sentence, plain text |
| Stability defends against Control, `max(stability, 0)` | Siderians (future) | `make_dominion.ex:114-116` | dominions: one sentence |
| Body types, tile counts, orbiting bodies, potential ranges | `stellar-bodies` | `stellar-body.ex` | NEW table D2 |
| Star type → body count | `stellar-bodies` | `stellar-system.ex` | NEW table D3 |
| Tile 1 = infrastructure tile | `stellar-bodies` | `tile.ex:20-34` | the "needs infra" and "upgrade cap" rules are Buildings (`stellar_system.ex:356-376`) |
| Five statuses and what each allows | `star-systems` | `stellar_system.ex:43`, action `start/2` checks | |
| Sector rule (own or adjacent sector) | `star-systems` | `galaxy.ex:108-123` | sector ownership: Galaxy (future) |
| Capital: first system, lost for good | `star-systems` | `:235-279` | Q2 |
| Fixed starter layout outside dailies | `star-systems` | `stellar_system.ex:246-249`, `starter_stellar_system_data.ex` | one sentence |
| Colonization requirements, duration, colony start | `colonization` | `colonization.ex`, `:1396-1425` | interception: Navarchs |
| Conquered system keeps buildings and population; dominion → system | `star-systems` | `conquest.ex:143-154`, `:235-269` | damage numbers: Navarchs |
| System Limit 1, Dominion Limit 0, what they block, Lex unslot guard | `system-limits` | `player.ex:207-275`, `:539-540`, `:1005-1011` | |
| Liberate/Administer cost, Abandon cost, requirements, what stays | `administrative-operations` | `player.ex:324-350`, `:1289-1292`, `player/agent.ex:133-240` | |
| Siege: blocked actions, how it ends | `siege` | `:281-295`, `:346`, `:951-983` | besieged penalty stays on system-penalties |
| Which buildings a siege damages (defense ×2, upgrade refund) | `siege` | `:1657-1750` | damaged-building effects and repair: Buildings |
| Pillage yield: max 100, refill, −45 per siege, scales the haul | `siege` | `:148-150`, `:297-331`, `:936-949`, `loot.ex:121-124` | per-outcome multipliers: Navarchs (Q4, Q5) |
| Population lost and buildings damaged per outcome | Navarchs (future) | `conquest.ex:123-129`, `raid.ex:100-106`, `loot.ex:101-107` | numbers are hard-coded; the Navarchs planner needs them extracted for a generated table |
| Dominion definition, restrictions, acquisition and loss | `dominions` | see brief | |
| Dominion share = rate × output, base 30 %, sources | `dominion-tax-rate` | `player.ex:1012-1053` | Q6 |
| Self-development cadence, priorities, profile | `self-development` | `system_ai/*`, `:912-931` | Q7 |
| System points for dominions | `population-class` (existing) | `victory.ex:87-110` | dominions links |
| Visibility levels | Galaxy (future) | `faction/stellar_system.ex:60-82` | star-systems: one sentence |
| S.L.S.D., Intelligence, Cybersecurity, ship initial XP | Galaxy, Erased, Ships (future) | | system-outputs: one sentence |

## Linking plan for existing pages

Each edit sends the page back through phase 2 (§5.2). Links only, except the moved defense rule.

| Page | Change |
| --- | --- |
| `population` | Replace the defense bullet with "In a system you own, population adds defense. See [[defense]]." Link "A new colony" → [[colonization]]. Link the closing Navarch sentence → [[siege]]. Add `defense`, `colonization` to `related`. |
| `credit` | "a share of your dominions' credits" → [[dominion-tax-rate]]. Intro links [[system-outputs]]. Add both to `related`. |
| `mobility` | After the negative-credit sentence: "See [[bonus-stacking]]." Apply the Q1 decision. |
| `system-penalties` | "after every bonus is counted" → [[bonus-stacking]]. Besieged row "a Navarch is conquering, bombarding or pillaging" → [[siege]]. Add `production`, `defense` to `related`. (Whether `[[slug\|{name:…}]]` compiles is untested; if not, keep the list and add a related entry.) |
| `stability` | One bullet under "What it does": "It defends the system against a Siderian's Control. See [[dominions]]." |
| `population-class` | "every system and dominion" → [[dominions\|dominion]]. |
| `housing` | "planets" in the first section → [[stellar-bodies\|planets]]. |
| `workforce` | "planet, moon or asteroid" → [[stellar-bodies]]. |
| `galaxy/map-legend` | Later (Galaxy run): "Neutral" row → [[star-systems]]. |

## Batch plan and estimates

Pilot 2 cost 91 agents for 10 pages (~9 per page, revisions and consistency included). Short table-driven
leaves ran cheaper (accepted round 0: ~4-5 agents). Guides and leaves with edge cases ran dearer (~12-15).

| Order | Group (1 writer) | Pages | Needs first | Estimate |
| --- | --- | --- | --- | --- |
| 1 | System outputs | system-outputs, production, technology, ideology, defense | Q1 answered; capture prepares R1-R3 (capture agent) | ~40 agents |
| 1b | Re-review of existing pages from the linking plan | population, credit, mobility, system-penalties, stability, population-class, housing, workforce | runs after groups 1-3 land (one pass) | ~35 (8 × ~4-5) |
| 2 | Star systems | star-systems, stellar-bodies, colonization, system-limits, administrative-operations, siege | Q2, Q3, Q4, Q8-Q10 answered; D2, D3 generators; R1, R4-R6 (capture agent) | ~55 agents |
| 3 | Dominions | dominions, dominion-tax-rate, self-development | Q3, Q5-Q7 answered; D4 formatter; D6 scene for shots (can write first, add shots after) | ~30 agents, +~10 when shots are added later |

Total ≈ 160-170 agents. Groups 1 and 2 can run in parallel once their questions are answered. Group 3
goes last, because it links to `administrative-operations`, `system-limits`, `defense` and `siege`, and its
consistency pass should see them. The locale fixes (D7) land before group 2, so writers do not quote the
typos.

# Patents and lexes: guide map

Planner output, phase 0 (docs/help-manual.md §3.2, §5.2 v3). Written 2026-09-26 on branch
`claude/player-manual-docs-next-03a45b` (base 7b8f0c0). Legacy values unless a speed is named. Line references
are to that commit. Every rule marked "run" was executed in the Docker `rc` container against the real content
of all three speeds (`tmp/help-review/patents/dump.exs` → `dump.txt`, `tmp/help-review/patents/lex_patent_verify_test.exs`, run from `test/tmp/`, →
`verify.txt`; both scratch, not committed).

Speeds: L = Legacy (`:slow`), T = Tactic (`:medium`), F = Flash (`:fast`).

The branch was fast-forwarded to master 5b27317 on 2026-09-29. `player.ex` line numbers after line 237 moved
by about +21 (Wave Defense additions); nothing else cited here changed. Writers cite current lines in
`sources:`.

## Human answers (2026-09-30, after reading the catalog slots)

- **Mobility credits (gameplay fix).** The mobility credit line ignored percentage mobility bonuses (a lex such
  as Trade Secrets, A.R.K.'s tradition) unless an unrelated order-30 `:add` (Monolith, Reflect District,
  Business Arch) refreshed the bonus pipeline's snapshot. The user chose to fix the game: the line is now an
  `:add` that reads current mobility (`stellar_system.ex` collect_initial_bonuses,
  `test/game/instance/stellar_system/mobility_credit_test.exs`). The Monolith does nothing for mobility; pages
  never say it does. Percentages only matter in a system that has mobility (buildings, Freedom of Movement).
- **Side uses go last.** A patent's or lex's purpose is what it unlocks or does. Daily challenge races are listed
  in a generated "Also used in" section at the end of the page (`RC.Help.Catalog.also_used_md/3`), never in the
  prose slot. Buildings follow the same rule (Floating Gardens).
- **Slots state the effect plainly.** No comparisons that read as a second effect (Centralization of Power no
  longer says "as much again as its taxes"), and no edge cases that cannot happen in play (a system's own
  credits are never below zero when these bonuses apply).

## Human answers (2026-09-29, override the open questions in section 1)

- **V1:** approved, including D8: rename the in-game strings that say "policy" or "Doctrines".
- **Q1:** a bug. A lex must never be active twice. Fixed in code (D4a).
- **Q2:** a bug (the user found it too). Fix the display (D4b).
- **Q3:** the `_early` / `_mid` / `_late` names are left over from an old design session. Ignore them for
  now: pages state that all four traditions are always on.
- **Q4-Q7:** defaults stand (no answer needed).
- **New page asked for: cost scaling.** A short page that explains how prices grow, with examples:
  `price-scaling` (section 3). It owns the patent and lex price formulas and the lex slot price. The two guides
  keep one or two sentences each and link to it.
- **The lock time needs a table or graph on the Lexes guide**, because it matters. The guide's "Changing your
  active lexes" section gets `{chart:lex_change_waits}` (D3b). `lex-changes` keeps the exact table.
- **The game should say how long the lock would be if you applied now.** D9: the lex panel shows the wait
  that applying now would start, next to the apply stamp.

## Human answers already given (2026-09-26)

- **A page for a key that is missing at the viewed speed** still exists and says so, with a way out: "The game
  mode you're viewing, Flash, doesn't have this patent. Switch to Legacy." Most readers only land there from a
  link, so a plain message plus switch links is enough. Applies to every catalog kind, buildings included (D5).
- **Vocabulary:** the doctrine/policy split is unnecessary for players. Drop "doctrine" from everything a player
  reads. Section 1, V1 proposes the exact words.
- **The lex-change cooldown keeps growing for the whole game.** Intended. Pages state it as a rule.
- **Cultures:** no page (see section 1, "Out of scope").
- **`[INACTIF]` / `[UNAVAILABLE]` keys:** none exist. The filter in `lib/mix/tasks/patent_table.ex:44` and
  `lex_table.ex:25` matches nothing in today's locales, so every content key gets a page.
- **Excluded:** faction trees, faction patents and lexes, laws, government, everything in the faction-government
  beta.

---

## 1. Summary for approval

### Guide tree

6 new mechanic pages in a new directory `priv/help/en/research/` (the Bottombar's two buttons, Patents and Lex):

```
research/patents        GUIDE  What a patent is, the tree and its branches, buying one, the price increase,
                               what patents unlock, the patent panel, all patents (generated list)
research/lexes          GUIDE  What a lex is, buying one, active lexes and lex slots, the lex panel,
                               limits come from active lexes, all lexes (generated list)
  research/lex-changes  leaf   Applying a new set of active lexes: the wait before the next change grows with
                               every change and never resets; what a change can't do (go over a limit)
  research/agent-limits leaf   Navarch, Erased and Siderian limits: start at 0, come from active lexes,
                               what the limit blocks, sources table
research/price-scaling  mechanic (no guide)  How patent, lex and lex slot prices grow, with worked examples
                               at the viewed speed (added 2026-09-29 at the user's request)
research/traditions     mechanic (no guide)  Every faction's four traditions: always on, for every member,
                               same at every speed; generated table of all 20
```

Why this split:

- **Patents is one guide with no leaves.** Every patent rule is one to four sentences (rule 3.2.4): the ancestor,
  the technology price, the price increase, instant and permanent, no refund. The detail lives in the 65 catalog
  pages, which print "Part of the Patents guide" the way building pages do.
- **Lexes has two leaves.** The change cooldown has a formula, a per-speed table and three edge cases a player
  would otherwise report as bugs, so it is a leaf. Lex slots are one price rule and a table, so they are a
  section of the guide with the alias `lex-slots`.
- **Agent limits live here, not in the Agents chapter.** Active lexes are the only way to raise them, they start
  at 0, and "why can't I hire an agent" is the first question a new player hits. `system-limits` (Systems
  chapter) already owns the System and Dominion Limits and stays the owner. `agent-limits` is its sibling for the
  three agent limits. The Agents chapter will link here.
- **Traditions get one page, not 20 catalog pages.** A tradition is one bonus with a name. A table with one row
  per tradition, grouped by faction with an anchor per faction, answers everything. The Factions chapter links
  to `traditions#<faction>`.

Directory name `research/`: patents and lexes share a panel style and the Bottombar, and the category needs one
folder. Slugs do not include the folder, so the name only matters for authors.

### Catalog plan

- **65 patent pages**, `priv/help/en/patent/<key>.md`, slug `patent/<key>` (the slug `PatentCard.vue:12`
  already opens). L and T have the same 64 keys. F has 39: 38 shared plus `merge_fighter_corvette`. The 26
  L/T-only keys and the one F-only key get the "not in this mode" message at the other speeds (D5).
- **61 lex pages**, `priv/help/en/lex/<key>.md`, slug `lex/<key>` (`DoctrineCard.vue:12`). L and T have all 61.
  F has 39 of them, with different branches, costs and ancestors.
- Locale keys with no content row get no page: `fighter_1`, `frigate_1`, `infra_orbital_1`, `orbital_hypergate`.
- The shell (D1, D2) carries everything that differs per speed. Prose slots: 6 non-empty (section 4), the rest
  empty.

### Vocabulary (V1, needs a yes)

The UI already calls the thing a "Lex" and the chosen set "Policies". "Doctrine" shows up for players in exactly
one string (`portal.json` `page.profile_detail.icon_category.doctrine` = "Doctrines"). Proposal:

| Concept | Manual word | Internal name | Today's UI words |
| --- | --- | --- | --- |
| A lex you bought | **lex** (plural **lexes**), lowercase in running text like "patent" | doctrine | Lex, lexes, Purchased Lexes |
| A bought lex that is switched on | **active lex** | policy | Active lexes, policy, Policies |
| A place for one active lex | **lex slot** | `max_policies` | policy slot, "+1 slot" |
| Switching the set of active lexes | **change your active lexes** | `update_policies` | "Apply these new policies" |

- Pages never say "doctrine" or "policy". Where a page must name the panel's label "Policies", it quotes it with
  `{ui:minipanel.doctrine.policies_title}` so it follows any rename.
- **D8 (optional, recommended):** rename the en/fr UI strings that say "policy" to the words above (about ten
  strings, list in section 6), and "Doctrines" → "Lexes" on the profile icon picker. If you'd rather keep
  "policy" in the UI, the manual still works: it will explain "active lex" once as "what the lex panel calls
  a policy".
- Existing pages write "Lex" with a capital (`ideology`, `technology`, `system-limits`, `dominions`, `mobility`,
  `system-outputs`). The linking run lowercases them (section 8).
- Name clash to watch: the lex `upgrade_xp` is called "Navarch Tradition" in the UI. A tradition is also a
  faction bonus. Pages that link it always use its full name and link it, so the reader never takes it for a
  faction tradition.

### A developer builds first

1. **D1 patent shell** and **D2 lex shell**: facts block, in-game card, unlocks or effects, path from the root,
   "leads to" list. Needed by the guides' "all patents / all lexes" sections and the catalog run.
2. **D3 tables**: `patents_list`, `lexes_list`, `lex_slot_costs`, `lex_change_waits`, `traditions`.
3. **D4 bug fixes** from Q1 and Q2 (server refuses a repeated lex; the patent panel shows the real price under
   Open Science and Lost Sciences).
4. **D5 "not in this mode" message** with switch links, for buildings, patents and lexes.
5. **D6 capture scenes** for the patent panel, lex panel and both cards (writers can work without them, as in
   the Buildings run).
6. **D7 locale fixes**: `cooldown_not_unlock` has no error string; the news line "first to bring fifteen lexes
   into law" counts bought lexes, not active ones.
7. **D8 vocabulary renames** if V1 is approved.

### Open questions

- **Q1 A repeated lex counts twice (defect, run).** `update_policies` checks that each key is owned but never
  that the keys are distinct (`player.ex:528-533`). `[agent, agent]` is accepted, takes two slots and applies
  the bonus twice: Navarch Limit 4 instead of 2 at Legacy (`verify.txt`). The lex panel can't produce it, so
  only a hand-crafted client reaches it. **Default:** fix in code (D4a): the server refuses a list with a
  repeated lex. Pages say nothing about it.
- **Q2 The patent panel shows the wrong price under Open Science or Lost Sciences.** The server multiplies the
  price by 0.5 or 2 (`player.ex:455-456`, `mutator.ex:817-834`). The panel header and the card compute
  `cost × (1 + factor)` without the mutator (`PatentMiniPanel.vue:183-185`, `PatentCard.vue:164`). With Lost
  Sciences a player sees 50 and pays 100. **Default:** fix the display (D4b). The patents guide states the
  real price, and says in one sentence that those two game modifiers halve or double it (plain text until the
  Game modes chapter writes the modifier pages).
- **Q3 Traditions are all on from the first tick.** Each faction's four tradition keys are named `_early`,
  `_mid`, `_late` and `_malus` (`faction.ex:11-28`), which reads as if they were meant to unlock over the game.
  The code applies all four from the start (`player.ex:1090-1100`; run: all four reasons present on a fresh
  player at every speed), and the faction panel lists all four with no timing (`Overall.vue:16-32`). Intended?
  **Default:** yes, state "always on".
- **Q4 Tactic's price increase is steep.** Each patent you own adds 30% of the base price to every later patent
  at Tactic, against 5% at Legacy and 20% at Flash (`constant-medium.ex:28-29`). The same for lexes. At Tactic
  the 11th patent costs four times its base price. FYI for balance; pages show each speed's number from
  `{const:}` tokens either way. **Default:** document as is.
- **Q5 An apply that changes nothing still costs a change (FYI).** The server does not compare the old and new
  sets: re-applying the same set, or applying an empty set, is accepted and makes the next wait longer
  (`player.ex:551-560`; run). The panel blocks an unchanged set (`DoctrineMiniPanel.vue:355`), but "Remove all
  lexes" then applying does count. **Default:** `lex-changes` says "Every change you apply counts, even one that
  only removes lexes." No code change.
- **Q6 Agent limits owned here.** See the guide tree. **Default:** approve.
- **Q7 Flash trees are arranged differently.** Flash patents use two branches (Economic, Military) instead of
  four, and Flash lexes use two (Expansion, Characters) instead of four, with different ancestors and costs.
  Like the Buildings Q8, pages show each speed's content as it is. **Default:** no remark beyond the generated
  shell.

### Advanced mechanics (rule 19)

None. There is no hidden roll or AI choice here. The order in which bonuses stack is owned by `system-outputs`.

### Out of scope, and where it goes

- **Cultures** (`culture.ex`): an internal name set per faction. Players see it only as the "origin" line on an
  agent's card (`CharacterCard.vue:86`, `:205-207`, e.g. "Tetrarchian"), and it picks agent names, portraits
  and place names. No gameplay effect. At most one sentence in the Agents chapter.
- **Mutators** that mention patents or lexes: `pioneer_charter`, `restless_senate` ("Lex influence", which
  matches no mechanic) and `doctrine_of_the_masses` (about Siderian skills despite the name) are all
  `implemented: false` (`mutator.ex:575-593`, `677-685`). Game modes chapter.
- **Daily race "Destroyer's Blueprint"** (buy the Armoring patent `capital_1`, `lib/daily/objective.ex:126-136`):
  one sentence on the catalog page (slot), owned by the Game modes chapter later.
- **Agent hiring, the market and the deck:** Agents chapter. `agent-limits` owns only the limit.

---

## 2. Refreshed facts

"Inventory" means `docs/help-manual-inventory.md` §A.3. The code crawl for this map re-checked every row; its
full report, with the front-end details, is `code-crawl.md` next to this file.

| Rule | Code | Verified | Differs from the inventory |
| --- | --- | --- | --- |
| Patent check order: unknown, already owned, ancestor not owned (`:patent_locked`), not enough technology. Exactly the price is enough | `player.ex:440-471` | run: 49 refused, 50 accepted for a 50 patent | none |
| Patent price = base × (1 + patents owned × `patent_level_price_increase`) × modifier. Increase 5% L, 30% T, 20% F. Every owned patent counts, upgrade and unit-size patents included. Not rounded | `player.ex:455-456`, `constant-*.ex:28` | run: L Assembly Lines (300) as 2nd patent = 315, with 10 owned = 450; T 1st→2nd ×1.3; F 360 / 900 | T and F values new |
| Open Science ×0.5, Lost Sciences ×2 on patent prices only; they stack | `mutator.ex:605-613`, `667-675`, `817-834` | code | inventory cited 820-824 |
| A patent works at once, forever. No refund, no cooldown, no news | `player.ex:460-467`, `agent.ex:490-510` | code | no-news new |
| Building orders need the level's patent; ship orders need the ship's patent and those of every smaller unit of the same model | `player.ex:383-385`, `416-426` | code (owned by Buildings / Ships) | none |
| Lex check order: unknown, already owned, ancestor not owned (`:doctrine_locked`), not enough ideology | `player.ex:473-501` | run | none |
| Lex price = base × (1 + lexes owned × `doctrine_level_price_increase`). 5% L, 30% T, 20% F. Patents owned don't count, and no modifier applies | `player.ex:485` | run: L Reaction Force (50) as 2nd lex = 52.5; a player owning 1 patent pays 50 for the first lex | separate counters confirmed |
| Both trees have exactly one ancestor per node (the lex typespec `[atom()]` is wrong) | `doctrine.ex:11`, `:59`, `player.ex:448`, `:481` | data dump | new |
| A bought lex does nothing until it is active | `player.ex:1076-1088` | run: Navarch Limit 0 after buying Age of Exploration, 2 after activating | none |
| Lex slots: you start with 1. The next slot costs initial × 2^(slots − 1) ideology, capped at a maximum price. The number of slots has no cap | `player.ex:503-521`, `:155`, `constant-*.ex:24-25` | run: L 200, 400 … 51 200, then 100 000 from the 11th slot on; T 50 … 25 600, then 50 000; F 200 … 25 600, then 50 000 | "no cap on slots" and plateau new |
| Change check order: more lexes than slots, wait not over, a lex not owned, then the limits check on the result | `player.ex:523-549` | run: each error reproduced | none |
| The limits check compares every count to the new limits: systems, dominions, Navarchs, Erased, Siderians (agents on the board, not the deck). Any change that leaves one over is refused | `player.ex:539-549` | run: dropping Age of Exploration with 2 Navarchs → refused; 2 systems with 1 System Limit → refused | wider than "can't un-slot capacity you use" |
| Wait after a change = initial + changes so far × factor, in ticks. The count starts at 1 and never resets; the very first change has no wait before it | `player.ex:551-560`, `:156-157` | run: L 6, 10, 14, 18 … ticks; T 5, 7, 9 …; F 26, 32, 38 … | T and F new |
| Every accepted apply counts, even an unchanged or empty set | `player.ex:551-560` | run (Q5) | new |
| A repeated lex is accepted and counts twice | `player.ex:528-533`, `1077-1088` | run (Q1) | new defect |
| New active lexes apply at once to the empire, every system, every dominion and every agent on the board | `player.ex:562-567`, `agent.ex:546-584` | code | new |
| Limits: System Limit starts at 1, everything else at 0. Only active lexes raise them (plus two game modifiers) | `player.ex:1026-1040`, `bonus-pipeline-out.ex:94-122`, `mutator.ex:366-392` | run: all limits with no lex = 0 except System Limit 1. F's Age of Exploration gives +1 each, L and T +2 | F value new |
| Agent limit blocks: activating an agent from the deck, buying an agent on the market | `player.ex:651`, `:1265-1273`, `market.ex:627` | code | new |
| Traditions: four per faction, always on for every member, same content at every speed | `player.ex:1090-1100`, `faction.ex:11-28` | run (Q3) | line numbers |
| News: only lexes. The first player in the galaxy to own 15 bought lexes gets a bulletin (not in Flash, daily or tutorial games). Patents never make news | `agent.ex:516-524`, `news/server.ex:227-228`, `:495-513` | code | "into law" wording is misleading (D7) |
| Starting stock: L 450 technology, 370 ideology; T 300 / 350; F 0 / 0. No patents or lexes | `constant-*.ex:20-22`, `player.ex:148-157` | data dump | T, F new |
| Patent panel: owned/total in the title, a splash with only the root before the first purchase, one tab per branch, clicking an available patent buys it with no confirm, hover shows the card, right-click pins it | `PatentMiniPanel.vue:1-302`, `MiniPanelMixin.js:29-45` | code | pin new |
| Lex panel: clicking an available lex buys it with no confirm, clicking an owned one stages it, clicking a staged one unstages it; "+1 slot" buys a slot with no confirm; the stamp applies; applying fewer lexes than slots needs a second click within 6 s; staging more than your slots is allowed but applying it is refused | `DoctrineMiniPanel.vue:27-441` | code | new |
| Lex card: Buy, Buy and Activate, Activate, Active | `DoctrineCard.vue:1-123` | code | "Buy and Activate" new |
| Cost Increase Factor header = owned × increase, shown after the first purchase | `PatentMiniPanel.vue:34-39`, `DoctrineMiniPanel.vue:128-133` | code | none |
| Hotkeys: P patents, L lexes | `Game.vue:12-13`, `:304-306` | code | none |
| On phones a tap opens the card instead of buying | `PatentMiniPanel.vue:85-94`, `DoctrineMiniPanel.vue:306-313` | code | new |

Content summary (data dump):

- Patent branches: L/T Origin (`root`) + Habitable Planets, Barren Planets, Moons and Asteroids, Shipyards and
  Ships; F Origin + Economic, Military.
- Lex branches: L/T Origin + Expansion, Navarchs, Erased, Siderians; F Origin + Expansion, Characters.
- L/T differ in costs, the T increase factor and a few values (T Fixer Network cover +0.5 instead of +0.3; T
  Synthetic Drugs +30 stability instead of +5% credit/technology/production; T unlocks Integrated Proxy Systems with
  `dome_academy` instead of `dome_defense_1`).
- Patents with no unlock list: the 4 hidden `infra_orbital_N` and the unit-size patents (`merge_*`, 6 at L/T, 5 at F). Their
  card shows a `patent_info` line instead.
- Patent descriptions and quotes are empty ("—") for all 69 locale keys. 48 of 61 lexes have no description.
  The card's About panel shows "—" for them. Not manual scope.

---

## 3. Detailed briefs

Common rules: docs/help-manual.md §3.2 (guide about 450 words, leaf about 180, both signals, rule 18), §3.4
style, §3.5 visuals. A page OWNS only what its brief lists. Everything else is one sentence plus `See [[page]]`,
or plain text when the page does not exist yet (Ships, Navarchs, Erased, Siderians, Agents, Factions, Game
modes). Numbers come from `{const:}` / `{table:}` tokens, never typed. Waits use `{duration:}`.

### `patents` (guide)

- File `research/patents.md`, `kind: guide`, title "Patents".
- `aliases: [patent-tree#the-patent-tree]`
- `terms: [patent, patents, patent tree, Cost Increase Factor, Origin]`
- Headings: `## The patent tree`, `## Buying a patent`, `## The price of a patent`, `## What patents unlock`,
  `## The patent panel`, `## All patents`.
- OWNS:
  1. **Intro**, two sentences: you buy patents with technology, and each one unlocks buildings, building levels,
     ships or larger ship units. A patent is yours for the rest of the game.
  2. **The patent tree.** Branches at the viewed speed (generated names via `{name:patent_class.*}`; F has two).
     Every patent except the first needs one patent before it (its ancestor). The first is
     `{name:patent.citadel}` in the Origin branch.
  3. **Buying a patent.** Needs its ancestor and enough technology. Takes effect at once. No refund, no way to
     sell it back. The panel buys on click with no confirm (edge, one sentence).
  4. **The price of a patent**, two sentences: each patent has a base price, and every patent you own makes the
     next one dearer; the panel header's "Cost Increase Factor" shows by how much. → [[price-scaling]] (owner
     of the formula and the examples).
  5. **What patents unlock.** Four kinds, one line each: a building's level 1 (→ [[buildings]]), upgrade levels
     (→ [[upgrades]], the three infrastructure patent families and the hidden Moons and Asteroids patents),
     ships (plain text, Ships), larger units of a ship (plain text, Ships; the unit-size patents' info line).
     Each patent's page lists exactly what it unlocks.
  6. **The patent panel.** `{shot:patent-panel#tabs,factor,available,locked|…}`. Hotkey P. Tabs per branch.
     Locked, available and owned look different (the shot shows it; no prose on looks, rule 8). Hover a
     patent for its card, right-click to pin the card.
  7. **All patents.** `{table:patents_list}` (D3).
- Edges, one sentence each: technology you don't have is never borrowed (exact amount is enough); a patent can
  unlock a building you can't build yet because of its body type or infrastructure (→ [[buildings]]).
- Visual: the panel shot. No chart.

### `lexes` (guide)

- File `research/lexes.md`, `kind: guide`, title "Lexes".
- `aliases: [lex#what-a-lex-is, lex-slots#lex-slots, active-lexes#active-lexes, lex-tree#the-lex-tree]`
- `terms: [lex, lexes, active lex, lex slot, Policies]`
- Headings: `## What a lex is`, `## The lex tree`, `## Buying a lex`, `## Active lexes`, `## Lex slots`,
  `## Changing your active lexes`, `## Limits`, `## The lex panel`, `## All lexes`.
- OWNS:
  1. **What a lex is.** An empire-wide law bought with ideology. It does nothing until it is active. Many lexes
     have a drawback next to their benefit (the effect list on each page shows both).
  2. **The lex tree.** Branches at the viewed speed. One ancestor per lex. The root is
     `{name:doctrine.agent}`.
  3. **Buying a lex.** Ancestor + ideology. Every lex you own makes the next one dearer (→ [[price-scaling]]).
     Buying is permanent, no refund. The card's "Buy and Activate" does both in one click when a slot is free.
  4. **Active lexes.** Only active lexes give their effects. They apply at once to your empire, every system,
     every dominion and every agent on the board.
  5. **Lex slots.** You start with one and buy more with ideology ("+1 slot"). No limit on the number of
     slots. Buying a slot is instant and starts no wait. Each slot costs more than the last (→
     [[price-scaling]]).
  6. **Changing your active lexes.** You pick a new set and apply it. After each change you must wait before
     the next, and the wait grows with every change for the rest of the game. `{chart:lex_change_waits}` (the
     user asked for a visual here: it is the guide's main picture). The panel shows the wait that applying now
     would start (D9). → [[lex-changes]] for the exact table and what counts as a change.
  7. **Limits**, two sentences: your System, Dominion, Navarch, Erased and Siderian limits come from active
     lexes (Age of Exploration gives the first agents), and a change that would leave you over one is refused.
     → [[system-limits]], [[agent-limits]].
  8. **The lex panel.** `{shot:lex-panel#tabs,staged,slots,apply,cooldown|…}`. Hotkey L. Click an available lex
     to buy it, click an owned one to put it in the "Policies" bar (quote via `{ui:}`), click it there to take it
     out; the stamp applies; "+1 slot" buys a slot. Applying fewer lexes than you have slots asks for a second
     click. The set you staged is dropped when you close the panel.
  9. **All lexes.** `{table:lexes_list}` (D3).
- Visuals: the panel shot and the wait chart.

### `lex-changes` (leaf of `lexes`)

- File `research/lex-changes.md`, `kind: mechanic`, `guide: lexes`, title "Changing active lexes".
- `aliases: [lex-cooldown, policy-cooldown]`
- `terms: [lex change, wait, cooldown]`
- OWNS:
  1. One sentence: after you apply a new set of active lexes, you must wait before the next change.
  2. Shot: the panel's cooldown ring and counter, and the "applying now" wait (D9)
     (`{shot:lex-panel#cooldown,next-wait}` crop or its own recipe).
  3. The wait: `{const:initial_update_policies_cooldown}` plus `{const:update_policies_cooldown_factor}` for
     each change you have made so far, in ticks. It never goes back down. Your first change has no wait before
     it. `{table:lex_change_waits}` (first 8 changes, in both units via `{duration:}`).
  4. What counts: every change you apply, even one that only removes lexes (Q5).
  5. What a change can't do: leave a count over its limit (systems, dominions, Navarchs, Erased, Siderians).
     Owns this rule; `system-limits` keeps its one sentence and links here. Fix: free a system or put an agent
     back in the deck first (plain text for the deck until the Agents chapter).
  6. Edge: more lexes than slots are refused; lexes you only staged are lost when the panel closes.

### `agent-limits` (leaf of `lexes`)

- File `research/agent-limits.md`, `kind: mechanic`, `guide: lexes`, title "Agent limits".
- `aliases: [navarch-limit, erased-limit, siderian-limit, agent-limit]`
- `terms: [Navarch Limit, Erased Limit, Siderian Limit, agent limit]`
- OWNS:
  1. One sentence each: what `{name:bonus_pipeline_out.player_admiral}`, `…player_spy`, `…player_speaker` count
     (agents on the board, not the ones in your deck).
  2. Shot if the Bottombar shows the counters (D6 checks; else none).
  3. They start at 0. Active lexes raise them; `{name:doctrine.agent}` is the first. Two game modifiers add to
     them (plain text).
  4. What the limit blocks: activating an agent from the deck, buying one on the market. A change of active
     lexes can never leave you over a limit (→ [[lex-changes]]), so the page does not cover being over one.
  5. Three tables: `{table:bonus_sources player_admiral}`, `player_spy`, `player_speaker`.
- Mirror `system-limits` in shape so the two read as siblings.

### `price-scaling` (mechanic, no guide)

- File `research/price-scaling.md`, `kind: mechanic`, title "How prices grow". The user wants it short, with
  examples. `related: [patents, lexes]`.
- `aliases: [patent-price, lex-price, cost-increase-factor, lex-slot-price#lex-slots]`
- `terms: [Cost Increase Factor, price increase]`
- Headings: `## Patents and lexes`, `## Lex slots`.
- OWNS:
  1. **Patents and lexes.** Each has a base price (its page, and the tree). Every patent you own adds
     `{const:patent_level_price_increase}` of the base price to the next patent. Lexes work the same way with
     their own count (`{const:doctrine_level_price_increase}`): patents never raise lex prices, and lexes never
     raise patent prices. Every purchase counts, including upgrade and unit-size patents. The panel header's
     "Cost Increase Factor" is the extra you pay now.
  2. **Examples**: `{table:price_scaling}` (D3): the same real patent and lex bought as your 1st, 5th, 10th,
     20th, 30th, 40th purchase, at the viewed speed. The rows show the factor and the price.
  3. One sentence: the Open Science and Lost Sciences game modifiers halve or double patent prices (Q2, plain
     text until the Game modes chapter exists). They never change lex prices.
  4. **Lex slots.** Each new slot costs twice the one before, until the price reaches its maximum. After that
     every slot costs the maximum. `{table:lex_slot_costs}`. One sentence: the calculator (X) knows the next
     slot's price as "lex slot" (plain text unless a calculator page exists).
- No formula block. Plain sentences plus the two tables are enough (the user asked for "briefly").

### `traditions` (mechanic, no guide)

- File `research/traditions.md`, `kind: mechanic`, title "Traditions".
- `aliases: [tradition]`. No per-faction aliases: the table is generated, and an alias can only point at a
  heading written in the page's own file. The Factions chapter links `[[traditions]]`.
- `terms: [tradition, traditions]`
- OWNS:
  1. Each faction has four traditions: three bonuses and one drawback. They are always on for every member
     from the first tick, can't be changed, and are the same at every speed (Q3).
  2. Where you see them: the faction panel and the faction picker (shot optional).
  3. `{table:traditions}` (D3): one row per tradition with its faction, name, effect and description.
  4. One sentence: tradition effects appear in resource tooltips as "Tradition". Not to be confused with the lex
     named `{name:doctrine.upgrade_xp}` (link `[[lex/upgrade_xp]]`).

---

## 4. Catalog prose slots

A slot never repeats the shell (branch, price, ancestor, unlocks, effects, info line, path). Only these are
non-empty; everything else is covered by the shell and the guides.

| Key | UI name | Speeds | Slot | Code |
| --- | --- | --- | --- | --- |
| `lex/agent` | Age of Exploration | L T F | 2 sentences: agent limits start at 0, so no agent can be activated until this lex is active ([[agent-limits]]); it is the root of the lex tree, so every other lex needs it first. | `player.ex:1026-1040`, `:651` |
| `lex/mobility_2` | Trade Secrets | L T F | 1 sentence: its percentage raises a system's mobility, but not the Mobility credit bonus, which counts mobility before percentages unless the system has a Reflect District, Business Arch or Monolith ([[mobility]]). Writer checks `mobility.md:28-30` wording and reuses it. | `bonus.ex:38-87` |
| `lex/credit_pop` | Centralization of Power | L T F | 1 sentence in plain words for its "2 × population → credit" effect (writer runs it: credit gained per tick for a system of known population, with and without the lex). | `bonus.ex:13-29`, `:85-96` |
| `lex/cover` | Fixer Network | L T | 1 sentence: what cover is, plain text until the Erased chapter. Skip if the shell's effect row already links a page. | — |
| `lex/upgrade_xp` | Navarch Tradition | L T | 1 sentence: it is a lex, not one of the faction [[traditions]]; its effect raises the starting experience of ships built in your systems (plain text for ship experience, Ships). | `stellar_system.ex:1144-1152` |
| `patent/capital_1` | Armoring | L T F | 1 sentence: buying it completes the Destroyer's Blueprint daily race (plain text, daily challenge). | `lib/daily/objective.ex:126-136` |

Checked and left empty on purpose:

- Upgrade patents (`infra_*_N`) and unit-size patents (`merge_*`): the shell prints the card's info line and
  links it to `[[upgrades]]` / the Ships chapter (D1).
- Limit lexes (`system_*`, `sys_dom_*`, `dominion_*`, `admiral_*`, `spy_*`, `speaker_*`): the effect rows link
  to `system-limits` / `agent-limits`.
- Shipyard patents: the unlock list links the shipyard's page, which owns the ship classes.
- `citadel`: the shell's "root of the tree" line covers it.

---

## 4b. Shell checks for the developer

1. Patent unlock list = `patent.unlock` (buildings with level, ships). Hidden levels are already left out
   (`patent.ex:56-62`), so `infra_orbital_N` has an empty list: show its `data.patent_info.<key>` line instead,
   with a link to `[[upgrades]]`. `merge_*`: info line, Ships plain text.
2. Unlock entries at level > 1 read "Megapolis level 2", like the card's "(lvl N)".
3. "Leads to" = the nodes whose `ancestor` is this key at the viewed speed. Can be empty.
4. Path from root: reuse `patent_chain/2`; write a lex twin.
5. Price in the facts: base price, then "+{const} of the base for each patent you own" linking
   `[[patent-price]]`. Never a single number, since the real price depends on the player.
6. Lex effects: render each `Core.Bonus` like `CardComplexBonus.vue` and the building card. Negative values are
   drawbacks: group them after the benefits under a "Drawbacks" label, same row style. Targets link through
   `@target_pages` extended with `player_admiral|spy|speaker → agent-limits`, `player_technology → technology`,
   `player_ideology → ideology`, `player_credit → credit`, `army_* → ` (none yet), `spy_* / speaker_*` (none
   yet).
7. Mul bonuses whose input differs from their target (`credit_pop`: `sys_pop → sys_credit`) render as
   "value × input icon", the same as buildings. Dev checks the rendered text against a run before the catalog
   batch starts.
8. Branch name from `patent_class` / `doctrine_class`. The Origin root appears in every tab in the panel, but
   belongs to the `root` class.

---

## 5. Developer specs

**D1. Patent catalog shell** (`RC.Help.Catalog`, `parse_slug("patent/" <> key)`). Per speed:
- `{facts:patent <key>}`: "Part of the Patents guide", branch, base price + increase line (4b.5), requires
  (ancestor link), leads to, and the patent's info line when it has one.
- prose slot
- `{card:patent <key>}`: the in-game card (icon, name, illustration, unlock list with icons and links, info line,
  base price). No level selector.
- `## Unlocks` generated list (links to `building/<key>`; ships link `ship/<key>` once those pages exist).
- `## Unlocking`: path from the root (reuse `building_unlock`'s chain rendering).
- Title and icon from locale, like buildings (`fill_meta/2`).
- Lint: a patent key found in no speed's content is an error (as buildings).

**D2. Lex catalog shell** (`parse_slug("lex/" <> key)`):
- `{facts:lex <key>}`: "Part of the Lexes guide", branch, base price + increase line, requires, leads to.
- prose slot
- `{card:lex <key>}`: icon, name, illustration, quote when not "—", effects (benefits then drawbacks), base price.
- `## Effects` table: one row per bonus, both units for per-tick targets (`{amount:}` like building cards).
- `## Unlocking`: path from the root.

**D3. Tables** (`RC.Help.Tables`):
- `patents_list`: grouped by branch (`Format.grouped/2`), rows in tree order; columns Patent (icon + link),
  Requires, Base price, Unlocks (short list). Test: L 64 rows, F 39.
- `lexes_list`: grouped by branch; columns Lex, Requires, Base price, Effects (short). Test: L 61, F 39.
- `lex_slot_costs`: slot number (2nd, 3rd …) and ideology price, from the constants, stopping at the first
  slot that hits the maximum and adding "and every slot after". Test: L 2nd 200 … 11th 100 000.
- `lex_change_waits`: change 1-8 and the wait after it, `{duration:}` both units. Test: L 6, 10, 14 … ticks.
- `traditions`: one table, columns faction / tradition / effect (linked target) / description.
- `price_scaling`: rows for purchase number 1, 5, 10, 20, 30, 40. Columns: purchase, factor (×1.00, ×1.20 …),
  price of one real patent, price of one real lex. The example keys exist at every speed (the generator asserts
  it); both names link. Test: L row 10 = ×1.45.

**D3b. Chart `lex_change_waits`** (`RC.Help.Charts`): x = change number 1 to 30, y = the wait that change
starts, both units like the population chart. Caption states the rule in words. Test: L change 1 = 6 ticks =
18 min.

**D4. Code fixes.**
- a (Q1): `update_policies` refuses a list with a repeated key, new error `:duplicate_policy` with an
  `errors.json` string. Unit test beside the other player tests.
- b (Q2): the patent panel header, the patent card and the X-calculator (if it prices patents; today it doesn't)
  apply the Open Science / Lost Sciences multiplier. Needs the instance's mutator keys on the client (check
  what the store already has).

**D5. "Not in this mode" message**, every catalog kind (`building_body/3` today prints "This building is not in
%{speed} games."):
- Text: "The game mode you're viewing, {speed}, doesn't have this {kind}. Switch to {other speeds}." where each
  other speed that has the key is a link.
- Compiler emits `<a class="help-speed-switch" data-speed="slow">Legacy</a>`.
- Public site (`Portal.HelpLive`): turn it into a `patch` to the same slug with `speed=` and the current lang and
  unit (reuse `link_query/3`).
- In game: the manual always follows the game's own mode, so the link opens the public page at that speed in a
  new tab (`render.js`).
- Search and the index still list these pages. Test: a Flash page for `patent/open_intel` links Legacy and
  Tactic; `patent/merge_fighter_corvette` at Legacy links Flash only.

**D6. Capture scenes** (`e2e/help-shots`): empire fixture option `research` that owns a few patents in two
branches, owns four lexes with two active, two slots, and a running change wait. Recipes: `patent-panel`
(marks tabs, factor, available, locked), `lex-panel` (tabs, staged, slots, apply, cooldown), `patent-card`,
`lex-card` (Buy and Activate). Optional: Bottombar agent counters for `agent-limits`.

**D7. Locale fixes (en, fr).**
- `errors.json` `toast.error.cooldown_not_unlock`: missing; add "You must wait before changing your active lexes
  again."
- `portal.json` `news.doctrine.first.public`: "…first to bring fifteen lexes into law" → "…first to hold fifteen
  lexes" (it counts bought lexes).

**D8. Vocabulary renames (if V1 approved), en and fr:** `minipanel.doctrine.policies_title` "Policies" → "Active
lexes"; `apply_policies` / `save` "Apply these new policies" → "Apply these lexes"; `policies_locked`
"Currently impossible to change policies" → "You can't change your active lexes yet"; `card.doctrine.choose_lex`
"Activate lex as a policy" → "Activate this lex"; `card.doctrine.no_lex_slot` "No free policy slots" → "No free
lex slot"; `toast.error.too_many_policies` → "More active lexes than lex slots"; tutorial steps 13 (title
"Policies"), 35 and 56 ("Buy a policy slot") → lex slot wording; `page.profile_detail.icon_category.doctrine`
"Doctrines" → "Lexes". Then pages drop the `{ui:}` quote of "Policies".

**D9. Lex panel: the wait that applying now would start** (user request 2026-09-29). Next to the apply stamp in
`DoctrineMiniPanel.vue`, show "Applying now locks changes for {duration}" while changes are staged (and in the
stamp's tooltip). Value = `initial_update_policies_cooldown + update_policies_count × update_policies_cooldown_factor`
ticks, converted with the game's tick length. Needs `update_policies_count` on the client player state and the two
constants on the client. After an apply the number must match the new cooldown ring's total
(`policies_cooldown.initial`). Locale key `minipanel.doctrine.next_wait` (en, fr).

---

## 5b. Built on 2026-09-29 (developer batch 0)

Everything in section 5 except D6 (capture scenes, left for batch 1b):

- **D1, D2:** `lib/rc/help/research_catalog.ex` (`RC.Help.ResearchCatalog`); `RC.Help.Catalog` dispatches
  `patent/<key>` and `lex/<key>`. 65 patent and 61 lex stubs in `priv/help/en/{patent,lex}/`. Card images copied
  by the assets webpack to `/img/help/patents/` and `/img/help/lexes/`. Card styles reuse `.help-bcard` plus
  `.help-bcard-note` / `.help-bcard-quote`.
- **D3, D3b:** tables `patents_list`, `lexes_list`, `price_scaling` (examples `shipyard_2` and `credit_2`, rows
  1st to 60th capped at the tree size), `lex_slot_costs`, `lex_change_waits` (first 10 changes), `traditions`;
  chart `lex_change_waits changes=30` (per-hour variant in minutes when the line stays under two hours).
  `{duration:}` now reads "18 min" / "39 s" under an hour for the per-hour reader.
- **D4a:** `update_policies` throws `:duplicate_policy` (`test/game/instance/player/policies_test.exs`).
- **D4b:** join payload `global_instance.patent_cost_multiplier`; `PatentCard.vue` price and a "×2" in the patent
  panel header.
- **D5:** block token `{absent:<kind> <key>}` for buildings, patents and lexes; `Portal.HelpLive` makes each
  switch link name its speed and keep lang and unit; `render.js` opens it on the public site in a new tab.
- **D7, D8:** en and fr locale strings (de only the profile icon category). New keys
  `toast.error.cooldown_not_unlock`, `toast.error.duplicate_policy`, `minipanel.doctrine.next_wait`.
- **D9:** `DoctrineMiniPanel.vue` header reads "Applying now locks your lexes for {duration}" while a change is
  staged, and the stamp's tooltip repeats it. Checked in a daily: the preview's 6 ticks matched the server's new
  cooldown after the apply.

## 6. Formula and topic owners

| Rule | Owner | Code |
| --- | --- | --- |
| Patent price and Cost Increase Factor | `price-scaling` | `player.ex:476-477` |
| Patent ancestor rule, instant, no refund | `patents` §Buying a patent | `player.ex:440-471` |
| What a patent unlocks, per patent | patent shell | `patent.ex:56-78` |
| Per-level upgrade patents | `upgrades` (existing) | `building.ex:72-80` |
| Ship patents and unit sizes | Ships (future); patent shell lists them | `player.ex:416-426` |
| Lex price | `price-scaling` | `player.ex:506` |
| Lex slot price | `price-scaling` + `lex_slot_costs` | `player.ex:524-542` |
| Wait after a change, chart | `lexes` §Changing (chart only), `lex-changes` (rule and table) | `player.ex:572-581` |
| Only active lexes count; apply at once | `lexes` §Active lexes | `player.ex:1076-1088`, `agent.ex:546-584` |
| Change wait, what counts as a change, limits check on a change | `lex-changes` | `player.ex:523-560` |
| System and Dominion Limits, what they block | `system-limits` (existing) | as that page |
| Navarch, Erased, Siderian Limits, what they block | `agent-limits` | `player.ex:651`, `:1265-1273`, `market.ex:627` |
| Traditions | `traditions` | `player.ex:1090-1100`, `faction.ex` |
| Per-lex effects | lex shell | `doctrine-*.ex` |
| How bonuses stack | `system-outputs` (existing) | `bonus.ex` |
| 15-lex news bulletin | Galaxy & UI news page (future); `lexes` says nothing | `agent.ex:516-524` |
| Game modifiers on prices and limits | Game modes (future); one plain sentence where they apply | `mutator.ex` |

---

## 7. Linking plan for existing pages

Links and the lowercase "lex" only. Applied by a run after the new pages land.

| Page | Change |
| --- | --- |
| `ideology` | "Buying Lexes and Lex slots." → "Buying [[lexes]] and [[lex-slots\|lex slots]]." Drop "A Lex is a law your empire buys and places in a slot." or make it one linked sentence. "A Lex counts only while it sits in a slot." → "A lex counts only while it is [[active-lexes\|active]]." Traditions → [[traditions]]. |
| `technology` | "patents" in what-spends-it → [[patents]]. Lexes/traditions sentence → links. |
| `system-limits` | "Lexes raise them." → [[lexes]]. "You cannot unslot a Lex if that would put you over a limit." → "A [[lex-changes\|change of active lexes]] that would put you over a limit is refused." Add `agent-limits`, `lexes` to `related`. |
| `dominions` | "Your Lexes and your faction's traditions" → "[[active-lexes\|Your active lexes]] and your faction's [[traditions]]". |
| `mobility` | "from a Lex or tradition" → "from a [[lexes\|lex]] or [[traditions\|tradition]]". |
| `system-outputs` | "Lexes, traditions and agent skills." → links. |
| `upgrades` | Patent names in the prose → `[[patent/<key>]]` where named; "each level needs a patent" → [[patents\|patent]]. |
| `buildings` | "Level 1 needs the building's patent." → [[patents\|patent]]. |
| `production`, `credit`, `technology`, `ideology` | Nothing in prose: the `bonus_sources` tables already link `lex/<key>` once the pages exist. Traditions rows get links through D3 (`traditions#<faction>`). |
| `hotkeys` | P and L rows → link [[patents]] / [[lexes]] if the page's table format allows. |

---

## 8. Batch plan and estimates

About 9 agents per mechanic page in past runs, 12-15 for a guide.

| Order | Batch | Pages | Needs first | Estimate |
| --- | --- | --- | --- | --- |
| 0 | Developer | D1-D5, D7-D9 | map approved | no agents |
| 1 | Research group, 1 writer | `patents`, `lexes`, `lex-changes`, `agent-limits`, `price-scaling`, `traditions` | D1-D3 merged | 2 guides ~14 each, 4 leaves ~9 each = ~64, + 1 consistency critic |
| 1b | Capture | D6 recipes | D6 fixture | 1-2 agents; pages that gain a shot re-review: ~4 × 3 = ~12 |
| 2 | Linking plan | ~10 existing pages (section 7) | batch 1 landed | ~10 × 4 = ~40 |
| 3 | Catalog slots | 6 non-empty slots | shells compile | 1 writer, 1 accuracy critic (runs code), 1 clarity critic, no voters (all 1-2 sentences), ≤1 revision = ~5 |

Total ≈ **125 agents**, most of it batch 1 and the linking re-review. Batches 2 and 3 can run in parallel after
batch 1.

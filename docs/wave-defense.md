# Wave Defense ("Rebellion") — design and implementation plan

Status: **planned 2026-09-12; MVP slice built 2026-09-13 (§0).** This document
is the brief for the implementation agents. It is deliberately explicit about file paths, function
names, formulas and the decisions already taken, so each phase in §12 can be
handed to an agent without re-deriving the survey.

Short verdict: **yes, the mode is buildable on what exists.** Three
foundations carry most of the weight:

1. The **Daily Challenge** instance recipe (`Daily.Boot.boot_persisted/2`) —
   real scenario/instance/registration rows, no lobby magic needed.
2. The **SystemAI behavior-tree engine** (`SystemAI`, `SystemAI.Actions`,
   `Instance.SystemAI.Parser`, `priv/data/system_ai/behavior_tree.json`) —
   the decision-tree format the user wants agent scripting encoded in.
3. The **unmerged game-AI branch** `origin/claude/game-ai-bot-training-run-9d05c1`
   (== `origin/claude/relaxed-morse-0d03c9`, head `c29b43f`) — an in-process
   bot driver, an engine-payload adapter, a lane pathfinder, a `bot_faction`
   instance column with registration lock, and an arena-bred fleet
   blueprint table. Master has none of it. It merges into master with only
   two trivial conflicts (`.gitignore`, `lib/game/system_ai/actions.ex`),
   but we port selected files rather than merge the 15.9k-line branch (§2.2).

Everything else — roles, targeting, recruitment, construction, waves — is new
code under `lib/wave/`.

---

## 0. MVP slice (built 2026-09-13)

A deliberately small first slice that proves the load-bearing plumbing before
any combat AI is written. It answers seven questions: can a new faction exist
with a bot as its only member; can a game-time timer initiate actions; can the
bot buy agents and receive ships without construction; can it manage agents
end to end; can limits be bypassed for the bot without leaking to humans; does
a new behavior tree run; and does the bot's territory develop on it.

### What it does

- **The Rebellion is a real faction.** `:rebellion` in `Data.Game.Faction.Content`
  with a `:rebel` culture (name lists alias the stelloliberalism corpus in
  `Data.Picker.index/0` until rebel lists exist), four traditions, an original
  icon (`front/src/icons/faction/rebellion*.js`), colors in
  `front/src/utils/factions.js` (`BOT_FACTIONS`, kept out of the playable
  roster), and en/fr text. The catalog struct gained `playable` (false for the
  Rebellion), and player-facing faction lists such as `RC.ProfileIcons.faction_keys/0`
  filter on it. `Instance.Faction.Government.Rules.module_for/1` gained a
  fallback so an unknown faction can never crash a faction agent.
- **One bot, alone in its faction.** `Wave.Boot.start/1` rewrites a scenario
  (default: the bundled two-sector test map) to Legacy speed and
  `game_mode_type: "wave"`, hands one rival start sector to the Rebellion,
  creates a public late-registration instance with a capacity-1 Rebellion
  faction, registers the shared `is_bot` profile `wave-rebellion@tetrarchyfalls.local`,
  and starts the game. `Portal.RegistrationController.join/2` refuses the
  Rebellion with `:bot_faction_locked` (`Wave.locked_faction?/2`).
- **The Warlord.** `Wave.Warlord.Agent` is a `Core.TickServer` started by
  `Instance.Manager` inside the instance tree (and on the snapshot allow-list),
  ticking every 1 ut. Its pure state and decisions live in `Wave.Warlord`.
  Each pass: marks the bot player connected, tops credit/technology/ideology up
  to floors, and every `hire_interval_ut` (120 ut = 6 real hours at Legacy)
  runs a hire cycle.
- **Hire cycle.** Buys the cheapest one-star (`:common`) Navarch from the
  shared character market with `{:hire_character, id}`, deploys it on-board at
  the capital with `{:activate_character, …}`, and materializes a
  `transport_1` into tile 1 with the character agent's
  `{:order_ship, {nil, 1, :transport_1, nil}}` + `{:put_ship, 1, 0}` — no
  production, credits, patents or shipyard.
- **Agent management.** An idle Navarch carrying a colony ship gets a lane-hop
  itinerary plus a colonization order toward the nearest uninhabited system in
  a takeable sector (owned or adjacent), never a target another coloniser
  holds (`Wave.Nav`, `Wave.Warlord.colonisation_target/4`). Orders are read
  back, because `add_character_actions` answers `:ok` even when validation
  drops them. Once a dispatched Navarch is idle with its ship spent, it is
  recalled with `{:deactivate_character, id}` and dismissed with
  `{:dismiss_character, id}` (dismissal has no deck cooldown). A Navarch that
  can't be recalled because it isn't in owned space is walked home first.
- **Bot-only bypasses.** `Wave.Config.player_bonuses/1` adds +500 systems,
  +500 dominions and +50 of each agent type to the bot player only, through
  `Instance.Player.Player.extract_bonus/2`. `Player.detect_bankruptcy/2`
  ignores the bot faction, so its agents never go on strike.
- **Rebel Dominion tree.** `priv/data/system_ai/behavior_tree_wave.json`,
  generated from the vanilla tree with: upgrade odds 25% (was 50%), a new
  branch `sequence[no_free_tiles?, select[upgrade_any, done]]` so a built-out
  system upgrades instead of terminating, and `upgrade_any` in place of
  `upgrade_random`. `SystemAI.Actions.upgrade_any/1` draws only from upgrades
  the engine accepts (`SystemAI.Helper.get_legal_upgrades/1`), including the
  infrastructure tile, which fixes the level-1 freeze for rebel systems. The
  Rebel Workforce subtree uses `build_housing/1` instead of the vanilla
  `build_workforce/1`, whose body-type filter never matches: without housing
  a young colony used up its workforce and sat idle until population growth
  freed more (a colony paused at ten buildings on the first test game). With
  `build_housing/1` the same colonies raised habitation steadily. Housing
  spam costs stability, so watch happiness when tuning.
- **Five-minute cadence.** `StellarSystem.auto_actions/2` routes through
  `Wave.Config.system_ai/2`: rebellion-held systems **and** dominions run
  `:rebel_dominion` every `ai_interval_ut` (1.667 ut = 5 real minutes);
  everything else is unchanged. `compute_next_tick_interval/1` wakes rebel
  systems for their AI turn. The queue gate (`wait_if_queue_is_busy`) is kept,
  so "no delay" means the next order lands within five minutes of the last
  one finishing.
- **Safety net.** `SystemAI.step/1` now has a 1,000-evaluation budget and
  returns `{:error, :bt_runaway}` instead of hanging a system agent.

### Breakout: Siderian capture, idle-Navarch cap, pass cost (2026-09-15)

**Why.** On the production Citadel map (scenario 145) colonization alone
stalled at 1 of 19 sectors. A sector changes hands only when a faction has
strictly more inhabited systems there than the current holder, and neutral
systems vote as a `nil` faction. Harara's only neighbour, Persiennes, has 3
neutrals and 2 open systems, so colonizing could never take it and the
Rebellion was walled in. The 20 idle colonisers meanwhile retried every pass.

**Siderian capture.** The Warlord keeps up to `max_siderians` (3) Siderians,
never more than there are capture targets. The first is hired at once and
each further one after `siderian_hire_interval_ut`. An idle Siderian that
isn't resting after an attempt rolls a sector class (frontier 80, border 15,
internal 5, renormalized over classes that have targets). It then sends a
`make_dominion` itinerary at a neutral system or foreign dominion. Frontier
picks prefer the sector closest to changing hands, then the nearest system.
A captured dominion votes for the Rebellion, which is what breaks the wall.
Outcomes are scored when the Siderian goes idle again.

**Idle-Navarch cap.** Colonisers are capped at `idle_navarch_factor` (1.5)
times the open systems left in reachable sectors, rounded down, under
`max_active_colonisers`. Hiring stops at the cap, and surplus idle colonisers
are recalled and dismissed. Dispatched ones are never interrupted.

**Pass cost.** `Wave.Geometry` turns one galaxy read into lane adjacency,
owned and reachable sectors, sector classes, ownership deficits and candidate
lists, shared by every decision in the pass. Hop distances are memoized per
source system. Only agents the player roster reports idle get a full state
read, with a full refresh every `state_refresh_passes` (20). A due hire only
triggers a galaxy read when the last reading left room for one. Measured with
`Wave.Profile` on the stalled Citadel game at 200×:

| Measure | Before | After |
|---|---|---|
| Node reductions in 10 s | 157.7 M | 11.2 M |
| Warlord share of node work | 88% | 57% |
| Container CPU | 55–73% | 30–53% |
| Warlord pass cost | not measured | about 3.5 ms |

The zero-cap throttle landed after that measurement.

### Deviations from the plan below

| Plan | MVP | Why |
|---|---|---|
| Any scenario faction becomes the bot faction | A new catalog faction `:rebellion` | The user asked for a defined faction |
| Recruits synthesized in a skill range | Real market purchase of a one-star Navarch | MVP spec; proves agent purchasing |
| Navarch combat roles | Colonization only | MVP spec |
| Faction-scoped mutators for caps and Rebel Zeal | `Wave.Config.player_bonuses/1` in `extract_bonus/2`; Rebel Zeal not built | Smallest change that proves bot-only bypass |
| Tree map on the galaxy agent | `SystemAI.Trees` parses extra trees once into `:persistent_term`; the vanilla tree still rides the galaxy | No snapshot shape change, no galaxy round trip per AI turn |
| Remove `wait_for_population_growth` | Kept | It only short-circuits builds that would fail on workforce anyway |
| `choose_upgrade_category` + synthetic infra category | One legality-aware `upgrade_any` | Simpler, and it fixes the infra ceiling directly |
| Port the `bot_faction` column | `Wave.locked_faction?/2` over `game_data` plus capacity 1 | No migration for an MVP |

Known gaps: the bot's cached copy of a system can lag behind AI orders on its
own `:inhabited_player` systems (humans read systems directly, so they are
unaffected); a pause/resume re-sends `:connect`, inflating the bot's
connected-client count (harmless, it only needs to be above zero); the vanilla
`build_workforce/1` bug is untouched.

### Driving it (dev only)

The harness endpoints are gated by the shared secret and a non-prod
environment. Read `.dev-ports.json` for this worktree's Phoenix port; the
docker-compose secret is `dev-harness-secret`.

```bash
curl -s -X POST localhost:$PORT/api/harness/wave/start -H 'x-harness-secret: dev-harness-secret' -H 'content-type: application/json' -d '{"email":"user1@abc","knobs":{"hire_interval_ut":2}}'
```

```bash
curl -s localhost:$PORT/api/harness/wave/$IID/status -H 'x-harness-secret: dev-harness-secret'
```

`GET /api/harness/wave/profile?ms=10000` attributes node CPU to agent types
over a sampling window. The start body also accepts inline `game_data` and
`game_metadata` (e.g. a scenario copied from production) and a
`win_points_target` override, and status reports per-sector owner, vote
counts and adjacency. `POST …/force_hire` runs a hire cycle now; `POST …/run` runs one Warlord pass;
`POST …/speed` with `{"multiplier": n}` applies the runtime speed cheat (the
start body also accepts `"speedup"`). At Legacy speed a colonization round trip
takes hours of real time, so tests normally run at 100–200×. The creator can
also use the in-game speed cheat, capped at 50×, since wave instances are
created with cheats enabled.

---

## 1. Player-facing rules (normalized spec)

Terminology: UI names map to internal actions as follows (from
`lib/game/instance/character/action_impl.ex` and `front/src/locales/en/game.json`).

| UI / spec word | Internal action | Actor | Target |
|---|---|---|---|
| Pillage | `loot` | Navarch (`:admiral`) | system |
| Bombard | `raid` | Navarch | system |
| Conquer | `conquest` | Navarch | system |
| Capture dominion / Control | `make_dominion` | Siderian (`:speaker`) | system (`:inhabited_neutral` or `:inhabited_dominion` only) |
| Destabilize | `encourage_hate` | Siderian | system |
| Seduce | `conversion` | Siderian | character (must be in the same system) |
| Infiltrate | `infiltrate` | Erased (`:spy`) | system |
| Remove / Delete | `assassination` | Erased | character (same system) |
| Sabotage | `sabotage` | Erased | character (Navarch, same system) |
| Move | `jump` (one per star lane) | any | — |

### 1.1 Setup

- Created from any Forge scenario at **Legacy speed** (`:slow`, factor 1:
  1 ut = 1 in-game day = **3 real minutes**; 20 ut per real hour, 480 ut per
  real day). Only Legacy is offered in v1 (the constants below are Legacy).
- The creator picks the **human faction** and the **rebellion faction** (any
  two of the scenario's factions). Sectors that belong to other factions in
  the scenario are rewritten to unowned (`"faction" => nil`) so the map has
  exactly one human start and one rebellion start (§3.2, knob to give the
  rebellion the extra start sectors instead).
- Humans register into the human faction through the normal lobby; the
  rebellion faction is locked to humans (`:bot_faction_locked`). Late
  registration is allowed and the rebellion scales with the live human count.
- The two-faction diplomacy rule already starts the game at war
  (`Instance.Diplomacy.Diplomacy.new/2`).
- Victory conditions are unchanged for both factions (default 14 VP on the
  three tracks, or time-out ranking).

### 1.2 Timeline

- **Spawn phase**: 0 → 3 real days (0 → **1440 ut**). The rebellion builds
  its economy, recruits, and constructs fleets, but issues no offensive
  orders. Siderians may still capture frontier dominions (their 80% bucket)
  because that is expansion, not attack; knob `assault_only_after_spawn`
  defaults to `false` for capture, `true` for everything else.
- **Assault phase**: from 1440 ut onward, all roles are live. Waves are
  expressed as a **roster schedule** (how many agents of each type the
  rebellion keeps alive) and a **tech-tier schedule** (which blueprints are
  eligible) — see §5.5 and §7.3.

### 1.3 Roles (the user's spec, with interpretations marked ⚑)

**Siderian**

- *Capture dominions*: candidates are `:inhabited_neutral` or
  `:inhabited_dominion` systems (owned by the humans or unowned), never the
  rebellion's own, and **takeable** for the rebellion
  (`Galaxy.check_system_takeability/3`: in a rebellion-owned sector or
  adjacent to one). Bucket weights 80 / 15 / 5:
  - 80 — system's sector is **uncontrolled** (`owner == nil`) and adjacent to
    a rebellion sector ("frontier");
  - 15 — system's sector is a **border** sector: rebellion-owned but touching
    a non-rebellion sector, contested (both factions hold inhabited systems in
    it), or human-owned and adjacent to rebellion territory ⚑;
  - 5 — system's sector is a rebellion **interior** sector (all neighbours
    rebellion-owned).
  Empty buckets are dropped and weights renormalized; within a bucket pick by
  proximity (nearest hop count, ties by rand).
- *Destabilize*: 80 — a human `:inhabited_player` system; 20 — a human
  dominion located in an uncontrolled sector. Nearest first.
- *Seduce*: 50 — governor mode (travel to a human system with a governor,
  attempt the governor); 50 — agent mode (any visible human non-governor
  character: Navarchs, Siderians, discovered Erased). If nothing is visible,
  roam (§6.6).
- Role split among Siderians (not in the spec) ⚑: 40% capture / 30%
  destabilize / 30% seduce. Knob.

**Erased**

- *Infiltrate*: human-owned systems where the rebellion's **resolved
  visibility < 5** (`Instance.Faction.Faction.resolve_system_visibility/2`);
  75 — human dominions, 25 — human systems.
- *Remove*: once per real day (480 ut) roll `governors_allowed` at 10% and
  `unknown_attempt_day` at 25% (both faction-wide). Candidates are visible
  human characters (governors only on allowed days). Each candidate gets a
  **chance class** (§6.4): `:unknown` (defender stat not visible),
  `:fail` (band entirely below 0.5), `:mixed`, `:success` (band entirely
  above 0.5). Attempt gate per candidate per day: unknown → only on an
  `unknown_attempt_day`; fail → 25%; mixed → 50%; success → 95%. Survivors are
  sorted by expected success (band midpoint) descending and dealt to the
  available removers round-robin, nearest remover first.
- *Sabotage*: same attempt gate as remove. A saboteur always prefers a human
  fleet **in its current system or one hop away**. 75% of saboteurs are
  **wreckers** (station themselves in human systems/dominions and attack
  fleets sitting there); 25% are **guards** (roam rebellion-owned systems and
  hit visiting fleets).
- Role split among Erased ⚑: 40% infiltrate / 30% remove / 30% sabotage.
  Knob.

**Navarch**

- 30% **defense**: 60% of them post on border systems (rebellion systems in
  border/contested sectors or adjacent to uncontrolled ones), 40% on core
  systems (interior sectors, capital first). A rebellion system under siege
  pulls the nearest defender regardless of post.
- 70% **offense**: 80% **frontline** — targets in contested sectors or human
  sectors bordering uncontrolled/contested sectors (depth 0); 20% **deep
  strike** — human systems at sector depth ≥ 1, weighted `0.5^depth` ⚑ so
  the first target is much more likely one sector in than three.
- Offense action: 70 pillage (`loot`) / 30 bombard (`raid`), rolled per
  sortie.
- Fleets are **constructed, not produced** (§5.6): when a Navarch is at a
  rebellion-owned system, one ship from its blueprint materializes every
  **15 real minutes (5 ut)** until the blueprint is complete; then the
  Navarch is released to its role. An empty Navarch elsewhere travels home
  first.
- Wounded fleets (< 35% surviving hull ⚑) retreat to the nearest owned
  system and re-enter construction to refill lost tiles.

### 1.4 Agent strength

- Every 3 real days (1440 ut) compute, per type, the **average non-governor
  skill points** of all human characters of that type
  (`Enum.sum(Enum.take(character.skills, 3))` — indices 0..2 are the
  `:army`/`:spy`/`:speaker` skills for every type; 3..5 are the
  `:stellar_system` governor skills). Include deck, governor and on-board
  characters. Fall back to the other types' average, then 0.
- Target range: Siderian/Erased `[ceil(0.8·avg), ceil(1.1·avg)]`; Navarch
  `[ceil(0.5·avg), ceil(0.95·avg)]`. Never negative. If `hi − lo < 2`,
  widen by one on each side; if that would push `lo` below 1, push the
  deficit onto `hi` (so `[1,1] → [1,3]`, `[4,4] → [3,5]`, `[0,0] → [1,3]`).
- Recruits are created inside the range (§5.2). Existing agents whose
  non-governor points fall below `lo` at a review join the **training pool**:
  they travel back to the rebellion home sector and earn **2 XP per real
  hour (0.1 XP/ut)** passively until back in range, then return to duty.

### 1.5 Rebellion economy

- Systems owned by the rebellion (its `:inhabited_player` systems **and** its
  dominions) are developed by a **wave copy of the dominion behavior tree**
  ("Rebel Dominion", §4.3) with: no cadence delay, "if no slot is empty, go
  to upgrades instead of terminating", and 25% upgrade odds (down from 50%)
  when slots are empty.
- **Rebel Zeal**: ×2.5 system production for the rebellion faction only
  (§4.1).
- Because ships and agents are synthesized, the rebellion's production and
  credits do **not** gate its military; they feed defence buildings, pillage
  value, and the optional market recruitment mode.

---

## 2. Architecture

### 2.1 Process model

```
Instance.Supervisor (per instance)
 ├─ … existing agents (time, rand, market, galaxy, victory, diplomacy,
 │     factions, orchestrator, players, stellar systems, characters)
 └─ Wave.Warlord.Agent   ← NEW, one per wave instance, a Core.TickServer
        state: %Wave.Warlord{}  (roster/roles/pools/blueprint progress/timers)
        tick:  every 1.67 ut ± 0.5 (≈5 real min ± 90 s at Legacy)
        does:  build Wave.View → for each idle rebellion agent run its role
               tree (BT) → collect orders → execute via Wave.Bot.Act against
               the rebellion Player.Agent → record telemetry
```

Decisions:

- **One rebellion player, one commander.** The rebellion is a single real
  profile/registration (`wave-rebellion@tetrarchyfalls.local`, `is_bot: true`)
  in the bot faction, so every agent, system and dominion hangs off one
  `Instance.Player.Agent`. The Warlord is the faction brain. This avoids the
  cross-player pool coordination an N-bot design (the branch's `RC.Bots`)
  would need. Player caps are lifted by a wave bonus set (§4.2).
- **The Warlord is a `Core.TickServer` inside the instance tree**, not an
  external overseer. It is then started/stopped/paused/speed-cheated with the
  instance, snapshotted and restored by `Instance.Manager`, and its timers are
  pause-safe. Requirements: implement `on_call/3`, `on_cast/2`,
  `on_info(:tick, state)`, `do_next_tick/2`, `Wave.Warlord.compute_next_tick_interval/1`,
  start it in `Instance.Manager.do_init_from_model/4` when the instance is a
  wave game, and **add `Wave.Warlord.Agent` to `@snapshot_allowed_modules`**
  in `lib/game/instance/manager.ex` (otherwise snapshot restore rejects it).
  Do not use a plain GenServer (the `Game.News.Server` `@no_tick`/`@no_snapshot`
  wedge).
- **Engine state is the source of truth.** The Warlord persists only what the
  engine does not know: role assignments, pool membership, blueprint per
  Navarch and construction cursor, daily rolls, review timers, telemetry.
  On restore it re-derives the roster from the player state and drops
  assignments for characters that no longer exist. Every struct field is
  read with `Map.get/3` and written with `Map.put/3` (snapshot tolerance
  convention, `lib/game/instance/player/player.ex:88-104`).
- **Decision trees, not running behaviour trees.** Each idle agent is
  evaluated once per Warlord tick with a fresh tree (exactly how `SystemAI`
  uses the library). Long actions are the engine's action queue; the tree
  only decides *what to enqueue next*. No `:running` state is needed.
- **The rebellion reads the world omnisciently but acts on its own
  intelligence.** `Wave.View` reads galaxy/system/character state directly
  (cheap, and every shipped 4X AI does this), while the chance-class and
  infiltrate rules explicitly use the rebellion faction's *resolved
  visibility* so "unknown chances" means what it means for a human.

### 2.2 What is reused, ported, or new

| Concern | Source | Action |
|---|---|---|
| BT engine + parser + `mix extract_actions` | master (`lib/game/system_ai/*`, `lib/game/util/parser.ex`, `term_parser.ex`, hex `behavior_tree 0.3.1`) | reuse; add a keyed tree registry (§8.1) |
| Instance recipe | master `Daily.Boot.boot_persisted/2`, `Portal.InstanceController.do_fresh_start/3` | reuse pattern in `Wave.Boot` |
| Bot profile creation | master `Daily.Boot.ensure_profile/2` | copy pattern |
| Engine payload adapter | branch `lib/headless/bot/act.ex` (97 lines) | **port** as `Wave.Bot.Act` |
| Lane pathfinder (BFS hops) | branch `lib/headless/bot/nav.ex` (62 lines) | **port** as `Wave.Nav`, add Dijkstra by edge weight for travel time |
| Per-decision view builder | branch `lib/headless/bot/view.ex` (109 lines) | **port** as `Wave.View`, trimmed to one player |
| Driver GenServer | branch `lib/headless/bot.ex` | do **not** port; the Warlord replaces it. Borrow two ideas: `{:update_client_status, :connect}` on start so the bot player counts as active, and the per-kind ok/refused tallies |
| `bot_faction` column, registration lock, lobby tag, create-form select | branch migration `20260705150000_add_bot_faction_to_instances.exs`, `lib/rc/instances.ex`, `lib/rc/instances/instance.ex`, `lib/portal/controllers/registration_controller.ex`, `lib/portal/views/instance_view.ex`, `front/src/portal/pages/Instance.vue`, `front/src/portal/pages/play/New.vue`, locale keys | **port** |
| Orchestrator stale-lock self-heal | branch commit `9ac5be8` (`action_queue.ex` `lock_expired?/2`, `character.ex` `recover_from_stale_lock/1`); on branches `claude/great-chatelet-d96fae` etc., **not on master** | **port** — dozens of bot characters queuing continuously will hit lost round-trips |
| Interception death leaves a wedged head | branch diff to `conquest.ex`/`loot.ex`/`raid.ex` (`Character.abort_action` in the fled/died branch) | verify on master; port if the `else` branch still returns `{character, []}` |
| Runtime `SPEEDUP` | branch `lib/game/core/tick.ex` `speedup/0` (persistent_term) | **port** — makes soak runs tunable without recompiling |
| `Instance.Rand.Safe`, market `generate_character` rescue, galaxy `get_initial_system` nil-safety, player `:claim_initial_system` guard | branch | port opportunistically (hardening; low risk) |
| Arena blueprint generator | branch `lib/sim/blueprints.ex` + `mix sim.blueprints` (appless) | **port** — seeds the pool when mined data is thin (§7.4) |
| `RC.Bots`, `RC.Bots.Overseer`, `Headless.Policies.*`, marathon/dashboard tooling, `Headless.Strategist/Budget/Econ/Fitness` | branch | not needed |
| Everything under `lib/wave/` | — | new |

### 2.3 Module map (new code)

```
lib/wave/
  wave.ex                  Wave — mode constants, game_data["wave"] schema, knobs
  boot.ex                  Wave.Boot — instance creation, bot profile, registration, start
  config.ex                Wave.Config — read/validate knobs from metadata (rescue-guarded like Instance.Mutators.daily?/1)
  warlord.ex               Wave.Warlord — pure state + tick logic (roster, pools, phases, schedules)
  warlord/agent.ex         Wave.Warlord.Agent — the Core.TickServer wrapper
  view.ex                  Wave.View — per-tick snapshot (ported)
  nav.ex                   Wave.Nav — hop paths + weighted travel time (ported + Dijkstra)
  geometry.ex              Wave.Geometry — sector classes, depth, posts (pure)
  intel.ex                 Wave.Intel — visibility-aware chance classes (pure)
  recruit.ex               Wave.Recruit — skill ranges, recruit synthesis, spawn placement
  roles.ex                 Wave.Roles — pool targets, deficit-biased assignment, reviews
  training.ex              Wave.Training — training pool drip + homing
  blueprints.ex            Wave.Blueprints — pool loading, tiers, eligibility/deprecation, pick
  blueprints/miner.ex      Wave.Blueprints.Miner — extraction from player_report / player_events / snapshots
  construction.ex          Wave.Construction — the 15-min ship materialization loop
  schedule.ex              Wave.Schedule — roster + tech-tier schedules
  trees.ex                 Wave.Trees — loads priv/data/wave/*.json, runs a tree for an agent
  actions/common.ex        Wave.Actions.Common — BT actions shared by all roles
  actions/navarch.ex       Wave.Actions.Navarch
  actions/siderian.ex      Wave.Actions.Siderian
  actions/erased.ex        Wave.Actions.Erased
  bot/act.ex               Wave.Bot.Act — abstract order → Game.call payload (ported)
  telemetry.ex             Wave.Telemetry — counters + status map for /api/harness/wave
priv/data/wave/
  navarch.json  siderian.json  erased.json      the role decision trees (BT editor format)
  blueprints.json                               mined pool (committed artifact)
  blueprints.seed.json                          arena seed pool
priv/data/system_ai/behavior_tree_wave.json     "Rebel Dominion" build tree
lib/mix/tasks/wave.mine_blueprints.ex, wave.soak.ex, wave.preview_trees.ex
```

### 2.4 Time conversions used throughout (Legacy)

| Real | ut | Notes |
|---|---|---|
| 3 min | 1 | `Core.Tick.@unit_time_divider 180_000 / factor 1` |
| 5 min | 1.667 | Warlord cadence (jitter ±0.5 ut) |
| 15 min | 5 | construction cadence |
| 1 h | 20 | 2 XP/h = 0.1 XP/ut |
| 1 day | 480 | Erased daily rolls; note `Instance.Diplomacy.@ut_per_day 480` uses the same convention |
| 3 days | 1440 | spawn phase; strength review |
| 30 days | 14400 | default Legacy `time_limit` 43200 min |

Travel: `edge.weight × constant.character_movement_factor` (Legacy 7.2) ut per
hop; lanes are ≤ 12 units (`SpatialGraph.@max_dist`), so a hop is ≤ 86 ut
(≈ 4.3 real hours). Legacy action durations: `conquest_time 150`,
`raid_time 40`, `loot_time 20`, `make_dominion_time 150`,
`encourage_hate_time 50`, `infiltration_time 50` ut, the dice-based ones
multiplied by `Core.Dice.ratio_to_factor/1` (1.0–2.0). Timers must be kept
in ut and advanced from `elapsed_time` in `do_next_tick/2` — never
`Process.send_after` — so pause/resume and the speed cheat behave.

---

## 3. Instance lifecycle

### 3.1 Creation flow

`front/src/portal/pages/play/New.vue` → `POST /api/instances` →
`Portal.InstanceController.create/2` → `RC.Instances.create_instance/3`,
unchanged, plus:

- `game_mode_type: "wave"` (a new value; there is no server whitelist,
  `create_instance/3` copies it into `game_data` verbatim). Ranked is
  refused for wave games.
- `bot_faction: "<key>"` (ported column; validated to be one of the
  instance's factions).
- `game_data["wave"]` block written by `Wave.Boot.prepare_game_data/3`:

```elixir
%{
  "bot_faction" => "myrmezir",
  "human_faction" => "tetrarchy",
  "spawn_phase_ut" => 1440,
  "roster" => %{"base" => %{"admiral" => 1.0, "speaker" => 0.75, "spy" => 0.75},
                "per_wave" => %{"admiral" => 1, "speaker" => 0.5, "spy" => 0.5},
                "cap" => %{"admiral" => 12, "speaker" => 8, "spy" => 8},
                "wave_interval_ut" => 960},
  "tech" => %{"tiers_per_wave" => 1, "catch_up" => true, "ship_level_by_tier" => true},
  "roles" => %{"speaker" => %{"capture" => 0.4, "destabilize" => 0.3, "seduce" => 0.3},
               "spy" => %{"infiltrate" => 0.4, "remove" => 0.3, "sabotage" => 0.3,
                          "wreckers" => 0.75},
               "admiral" => %{"defense" => 0.3, "border" => 0.6, "frontline" => 0.8,
                              "pillage" => 0.7, "retreat_hull" => 0.35}},
  "recruitment" => "synthesize",          # | "market"
  "rebel_territory" => "home_sector",     # | "all_other_starts"
  "solvency_floor" => 50_000
}
```

  Defaults live in `Wave.defaults/0`; the form only exposes a handful
  (factions, difficulty preset). `Instance.Manager.do_init_from_model/4`
  caches `wave: game_data["game_mode_type"] == "wave"` and
  `wave_config: game_data["wave"]` in the metadata keyword list next to
  `daily:` (`lib/game/instance/manager.ex:350-376`); `Wave.Config.enabled?/1`
  and `Wave.Config.get/1` read them like `Instance.Mutators.daily?/1`.
- `mutators` gets the two rebellion entries appended (§4.1) with the faction
  scope.
- Sectors: every sector whose `"faction"` is neither the human nor the bot key
  becomes `"faction" => nil` (or the bot key when
  `rebel_territory == "all_other_starts"`).
- `faction_gov_enabled` is written **explicitly `false`** (an absent key
  grandfathers government ON at Legacy — `Instance.Faction.Government.enabled?/2`).
  The rebellion faction cannot vote and government adds nothing to the mode.
- `cheats_enabled` untouched (creator's choice).

### 3.2 Bot faction registration and start

After `publish_instance/2` (the user publishes from the instance page as
today), `Wave.Boot.ensure_rebellion_registered/1` registers the shared
rebellion profile into the bot faction
(`RC.Registrations.register_profile(faction, profile)`); this runs from the
publish path when `game_mode_type == "wave"` and is idempotent. The profile is
created like `Daily.Boot.ensure_profile/2` with `is_bot: true` set directly on
the account (`RC.Bots.mark_bot/1` pattern) so it is excluded from rankings and
search. One shared profile is fine: player agents are keyed
`{instance_id, :player, profile_id}`.

Start is the standard `do_fresh_start/3` sequence
(`create_from_model` → `Manager.call(:start)` → `Instances.start_instance/2`),
which is what the "Start" button already does; wave games use
`start_setting: "manual"` or `"auto"` like any other. At `:start` the Warlord:

1. `Game.call(iid, :player, bot_pid, {:update_client_status, :connect})` —
   without it the bot player flips `is_active: false` and
   `Instance.Victory.Faction.reset_player_count/2` counts 0 players for the
   rebellion, which collapses its population thresholds and inflates the
   humans' (`faction_weighting`). Re-issued after every restore, because
   snapshot restore zeroes `connected_clients`.
2. Reads `home_sector_ids` (sectors owned by the bot faction at boot) and the
   bot player's initial system.
3. Enters phase `:spawn`.

**Victory weighting** ⚑: even with one active bot player, a 5-human faction
gets `faction_weighting ≈ 1.29` and the rebellion `0.5`. For a survival mode
this asymmetry is wrong-way (bot milestones cheaper). Add a wave-only rule in
`Instance.Victory.Victory.update_tracks/1`: when `Wave.Config.enabled?/1`,
use `player_count = max(human_count, 1)` for **both** factions so the
weighting is 1.0 on each side. Gate strictly on the wave flag.

### 3.3 Humans

- Join via the lobby as today; `Portal.RegistrationController.join/2` refuses
  the bot faction with `:bot_faction_locked` (ported guard), `Instance.vue`
  shows the locked card.
- Late joins (`registration_type: "late_registration"`) hot-add through the
  existing `Instance.Manager.call(id, {:add_player, ...})`; the Warlord picks
  up the new human count on its next tick (roster schedule is a function of
  `n_humans`).
- Client mode flag: the game store currently infers mode from
  `time.speed === 'daily'`; that cannot work at Legacy. Add `wave: %{...}`
  to the `instanceInfo` payload assembled in `Portal.Controllers.GlobalChannel`
  (consumed at `front/src/game/store.js:137`) — see §10.

### 3.4 End of game

Unchanged: `Instance.Victory.Agent` ranks both factions, `record_victory/2`,
rankings (bot account excluded by `is_bot`), Discord post. The Warlord stops
with the tree. `RC.ProfileStats` already excludes dailies by
`game_mode_type`; extend the same filter to `"wave"` so PvE results don't
count toward career stats ⚑ (decision: exclude from ranked stats, include in
"games played").

---

## 4. Rebellion economy

### 4.1 Faction-scoped mutators ("Rebel Zeal", "Rebel Command")

Mutators are instance-global today (`Instance.Mutators.bonus_entries/1`).
Add a faction scope:

- `Data.Game.Mutator` catalog (`lib/data/game/mutator.ex`), two new entries,
  `daily_eligible: false`, `hook: :on_bonus`:
  - `:rebel_zeal` — `%Core.Bonus{from: :sys_production, to: :sys_production, type: :mul, value: 1.5}`
    (`:mul` adds `input × value` on top of the additive base, so 1.5 ⇒ ×2.5;
    cf. `:industrial_surge` = "+40%" with `value: 0.4`).
  - `:rebel_command` — `bonuses:` list of `:add` bonuses `direct → player_system +30`,
    `direct → player_dominion +30`, `direct → player_admiral +20`,
    `direct → player_spy +20`, `direct → player_speaker +20` (pipeline-out
    keys in `lib/data/game/content/bonus-pipeline-out.ex` map to
    `max_systems/max_dominions/max_admirals/max_spies/max_speakers`).
- `game_data["mutators"]` entries gain an optional `"faction"`:
  `%{"key" => "rebel_zeal", "faction" => "myrmezir"}`.
- `Instance.Mutators.bonus_entries/2` (new arity, `faction_key`) returns only
  entries whose scope is absent or equal to the faction; `Instance.Player.Player.extract_bonus/2`
  (`lib/game/instance/player/player.ex:1190`) calls it with `state.faction`.
  `active_keys/1` keeps its shape (used by `cost_multiplier` etc.).
- The bonus reaches systems through the existing
  `{:update_bonuses, :player, system_bonuses}` pushes on claim / policy
  events; nothing else to wire. Verify with a test that a human system in the
  same instance does **not** carry the `{:mutator, :rebel_zeal}` value part.

### 4.2 Solvency

Character wages and fleet maintenance drain `player_credit` via `:direct_last`;
`Player.is_bankrupt` (`credit.value <= 0 and credit.change < 0`) puts every
character `on_strike` and refuses hires/orders. The Warlord runs a solvency
guard each tick: if the bot player's `credit.value < solvency_floor`, cast
`{:add_resources, floor - value, 0, 0}` (engine-internal handler on
`Instance.Player.Agent`, used by loot). Telemetry counts top-ups so the drain
is visible when tuning.

### 4.3 "Rebel Dominion" build tree

Fork `priv/data/system_ai/behavior_tree.json` to
`priv/data/system_ai/behavior_tree_wave.json`, tree title `"Rebel Dominion"`
(keep the vanilla `"Dominion"` byte-identical; the SystemAI tests parse it by
name). Tree edits, using the node ids from the survey:

| Change | Edit |
|---|---|
| (d) 25% upgrade odds | `Upgrade` tree node `63d8bb01-…`: `"title": "SystemAI.Actions.succeed_upgrade?(0.25, 10)"` (`name` unchanged) |
| (a) no cadence | remove root child `36a8ab88-…` (`wait_for_population_growth(4)`); **keep** `f478322b-…` (`wait_if_queue_is_busy()`) so the queue holds one item at a time — "no delay" means the next order is placed the tick the previous completes |
| (c) upgrade when full | insert before the final `sequence[get_random_body, …]` root child: `sequence[ Wave.SystemAI.no_free_tiles?() ; Wave.SystemAI.choose_upgrade_category() ; SystemAI.Actions.upgrade_random() ; SystemAI.Actions.done() ]` — the trailing `done()` is the root-fail-loop guard |

Engine changes behind it (all in master files):

1. **Keyed tree registry.** `Instance.Galaxy.Galaxy.behavior_tree` becomes
   `%{dominion: node, rebel_dominion: node}` loaded from a list in
   `config :rc, RC.SystemAI` (`trees: [dominion: {path, name}, rebel_dominion: {path, name}]`);
   `Instance.Galaxy.Agent.on_call({:get_behavior_tree, key}, …)`;
   `SystemAI.do_action/3` takes the key (default `:dominion`). Better: cache
   the parsed tree in the system agent state on first use — at zero cadence
   the galaxy round trip per evaluation is waste.
2. **Cadence.** `@ai_next_action_unit_days 50` in
   `lib/game/instance/stellar_system/stellar_system.ex:10` becomes
   `ai_action_interval(state)` — `0` for rebellion systems, `50` otherwise.
3. **Scheduler.** `StellarSystem.compute_next_tick_interval/1` (`:191`) must
   include the AI's next-action time for AI-driven statuses; today it returns
   `:never` for an idle system with a flat population and `Core.Tick.next/2`
   cancels the timer, so "no delay" would mean "never runs again".
4. **Bot-owned player systems.** `auto_actions/2` (`:912`) guard gains
   `or (state.status == :inhabited_player and Wave.Config.bot_system?(state))`
   where `bot_system?` compares `state.owner.faction` to the cached
   `wave_config["bot_faction"]`. Tree key: `:rebel_dominion` for rebellion
   systems and dominions, `:dominion` for everyone else.
5. **Infra/hab upgrade eligibility.** `SystemAI.Helper.get_upgradable_tiles/3`
   filters by profile output; `infra_*` (`[:hab, :happiness]`) and `hab_*`
   (`[:hab]`) never qualify, and `order_building_production/2` throws
   `:not_upper_than_infra` for any non-orbital tile above the infra level, so
   a saturated body freezes at level 1. `Wave.SystemAI.choose_upgrade_category/1`
   therefore adds a synthetic `:infrastructure` category (tile 1 of each
   planet, then habitations) and picks a category weighted by `ai_profile`
   **restricted to categories with a non-empty upgradable set** (the
   `get_categories_proportion_built` consistency doctrine at
   `helper.ex:108-117` — a drawn-but-empty category is how the tree hangs).
6. **`build_workforce/1` bug** (`actions.ex:261-277`): filters body `type in
   [:open, :dome]` but body types are `:habitable_planet | :sterile_planet |
   :moon | :asteroid`, so it always fails, and would `CaseClauseError` if it
   passed. Fix: `type in [:habitable_planet, :sterile_planet]` and map
   through `Helper.body_type_to_biome_key/1`. ⚑ This also changes vanilla
   neutral behaviour (they will start building workforce buildings) — confirm
   with the user before shipping; it is a real bug.
7. **Player copy staleness.** AI orders bypass `Player.update_stellar_system/2`.
   Tag `:player_update` in the change set after an AI order on a bot-owned
   `:inhabited_player` system so the bot player's cached system list stays
   coherent (only matters for the rebellion's own reads).

Keep the anti-loop regression test shape from
`test/game/system_ai/unique_building_filter_test.exs` ("a saturated body ends
the action instead of looping") for the new tree — a broken tree **hangs**
the suite rather than failing it.

---

## 5. Recruitment, strength, roles, construction

### 5.1 Roster and reviews

`Wave.Schedule.desired_roster(config, day_ut, n_humans)` (pure):

```
w        = if day_ut < spawn_phase_ut, do: 0, else: 1 + div(day_ut - spawn_phase_ut, wave_interval_ut)
desired  = min(cap[type], ceil(base[type] * n_humans) + floor(per_wave[type] * w))
```

Each tick, for each type with `alive_count < desired`, recruit at most one
agent per type per tick (throttle knob `recruits_per_tick`). Losses are
therefore replaced within minutes; the roster ratchets up one wave at a time.
Telemetry records `wave_index` transitions and emits a news-ticker entry
(`Game.News.emit(iid, "wave.started", %{wave: w, ...})`) so humans see the
escalation in the ticker.

Every `review_interval_ut` (1440): recompute skill ranges (§1.4), move
under-range agents to the training pool, rebalance roles against the pool
targets (§5.4). Also re-read `n_humans`.

### 5.2 Recruit synthesis (default) and market mode

`Wave.Recruit.range(avg, type)` implements §1.4 exactly (unit-tested against
the examples). `Wave.Recruit.synthesize(iid, type, range, faction_key)`:

1. `{:ok, id} = Game.call(iid, :character_market, :master, :get_next_character_id)`.
2. `Character.Character.new(id, type, rank, nth, iid, %{culture, spec1, spec2, skills})`
   — the `initial_data` clause pins `skills` (a 6-list) and sets
   `initial_skill_points = 0`, `initial_experience = 15`. Choose
   `spec1/spec2` from the type's non-governor specializations; distribute
   `total = rand(lo..hi)` points across indices 0..2 weighted 8/5/1 toward
   `spec1/spec2`, zero in 3..5; rank by total (`:common` < 4, `:remarkable`
   < 9, `:exceptional` otherwise) so protection/determination ranges match
   what a human of that strength would have (`Data.Game.CharacterRank`).
   Culture from `Data.Game.Faction` of the bot faction.
3. Place: `Game.call(iid, :player, bot_pid, {:convert_character, character, system_id})`
   — the dev-fixture spawn primitive (`lib/game/instance/player/agent.ex:773`):
   mints the id, activates `:on_board` at `system_id`, starts the character
   agent, pushes it into the system. No slot check beyond the caps, no cost.

Market mode (`"recruitment" => "market"`): read
`Game.call(iid, :character_market, :master, :get_state)`, filter slots by type
and `sum(take(skills,3)) in lo..hi`, hire with
`{:hire_character, id}` (needs credit/tech/ideology — the solvency guard
tops up credit only, so market mode also needs tech/ideology floors), then
`{:activate_character, id, :on_board, system_id}` (own systems only). Fall
back to synthesis when no slot matches. Market mode competes with humans for
the shared 24-slot market (refill cooldown `market_cooldown_duration` 200 ut
at Legacy ≈ 10 real hours) — ship it as an option, not the default.

### 5.3 Spawn placement

`Wave.Recruit.spawn_system(view, geometry)`: 80% a rebellion-owned system in
a **border** sector, 20% one in a **core** sector (both as classified by
`Wave.Geometry`, §6.1). With a single rebellion sector everything is border;
the 20% then falls back to the capital. Spawn locality is recorded on the
roster entry (`:border | :core`) for role assignment.

### 5.4 Roles and pools

`Wave.Roles.targets(config, counts)` turns the ratios into integer targets per
role per type (largest-remainder rounding). `Wave.Roles.assign(entry, pools)`
picks the role with the largest deficit `target − assigned`; ties prefer the
role matching spawn locality (border → offense/border-defense/wreckers;
core → core-defense/guards/infiltrators). At each review, agents are
re-shuffled only when a role's deficit exceeds 1 (hysteresis, so agents don't
ping-pong). Roles:

| Type | Roles |
|---|---|
| `:admiral` | `:defense_border`, `:defense_core`, `:offense_frontline`, `:offense_deep`, plus transient states `:constructing`, `:training`, `:retreating` |
| `:speaker` | `:capture`, `:destabilize`, `:seduce`, `:training` |
| `:spy` | `:infiltrate`, `:remove`, `:sabotage_wrecker`, `:sabotage_guard`, `:training` |

### 5.5 Tech tier schedule

`Wave.Schedule.tech_tier(config, w, human_signal)` = `min(8, 1 + tiers_per_wave × w)`
before catch-up; with `"catch_up" => true`, never lower than
`human_best_fielded_tier − 1`, where the human signal is the highest tier
(by `Sim.Blueprints`' ladder) of any ship key seen in human armies
(`Wave.View` reads human character armies directly). Tiers reuse the branch
ladder (`t1_scouts … t8_capitals`, cumulative patent sets). Tier changes are
telemetry + ticker events.

### 5.6 Navarch construction

`Wave.Construction` per Navarch: `{blueprint_id, cursor}`.

- Trigger: Navarch is `:idle`/`:docking`, queue empty, at a rebellion-owned
  system, and has empty tiles relative to its blueprint. If it has **no**
  ships and is not at an owned system, enqueue a move-only path home first.
- Every 5 ut (per-Navarch timer advanced from `elapsed_time`): take the next
  `{tile, ship_key}` of the blueprint that is not filled and
  `Game.call(iid, :character, cid, {:order_ship, {nil, tile, ship_key, nil}})`
  then `Game.cast(iid, :character, cid, {:put_ship, tile, initial_xp})` — the
  `Sim.Fleet.build/2` path; no production, credits, tech, patents or shipyard
  involved. `initial_xp` = 0, or the tier's ship level when
  `"ship_level_by_tier"` (difficulty lever; ship level scales strikes +1%/lvl
  and hull handling, `lib/game/fight/ship.ex:31`).
- Complete ⇒ role released; stance set once per Navarch
  (`{:update_reaction, cid, :attack_enemies}` — Interdiction; `:flee` while
  retreating).
- Losses: wounded fleets (`army_health < retreat_hull`) get a move-only path
  to the nearest owned system and re-enter construction there. Ship
  destruction empties the tile; construction refills it from the blueprint.
- A blueprint is chosen at Navarch spawn by role (defense roles →
  `:defense`/`:intercept` blueprints, offense → `:raid_*`), from the tiers the
  rebellion has unlocked (§7.3). When a Navarch's blueprint is deprecated by a
  tier change it finishes the current one; the next rebuild (after losses)
  re-picks.

### 5.7 Training pool

`Wave.Training`: an entry below its range is tagged `:training`; if it is
outside `home_sector_ids` it receives a move-only path to the capital (or
nearest home-sector owned system). Each tick the Warlord casts
`{:add_experience, 0.1 × elapsed_ut}` to every trainee's character agent
(`Instance.Character.Agent.on_cast({:add_experience, amount}, …)`, the
Training Center hook). Level-ups add a skill point weighted 8/5/1 toward the
character's specializations (`Character.add_skill_point/2`), so with
non-governor `spec1/spec2` most points land where they count. When
`sum(take(skills,3)) >= lo`, the agent leaves the pool and is re-assigned.

---

## 6. Targeting library

All pure functions over a `%Wave.View{}`; unit-tested with hand-built
`Instance.Galaxy.Galaxy` structs (`Test.FleetScenario` builders).

### 6.1 `Wave.Geometry`

Inputs: `galaxy.sectors` (`owner`, `adjacent`, `division`, `starter?`),
`galaxy.stellar_systems` (`faction`, `status`, `sector_id`), the two faction
keys `r` (rebellion) and `h` (human).

Definitions (all recomputed per tick; ownership only changes on claims):

- `held(s, f)` = count of inhabited systems (`class != nil`) in sector `s`
  with `faction == f` (the same rule `Sector.update_owner/2` uses).
- `contested?(s)` = `held(s, r) > 0 and held(s, h) > 0`.
- Sector class for `r`:
  - `:core` — `owner == r`, not contested, every adjacent sector `owner == r`;
  - `:border` — `owner == r` and (contested or any adjacent sector `owner != r`);
  - `:frontier` — `owner == nil` and adjacent to a sector with `owner == r`;
  - `:enemy_border` — `owner == h` and (contested or adjacent to a non-`h` sector);
  - `:enemy_interior` — `owner == h`, all adjacent `owner == h`;
  - `:far` — everything else.
- `depth(s)` for human sectors = BFS distance over `adjacent` from the nearest
  sector with `owner != h` (0 = enemy_border).
- `posts(view)`: `border_posts` = rebellion systems in `:border` sectors,
  sorted by number of adjacent non-rebellion sectors desc, then by proximity
  to the nearest human system; `core_posts` = rebellion systems in `:core`
  sectors, capital first. With one rebellion sector, `core_posts` falls back
  to the capital.
- Human targets: `frontline_targets` = human systems in `:enemy_border`
  sectors (depth 0) plus systems in contested sectors; `deep_targets` =
  human systems with depth ≥ 1, each with weight `0.5^depth`.

### 6.2 `Wave.Nav` (ported + extended)

- `path_hops(galaxy, from, to)` — BFS hop pairs (branch code).
- `travel_ut(galaxy, from, to, movement_factor)` — Dijkstra over
  `galaxy.edges` weights × factor; used to break ties by real distance and to
  estimate arrival for the "distribute by distance" rules.
- Adjacency is built once per tick and cached in the view (`galaxy.edges` is
  flat; BFS per agent over 6k systems is fine at a 5-minute cadence but do not
  rebuild the map per call).

### 6.3 Legality filters (code, never tree data)

Every terminal action re-checks the engine's own preconditions so orders are
not silently dropped (`ActionImpl.pre_validate_action/2` swallows throws and
`Act` cannot see it):

- `make_dominion`: speaker not on cooldown (`Speaker.locked?`), rebellion
  `available_dominion_slot?`, target status in `[:inhabited_neutral, :inhabited_dominion]`,
  `{:check_system_takeability, id, r} == {:ok, :takeable}`, not own.
- `loot`/`raid`: Navarch has ships, target inhabited, not own, `siege == nil`,
  no duplicate of the same action queued.
- `conversion`/`assassination`/`sabotage`: target character currently in the
  target system (re-read on arrival — the tree runs again when the agent is
  idle in place; the terminal action is issued only when the agent is
  **already** in the target system, so travel and attempt are two decisions).
- `infiltrate`: target inhabited; no duplicate queued.
- Every itinerary is one `add_character_actions` push: hop jumps + terminal
  action, with `data.target` equal to the queue's `virtual_position` after the
  hops (strict chaining). After the push, read back
  `{:get_character_state, cid}`; if the queue is shorter than pushed, count a
  refusal and let the next tick retry.
- Reserved targets: a per-tick `MapSet` of systems/characters already
  claimed by another agent this tick (stacking allowed only for
  `encourage_hate` and for wreckers in the same fleet-rich system).

### 6.4 `Wave.Intel` — chance classes

Mirror of `Core.Dice` (`lib/game/core/dice.ex`) and the client preview
(`front/src/game/components/galaxy/system/ActionOverview.vue:56-67`):

```
ratio = attacker / (attacker + defender)   (0.5 when both 0)
lo    = max(ratio - 0.20 + 0.01 * min(level, 20), 0)
hi    = min(ratio + 0.20, 1)
class = cond do hi <= 0.5 -> :fail; lo >= 0.5 -> :success; true -> :mixed end
midpoint = (lo + hi) / 2
```

Inputs per action (from the action modules):

| Action | attacker | defender | "known" when rebellion visibility of the target system is… |
|---|---|---|---|
| `assassination` | `spy.assassination_coef.value` | `target.protection` (+ `system.counter_intelligence.value` if the target's faction owns the system) | ≥ 5 for `protection` (`StellarSystem.Character.obfuscate/2`), ≥ 4 for CI |
| `sabotage` | `spy.sabotage_coef.value` | same as above | same |
| `conversion` | `speaker.conversion_coef.value` | `max(target.determination (+ system.happiness if same faction as owner), 0)` | ≥ 4 determination, ≥ 3 happiness |
| `infiltrate` | `spy.infiltrate_coef.value` | `system.counter_intelligence.value` | ≥ 4 |
| `encourage_hate`, `make_dominion` | speaker coef | `max(system.happiness.value, 0)` | ≥ 3 |
| `loot`/`raid` | `army.raid_coef.value` | `system.defense.value` | ≥ 2 |

Visibility = `Instance.Faction.Faction.resolve_system_visibility(faction_state, system).value`
using the rebellion's faction state (`Game.call(iid, :faction, r_id, :get_state)`,
read once per tick) and the full system state. Unknown ⇒ `:unknown`. The
Erased daily gates consume the class; Navarch and Siderian roles use the
class only for ordering ties (not requested as a gate) — knob
`erased_only_gating: true`.

### 6.5 Erased daily distribution

`Wave.Actions.Erased.plan_removals(view, removers, rolls)`:

1. candidates = visible human characters (`system.characters` for systems
   with visibility ≥ 2; governors from `system.governor` on
   `governors_allowed` days; undercover Erased excluded).
2. class + gate per candidate per day (rolls cached in
   `warlord.daily[day_index][candidate_id]` so a target is decided once per
   day, not per tick).
3. sort by midpoint desc; assign round-robin to removers sorted by
   `travel_ut` to the candidate; each remover gets at most one target per
   day; a remover already travelling keeps its target.

Same planner for saboteurs with `target.type == :admiral` and the "fleet
within one hop of the agent" override applied first.

### 6.6 Roaming

When a role has no legal target: Siderians in seduce mode and Erased
removers/wreckers move to the nearest human system with the highest
`population` among those with visibility < 5 (explore + get visibility), else
to the nearest frontline human system; guards patrol between `border_posts`.
Roaming is a move-only itinerary of at most 3 hops per decision.

---

## 7. Fleet blueprint pool

### 7.1 Data shape (`priv/data/wave/blueprints.json`)

```json
{ "generated_at": 1780000000, "speed": "slow",
  "blueprints": [
    { "id": "bp_9f3a…",
      "slots": [[1,"fighter_4v2",0],[2,"fighter_4v2",0],[4,"corvette_1",0]],
      "counts": {"fighter_4v2": 2, "corvette_1": 1},
      "patents": ["shipyard_1","fighter_2","fighter_4","merge_fighter_1","shipyard_2","corvette_1"],
      "tier": 4,
      "roles": ["raid"],
      "evidence": {"pillages": 3, "bombards": 1, "fights_won": 2, "fights_survived": 4},
      "score": {"margin": 0.31, "win_rate": 0.7, "bomb": 24.0, "credit": 61400},
      "sources": [{"instance_id": 121, "event": "loot", "id": 88123}]
    } ] }
```

Tile positions are kept: `Fight.Army.get_ready_ships/2` commits one line of
three tiles every two turns, so tiles 1–3 are the vanguard and 16–18 arrive
around turn 11. Two fleets with the same counts and different layouts are
different designs. `patents` = `Sim.Cost.required_patents(slots)`; `tier` =
the lowest ladder tier whose cumulative patent set covers `patents`.

### 7.2 Mining (`Wave.Blueprints.Miner`, `mix wave.mine_blueprints`)

Run against a **locally restored production backup** (`db-restore.sh`),
never the live DB. Filter instances with `game_data->>'speed' = 'slow'`
(knob `--speeds`). Sources, in order of value:

1. `player_report` (`type = 'fight'`): `report::json -> initial.attackers[] / defenders[]`
   carry both sides' full 18-tile armies (`army.tiles[].ship.{key,level,units[].hull}`);
   `metadata::json ->> 'result'` is the owning player's status
   (`victorious | dead | fleeing`). One row per participating player; take
   the winner's side as `fights_won`, `fleeing` survivors with ≥ 50% hull as
   `fights_survived`.
2. `player_events` (`type = 'box'`, `key IN ('loot','raid')`,
   `data->>'side' = 'attacker'`, `outcome IN ('normal_success','critical_success')`):
   `data -> 'admiral' -> 'current' -> 'army' -> 'tiles'` is the attacker's
   fleet (vis 5 on the attacker's own row; defender rows have `ship: null`).
   `loot` rows carry the amounts and `balance_of_power`.
3. Optional: the last snapshot ETF per finished instance
   (`instance_snapshots.name` → S3 `snapshots/<name>` or `priv/_storage/`,
   `:erlang.binary_to_term(_, [:safe])`): every `Instance.Character.Agent`
   state's `data.army.tiles` — "what people kept fielded".

Normalization: drop empty/planned tiles, keep `{tile, key, level}`, hash the
sorted slot list, merge evidence per hash, discard fleets with fewer than 4
ships or containing `transport_1`. Role tags: `raid` from loot/raid events
and fights won as attacker; `defense` from fights won as defender;
`intercept` from fights won as attacker with no siege in the same
`instance_event_log` window (best effort — fine to skip in v1). Score each
survivor offline with `Sim.Arena.matchup/3` against the tier's gauntlet
(`Sim.Blueprints.gauntlet_keys/1`) so the pool has a strength ordering.

### 7.3 Eligibility and deprecation

`Wave.Blueprints.eligible(pool, unlocked_patents, role)`:

- every `patent` ∈ `unlocked_patents`;
- **not deprecated**: no ship key in `slots` has an unlocked `merge_to`
  successor (`Data.Game.Ship.merge_to`, e.g. `fighter_1 → fighter_1v2` once
  `merge_fighter_1` is unlocked). Merge tiers have identical combat stats and
  2×/4×/8× the units, so deprecation is exactly "the pool moves to stronger
  fleets".
- If a role's eligible set is empty, **promote**: substitute each deprecated
  key with its highest unlocked successor in place and use that (tagged
  `promoted: true` in telemetry).

Pick: weighted by `score.margin` (defense/intercept) or `score.bomb`
(raid), with a `blueprint_mix` knob choosing among the top 3 so fleets vary.

### 7.4 Seed pool

Port `Sim.Blueprints` and run `mix sim.blueprints` once (appless, hours of
CPU; use `ERL_FLAGS="+S 4"`); convert its per-tier champions/counters into
`blueprints.seed.json` with roles `defense | intercept | raid` mapped from
the arena goals. The loader unions seed + mined pools and prefers mined
entries when both exist for a tier/role. Also carry the branch's two
hand-crafted `invasion_column_*` blueprints if conquest is enabled later.

---

## 8. Behavior-tree encoding

### 8.1 Engine generalization (small, in master files)

- Move the BT plumbing to `lib/game/bt/`: `Game.BT.Parser` (was
  `Instance.SystemAI.Parser` in `lib/game/util/parser.ex`),
  `Game.BT.TermParser`, and a new `Game.BT.Runner.run/3` that is
  `SystemAI.step/1` generalized: `run(tree, context, state)` → `{:ok, state}
  | {:error, reason}`, same action contract (`:succeed | :fail |
  {:succeed, map} | {:done, state} | {:error, reason}`). `SystemAI` delegates.
  Keep module aliases so `mix extract_actions` and the tests still resolve.
- Add a **step budget** to the runner (e.g. 500 steps → `{:error, :bt_runaway}`)
  so a root-fail loop can never hang a process again; log the tree name.
- Delete or implement the dead editor node types (`wait`, `log`, `error`,
  `succeed_rate`, `done` compile to a non-existent `BT.Actions` module and
  crash at step time). Implement `Game.BT.Actions` with those five so trees
  authored in the editor work.
- Keyed loading: `Game.BT.Trees.load(spec)` returns `%{key => Node}` from a
  keyword config; galaxy holds the dominion pair (§4.3), the Warlord holds
  the wave trio (parsed once at init; the JSON is data, not snapshot state —
  do not store parsed nodes in the snapshot, reload on restore).
- Randomness stays **in actions** via the instance rand agent
  (`Game.call(iid, :rand, :master, {:uniform})`), never the library's
  `random`/`random_weighted` nodes (they use the process PRNG and break
  determinism and the `FakeRand` test recipe).

### 8.2 Tree evaluation contract for agents

`Wave.Trees.decide(tree, view, entry, warlord)`:

- `context` (the blackboard): `%{view:, agent:, entry:, role:, r:, h:, geometry:, intel:, rolls:, reserved:}`
  plus whatever actions merge in via `{:succeed, map}` (e.g. `bucket`,
  `target`, `hops`).
- `state` (mutated only by terminal actions): `%Wave.Decision{orders: [], reserve: [], note: nil}`.
- Terminal actions return `{:done, %Wave.Decision{}}`; the Warlord executes
  `orders` through `Wave.Bot.Act`, merges `reserve` into the tick's reserved
  set, and records `note` in telemetry.
- Non-terminal actions are conditions (`:succeed | :fail`) or choosers
  (`{:succeed, %{target: id}}`). Weights are **tree arguments**, e.g.
  `Wave.Actions.Siderian.pick_capture_target(80, 15, 5)`, so designers tune
  them in JSON without code changes.

### 8.3 Tree sketches (authored in `priv/data/wave/*.json`)

**navarch.json**
```
select
├─ sequence[ Common.role_is?(:training) ; Common.go_home() ]
├─ sequence[ Navarch.wounded?() ; Navarch.retreat_home() ]
├─ sequence[ Navarch.construction_pending?() ; Navarch.construct_or_go_home() ]
├─ sequence[ Common.phase_is?(:spawn) ; Navarch.hold_post() ]
├─ sequence[ Common.role_in?([:defense_border, :defense_core]) ;
│            select[ sequence[ Navarch.siege_nearby?() ; Navarch.relieve_siege() ] ,
│                    Navarch.hold_post() ] ]
├─ sequence[ Common.role_is?(:offense_frontline) ; Navarch.pick_frontline_target() ;
│            Navarch.pick_sortie(70) ; Navarch.sortie() ]
├─ sequence[ Common.role_is?(:offense_deep) ; Navarch.pick_deep_target(0.5) ;
│            Navarch.pick_sortie(70) ; Navarch.sortie() ]
└─ Common.idle()
```

**siderian.json**
```
select
├─ sequence[ Common.role_is?(:training) ; Common.go_home() ]
├─ sequence[ Siderian.on_cooldown?() ; Common.idle() ]
├─ sequence[ Common.role_is?(:capture) ; Siderian.pick_capture_target(80, 15, 5) ; Siderian.travel_or_act("make_dominion") ]
├─ sequence[ Common.role_is?(:destabilize) ; Common.phase_is?(:assault) ; Siderian.pick_destabilize_target(80, 20) ; Siderian.travel_or_act("encourage_hate") ]
├─ sequence[ Common.role_is?(:seduce) ; Common.phase_is?(:assault) ;
│            select[ sequence[ Common.roll(50) ; Siderian.pick_governor_target() ] ,
│                    Siderian.pick_agent_target() ] ;
│            Siderian.travel_or_act("conversion") ]
├─ Common.roam()
└─ Common.idle()
```

**erased.json**
```
select
├─ sequence[ Common.role_is?(:training) ; Common.go_home() ]
├─ sequence[ Erased.fleet_within_one_hop?() ; Common.role_in?([:sabotage_wrecker, :sabotage_guard]) ;
│            Erased.attempt_gate("sabotage") ; Erased.travel_or_act("sabotage") ]
├─ sequence[ Common.role_is?(:infiltrate) ; Common.phase_is?(:assault) ; Erased.pick_infiltrate_target(75, 25) ; Erased.travel_or_act("infiltrate") ]
├─ sequence[ Common.role_is?(:remove) ; Common.phase_is?(:assault) ; Erased.assigned_removal_target?() ; Erased.travel_or_act("assassination") ]
├─ sequence[ Common.role_is?(:sabotage_wrecker) ; Common.phase_is?(:assault) ; Erased.pick_wrecker_station() ; Common.travel_only() ]
├─ sequence[ Common.role_is?(:sabotage_guard) ; Erased.pick_guard_station() ; Common.travel_only() ]
├─ Common.roam()
└─ Common.idle()
```

`travel_or_act(action)` is the key composite: if the agent is already in the
target system it emits the terminal action; otherwise it emits the hop
itinerary only (arrival makes the agent idle in place; the next tick re-runs
the tree, re-validates, and acts). Each action module lists its functions
with `@doc` so `mix extract_actions --actions-dir lib/wave/actions/` publishes
the palette for the editor.

---

## 9. Engine change checklist

**Must (mode does not work without):**

| File | Change |
|---|---|
| `lib/game/instance/manager.ex` | start `Wave.Warlord.Agent` in `do_init_from_model/4` for wave games; add to `@snapshot_allowed_modules`; cache `wave:`/`wave_config:` metadata |
| `lib/game/instance/mutators.ex`, `lib/game/instance/player/player.ex:1190`, `lib/data/game/mutator.ex` | faction-scoped mutators + `rebel_zeal`/`rebel_command` |
| `lib/game/instance/stellar_system/stellar_system.ex` | cadence per system, scheduler includes AI timer, `auto_actions` guard for bot `:inhabited_player`, tree key selection, `:player_update` tag |
| `lib/game/system_ai/*`, `lib/game/util/parser.ex`, `config/config.exs` | keyed tree registry; `Wave.SystemAI` actions; upgrade-category fix; runner step budget |
| `lib/game/instance/galaxy/galaxy.ex`, `galaxy/agent.ex` | tree map + `{:get_behavior_tree, key}` |
| `lib/game/instance/character/action_queue.ex`, `character/character.ex` | port stale-lock self-heal (`9ac5be8`) |
| `lib/game/instance/character/actions/{conquest,loot,raid}.ex` | verify/port abort-on-interception-death |
| `lib/game/instance/victory/victory.ex` | wave-only equal `player_count` weighting |
| `lib/rc/instances/instance.ex`, `lib/rc/instances.ex`, migration | `bot_faction` column + validation (ported) |
| `lib/portal/controllers/registration_controller.ex`, `lib/portal/views/instance_view.ex` | `:bot_faction_locked`, expose `bot_faction` (ported) |
| `lib/portal/channels/controllers/global_channel.ex` | `instanceInfo.wave` |
| `lib/rc/profile_stats.ex` | exclude `"wave"` like `"daily"` |
| `lib/game/core/tick.ex` | runtime `SPEEDUP` (ported) |

**Should (quality/hardening):** `Instance.Rand.Safe`, market
`generate_character` rescue, `Galaxy.get_initial_system/3` nil-safety,
`Player.Agent :claim_initial_system` guard, `build_workforce` bug fix (after
confirmation), `Game.BT.Actions` for the editor's built-in nodes, BT module
relocation.

---

## 10. Frontend

- `front/src/portal/pages/play/New.vue`: game mode radio gains `wave`
  (visible on `slow` scenarios; the `canBeRanked` forcing to `casual` at
  lines 334-336 must not override it), human/rebellion faction selects
  (rebellion select = ported `bot_faction` select), a difficulty preset
  (maps to `game_data["wave"]` knobs). Ranked disabled.
- `front/src/portal/pages/Instance.vue`: rebellion faction card locked
  (ported), wave badge, "humans vs rebellion" copy.
- `front/src/portal/pages/Play.vue` + `router.js`: a `/play/wave` entry
  listing open wave games (model on `Legacy.vue`, not `Daily.vue` — this is
  lobby play).
- In game: `store.js` `instanceInfo.wave` → a small **Rebellion panel/banner**
  (wave index, next wave ETA, rebellion tech tier, roster counts if the
  design wants them visible; at minimum wave index + ETA). Ticker already
  shows `wave.started` news.
- Locales: `page.play.new.game_mode_types.wave`, `page.play.wave.*`,
  `page.instance.bot_faction_*` (ported), `game.wave.*`, and
  `data.mutator.rebel_zeal/rebel_command` names in `en/fr/de`.

---

## 11. Testing and tuning

- **Pure units** (fast, `async: true`): `Wave.Recruit.range/2` (the four
  worked examples + negatives + avg 0), `Wave.Schedule` (roster/tier tables),
  `Wave.Geometry` (hand-built 4-sector galaxies: core/border/frontier/enemy
  depth), `Wave.Intel.chance_class/…` against the Dice band, `Wave.Blueprints`
  eligibility/deprecation/promotion, `Wave.Roles` largest-remainder targets
  and deficit assignment with hysteresis, faction-scoped `bonus_entries/2`.
- **Tree units**: the `unique_building_filter_test.exs` recipe — parse the
  JSON, register a fake galaxy `:get_behavior_tree`, use
  `Test.FleetScenario.spawn_fake_rand/2` (`uniform_value`, `random_index`) to
  steer bucket rolls, assert the emitted `%Wave.Decision{orders: …}`. One
  test per role per branch, plus a "no legal target ⇒ idle, never loops" test
  for each tree and for `Rebel Dominion` (the runner step budget turns a hang
  into a failure).
- **Instance boot test** (`test/wave/boot_test.exs`, DB, `async: false`):
  build a 2-faction Legacy `game_data` from `test/support/scenario_game_data.json`
  (or port `Headless.Scenario.generate/1` as `Test.WaveMap` for a 4-band
  30-system map), run `Wave.Boot`, assert the Warlord is registered, the bot
  player is active, `rebel_zeal` is on the rebellion's system and not on the
  human's, and a `{:debug, :force_phase, :assault}` call followed by a
  `{:debug, :tick, 10}` call produces recruits and orders (debug handlers are
  compiled only when `Mix.env() in [:dev, :test]`).
- **Soak** (`mix wave.soak --days N --speedup 40`): dev container, runtime
  `SPEEDUP` + `{:cheat_set_speedup, 50}` (both multiply the factor), Legacy
  content, an idle human faction (systems still grow), prints per-wave
  telemetry: recruits by type, orders ok/refused by kind, pillage credit
  taken, dominions captured, agents removed, bankruptcies avoided, BT step
  counts. This is the tuning loop for the knob defaults; run it before the
  first human playtest. At 50× a 3-day spawn phase is ~1.7 real hours.
- **E2E** (`bin/e2e.ps1`): create a wave game from the UI, join the human
  faction, verify the rebellion card is locked, start, see the wave banner.

All Elixir tests run through `docker compose exec` (host Elixir is
forbidden); chown new host-created files to `rc` first; read
`.dev-ports.json` before touching the app.

---

## 12. Implementation phases (hand-offs)

Each phase lands as its own branch off `master` (follow-ups never stack on a
merged branch), with tests, and updates this doc's status line.

**Phase 0 — Foundations port.** Port from the game-AI branch: `bot_faction`
migration/schema/validation/lock/view, `Wave.Bot.Act`, `Wave.Nav`,
`Wave.View`, stale-lock self-heal, interception-death abort (verify first),
runtime `SPEEDUP`, `Sim.Blueprints` + task, hardening items. Generalize the
BT runner with a step budget and keyed loading; implement `Game.BT.Actions`.
*Accept:* existing suites green; `mix sim.blueprints --tiers t1_scouts --gens 1`
runs; a tree with an unconditional root fail returns `{:error, :bt_runaway}`.

**Phase 1 — Lifecycle skeleton.** `Wave`, `Wave.Config`, `Wave.Boot`
(game_data preparation, sector rewrite, rebellion profile, registration on
publish), manager metadata + Warlord `Core.TickServer` with phases and
telemetry only (no roles yet), victory weighting, `instanceInfo.wave`,
profile-stats exclusion, harness status endpoint `GET /api/harness/wave/:iid/status`.
*Accept:* boot test passes; instance survives `:make_snapshot` → restore with
the Warlord intact; pausing the instance freezes Warlord timers.

**Phase 2 — Rebellion economy.** Faction-scoped mutators, `rebel_zeal`,
`rebel_command`, solvency guard, `behavior_tree_wave.json`, keyed tree
registry, cadence/scheduler/guard changes, upgrade-category action, infra
upgrade eligibility, (confirmed) `build_workforce` fix.
*Accept:* rebellion system shows ×2.5 production detail; a saturated
rebellion system upgrades instead of freezing; vanilla `"Dominion"` tests
unchanged; human systems unaffected.

**Phase 3 — Recruitment and construction.** `Wave.Recruit`, `Wave.Roles`,
`Wave.Schedule`, `Wave.Training`, `Wave.Blueprints` loader with the seed
pool, `Wave.Construction`. Agents spawn, get roles, Navarchs fill their
blueprints one ship per 5 ut, trainees drip XP and go home.
*Accept:* soak shows roster tracking the schedule, blueprints completing,
review moving under-range agents to training and back.

**Phase 4 — Targeting library.** `Wave.Geometry`, `Wave.Intel`, `Wave.Nav`
travel time, reserved-target bookkeeping, legality filters. Pure + tested.

**Phase 5 — Navarch trees.** `navarch.json`, `Wave.Actions.Navarch`,
posts, siege relief, frontline/deep sorties, pillage/bombard roll, retreat.
*Accept:* soak shows sorties landing with `loot`/`raid` outcomes in
`player_events`, defenders parked on border posts, wounded fleets returning.

**Phase 6 — Siderian trees.** `siderian.json`, capture buckets, destabilize,
seduce modes, cooldown handling, roaming.

**Phase 7 — Erased trees.** `erased.json`, daily rolls, chance gating,
removal distribution, wreckers/guards, infiltrate buckets.

**Phase 8 — Blueprint mining.** `Wave.Blueprints.Miner`, `mix wave.mine_blueprints`,
run against a restored backup, commit `blueprints.json`, offline scoring,
loader union rules, tier catch-up signal.

**Phase 9 — Frontend, docs, tuning.** New/Instance/Play pages, in-game
banner, locales, `docs/wave-defense.md` status, memory note, first soak-tuned
knob defaults, then a human playtest instance.

Dependencies: 0 → 1 → 2 and 3 (parallel) → 4 → 5/6/7 (parallel) → 8 (any
time after 3) → 9.

---

## 13. Decisions taken (⚑ = confirm with the user if it matters)

1. Recruits are **synthesized** in range by default; market purchase is an
   option. ⚑ (The spec says "attempt to purchase from the market"; synthesis
   is deterministic and does not drain the humans' market.)
2. Ships are **materialized** directly (order_ship + put_ship on the
   character agent), never produced; the rebellion economy does not gate
   fleets. Consistent with "simulate their construction".
3. Role splits for Siderian (40/30/30) and Erased (40/30/30) ⚑ — not in the
   spec.
4. Roster and tech-tier schedules as in §3.1 defaults ⚑ — "increasing waves"
   needed numbers.
5. Sector bucket definitions in §6.1 ⚑ — the spec's "border" is read as
   either side's frontline; "internal" as rebellion interior.
6. Deep-strike weight `0.5^depth` ⚑.
7. Wounded threshold 35% hull ⚑.
8. Extra scenario factions' sectors become uncontrolled by default ⚑;
   option to hand them to the rebellion.
9. Victory weighting equalized for wave games ⚑; conquest thresholds and
   `win_points_target` remain scenario-controlled.
10. "Day" and "hour" in the spec are **real** time at Legacy (480 / 20 ut).
11. Single rebellion player with lifted caps (not N bot players).
12. Colonization, conquest and armadas are **out of v1** for the rebellion
    (Siderian capture is its expansion; Navarchs pillage/bombard only).
13. Blueprints are mined from Legacy games only by default ⚑.
14. Rebellion display name stays the catalog faction's name in v1; a
    per-instance "Rebellion" label is cosmetic follow-up ⚑.
15. Faction government is forced off for wave games.

---

## 14. Risks and mitigations

- **Silent order drops** (`pre_validate_action/2` swallows throws): every
  push is read back; refusals are counted per kind and surfaced in the
  harness status. Legality filters mirror engine checks.
- **Orchestrator round-trip loss** under many characters: the ported
  self-heal plus the Warlord's own watchdog (an agent `:locked` for more than
  N ticks is logged; the self-heal recovers it).
- **Rand agent as a serialization point** at zero build cadence across a big
  rebellion: cache the tree per system agent; if profiling shows contention,
  give the wave tree a per-system `:rand` stream seeded from the instance
  seed + system id (determinism preserved).
- **Runaway trees**: runner step budget; anti-loop tests per tree.
- **Bankruptcy strike**: solvency guard; telemetry on top-ups.
- **Bot player restore**: `connected_clients` zeroed on restore → the Warlord
  re-issues `:connect` on `:start`; roster re-derived from engine state.
- **Human fairness perception**: ships and agents appear from nowhere; keep
  the ticker honest ("Rebellion reinforcements arrive at X") ⚑ and expose the
  wave index so escalation is legible.
- **Map dependence**: a scenario where the rebellion's start sector is not
  adjacent to anything the humans can reach yields a passive game; the
  create form should warn when the two start sectors are not within 2
  sector hops (computable from `game_data["sectors"]` polygons with the same
  SAT adjacency the engine uses).

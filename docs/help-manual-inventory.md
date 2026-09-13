# Help manual — codebase inventory (phase 0)

First-pass inventory of every mechanic, formula, UX surface and gap that the
help-manual pipeline (see `docs/help-manual.md` §5) starts from. Produced
2026-09-13 against commit 6a61bfb by nine read-only exploration passes, one per
category. Values are **Legacy** (`:slow`) unless stated. File references are
`path:line` at that commit and will drift; the pipeline re-verifies them.

This file is a working artifact: the phase-0 step of each category run
refreshes its section, and the "Gaps / ambiguities" lists are the seed for the
"edge cases the page must state" rule.

**Excluded scope (2026-09-13).** Beta and unfinished features are kept here
for later but are NOT inputs to the writers: faction government (seats,
treasury, taxes, tithe, tyranny, faction patents/lexes/laws), faction
buildings and orbital stations, armadas, gateways/portals and `hypergate`,
inter-faction diplomacy, and the account beta flags (`agent_fan_display`,
`mobile_ui`, `slim_sync`). Paragraphs and rows about them are marked
`[EXCLUDED]`. Review verdicts on the gap lists live in
`docs/help-manual.md` §8.

Sections:

1. Systems & dominions
2. Buildings & faction stations
3. Patents, lexes, traditions, cultures, faction trees
4. Navarchs & fleet actions
5. Ships & battle resolution
6. Siderians & Erased
7. Agents, agent market, player economy
8. Factions, government, victory, diplomacy, galaxy, game modes
9. Front-end surfaces and integration facts

---

### A.1 Systems & dominions

#### Mechanics

| UI name (en) | internal key | defining code |
|---|---|---|
| Production | `sys_production` → `production` | `lib/data/game/content/bonus-pipeline-out.ex:4`; field `lib/game/instance/stellar_system/stellar_system.ex:55` |
| Credit | `sys_credit` → `credit` | `bonus-pipeline-out.ex:22`; field `stellar_system.ex:58` |
| Technology | `sys_technology` | `bonus-pipeline-out.ex:10`; field `stellar_system.ex:56` |
| Ideology | `sys_ideology` | `bonus-pipeline-out.ex:16`; field `stellar_system.ex:57` |
| Stability | `sys_happiness` → `happiness` | `bonus-pipeline-out.ex:34`; field `stellar_system.ex:59` |
| Housing | `sys_habitation` → `habitation` | `bonus-pipeline-out.ex:28`; field `stellar_system.ex:54` |
| Population (mobilized/total) | `workforce` / `used_workforce` | `stellar_system.ex:50-51`; computed `stellar_system.ex:1213`, `:1516` |
| Population (raw, growing) | `population` (`Core.DynamicValue`) | `stellar_system.ex:49`; `population_next_tick/2` `:1226` |
| Mobility | `sys_mobility` | `bonus-pipeline-out.ex:40`; field `stellar_system.ex:60` |
| Defense | `sys_defense` | `bonus-pipeline-out.ex:52`; field `stellar_system.ex:62` |
| S.L.S.D. | `sys_radar` → `radar` | `bonus-pipeline-out.ex:64`; radius `lib/game/instance/faction/faction.ex:273` |
| Intelligence | `sys_ci` → `counter_intelligence` | `bonus-pipeline-out.ex:46`; field `stellar_system.ex:61` |
| Cybersecurity | `sys_remove_contact` → `remove_contact` | `bonus-pipeline-out.ex:58`; tick `stellar_system.ex:896-907` |
| Fighter/Corvette/Frigate/Capital initial XP | `sys_fighter_lvl` … `sys_capital_lvl` | `bonus-pipeline-out.ex:70-93`; fields `stellar_system.ex:65-68` |
| Population class (Outpost … Nerve Center) | `population_class` | `lib/data/game/content/population_class.ex`; assign `stellar_system.ex:1533` |
| Population status (Normal … Widespread rebellion) | `population_status` | `population_status.ex`; assign `stellar_system.ex:1543` |
| Insufficient stability penalty | `uprising_penalties` | `stellar_system.ex:1341`, `:1373` |
| Insufficient population penalty | `workforce_penalties` | `stellar_system.ex:1332-1340`, `:1370` |
| Besieged penalty | `under_siege_penalties` | `stellar_system.ex:1330`, `:1367`; only `@limited_penalty_fields` = `[:sys_production]` (`:12`) |
| Temporary penalties (Destabilization) | `happiness_penalties` | `stellar_system.ex:867`, decay `:985`, injection `:1890` |
| Siege | `siege` | `lib/game/instance/stellar_system/siege.ex`; tick `stellar_system.ex:951` |
| Raid potential (pillage yield) | `raid_potential` | `stellar_system.ex:148-150`, `:936`, consumed `:297` |
| System status (uninhabitable/uninhabited/autonomous/dominion/player) | `status` | `stellar_system.ex:43`; roll `:135-146` |
| Colonization | `:colonization` | `lib/game/instance/character/actions/colonization.ex` |
| Claim / capital flag | `claim/4`, `capital?` | `stellar_system.ex:235`, `:77` |
| Abandon system / dominion | `abandon/1` | `stellar_system.ex:271`; cost `player.ex:340-349` |
| Liberate (turn into dominion) / Administer | `transform_system_to_dominion` / `_to_system` | `lib/game/instance/player/agent.ex:133`, `:160`; cost `player.ex:1289` |
| Dominion | `:inhabited_dominion` | `stellar_system.ex:256-259`; created by `make_dominion.ex` |
| Dominion Tax Rate | `dominion_rate` | `bonus-pipeline-out.ex:214`; base `player.ex:1012-1015`; application `player.ex:1039-1053` |
| System Limit / Dominion Limit | `player_system` / `player_dominion` → `max_systems` / `max_dominions` | `bonus-pipeline-out.ex:94`, `:100`; checks `player.ex:208`, `:261`, `:778-784` |
| Stellar bodies (planets/moons/asteroids) | `Data.Game.StellarBody` | `lib/data/game/content/stellar-body.ex`; instance `lib/game/instance/stellar_system/stellar_body.ex` |
| Body factors (Industrial/Technological/Activity) | `body_ind` / `body_tec` / `body_act` | `bonus-pipeline-in.ex:137-157`; rolls `stellar_body.ex:63-65` |
| Tiles / infrastructure tile | `Tile`, `type: :infrastructure` | `lib/game/instance/stellar_system/tile.ex:20-34` |
| Building damage / repair | `damage_tile`, `plan_repair_building` | `stellar_system.ex:1684`, `tile.ex:93`; cost factor `building_repairs_factor` |
| Star type (Yellow dwarf, …) | `Data.Game.StellarSystem` | `lib/data/game/content/stellar-system.ex` |
| Faction station (build slots) | `station` | `lib/game/instance/stellar_system/station.ex`; bonuses `stellar_system.ex:1866` |
| Autonomous/dominion self-development AI | `SystemAI` | `lib/game/system_ai/*.ex`; trigger `stellar_system.ex:912-931` |

#### Formulas (Legacy = `lib/data/game/content/constant-slow.ex`)

**Bonus stacking (`lib/game/core/bonus.ex`)**
- Each bonus is `{from, value, type, to}`. `:add` reads its input from the *live* state (`get_input`, `bonus.ex:94`); `:mul` reads from `base_state`, the snapshot taken after the last `:add` (`bonus.ex:42-56`).
- Contribution = `input * bonus.value`, where `input = 1` for `from: :direct`. So `:add` with `from: :direct` adds `value` flat; `:mul` with `from: X` adds `base_state.X * value` (a share of the pre-mul subtotal, *not* compounding).
- If the target's current value is negative, a `:mul` contributes 0 (`bonus.ex:21`).
- Ordering (`prepare/1`, `bonus.ex:62-87`): by `BonusPipelineIn.order` (10…80), with `-2` for `from: :direct` and `-1` for self-referential `X→X`; ties break `:add` before `:mul`.
- `Core.Value.add` sums parts into `.value` and records each part under `details[reason_type]` — that details map is what the UI tooltip breaks down.

**Initial per-system bonuses** (`stellar_system.ex:1817-1863`)
- production += `system_capital_base_production` (100) if `capital?` else `system_base_production` (40)
- happiness += `system_base_happiness` (35)
- defense += `system_base_defense (0.15) * workforce`, only if `status == :inhabited_player` (0 for dominions/neutrals)
- happiness += `system_population_negative_happiness_factor (-1.0) * workforce`
- credit += `system_population_taxes_factor (2) * workforce`  ← "Taxes"
- credit += (`:mul`, from `sys_mobility`) **mobility × 0.1 × workforce** (`system_mobility_taxes_factor` = 0.1), evaluated against `base_state.mobility` ← "Mobility bonus"
- radar += `@base_radar` = 1.0 (`stellar_system.ex:9`)

**Population growth** (`population_next_tick/2`, `stellar_system.ex:1226-1268`), per elapsed time unit:
```
if happiness < -10 : growth = -0.002
elif happiness < 0 : growth = -0.001
else:
  happiness_factor  = min(happiness, 25) * 0.002
  habitation_factor = min((habitation + 0.75 - population) * 0.1, 1)     # can be negative
  pop_factor        = (1 - min(population,120)/120) * 0.8 + 0.2          # in [0.2, 1]
  growth = (system_base_growth(0.02) + happiness_factor) * habitation_factor * pop_factor
population' = max(population + growth * elapsed_time, 0)
workforce   = floor(population)
```
Starting population on colonisation/opening = `system_starting_population` = 15.8 (`stellar_system.ex:1420`).

- **Per-body population split** (`apportion_workforce/2`, `:1486`): largest-remainder apportionment proportional to each body's summed `habitation` bonus. Moons/asteroids excluded (`:1441-1443`).
- **Used workforce** (`:1516`): sum of `building.workforce` over tiles with `building_status ∈ {:built, :damaged}`.
- **Workforce penalty** (`:1332`): `coeff = 1 - workforce/used_workforce` when `used_workforce > workforce`; `:mul` of `-coeff` on all `@standard_penalty_fields` (`:18-30`: production, credit, technology, ideology, defense, ci, remove_contact, 4× ship-lvl).
- **Uprising penalty** (`:1341`): `coeff = population_status.penalty` — 0 / 0.1 / 0.25 / 0.5 / 0.8 for normal / discontent / demonstration / uprising / general_uprising. Same fields.
- **Siege penalty** (`:1330`): production drops to 0 while besieged; nothing else.
- Status thresholds (`population_status.ex`, `happiness <= threshold`): normal ≤10000 (sentinel), discontent ≤0, demonstration ≤−10, uprising ≤−20, general_uprising ≤−30.
- **Population class** (`population_class.ex`, first class with `population >= threshold`): minor ≥0 (1 pt), medium ≥40 (2), large ≥60 (4), major ≥70 (7), big ≥80 (11), huge ≥90 (16), enormous ≥120 (25), prodigious ≥160 (75). `points` feed victory scoring (`lib/game/instance/victory/victory.ex:98-105`).
- **Temporary happiness penalties** decay linearly: `value -= elapsed_time * 0.01` (`happiness_penalty_reduction_factor`), dropped at ≤0 (`:991-993`).
- **Radar / S.L.S.D. radius**: `radius = radar.value * system_base_radar_size (3)` (`faction/faction.ex:273`); `radar ≤ 0` or no owner → no disk.
- **Cybersecurity**: accumulator `value += change * elapsed_time`; when `value > 25_000` (`@max_remove_contact`, `:11`) it resets and one enemy malware is removed (`:896-906`, `agent.ex:375`). Initial value uniform in [0, 25000].
- **Raid potential**: starts 100, regen 0.25/ut (`system_raid_potential_growth`), cap 100. A pillage subtracts `min(raid_potential, 45)` (`raid_potential_impact`) and kills `population * lost_population_chances`.
- **Production consumption**: `production.value * elapsed_time` per tick into the queue (`:1004`); ETA = `remaining / production.value` (`production_queue.ex:77-84`); the station build track runs in parallel on the same rate (`:1097-1100`).
- **Neutral system generation**: needs a habitable/sterile planet; `roll < system_neutral_ratio (0.35)` → `:inhabited_neutral`, else `:uninhabited`; no planet → `:uninhabitable` (`:135-146`).
- **Dominion income** (`player.ex:1039-1053`): contribution = `dominion_rate × system_resource`. Base `dominion_rate = 0.3` (`player.ex:1014`), +0.1 from a faction tradition (`faction.ex:50`), +0.2/+0.05/+0.3 from lexes (`doctrine-slow.ex:141-176`). Own systems contribute at 1.0.
- **Limits**: `max_systems` starts at 1 (`player.ex:1010`); colonisation/conquest blocked at the limit (`player.ex:208`); dominions at `max_dominions` (`:261`).
- **Administer/Liberate cost**: `10_000 + transformed_count × 1_000` ideology (`player.ex:1289-1291`). **Abandon**: 5_000 ideology (`player.ex:340-349`).
- **Timers (ut, Legacy)**: colonization 150, conquest 150, raid 40, loot 20, make_dominion 150, encourage_hate 50, infiltration 50.
- **Generation ranges**: bodies per system 4..8 by star type; tiles 6..8 on planets / 1..3 on moons+asteroids / 0 on gas giants & belts; factors 1..5. Tile #1 of every primary body is the `:infrastructure` tile (`tile.ex:22-24`); colonisation force-places `infra_open` / `infra_dome` there (`stellar_system.ex:1394-1422`).

#### UX surfaces

- `galaxy/system/Properties.vue` — defense, population class chip, owner line, star type, credit/technology/ideology with `resource-description.*` tooltips.
- `Population.vue` — used/total workforce, housing, stability, growth adjective (`galaxy.system.population.growth_0..5`).
- `PopulationStatus.vue` — status ladder (`data.population_status.<key>.name|desc`), reads `penalty` from the client-side table.
- `Details.vue` — Mobility, S.L.S.D., Intelligence, Cybersecurity (displays `.change`, not `.value`, `Details.vue:237`), ship initial-XP rows.
- `Bodies.vue` / `BodiesItem.vue` — body icons `stellar_body/*`, per-body population, the three factors, tile grid with `building/frame_{biome}` placeholders.
- `State.vue` — Liberate/Administer/Abandon with ideology cost (`system.transform_to_*`, `system.abandon_*`).
- `Production.vue` / `ProductionBox.vue` / `StationBox.vue` — build queue and station slots.
- `generic/ResourceDetail.vue` — renders `Core.Value.details` grouped by `resource-detail.type.*`, misc reasons via `resource-detail.misc.*`.
- Icons: `resource/*` (19), `stellar_body/*` (12), `stellar_system/*` (7). Names: `data.bonus_pipeline_out.sys_*.name`, `data.stellar_system.*.name`, `data.stellar_body.*.name`.
- Status prose already written: `system.status.*`, `system.empty_system.*`, `system.hidden_system.*`.

#### Cross-links

- Buildings: collected `stellar_system.ex:1287-1301`; workforce `:1516`; habitation `:1454-1462`; damage/repair `:1655-1729`, `building_repairs_factor` 0.5.
- Faction station: `station.ex`, bonuses `:1866-1888` (built + powered only), control sync on conquest `:776-818`, Training Center drip `:1027-1095`.
- Navarch pillage/bombard/conquest: `actions/loot.ex:51,98`, `raid.ex:51,97`, `conquest.ex:69,120` all roll `Core.Dice.ratio(coef, system.defense.value)`; damage entry `stellar_system.ex:297`. Colonisation: `colonization.ex`.
- Siderian: `make_dominion.ex:110-113` rolls against `max(happiness, 0)`; `encourage_hate.ex` pushes a `happiness_penalties` entry via `:867`.
- Erased: `infiltration.ex:28,59`, `sabotage.ex:46`, `assassination.ex:43` defend with `counter_intelligence.value`; malware removed by Cybersecurity `:899` → `agent.ex:375`.
- Patents / lexes emit `Core.Bonus` into the same pipeline; dominion_rate lexes `doctrine-slow.ex:141-180`.
- Government tax: `player.ex:979-999`, cap `government_tax_cap` = 10 %.
- Victory: `victory.ex:87-114` sums population-class points per faction; sector points `galaxy/sector.ex:18`, `victory/sector.ex`.
- Visibility: `faction/stellar_system.ex:60-82` gates which fields a foreign player sees by visibility level (2 defense/siege, 3 population, 4 credit/tech/ideo/intelligence, 5 radar/cyber/mobility/ship-XP/station); tile obfuscation `tile.ex:132-149`.
- Mutators/daily: `Instance.Mutators` reshapes factors and tile counts (`stellar_body.ex:32-33`, `stellar_system.ex:1760-1803`).

#### Gaps / ambiguities

1. `resource-description.habitation` says housing "accommodates 1 billion people" each, but housing is a growth *target* (`habitation + 0.75`), not a cap. Population can exceed housing and just stops growing.
2. Cybersecurity UI shows a rate (`.change`); the removal trigger is the accumulated `.value` crossing a hard-coded 25 000. No progress indicator exists.
3. `@base_radar = 1.0` is hard-coded while `system_base_radar_size` (3) is a constant; effective base radius 3 is stated nowhere.
4. Dominions and autonomous systems get **no** population-derived defense (`:1825-1828`); `system.status.inhabited_dominion` does not say so.
5. `system.status.uninhabited` has a typo ("This *uninhabited**").
6. `resource-detail.misc.workforce_penalties` is labelled "Insufficient population" but the condition is over-employment; wording reads backwards.
7. `population_status.normal.threshold = 10_000` is a sentinel; `display_max/min` (0..10) is what `PopulationStatus.vue` shows, so a player at stability 40 sees "0 to 10". Intent unknown.
8. `update_population` calls `compute_local_population`/`compute_bonus` twice (`:1216-1219`), reason unknown.
9. `ensure_habitable_planet` / `starter_factors` only apply under daily/mutator instances; not surfaced.
10. `Properties.vue:104` references `data.bonus_pipeline_in.sys_visibility.name`, which does not exist.
11. Dominion self-development (`SystemAI`, every 50 days, `:10,916`) has no UI explanation; build priorities not traced.
12. `system_neutral_ratio` can be overridden per sector (`Instance.Manager.compute_neutral_overrides/1`), not read.

---

### A.2 Buildings (faction stations excluded)

All values Legacy (`lib/data/game/content/building-slow.ex`). `biome` maps to body type via `stellar-body.ex`: `open` = habitable planet, `dome` = barren planet, `orbital` = moon/asteroid. Gas giants and asteroid belts have `biome: :none` and 0 tiles.

#### Building table (47 locale keys)

| key | name | biome | lvl | wf | limit | produces (direct = flat; ×X = scaled by body/system factor) | patent L1 |
|---|---|---|---|---|---|---|---|
| infra_open | Megapolis | open | 5 | 2 | unique_body | +10 habitation, +2→10 happiness (direct) | infra_open_1 |
| infra_dome | Central Hub | dome | 5 | 2 | unique_body | +10 habitation, +2→10 happiness | infra_dome_1 |
| mine_dome | Array of Excavators | dome | 5 | 2 | – | production ×body_ind 2.8→14; happiness ×body_pop −0.05→−0.25 | infra_dome_1 |
| mine_orbital | Swarm of Self-drilling Machines | orbital | 5 | 1 | – | production ×body_ind 3→15 | orbital_prod |
| hab_open | Residential District | open | 5 | 0 | – | +3→4 habitation | none |
| hab_dome | Capsule Cities | dome | 5 | 0 | – | +3→6 habitation | dome_pop |
| hab_open_poor | Hive Cities | open | 5 | 0 | – | +4→10 habitation, −1→−5 happiness | open_industries |
| hab_open_rich | Residential Archipelago | open | 5 | 0 | – | +3→5 habitation, credit ×body_act 5→40 | open_credit |
| factory_open | Industrial Hub | open | 5 | 2 | – | production+credit ×body_ind; happiness ×body_pop malus | open_industries |
| factory_orbital | Refining Ducts | orbital | 5 | 1 | – | production+credit ×body_ind | orbital_credit |
| high_factory_dome | Metamaterials Factory | dome | 5 | 5 | unique_body | production ×body_ind 7→40; technology ×body_tec 3→30 | dome_industries |
| lift_open | Orbital Link | open | 5 | 3 | unique_body | credit + mobility ×body_ind | open_lift |
| lift_dome | Space Elevator | dome | 5 | 3 | unique_body | production + mobility ×body_ind | dome_mobility |
| university_open | Delta Polytech | open | 5 | 2 | unique_body | +3 technology direct, technology ×body_pop 0.15→0.6 | none |
| research_open | Accelerator | open | 5 | 5 | unique_body | technology ×body_tec 3→15 | open_research |
| research_dome | Impact Research Center | dome | 5 | 1 | unique_body | technology ×body_tec 1.2→6 | infra_dome_1 |
| research_orbital | Experiment Station | orbital | 5 | 1 | unique_body | technology ×body_tec 0.6→4 | orbital_research |
| ideo_open | Citadel | open | 5 | 2 | unique_body | +3 ideology direct, ideology ×body_pop | citadel |
| ideo_dome | Holodome | dome | 5 | 2 | unique_body | ideology + credit ×body_pop | dome_happiness |
| monument_open | Floating Gardens | open | 5 | 2 | unique_body | direct happiness 1.6→10, ideology 3.75→30 | open_ideo |
| monument_dome | Monolith | dome | 5 | 3 | **unique_system** | direct happiness 5→30, ideology ×sys_pop 0.2→2 | dome_ideo |
| ideo_credit_open | Network of Artificial Islands | open | 5 | 4 | unique_body | ideology/happiness ×body_act, credit ×body_pop | open_island |
| market_open | Commercial Artery | open | 5 | 2 | – | credit ×body_pop 2→10 | open_credit |
| market_dome | Omnimarket | dome | 5 | 2 | – | credit ×body_pop, direct technology | dome_pop |
| finance_open | Reflect District | open | 5 | 5 | unique_body | credit ×sys_mobility 2→10; direct happiness −6.4→−32 | open_mobility |
| finance_orbital | Business Arch | orbital | 5 | 3 | unique_body | credit ×sys_mobility; direct happiness malus | orbital_mobility |
| spatioport_dome | Industrial Spaceport | dome | 5 | 2 | unique_body | direct mobility 1.6→8, production ×body_pop | dome_mobility |
| spatioport_orbital | Orbital Terminus | orbital | 5 | 2 | unique_body | direct mobility 1.5→7.5, direct credit 20→100 | orbital_mobility |
| defense_global_dome | C.N.D. | dome | 5 | 5 | **unique_system** | direct happiness; defense ×sys_defense +20%→+100% | dome_defense_2 |
| defense_local_open | Planetary Shield | open | 5 | 3 | unique_body | direct defense 4.8→24 | open_defense |
| defense_local_dome | Interception Tunnels | dome | 5 | 3 | unique_body | defense ×body_pop 0.4→2 | dome_defense_1 |
| defense_local_orbital | Constellation of Lures | orbital | 5 | 1 | unique_body | direct defense 3→10 | orbital_defense |
| happy_pot_open | Preserved Ecosystem | open | 5 | 5 | unique_body | happiness ×body_act 5→25 | open_happiness |
| happy_pot_dome | Hyperdrive Circuit | dome | 5 | 2 | unique_body | happiness + technology ×body_act | dome_happiness |
| happy_pot_orbital | Zero-G Arena | orbital | 5 | 2 | unique_body | happiness + credit ×body_act | orbital_happiness |
| happy_orbital | O.P.U. | orbital | 5 | 1 | unique_body | direct happiness 6→30, production 2→10 | orbital_defense |
| shipyard_1_orbital | S-01 Assembly Line | orbital | 5 | 2 | **unique_system** | direct production, counter-intel, fighter_lvl (initial XP) | shipyard_1 |
| shipyard_2_orbital | S-02 Assembly Line | orbital | 5 | 3 | **unique_system** | production, CI, corvette_lvl | shipyard_2 |
| shipyard_3_orbital | Space Dock | orbital | 5 | 4 | **unique_system** | production, CI, defense, frigate_lvl | shipyard_3 |
| shipyard_4_orbital | Assembly Superstructure | orbital | 5 | 6 | **unique_system** | production, CI, defense, capital_lvl | shipyard_4 |
| military_school_dome | Aerospace Military Academy | dome | 5 | 3 | unique_body | +6→30 initial XP to all four ship classes | dome_academy |
| radar_orbital | S.L.S.D. Network | orbital | 5 | 3 | **unique_system** | radar 0.5→3.5, CI 5→50, remove_contact 5→20 | orbital_radar |
| counterintelligence_open | Orb-INTEL | open | 5 | 5 | **unique_system** | CI 50→170, remove_contact 30→150 | open_intel |
| removecontact_open | Convention Center | open | 5 | 2 | unique_body | CI 30→110 | infra_open_2 |
| removecontact_dome | Integrated Proxy Systems | dome | 5 | 1 | – | remove_contact 20→100 | dome_defense_1 |
| hypergate [EXCLUDED: beta] | Singularity Ring | **:gate** | 1 | 10 | unique_system | direct mobility +16 | orbital_hypergate |
| happy_open | Administrative Center | — | — | — | — | **locale/icon only, no content row** (all speeds) | — |

- `biome: :gate` (`building-slow.ex:2882`) matches no stellar body biome and `order_building_production` throws `:wrong_biome` (`stellar_system.ex:347`) → **hypergate is currently unbuildable**. Slow + medium only.
- Level costs: credit 1 500 (university_open L1) to 831 000 (hypergate); production 30 to 473 000.
- Fast/medium are structurally identical to slow. Medium = same 46 keys; fast = 33 keys. `Player.order_building` guards keys absent from the instance dataset (`player.ex:361-366`).

#### Mechanics

- Order: `stellar_system.ex:333` validates biome, tile type, tile free, unique flags, infra prerequisite.
- Credit debit + patent gate: `player.ex:351-397` (`:not_enough_credit`, `:patent_not_unlocked`, `:player_is_bankrupt`); dry-run then commit from `player/agent.ex:336`.
- Infrastructure prerequisite: tile 1 of a primary body is `:infrastructure` (`tile.ex:20-24`); only infra buildings go there, and no other tile may be built until tile 1 is occupied (`stellar_system.ex:357-367`).
- Upgrade rules: one level at a time, never downgrade; on non-orbital bodies a tile's level may not exceed tile 1's infra level (`:368-378`).
- Uniqueness: `:unique_body` one per body, `:unique_system` one per system, checked only at level 1 (`:380-399`).
- Production queue: FIFO `%ProductionItem{}` (`production_queue.ex:18`, `production_item.ex:11-19`); one shared queue per system for buildings, repairs and ships.
- Queue advance: `production.value * elapsed_time` per tick, overflow cascades (`:1005`, `:1126`, `production_queue.ex:53-67`).
- Completion: tile flips to `:built` / level+1 (`tile.ex:69-74`), notif `:building_finished`, bonuses recomputed (`:1159-1196`).
- Cancel/refund: full credit refund, tile un-planned (`:590-638`, refund in `player/agent.ex:414-422`). Refused under siege.
- Demolish: instant, free, no refund; infrastructure tiles not removable (`:547-575`).
- Repair: `production × 0.5` and `credit × 0.5` (`:494-545`; `building_repairs_factor`).
- Damage: raid/loot/conquest damage N random non-infra built tiles; defence buildings weighted ×2; a mid-upgrade tile has its queue entry cancelled and refunded (`:1675-1750`).
- Siege lock: no ordering, repair, removal or cancel while `siege != nil`.
- Shipyard gate: a ship with `shipyard` set requires that shipyard `:built` (`:435-459`).
- Visibility: tiles obfuscated below contact level 5 (`tile.ex:132-149`).
- Faction stations [EXCLUDED: beta]: 2×2 slot grid, government-only, parallel labor track (`station.ex:39-231`, orders `:641-700`); cancel refunds full treasury cost; demolish free (`docs/faction-buildings.md`).

#### Formulas

- Construction time (ut) = `level.production / system.production.value` (`production_queue.ex:81-88`); UI converts with `tickToSecondFactor` (`BuildingCard.vue:114`). Legacy speed factor 1; 1 ut ≈ 3 wall-minutes.
- Total queue time = Σ`remaining_prod` / `production.value` (`production_queue.ex:90-104`).
- Repair cost = `round(production × 0.5)`, `round(credit × 0.5)`.
- Per-level scaling (`lib/data/game/building.ex:130-174`, `value_by_level/5`): level 1 = `min`, level max = `max`; intermediate levels use linear interpolation (`l`) or a named step curve applied to `max`: `a [.05,.30,.60] · b [.025,.25,.55] · c [.05,.15,.40] · d [.125,.25,.50] · e [.32,.52,.75] · f [.30,.45,.65] · g [.25,.40,.65] · s [.60,.80,.90]`; trailing digit = decimal precision. Applies to `production`, `credit` and each bonus value independently.
- Patent per level: L1 uses the sheet's patent; `:infrastructure` buildings substitute the level digit (`infra_open_1..5`); orbital buildings use hidden `infra_orbital_<n>` for L2-5 (`hide_patent?: true`); everything else `nil` above L1 (`building.ex:64-76`).
- Faction building labor ≈ `hours × 20 ut/h × production_rate`; Gateway 256 000 labor ≈ 16 h at 800 prod (`content/faction_building.ex` moduledoc).

#### UX surfaces, icons, locale keys

- Cards: `card/BuildingCard.vue` (level pips, illustration, cost row, limitation toasts, requirement tooltip via `levelRequirementsUnmet`), `CardComplexBonus.vue`, `ProductionQueueCard.vue`, `ClosedProductionCard.vue`.
- System view: `galaxy/system/Production.vue` (build menu, gating `:196-217`), `Bodies.vue` / `BodiesItem.vue`, `ProductionBox.vue`, `StationBox.vue`, `Details.vue`, `Properties.vue`.
- Shared validation: `front/src/utils/buildingValidation.js`.
- Icons: `front/src/icons/building/*.js` one per key plus `frame_open|dome|orbital(_hidden)`. Orphan `spatioport_open.js`. Illustrations `data/buildings/<key>.jpg` else `default.jpg`.
- Locale: `data.building.<key>.{name,quote,description}` (most placeholders); `card.building.*`, `card.cost.*`, `card.production_queue.*`, `production.*`, `galaxy.station.*`.

#### Cross-links

- Bonus pipeline `to`/`from` keys in `bonus-pipeline-out.ex` / `bonus-pipeline-in.ex`; aggregation `stellar_system.ex compute_bonus/1`.
- Patents: the building→patent link lives on the *building* level record, not on the patent. UI reverse lookup shows `card.patent.unlocks_something`.
- Ships: `ship-slow.ex` `shipyard:` field — shipyard_1 gates 16 fighter hulls, shipyard_2 nine corvettes, shipyard_3 eight frigates, shipyard_4 three capitals; transports need none. Initial XP from `*_lvl` bonuses (`stellar_system.ex:1130-1140`).
- Erased: `mutator.ex:434-442` boosts `spy_sabotage`. **Sabotage does not touch buildings** — `sabotage.ex:68-70` damages a target character's *army* only.
- Navarch bombardment: `raid.ex:100-117` sets `damaged_buildings_count` per dice outcome (crit-fail 0 / fail 1 / success 5 / crit 6); same path in `conquest.ex:123`, `loot.ex:101`; applied `stellar_system.ex:297-330`.
- Faction government [EXCLUDED]: `docs/faction-buildings.md`, `faction_building.ex` (gateway / training_center / cyber_command), gateway constants `constant-slow.ex:78-87`.
- Existing generator: `lib/mix/tasks/building_table.ex` emits per-level tables with 13 bonus columns; does **not** cover biome, limitation, patent, illustration or `display` category.

#### Gaps / ambiguities

- `happy_open` ("Administrative Center") has locale + icon but no content row in any speed.
- `hypergate` unreachable (`biome: :gate`). Shelved or bug: unknown.
- `spatioport_open.js` icon has no building key.
- `data.building.*.description/quote` are placeholders — no flavour text to source.
- `display` field (`infrastructure, industrial, life, output, culture, finance, defense, shipyard`) drives build-menu grouping; no locale strings for these names found.
- Cyber Command faction-building costs are TBD in `docs/faction-buildings.md`.
- No per-building design rationale exists in the repo.

---

### A.3 Patents, lexes, traditions, cultures (faction trees excluded)

All values Legacy (`speed: :slow`, 1 ut = 3 wall-minutes). Fast/medium have different trees (fast patents use classes `economic`/`military`, fast doctrines use `character`/`expansion`; medium is structurally identical to slow but re-costed).

#### Patent table (`lib/data/game/content/patent-slow.ex`, 64 nodes)

| key | name | class | cost | prereq | unlocks / effect |
|---|---|---|---|---|---|
| citadel | Holographic Storage System | root | 50 | — | Citadel lvl1 (tree root) |
| infra_open_1 | Urbanization | open | 50 | citadel | Megapolis lvl1 |
| open_industries | Cookie-cutter Cities | open | 1000 | infra_open_1 | Hive Cities, Industrial Hub |
| open_research | Z-poly Coils | open | 40000 | open_industries | Accelerator |
| open_intel | Drone Swarms | open | 30000 | open_research | Orb-INTEL |
| infra_open_2 | Urbanization II | open | 400 | infra_open_1 | Megapolis lvl2, Convention Center; habitable buildings → lvl2 |
| open_ideo | Maglev Architecture | open | 3000 | infra_open_2 | Floating Gardens |
| infra_open_3 | Urbanization III | open | 2000 | open_ideo | Megapolis lvl3; habitable → lvl3 |
| open_defense | Extended Magnetic Generators | open | 4000 | infra_open_3 | Planetary Shield |
| infra_open_4 | Urbanization IV | open | 8000 | open_defense | Megapolis lvl4; habitable → lvl4 |
| infra_open_5 | Urbanization V | open | 20000 | infra_open_4 | Megapolis lvl5; habitable → lvl5 |
| open_credit | Publicity Terminals | open | 16000 | infra_open_1 | Residential Archipelago, Commercial Artery |
| open_island | Floating Cities | open | 40000 | open_credit | Network of Artificial Islands |
| open_lift | Nanotubes | open | 30000 | open_island | Orbital Link |
| open_happiness | Climate Control | open | 40000 | open_lift | Preserved Ecosystem |
| open_mobility | Luxury Architecture | open | 120000 | open_happiness | Reflect District |
| infra_dome_1 | Controlled Environment | dome | 50 | citadel | Central Hub, Array of Excavators, Impact Research Center |
| dome_pop | Pressurized Cities | dome | 3000 | infra_dome_1 | Capsule Cities, Omnimarket |
| dome_happiness | Holograms | dome | 12000 | dome_pop | Holodome, Hyperdrive Circuit |
| dome_ideo | Monumental Architecture | dome | 150000 | dome_happiness | Monolith |
| infra_dome_2 | Controlled Environment II | dome | 400 | infra_dome_1 | Central Hub lvl2; barren → lvl2 |
| dome_defense_1 | Autonomous Drills | dome | 3000 | infra_dome_2 | Interception Tunnels, Integrated Proxy Systems |
| infra_dome_3 | Controlled Environment III | dome | 2000 | dome_defense_1 | Central Hub lvl3; barren → lvl3 |
| dome_defense_2 | Quantum Cryptography | dome | 14000 | infra_dome_3 | C.N.D. |
| infra_dome_4 | Controlled Environment IV | dome | 8000 | dome_defense_2 | Central Hub lvl4; barren → lvl4 |
| infra_dome_5 | Controlled Environment V | dome | 20000 | infra_dome_4 | Central Hub lvl5; barren → lvl5 |
| dome_mobility | Magnetic Cranes | dome | 2000 | infra_dome_1 | Space Elevator, Industrial Spaceport |
| dome_academy | Neural Derivations | dome | 16000 | dome_mobility | Aerospace Military Academy |
| dome_industries | Advanced Catalysis | dome | 150000 | dome_academy | Metamaterials Factory |
| orbital_credit | Magnetic Pipelines | orbital | 50 | citadel | Refining Ducts |
| orbital_defense | Signature Reduction | orbital | 200 | orbital_credit | Constellation of Lures, O.P.U. |
| orbital_prod | Crystal Shell | orbital | 4000 | orbital_defense | Swarm of Self-drilling Machines |
| orbital_radar | S.L.S.D. Captors | orbital | 8000 | orbital_prod | S.L.S.D. Network |
| infra_orbital_2 | Pressurized Environment II | orbital | 400 | orbital_credit | orbital buildings → lvl2 |
| infra_orbital_3 | Pressurized Environment III | orbital | 2000 | infra_orbital_2 | orbital → lvl3 |
| infra_orbital_4 | Pressurized Environment IV | orbital | 8000 | infra_orbital_3 | orbital → lvl4 |
| infra_orbital_5 | Pressurized Environment V | orbital | 20000 | infra_orbital_4 | orbital → lvl5 |
| orbital_research | Exobiology | orbital | 3000 | orbital_credit | Experiment Station |
| orbital_happiness | Gravity Generator | orbital | 14000 | orbital_research | Zero-G Arena |
| orbital_mobility | Secured Habitations | orbital | 50000 | orbital_happiness | Business Arch, Orbital Terminus |
| shipyard_1 | Assembly Lines | ship | 300 | citadel | S-01 Assembly Line; Scout |
| fighter_2 | Light Fuselage | ship | 800 | shipyard_1 | Light Fighter |
| fighter_3 | Reinforced Fuselage | ship | 800 | shipyard_1 | Fighter-bomber |
| fighter_4 | Compact Turrets | ship | 6000 | fighter_2 | Interceptor |
| merge_fighter_1 | Fighter Formation I | ship | 12000 | shipyard_1 | build/merge 4-fighter units |
| shipyard_2 | Precision Cranes | ship | 3000 | merge_fighter_1 | S-02 Assembly Line |
| merge_fighter_2 | Fighter Formation II | ship | 60000 | shipyard_2 | 8-fighter units |
| merge_corvette_1 | Corvette Formation I | ship | 5000 | merge_fighter_2 | 4-corvette units |
| shipyard_3 | Orbital Holds | ship | 10000 | merge_corvette_1 | Space Dock; Assault Frigate |
| frigate_4 | Repair Bay | ship | 50000 | shipyard_3 | Repair Platform |
| frigate_3 | Military Drones | ship | 70000 | frigate_4 | Drone Carrier |
| transport_2 | Capsule Quarters | ship | 60000 | shipyard_3 | Carrier |
| frigate_2 | Hypersonic Chargelauncher | ship | 80000 | transport_2 | Gunner |
| merge_fighter_3 | Fighter Formation III | ship | 220000 | shipyard_3 | 16-fighter units |
| merge_corvette_2 | Corvette Formation II | ship | 20000 | merge_fighter_3 | 8-corvette units |
| shipyard_4 | Space Hyperstructures | ship | 50000 | merge_corvette_2 | Assembly Superstructure |
| capital_1 | Armoring | ship | 80000 | shipyard_4 | Destroyer |
| capital_2 | Advanced Armoring | ship | 100000 | capital_1 | Cruiser |
| capital_3 | Multifunctional Nodes | ship | 120000 | shipyard_4 | Coordinator |
| merge_frigate_1 | Frigate Formation I | ship | 60000 | shipyard_4 | 4-frigate units |
| corvette_1 | Light Nodal Fuselage | ship | 18000 | shipyard_2 | Light Corvette |
| corvette_2 | Nodal Fuselage | ship | 25000 | shipyard_2 | Heavy Corvette |
| corvette_3 | Auto-Aim | ship | 25000 | corvette_2 | Multi-turret Corvette |
| transport_1 | Hypersleep Chamber | ship | 500 | citadel | Colonisation Ship |

Classes (`data.patent_class`): root "Origin", open "Habitable Planets", dome "Sterile Planets", orbital "Moons and Asteroids", ship "Shipyards and Ships" (+ `economic`, `military` unused in Legacy).

Patents give **no direct bonuses**, only unlocks. The `unlock` list is derived at load time (`lib/data/game/patent.ex:56-74`): every building level and ship whose `patent` matches and whose `hide_patent?` is false. `infra_*` and `merge_*` nodes look empty because their beneficiaries are hidden variants; their player-facing text comes from `data.patent_info.*` (19 keys).

#### Lex table (`lib/data/game/content/doctrine-slow.ex`, 61 nodes; cost = ideology)

| key | name | class | cost | prereq | effect |
|---|---|---|---|---|---|
| agent | Age of Exploration | root | 50 | — | Erased/Navarch/Siderian limit +2 each |
| system_1 | Proto-Empire | expansion | 7000 | agent | System limit +1 |
| system_2 | Extended Administration | expansion | 20000 | system_1 | System +1; Tech −30 |
| mobility_1 | Freedom of Movement | expansion | 2000 | system_2 | Mobility +20 |
| system_3 | Decentralized Administration | expansion | 60000 | mobility_1 | System +2; Credit −4%; Tech −20; Ideo −50 |
| mobility_2 | Trade Secrets | expansion | 10000 | system_3 | Mobility +10%; Credit −100 |
| system_4 | Second Core | expansion | 200000 | mobility_2 | System +3; Credit −8%; Stability −16; Ideo −150 |
| credit_pop | Centralization of Power | expansion | 2000 | system_2 | Credit += Population×2; Defense −25% |
| sys_dom_1 | External Colonies | expansion | 50000 | credit_pop | System +1; Dominion +2; Credit −3%; Ideo −50 |
| sys_dom_2 | Empire's Edge | expansion | 180000 | sys_dom_1 | System +2; Dominion +4; Credit −6%; Stab −8; Tech −100 |
| dominion_1 | Exclusive Trade Zone | expansion | 9000 | system_1 | Dominion +3 |
| dominion_rate_1 | Business Integration | expansion | 5000 | dominion_1 | Dominion tax rate +0.2 |
| dominion_2 | Protectorate | expansion | 40000 | dominion_rate_1 | Dominion +4; Stab −8; rate +0.05; Ideo −30 |
| dominion_rate_2 | Incorporation of Protectorates | expansion | 20000 | dominion_2 | Dominion tax rate +0.3 |
| dominion_3 | Federation of Protectorates | expansion | 120000 | dominion_rate_2 | Dominion +7; Stab −12; rate +0.05; Ideo −90 |
| admiral_1 | Reaction Force | admiral | 50 | agent | Navarch limit +2 |
| upgrade_raid | Tactical Scouting | admiral | 500 | admiral_1 | Bombing +20; Credit −50 |
| admiral_2 | Galtacon Orthodoxy | admiral | 1000 | upgrade_raid | Navarch +4 |
| reduce_maintenance_1 | Simplified Chain of Command | admiral | 5000 | admiral_2 | Maintenance −10% |
| admiral_3 | Military Academy | admiral | 18000 | reduce_maintenance_1 | Navarch +5; Erased +2; Credit −4% |
| upgrade_invasion | Combat Drugs | admiral | 80000 | admiral_3 | Invasion +22% |
| admiral_4 | War Propaganda | admiral | 18000 | reduce_maintenance_1 | Navarch +5; Siderian +2; Credit −4% |
| reduce_maintenance_2 | Component Standardization | admiral | 80000 | admiral_4 | Maintenance −18% |
| upgrade_repair | Modular Construction | admiral | 2000 | admiral_2 | Repair +10%; Production +12% |
| upgrade_fleet | Armed Forces Automation | admiral | 60000 | upgrade_repair | Repair +20%; Invasion +8%; Bombing +10%; Credit −8% |
| defense_1 | War Council | admiral | 500 | admiral_1 | Defense +25; Production −50% |
| prod_1 | Relaxed Production Standards | admiral | 3000 | defense_1 | Production +30 |
| prod_2 | Pace of War | admiral | 20000 | prod_1 | Production +50 and +10% |
| upgrade_xp | Navarch Tradition | admiral | 100000 | prod_2 | Initial XP +30% for all four hull classes |
| credit_1 | Stelloliberal Maze | spy | 50 | agent | Credit +100 |
| spy_1 | Underground Networks | spy | 1000 | credit_1 | Erased +4; Credit −200 |
| infiltration | Information Systems Surveillance | spy | 3000 | spy_1 | Infiltration +15 |
| spy_3 | RNA Camouflage | spy | 18000 | infiltration | Erased +7; Siderian +2; Tech −4% |
| assassinate | Simpler Practices | spy | 25000 | spy_3 | Erased Removal +25 |
| cover | Fixer Network | spy | 90000 | assassinate | Cover recovery +0.3; Ideo −5% |
| spy_4 | Parallel Military Strategy | spy | 18000 | infiltration | Erased +7; Navarch +2; Stab −14 |
| sabotage | Industrial Espionage | spy | 25000 | spy_4 | Sabotage +40 |
| spy_bonus | Deep State | spy | 80000 | sabotage | Infiltration +25%; Sabotage +15%; Removal +15% |
| spy_def_1 | Digitalization of Interactions | spy | 5000 | spy_1 | Intelligence +30; Cybersecurity +20 |
| spy_def_2 | Total Surveillance | spy | 80000 | spy_def_1 | Intelligence +30%; Cybersecurity +100%; Credit +5% |
| credit_perc_1 | Decentralized Cryptocurrencies | spy | 1000 | credit_1 | Credit +10% |
| credit_2 | Confiscatory Policies | spy | 3000 | credit_perc_1 | Credit +300 |
| spy_2 | Secret Organization | spy | 25000 | credit_2 | Credit +15%; Erased +2 |
| credit_3 | Embezzlement | spy | 20000 | spy_2 | Credit +500 |
| credit_pola_1 | Financialized Society | spy | 100000 | credit_3 | Credit +40%; Tech −10%; Ideo −10%; Stab −24 |
| speaker_1 | First Contacts | speaker | 50 | agent | Ideology +3; Tech +3 |
| ideo_1 | Linguistic Unification | speaker | 300 | speaker_1 | Ideology +6 |
| ideo_2 | Mass Media | speaker | 3000 | ideo_1 | Ideology +16 |
| speaker_2 | Public Relations | speaker | 3000 | ideo_2 | Siderian +3 |
| speaker_3 | Soft Power | speaker | 20000 | speaker_2 | Siderian +6; Navarch +2; Tech −4% |
| speaker_dominion | Cultural Imperialism | speaker | 80000 | speaker_3 | Make-dominion +20%; Encourage-hate +20% |
| speaker_4 | Embassy Arsenal | speaker | 20000 | speaker_2 | Siderian +6; Erased +2; Production −10% |
| conversion | Siderian Legacy | speaker | 80000 | speaker_4 | Seduction +20 and +10% |
| stab_2 | Propaganda | speaker | 6000 | ideo_2 | Stability +40 |
| ideo_3 | Stelloliberalized Entertainment | speaker | 30000 | stab_2 | Ideology +15% |
| ideo_pola | Fake News | speaker | 100000 | ideo_3 | Ideology +30%; Tech −6%; Credit −6% |
| tech_1 | Promotion of Science | speaker | 300 | speaker_1 | Technology +6 |
| tech_2 | Sponsored Chairmanship | speaker | 3000 | tech_1 | Tech +10; Siderian +2 |
| stab_1 | Synthetic Drugs | speaker | 4000 | tech_2 | Credit/Tech/Production +5% each |
| tech_3 | Predictive Sciences | speaker | 30000 | stab_1 | Technology +15% |
| tech_pola | Technocracy | speaker | 100000 | tech_3 | Tech +30%; Ideo −6%; Production −4% |

Classes (`data.doctrine_class`): root "Origin", expansion, admiral "Navarchs", spy "Erased", speaker "Siderians" (+ `character`, fast only).

#### Traditions and cultures

**Traditions** are not chosen: four fixed passives per faction (`lib/data/game/content/faction.ex`, field `traditions`), always in force for every member from turn 0 — three benefits (`_early`/`_mid`/`_late`) and one malus. Applied in `player.ex:1069-1079` with reason `{:tradition, key}`.

| faction | early | mid | late | malus |
|---|---|---|---|---|
| tetrarchy | Aphera Research Centers: Tech +3 | Heart of the fleet: frigate initial XP +25% | Chatur Arsenal: maintenance −10% | Old Houses: Ideology −5% |
| myrmezir | Revolutionary Inspiration: Ideology +2 | Siderean Teachings: make-dominion +20% | The Ariance Charter: dominion rate +0.1 | Cultural diversity: Stability −5 |
| cardan | Nekesh Circle: Intelligence +20 | RNA Selection: assassination +15% | Network of Believers: infiltration +15% | Technology Caution: Tech −5% |
| synelle | Salt of the Earth: Production +30 | Syns strength: Defense +10% | Grey Militia: repair +20% | Decentralization: Credit −5% |
| ark | Multisidereal Consortium: Credit +50 | Surveillance Company: Stability +10 | Aeronautical Tycoon: Mobility +15% | Mercenary: maintenance +5% |

**Cultures** (`lib/data/game/content/culture.ex`, 5 keys + `null` locale placeholder) are cosmetic only: name repositories per faction (1:1), drive generated agent names, portrait selection (`character_illustration.ex:17`), and place-name pools (`manager.ex:673-697`). Revealed as an intel field at spy detail level 4 (`faction/character.ex:90`). Locale `data.culture.<key>.{name,kind}`: Tetrarchic, Myrmezirian, Cardanian, Syn, Stelloliberalist.

#### Faction trees [EXCLUDED: faction-government beta]

Faction patents (`content/faction_patent.ex`, treasury technology, bought by the Head of Economy):

| key | cost | prereq | effect |
|---|---|---|---|
| research_compact | 800 | — | Technology +2 (per member) |
| deep_space_relay | 1600 | research_compact | Radar +0.5 |
| counterintel_grid | 3200 | deep_space_relay | Counter-intelligence +10 |
| standardized_freight | 1600 | research_compact | Fleet maintenance −5% |
| chartered_shipyards | 3200 | standardized_freight | Fleet repair +15% |
| orbital_engineering | 2400 | research_compact | gates Training Center faction building |
| gateway_theory | 12000 | orbital_engineering | gates Gateway building |
| cyber_warfare_program | 6400 | counterintel_grid | gates Cyber Command building |

Faction lexes (`content/faction_lex.ex`, treasury ideology, bought by the Leader; effect only while enacted):

| key | cost | prereq | effect |
|---|---|---|---|
| assembly_charter | 600 | — | Ideology +2 |
| civic_pride | 1200 | assembly_charter | Stability +3 |
| sanctuary_accord | 2400 | civic_pride | System defense +10% |
| mobilization_act | 1200 | assembly_charter | System mobility +10% |
| war_footing | 2400 | mobilization_act | Invasion +10% |

Marquee nodes (Gateway Network, SLSD Command Uplink, War Bonds, Lend-Lease, Colonial Charter, Claimed Sector, Emergency Powers) are designed but unimplemented — `docs/faction-government.md:713-830`.

#### Mechanics and formulas

- **Patents** — `purchase_patent/2` (`player.ex:440-471`): errors `:unknown_patent`, `:patent_already_purchased`, `:patent_locked` (single `ancestor`), `:not_enough_technology`. Cost = `patent.cost × (1 + owned_count × patent_level_price_increase) × mutator` — Legacy `patent_level_price_increase = 0.05` (+5 % per owned patent, shown as "Cost Increase Factor"). Mutators: `open_science` ×0.5, `lost_sciences` ×2.0 (`mutator.ex:820-824`). No refund, no cooldown; permanent and immediately active. A `TODO: modificateur culturel` (`:460`) was never built.
- Gates: building orders check `level.patent ∈ patents` (`:382-387`); ship orders check `ship.patent` **and** all lower-`unit_count` variants of the same `model` (`:416-426`, `:ancestors_patents_not_unlocked`) — this is what `merge_*` patents feed.
- Player starts with no patents/doctrines/policies, `max_policies: 1`, `update_policies_count: 1`; 450 technology / 370 ideology / 300 000 credit on Legacy.
- **Lexes** — two-step: buy, then slot. `purchase_doctrine/2` (`:473-501`): cost = `doctrine.cost × (1 + owned_count × 0.05)` ideology. Buying alone grants nothing.
- `purchase_policy_slot/1` (`:503-521`): cost = `2^(max_policies − 1) × 200`, capped at 100 000 → 200, 400, 800, 1600 … Mirrored client-side in `front/src/game/calc/env.js:41-47`.
- `update_policies/2` (`:523-570`): sets the whole active list. Rejects `:too_many_policies`, `:cooldown_not_unlock`, `:unavailable_doctrine`; re-validates downstream capacity (`:not_enough_system_slot` / `_dominion_slot` / `_admirals_slot` / `_spies_slot` / `_speakers_slot`). Lexes are freely swappable, but you cannot un-slot capacity you are using.
- Cooldown after each change: `2 + update_policies_count × 4` ut (`:552`); count starts at 1 and never resets → 6, 10, 14, 18 … ut (18 wall-min then +12 min per change).
- Only slotted policies apply bonuses (`:1055-1067`, reason `{:doctrine, key}`).
- **Faction trees** — `Government.purchase/5` (`government.ex:1504-1550`): government `:running`; seat gate (economy for patents, leader for lexes; Tetrarchy leader-overreach allowed at an income malus); `:already_owned`, `:ancestor_not_owned`, `:treasury_insufficient`. Cost = `round(node.cost × economy_mods[...])`; ARK also pays treasury credit ×10. Modifiers: ARK 0.9/0.9; Cardan patents 1.1, lex 0.95, law cooldown 0.95; Myrmezir lex 0.9, cooldown 1.1; Synelle patents 0.9, lex 1.1; Tetrarchy neutral.
- `update_laws/4` (`:2282-2333`): Leader only, `government_max_laws` = **2** (`constant-slow.ex:68`), blocked by `law_cooldown`; Myrmezir routes through a 24 h referendum. `apply_laws/3` arms `government_law_cooldown` = 480 ut (24 h). `effects/2` pushes patents + active laws to every member (reason `{:government, key}`).
- No refund/repeal-with-rebate anywhere.

#### UX surfaces, icons, locale keys

- `mini-panel/PatentMiniPanel.vue` (class tabs, tree layout, cost-factor header), `DoctrineMiniPanel.vue` (tree + staging area, `+1 slot`, cooldown counter), `FactionTreeMiniPanel.vue` (patent/lex tabs, treasury, `laws n/max`, overreach warning).
- `card/PatentCard.vue`, `card/DoctrineCard.vue`, `card/FactionTreeCard.vue`.
- Icons: `front/src/icons/patent/*.js` (one per key + frames; includes keys used by other speeds), `front/src/icons/doctrine/*.js`.
- Locale: `data.patent.<key>.{name,description,quote}`, `data.patent_class`, `data.patent_info` (19), `data.doctrine.*`, `data.doctrine_class`, `data.tradition.<20>.{name,description,bonus_label}`, `data.culture`, `data.faction_patent`, `data.faction_lex`; `minipanel.patent.*`, `minipanel.doctrine.*`, `minipanel.faction_tree.*`, `card.patent.*`, `card.doctrine.*`, `card.faction_tree.*`, `panel.faction_government.*`.
- Channel commands: `purchase_patent`, `purchase_doctrine`, `purchase_policy_slot`, `update_policies` (`player_channel.ex:210-238`); `gov_purchase_patent` etc. (`faction_channel.ex:580`).
- Existing tables: `lib/mix/tasks/patent_table.ex`, `lex_table.ex` (MediaWiki, join content with `data.json`, filter `[INACTIF]`/`[UNAVAILABLE]` rows).

#### Cross-links

- Buildings: `building.ex:74-107` (`patent`, `hide_patent?` per level) — the patent tree is effectively the building unlock index.
- Ships: `ship-slow.ex` (`patent`, `model`, `unit_count`, `hide_patent?`).
- Bonus pipeline: every lex/tradition/faction-node effect resolves through `extract_bonus` (`player.ex:1030-1200`).
- Agent limits: `player_admiral|spy|speaker` outputs are the recruit caps enforced in `update_policies` (`:542-549`) and at hire.
- Faction government: `docs/faction-government.md` §5–§6; `government.ex`; seat rules `government/rules/*.ex`. Faction buildings gated by faction patents (`government.ex:1579`).
- Mutators: `mutator.ex:807-830`, `instance/mutators.ex:63,95`.

#### Gaps / ambiguities

- Three-way naming split: internal `doctrine` (purchased) / `policy` (slotted) / UI "Lex" and "Policies"; faction side "lex" (purchased) / "law" (enacted). The manual must fix one vocabulary.
- Cultures have no gameplay effect; two TODOs reserve a cultural price modifier.
- Fast/medium trees differ materially (fast: 39 doctrines vs 61). A Legacy-only manual misleads Flash players.
- `[UNAVAILABLE]`/`[INACTIF]` rows exist; not audited which Legacy keys carry them.
- Policy cooldown count never resets; late-game swaps become very expensive. Intent unknown.
- Faction trees have no per-speed variants; identical costs in a 30-day Legacy and a 4-hour Flash game.
- No refund/respec path exists anywhere; "permanent" is accurate.

---

### A.4 Navarchs and fleet actions

Time unit = **ut**. `1 ut = 180_000 ms / speed.factor` (`character/action.ex:93`); Legacy factor 1 → 1 ut = 3 wall-minutes; medium 20 → 9 s; fast 120 → 1.5 s; daily 240 → 0.75 s.

#### Actions table

Registry `character/action_impl.ex:10-26`. Every action = `pre_validate/2` (queue-time) → `start/2` → `finish/2`.

| UI name | key | Target | Preconditions | Duration | Cost | Effect on target | Interrupted by | file:line |
|---|---|---|---|---|---|---|---|---|
| Move | `:jump` | adjacent system (graph edge) | not `:docking`; target ≠ current; `virtual_position == source`; edge exists; Erased: not discovered | `edge.weight × character_movement_factor` | none | none | queue clear (`character/agent.ex:317`); death | `actions/jump.ex:13-39` |
| Bombard | `:raid` | inhabited system (player/dominion/neutral) | Navarch; not docking; on target; ≥1 ship; not own; no existing siege; no duplicate queued | `raid_time × ratio_to_factor(ratio(raid_coef, defense))`, resolved at `start` | fleet hull damage | pop loss, building damage, `raid_potential` −45, siege (production −100 %) | arrival interception; siege release on besieger death/flee/departure | `actions/raid.ex:10,45,51,85` |
| Pillage | `:loot` | same as raid | same | `loot_time × ratio_to_factor(...)` | fleet hull damage | credits/tech/ideology transferred; pop loss; buildings; `raid_potential` −45 | same | `actions/loot.ex:10,45,52,85` |
| Conquer | `:conquest` | inhabited system | Navarch; on target; ≥1 ship; free system slot; not own; no siege; sector `:takeable` | `conquest_time × ratio_to_factor(ratio(invasion_coef, defense)) × 0.5 in daily` | fleet hull damage | ownership transfer on success; pop loss; buildings; siege | same | `actions/conquest.ex:18,61,69,103` |
| Colonize | `:colonization` | `:uninhabited` system | Navarch; not docking; on target; free slot; carries `transport_1`; sector takeable; no siege | flat `colonization_time` (no dice) | consumes the `transport_1` | system claimed | interception at `start`; conditions re-checked at `finish` | `actions/colonization.ex:10,43,54,75` |
| Engage in combat | `:fight` | a named enemy Navarch on a system | Navarch; on target system; target still there and different owner | 0 | hull losses / death | battle | target gone → `fight_target_gone` | `actions/fight.ex:12,22` |
| Portal [EXCLUDED: beta] | `:gateway_charge` → `:gateway_jump` → `:gateway_fatigue` | linked far system | not docking; gateway pair linked/free/powered | 120 / 40 / 40 ut | 250 credit + 50 tech per ut of charge | arrival interception only | cannot be recalled mid-jump | `actions/gateway_*.ex` |
| Dock (implicit) | `action_status: :docking` | own fleet | idle or docking | until ship build finishes | ship cost | — | cancelling all planned ships → idle | `character.ex:366,413-436` |
| Flee (implicit) | queue-injected `:jump` | closest system by edge weight | after lost battle, `:flee` roll, or failed raid/loot/conquest | normal jump time | — | — | — | `character.ex:369-392`, `galaxy.ex:125` |

Queue: unbounded FIFO (`action_queue.ex:27-33`); `virtual_position` is the "where the queue ends" cursor every `pre_validate` checks; `clear_actions(index)` truncates.

#### Mechanics

**Stances** (`army.reaction`, valid set `army.ex:6`, default `:defend`). UI names in `game.json` `character_reaction.*`.

| Internal | UI | incoming | hostile_action in my system | I arrive, enemy present | I arrive, enemy busy |
|---|---|---|---|---|---|
| `flee` | Deserter | – | – | – | – |
| `fight_back` | Prudent | – | – | – | – |
| `defend` | Defender | – | ✔ | – | ✔ |
| `attack_enemies` | Interdiction | ✔ | ✔ | – | – |
| `attack_everyone` | Fury | ✔ | ✔ | ✔ | ✔ |

**`Stances.vue:66-73` matches the code exactly** (`jump.ex:177,193-195`; raid/loot/conquest/colonization pass `[:defend, :attack_enemies, :attack_everyone]`). Deserter forbidden inside an armada (`armada.ex:91`); bankruptcy forces `:flee` on non-armada Navarchs (`character.ex:326-338`).

**Two-pass interception** (`Fight.check_interception/4`, `fight.ex:198-236`; `find_hostiles/4` `:328-371`): pass 1 = actor's own engagement (`:all` Fury / `:busy` Defender / `:none`); pass 2 = sitters intercept only if idle (`:idle` or `:docking`) and stance ∈ reactions. Union, deduplicated. `present?` excludes `[:moving, :attached, :fight]`. Hostiles ordered Fury → Interdiction → Defender → Prudent → Deserter with seeded shuffle (`fight.ex:525-533`). `joined_with/2` folds armada co-members and eligible faction-mates into one battle. Actor with `:flee` rolls `rand < fleeing_chance (0.5)` first; success = retreat jump + cancel planned ships (`fight.ex:264-287`).

**Armadas** [EXCLUDED: gated behind the faction-government beta] (`docs/armadas.md`): plain map `%{id, name, member_ids}` on each member; size 2–3; same player, co-located, all idle. Lead = first member to enqueue. Transit: lead jumps, members `:attached` (no radar blip), all materialize at destination before the interception pass (`jump.ex:61-65, 201-212`). Armada acts with its most aggressive member's stance (`Armada.effective_reaction/1`). Gated behind the Faction Government beta (`actionValidation.js:10-19`).

**Fleet slots and maintenance**: `army_tile_count = 18` on every speed. Maintenance = Σ `maintenance_cost` over filled tiles (`army.ex:271`), surfaced as `army_maintenance`, subtracted from `player_credit` per Navarch (`player.ex:1211-1221`); feeds score ×1.1 (`player.ex:812`) and resale value ×250 (`player/market.ex:306-307`).

**Siege** (`stellar_system/siege.ex`): `{type, days, duration, besieger_id}`, counts down 1/ut. Started by raid/loot/conquest `start`. While besieged: production −100 %, all production orders/removals throw `:no_production_under_siege`, no other hostile action can start. Released by action `finish`, besieger death/flee, besieger departure backstop (`agent.ex:255-280`), or expiry with orphan sweep (`stellar_system.ex:951-976`).

**Defense**: `system_base_defense × workforce` for `:inhabited_player` only, plus buildings/lexes. It is the defender term in every dice roll and in the duration ratio: higher defense both slows the siege and worsens attacker odds, and scales attacker hull loss.

**Detection**: only characters with `action_status == :moving` enter the spatial index (`lib/game/spatial/spatial.ex:10-30`) — **idle fleets sitting in a system are never radar blips; `:attached` armada members neither**. Radar disks per system: `radius = radar.value × 3`; blips carry faction, position and heading only.

**Travel graph**: any two systems within `@max_dist = 12` map units are linked, weight = Euclidean distance (`spatial_graph.ex:6-7,52-55`); edges crossing a blackhole disk are dropped (`:177-204`); disconnected components stitched with the shortest legal edge. Sector takeability (conquest + colonization): sector owned by your faction or adjacent to one you own (`galaxy.ex:108-123`).

#### Formulas and constants (Legacy / medium / fast)

- Travel time = `edge.weight × character_movement_factor` ut; factor **7.2** / 4.4 / 6. Max hop ≈ 12 ⇒ ≤ 86.4 ut ≈ 4 h 20 on Legacy.
- Dice (`lib/game/core/dice.ex`): `ratio = A/(A+D)`; window `[ratio − 0.20 + 0.01×min(level,20), ratio + 0.20]` clamped; roll < 0.05 critical failure, < 0.50 failure, < 0.95 success, else critical success.
- Siege duration = `base × (2 − |ratio − 0.5| × 2)` → 1.0× (mismatch) to 2.0× (even). Bases: `raid_time` **40**/26/40, `loot_time` **20**/18/30, `conquest_time` **150**/40/60, `colonization_time` **150**/40/20.
- Attack values: raid/loot use `army.raid_coef`, conquest `army.invasion_coef` = Σ `ship.unit_*_coef × (hull/max_hull) × unit_count` + army bonuses (`army.ex:254-306`).
- Attacker hull loss = `pv_factor × defense + (1 − ratio) × 0.1 × total_army_pv`; `pv_factor` by outcome raid 12/10/8/6, loot 15/13/10/7, conquest 12/10/8/6 (crit-fail → crit-success). Damage spread: 4 passes, ≤25 % of a ship's `unit_hull` per tile (`army.ex:92-135`).
- Repair = `repair_coef × 0.4 × elapsed_time` hull points, proportional to missing hull; **only while the queue is empty** (`character.ex:626-632`).
- Target damage `{pop-loss %, buildings}`: raid `{0,0}`, `{0.05,1}`, `{0.10,5}`, `{0.20,6}`; loot `{0,0,×0}`, `{0.02,0,×0}`, `{0.05,2,×150}`, `{0.02,1,×200}`; conquest `{0.02,0,no}`, `{0.10,2,no}`, `{0.20,6,taken}`, `{0.05,2,taken}`.
- Loot payout = `system.<res>.value × multiplier × (raid_potential/100)`, moved from victim to raider (`loot.ex:122-129`).
- Raid potential regrows 0.25/ut to 100; each siege release subtracts **45**/45/30.
- XP = `10 × factor`; raid 0.1/0.3/1/1.2, loot same, conquest 0.25/0.8/1.2/1.5; colonization 10; `drop_explorer_xp` 2 on first arrival (`jump.ex:214-228`).
- Failure retreat: failure/critical failure on raid, loot or conquest forces a flee jump to the nearest system.

#### UX surfaces, icons, locale keys

- `card/CharacterCard.vue`, `ClosedCharacterCard.vue`, `overlay/opened-character.vue`, `card/TargetSystemCard.vue`, `galaxy/selection/Army.vue` (stance picker, 18-tile grid), `galaxy/MapActionRadial.vue:55-66`, `galaxy/system/Actions.vue` + `ActionOverview.vue` (attacker-vs-defender preview), `panel/help/Stances.vue`. Client gating: `front/src/utils/actionValidation.js`.
- Icons: `action/{jump,raid,loot,conquest,colonization,fight,gateway_*}` (+ `_alt`), `reaction/*`, `agent/admiral`, `ship/{raid,invasion,repair,interception,hull,shield,handling,unit}`.
- Locale: `data.character.admiral.*`, `data.character_action_status.*`, `data.character_rank.*`; `character_reaction.*`, `panel.help.stances_*`, `galaxy.system.actions.*` (incl. `fail_hint_*`), `notification.text.*`, `notification.box.*`, `notification.report.{raid,loot,conquest,fight}.*`, `report.*`, `resource-description.{defense,radar}`, `resource-detail.type.fleet_maintenance`, `card.character.*`, `card.opened_character.*`.

#### Cross-links

- Ships: `ship.ex:15,31-33` (`maintenance_cost`, `unit_repair_coef`, `unit_invasion_coef`, `unit_raid_coef`); `fight/manager.ex` resolves battles.
- Systems: defense, production, raid_potential, population, building damage, siege penalties in `stellar_system.ex`.
- Siderian: `make_dominion` competes for the same systems and appears in Stances help text.
- Erased: `sabotage.ex` → `Army.sabotage/3`; `assassination.ex` kills Navarchs; discovered Erased cannot move (`jump.ex:17-18`).
- Diplomacy: `:bombardment`, `:pillage`, `:conquest`, `:fleet_destroyed` reports. Victory: sector ownership via `claim_system`/`lose_system`. News: `raid.hit`, `loot.hit`, `conquest.taken`, `colonize.first`, `battle.fought`. Economy: bankruptcy sets `on_strike`, blocks orders, forces Deserter.

#### Gaps / ambiguities

1. **Stances help lists "dominion takeover" as a Defender/Fury trigger, but `MakeDominion` never calls `check_interception`.** Help text or action is wrong.
2. Colonization has no dice roll and no interception at `finish`.
3. Possible siege leak: `{:clear_actions, 0}` drops a running raid/conquest without releasing the siege if the Navarch stays. Unverified.
4. `raid_coef` powers both bombardment and pillage; no separate pillage stat.
5. `:attack_enemies` vs `:attack_everyone` not distinguished by alliance (TODOs `fight.ex:51-52, 336-337`); "unallied" = different faction only.
6. Fury's `arriving_busy` is subsumed by `arriving`.
7. No action-queue length cap found.

---

### A.5 Ships and battle resolution

Struct `lib/data/game/ship.ex:7-35`. **No ship "speed" or "range" stat exists** — movement is a character property. Combat stats are per unit; a "ship" is a squadron of `unit_count` identical units on one army tile. `unit_pattern` is cosmetic. `unit_armor` is sim-only (default 0).

#### Ship table (38 keys, `lib/data/game/content/ship-slow.ex`)

Strikes read `count × damage`. E = energy, X = explosive. Yard 1–4 = `shipyard_N_orbital`. Costs credit / technology / production.

| key | UI name | class | units | hull | handl. | shield | flak | E strikes | X strikes | raid/inv/rep | wt | credit/tech/prod | maint | yard | patent |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| fighter_1 | 2 Scouts | fighter | 2 | 12 | 90 | 0 | 0 | 1×4 | — | 0/0/0 | 1 | 900/0/120 | 1 | 1 | shipyard_1 |
| fighter_1v2 | 4 Scouts | fighter | 4 | 12 | 90 | 0 | 0 | 1×4 | — | 0/0/0 | 2 | 1800/0/232 | 2 | 1 | merge_fighter_1 |
| fighter_1v3 | 8 Scouts | fighter | 8 | 12 | 90 | 0 | 0 | 1×4 | — | 0/0/0 | 4 | 2900/0/472 | 4 | 1 | merge_fighter_2 |
| fighter_1v4 | 16 Scouts | fighter | 16 | 12 | 90 | 0 | 0 | 1×4 | — | 0/0/0 | 8 | 5800/0/944 | 8 | 1 | merge_fighter_3 |
| fighter_2 | 2 Light Fighters | fighter | 2 | 25 | 65 | 10 | 0 | 2×9 | 1×3 | 0/0/0 | 2 | 1400/0/352 | 8 | 1 | fighter_2 |
| fighter_2v2 | 4 Light Fighters | fighter | 4 | 25 | 65 | 10 | 0 | 2×9 | 1×3 | 0/0/0 | 4 | 2700/25/704 | 16 | 1 | merge_fighter_1 |
| fighter_2v3 | 8 Light Fighters | fighter | 8 | 25 | 65 | 10 | 0 | 2×9 | 1×3 | 0/0/0 | 8 | 4300/50/1408 | 32 | 1 | merge_fighter_2 |
| fighter_2v4 | 16 Light Fighters | fighter | 16 | 25 | 65 | 10 | 0 | 2×9 | 1×3 | 0/0/0 | 16 | 8600/100/2824 | 64 | 1 | merge_fighter_3 |
| fighter_3 | 2 Fighter-bombers | fighter | 2 | 20 | 60 | 0 | 0 | — | 1×10 | 1/0/0 | 2 | 1400/0/352 | 10 | 1 | fighter_3 |
| fighter_3v2 | 4 Fighter-bombers | fighter | 4 | 20 | 60 | 0 | 0 | — | 1×10 | 1/0/0 | 4 | 2700/25/704 | 20 | 1 | merge_fighter_1 |
| fighter_3v3 | 8 Fighter-bombers | fighter | 8 | 20 | 60 | 0 | 0 | — | 1×10 | 1/0/0 | 8 | 4300/50/1408 | 40 | 1 | merge_fighter_2 |
| fighter_3v4 | 16 Fighter-bombers | fighter | 16 | 20 | 60 | 0 | 0 | — | 1×10 | 1/0/0 | 16 | 8600/100/2824 | 80 | 1 | merge_fighter_3 |
| fighter_4 | 2 Interceptors | fighter | 2 | 25 | 75 | 0 | 0 | 4×6 | — | 0/0/0 | 3 | 1400/0/352 | 8 | 1 | fighter_4 |
| fighter_4v2 | 4 Interceptors | fighter | 4 | 25 | 75 | 0 | 0 | 4×6 | — | 0/0/0 | 6 | 2700/25/704 | 16 | 1 | merge_fighter_1 |
| fighter_4v3 | 8 Interceptors | fighter | 8 | 25 | 75 | 0 | 0 | 4×6 | — | 0/0/0 | 12 | 4300/50/1408 | 32 | 1 | merge_fighter_2 |
| fighter_4v4 | 16 Interceptors | fighter | 16 | 25 | 75 | 0 | 0 | 4×6 | — | 0/0/0 | 24 | 8600/100/2824 | 64 | 1 | merge_fighter_3 |
| corvette_1 | 2 Light Corvettes | corvette | 2 | 75 | 40 | 30 | 0 | 2×19 | 2×6 | 2/0/1 | 4 | 4300/80/1176 | 14 | 2 | corvette_1 |
| corvette_1v2 | 4 Light Corvettes | corvette | 4 | 75 | 40 | 30 | 0 | 2×19 | 2×6 | 2/0/1 | 8 | 8600/160/2352 | 28 | 2 | merge_corvette_1 |
| corvette_1v3 | 8 Light Corvettes | corvette | 8 | 75 | 40 | 30 | 0 | 2×19 | 2×6 | 2/0/1 | 16 | 17300/320/4704 | 56 | 2 | merge_corvette_2 |
| corvette_2 | 2 Heavy Corvettes | corvette | 2 | 110 | 30 | 20 | 15 | — | 1×18 | 3/0/2 | 5 | 4300/100/1176 | 15 | 2 | corvette_2 |
| corvette_2v2 | 4 Heavy Corvettes | corvette | 4 | 110 | 30 | 20 | 15 | — | 1×18 | 3/0/2 | 10 | 8600/200/2352 | 30 | 2 | merge_corvette_1 |
| corvette_2v3 | 8 Heavy Corvettes | corvette | 8 | 110 | 30 | 20 | 15 | — | 1×18 | 3/0/2 | 20 | 17300/400/4704 | 60 | 2 | merge_corvette_2 |
| corvette_3 | 2 Multi-turret Corvettes | corvette | 2 | 335 | 20 | 10 | 7 | 6×11 | — | 0/0/0 | 4 | 8600/875/1426 | 30 | 2 | corvette_3 |
| corvette_3v2 | 4 Multi-turret Corvettes | corvette | 4 | 335 | 20 | 10 | 7 | 6×11 | — | 0/0/0 | 8 | 17300/1750/2852 | 60 | 2 | merge_corvette_1 |
| corvette_3v3 | 8 Multi-turret Corvettes | corvette | 8 | 335 | 20 | 10 | 7 | 6×11 | — | 0/0/0 | 16 | 34600/3500/5704 | 120 | 2 | merge_corvette_2 |
| transport_1 | Colonisation Ship | transport | 1 | 400 | 0 | 10 | 10 | — | — | 0/0/0 | 5 | 60000/15000/32000 | 100 | none | transport_1 |
| transport_2 | Carrier | transport | 1 | 1500 | 30 | 50 | 5 | 2×3 | — | 0/**30**/10 | 18 | 18000/3000/6720 | 300 | none | transport_2 |
| frigate_1 | 2 Assault Frigates | frigate | 2 | 200 | 20 | 60 | 10 | 2×26 | 1×77 | 0/2/0 | 12 | 9200/200/3920 | 40 | 3 | shipyard_3 |
| frigate_1v2 | 4 Assault Frigates | frigate | 4 | 200 | 20 | 60 | 10 | 2×26 | 1×77 | 0/2/0 | 24 | 22000/400/7840 | 80 | 3 | merge_frigate_1 |
| frigate_2 | 2 Gunners | frigate | 2 | 320 | 10 | 35 | 20 | — | 1×390 | 8/0/0 | 14 | 21600/3000/3920 | 60 | 3 | frigate_2 |
| frigate_2v2 | 4 Gunners | frigate | 4 | 320 | 10 | 35 | 20 | — | 1×390 | 8/0/0 | 28 | 43200/6000/7840 | 120 | 3 | merge_frigate_1 |
| frigate_3 | 2 Drone Carriers | frigate | 2 | 950 | 20 | 65 | 30 | 10×8 | — | 2/0/2 | 14 | 21600/2500/5880 | 100 | 3 | frigate_3 |
| frigate_3v2 | 4 Drone Carriers | frigate | 4 | 950 | 20 | 65 | 30 | 10×8 | — | 2/0/2 | 28 | 43200/5000/11760 | 200 | 3 | merge_frigate_1 |
| frigate_4 | 2 Repair Platforms | frigate | 2 | 1500 | 15 | 30 | 80 | — | 1×16 | 0/2/**75** | 14 | 21600/500/3000 | 75 | 3 | frigate_4 |
| frigate_4v2 | 4 Repair Platforms | frigate | 4 | 1500 | 15 | 30 | 80 | — | 1×16 | 0/2/**75** | 28 | 43200/1000/6000 | 150 | 3 | merge_frigate_1 |
| capital_1 | Destroyer | capital | 1 | 4000 | 0 | 65 | 40 | 4×150 + 10×50 | 8×50 | 30/0/10 | 30 | 200000/25000/100000 | 1400 | 4 | capital_1 |
| capital_2 | Cruiser | capital | 1 | 5000 | 0 | 50 | 70 | 6×120 + 4×80 + 6×30 | 1×800 + 2×100 | 50/20/30 | 40 | 250000/30000/120000 | 1600 | 4 | capital_2 |
| capital_3 | Coordinator | capital | 1 | 7000 | 0 | 85 | 75 | 8×30 | 6×20 | 0/200/500 | 35 | 320000/35000/120000 | 1500 | 4 | capital_3 |

`vN` variants are merge formations of the same model (`merge_to` chain); ordering one requires the merge patent **and** all smaller-formation patents of that model (`player.ex:422-427`). Capital ships get a random proper name (`character.ex:420-423`).

#### Battle mechanics, one battle step by step

1. Trigger: explicit `:fight` (`actions/fight.ex:12-20`) or interception on arrival (`:198-236`).
2. Flee check (interception path): stance `:flee` → `rand < 0.5`; success = jump to closest system, queued ships cancelled (`:266-286`).
3. Side assembly: attacker + faction-mates with joining stance + armada members (`:55-82, 541-555, 481-500`) → `Fight.Manager.fight/2`.
4. Conversion: `Fight.Army.convert` (`fight/army.ex:18-37`); `Fight.Ship.convert` applies level scaling and morale (`fight/ship.ex:31-83`).
5. Join delay: Nth army of a side waits `(N−1) × 2` turns (`manager.ex:63-72`).
6. Fight scale = Σ `weight` of all filled tiles both sides (`manager.ex:76-84`).
7. Turn loop, max 100 turns (`manager.ex:134-159`):
   - transfer: one line of 3 tiles per army enters every 2 turns (`army.ex:39-52`);
   - release target if gone (`manager.ex:212-227`);
   - pick target: **uniform random** among enemy ships on the field (`:193-210`) — no class preference;
   - engage: all ships sorted by **morale descending** (the only "initiative", `:235-237`); each alive unit fires its full strike list at a random alive unit of the target, re-rolled per strike (`fight/ship.ex:155-223`);
   - cleaning: destroyed ships removed, escaping ships pulled back (`manager.ex:287-347`);
   - morale ≤ 0 → `:escaping` (`fight/ship.ex:105`);
   - outcome: side defeated when no ship on field and no reinforcement line left (`:417-426`); both → draw; turn 100 → draw.
8. Post-battle status per character: `:victorious` / `:dead` (no ship left) / `:fleeing` (`manager.ex:100-131`).
9. Character XP = `min(fight_scale,1000)/1000 × 15 + 6` (6–21), zero if no ships (`:112-123`).
10. Ship XP: `min(gained_xp,100)/5 + 5` on conversion back (`character/ship.ex:26-31`).
11. Callbacks: `:fleeing` releases siege, enqueues retreat jump, clears production queue; `:dead` releases siege, detaches armada, kills character (`player/agent.ex:1333-1394`).
12. Diplomacy/news: `:fleet_destroyed`; `battle.fought`.
13. Report: `RC.PlayerReports` row `type: "fight"` + `Notification.Box :fight` (`fight.ex:560-670`).

#### Formulas and constants (Legacy)

- `army_tile_count = 18` → 6 lines of 3.
- Morale at start = `army_unit_base_morale (20) + ship.level × 0.5 + character.level × 0.5` (`fight/ship.ex:66-68`).
- Level scaling (`fight/ship.ex:34-51`): strikes `× (1 + 0.01 × level)`; `handling = min(base + 0.5 × level, 95)`; shield/interception same if base > 0. (Comments say +0.5 %/+0.1 per level; code does +1 %/+0.5.)
- Hit resolution (`:225-263`): `p(dodge) = handling/100 × 0.75` vs energy, `× 1.0` vs explosive. On hit: energy `dmg × (1 − shield/100)`; explosive `rand < interception/100 → 0` else full. Then `max(dmg − armor, 0)`.
- Damage capped at unit hull; hull 0 → destroyed (`fight/ship_unit.ex:20-30`).
- Morale loss on target ship by damage ratio of max hull: <5 % → 0, <10 % → 1, <20 % → 2, <30 % → 6, <40 % → 10, else 15 (`fight/ship.ex:138-153`). Side-wide loss on every enemy ship: 0.3 per unit lost + 2.5 if a ship died.
- Ship XP in battle = `damage_dealt × 0.01`.
- Level-up threshold: `round(10×(L+1) + ((L+1)/2)^2.5) − xp` (`character/ship.ex:73-75`); same shape for characters (`character.ex:894-896`).
- Initial ship XP at build = system's `fighter_lvl / corvette_lvl / frigate_lvl / capital_lvl` (`stellar_system.ex:1128-1140`).
- Out-of-combat repair: `repair_coef × 0.4 × elapsed_time`, spread over missing hull (`army.ex:199-240`); only while idle. `repair_coef` per ship = `unit_repair_coef × (hull/max_hull) × unit_count` — damaged ships repair slower.
- Fight-scale names (client): >100 small, >300 medium, >600 big, >1000 xbig, >2000 xxbig (`Reports.vue:412-418`).

#### UX surfaces, icons, locale keys

- `card/ShipCard.vue` (stats, formation pips, per-unit hull dots); keys `card.ship.*`, `card.cost.*`, `data.ship.<key>.{name,description,trade_name}`.
- `galaxy/selection/Army.vue` (18-tile grid, coefficient readouts), `CharacterCard.vue`, `ClosedCharacterCard.vue`.
- Reports: `panel/operation/Reports.vue`, `report/FightReport.vue`, `box-notification/FightNotif.vue`; keys `report.*`, `panel.operations.fight_*`.
- Simulator: `portal/pages/FightSimulator.vue` + `SimulatorRoundLog.vue`; backend `fight_controller.ex` (`POST /run-fight`, `GET /fight-balances`), capped at 100 runs; headless `lib/sim/*`.
- Icons `ship/`: one per key + `hull, shield, handling, interception, energy_strikes, explosive_strikes, repair, raid, invasion, loot, unit`, frames.

#### Cross-links

- Build chain: player pays credit+tech, checks patents (`player.ex:400-437`) → system checks shipyard present and no siege (`stellar_system.ex:435-459`) → queued as `:ship` item → admiral `:docking`, tile `:planned` (`character.ex:414-435`) → `{:ship_built, item, initial_xp}` → `{:put_ship, tile_id, initial_xp}`.
- Patents: `patent-slow.ex:443-681`.
- Navarch actions: conquest → `invasion_coef`, raid/loot → `raid_coef`; those actions damage the army via `Army.damage/3`.
- Sabotage: `sabotage.ex:69` → `Army.sabotage/3` (`army.ex:137-197`): one random filled tile takes `sabotage_coef × pv_factor`, hex-ring neighbours 10 % splash.
- Colonization consumes a `transport_1` (`army.ex:242-248`).
- Armadas: `docs/armadas.md`, `Armada.order_battle_side/2`.

#### Gaps / ambiguities

- **0.001-hull zombie bug is present.** `Character.ShipUnit.convert/1` stores a dead unit as `hull: 0.001` (`character/ship_unit.ex:20-27`); `Fight.ShipUnit.convert/1` marks destroyed only when `hull == 0` exactly, so such units re-enter the next battle alive, absorb targeting rolls and fire full strikes. `Ship.is_destroyed/1` requires all units at exactly 0.001; repair heals them.
- `Army.damage/3` → `Ship.damage/2` applies computed damage to **every** unit of the ship (`character/ship.ex:54-57`); likely unintended.
- Comment/code mismatch on level scaling (`fight/ship.ex:34-47`).
- `unit_initial_level: 25` and `unit_level_growth: 1.5` constants are dead.
- `report.result` is a TODO (`fight.ex:111-114`).
- `ship_stats.csv` and `generate_wiki_tables.sh` at repo root contain a different (probably fast/balance) stat set — not a Legacy source.
- `:attack_enemies` vs `:attack_everyone` identical (TODO `fight.ex:51-53, 336-337`).
- `Fight.Army.experience` is read but never consumed.

---

### A.6 Siderians and Erased

- **Siderian** (`:speaker`, `character/speaker.ex:1-55`): three coefficients (`make_dominion_coef`, `encourage_hate_coef`, `conversion_coef`) and one shared **cooldown**; while `Speaker.locked?/1` no Siderian action can be queued or started. No cover; always visible to the system owner.
- **Erased** (`:spy`, `character/spy.ex:1-105`): `infiltrate_coef`, `sabotage_coef`, `assassination_coef` and a **cover** `DynamicValue` (initial 80, clamped 0–100, regen `@cover_recovery 0.25`/ut). No cooldown; the limiter is cover loss.

#### Siderian actions (all roll `Core.Dice.roll(attack, level, defense)`)

| UI name | key | target | preconditions | duration | attack vs defense | success | failure | file |
|---|---|---|---|---|---|---|---|---|
| Seduce | `:conversion` | one enemy agent (any type, incl. governor) in the system | Siderian free; no second queued; target present, not yours | instant | `conversion_coef` vs `target.determination` + `system.happiness` if the target's faction owns the system (floored at 0) | target removed from owner and re-created under the attacker; news `agent.converted`; diplomacy `:removal`/`:agent_removal` | cooldown + small XP | `actions/conversion.ex:10-120` |
| Destabilize | `:encourage_hate` | the system the Siderian stands on | not yours; status neutral/dominion/player; Siderian free | `encourage_hate_time` = **50 ut** | `encourage_hate_coef` vs `max(happiness, 0)` | happiness penalty pushed on the system; diplomacy `:destabilize` | penalty 0 (crit fail) or **5 (normal fail)** | `actions/encourage_hate.ex:10-119` |
| Control | `:make_dominion` | the system the Siderian stands on | status neutral or dominion; sector takeable; free dominion slot; not yours; Siderian free | `make_dominion_time` = **150 ut** | `make_dominion_coef` vs `max(happiness, 0)` | previous owner loses the dominion, attacker claims it; news `dominion.taken` | untouched; "under attack" pulse lifted | `actions/make_dominion.ex:11-183` |

Outcomes (crit fail / fail / success / crit success):
- conversion {cooldown, success, xp×}: 220,no,0.1 · 180,no,0.3 · 120,yes,1 · 100,yes,1.2
- encourage_hate {cooldown, penalty, xp×}: 120,0,0.1 · 100,5,0.3 · 40,15,1 · 30,20,1.2
- make_dominion {cooldown, taken, xp×}: 200,no,0.1 · 140,no,0.3 · 80,yes,1 · 60,yes,1.2

Late re-check at `finish` (`encourage_hate.ex:59-61`, `make_dominion.ex:108-111`): if preconditions fail, the action is cancelled silently, no roll.

#### Erased actions

| UI name | key | target | duration | attack vs defense | success | failure | file |
|---|---|---|---|---|---|---|---|
| Infiltrate the network | `:infiltrate` | the system the Erased stands on (neutral/dominion/player) | `infiltration_time` (50) × `ratio_to_factor` → **50–100 ut** | `infiltrate_coef` vs `system.counter_intelligence` | drops 1 (success) / 2 (crit) malware contacts for the attacker's faction on that system | 0 contacts, larger cover loss | `actions/infiltration.ex:9-105` |
| Sabotage the fleet | `:sabotage` | one enemy **Navarch** in the system | instant | `sabotage_coef` vs `target.protection` + system CI if the target's faction owns the system | ship damage `sabotage_coef × pv_factor` on a random filled tile, splash to adjacent tiles; diplomacy `:sabotage` | no damage, heavy cover loss | `actions/sabotage.ex:9-106`, `army.ex:137-170` |
| Delete | `:assassination` | one enemy agent (any type) in the system | instant | `assassination_coef` vs `target.protection` + system CI if owner | target killed; news `agent.assassinated`; diplomacy `:removal`/`:agent_removal` | survives, very heavy cover loss | `actions/assassination.ex:9-139` |
| Cover recovery (passive) | — | self | continuous, **only with an empty queue** | — | regen 0.25/ut + `spy_cover` bonuses, cap 100 | — | `character.ex:634-646`, `spy.ex:44-56` |

Outcomes (crit fail / fail / success / crit success):
- infiltrate {contacts, cover loss, xp×}: 0,30–40,0.1 · 0,20–30,0.3 · 1,8–12,1 · 2,4–8,1.2
- sabotage {cover loss, pv_factor, xp×}: 40–50,0,0.25 · 30–40,0,0.8 · 20–30,**6**,1.2 · 10–20,**12**,1.5
- assassination {success, cover loss, xp×}: no,50–80,0.25 · no,30–50,0.8 · yes,20–30,1.2 · yes,10–20,1.5

Cover loss is a uniform draw inside the range.

#### Formulas and constants (Legacy)

- Dice (`lib/game/core/dice.ex`): `ratio = attack/(attack+defense)` (0.5 if both 0); `min = ratio − 0.20 + 0.01 × min(level, 20)`, `max = ratio + 0.20`, clamped; `< 0.05` crit failure, `< 0.50` failure, `< 0.95` success, else crit success. Level is worth up to +0.20 on the lower bound. `ratio_to_factor(r) = 2 − |r − 0.5| × 2` — infiltration is **slowest at an even matchup** (×2 = 100 ut), ×1 at total dominance or inferiority.
- Constants: `infiltration_time 50`, `cover_threshold 75`, `make_dominion_time 150`, `encourage_hate_time 50`, `character_passive_xp_gain 0.05`, `character_level_wages 8`, `happiness_penalty_reduction_factor 0.01`. Hard-coded: `@initial_cover 80`, `@cover_recovery 0.25` (`spy.ex:6-9`); `@max_remove_contact 25_000` (`stellar_system.ex:11`).
- XP: `10 × xp_factor`; next level `round(10×(L+1) + ((L+1)/2)^2.5) − current`; level-up adds protection/determination and 1 skill point (main spec weight 8, second 5, others 1; skill cap 12).
- Coefficient sources (`content/character.ex`): Erased skills `informer` +20 infiltrate, `assassin` +18, `saboteur` +18, `counter_spy` +10 `sys_ci`, `cleaner` +10 `sys_remove_contact`, `mafioso` +5 % `sys_credit`. Siderian: `proselyte` +10 make_dominion, `agitator` +14 encourage_hate, `seducer` +13 conversion, `leader` +6 `sys_happiness`, `scholar` +5 % `sys_technology`, `philosopher` → ideology (unverified). Stat growth: Erased protection +10/max 350, determination +11/max 425; Siderian 14/250 and 17/275.

#### Mechanics

- **Cover and discovery**: `undercover? = cover >= 75`. Crossing the threshold clears the whole action queue (`character.ex:569-582`), pushes the character to the system (visible), notifies the owner (`:foreign_spy_discovered`). While discovered, all three coefficients go to **zero** (`spy.ex:85-102`); cannot `jump` (`jump.ex:17`) or `gateway_charge`; queue re-cleared each tick (`character.ex:652-668`). Recovery only with an empty queue.
- **Visibility**: undercover Erased are stripped from the enemy system view (`faction/stellar_system.ex:124-135`, `player/stellar_system.ex:63-84`); `cover` is faction-private (tier 6). Attack notifications to the victim use tier 1 (type + level only) if the spy stayed hidden.
- **Malware / informers**: infiltration adds `:informer` parts to the faction's `VisibilityValue` for that system (`faction.ex:143-155`), +1 visibility each. UI label: "Malware" (`resource-detail.type.informer`).
- **Cybersecurity**: system `remove_contact` accumulator seeded 0–25 000, accrues at the summed rate per ut; on crossing 25 000 it resets and one random enemy malware is removed (`stellar_system.ex:896-909`, `victory/agent.ex:54-72`). The displayed number is the *rate*.
- **Intelligence** (`sys_ci`): defense for infiltration; **added to a defending agent's protection when its faction owns the system**. Sources: buildings, faction Cyber Command (+150/+150), the Erased `counter_spy` spec. Cyber Command also publishes a noisy per-sector malware census every 120 ut (`government.ex:2158-2205`).
- **Happiness penalties** stack (one entry per hit), decay `0.01 × elapsed` per ut; a 15-point Destabilization lasts ~1 500 ut.
- **Agent limits**: `max_spies` / `max_speakers` start at **0** (`player.ex:160-162`); only lexes fill them (root lex +2/+2; up to +7 Erased / +6 Siderian). Enforced at hire/activation (`player.ex:1247-1249`). The client also blocks a Seduction that would exceed the attacker's cap for the target's type (`actionValidation.js:338-351`).

#### UX surfaces, icons, locale keys

- `galaxy/selection/Speaker.vue` (coefs + cooldown), `selection/Spy.vue` (coefs + cover gauge with `cover_threshold` cursor), `overlay/opened-character.vue:43-48`, `card/CharacterCard.vue:277,339-340`, `galaxy/system/Actions.vue:268-372`, `ActionsLegacy.vue`, `MapActionRadial.vue:71-79`, `actionValidation.js:152-360` (gating + attack/defense overview), `system/Details.vue:197-244`, `system/Properties.vue:326-340` (malware/explorer breakdown), `box-notification/{Assassination,Conversion,EncourageHate,Infiltration,MakeDominion,Sabotage}Notif.vue`.
- Icons: `action/{conversion,encourage_hate,make_dominion,assassination,sabotage,infiltrate}{,_alt}`, `agent/{speaker,spy,discovered,undercover,protection,determination}`, `resource/{counter_intelligence,remove_contact}`.
- Locale: `data.character.speaker|spy.*`, `data.character_action_status.*`, bonus pipeline names; `galaxy.system.actions.*` + `fail_hint_*`; `galaxy.selection.view.{speaker_*, spy_*, undercover, discovered, cover_*}`; `card.character.{spy,speaker}_limit_reached`; `notification.box.*`, `notification.box.cover_lost`, `unknown_spy`; `notification.text.foreign_spy_discovered` etc.; `resource-description.{counter_intelligence,remove_contact}`; `resource-detail.happiness_penalties.encourage_hate`; `resource-detail.misc.discovered`; `resource-detail.type.informer`.

#### Cross-links

- Stability: Destabilize and Control read `happiness` as defense; Destabilize writes a decaying penalty. Siderian `leader` spec adds `sys_happiness` while governing.
- Dominions: Control consumes a `max_dominions` slot; marks/unmarks the victim's dominion "under attack" (`make_dominion.ex:59-61,130-132`).
- Buildings supply `sys_ci` / `sys_remove_contact`; faction Cyber Command adds the census.
- Ships: Sabotage destroys real hulls with splash (`army.ex:137-170`).
- Navarchs: only legal Sabotage target; also targetable by Seduce and Delete.
- Diplomacy/news kinds `:removal`, `:agent_removal`, `:destabilize`, `:sabotage`; `agent.assassinated`, `agent.converted`, `dominion.taken`.
- Economy: wages 8/level; hire ranges Erased 1200–2100 cr + 100–250 ideology, Siderian 100–250 tech + 200–350 ideology.

#### Gaps / ambiguities

1. **Likely bug** `actions/jump.ex:135` passes the whole `%Spy{}` struct to `Spy.undercover?/2` (map ≥ integer is always true), so every Erased suppresses the `foreign_agent_stopped/passed` arrival notification.
2. No server-side agent-cap check on Seduce; only the client checks.
3. Infiltration duration curve is non-monotonic; intent unknown.
4. `remove_contact` threshold undocumented; no progress indicator.
5. Cover regen blocked by a queued-but-not-started action; only `cover_locked` hints at it.
6. `philosopher` spec target inferred as `sys_ideology`, unverified.
7. Erased have no cooldown; asymmetry with Siderians may or may not be intended.
8. `spy_cover` modifies regen *rate*, not the pool; no UI explains the 0.25/ut baseline.
9. A normal-failure Destabilize still inflicts 5 stability; not documented anywhere.

---

### A.7 Agents in general, agent market, player economy

#### Mechanics

| UI name | Internal key | Location |
|---|---|---|
| Agent struct | `Instance.Character.Character` | `character.ex:23-70` |
| Status lifecycle | `:for_hire → :in_deck → :governor | :on_board → :dead` | `character.ex:25` |
| Types | `:admiral / :speaker / :spy` | `content/character.ex:5,54,98` |
| Ranks (3) | `:common / :remarkable / :exceptional` | `content/character-rank.ex` |
| Generation (name, culture, portrait, age, spec) | `Character.new/6` | `character.ex:76-155` |
| Specializations (6 per type) + secondary | `specialization`, `second_specialization` | `character.ex:80-93` |
| Skill points and roll (weights 8/5/1, cap 12) | `add_skill_point/2` | `character.ex:14,920-970,1079-1091` |
| Level-up (+protection/determination, +1 skill pt) | `level_up/1` | `character.ex:898-918` |
| XP curve | `get_next_level_experience/1` | `character.ex:894-896` |
| Passive XP (governors only) | `character_passive_xp_gain` | `character.ex:1025-1037, 600-609` |
| Salaries | `character_level_wages` → `player_credit` | `player.ex:1199-1209` |
| Fleet maintenance (separate debit) | `army_maintenance` | `player.ex:1211-1225` |
| Bankruptcy / on strike | `is_bankrupt`, `on_strike` | `player.ex:1253-1271`; `character.ex:327-339` |
| Agent limits | `player_admiral / player_spy / player_speaker` | `bonus-pipeline-out.ex:106-123`; `player.ex:1243-1251` |
| Agent market | `Instance.CharacterMarket.CharacterMarket` | `character_market/character_market.ex` |
| Market refill | `fill_empty_slots/1`, `market_cooldown_duration` | `:57-75, 99-113` |
| Atomic hire | `{:sell_if_affordable, …}` | `character_market/agent.ex:53-85` |
| Deck | `character_deck`, `max_character_in_deck` | `player.ex:572-606` |
| Deploy / recall + cooldown | `activate_character/4`, `deactivate_character/2`, `character_deck_cooldown` | `player.ex:633-705` |
| Dismiss (permanent) | `dismiss_character/2` | `player.ex:608-620` |
| Player resources | `player_credit / player_technology / player_ideology` | `player.ex:62-64` |
| Income aggregation | `extract_bonus/2` + `compute_bonus/1` | `player.ex:1001-1241, 944-967` |
| Score | `get_stats/1` | `player.ex:786-834` |
| Inactivity | `@delay_before_inactivity 1920` | `player.ex:12,918-929` |
| Player→player market | `Instance.Player.Market`, `market_taxe` | `player/market.ex` |
| Faction gift market | `Instance.Faction.Market` | `faction/market.ex` |
| Empire panel | tabs | `EmpirePanel.vue:52-57` |
| Financials + calculator | `calc/` engine | `calc/engine.js`, `env.js`, `store.js`; `empire/Financials.vue` |
| QuickCalc (hotkey X) | `toggleCalc` | `Game.vue:23,277`; `calc/QuickCalc.vue` |

#### Ranks (`content/character-rank.ex`)

| Rank (UI) | key | slots/type | init XP | init protection | init determination | init skill pts | cost_factor | nth_factor |
|---|---|---|---|---|---|---|---|---|
| Common ★ | `:common` | 2 | 11–23 | 0 | 0 | 0 | ×2 | +1 %/turn |
| Outstanding ★★ | `:remarkable` | 3 | 76–118 | 0–10 | 0–10 | 0–2 | ×21 | +5 %/turn |
| Exceptional ★★★ | `:exceptional` | 3 | 160–250 | 5–20 | 5–20 | 2–6 | ×36 | +25 %/turn |

Effective starting level: Common 1–2, Outstanding 5–8, Exceptional 10–13. Faction starting agent is forced `:common` with 15 XP (`character.ex:105-108,157-168`).

#### XP thresholds (cumulative)

`T(L) = round(10·L + (L/2)^2.5)` = total lifetime XP to be level L (`character.ex:894-896`; XP never resets on level-up). Mirrored client-side at `CharacterCard.vue:350`.

| Level | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10 | 11 | 12 | 13 | 14 | 15 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Cumulative | 10 | 21 | 33 | 46 | 60 | 76 | 93 | 112 | 133 | 156 | 181 | 208 | 238 | 270 | 304 |
| Increment | 10 | 11 | 12 | 13 | 14 | 16 | 17 | 19 | 21 | 23 | 25 | 27 | 30 | 32 | 34 |

No character level cap; skill cap 12 per skill.

#### Market rules

| Rule | Value | Source |
|---|---|---|
| Slot grid | 3 types × (2 common + 3 outstanding + 3 exceptional) = 24 slots | `character_market.ex:21-30` |
| Refill cooldown | `market_cooldown_duration` = 200 ut (10 h Legacy) | `constant-slow.ex:30` |
| Turnover | on expiry the unsold agent is discarded, `nth` +1, new agent rolled, cooldown reset | `:99-113` |
| On sale | slot refilled immediately (fresh 200 ut) | `:77-92` |
| Deck cap | `max_character_in_deck` = 15 | `constant-slow.ex:35` |
| Recall cooldown | `character_deck_cooldown` = 40 ut (2 h) | `constant-slow.ex:36`; `player.ex:697-699` |
| Blockers on hire | bankrupt, insufficient credit/tech/ideology, deck full | `player.ex:572-588` |
| Blockers on deploy | deck cooldown, `on_sold`, siege, no free type slot, one governor per system | `player.ex:636-651` |

#### Formulas (Legacy)

- Hire price (`character.ex:113-117`): `nth_factor = 1 + nth × rank.nth_factor`; each of credit/tech/ideology = `trunc(rand(type_range) × rank.cost_factor × nth_factor)`. Base ranges: Navarch 600–1500 cr / 200–350 tech; Erased 1200–2100 cr / 100–250 ideo; Siderian 100–250 tech / 200–350 ideo. Prices creep up with slot rotation (+25 %/rotation for Exceptional).
- Salary: `−8 × level` credits/ut, only for deployed agents and governors; deck cards are free.
- Fleet maintenance: separate `:direct_last` debit for on-board Navarchs.
- Passive XP: +0.05/ut base, only converted for `:governor`. `Mutators.xp_multiplier/2` scales both.
- Income aggregation order (`player.ex:1227-1240`, `Core.Bonus.prepare/1`): (1) additive `:direct` order 8 — initial values, own systems, dominions × `dominion_rate`, lexes, traditions, government patents/laws, Cardan tithe, mutators; (2) multiplicative order 69 — faction income tax `×(1 − rate/100)`, tyranny `×(1 − malus/100)`; (3) `:direct_last` order 78 — salaries, then fleet maintenance. Net lands in `credit.change`.
- Bankruptcy = `credit.value ≤ 0 and credit.change < 0` (`player.ex:1254`): every agent `on_strike`, non-armada Navarchs forced to Deserter.
- Faction tax remittance (`player.ex:979-998`): withheld per ut = `net × rate / (100 − rate)`, flushed every 5 ut.
- Player→player market fee (`player/market.ex:151`): `final_price = offer.price + 0.1 × offer.value`; `value` = technology/ideology `amount × 10`; deck agent `level × 50 000`; on-board agent `level × 50 000 + maintenance × 250`. Tradables: technology, ideology, deck agents, deployed agents. Bans: own offer, war embargo, receiver over cap.
- Faction gift market (`faction/market.ex`): sender pays `amount × (1 + tax/100)`; tax rises `amount/2500` (credit) or `amount/200` (tech/ideo), cap 60 %, decays 0.4/ut to a 5 % floor.
- Score (`player.ex:806-815`): `credit.change + 10·tech.change + 10·ideo.change + 8·Σgovernor levels + 15·Σdeployed levels + 1.1·Σmaintenance + credit/100000 + tech/10000 + ideo/10000`.

#### UX surfaces, icons, locale keys

| Surface | File | Locale |
|---|---|---|
| Agent market mini-panel | `mini-panel/CharacterMarketMiniPanel.vue` | `minipanel.character_market.*`, `data.character_rank.*` |
| Agent card | `card/CharacterCard.vue` (`resource/*`, `agent/protection`, `agent/determination`) | `card.character.*` incl. `*_limit_reached` |
| Deck mini-panel | `mini-panel/CharacterDeckMiniPanel.vue` | `minipanel.character_deck.*`, `navbar.bottombar.*` |
| Resource market | `mini-panel/MarketMiniPanel.vue`, `market/MarketOffer.vue`, `MarketSell.vue` | `minipanel.market.*` |
| Faction gift market | `panel/faction/*` | `panel.faction.market*` |
| Empire panel | `panel/EmpirePanel.vue` + `empire/{Overall,Possessions,GalacticSurvey,Financials,Mutators,Cheats}.vue` | `panel.empire.*` |
| Calculator | `empire/Financials.vue`, `calc/*` | `calc.*` |
| Income tooltips | `generic/ResourceDetail.vue` | `resource-detail.type.{character_wages,fleet_maintenance,…}`, `resource-detail.government.*` |
| Bankruptcy banner | `navbar/Topbar.vue:59-63` | `navbar.topbar.bankrupt*` |

#### Cross-links

- Agent limits ← lexes: base 0; root lex +2 each; branches up to +7.
- Salaries ← levels ← XP ← actions (`Character.add_experience/2` from every action module).
- Governors ← passive XP (system-parked agents are the XP farm).
- Skills → bonuses routed by `BonusPipelineOut.to` (`character.ex:1021-1067`).
- Market ↔ economy: `buy_offer` debits via `Player.add_credit/2`; a listed deck card is `on_sold` and cannot be deployed or recalled.
- Calculator ↔ income: `calc/env.js:17-40` extrapolates from `{value, change}`, `perHour = 20 × speedFactor`; mirrors the lex-slot cost formula.
- Government ↔ income: tax, tithe, tyranny entries in the same pipeline (`player.ex:1096-1185`).

#### Gaps / ambiguities

1. `character_base_action_xp` (10) is used only by colonization; every other action computes XP locally.
2. `market_taxe` has a second consumer at `government.ex:2550`, purpose not inspected.
3. Two things are both called "market" (player offer board vs faction gifting). The manual must name them distinctly.
4. Recall cooldown never resets to `nil` (cosmetic).
5. `forb_specializations` always `[]`; portrait filter is type+rank only.
6. Culture not inherited from faction for market agents (TODO `character.ex:100`).
7. `:dead` status declared but assassination just drops the agent; unknown if persisted.
8. XP curve duplicated server/client; server is canonical.
9. Deck cap not checked on market transfer of a board character (by design).
10. `:remarkable` renders as "Outstanding" in EN; use UI strings.

---

### A.8 Factions, victory, galaxy map, game modes (government and diplomacy excluded)

#### Factions

| Faction | key | colour | Early | Mid | Late | Malus |
|---|---|---|---|---|---|---|
| Tetrarchy | `tetrarchy` | `#3f66df` | +3 technology | +25 % frigate level | −10 % army maintenance | −5 % ideology |
| Myrmezir | `myrmezir` | `#bc2433` | +2 ideology | +20 % make-dominion | +0.1 dominion rate | −5 stability |
| Cardan | `cardan` | `#8e60bf` | +20 counter-intel | +15 % assassination | +15 % infiltration | −5 % technology |
| Synelectic Federation | `synelle` | `#a2cd44` | +30 production | +10 % defense | +20 % army repair | −5 % credit |
| A.R.K. | `ark` | `#c9a115` | +50 credit | +10 stability | +15 % mobility | +5 % army maintenance |

**Five playable factions** (`lib/data/game/content/faction.ex:4-143`); `data.faction.neutral` is a locale-only sixth entry with no icon. Each faction has a starting agent archetype (`initial_character_type/spec1/spec2/skills`, `faction.ex:7-10`), theme colour, and faction chat (ring buffer 80 msgs, 1000 chars, `faction.ex:20,226-249`).

**Faction government** [EXCLUDED: beta] (`government.ex`, Legacy-only, beta opt-in at creation, default OFF; `docs/faction-government.md` §5.0 = shipped slice, §5.1–5.6 = design): seats `:leader :economy :military` (`:653-668`); income tax per resource capped at `government_tax_cap = 10` % (`:1445-1471`); treasury deposit/withdraw/grant (`:2680, :2515, :2539`); Cardan tithe (`:605-624, :2394-2406`); Tetrarch tyranny/overreach (`:627-720`, malus 24 h, total clamped 100 %). Durations (Legacy ut → wall): founding 1440 (72 h), election 960 (48 h), min election 480, approval/tyranny window 480, law cooldown 480, Myrmezir term 3360 (7 d), Synelle term 5280 (11 d), lockout 1440, Cardan quorum 5 %, max 5 rounds, max 2 laws (`constant-slow.ex:59-74`). Faction ranking: `points, best_prod, best_credit, best_technology, best_ideology, best_workforce` (`RankingPanel.vue:34,45-52`).

#### Victory

- Victory agent ticks every 10 ut (`victory.ex:7,129`); broadcasts every 20 ut; post-victory grace `@final_unit_days 200` (Legacy 10 h, Flash 5 min); game closes when winner set **and** timer ≤ 0 **and** nobody connected (`:281-285`).
- Win target `win_points_target` (default 14, ceiling 30; `:35,181`; scenario override `manager.ex:524`). Types `"victory_track"`, `"win_on_time"`. `time_only` (daily) disables the points win.
- Three tracks × 4 tiers, stars per tier `[0, 2, 5, 10]` (`:386`), max 30:

| Track | Points counted | Tier coefficients | Top-tier cap |
|---|---|---|---|
| Conquest | Σ `victory_points` of owned sectors | `[0,.25,.6,.95] × total_sector_points × 2 / faction_count × w` | `max(min(floor(0.95·total), total−1), 1)` |
| Population | Σ `PopulationClass.points` of owned systems | `[0,.15,.3,.6] × inhabitable_systems × 16 × w`, also `≤ 400·coeff·player_count + k` | per-player cap |
| Visibility | Σ intel on enemy systems (≤5 each) | `[0,.3,.6,.95] × enemy_possessions × 5 × 2 / faction_count × w` | `floor(0.95 × max)` |

- Faction weighting `w = clamp(sqrt(player_count / (total_players / faction_count)), 0.5, 1.5)` (`:326-332`).
- Tie-break (equal VP): `possession/inhabitable + min(pop/(possession×160),1) + visibility/(enemy×5)`, range 0..3 (`:246-280`).
- Sector control: strict plurality of colonised systems in the sector; ties keep incumbent; starter sectors ignore neutral until first flip (`galaxy/sector.ex:51-95`). Sector re-evaluation every 20 ut (`galaxy.ex:11,260`). Sector `victory_points` → `Victory.Sector.value`.
- `conquest_thresholds` scenario override (`:44,353-357`). The Legacy `victory_points` game_data field is **dead** (`:30-36`).
- Daily objectives (19, `lib/daily/objective.ex:36-253`) are daily-challenge only, not multiplayer victory.

#### Diplomacy [EXCLUDED: unfinished] (`diplomacy/diplomacy.ex`)

- Stances `:cold_war` (default), `:war`, `:non_aggression` (`:16-35,159-160`); 2-faction games start at war (`:109-112`). `declare_war/3` unilateral; `propose/4` kinds `:non_aggression, :peace`, accept/reject; `break_pact/3`.
- Tension ledger: `+10` per successful cold-war aggression (conquest, removal, agent_removal, bombardment), ×0.5 on failure, ×2 under a pact, clamped 0..100; decays 2 per 480 ut (`:46-48,313-334,366-377`).
- War meters `exhaustion 0 / momentum 50 / frenzy 100`, clamp 0..100, `+1 exhaustion / 480 ut` (`:52-66,382`).
- Per-viewer filtering (`public_view/2`). Report hook kinds: conquest, bombardment, pillage, destabilize, removal, agent_removal, sabotage, fleet_destroyed (`:418-435`).
- **Alliances do not exist.** "Unallied" for interception = different faction. Pacts do not exempt fleets.

#### Galaxy map

- Sector struct (polygon, centroid, adjacency, owner, VP; `galaxy/sector.ex:9-20`); `starter?` rule; takeability = own sector or adjacent (`galaxy.ex:108-122`).
- Blackholes veto hyperlane edges (`spatial_graph.ex:35-60,153`); `check_jump/3` accepts existing edges only.
- System statuses `:uninhabitable :uninhabited :inhabited_neutral :inhabited_dominion :inhabited_player`; six star types (`stellar-system.ex:5-38`).
- Visibility 0–5 (`Core.VisibilityValue`); radar via `faction.ex:47-49,261-340`.
- Map modes `population, visibility, radar` + `character-label`, `system-icons`, `ruler` (`galaxy/Map.vue:85-90`).
- Player markers `SystemIcon` kinds attack/danger/flag/path/question/shield/target (`system_icon.ex:17-24`) — only 4 SVGs exist (`attack, flag, path, question`).
- Galactic Survey (30 s ± 5 s cache, visibility-gated rows; `galactic_survey.ex`); UI `empire/GalacticSurvey.vue`.
- Legend (`help/Legend.vue`) already covers: system chips (Empty, Neutral*, Opposing*, Yours), agent chips (own three types, Detected blip), three map modes, three notes. `inhabited_dominion` has no own legend row.
- Hotkeys (`help/Hotkeys.vue:28-49`): F search · X calculator · O faction · S empire · A operations · R ranking · V victory · P patents · L lexes · M agent market · H help · C copy · Z ruler · Esc · Home · `.` `,` Space · 1-9 / Ctrl+1-9.

#### Game modes and time

| UI | key | factor | 1 ut | Default time limit (min) / range | Locale duration |
|---|---|---|---|---|---|
| Flash | `fast` | 120 | 1.5 s | 120 / 60–180 | "1-2 hours" |
| Tactic | `medium` | 20 | 9 s | 600 / 300–720 | "4-5 days" (mismatch) |
| Legacy | `slow` | 1 | 3 min | 43 200 / 10 080–129 600 | "1 month" |
| daily (hidden) | `daily` | 240 | 0.75 s | ~30 min | — |

- `elapsed_ut = wall_ms × factor / 180 000` (`tick.ex:7,57,73-75`); `SPEEDUP` env for dev.
- Calendar `:tetrarch`, `ut_to_day_factor 1.0`, 20 days/month, 24 months/year → 480 ut = 1 year = 24 wall-hours on Legacy (the unit diplomacy and government use).
- Match length `ut_time_left = minutes × 60 000 × factor / 180 000` (`manager.ex:390`); Legacy default 14 400 ut = 30 days.
- Autosave ~15 wall-min, `@max_autosaves 10` (`time.ex:19-30`).
- **Mutators** (56, `mutator.ex:54-700`, tags `polarity, daily_eligible, axis, hook, implemented`): starting resources (`empire_of_wealth`, `frontier_stockpile`, `lean_years`, `old_knowledge`, `faith_reborn`, `teeming_masses`, `pioneer_charter`, `the_bequest_estate`); world-gen (`garden_worlds`, `barren_crucible`, `worlds_of_plenty`, `hardscrabble_worlds`, `gilded_orbitals`, `sprawling_frontier`, `open_frontier`); income boons (`bull_market`, `enlightened_age`, `zealous_fervor`, `industrial_surge`, `prosperous_masses`, `joyful_industry`, `demographic_dividend`, `radiant_court`); income banes (`luddite_backlash`, `crisis_of_faith`, `heavy_tithes`, `failing_reactors`, `hungry_mouths`, `tides_of_industry`); stability/housing (`festival_days`, `sullen_populace`, `cramped_quarters`, `crowded_slums`); military (`veteran_shipwrights`, `subsidized_yards`, `field_docks`, `brittle_hulls`, `cheap_steel`, `hyperlane_mastery`, `porous_borders`); intel (`panopticon`, `blind_watch`, `ghost_protocols`, `silver_tongues`, `doctrine_of_the_masses`); court (`open_court`, `closed_borders`, `prodigies`, `inexperienced_court`, `expansion_charter`); research (`open_science`, `lost_sciences`, `restless_senate`); hazards (`agitators_abroad`, `reavers_come`, `crumbling_ground`). Check the `implemented:` flag before documenting one.
- Forge (`portal/pages/create/Scenario.vue:674-686`), daily challenge (`docs/daily-challenge.md`, 07:00 UTC, 2 boons + 1 bane), tutorial (`galaxy.is_tutorial`, `tutorial.step0..58`).
- **Wave defense is not on this branch** (no `docs/wave-defense.md`, no engine module at 6a61bfb). It exists on a separate branch per project memory; inventory it when it merges.

#### UX surfaces, icons, locale keys

- `panel/FactionPanel.vue` + `faction/{Overall,Player,Government,Treasury,Diplomacy,About}.vue`; `RankingPanel.vue` + `ranking/*`; `mini-panel/VictoryMiniPanel.vue`; `help/{Legend,Hotkeys}.vue`; `galaxy/Map.vue`; `front/src/game/map/*`; `empire/GalacticSurvey.vue`; `create/Scenario.vue`.
- Icons: `faction/{5 keys}{,-small}` (no neutral), `stellar_system/*`, `marker/{attack,flag,path,question}`.
- Locale: `data.faction.*`, `data.victory.{conquest,population,visibility}.{name,description,points}`, `data.speed.*`, `data.stellar_system.*`, `data.population_class.*`, `data.calendar.*`, `data.objective.*`, `data.mutator.*`; `minipanel.victory.*`; `panel.faction.*`; `panel.faction_government.*` (~85 keys); `panel.faction_diplomacy.*`; `panel.ranking.*`; `panel.help.*`; `galaxy.map.*`; `search.*`, `duration.*`, `daily_result.*`.

#### Cross-links

- Sector flip → victory (`galaxy/agent.ex:170-176` → `victory.ex:59-68`); system ownership/population → victory (`:88-120`); faction intel → visibility track (`:122-131`).
- Diplomacy ↔ actions via `Diplomacy.report/5`; diplomacy ↔ stances: pacts do not affect interception.
- Government ↔ player income via `Player.extract_bonus/2`.
- Speed ↔ content: per-speed content modules; `:daily` falls back to `:slow`.
- Daily ↔ victory: `time_only`; mutators ↔ daily generator.
- Blackholes ↔ movement.

#### Gaps / ambiguities

1. Five playable factions, not six.
2. Tactic duration: locale "4-5 days" vs Forge default 10 h; authoritative source unknown.
3. Legacy `victory_points` game_data field is dead; only `win_points_target` matters.
4. `@ut_per_day 480` is one wall-day at Legacy, not one game-day; comment ambiguous.
5. Diplomacy effects text promises visibility −1/+1 (`panel.faction_diplomacy.effects.*`) but no such modifier found in `diplomacy.ex`; verify.
6. Marker icons `danger`, `shield`, `target` missing.
7. Objectives are daily-only.
8. Mutator `implemented: false` entries exist; enumerate before listing.
9. Faction government is Legacy-only and beta-gated; most of the doc is proposal.

---

### A.9 Front-end surfaces and integration facts

`tt=N` = number of `v-tooltip` bindings today.

#### Cards (`front/src/game/components/card/`)

- `BuildingCard.vue` — name/level/quote, workforce, credit + production costs, unlock list, level pips; tt=7. Best `?` anchor in the game.
- `CardComplexBonus.vue` — bonus pipeline in/out names, signed modifiers, literal `?` placeholders at :35/:72; tt=6.
- `CharacterCard.vue` — type/culture/rank, skills + descriptions, determination/protection, upkeep; tt=5.
- `ClosedCharacterCard.vue` — action icon, `agent/discovered`; tt=1.
- `ClosedProductionCard.vue` — queue item, remaining ticks; tt=2.
- `ClosedSystemCard.vue` — system type, siege type; tt=4.
- `DoctrineCard.vue` — name/description/quote, ideology cost; tt=0 (descriptions exist; the *class* concept has no help).
- `FactionTreeCard.vue` — faction patent/lex/building nodes; tt=0. **No affordance.**
- `PatentCard.vue` — name, tech cost, unlock list; tt=1.
- `ProductionQueueCard.vue` — queue order, ETA; tt=0. **No affordance.**
- `ProfileCard.vue` — tt=0. `SectorCard.vue` — sector, owner shares, victory points; tt=0. **No affordance.**
- `ShipCard.vue` — hull, shield, handling, interception, energy/explosive strikes, raid, invasion, repair, costs; tt=10 (richest per-stat tooltip set; the model for stat → topic mapping).
- `TargetSystemCard.vue` — tt=0.

#### Mini-panels

- `CharacterDeckMiniPanel.vue` tt=0 · `CharacterMarketMiniPanel.vue` tt=1 · `DoctrineMiniPanel.vue` tt=1 · `FactionTreeMiniPanel.vue` tt=0 (**none**) · `MarketMiniPanel.vue`/`market/*` tt=0/1/0 · `PatentMiniPanel.vue` tt=0 (**none**) · `VictoryMiniPanel.vue` tt=2, uses `ResourceDetail`.

#### Panels

- Container panels render `.panel-navbar` with one `v-tooltip.right` per tab.
- `empire/Overall.vue` tt=0 · `empire/Possessions.vue` per-system columns tt=0 (**prime `?`-per-column site**) · `empire/GalacticSurvey.vue` tt=13 (densest) · `empire/Financials.vue` tt=0 · `empire/Mutators.vue` tt=0.
- `faction/{Overall,About,Player(2),Treasury(1),Diplomacy(3),Government(1)}.vue` — mostly bare.
- `operation/Agents.vue` tt=0 · `operation/Reports.vue` tt=0 · `operation/report/FightReport.vue` tt=0 — **biggest unexplained-number surface in the game**.
- `ranking/*` tt=0. `help/{Hotkeys,Legend,Stances,Links}.vue` — existing content.

#### Galaxy

- `Map.vue` modes/markers/ruler tt=4 · `MapActionRadial.vue` tt=0 · `selection/Army.vue` fleet grid, stances, coefficients tt=4 + native `:title`, literal `?` at :155 · `selection/Speaker.vue` tt=1 · `selection/Spy.vue` tt=3 · `selection/View.vue` tt=6.
- `system/Details.vue` — **already uses `<span class="info" v-tooltip="$t('resource-description.X')">?</span>` at :12, :62, :197, :223. This is the canonical `?` affordance to generalise.**
- `system/Population.vue`, `Properties.vue`, `ProductionBox.vue` — pass `resource-description.*` into `ResourceDetail`.
- `system/Bodies.vue` tt=2 / `BodiesItem.vue` tt=7 · `system/Actions.vue` tt=2 / `ActionsLegacy.vue` tt=7 · `AgentBadge.vue` tt=5 · `ActionOverview.vue` literal `?` at :43 · `StationBox.vue` tt=5 · `PopulationStatus.vue` tt=1.

#### Other

- `generic/ResourceDetail.vue:2-16` — the reusable `?` component (renders when `description` is passed); 10 call sites.
- `box-notification/*.vue` (13) — all tt=0; render `$tmd('notification.box.<key>')` markdown with icons + numbers. **Zero help affordance.**
- `navbar/Topbar.vue` tt=5; renders `marker/question` at :48 for the mobile Help button. `navbar/Bottombar.vue` tt=7; `resource-description.*` at :165/:183/:201.
- `Settings.vue` — natural place for a "Manual" entry. `Tutorial.vue` tt=3. `Chat.vue` ref chips `[[sys:id|label]]`; `chat/refs/ChatRefUnknown.vue:5` renders a `?` chip. `NotificationCenter.vue` tt=1. `overlay/opened-character.vue` / `opened-player.vue` tt=0.

#### Modal pattern (copy for the help modal)

- `SearchOverlay.vue`: mounted by `Game.vue:69` as a sibling of the panels container. Local `isOpen`; `open/close/toggle` (:95-107). Root bus: `mounted()` :133-136 `this.$root.$on('toggleSearch', …)` / `'closeSearch'`, `$off` in `beforeDestroy`. Markup `.search-overlay-backdrop` (`@click.self="close"`) > `.search-overlay` with `f-${theme}` (theme from `$store.getters['game/theme']`, classes generated in `styles/shared/variables.scss:65`). Keyboard inline on the input (`@keydown.esc.prevent.stop`). Styles `styles/game/components/search.scss` (`main.scss:59`), `z-index: $z-map-overlay` = 550 (panels 500, navbar 600). **Does not touch the store overlay stack** (`game/addOverlay`); only panels and the system view do.
- `QuickCalc.vue`: same bus (`toggleCalc`/`closeCalc` :177-182). Root `class="quick-calc calc-suppress"` + `tabindex="-1"` + `@keydown.esc.stop`. **`calc-suppress` is required for any modal with a text input**: `main.js:45-47` configures `VueShortkey` with `prevent: ['input','textarea','.chat-composer','.calc-suppress','.calc-suppress *']`. Styles are `<style scoped>` in the SFC (:191-244), `position: fixed; top: 64px; z-index: 560`.
- Hotkeys use **`v-shortkey`** (vue-shortkey 3.1.7), not v-hotkey: `Game.vue:5-43` map → `onShortkey` (:217). `help: ['h']` (:21) → `togglePanel('help')` (:268-270). New key = one map entry + one branch.
- Mobile: `mobile.scss` imported last, rules scoped `body.is-mobile-ui &`; gated by `utils/viewport.js` (`max-width: 768px` **and** the `mobile_ui` beta flag). `search.scss` has no mobile block.

#### Panel pattern

- `HelpPanel.vue` (55 lines): register a sub-panel by adding to `data().panels` (:34), importing + `components` (:24-27, :48-53), one `v-show` line (:16-19). Tab label = `panel.help.<subpanel>`; content `<h1>` = `panel.help.<subpanel>_title`.
- **Panel-navbar buttons have no per-tab icons**: every button is an 80×80 cell with a grey square (`panels/main.scss:41-80`); mobile 56×56. Icons would be new CSS.
- Registered in `Game.vue:182-206` as `{ name: 'help', side: 'left' }`; `open(data)` called at `Game.vue:360` — `HelpPanel.open()` is a no-op, so `if (data && data.topic) this.activePanel = …` is the one-line deep-link hook (precedent `EmpirePanel.vue:67-71`).
- Content shell: `<div class="panel-content is-small"><v-scrollbar class="has-padding">`. Widths `is-small` 600 / `is-medium` 900 / `is-large` 1200 (`panels/main.scss:86-88`). A manual wants `is-medium`.
- v-scrollbar: never inline `:settings` literals; use `VERTICAL_SCROLL_SETTINGS` from `utils/scrollbar.js`, or pass none.
- Legend/Stances/Hotkeys/Links are stateless (no store reads) but depend on `panels/help.scss` (419 lines, `.game-context` only).

#### I18n

- `plugins/i18n.js`: `en` bundles statically imported and **merged into one flat namespace** (`Object.assign(portal, game, data, errors)`); other locales lazy-load. `availableLanguages = ['fr','en','de']`, fallback `en`.
- `$tmd` = `renderMd(this.$t(...))` → `utils/markdown.js` → `marked(escape(md))` (marked ^2.0.1): HTML-escaped **first**, then markdown; no sanitizer after marked; consumed with `v-html`.
- `resource-description.*` has 12 entries — the natural seed for the topic id space.
- **`data.json` is hand-maintained.** `mix update_data` writes Elixir content from Google Sheets CSVs, never the locales. Only the wiki-table mix tasks read the locale JSON.
- **No locale text is served at runtime**; `data_controller.ex` returns numeric balance data only. A help corpus must ship in the bundle or come from a new endpoint.
- No lint enforces key parity across en/fr/de; a new corpus silently falls back to English.

#### Icons

- Registered by `front/src/icons/index.js` (46 `require` lines, one per file/dir). `Vue.use(VueSvgIcon, { tagName: 'svgicon' })` (`main.js:51`). Namespaces: action, agent, building, doctrine, faction, marker, patent, reaction, resource, ship, stellar_body, stellar_system + ~30 flat utility icons.
- Regen script `front/package.json:12` `vsvg -s ./../../svg-icons/` — **the source SVG directory is outside the repo and absent**. The generated modules are the only source of truth.
- Each module is `icon.register({ 'resource/credit': { width, height, viewBox, data: '<path …/>' } })` — raw SVG markup, so a build step can emit a sprite or inline `<svg>` by requiring those modules. No standalone `.svg` files exist for these icons. The Phoenix site uses FontAwesome.

#### Public site

- Public routes `router.ex:104-118` (`scope "/"`, pipeline `[:auth, :browser, :browser_public]`): `/`, `/about`, `/patch-notes`, `/cgu`, `/login`, `/signup`, … Adding `live("/help", HelpLive)` / `live("/help/:topic", …)` is a two-line change. Root layout `templates/public_layout/root.html.leex` with hard-coded nav links (:26-28).
- LiveViews are thin; `patch_notes_live.html.leex` is hand-written HTML. `about_live.ex` toggles EN/FR by duplicated markup — the only public-page i18n mechanism.
- Blog subsystem exists (`lib/rc/blogs/*`, admin LiveViews) but its public routes are commented `# TODO: unused routes`.
- **Server-side markdown exists**: `lib/rc/markdown.ex:18-23` — `Earmark.as_html! |> HtmlSanitizeEx.markdown_html |> strip_protocol_relative`.
- **Styling is not shared**: Phoenix pages use `assets/css/app.scss` (webpack); the SPA uses `front/src/styles/main.scss` under `.portal-context`/`.game-context`. Two variable sets, two fonts. A public manual either gets `assets/css/views/_help.scss` (aligned with `pk-content`) or lives as an SPA route.

#### Deep links

- Router `mode: IS_STEAM ? 'hash' : 'history'`, base `/portal/`. Deep-link stash (`router.js:9-21`, `sessionStorage 'rc-deep-link'`) replayed in `App.vue:56-65` for signed-in users. A `/help/*` SPA route must be **unguarded**.
- `$route.query` is read in exactly one place (`profile/Detail.vue:564-566`); no `?help=` or hash handling exists. `/game` takes no params; instance id comes from cookies (`store.js:5,31-40`). **`/game?help=<slug>` is safe to add**: `Game.vue mounted()` (:441) reads it and emits.
- Precedents: QuickCalc expand → `EmpirePanel.open({ tab: 'financials' })`; FightNotif → `Reports.vue:191`; chat refs `[[sys:123|Label]]` (`chat/parseChatMessage.js:26-31`, `chat/refNavigation.js:15-23` with a `// Phase 2` extension point). **Adding a `help` ref kind lets players link manual topics in chat.**

#### Build

- `build-front.sh`: `phoenix()` builds `assets/`, `mix phx.digest`, moves `priv/static` → `$HOME/www-root/asylamba/static`; `vue()` builds `front/dist` → `…/front`. `priv/static` does not exist in the tree.
- nginx (`deploy/nginx/rc.conf.example`): `/portal/` → SPA with `try_files … /portal/index.html`; `/api/`, `/socket/`, `/live/` and everything else → Phoenix.
- Static HTML at build time is feasible (emit into `assets/static/help/` before digest) but has no precedent; a LiveView/controller route is simpler and gives no-JS HTML anyway.

---


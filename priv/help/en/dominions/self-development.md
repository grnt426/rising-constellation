---
title: Self-development
guide: dominions
aliases: [autonomous-development]
terms: [self-development, autonomous development, development specialty]
related: [dominions, star-systems, production, siege, housing, workforce, stability, stellar-bodies]
sources:
  - config/config.exs:161-163
  - lib/game/instance/stellar_system/stellar_system.ex:10
  - lib/game/instance/stellar_system/stellar_system.ex:34
  - lib/game/instance/stellar_system/stellar_system.ex:152-154
  - lib/game/instance/stellar_system/stellar_system.ex:160-161
  - lib/game/instance/stellar_system/stellar_system.ex:186-188
  - lib/game/instance/stellar_system/stellar_system.ex:275-278
  - lib/game/instance/stellar_system/stellar_system.ex:371-392
  - lib/game/instance/stellar_system/stellar_system.ex:926-944
  - lib/game/instance/stellar_system/stellar_system.ex:1821-1831
  - lib/game/instance/rand/agent.ex:10-13
  - priv/data/system_ai/behavior_tree.json:61-72
  - priv/data/system_ai/behavior_tree.json:247
  - priv/data/system_ai/behavior_tree.json:289
  - priv/data/system_ai/behavior_tree.json:379-434
  - priv/data/system_ai/behavior_tree.json:486-590
  - priv/data/system_ai/behavior_tree.json:634-645
  - priv/data/system_ai/behavior_tree.json:689-726
  - priv/data/system_ai/behavior_tree.json:770-807
  - priv/data/system_ai/behavior_tree.json:897-978
  - priv/data/system_ai/behavior_tree.json:1022-1097
  - priv/data/system_ai/behavior_tree.json:1141-1178
  - lib/game/system_ai/actions.ex:50-72
  - lib/game/system_ai/actions.ex:112-141
  - lib/game/system_ai/actions.ex:146-206
  - lib/game/system_ai/actions.ex:223-311
  - lib/game/system_ai/actions.ex:316-348
  - lib/game/system_ai/buildings_helper.ex:6-24
  - lib/game/system_ai/helper.ex:4-6
  - lib/game/system_ai/helper.ex:8-14
  - lib/game/system_ai/helper.ex:23-69
  - lib/game/system_ai/helper.ex:75-156
  - lib/game/system_ai/helper.ex:248-276
  - lib/game/system_ai/helper.ex:304-346
  - lib/game/system_ai/helper.ex:363-389
  - lib/game/system_ai/helper.ex:432-440
length: long
length_reason: the six build priorities must name both main planets and that upgrades can land anywhere in the system, which runs about 10 words over
status: reviewed

---
[[autonomous-system|Autonomous systems]] and [[dominions]] build by themselves.

{shot:autonomous-state#status|The highlighted status says this autonomous system develops itself.}

Each makes at most one building decision every {duration:50}. Its first decision comes at a random time within that span.

It does the first of these that fits:

1. If its [[production|build queue]] is busy, it waits.
2. It repairs a [[siege|damaged building]].
3. It builds a few starter buildings on its main habitable and barren planets.
4. With 3 or fewer free [[workforce]], it builds [[stellar-bodies|infrastructure]] on a planet that has none.
5. With 10 or less [[stability]], it builds infrastructure or a stability building.
6. It builds a random building on a random planet, moon or asteroid, or upgrades one somewhere in the system.

Known issue: when free workforce runs low, it should also build [[housing]], but never does.

Each system has a hidden development specialty, picked at random. It makes one kind of building more likely in step 6 above. See Advanced mechanics below.

- When it lacks the free workforce for the building it picked, it builds nothing that cycle.
- It never upgrades infrastructure.
- It never builds a {name:building.monument_dome} or {name:building.high_factory_dome}.
- A fully built system only repairs.

{advanced}
## Development specialties

When the galaxy is created, every system gets one of five specialties. Each is equally likely. A system keeps its specialty for good, even when it changes owner or is abandoned. The game never shows it.

A specialty favours buildings that make its output. A building that makes two outputs counts for both.

| Specialty | Favours buildings that make |
| --- | --- |
| Production | [[production]] |
| Credit | [[credit|credits]] |
| Technology | [[technology]] |
| Ideology | [[ideology]] |
| Defense | [[defense]] |

## How it picks a building

In step 6, it goes through these in order:

1. It picks a random planet, moon or asteroid with a free tile.
2. A barren planet first gets its infrastructure, then a {name:building.hab_dome} building.
3. A habitable planet first runs the starter check below.
4. It rolls a kind of building. Its specialty's kind has 1 chance in 2. Each other kind has 1 chance in 8.
5. A kind with nothing that fits on that body is left out, and the other kinds split its chance in proportion to their own. If no kind has anything that fits, nothing is built that cycle.
6. Once the system has 10 finished buildings, it tries an upgrade first half the time. It picks a random finished, undamaged building of the rolled kind anywhere in the system, below its top level.
7. Otherwise, it builds a random building of the rolled kind that fits the body, on a random free tile. On a habitable planet without infrastructure, this fails and nothing is built that cycle.

For example, in Legacy, no production building fits a habitable planet once the system has 18 finished buildings. A production specialty then rolls each other kind 1 chance in 4.

In Legacy, no ideology building fits a moon or an asteroid. With 0 to 7 finished buildings, a production specialty rolls production there 4 chances in 7. Each other kind gets 1 chance in 7.

How many buildings of each kind the system already has does not change the roll.

A building that allows one per planet or one per system is skipped when one is already there.

Upgrades do not need free workforce. If nothing of the rolled kind can be upgraded, it builds instead. On a planet, a building cannot rise above its infrastructure's level. An upgrade that would do so fails, and nothing is built that cycle. It never upgrades infrastructure. So its upgrades only succeed on moons and asteroids, unless a planet's infrastructure was already raised.

A random or stability building it picks must need a workforce in this range. The range depends on how many finished buildings the system has, infrastructure included:

| Finished buildings in the system | Workforce of the building it picks |
| --- | --- |
| 0 to 7 | 0 to 2 |
| 8 to 17 | 2 to 4 |
| 18 or more | 3 to 6 |

## Starter buildings

A main planet needs infrastructure and more than 4 free tiles. It must also be the only habitable planet with infrastructure and a free tile. Otherwise, the system has no main planet. The main planet gets two {name:building.hab_open_poor}, then one {name:building.university_open}.

Once it has them, the same check runs on barren planets. The main barren planet is picked the same way among barren planets. It gets two {name:building.hab_dome}, then one {name:building.mine_dome}.

When step 6 picks a habitable planet, the starter check runs again. If the system has no main habitable planet, the barren starter check also runs. Either way, starter buildings always go to the main planets, whichever planet step 6 picked.

## Low workforce and low stability

In step 4, it picks a random planet without infrastructure and builds it there. Step 5 does the same. When every planet has infrastructure, step 5 builds a stability building instead. It picks one the body does not have yet, from the workforce range above. When a step finds nothing to build, it moves on to the next step.

Known issue: the decision tree also has a step that waits for population to grow into free housing, but it never triggers. It needs population to grow faster than it ever can.
{/advanced}

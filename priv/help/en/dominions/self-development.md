---
title: Self-development
guide: dominions
aliases: [autonomous-development]
terms: [self-development, autonomous development]
related: [dominions, star-systems, production, siege, housing, workforce, stability, stellar-bodies]
sources:
  - lib/game/instance/stellar_system/stellar_system.ex:10
  - lib/game/instance/stellar_system/stellar_system.ex:152-154
  - lib/game/instance/stellar_system/stellar_system.ex:912-931
  - lib/game/instance/stellar_system/stellar_system.ex:1807-1817
  - lib/game/instance/stellar_system/stellar_system.ex:333-377
  - lib/game/instance/stellar_system/stellar_system.ex:494-498
  - priv/data/system_ai/behavior_tree.json:246-258
  - priv/data/system_ai/behavior_tree.json:266-296
  - priv/data/system_ai/behavior_tree.json:401-434
  - priv/data/system_ai/behavior_tree.json:542-590
  - priv/data/system_ai/behavior_tree.json:645
  - priv/data/system_ai/behavior_tree.json:689-726
  - priv/data/system_ai/behavior_tree.json:770
  - lib/game/system_ai/actions.ex:112-348
  - lib/game/system_ai/buildings_helper.ex:6
  - lib/game/system_ai/helper.ex:8-14
  - lib/game/system_ai/helper.ex:161-177
  - lib/game/system_ai/helper.ex:234-276
  - lib/game/system_ai/helper.ex:301-346
length: long
length_reason: the six-step decision order, the two routes to the starter buildings, and the upgrade and workforce stalls are one topic; each needs its conditions in full
status: reviewed

---
[[autonomous-system|Autonomous systems]] and [[dominions]] build by themselves.

{shot:autonomous-state#status|The highlighted status says this autonomous system develops itself.}

Each makes at most one building decision every {duration:50}. Its first decision comes at a random time within that span.

It does the first of these that fits:

1. If its [[production|build queue]] is busy, it waits.
2. It repairs a [[siege|damaged building]].
3. It builds starter buildings. This needs exactly one habitable planet with infrastructure and a free tile. If that planet has over 4 free tiles, it gets two {name:building.hab_open_poor}, then a {name:building.university_open}. Once it has them, and while it still has over 4 free tiles, the same test runs on barren planets. A barren planet that passes gets two {name:building.hab_dome}, then one {name:building.mine_dome}.
4. With 3 or fewer free [[workforce]], it builds [[stellar-bodies|infrastructure]] on a planet that has none.
5. With 10 or less [[stability]], it builds infrastructure on a planet that has none, or else a stability building.
6. It picks a random planet, moon or asteroid with a free tile and builds there.

When it picks a random barren planet, that planet first gets its infrastructure, then a [[housing]] building. When it picks a habitable planet, it first checks the starter buildings again. This way, a barren planet that passes the test can get its starter buildings even when no habitable planet does. After that, the planet it picked gets a random building.

Once the system has 10 finished buildings, half the time it tries to upgrade a building first. If nothing can be upgraded, it builds instead.

The more finished buildings a system has, the more workforce its random building needs. Whenever it lacks the free workforce for what it picked, it builds nothing that cycle.

- It never upgrades infrastructure.
- It never builds a {name:building.monument_dome} or {name:building.high_factory_dome}.
- A fully built system only repairs.

Known issue: when free workforce runs low, it should also build housing, but never does.

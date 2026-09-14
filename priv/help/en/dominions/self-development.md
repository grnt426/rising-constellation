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
status: reviewed

---
[[autonomous-system|Autonomous systems]] and [[dominions]] build by themselves.

{shot:autonomous-state#status|The highlighted status says this autonomous system develops itself.}

Every {duration:50}, each makes at most one building decision, from a random point in that cycle.

It does the first that fits:

1. If its [[production|build queue]] is busy, it waits.
2. It repairs a [[siege|damaged building]].
3. If its main habitable planet has its infrastructure and over 4 free tiles, it gets two {name:building.hab_open_poor} and a {name:building.university_open}. After that, a barren planet with its infrastructure and over 4 free tiles gets two {name:building.hab_dome} and one {name:building.mine_dome}.
4. With 3 or fewer free [[workforce]], it builds missing [[stellar-bodies|infrastructure]].
5. With 10 or less [[stability]], it builds missing infrastructure or stability buildings.
6. It builds on a random planet, moon or asteroid with a free tile.

In step 6, a barren planet first gets infrastructure and [[housing]]. From 10 buildings, half the time it tries an upgrade first.

Bigger systems need more free workforce to build.

- It never upgrades infrastructure.
- It never builds a {name:building.monument_dome} or {name:building.high_factory_dome}.
- A fully built system only repairs.

Known issue: step 4 should build housing too, but never does.

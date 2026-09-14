---
title: Self-development
guide: dominions
aliases: [autonomous-development]
terms: [self-development, autonomous development]
related: [dominions, workforce, stability]
sources:
  - lib/game/instance/stellar_system/stellar_system.ex:10
  - lib/game/instance/stellar_system/stellar_system.ex:152-154
  - lib/game/instance/stellar_system/stellar_system.ex:912-931
  - lib/game/instance/stellar_system/stellar_system.ex:1807-1817
  - lib/game/instance/stellar_system/stellar_system.ex:333-377
  - lib/game/instance/stellar_system/stellar_system.ex:494-498
  - priv/data/system_ai/behavior_tree.json:266-296
  - priv/data/system_ai/behavior_tree.json:401-434
  - priv/data/system_ai/behavior_tree.json:542-590
  - priv/data/system_ai/behavior_tree.json:645
  - priv/data/system_ai/behavior_tree.json:689-726
  - priv/data/system_ai/behavior_tree.json:770
  - lib/game/system_ai/actions.ex:112-348
  - lib/game/system_ai/buildings_helper.ex:6
  - lib/game/system_ai/helper.ex:8-14
  - lib/game/system_ai/helper.ex:248-276
  - lib/game/system_ai/helper.ex:301-346
status: reviewed

---
[[star-systems|Autonomous systems]] and [[dominions]] build by themselves.

Every {duration:50}, each makes one building decision.

It does the first that applies:

1. If its [[production|build queue]] is busy, it waits.
2. It repairs a [[siege|damaged building]].
3. On its main habitable planet, it builds two {name:building.hab_open_poor} and a {name:building.university_open}. Then two {name:building.hab_dome} and one {name:building.mine_dome} on a barren planet.
4. With 3 or fewer free [[workforce]], it builds [[stellar-bodies|infrastructure]] on a planet without it.
5. With 10 or less [[stability]], it builds infrastructure, or else a stability building.
6. It picks a random planet. A barren planet first gets infrastructure and [[housing]]. Then it builds a random building. With 10 or more buildings, it may upgrade instead.

Systems with more buildings pick buildings that cost more workforce. Without enough free workforce, it builds nothing.

Edge cases:

- It never upgrades infrastructure. So upgrades that need it fail.
- It never builds a {name:building.monument_dome} or a {name:building.high_factory_dome}.
- Under siege, it orders nothing.
- Once every tile is built, it only repairs.

Known issue: it should build housing when workforce is low, but never does.

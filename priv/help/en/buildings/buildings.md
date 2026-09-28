---
title: Buildings
kind: guide
terms: [building, buildings, Unique, Limited, unique building, limited building, destroy, demolish, infrastructure building]
aliases: [unique-buildings#unique-buildings, limited-buildings#limited-buildings, infrastructure-building#infrastructure-first, destroy-building#destroying-a-building, demolish#destroying-a-building, foreign-buildings#buildings-of-other-players, order-building#ordering-a-building]
related: [construction-queue, upgrades, damaged-buildings, stellar-bodies, workforce, siege, dominions]
length: long
length_reason: the brief keeps ordering, Unique and Limited, destroying and other players' tiles as guide sections rather than leaves, and each rule needs its own sentence
sources:
  - lib/game/instance/stellar_system/stellar_system.ex:305-320
  - lib/game/instance/stellar_system/stellar_system.ex:347-451
  - lib/game/instance/stellar_system/stellar_system.ex:565-595
  - lib/game/instance/stellar_system/stellar_system.ex:1414-1439
  - lib/game/instance/stellar_system/stellar_system.ex:1536-1550
  - lib/game/instance/stellar_system/stellar_system.ex:1624-1635
  - lib/game/instance/stellar_system/agent.ex:212-228
  - lib/game/instance/stellar_system/tile.ex:20-52
  - lib/game/instance/stellar_system/tile.ex:82-90
  - lib/game/instance/stellar_system/tile.ex:132-149
  - lib/game/instance/character/actions/conquest.ex:123-140
  - lib/game/instance/character/actions/raid.ex:100-117
  - lib/game/instance/character/actions/loot.ex:101-118
  - lib/game/instance/player/player.ex:59-60
  - lib/game/instance/player/player.ex:351-398
  - lib/game/instance/player/agent.ex:343-364
  - lib/game/instance/player/agent.ex:389-402
  - lib/game/instance/faction/stellar_system.ex:83-87
  - lib/game/instance/faction/stellar_system.ex:140-171
  - lib/game/instance/faction/faction.ex:169-183
  - lib/data/game/content/stellar-body.ex
  - lib/data/game/content/building-slow.ex
  - front/src/game/components/galaxy/system/Production.vue:188-218
  - front/src/game/components/galaxy/system/Production.vue:296
  - front/src/game/components/card/BuildingCard.vue:15
  - front/src/game/components/card/BuildingCard.vue:54-66
  - front/src/game/components/card/BuildingCard.vue:108-122
  - front/src/game/components/galaxy/system/BodiesItem.vue:151-173
  - front/src/game/components/galaxy/system/BodiesItem.vue:209-232
status: reviewed
---
Buildings stand on the tiles of your systems' [[stellar-bodies|planets, moons and asteroids]] and add to the system's [[system-outputs|outputs]], [[housing]] and [[stability]]. Every building has its own page, which the ? on its card opens.

## Where buildings go

Each building fits one body type: {name:patent_class.open}, {name:patent_class.dome}, or {name:patent_class.orbital}. Gas giants and asteroid belts take no buildings. See [[stellar-bodies]]. Each building's own page says which type it fits, and so does the table at the end of this guide.

## Infrastructure first

Tile 1 of a planet takes only its infrastructure building. See [[infrastructure-tile|the infrastructure tile]]. The planet's other tiles take no building until that one is finished. Ordering it is not enough. A new colony starts with a level 1 infrastructure building on one of its planets. See [[colonization]]. Moons and asteroids have no infrastructure building and need none.

The infrastructure building also caps the level of the other buildings on its planet. None of them can be upgraded above its level. See [[upgrades]].

## Ordering a building

Pick a free tile, then a building from its menu.

{shot:build-menu#locked,disabled,limited,cost|A building whose patent you lack (1), a Limited building already on this planet (2), its Limited badge (3) and its costs (4).}

- Level 1 needs the building's patent. The few buildings that need none say so on their page.
- A building has two costs: [[credit]] and [[production]].
- You pay the full credit cost when you order. You need at least that much credit.
- While your empire is bankrupt, you cannot order.
- The production cost is worked off in the system's [[construction-queue|construction queue]].
- You cannot order buildings in a [[dominions|dominion]].

## Unique and Limited buildings

A building with no limit can fill every free tile of its body type. Most buildings are Unique or Limited instead.

### Unique buildings

A Unique building can stand only once in a star system. A copy on any body of the system counts.

### Limited buildings

A Limited building can stand only once on each planet, moon or asteroid. So one system can hold several, one on each body of its type.

For Unique and Limited buildings alike:

- A copy that is only ordered, or that is [[damaged-buildings|damaged]], still counts.
- The limit is checked only when you order level 1. It never blocks upgrading your copy.
- Destroying your copy, or cancelling its order, lets you order a new one at once.

The build menu does not let you order a building the limit blocks, like building (2) in the screenshot above.

## Destroying a building

- Destroying a building is instant. No credit or production comes back.
- An infrastructure building can never be destroyed.
- A building cannot be destroyed while it is being built, upgraded or repaired.
- A damaged building can be destroyed.
- Nothing can be destroyed during a [[siege]].
- The building's [[workforce]] is freed at once.

## Damage

When a Navarch's conquest, bombardment or pillage resolves, it can damage buildings. See [[siege]]. A damaged building gives no bonuses until it is repaired. See [[damaged-buildings]].

## Buildings of other players

For a system outside your faction, your system visibility decides what you see of its buildings.

| System visibility | What its tiles show |
| --- | --- |
| 0 or 1 | Nothing about its buildings. |
| 2 or 3 | Which tiles hold a building, and which of those are damaged. |
| 4 | Also which building stands on each tile. |
| 5 | Everything, including levels and construction in progress. |

{shot:foreign-tiles#hidden-building|At system visibility 2, the highlighted tile shows that it holds a building, but not which one or its level.}

A system held by your faction always shows everything. An agent of your faction in the system gives at least visibility 2.

## All buildings

{table:buildings_list}

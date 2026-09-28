---
title: Upgrades
kind: mechanic
guide: buildings
terms: [upgrade, building level, level cap]
aliases: [upgrade, building-levels]
length: long
length_reason: level requirements differ for infrastructure, other planet and moon or asteroid buildings, and the brief adds the Flash, damaged and siege edge cases
related: [buildings, construction-queue, damaged-buildings, siege]
sources:
  - lib/game/instance/stellar_system/stellar_system.ex:381-396
  - lib/game/instance/stellar_system/stellar_system.ex:1624-1635
  - lib/game/instance/stellar_system/stellar_system.ex:1704-1748
  - lib/game/instance/stellar_system/stellar_system.ex:1750-1768
  - lib/game/instance/stellar_system/agent.ex:237-245
  - lib/game/instance/stellar_system/tile.ex:44-46
  - lib/game/instance/stellar_system/tile.ex:72-74
  - lib/game/instance/player/player.ex:382-387
  - lib/data/game/building.ex:72-80
  - lib/data/game/patent.ex:56-62
  - lib/data/game/content/building-fast.ex
  - front/src/game/components/galaxy/system/BodiesItem.vue:61-76
  - front/src/game/components/galaxy/system/BodiesItem.vue:222-227
status: reviewed
---
An upgrade raises a finished building by one level. You order and pay for it [[order-building|like a new building]]. Each level's costs and effects are on the building's page.

{shot:body-tiles-actions#upgrade|The Upgrade button of a level 1 building.}

- You can only order the next level. Levels cannot be skipped.
- A tile takes one order at a time, so you upgrade one level after another. See [[construction-queue]].
- While it upgrades, the building keeps working at its current level. The new level counts once the upgrade is finished.

## What each level needs

In a Flash game, every building has one level, so nothing can be upgraded. See [[game-time]].

- An [[infrastructure-building|infrastructure building]] needs its own patent for each level. The infrastructure building is [[building/infra_open]] on {name:patent_class.open} and [[building/infra_dome]] on {name:patent_class.dome}.
- Other buildings on a planet need no patent above level 1. Their level can never be higher than the level of the planet's infrastructure building. The infrastructure building's new level counts toward that cap only once its upgrade is finished.
- Buildings on moons and asteroids have no such cap. From level 2, each level needs a patent, and that patent is the same for every building on a moon or asteroid.

For example:

    {name:building.infra_open} at level 3: the other buildings on that planet can reach level 3

{table:upgrade_patents}

A damaged building must be repaired before it can be upgraded. See [[damaged-buildings]].

When a [[siege]] damages a building that is upgrading, the upgrade is cancelled and its credit refunded.

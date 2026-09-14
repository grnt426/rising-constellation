---
title: Damaged buildings
kind: mechanic
guide: buildings
terms: [damaged building, repair, repairs, repairs underway]
aliases: [repair, repairs]
related: [buildings, siege, construction-queue, upgrades, workforce]
sources:
  - lib/game/instance/stellar_system/stellar_system.ex:305-333
  - lib/game/instance/stellar_system/stellar_system.ex:1704-1748
  - lib/game/instance/stellar_system/agent.ex:211-247
  - lib/game/instance/character/actions/conquest.ex:140
  - lib/game/instance/character/actions/raid.ex:117
  - lib/game/instance/character/actions/loot.ex:118
  - lib/game/instance/character/actions/sabotage.ex
  - lib/game/instance/stellar_system/stellar_system.ex:1290-1330
  - lib/game/instance/stellar_system/stellar_system.ex:1624-1635
  - lib/game/instance/stellar_system/stellar_system.ex:1536-1551
  - lib/game/instance/stellar_system/stellar_system.ex:386
  - lib/game/instance/stellar_system/stellar_system.ex:398-419
  - lib/game/instance/stellar_system/stellar_system.ex:453-477
  - lib/game/instance/stellar_system/stellar_system.ex:512-563
  - lib/game/instance/stellar_system/stellar_system.ex:565-595
  - lib/game/instance/stellar_system/stellar_system.ex:608-653
  - lib/game/instance/stellar_system/tile.ex:92-130
  - lib/game/instance/player/player.ex:371-387
  - lib/game/instance/player/agent.ex:1428-1450
  - lib/data/game/content/constant-slow.ex:19
  - front/src/game/components/galaxy/system/BodiesItem.vue:213-219
status: reviewed
---
A building can be damaged when a Navarch's conquest, bombardment or pillage resolves. Nothing else damages buildings. An Erased's sabotage never does. See [[siege]] for which buildings can be hit.

{shot:body-tiles-actions#damaged,repair|A damaged building (1) and its Repair button (2).}

A damaged building:

- Gives none of its bonuses, so no outputs, housing or stability.
- Still mobilizes its [[workforce]].
- Still counts as the one copy of a [[unique-buildings|Unique]] or [[limited-buildings|Limited]] building.
- Cannot be upgraded until it is repaired. See [[upgrades]].
- Can still be destroyed. See [[destroy-building]].
- If it is a shipyard, the system cannot order its ships.

## Repairing

A repair costs {const:building_repairs_factor} times the credit and production of the building's current level. You pay the credit when you [[order-building|order]]. The production is worked off in the [[construction-queue|construction queue]].

    8,000 credits × {const:building_repairs_factor} = 4,000 credits
    1,000 production × {const:building_repairs_factor} = 500 production

Both costs are rounded to the nearest whole number. A repair needs no patent, and the building comes back at the same level.

Cancelling a repair gives back its credit. See [[cancel-order]]. The building stays damaged.

During a [[siege]], you can neither order nor cancel a repair.

---
title: Construction queue
kind: mechanic
guide: buildings
terms: [construction queue, build queue, queue, cancel, refund]
aliases: [build-queue, cancel-order#cancelling-an-order]
length: long
length_reason: the brief gives this leaf the order of work, one order per tile, both time estimates, each kind of refund, the siege lock and the change of hands, one sentence each
related: [buildings, production, upgrades, damaged-buildings, siege, administrative-operations]
sources:
  - lib/game/instance/stellar_system/production_queue.ex:18-68
  - lib/game/instance/stellar_system/production_queue.ex:73-74
  - lib/game/instance/stellar_system/stellar_system.ex:361
  - lib/game/instance/stellar_system/stellar_system.ex:369
  - lib/game/instance/stellar_system/stellar_system.ex:516-522
  - lib/game/instance/stellar_system/stellar_system.ex:604-606
  - lib/game/instance/stellar_system/stellar_system.ex:608-653
  - lib/game/instance/stellar_system/stellar_system.ex:235-283
  - lib/game/instance/stellar_system/stellar_system.ex:1144-1222
  - lib/game/instance/stellar_system/tile.ex:55-60
  - lib/game/instance/stellar_system/tile.ex:103-104
  - lib/game/instance/stellar_system/agent.ex:61-86
  - lib/game/instance/stellar_system/agent.ex:341-346
  - lib/game/instance/player/agent.ex:147
  - lib/game/instance/player/agent.ex:198
  - lib/game/instance/player/agent.ex:1027
  - lib/game/instance/player/agent.ex:1303-1308
  - lib/game/instance/player/agent.ex:1405-1426
  - lib/game/instance/player/agent.ex:421-449
  - lib/game/instance/player/player.ex:770-772
  - lib/game/instance/character/character.ex:455-458
  - lib/game/instance/character/actions/conquest.ex:140-150
  - front/src/game/components/card/BuildingCard.vue:106-126
  - front/src/game/store.js:201-206
  - front/src/game/components/galaxy/system/Production.vue:178-187
  - front/src/game/components/card/ClosedProductionCard.vue:38-48
  - front/src/game/components/galaxy/system/ProductionBox.vue:28-64
status: reviewed
---
The construction queue is a system's list of orders: new buildings, upgrades, repairs and ships. Each system has one queue, and it works through its orders in the order you placed them.

{shot:production-queue#first,finish-time,cancel|The first order (1), its estimated finish time (2) and the cancel button of the hovered order (3).}

The system's [[production]] goes into the first order.

{shot:production-box-queue#progress,counter|The order being built and the number of orders behind it (1), and the time it has left (2).}

A tile takes one order at a time. While it is being built, upgraded or repaired, it takes no other order until that one finishes or is cancelled.

## Time estimates

{shot:build-menu#cost|A building card's costs, with its build time next to the production cost.}

The time on a building card is the time to build that building alone, at the system's current production. For a building that costs 1,200 production:

    1,200 production ÷ {rate:100|production} = {duration:12}

The queue list shows when each order should finish. It counts every order before it, at the current production. The card's time and the queue list's finish times change whenever the system's production changes. In a Flash game, the queue list shows no finish times. See [[game-time]].

## Cancelling an order

- You can cancel any order, not only the last one.
- A new building or an upgrade gives back its full credit cost.
- A repair gives back the credit it cost. See [[damaged-buildings]].
- A ship order gives back its credit and technology cost.
- Production already spent on the order is lost.
- The tile goes back to how it was: empty, damaged, or with its building at the old level.

During a [[siege]], you can neither order nor cancel.

When the system is conquered, or you use [[liberate|Liberate]] or [[abandon|Abandon]] on it, its building, upgrade and repair orders stay and keep building. Nothing still in the queue is refunded to you, and you can no longer cancel those orders.

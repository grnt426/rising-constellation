---
title: Patents
kind: guide
terms: [patent, patents, patent tree, Origin]
aliases: [patent-tree#the-patent-tree]
related: [price-scaling, technology, buildings, upgrades, lexes]
sources:
  - lib/game/instance/player/player.ex:461-492
  - lib/game/instance/player/player.ex:476-477
  - lib/game/instance/player/player.ex:403-407
  - lib/game/instance/player/player.ex:436-447
  - lib/game/instance/player/agent.ex:505-525
  - lib/data/game/patent.ex:56-78
  - lib/data/game/content/patent-slow.ex
  - lib/data/game/content/patent-medium.ex
  - lib/data/game/content/patent-fast.ex
  - front/src/game/components/mini-panel/PatentMiniPanel.vue:1-5
  - front/src/game/components/mini-panel/PatentMiniPanel.vue:13-24
  - front/src/game/components/mini-panel/PatentMiniPanel.vue:33-40
  - front/src/game/components/mini-panel/PatentMiniPanel.vue:53-58
  - front/src/game/components/mini-panel/PatentMiniPanel.vue:103-132
  - front/src/game/components/mini-panel/PatentMiniPanel.vue:139-153
  - front/src/game/components/mini-panel/PatentMiniPanel.vue:246-295
  - front/src/game/components/card/PatentCard.vue:1-143
  - front/src/game/components/card/PatentCard.vue:164-168
  - lib/game/instance/character/ship.ex:17
  - lib/game/instance/character/army.ex:245
  - front/src/game/Game.vue:12
status: reviewed
---
Patents are research you buy with [[technology]]. Each one unlocks buildings, building levels, ships or larger ship units. A patent is yours for the rest of the game.

## The patent tree

Patents form a tree. Its first patent is {name:patent.citadel}, alone in the {name:patent_class.root} branch. Every other patent needs one patent before it, called its ancestor. Each patent's page lists its ancestor under Requires, the path to it from {name:patent.citadel}, and exactly what it unlocks.

The rest of the tree is split into branches, which differ by game mode (see [[game-time]]):

- Legacy and Tactic: {name:patent_class.open}, {name:patent_class.dome}, {name:patent_class.orbital}, {name:patent_class.ship}
- Flash: {name:patent_class.economic}, {name:patent_class.military}

## Buying a patent

You can buy a patent once you own its ancestor and have enough technology. Having exactly its price is enough.

- A patent works as soon as you buy it.
- There is no refund, and no way to sell a patent back.
- In the patent panel, a click on an available patent buys it at once, with no confirmation.
- On a phone, a tap opens the patent's card instead, and its {ui:card.patent.buy} button buys it.

## The price of a patent

Each patent has a base price in technology, listed below, and its card shows the price you pay now. Every patent you own makes the next one dearer, and the panel's {ui:minipanel.patent.price_factor} shows by how much. See [[price-scaling]].

## What patents unlock

- **Buildings.** A building's patent unlocks its level 1. See [[buildings]].
- **Building levels.** Upgrade patents unlock the higher levels of infrastructure buildings and of buildings on moons and asteroids. Flash games have none. An infrastructure building's level caps the other buildings on its planet. See [[upgrades]].
- **Ships.** A ship's patent lets your shipyards build it.
- **Larger units.** A unit is a group of identical ships that takes one place in a fleet. A unit-size patent lets your shipyards build a ship in larger units.

A patent can unlock a building that none of your systems can take yet, because of its body type or infrastructure. See [[buildings]].

## The patent panel

Press P to open the patent panel (see [[hotkeys]]). Its branch tabs appear once you own your first patent.

{shot:patent-panel#tabs,owned,available,locked|Branch tabs (1), with owned (2), available (3) and locked (4) patents.}

Hover a patent to see its card. Right-click a patent to hold its card in place, and right-click anywhere in the panel, or close the card, to let it go.

{shot:patent-dock#patent,card|A right-clicked patent (1) and its card held in place (2).}

## All patents

{table:patents_list}

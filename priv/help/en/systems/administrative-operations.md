---
title: Administrative Operations
guide: star-systems
terms: [administrative operations, Liberate, Administer, Abandon, abandon system, abandon dominion]
aliases: [liberate, administer, abandon]
related: [dominions, system-limits, self-development, ideology]
sources:
  - front/src/game/components/galaxy/system/State.vue:27-107
  - lib/game/instance/player/agent.ex:132-236
  - lib/game/instance/player/agent.ex:1397-1418
  - lib/game/instance/player/player.ex:208-218
  - lib/game/instance/player/player.ex:261-265
  - lib/game/instance/player/player.ex:324-349
  - lib/game/instance/player/player.ex:1289-1292
  - lib/game/instance/stellar_system/stellar_system.ex:235-279
  - lib/data/game/content/constant-slow.ex:32-34
status: reviewed

---
Administrative Operations change how you hold one of your systems or dominions. They cost {icon:resource/ideology} [[ideology]].

{shot:system-state#liberate,abandon|Liberate (1) and Abandon (2), hatched here because this is the player's only system.}

- **Liberate** turns your system into your dominion. See [[dominions]].
- **Administer** turns your dominion back into your system.
- **Abandon** makes your system or dominion autonomous. It no longer belongs to you.

## Cost

Abandon costs {const:abandonment_cost} ideology. Liberate and Administer share one price. It starts at {const:transform_initial_cost} ideology. Every Liberate or Administer you do in this game adds {const:transform_additional_cost} to it. It never goes back down.

    after 3 Liberates or Administers in total:  {const:transform_initial_cost} + 3 × {const:transform_additional_cost} ideology

Your ideology must be higher than the price, not equal to it.

## Requirements

- Liberate and Abandon never work on your last system.
- Liberate needs a free dominion slot. Administer needs a free system slot. See [[system-limits]].

## What stays and what goes

- Buildings and population stay.
- Liberating or abandoning a system removes its governor and cancels the ship orders of your Navarchs there.
- A system that was your capital stops being your capital forever. See [[star-systems]].
- An abandoned system keeps building by itself. See [[self-development]].
- Anyone can then conquer it or take it with a Siderian's Control, you included. See [[dominions]].

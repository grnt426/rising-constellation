---
title: Colonization
guide: star-systems
icon: action/colonization
terms: [colonization, colonize, colony, colonization ship, colonisation ship]
related: [star-systems, system-limits, population, stances]
sources:
  - lib/game/instance/character/actions/colonization.ex:10-20
  - lib/game/instance/character/actions/colonization.ex:23-43
  - lib/game/instance/character/actions/colonization.ex:75-121
  - lib/game/instance/character/action_impl.ex:61-65
  - lib/game/instance/character/actions/fight.ex:330-341
  - lib/game/instance/player/player.ex:778-780
  - lib/game/instance/character/army.ex:52-53
  - lib/game/instance/character/army.ex:242-248
  - lib/game/instance/galaxy/galaxy.ex:108-123
  - lib/game/instance/stellar_system/stellar_system.ex:251-254
  - lib/game/instance/stellar_system/stellar_system.ex:1396-1425
  - lib/data/game/content/constant-slow.ex:6
  - lib/data/game/content/constant-slow.ex:47
status: reviewed

---
{icon:action/colonization} Colonization turns an uninhabited system into your system. No other kind of system can be colonized.

{shot:uninhabited-state#status|An uninhabited system says it can be colonized.}

## What you need

- A Navarch in the system with a {name:ship.transport_1}.
- A free slot under your System Limit. See [[system-limits]].
- The system is in a sector your faction holds, or in a sector next to one you hold. See [[star-systems]].

## How it goes

- It takes {duration:colonization_time}.
- When the colonization starts, Navarchs of other factions in the system can intercept yours. See [[stances]].
- On success, the {name:ship.transport_1} is used up.

## What the new colony gets

- A level 1 {name:building.infra_open} on its habitable planet with the most tiles.
- With no habitable planet, a level 1 {name:building.infra_dome} on its barren planet with the most tiles.
- {const:system_starting_population} population. See [[population]].

## When it is cancelled

If a requirement above is not met when you start, the colonization is cancelled and you get a notification. When the time runs out, the game checks the ship, the slot, the sector and that the system is still uninhabited. If one fails, it is cancelled the same way and no ship is used up.

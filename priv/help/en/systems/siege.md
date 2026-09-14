---
title: Siege
guide: star-systems
icon: action/conquest
terms: [siege, under siege, pillage yield]
aliases: [besieged, raid-potential, pillage-yield]
related: [system-penalties, production, defense, star-systems]
sources:
  - lib/game/instance/character/actions/conquest.ex:52-56
  - lib/game/instance/character/actions/conquest.ex:88-89
  - lib/game/instance/character/actions/raid.ex:37-41
  - lib/game/instance/character/actions/raid.ex:70-71
  - lib/game/instance/character/actions/loot.ex:37-41
  - lib/game/instance/character/actions/loot.ex:70-71
  - lib/game/instance/character/actions/loot.ex:101-129
  - lib/game/instance/character/actions/make_dominion.ex:22-40
  - lib/game/instance/stellar_system/siege.ex:15-34
  - lib/game/instance/stellar_system/stellar_system.ex:148-150
  - lib/game/instance/stellar_system/stellar_system.ex:297-331
  - lib/game/instance/stellar_system/stellar_system.ex:347
  - lib/game/instance/stellar_system/stellar_system.ex:441
  - lib/game/instance/stellar_system/stellar_system.ex:498
  - lib/game/instance/stellar_system/stellar_system.ex:936-983
  - lib/game/instance/stellar_system/stellar_system.ex:1332-1341
  - lib/game/instance/stellar_system/stellar_system.ex:1366-1392
  - lib/game/instance/stellar_system/stellar_system.ex:1686-1730
  - lib/game/instance/stellar_system/agent.ex:189-227
  - lib/game/instance/stellar_system/agent.ex:255-284
  - lib/game/instance/player/player.ex:640-690
  - lib/game/instance/player/agent.ex:1340-1380
status: draft
---
{icon:action/conquest} A system is under siege while a Navarch conquers, bombards or pillages it. It ends when that action resolves or the Navarch leaves.

## While besieged

- The system makes no [[production]]. See [[system-penalties]].
- No one can order buildings, repairs or ships.
- No one can place or recall agents.
- No other conquest, bombardment or pillage can start.
- A Siderian can still take Control to make a [[dominions|dominion]].

## When it ends

The attack can kill [[population]] and damage buildings. Each hit picks a random building:

- never an infrastructure building, or one already damaged or under repair
- a [[defense]] building twice as often

Hitting an upgrading building cancels and refunds the upgrade.

## Pillage yield

It is hidden, from 0 to 100. A pillage takes a multiple of the system's [[credit]], [[technology]] and [[ideology]] output. At 55 yield, a pillage takes 55 % of the haul at 100.

The yield refills by {rate:system_raid_potential_growth|pillage yield}. A pillage reads the yield before its own siege lowers it.

Known issue: every conquest, bombardment or pillage lowers pillage yield by {const:raid_potential_impact} when it resolves, even a failed one.

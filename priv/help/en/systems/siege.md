---
title: Siege
guide: star-systems
icon: action/conquest
terms: [siege, under siege, pillage yield]
aliases: [besieged#while-besieged, raid-potential#pillage-yield, pillage-yield#pillage-yield]
related: [system-penalties, production, defense, star-systems, damaged-buildings, construction-queue]
sources:
  - lib/game/instance/character/actions/conquest.ex:52-56
  - lib/game/instance/character/actions/conquest.ex:88-89
  - lib/game/instance/character/actions/raid.ex:37-41
  - lib/game/instance/character/actions/raid.ex:70-71
  - lib/game/instance/character/actions/loot.ex:37-41
  - lib/game/instance/character/actions/loot.ex:70-71
  - lib/game/instance/character/actions/loot.ex:93-96
  - lib/game/instance/character/actions/loot.ex:101-129
  - lib/game/instance/character/actions/make_dominion.ex:22-40
  - lib/game/instance/stellar_system/siege.ex:15-34
  - lib/game/instance/stellar_system/stellar_system.ex:148-150
  - lib/game/instance/stellar_system/stellar_system.ex:297-331
  - lib/game/instance/stellar_system/stellar_system.ex:347
  - lib/game/instance/stellar_system/stellar_system.ex:441
  - lib/game/instance/stellar_system/stellar_system.ex:498
  - lib/game/instance/stellar_system/stellar_system.ex:572
  - lib/game/instance/stellar_system/stellar_system.ex:610
  - lib/game/instance/stellar_system/stellar_system.ex:936-983
  - lib/game/instance/stellar_system/stellar_system.ex:1332-1341
  - lib/game/instance/stellar_system/stellar_system.ex:1366-1392
  - lib/game/instance/stellar_system/stellar_system.ex:1686-1730
  - lib/game/instance/stellar_system/agent.ex:189-227
  - lib/game/instance/stellar_system/agent.ex:255-284
  - lib/game/instance/player/player.ex:640-690
  - lib/game/instance/player/agent.ex:1348-1392
length: long
length_reason: siege blocks, building damage and pillage yield are one topic and each rule needs its full sentence
status: reviewed
---
{icon:action/conquest} A system is under siege while a Navarch conquers, bombards or pillages it. It ends when that action resolves or the Navarch leaves.

## While besieged

- The system makes no [[production]]. See [[system-penalties]].
- No one can order buildings, repairs or ships, cancel orders, destroy buildings, or place or recall agents.
- No other conquest, bombardment or pillage can start.

A Siderian can still take Control of a besieged autonomous system or dominion. See [[dominions]].

## Damage

When the attack resolves, it can kill [[population]] and [[damaged-buildings|damage buildings]], depending on its result. Each hit picks a random building. It never picks an infrastructure building, or one that is already damaged or under repair. The buildings in this table are twice as likely to be picked as the others:

{table:buildings_by_tag defense}

Hitting an [[upgrades|upgrading building]] cancels and refunds the upgrade.

## Pillage yield

Pillage yield is hidden, from 0 to 100. A successful pillage takes a multiple of the system's [[credit]], [[technology]] and [[ideology]] output from its owner's stock. At 55 yield, a pillage takes 55 % of what it would take at 100.

The yield refills by {rate:system_raid_potential_growth|pillage yield} until it is back at 100. When an attack resolves, a success lowers it by {const:raid_potential_impact} and a failure by {const:raid_potential_failure_impact}. A Navarch who is killed or forced to flee a fight before the attack resolves also lowers it by {const:raid_potential_failure_impact}. A Navarch who simply leaves ends the siege without lowering it. A pillage's loot uses the yield the system had before that same pillage lowers it.

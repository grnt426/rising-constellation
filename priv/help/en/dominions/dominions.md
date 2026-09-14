---
title: Dominions
kind: guide
terms: [dominion, dominions, Control]
related: [dominion-tax-rate, self-development, stability, population-class, administrative-operations, system-limits, star-systems, siege]
sources:
  - lib/game/instance/character/actions/make_dominion.ex:22-66
  - lib/game/instance/character/actions/make_dominion.ex:108-142
  - lib/game/instance/galaxy/galaxy.ex:108-118
  - lib/game/instance/player/player.ex:351-378
  - lib/game/instance/player/player.ex:400-409
  - lib/game/instance/player/player.ex:1039-1053
  - lib/game/instance/player/player.ex:1069-1079
  - lib/game/instance/player/agent.ex:160-236
  - lib/game/instance/player/agent.ex:505-519
  - lib/game/instance/player/agent.ex:993-1000
  - lib/game/instance/stellar_system/stellar_system.ex:256-261
  - lib/game/instance/stellar_system/stellar_system.ex:271-279
  - lib/game/instance/stellar_system/stellar_system.ex:912-931
  - lib/game/instance/stellar_system/stellar_system.ex:1827-1830
  - lib/game/instance/character/actions/conquest.ex:143-154
  - lib/game/instance/character/actions/raid.ex:37
  - lib/game/instance/character/actions/loot.ex:121-129
  - lib/game/instance/victory/victory.ex:87-110
  - front/src/game/components/galaxy/MapActionRadial.vue:74-77
status: reviewed

---
A dominion is a system you rule but do not run. It develops by itself and pays you a share of what it makes.

## What a dominion gives you

- A share of its [[credit]], [[technology]] and [[ideology]]. See [[dominion-tax-rate]].
- It builds by itself. See [[self-development]].
- It counts toward your faction's score, like your systems. See [[population-class]].

Your Lexes and your faction's traditions apply to it too.

## What you cannot do there

You cannot order buildings or ships in a dominion. Its population gives it no [[defense]].

## Getting a dominion

A {name:character.speaker} in the system can use {ui:galaxy.system.actions.make_dominion}.

- It works on an autonomous system.
- It also works on another player's dominion, even a faction-mate's.
- It never works on a player's system.
- You need a free dominion slot. See [[system-limits]].
- The system must be in a sector your faction holds, or next to one. See [[star-systems]].
- The higher the system's [[stability]], the more likely a Control fails.

You can also turn one of your own systems into a dominion with Liberate. See [[administrative-operations]].

No Navarch can stop a Control, whatever its stance. See [[stances]].

## Losing a dominion

- Another player's Control takes it.
- A Navarch's conquest takes it. It becomes the conqueror's system. See [[star-systems]].
- Abandon frees it. It becomes autonomous and no one owns it.
- Administer turns it into one of your own systems. You keep it, but it stops being a dominion. See [[administrative-operations]].

## Under attack

A Navarch can bombard or pillage your dominion. A pillage there takes its loot from your own credit, technology and ideology, not from the dominion. See [[siege]].

A dominion with negative output lowers your income. See [[dominion-tax-rate]].

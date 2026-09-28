---
title: Star systems
kind: guide
terms: [star system, system, status, uninhabitable, uninhabited, autonomous, autonomous system, neutral, capital]
aliases: [system-status#who-holds-a-system, capital#your-capital, autonomous-system#who-holds-a-system]
related: [stellar-bodies, colonization, system-limits, administrative-operations, siege, dominions, map-legend]
sources:
  - lib/game/instance/stellar_system/stellar_system.ex:43
  - lib/game/instance/stellar_system/stellar_system.ex:132-146
  - lib/game/instance/stellar_system/stellar_system.ex:235-279
  - lib/game/instance/stellar_system/stellar_system.ex:1822-1825
  - lib/game/instance/galaxy/galaxy.ex:108-123
  - lib/game/instance/faction/faction.ex:178-180
  - lib/game/instance/character/actions/colonization.ex:35-39
  - lib/game/instance/character/actions/conquest.ex:50-57
  - lib/game/instance/character/actions/conquest.ex:139-154
  - lib/game/instance/character/actions/raid.ex:37-41
  - lib/game/instance/character/actions/loot.ex:37-41
  - lib/game/instance/character/actions/make_dominion.ex:35-40
  - lib/game/instance/player/player.ex:240-259
  - lib/game/instance/player/agent.ex:1016-1035
  - lib/data/game/content/constant-slow.ex:7-8
  - front/src/locales/en/game.json:1032-1033
status: reviewed

---
A star system is a star with a few bodies around it. [[buildings|You build]] on the tiles of those bodies. See [[stellar-bodies]].

{shot:system-properties#owner,star|Who holds the system (1) and its star type (2).}

## Who holds a system

Every system has one of five statuses.

| Status | What other players can do to it |
| --- | --- |
| {ui:galaxy.map.uninhabitable} | Nothing. It has no habitable or barren planet. |
| Uninhabited | Colonization. |
| {ui:galaxy.system.properties.autonomous_system} | Conquest, bombardment, pillage and Control. It has no owner. |
| {ui:panel.empire.dominion} | Conquest, bombardment, pillage and Control. It belongs to a player. |
| A player's system | Conquest, bombardment and pillage. Never Control. |

A Navarch conquers, bombards and pillages. See [[siege]]. A Siderian's Control turns a system into a dominion. See [[dominions]].

Some systems are already autonomous when the galaxy is created. The [[map-legend|map legend]] calls them Neutral. Autonomous systems and dominions build by themselves. See [[self-development]].

How much you see of a system outside your faction depends on your visibility of it. For what you see of its buildings, see [[foreign-buildings]].

## Where you can expand

Colonization, conquest and Control only work in a sector your faction holds, or in a sector next to one.

## Getting more systems

- Colonize an uninhabited system. See [[colonization]].
- Conquer a system with a Navarch. It keeps its buildings and the population the attack left. A conquered dominion becomes your system.
- Take an autonomous system or another player's dominion with a Siderian's Control. It becomes your dominion.

How many you can hold has a limit. See [[system-limits]].

## Your capital

Your capital is your first system. Outside a daily challenge, every player's first system has the same bodies. Your capital starts with a higher base production. See [[production]].

It stops being your capital if you liberate it, abandon it or lose it. No other system ever becomes your capital, and it loses the higher base production.

## Losing systems

- You can give up a system or a dominion. See [[administrative-operations]].
- A Navarch can besiege your system. See [[siege]].
- If you lose your last system, you are out of the game, even if you still hold dominions.

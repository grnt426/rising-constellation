---
title: System and dominion limits
guide: star-systems
terms: [System Limit, Dominion Limit, system slot, dominion slot]
aliases: [system-limit, dominion-limit]
related: [colonization, administrative-operations, dominions, lexes, lex-changes, agent-limits]
sources:
  - lib/game/instance/player/player.ex:1005-1016
  - lib/game/instance/player/player.ex:208-265
  - lib/game/instance/player/player.ex:525-545
  - lib/game/instance/player/player.ex:778-784
  - lib/game/instance/player/agent.ex:133-182
  - lib/game/instance/character/actions/colonization.ex:35
  - lib/game/instance/character/actions/colonization.ex:86-90
  - lib/game/instance/character/actions/conquest.ex:50
  - lib/game/instance/character/actions/conquest.ex:139-143
  - lib/game/instance/character/actions/make_dominion.ex:35
  - lib/game/instance/character/actions/make_dominion.ex:109-134
  - lib/data/game/mutator.ex:380-393
  - front/src/game/components/navbar/Bottombar.vue:128-150
  - front/src/game/components/navbar/NavbarMaxedValue.vue:1-37
status: reviewed
---
Your {name:bonus_pipeline_out.player_system} is how many systems you can hold. Your {name:bonus_pipeline_out.player_dominion} is how many dominions you can hold.

{shot:bottombar-limits#systems|The Systems counter shows how many systems you hold, and its bar fills as you near your limit.}

Your {name:bonus_pipeline_out.player_system} starts at 1 and your {name:bonus_pipeline_out.player_dominion} at 0. [[active-lexes|Active lexes]] raise them. The tables below list which lexes raise each limit. The {name:mutator.expansion_charter} game modifier also adds 1 to your {name:bonus_pipeline_out.player_system} and 2 to your {name:bonus_pipeline_out.player_dominion}. It is not in the tables below.

{shot:bottombar-limits-tooltip#limit|Hover the Systems or Dominions counter to see your limit and where it comes from.}

## What they block

At your {name:bonus_pipeline_out.player_system}, these are refused:

- colonization (see [[colonization]])
- taking a system by conquest (see below)
- Administer (see [[administrative-operations]])

At your {name:bonus_pipeline_out.player_dominion}, these are refused:

- a Siderian's Control (see [[dominions]])
- Liberate (see [[administrative-operations]])

Colonization and Control check the limit again when they finish. If you are at the limit by then, the action is cancelled.

A conquest that succeeds while you are at your limit can still kill population and [[damaged-buildings|damage buildings]], but you do not take the system.

A [[lex-changes|change of active lexes]] that would leave you over a limit is refused. Your Navarch, Erased and Siderian Limits work the same way. See [[agent-limits]].

## Sources of {name:bonus_pipeline_out.player_system}

{table:bonus_sources player_system}

## Sources of {name:bonus_pipeline_out.player_dominion}

{table:bonus_sources player_dominion}

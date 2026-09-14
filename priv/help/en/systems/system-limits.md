---
title: System and dominion limits
guide: star-systems
terms: [System Limit, Dominion Limit, system slot, dominion slot]
aliases: [system-limit, dominion-limit]
related: [colonization, administrative-operations, dominions]
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
  - front/src/game/components/navbar/Bottombar.vue:128-150
status: draft
---
Your {name:bonus_pipeline_out.player_system} is how many systems you can hold. Your {name:bonus_pipeline_out.player_dominion} is how many dominions you can hold.

{shot:bottombar-limits#systems|The systems you hold. Hover the counter to see your limit.}

Your {name:bonus_pipeline_out.player_system} starts at 1 and your {name:bonus_pipeline_out.player_dominion} at 0. Lexes raise them.

## What they block

At your {name:bonus_pipeline_out.player_system}, these are refused:

- colonization (see [[colonization]])
- conquest
- Administer (see [[administrative-operations]])

At your {name:bonus_pipeline_out.player_dominion}, these are refused:

- a Siderian's Control (see [[dominions]])
- Liberate

The limit is checked again when a Navarch or Siderian finishes. At the limit by then, colonization and Control are cancelled. A successful conquest still hits the system, but you do not take it.

You cannot unslot a Lex if that would put you over a limit.

## Sources of {name:bonus_pipeline_out.player_system}

{table:bonus_sources player_system}

## Sources of {name:bonus_pipeline_out.player_dominion}

{table:bonus_sources player_dominion}

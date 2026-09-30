---
title: Agent limits
kind: mechanic
guide: lexes
terms: [Navarch Limit, Erased Limit, Siderian Limit, agent limit]
aliases: [navarch-limit, erased-limit, siderian-limit, agent-limit]
related: [lexes, lex-changes, system-limits]
sources:
  - lib/game/instance/player/player.ex:160-162
  - lib/game/instance/player/player.ex:544-575
  - lib/game/instance/player/player.ex:595-626
  - lib/game/instance/player/player.ex:660-684
  - lib/game/instance/player/player.ex:1101-1113
  - lib/game/instance/player/player.ex:1235-1242
  - lib/game/instance/player/player.ex:1297-1305
  - lib/game/instance/player/market.ex:622-640
  - lib/data/game/content/bonus-pipeline-out.ex:94-122
  - lib/data/game/content/doctrine-slow.ex:6-18
  - lib/data/game/mutator.ex:365-379
  - front/src/game/components/navbar/Bottombar.vue:283-296
  - front/src/game/components/navbar/Bottombar.vue:525-537
status: reviewed
length: long
length_reason: the brief gives one sentence per limit, the board and the deck, the bottom bar counter, the bought-versus-active rule, the modifier and both blocks, and each needs its own sentence
---
Your {name:bonus_pipeline_out.player_admiral} is how many Navarchs you can have on the board. Your {name:bonus_pipeline_out.player_spy} is how many Erased you can have on the board. Your {name:bonus_pipeline_out.player_speaker} is how many Siderians you can have on the board.

{shot:bottombar-agents#navarchs,erased,siderians|The Navarch (1), Erased (2) and Siderian (3) counters show your agents on the board, and each bar fills toward its limit.}

An agent is on the board once you activate it. Until then it waits in your deck, and agents in your deck don't count toward a limit.

{shot:bottombar-agents-tooltip#limit|Hover an agent counter to see its limit and where it comes from.}

All three start at 0. [[active-lexes|Active lexes]] raise them, and a lex you bought does nothing until it is active. The {name:mutator.open_court} game modifier also adds 1 to each limit, and it is not in the tables below. Without it, no agent can join the board until a lex that raises its limit is active, the first being [[lex/agent]].

The tables below list every lex that raises each limit. Every active source adds to it.

## What they block

At a limit, these are refused for that kind of agent:

- activating an agent from your deck
- buying, on the market, an agent that another player sells straight from their board, because it joins your board at once

Hiring an agent puts it in your deck, so the limits never block hiring.

The game refuses any change of active lexes that would leave you over a limit. See [[lex-changes]].

## Sources of {name:bonus_pipeline_out.player_admiral}

{table:bonus_sources player_admiral}

## Sources of {name:bonus_pipeline_out.player_spy}

{table:bonus_sources player_spy}

## Sources of {name:bonus_pipeline_out.player_speaker}

{table:bonus_sources player_speaker}

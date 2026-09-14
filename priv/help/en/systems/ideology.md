---
title: Ideology
icon: resource/ideology
kind: mechanic
guide: system-outputs
terms: [ideology]
related: [system-outputs, technology, dominion-tax-rate, administrative-operations, siege]
sources:
  - lib/game/instance/stellar_system/stellar_system.ex:1819-1868
  - lib/game/instance/stellar_system/stellar_system.ex:819-826
  - lib/game/instance/player/player.ex:944-965
  - lib/game/instance/player/player.ex:1005-1085
  - lib/game/instance/player/player.ex:320-350
  - lib/game/instance/player/player.ex:470-520
  - lib/game/instance/player/player.ex:572-600
  - lib/game/instance/player/agent.ex:305-329
  - lib/game/instance/player/agent.ex:1094-1098
  - lib/data/game/content/character.ex:93-95
  - lib/data/game/content/character.ex:137-139
  - lib/game/instance/character/character.ex:1043-1049
  - lib/game/instance/character/actions/loot.ex:101-129
status: reviewed

---
{icon:resource/ideology} Ideology is a resource your systems make for your empire. A system has no base ideology. All of it comes from buildings and other bonuses.

{shot:system-properties#ideology|The highlighted readout is this system's ideology.}

## Where it goes

- Your empire gains the ideology of all your systems.
- Your dominions add a share of theirs. See [[dominion-tax-rate]].

## What spends it

- buying Lexes and Lex slots. A Lex is a law your empire buys and places in a slot.
- some active Lexes, which lower your ideology income while they stay in a slot. They are listed in the last table below.
- hiring Erased and Siderians
- Liberate, Administer and Abandon. See [[administrative-operations]].

## Buildings that produce ideology

A range in this table runs from a building's first level to its last. See [[stellar-bodies]] for potentials.

{table:buildings_by_output sys_ideology}

## Other sources of ideology

A Siderian with the Wisdom skill raises the ideology of the system they govern. Each skill point adds 5 %.

{table:bonus_sources sys_ideology}

## What changes your empire's ideology income

These Lexes and traditions change your empire's total ideology income. A Lex counts only while it sits in a slot.

{table:bonus_sources player_ideology}

A Navarch who pillages one of your systems successfully takes ideology from your stock. See [[siege]].

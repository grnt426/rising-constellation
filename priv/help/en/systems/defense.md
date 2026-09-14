---
title: Defense
icon: resource/defense
kind: mechanic
guide: system-outputs
terms: [defense, population defense]
related: [system-outputs, population, workforce, siege, dominions]
sources:
  - lib/game/instance/stellar_system/stellar_system.ex:1819-1868
  - lib/game/instance/stellar_system/stellar_system.ex:1213
  - lib/data/game/content/constant-slow.ex:10
  - lib/data/game/content/constant-medium.ex:10
  - lib/data/game/content/constant-fast.ex:10
  - lib/data/game/content/building-slow.ex:1791-1840
  - lib/game/core/bonus.ex:38-87
  - lib/game/instance/character/actions/conquest.ex:118-137
  - lib/game/instance/character/actions/raid.ex:90-115
  - lib/game/instance/character/actions/loot.ex:90-115
  - lib/game/core/dice.ex:5-40
  - lib/game/instance/character/actions/make_dominion.ex:110-116
status: draft
---
{icon:resource/defense} Defense protects a system against a Navarch's conquest, bombardment and pillage. It stays in the system.

{shot:system-properties#defense|The highlighted shield is the system's defense.}

## Population and defense

In a Legacy or Tactic game, each whole point of [[population]] in a system you own adds 0.15 defense. In a Flash game, population adds no defense. Dominions and autonomous systems never get any.

For example, 20 population × 0.15 = 3 defense.

{shot:defense-tooltip#population|The highlighted row is the defense that population adds.}

## What it does

- More defense lowers a Navarch's chance to conquer, bombard or pillage the system.
- More defense also means more damage to the attacking fleet.

The odds themselves are explained with the Navarch actions.

## Buildings that produce defense

{table:buildings_by_output sys_defense}

A {name:building.defense_global_dome} adds a share of the defense the system already has, before percentage bonuses. See [[bonus-stacking]].

## Other sources of defense

{table:bonus_sources sys_defense}

Defense does nothing against a Siderian's Control. The system's [[stability]] defends against it. See [[dominions]].

Defense does nothing against the Erased either. Intelligence defends against them.

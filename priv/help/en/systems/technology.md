---
title: Technology
icon: resource/technology
kind: mechanic
guide: system-outputs
terms: [technology]
related: [system-outputs, ideology, dominion-tax-rate, siege]
sources:
  - lib/game/instance/stellar_system/stellar_system.ex:1819-1868
  - lib/game/instance/player/player.ex:1001-1090
  - lib/game/instance/player/player.ex:400-470
  - lib/game/instance/player/player.ex:572-600
  - lib/data/game/content/character.ex:49-51
  - lib/data/game/content/character.ex:137-139
  - lib/data/game/content/ship-slow.ex
  - lib/data/game/content/doctrine-slow.ex
  - lib/data/game/content/faction.ex:14
  - lib/data/game/content/faction.ex:82
  - lib/data/game/content/bonus-pipeline-out.ex:131
  - lib/game/instance/character/actions/loot.ex:101-129
status: reviewed

---
{icon:resource/technology} Technology is a resource your systems make for your empire. A system has no base technology. All of it comes from buildings and other sources.

{shot:system-properties#technology|The highlighted readout is the system's technology.}

## Where it goes

- Your empire gains the technology of all your systems.
- Your dominions add a share of theirs. See [[dominion-tax-rate]].
- Some Lexes and traditions raise or lower your empire's technology income directly.

## What spends it

- patents
- ships that have a technology cost
- hiring Navarchs and Siderians

## Buildings that produce technology

See [[stellar-bodies]] for potentials.

{table:buildings_by_output sys_technology}

## Other sources of technology

{table:bonus_sources sys_technology}

## What changes your empire's technology income

{table:bonus_sources player_technology}

A successful pillage on one of your systems takes technology from your stock. See [[siege]].

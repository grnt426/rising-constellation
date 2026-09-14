---
title: Stability
guide: population
icon: resource/happiness
terms: [stability, temporary penalty, temporary penalties, destabilization]
related: [population, population-status, system-penalties]
sources:
  - lib/game/instance/stellar_system/stellar_system.ex:1819-1868
  - lib/game/instance/stellar_system/stellar_system.ex:1894-1901
  - lib/game/instance/stellar_system/stellar_system.ex:867-872
  - lib/game/instance/stellar_system/stellar_system.ex:985-1002
  - lib/game/instance/stellar_system/stellar_system.ex:1244-1270
  - lib/game/instance/stellar_system/stellar_system.ex:1545-1565
  - lib/game/instance/character/actions/encourage_hate.ex:59-80
  - lib/game/core/value.ex:22-32
status: draft
---
{icon:resource/happiness} Stability is how content a system's [[population]] is. It starts at {const:system_base_happiness}. Each whole point of population changes it by {const:system_population_negative_happiness_factor}.

{shot:stability-tooltip#buildings,population|1. Stability from buildings. 2. Stability lost to population.}

What it does:

- It speeds up population growth. See [[population]].
- At 0 or below, it gives the system a [[population-status]] that reduces its outputs.

## Temporary penalties

A Siderian's {ui:galaxy.system.actions.encourage_hate} lowers a system's stability for a while. A success costs 15 stability and a critical success costs 20. Even a failure costs 5.

The penalty fades by {rate:happiness_penalty_reduction_factor|stability} and disappears when it reaches 0. Each penalty has its own line in the stability tooltip, showing what is left. Several penalties add up and fade separately.

## Buildings that change stability

{table:buildings_by_output sys_happiness}

## Other sources of stability

{table:bonus_sources sys_happiness}

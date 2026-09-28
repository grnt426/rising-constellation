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
  - lib/game/instance/character/actions/make_dominion.ex:114-116
  - lib/game/core/value.ex:22-32
status: reviewed
---
{icon:resource/happiness} Stability is how happy a system's [[population]] is. It starts at {const:system_base_happiness}, and population lowers it. Each whole point of population changes stability by {const:system_population_negative_happiness_factor}, and a fraction of a point does not count.

{shot:stability-tooltip#buildings,population|The highlighted lines show stability from buildings (1) and stability lost to population (2).}

What it does:

- It speeds up population growth. Below 0 stability, population slowly shrinks instead. See [[population]].
- At 0 or below, it gives the system a [[population-status]] that reduces its outputs.
- Higher stability makes a Siderian's {ui:galaxy.system.actions.encourage_hate} or [[dominions|Control]] more likely to fail.

## Temporary penalties

A Siderian's {ui:galaxy.system.actions.encourage_hate} lowers a system's stability. Even a failure costs 5 stability, but a critical failure costs nothing. A success costs 15, and a critical success costs 20.

The penalty fades by {rate:happiness_penalty_reduction_factor|stability} and disappears when it reaches 0. Several penalties add up and fade separately. Each one shows as its own Destabilization line in the stability tooltip, with what is left of it.

{shot:stability-tooltip-destabilized#temporary-penalties|A Destabilization penalty under Temporary penalties.}

## Buildings that change stability

{table:buildings_by_output sys_happiness}

## Other sources of stability

{table:bonus_sources sys_happiness}

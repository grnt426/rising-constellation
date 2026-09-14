---
title: Mobility
icon: resource/mobility
kind: mechanic
guide: credit
terms: [mobility, mobility bonus]
related: [credit, workforce]
sources:
  - lib/game/instance/stellar_system/stellar_system.ex:1834
  - lib/game/instance/stellar_system/stellar_system.ex:1859-1862
  - lib/game/core/bonus.ex:19-24
  - lib/data/game/content/constant-slow.ex:13
  - lib/data/game/content/bonus-pipeline-in.ex:165-171
status: reviewed
---
{icon:resource/mobility} Mobility adds credits to a system on top of its [[taxes]]. In the system's credit breakdown, this line is called {ui:resource-detail.misc.population_mobility}.

Each point of mobility adds {rate:system_mobility_taxes_factor|credits} for every point of [[workforce]].

For example, a system with 20 workforce and 8 mobility gets 20 × 8 × {rate:system_mobility_taxes_factor|credits} = {rate:16|credits}.

If the system's credits are below zero when the bonus is added, the bonus is 0.

## Buildings that produce mobility

{table:buildings_by_output sys_mobility}

## Buildings that scale with mobility

{table:buildings_by_input sys_mobility}

## Other sources of mobility

{table:bonus_sources sys_mobility}

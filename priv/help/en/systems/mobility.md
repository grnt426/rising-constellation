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
  - lib/game/core/bonus.ex:42-55
  - lib/game/core/bonus.ex:91-96
  - lib/data/game/content/constant-slow.ex:13
  - lib/data/game/content/bonus-pipeline-in.ex:165-171
status: reviewed
length: long
length_reason: the bonus skips percentage mobility except with three buildings, and both cases need the worked 30/33 example
---
{icon:resource/mobility} Mobility adds credits to a system on top of its [[taxes]]. In the system's credit breakdown, this line is called {ui:resource-detail.misc.population_mobility}.

Each point of mobility adds {rate:system_mobility_taxes_factor|credits} for every point of [[workforce]].

For example, a system with 20 workforce and 8 mobility gets 20 × 8 × {rate:system_mobility_taxes_factor|credits} = {rate:16|credits}.

If the system's credits are below zero when the bonus is added, the bonus is 0.

The bonus counts the system's mobility from before its percentage bonuses. So a percentage bonus from a Lex or tradition raises the system's mobility, but not this bonus. For example, 30 mobility with a +10 % Lex shows as 33, but the bonus still counts 30. Bonuses add up in a fixed order. See [[bonus-stacking]].

A {name:building.finance_open}, {name:building.finance_orbital} or {name:building.monument_dome} in the system changes this. With one of them, the bonus counts the raised mobility, 33 in the example. These buildings turn mobility or workforce into another resource. The {name:building.monument_dome} turns workforce into [[ideology]], so it is not in the tables below.

On top of that, a {name:building.finance_open} or a {name:building.finance_orbital} adds its own credits for each point of mobility. Those credits are a separate line, next to this bonus.

## Buildings that produce mobility

{table:buildings_by_output sys_mobility}

## Buildings that scale with mobility

{table:buildings_by_input sys_mobility}

## Other sources of mobility

{table:bonus_sources sys_mobility}

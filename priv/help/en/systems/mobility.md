---
title: Mobility
icon: resource/mobility
kind: mechanic
guide: credit
terms: [mobility, mobility bonus]
related: [credit, workforce]
sources:
  - lib/game/instance/stellar_system/stellar_system.ex:1896
  - lib/game/instance/stellar_system/stellar_system.ex:1921-1928
  - lib/game/core/bonus.ex:42-55
  - lib/game/core/bonus.ex:91-96
  - test/game/instance/stellar_system/mobility_credit_test.exs
  - lib/data/game/content/constant-slow.ex:13
  - lib/data/game/content/bonus-pipeline-in.ex:165-171
status: reviewed
---
{icon:resource/mobility} Mobility adds credits to a system on top of its [[taxes]]. In the system's credit breakdown, this line is called {ui:resource-detail.misc.population_mobility}.

Each point of mobility adds {rate:system_mobility_taxes_factor|credits} for every point of [[workforce]].

For example, a system with 20 workforce and 8 mobility gets 20 × 8 × {rate:system_mobility_taxes_factor|credits} = {rate:16|credits}.

A percentage bonus from a [[lexes|lex]] or a [[traditions|tradition]] raises the system's mobility, and this bonus counts all of it. For example, 30 mobility with a +10 % lex is 33, and the bonus counts 33. The credits for each point of mobility stay the same. A system with no mobility of its own gets nothing from a percentage. See [[bonus-stacking]].

A {name:building.finance_open} or a {name:building.finance_orbital} adds its own credits for each point of mobility. Those credits are a separate line, next to this bonus.

## Buildings that produce mobility

{table:buildings_by_output sys_mobility}

## Buildings that scale with mobility

{table:buildings_by_input sys_mobility}

## Other sources of mobility

{table:bonus_sources sys_mobility}

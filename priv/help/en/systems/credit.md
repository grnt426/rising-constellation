---
title: Credit
icon: resource/credit
terms: [credit, credits]
related: [taxes, mobility, population, workforce, system-penalties]
sources:
  - lib/game/instance/player/player.ex:1199-1241
  - lib/game/instance/stellar_system/stellar_system.ex:1831-1857
  - lib/game/instance/stellar_system/stellar_system.ex:1364-1390
status: draft
---
{icon:resource/credit} {ui:resource-description.credit}

A system produces credits from [[taxes]] on its [[population]], from the [[mobility]] bonus, and from buildings. [[system-penalties|System penalties]] can reduce a system's credits. Your income each tick is the sum over your systems, minus agent salaries and fleet upkeep.

## Buildings that produce credits

{table:buildings_by_output sys_credit}

## Other sources of credits

{table:bonus_sources sys_credit}

---
title: Population
icon: resource/population
terms: [population, workforce, mobilized population]
related: [taxes, stability, mobility]
sources:
  - lib/game/instance/stellar_system/stellar_system.ex:1226-1268
  - lib/game/instance/stellar_system/stellar_system.ex:1332-1340
  - lib/game/instance/stellar_system/stellar_system.ex:1825-1857
  - lib/data/game/content/constant-slow.ex:6-13
status: draft
---
{icon:resource/population} Population is counted in points. A new system starts at {const:system_starting_population} population and grows toward its housing. Growth slows as population approaches housing and stops above it; population is not capped.

Each point of population:

- pays [[taxes]]: {const:system_population_taxes_factor} credits per tick, plus the [[mobility]] bonus;
- changes [[stability]] by {const:system_population_negative_happiness_factor};
- adds {const:system_base_defense} defense in a system you own. Dominions and neutral systems get no defense from population.

Each point of population is one unit of workforce. Buildings mobilize workforce ({ui:card.building.mobilized}). Mobilizing more workforce than the system has applies a penalty to its outputs equal to the missing share: with 8 population and 10 mobilized, every output loses 20 %. The tooltip line for this is {ui:resource-detail.misc.workforce_penalties}.

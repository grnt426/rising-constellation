---
title: Stability
icon: resource/happiness
terms: [stability]
related: [population]
sources:
  - lib/game/instance/stellar_system/stellar_system.ex:1226-1268
  - lib/game/instance/stellar_system/stellar_system.ex:1341
  - lib/game/instance/stellar_system/stellar_system.ex:985-1001
  - lib/data/game/content/constant-slow.ex:9-11
status: draft
---
{icon:resource/happiness} Stability regulates how fast [[population]] grows. Every system starts with {const:system_base_happiness} stability, and each point of population changes it by {const:system_population_negative_happiness_factor}. Buildings, lexes and agents add or remove more.

Above 0, higher stability means faster growth, up to a cap of 25 stability. Below 0, population shrinks and the system's outputs take a penalty that grows in steps as stability falls; the system view shows the current step and its penalty.

Temporary penalties, such as a Siderian's Destabilize, fade by {const:happiness_penalty_reduction_factor} per tick until they reach 0.

## Buildings that change stability

{table:buildings_by_output sys_happiness}

## Other sources of stability

{table:bonus_sources sys_happiness}

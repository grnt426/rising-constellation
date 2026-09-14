---
title: Population status
guide: population
icon: resource/happiness
terms: [population status, population productivity, insufficient stability]
related: [stability, system-penalties]
sources:
  - lib/data/game/content/population_status.ex:1-41
  - lib/game/instance/stellar_system/stellar_system.ex:1325-1343
  - lib/game/instance/stellar_system/stellar_system.ex:1545-1570
  - lib/game/instance/stellar_system/agent.ex:383-398
  - lib/game/instance/stellar_system/stellar_system.ex:275-330
  - front/src/game/components/galaxy/system/State.vue:22-25
status: reviewed
---
{icon:resource/happiness} A population status is the tier a system's [[stability]] puts it in.

{table:population_statuses}

{shot:system-population-status#current|The highlighted band is the system's current status.}

- Every status below {name:population_status.normal} reduces the system's outputs by its penalty. See [[system-penalties]] for which outputs.
- Stability of exactly 0 is already {name:population_status.discontent}.
- Tooltips show this penalty as {ui:resource-detail.misc.uprising_penalties}.
- You get a notification when population, a finished or removed building, or a Destabilize pushes your system out of {name:population_status.normal}.

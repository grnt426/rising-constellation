---
title: Population
kind: guide
icon: resource/population
terms: [population, population growth, growth, growth target]
related: [housing, stability, workforce, credit]
sources:
  - lib/game/instance/stellar_system/stellar_system.ex:1204-1237
  - lib/game/instance/stellar_system/stellar_system.ex:1244-1270
  - lib/game/instance/stellar_system/stellar_system.ex:1396-1425
  - lib/game/instance/stellar_system/stellar_system.ex:1819-1868
  - lib/game/instance/stellar_system/stellar_system.ex:297-330
  - lib/game/instance/stellar_system/agent.ex:190-206
  - lib/game/instance/character/actions/conquest.ex:123-140
  - lib/game/instance/character/actions/raid.ex:100-117
  - lib/game/instance/character/actions/loot.ex:101-118
  - lib/rc/help/charts.ex:81-95
  - front/src/game/components/galaxy/system/Population.vue:9-31
status: reviewed
---
{icon:resource/population} Population is how many people live in a system, counted in points. A new colony starts with {const:system_starting_population} population.

{shot:system-population#growth,growth-bar|The growth word and the bar filling toward the next whole point, negative here because population is above its growth target.}

## How it grows

Population moves toward a growth target. It grows fast at first, then slows down as it gets close. The chart follows a new colony with 40 housing, with different amounts of extra stability.

{chart:population_growth housing=40 bonus=0,5,30|A new colony with 40 housing. Each line adds a different amount of stability.}

With no extra stability, the colony stops below its target. Each new point of population costs stability, and growth stops when stability runs out. See [[stability]]. At 0 stability or below, the system also gets a [[population-status]] that reduces its outputs.

## What sets the speed

- **Housing** sets the target: housing + 0.75. A system above its target shrinks back toward it. See [[housing]].
- **Stability** speeds growth, up to 25 stability. More than 25 adds nothing. Below 0 stability, population slowly drops. See [[stability]].
- **Size** slows growth down. At 120 population or more, a system grows at a fifth of the speed of an empty one.

Above the target, high stability makes the system shrink faster. Here is the exact growth, for players who want it:

    stability below −10:  growth = {rate:-0.002|population}
    stability below 0:    growth = {rate:-0.001|population}
    otherwise:            growth = (base + min(stability, 25) × {rate:0.002|population}) × housing factor × size factor

    base           = {rate:system_base_growth|population}
    housing factor = min((housing + 0.75 − population) × 0.1, 1)
    size factor    = (1 − min(population, 120) ÷ 120) × 0.8 + 0.2

## What population gives

- Taxes in credits. See [[credit]].
- It costs stability. See [[stability]].
- In a system you own, each whole point adds {const:system_base_defense} defense. Dominions get none.

Taxes, the stability cost and defense count only whole points of population. Growth uses the exact value. See [[workforce]].

A Navarch's conquest, bombardment or pillage can kill part of a system's population.

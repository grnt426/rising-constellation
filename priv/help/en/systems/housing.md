---
title: Housing
guide: population
icon: resource/habitation
terms: [housing, local population]
aliases: [local-population#population-on-each-body]
related: [population, workforce]
sources:
  - lib/game/instance/stellar_system/stellar_system.ex:1244-1270
  - lib/game/instance/stellar_system/stellar_system.ex:1446-1516
  - lib/game/instance/stellar_system/stellar_system.ex:1518-1533
  - lib/game/instance/stellar_system/stellar_system.ex:1204-1224
  - lib/game/instance/stellar_system/stellar_system.ex:1606-1617
  - lib/data/game/content/stellar-body.ex:27-67
  - front/src/game/components/galaxy/system/Bodies.vue:34-57
status: reviewed
---
{icon:resource/habitation} Housing sets the population a system grows toward. See [[population]] for how growth uses it.

## Population on each body

The system's [[workforce]] is shared out across its [[stellar-bodies|planets]]. Each planet gets a share in proportion to the housing its own buildings give. That share is the planet's {name:bonus_pipeline_in.body_pop}, shown on the highlighted badge.

{shot:system-bodies#body-population}

Example with 16 workforce:

    planet with 13 housing from buildings: 13 {name:bonus_pipeline_in.body_pop}
    planet with 3 housing from buildings:   3 {name:bonus_pipeline_in.body_pop}

- Gas giants and asteroid belts have no tiles, so they never get a share.
- Moons and asteroids never get a share either. No building there gives housing.
- Buildings on moons and asteroids still mobilize workforce.
- Only finished buildings count. A [[damaged-buildings|damaged building]] gives no housing.
- A planet's share is recalculated only when the system's workforce changes by a whole point.

## Buildings that give housing

{table:buildings_by_output sys_habitation}

## Other sources of housing

{table:bonus_sources sys_habitation}

## Buildings that scale with local population

{table:buildings_by_input body_pop}

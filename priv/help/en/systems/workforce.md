---
title: Workforce
guide: population
icon: resource/population
terms: [workforce, mobilized, mobilized workforce, over-mobilization, over-mobilized population]
related: [population, system-penalties]
sources:
  - lib/game/instance/stellar_system/stellar_system.ex:1213
  - lib/game/instance/stellar_system/stellar_system.ex:1518-1533
  - lib/game/instance/stellar_system/stellar_system.ex:1332-1343
  - lib/game/instance/stellar_system/stellar_system.ex:547-577
  - lib/game/instance/stellar_system/tile.ex:41-124
  - lib/data/game/content/building-slow.ex
  - front/src/game/components/galaxy/system/Population.vue:33-56
  - front/src/game/components/card/BuildingCard.vue:17-26
status: reviewed
---
{icon:resource/population} Workforce is a system's [[population]] rounded down to whole points. Buildings mobilize part of it.

{shot:system-population#workforce|Mobilized workforce and total workforce.}

Each building mobilizes a fixed workforce, the same at every level.

{shot:building-card-mobilized#mobilized|The workforce this building mobilizes.}

Which buildings mobilize:

- A finished building, on any [[stellar-bodies|planet, moon or asteroid]].
- A damaged building, even though it gives no bonuses.
- A building being upgraded or repaired.
- A building under construction mobilizes nothing until it is finished.
- Demolishing a building frees its workforce at once.

## Over-mobilization

When buildings mobilize more workforce than the system has, the system's outputs drop.

    12 workforce, 15 mobilized: outputs reduced by 20 %
    penalty = 1 − workforce ÷ mobilized

Tooltips show it as {ui:resource-detail.misc.workforce_penalties}. For the outputs it reduces and how it adds to other penalties, see [[system-penalties]].

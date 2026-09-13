---
title: Mobility
icon: resource/mobility
terms: [mobility, mobility bonus]
related: [taxes, population, credit]
sources:
  - lib/game/instance/stellar_system/stellar_system.ex:1831-1857
  - lib/game/core/bonus.ex:12-30
  - lib/data/game/content/constant-slow.ex:12-13
status: draft
---
{icon:resource/population} [[population|Population]] pays [[taxes]] in {icon:resource/credit} [[credit|credits]]. {icon:resource/mobility} Mobility raises that income: each point of mobility adds {const:system_mobility_taxes_factor} credits per point of population per tick.

Example:

    100 population × {const:system_population_taxes_factor} = 200 credits per tick (taxes)
    100 population × 45 mobility × {const:system_mobility_taxes_factor} = 450 credits per tick (mobility bonus)
    total: 650 credits per tick

The mobility bonus multiplies the system's credit subtotal after all flat bonuses. If that subtotal is negative, the mobility bonus is skipped. In the credit tooltip the two lines are {ui:resource-detail.misc.population_taxes} and {ui:resource-detail.misc.population_mobility}.

## Buildings that produce mobility

{table:buildings_by_output sys_mobility}

## Buildings that scale with mobility

{table:buildings_by_input sys_mobility}

## Other sources of mobility

{table:bonus_sources sys_mobility}

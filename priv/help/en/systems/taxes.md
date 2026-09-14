---
title: Taxes
icon: resource/credit
terms: [taxes, tax]
related: [population, workforce, mobility, credit]
sources:
  - lib/game/instance/stellar_system/stellar_system.ex:1831-1857
  - lib/data/game/content/constant-slow.ex:12
status: draft
---
Taxes are the {icon:resource/credit} [[credit|credits]] a system's {icon:resource/population} [[population]] pays every tick: {const:system_population_taxes_factor} credits per whole point of population ([[workforce]]). [[mobility|Mobility]] adds a bonus on top of that.

Taxes are a system income. They appear in the system's credit tooltip as {ui:resource-detail.misc.population_taxes}, next to the buildings that produce credits.

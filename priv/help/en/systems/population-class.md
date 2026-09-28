---
title: Population class
guide: population
icon: resource/population
terms: [population class, system points, star system points]
related: [population, workforce]
sources:
  - lib/data/game/content/population_class.ex:1-47
  - lib/game/instance/stellar_system/stellar_system.ex:1549-1557
  - lib/game/instance/victory/victory.ex:87-110
  - lib/game/instance/victory/victory.ex:344-393
  - front/src/game/components/galaxy/system/Properties.vue:38-56
status: reviewed
---
{icon:resource/population} A population class is a system's size tier. It comes from the system's [[population]].

{table:population_classes}

- The class uses the exact population, fractions included, not the rounded-down number used for [[workforce]]. So a system even a fraction of a point short of a class's population stays in the class below.
- Each class is worth the points in the last column. The galaxy map's {ui:panel.help.legend_mode_population_name} mode shows them.
- Your faction adds up the points of every system and [[dominions|dominion]] its players hold. That total is its score for {name:victory.population}, one of the paths to victory.
- Each milestone that total reaches on the path gives your faction victory points. If the total drops back below a milestone, the faction loses those points.
- The system view shows the points next to the owner's name. Hover them to see the system's class.

---
title: System penalties
guide: population
icon: resource/production
terms: [system penalties, output penalty, besieged]
related: [workforce, population-status, stability]
sources:
  - lib/game/instance/stellar_system/stellar_system.ex:12-30
  - lib/game/instance/stellar_system/stellar_system.ex:281-295
  - lib/game/instance/stellar_system/stellar_system.ex:1321-1343
  - lib/game/instance/stellar_system/stellar_system.ex:1366-1392
  - lib/game/core/bonus.ex:13-30
  - lib/game/core/bonus.ex:89-105
  - lib/game/instance/character/actions/conquest.ex:88
  - lib/game/instance/character/actions/raid.ex:70
  - lib/game/instance/character/actions/loot.ex:70
  - lib/data/game/content/population_status.ex:1-41
status: reviewed
---
System penalties reduce a system's outputs after every bonus is counted. There are three.

| Tooltip label | When | Size |
| --- | --- | --- |
| {ui:resource-detail.misc.under_siege_penalties} | a Navarch is conquering, bombarding or pillaging the system | all of its production |
| {ui:resource-detail.misc.workforce_penalties} | buildings mobilize more than the [[workforce]] | the share over-mobilized, see [[workforce]] |
| {ui:resource-detail.misc.uprising_penalties} | the [[population-status]] is not {name:population_status.normal} | set by the status |

## What they reduce

{ui:resource-detail.misc.under_siege_penalties} reduces production only. The other two reduce all of these:

- {name:bonus_pipeline_out.sys_production}
- {name:bonus_pipeline_out.sys_credit}
- {name:bonus_pipeline_out.sys_technology}
- {name:bonus_pipeline_out.sys_ideology}
- {name:bonus_pipeline_out.sys_defense}
- {name:bonus_pipeline_out.sys_ci}
- {name:bonus_pipeline_out.sys_remove_contact}
- {name:bonus_pipeline_out.sys_fighter_lvl}, {name:bonus_pipeline_out.sys_corvette_lvl}, {name:bonus_pipeline_out.sys_frigate_lvl} and {name:bonus_pipeline_out.sys_capital_lvl}

They never reduce [[stability]], [[housing]], [[mobility]] or S.L.S.D. An output that is already negative is not reduced.

## How they combine

Each penalty takes its share of what the previous one left.

    production 150, 12 workforce, 15 mobilized:  150 − 20 % = 120
    also {name:population_status.demonstration} (25 %):  120 − 25 % = 90
    also besieged:  production 0
    credit −50 in {name:population_status.demonstration}:  stays −50

Temporary stability penalties are something else. See [[stability]].

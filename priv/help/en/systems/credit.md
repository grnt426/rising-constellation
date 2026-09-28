---
title: Credit
icon: resource/credit
kind: guide
terms: [credit, credits, taxes, tax]
aliases: [taxes]
related: [population, workforce, mobility, system-penalties, system-outputs, dominion-tax-rate]
sources:
  - lib/game/instance/stellar_system/stellar_system.ex:1832-1862
  - lib/game/core/bonus.ex:13-29
  - lib/data/game/content/constant-slow.ex:12-13
  - lib/game/instance/player/player.ex:1005-1053
  - front/src/locales/en/game.json:1579-1583
  - lib/game/instance/player/player.ex:1199-1225
status: reviewed
---
{icon:resource/credit} Credits are the money of your empire. They pay for [[order-building|buildings]], ships, agent salaries and fleet maintenance. Credit is one of your systems' [[system-outputs|outputs]]. Each of your systems makes credits from taxes, the [[mobility|mobility bonus]], buildings and a few other sources.

## Taxes

Every whole point of [[population]] pays {rate:system_population_taxes_factor|credits} in taxes. Whole points of population are the system's [[workforce]]. You can read rates in ticks or in hours. See [[game-time]].

{shot:credit-tooltip#taxes|The highlighted Taxes row in a system's credit breakdown.}

For example, a system with 15 workforce pays 15 × {rate:system_population_taxes_factor|credits} = {rate:30|credits}.

## Mobility bonus

{icon:resource/mobility} Mobility adds more credits on top of taxes. The bonus grows with the system's workforce. See [[mobility]].

## Buildings

{table:buildings_by_output sys_credit}

## Other sources

{table:bonus_sources sys_credit}

## Penalties

Penalties can reduce a system's credits. See [[system-penalties]].

## Your income

Your empire's income is the sum of your systems' credits plus [[dominion-tax-rate|a share of your dominions' credits]], minus {ui:resource-detail.type.character_wages} and {ui:resource-detail.type.fleet_maintenance}.

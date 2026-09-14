---
title: Game time
kind: guide
terms: [tick, ticks, game speed, calendar]
related: [credit, population]
sources:
  - lib/game/core/tick.ex:8
  - lib/game/core/tick.ex:73-77
  - lib/data/game/content/speed.ex:1-33
  - lib/rc/help/tables.ex:75-94
  - lib/rc/help/data.ex:25-29
  - front/src/portal/pages/Settings.vue:55-80
  - front/src/locales/en/portal.json:1131-1135
  - front/src/game/components/HelpOverlay.vue:134
  - front/src/game/components/panel/help/Manual.vue:132
  - front/src/game/help/store.js:28-30
  - lib/portal/controllers/help_controller.ex:13
  - lib/data/game/content/calendar.ex:1-13
  - lib/game/instance/time/time.ex:45-48
  - front/src/utils/calendar.js:10-20
  - front/src/game/components/navbar/Calendar.vue:1-17
  - front/src/locales/en/data.json:439-456
  - lib/game/instance/stellar_system/stellar_system.ex:1833
status: reviewed
---
A tick is the game's unit of time. Income, growth and construction are all measured in ticks.

## Game speed

How long a tick lasts depends on the game's speed. A faster game fits more ticks into each real hour.

{table:speeds}

A daily runs on its own faster clock, which is not in this table.

## Ticks and hours

Every rate and duration in this manual is shown in ticks or in hours. For example, each whole point of [[population]] pays {rate:system_population_taxes_factor|credits} in [[taxes]].

An hour here is a real hour. So the same rate earns more in each real hour of a faster game. In a daily, the manual shows Legacy numbers, and its hours are Legacy hours.

You choose which unit you see. On the public site, a switch picks it. In a game, the manual uses the "Income display" setting from your account settings instead.

## The calendar

The date in the top bar is flavor. This manual never uses its days, months or years for rates or durations.

One tick is one day on that calendar. A month has 20 calendar days and a year has 24 months. A calendar year lasts {duration:480}. The months run from α-Tetran to ζ-Quadrinople.

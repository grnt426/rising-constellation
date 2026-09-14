---
title: Production
icon: resource/production
kind: mechanic
guide: system-outputs
terms: [production, base production, build queue]
related: [system-outputs, system-penalties, siege, star-systems, stellar-bodies]
sources:
  - lib/game/instance/stellar_system/stellar_system.ex:1004-1006
  - lib/game/instance/stellar_system/stellar_system.ex:1126-1202
  - lib/game/instance/stellar_system/stellar_system.ex:1819-1840
  - lib/game/instance/stellar_system/production_queue.ex:54-68
  - lib/game/instance/stellar_system/production_item.ex:34-40
  - lib/game/instance/player/player.ex:1001-1060
  - lib/data/game/content/constant-slow.ex:7-8
status: reviewed

---
{icon:resource/production} Production is what a system uses to build. It never leaves the system.

## What it does

- Production goes into the first item of the system's build queue. Buildings, repairs and ships all use it.
- When a building or repair finishes, the leftover production moves on to the next item.
- When a ship finishes, its leftover production is lost.
- With an empty queue, production is lost. It is not saved for later.
- At 0 production, the queue stops.

## Base production

Every system starts with {rate:system_base_production|production} before bonuses. Your [[star-systems|capital]] starts with {rate:system_capital_base_production|production} instead. The production breakdown calls this {ui:resource-detail.misc.initial}.

## Buildings that produce production

Some buildings make more on a body with a high {name:bonus_pipeline_in.body_ind}. See [[stellar-bodies]].

{table:buildings_by_output sys_production}

## Other sources of production

{table:bonus_sources sys_production}

A besieged system makes no production. See [[system-penalties]] and [[siege]].

Your empire never receives production, not even from a dominion. See [[dominion-tax-rate]].

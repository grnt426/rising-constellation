---
title: Stellar bodies
guide: star-systems
terms: [stellar body, planet, habitable planet, barren planet, moon, asteroid, gas giant, asteroid belt, tile, infrastructure tile, potential, Industrial Potential, Scientific Potential, Appeal Potential, star type]
aliases: [star-types#star-types, tiles#body-types, infrastructure-tile#the-infrastructure-tile, potentials#potentials]
related: [star-systems, housing, workforce]
sources:
  - lib/data/game/content/stellar-body.ex:1-72
  - lib/data/game/content/stellar-system.ex:1-42
  - lib/game/instance/stellar_system/stellar_body.ex:20-80
  - lib/game/instance/stellar_system/stellar_system.ex:101-107
  - lib/game/instance/stellar_system/stellar_system.ex:110-114
  - lib/game/instance/stellar_system/stellar_system.ex:246-249
  - lib/game/instance/stellar_system/stellar_system.ex:1431-1441
  - lib/game/instance/stellar_system/stellar_system.ex:1772-1778
  - lib/game/instance/stellar_system/starter_stellar_system_data.ex
  - lib/data/game/mutator.ex:869-913
  - lib/rc/help/format.ex:186-214
  - lib/rc/help/tables.ex:163-173
  - lib/rc/help/tables.ex:266-282
  - lib/game/instance/stellar_system/stellar_system.ex:348
  - lib/game/instance/stellar_system/stellar_system.ex:357-362
  - lib/game/instance/stellar_system/tile.ex:20-34
status: reviewed

---
Stellar bodies are the planets, moons and other objects in a star system. Your buildings go on their tiles.

{shot:system-body#potentials,tiles,infrastructure|A habitable planet with its three potentials (1), its tiles (2) and its infrastructure tile (3).}

## Body types

Each body is rolled within these ranges when the galaxy is created.

{table:stellar_bodies}

## The infrastructure tile

Tile 1 of every planet is its infrastructure tile. Only an infrastructure building goes there. That is the {name:building.infra_open} on a habitable planet and the {name:building.infra_dome} on a barren planet. Moons and asteroids have no infrastructure tile.

## Potentials

Every body with tiles has three potentials: {name:bonus_pipeline_in.body_ind}, {name:bonus_pipeline_in.body_tec} and {name:bonus_pipeline_in.body_act}. Some buildings make more on a body with a high potential.

### Buildings that scale with {name:bonus_pipeline_in.body_ind}

{table:buildings_by_input body_ind}

### Buildings that scale with {name:bonus_pipeline_in.body_tec}

{table:buildings_by_input body_tec}

### Buildings that scale with {name:bonus_pipeline_in.body_act}

{table:buildings_by_input body_act}

## Star types

The star type sets how many bodies a system has, not counting moons and asteroids.

{table:star_types}

Some game modes change the body and star rolls. Outside a daily, your first system always has the same bodies, so it can fall outside these ranges. See [[star-systems]].

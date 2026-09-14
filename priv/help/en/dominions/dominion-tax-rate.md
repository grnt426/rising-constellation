---
title: Dominion Tax Rate
guide: dominions
terms: [dominion tax rate, dominions tax rate, dominion income]
related: [dominions, credit, technology, ideology, system-penalties]
sources:
  - lib/game/instance/player/player.ex:1012-1015
  - lib/game/instance/player/player.ex:1039-1053
  - lib/game/instance/player/stellar_system.ex:47-53
  - lib/game/core/bonus.ex:62-87
  - lib/game/instance/stellar_system/stellar_system.ex:18-30
  - lib/game/instance/stellar_system/stellar_system.ex:1332-1392
  - lib/data/game/content/faction.ex:48-50
  - lib/data/game/content/doctrine-slow.ex:139-180
  - front/src/locales/en/game.json:1581
status: reviewed

---
The dominion tax rate is the share of each dominion's [[credit]], [[technology]] and [[ideology]] that you receive.

For example, at a 30 % rate, a dominion that makes {rate:500|credits} pays you {rate:150|credits}.

- The rate starts at 30 %.
- The share is taken from the dominion's output after its own [[system-penalties|penalties]].
- A dominion's production and defense are never shared.
- A dominion with negative output lowers your income by its share, however low that goes.

{shot:empire-credit-tooltip#dominions|The highlighted group is the credit each dominion pays you.}

## What changes the rate

Each bonus adds its points straight to the rate, unlike a [[bonus-stacking|percentage bonus]]. For example, 30 % + 20 % = 50 %.

{table:bonus_sources dominion_rate}

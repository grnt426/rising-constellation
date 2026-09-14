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
- Only those three resources are shared. You never receive any of a dominion's production or defense.
- If a dominion's output is negative, your share of it is negative too. That share is taken off your income, with no floor on how low it goes.

In your empire's income breakdowns, this income is grouped under {ui:resource-detail.type.dominion}.

{shot:empire-credit-tooltip#dominions|The highlighted group in the credit breakdown lists what each dominion pays you.}

## What changes the rate

Each bonus below adds its points straight onto the rate, unlike a [[bonus-stacking|percentage bonus]]. For example, a +20 % bonus raises the 30 % starting rate to 50 %. The dominion that makes {rate:500|credits} then pays you {rate:250|credits}.

{table:bonus_sources dominion_rate}

---
title: How prices grow
kind: mechanic
terms: [Cost Increase Factor, price increase]
aliases: [patent-price, lex-price, cost-increase-factor, lex-slot-price#lex-slots]
related: [patents, lexes]
length: long
length_reason: the brief gives it three price rules (patents and lexes, the game modifiers, lex slots) and the calculator line, one short sentence each
sources:
  - lib/game/instance/player/player.ex:461-492
  - lib/game/instance/player/player.ex:476-477
  - lib/game/instance/player/player.ex:494-522
  - lib/game/instance/player/player.ex:506
  - lib/game/instance/player/player.ex:524-542
  - lib/game/instance/player/player.ex:155
  - lib/game/instance/mutators.ex:63
  - lib/data/game/mutator.ex:816-834
  - lib/data/game/content/constant-slow.ex
  - lib/data/game/content/constant-medium.ex
  - lib/data/game/content/constant-fast.ex
  - front/src/game/components/mini-panel/PatentMiniPanel.vue:33-40
  - front/src/game/components/mini-panel/PatentMiniPanel.vue:186-188
  - front/src/game/components/mini-panel/DoctrineMiniPanel.vue:128-140
  - front/src/game/components/mini-panel/DoctrineMiniPanel.vue:269-273
  - front/src/game/calc/env.js:41-47
  - front/src/game/calc/engine.js:57
status: reviewed
---
Every [[patents|patent]] and every [[lexes|lex]] you buy makes the next one of its kind dearer. [[lex-slots|Lex slots]] get dearer too, by their own rule.

## Patents and lexes

Each patent and each lex has a base price, shown on its own page. Patents cost [[technology]] and lexes cost [[ideology]].

- Every patent you own adds the same share of the next patent's base price to its price. Each patent's page shows that share next to its base price.
- Lexes work the same way, with their own count. Patents never raise lex prices, and lexes never raise patent prices.
- Every purchase counts, upgrade and unit-size patents included.
- In the patent panel and the lex panel, {ui:minipanel.patent.price_factor} is the extra on your next purchase, as a percent of the base price. It is the table's Price factor above ×1, before any game modifier.

The table prices one patent, then one lex, at several purchases of their kind. The row for the 10th purchase is their price when you already own nine of their kind.

{table:price_scaling}

The {name:mutator.open_science} and {name:mutator.lost_sciences} game modifiers halve or double patent prices, but never lex prices.

## Lex slots

Each new [[lex-slots|lex slot]] costs twice the one before, up to a maximum price. The table's last row is that maximum, and every later slot costs it too. Buying a slot never changes the price of a lex.

{table:lex_slot_costs}

In the calculator (X, see [[hotkeys]]), the words "lex slot" stand for the price of your next slot.

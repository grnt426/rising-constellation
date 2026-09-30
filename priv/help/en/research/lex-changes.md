---
title: Changing active lexes
kind: mechanic
guide: lexes
terms: [lex change, wait, cooldown]
aliases: [lex-cooldown, policy-cooldown]
related: [lexes, agent-limits, system-limits]
length: long
length_reason: the brief gives this leaf the wait rule, what counts as a change, the limits check on a change and one edge case, each a sentence a player needs
sources:
  - lib/game/instance/player/player.ex:155-157
  - lib/game/instance/player/player.ex:544-593
  - lib/game/instance/player/player.ex:494-542
  - lib/game/instance/player/player.ex:936-980
  - lib/game/core/cooldown-value.ex:35-37
  - lib/data/game/content/constant-slow.ex:26-27
  - lib/data/game/content/constant-medium.ex
  - lib/data/game/content/constant-fast.ex
  - front/src/game/components/mini-panel/DoctrineMiniPanel.vue:37-86
  - front/src/game/components/mini-panel/DoctrineMiniPanel.vue:276-291
  - front/src/game/components/mini-panel/DoctrineMiniPanel.vue:373-452
status: reviewed
---
After you apply a new set of [[active-lexes|active lexes]], you must wait before you can change them again.

## The wait

Each change starts a wait of {duration:initial_update_policies_cooldown}, plus {duration:update_policies_cooldown_factor} for every change you have made so far, this one included. So each wait is longer than the last. The count never resets for the rest of the game. Your first change has no wait before it.

{shot:lex-panel-wait#cooldown|During a wait, the lex panel's stamp shows a ring, and the countdown above it shows the time left.}

{table:lex_change_waits}

The lex panel shows the wait that applying now would start. See [[lexes]]. During a wait you can't change your active lexes, but you can still buy lexes and lex slots.

## What counts as a change

Every change you apply counts, even one that only removes lexes. Buying a lex or a lex slot is not a change. A change that is refused starts no wait.

## What a change can't do

A change is refused if it would leave you with more systems, dominions, Navarchs, Erased or Siderians than your new limits allow. Only agents on the board count, not those in your deck. To drop a lex that one of them needs, first give up a system or dominion, or put an agent back in your deck. See [[administrative-operations]], [[system-limits]] and [[agent-limits]].

## Edge cases

- Applying more lexes than you have lex slots is refused. The panel lets you pick more, so you can decide which ones to drop.

---
title: Lexes
kind: guide
length: long
length_reason: the brief has nine sections, including the wait chart with the panel's own wait line and the lex panel's controls, which only this guide covers
terms: [lex, lexes, active lex, lex slot, Lex slots]
aliases: [lex#what-a-lex-is, lex-slots#lex-slots, active-lexes#active-lexes, lex-tree#the-lex-tree]
related: [lex-changes, agent-limits, price-scaling, ideology, system-limits, traditions, patents]
sources:
  - lib/game/instance/player/player.ex:148-162
  - lib/game/instance/player/player.ex:494-522
  - lib/game/instance/player/player.ex:524-542
  - lib/game/instance/player/player.ex:544-593
  - lib/game/instance/player/player.ex:1046-1057
  - lib/game/instance/player/player.ex:1101-1113
  - lib/game/instance/player/agent.ex:562-599
  - lib/data/game/content/bonus-pipeline-out.ex:94-122
  - lib/data/game/content/doctrine-slow.ex:6-27
  - lib/data/game/content/doctrine-medium.ex
  - lib/data/game/content/doctrine-fast.ex
  - front/src/game/components/mini-panel/DoctrineMiniPanel.vue:12-23
  - front/src/game/components/mini-panel/DoctrineMiniPanel.vue:27-126
  - front/src/game/components/mini-panel/DoctrineMiniPanel.vue:203-230
  - front/src/game/components/mini-panel/DoctrineMiniPanel.vue:276-291
  - front/src/game/components/mini-panel/DoctrineMiniPanel.vue:314-321
  - front/src/game/components/mini-panel/DoctrineMiniPanel.vue:325-452
  - front/src/game/components/mini-panel/DoctrineMiniPanel.vue:454-460
  - front/src/game/components/card/DoctrineCard.vue:62-121
  - front/src/game/Game.vue:12-13
status: reviewed
---
## What a lex is

A lex is a law for your whole empire, bought with [[ideology]]. A lex you own does nothing until it is active. Many lexes have a drawback next to their benefit. Each lex's own page lists both.

## The lex tree

Every lex except the first needs one lex before it, its ancestor. The first is [[lex/agent]], in the {name:doctrine_class.root} branch.

The rest of the tree is split into more branches, which differ by game mode (see [[game-time]]):

- Legacy and Tactic: {name:doctrine_class.expansion}, {name:doctrine_class.admiral}, {name:doctrine_class.spy}, {name:doctrine_class.speaker}
- Flash: {name:doctrine_class.expansion}, {name:doctrine_class.character}

## Buying a lex

You need the lex's ancestor and enough ideology. Every lex you own makes the next one dearer. See [[price-scaling]].

A lex is yours for the rest of the game. You can't sell it back, and there is no refund.

A lex's card also has {ui:card.doctrine.buy_and_activate}. It buys the lex and picks it for your next change of active lexes. You still apply that change yourself, as the next sections explain.

## Active lexes

Only active lexes give their effects. Each one takes a lex slot. You choose them by picking lexes you own in the lex panel, then applying that set. A new set works at once for your empire, every system, every dominion and every agent on the board.

## Lex slots

You start with one lex slot. The {ui:minipanel.doctrine.buy_slot} button buys another with ideology, at once. There is no limit on the number of slots. Each slot costs more than the one before, up to a maximum price. See [[price-scaling]].

## Changing your active lexes

You pick a new set of lexes in the lex panel, then apply it. After each change, you must wait before the next one. That wait grows with every change for the rest of the game.

{chart:lex_change_waits changes=30|The wait each change starts, from your first change to your 30th.}

While you have a change picked, the lex panel shows how long applying now would lock your lexes. See [[lex-changes]] for the exact waits and what counts as a change.

## Limits

Active lexes raise your System, Dominion, Navarch, Erased and Siderian Limits, and [[lex/agent]] is the first to raise your agent limits above zero. See [[system-limits]] and [[agent-limits]]. A change that would leave you over one of those limits is refused. See [[lex-changes]].

## The lex panel

Press L to open the lex panel. See [[hotkeys]]. Once you own a lex, the panel has one tab per branch other than {name:doctrine_class.root}, and each tab starts from {name:doctrine.agent}.

- Click a lex you can buy to buy it. There is no confirm.
- Click a lex you own to pick it. Click a picked lex to take it out.
- {ui:minipanel.doctrine.apply_policies} applies your picks. If you pick fewer lexes than you have slots, it asks for a second click.
- {ui:minipanel.doctrine.buy_slot} buys a lex slot, with no confirm.
- The {ui:minipanel.doctrine.reset_policies} button puts your picks back to your active lexes. The {ui:minipanel.doctrine.clear_policies} button takes out all your picks.
- While a wait runs, you can't pick or take out lexes. See [[lex-changes]].
- Lexes you picked but didn't apply are dropped when you close the panel.

On a phone, tapping a lex opens its card instead of buying it.

## All lexes

{table:lexes_list}

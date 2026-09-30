---
kind: catalog
status: reviewed
sources:
  - lib/data/game/content/doctrine-slow.ex
  - lib/game/instance/player/player.ex:494-519
  - lib/game/instance/player/player.ex:660-684
  - lib/game/instance/player/player.ex:1046-1066
  - lib/data/game/mutator.ex:365-379
---
Without the {name:mutator.open_court} game modifier, your [[agent-limits|agent limits]] start at 0. No agent can join the board until an active lex raises the limits.

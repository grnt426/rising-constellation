---
kind: catalog
status: reviewed
sources:
  - lib/data/game/content/doctrine-slow.ex
  - lib/game/core/bonus.ex:38-104
  - lib/game/instance/stellar_system/stellar_system.ex:1881-1925
  - lib/data/game/content/bonus-pipeline-in.ex:165-171
  - lib/data/game/content/building-slow.ex
  - lib/data/game/content/building-fast.ex
---
This lex's percentage raises the system's mobility, but not the [[mobility|Mobility bonus]] to credits. That bonus counts mobility from before percentage bonuses, unless a {name:building.finance_open}, a {name:building.monument_dome} or, outside Flash, a {name:building.finance_orbital} stands in the system.

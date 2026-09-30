---
kind: catalog
status: reviewed
sources:
  - lib/data/game/content/doctrine-slow.ex
  - lib/game/instance/stellar_system/stellar_system.ex:1921-1928
  - test/game/instance/stellar_system/mobility_credit_test.exs
  - lib/data/game/content/bonus-pipeline-in.ex:165-171
---
It raises the system's mobility, not the credits each point of mobility brings. The [[mobility|Mobility bonus]] still grows, because it counts the extra mobility. A system with no mobility gets nothing from it.

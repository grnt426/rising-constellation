---
kind: catalog
status: reviewed
sources:
  - lib/data/game/content/building-slow.ex
  - lib/game/instance/stellar_system/stellar_system.ex:453-477
  - lib/game/instance/stellar_system/stellar_system.ex:565-595
  - lib/game/instance/stellar_system/stellar_system.ex:1144-1176
  - lib/game/instance/stellar_system/stellar_system.ex:1734-1768
  - lib/game/instance/stellar_system/tile.ex:44-46
  - front/src/game/components/galaxy/system/Production.vue:222-231
  - front/src/game/components/galaxy/system/Production.vue:386-394
---
The ships it allows can still be ordered while it is being [[upgrades|upgraded]]. Ships already in the [[construction-queue|construction queue]] still finish if it is later [[damaged-buildings|damaged]] or [[destroy-building|destroyed]].

---
title: Traditions
kind: mechanic
terms: [tradition, traditions]
aliases: [tradition]
related: [lexes, system-outputs, game-time]
sources:
  - lib/data/game/content/faction.ex:11-28
  - lib/game/instance/player/player.ex:1115-1124
  - front/src/game/components/panel/faction/Overall.vue:16-32
  - front/src/portal/pages/Instance.vue:403-412
  - front/src/game/components/generic/ResourceDetail.vue:80-82
status: reviewed
---
A tradition is a permanent bonus or drawback that comes with your faction. Each faction has four: three bonuses and one drawback. They are always on for every member of the faction, from the first tick to the end of the game. You can't change them. They are the same in Legacy, Tactic and Flash games.

{shot:faction-traditions#traditions|The faction panel lists your faction's four traditions.}

The faction picker also shows them before you join.

In resource tooltips, tradition effects appear under {ui:resource-detail.type.tradition}. See [[system-outputs]] for how they add up. Legacy and Tactic games also have a lex named [[lex/upgrade_xp]]. It is a lex, not a tradition.

{table:traditions}

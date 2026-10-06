---
title: Neural rewiring
kind: mechanic
guide: agent-training
icon: agent/speaker
terms: [neural rewire, rewire, rewiring, skill points, respec]
aliases: [neural-rewire, rewires, skill-reallocation]
related: [university-courses, agent-training]
sources:
  - lib/game/instance/character/training.ex
  - lib/game/instance/character/character.ex:15
  - lib/game/instance/player/player.ex
  - lib/data/game/content/constant-slow.ex
  - front/src/game/components/card/CharacterCard.vue
status: draft
---
A neural rewire lets you move one skill point of an agent to another skill. Agents earn rewires on [[university-courses]].

- You spend rewires while the agent is in your deck.
- One rewire moves one point. You take it from one skill and give it to another.
- No skill can go above 12.
- No skill can go above the agent's main skill.
- You can take points from the main skill. The other skills must then fit under its new value.

For example, with two rewires:

    skills 5, 3, 1 → 7, 2, 0

An agent with a rewire left takes no new duty. You cannot make it a governor, send it to the field or send it back to a school. Spend every rewire first, or discard the ones you do not want.

Discarded rewires are lost for good. The agent's skills stay as they are.

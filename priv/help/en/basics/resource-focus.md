---
title: Your resource focus
kind: primer
terms: [mid game, resource focus, specialization, governor skills, agent training, agent experience]
related: [strategy-basics, early-game, late-game, dominions, administrative-operations, credit, technology, ideology]
sources:
  - lib/game/instance/stellar_system/stellar_system.ex:869-877
  - lib/game/instance/stellar_system/stellar_system.ex:1897-1936
  - lib/game/instance/player/player.ex:345-359
  - lib/game/instance/player/player.ex:657-734
  - lib/game/instance/player/player.ex:1057-1098
  - lib/game/instance/player/agent.ex:182-230
  - lib/game/instance/character/character.ex:824-896
  - lib/game/instance/character/character.ex:1137-1213
  - lib/game/instance/character/actions/loot.ex:37-128
  - lib/game/instance/character/actions/infiltration.ex:9-81
  - lib/game/instance/character/actions/sabotage.ex:28-109
  - lib/game/instance/character/actions/assassination.ex:28-137
  - lib/game/instance/character/actions/conversion.ex:33-118
  - lib/game/instance/character/spy.ex:6-102
  - lib/game/fight/manager.ex:112-123
  - lib/data/game/content/character.ex:28-135
  - lib/data/game/content/constant-slow.ex:32-55
  - lib/data/game/content/building-slow.ex
  - priv/planner/presets/basics-mid.json
  - docs/system-specialization-analysis.md
status: reviewed
---
Learn how a system grows into a specialist, when to hand a system to a dominion, and how agents gain levels.

In a Legacy match this is the mid game, roughly the fifth to the twelfth real day.

## From broad to focused

New patents now unlock buildings that do one thing well, such as the {name:building.research_open}.

A focused system is not rebuilt from scratch. In official matches the best systems kept the same base as everyone else. What set them apart was a few buildings and the governor.

**Match buildings to the site.**

- Credits come from population and from credit buildings. Many of those pay for the population of their planet. Later [[mobility]] adds more. See [[credit]].
- Technology comes from research buildings on bodies with a high {name:bonus_pipeline_in.body_tec}. See [[technology]].
- In a system, ideology comes only from ideology buildings. Many scale with the population of their planet, or with its {name:bonus_pipeline_in.body_act}. See [[ideology]].

**Match the governor to the focus.** Each system can have one governor. Use {ui:galaxy.system.properties.deploy_governor} in the system view. A governor uses a slot under the limit of its agent type. Its skills only help the system it governs. An agent's specialization decides where most of its skill points go.

- An Erased with the Broker specialization raises the system's credits.
- A Siderian with the Scientist specialization raises technology. The Ideologist raises ideology.
- A Navarch with the Shipowner specialization raises production.

**Choose early.** Deploy your governors early so they start to gain levels. Swap a governor out if it does not earn the skill points you need.

## Hand a system to a dominion

Your System Limit is small. A weak system holds a slot that a better site could use.

{ui:system.transform_to_dominion} turns one of your systems into a [[dominions|dominion]]. See [[administrative-operations]].

- It costs ideology. Each use raises the price of the next one.
- It needs a free slot under your Dominion Limit, which starts at zero. Lexes such as [[lex/dominion_1]] raise it.
- It frees one slot under your System Limit.
- You keep a share of the dominion's credits, technology and ideology. See [[dominion-tax-rate]].
- The dominion builds by itself. You can no longer order buildings or ships there. See [[self-development]].
- Its governor returns to your deck.

It also has costs that are easy to miss.

- It cannot be done to your last system.
- Your first system loses its starting production bonus for good.
- The system loses the defense it had from its population.
- A Siderian's {ui:galaxy.system.actions.make_dominion} can take a dominion. It cannot take a system.
- Ships on order there are cancelled.

{ui:system.transform_to_system} turns it back. That costs ideology the same way and needs a free system slot.

Many players do this with their first system. In the longer official matches, half of all first systems ended as dominions.

Some players go further and hold many dominions. That is going wide. It often goes with the broad way to play from [[strategy-basics]].

## Train your agents

An agent gains experience from what it does. Each level gives a skill point. Each level also raises its wage.

- An action gives experience even when it fails. A success gives more.
- A governor always earns {rate:character_passive_xp_gain|experience}.
- An agent that waits on the map gains nothing.

**Navarchs** can {ui:galaxy.system.actions.loot} autonomous systems nearby. The fleet needs ships, and only some ships add {ui:card.ship.bombing}. A success brings credits, technology and ideology. The fleet takes damage that grows with the system's [[defense]]. The system pays less for a while after each attempt. A fleet that fails flees. Battles give experience too.

Autonomous systems and dominions get no defense from their population. That makes them softer than a player's system.

**Erased** can use {ui:galaxy.system.actions.infiltrate} on autonomous systems and on other factions' dominions. Most players train them on autonomous systems first. Each attempt costs cover, which only slowly rebuilds over time. An Erased whose cover falls too low is discovered. It cannot act, move or return to your deck until it recovers. Cover only recovers while the Erased has no orders.

**With teammates.** {ui:galaxy.selection.plan.action.sabotage}, {ui:galaxy.system.actions.assassination} and {ui:galaxy.system.actions.conversion} also work on a teammate's agents. Some teams use that to train. Agree on it first, because a success is real.

- {ui:galaxy.selection.plan.action.sabotage} damages or destroys ships.
- {ui:galaxy.system.actions.assassination} removes the agent for good. A Navarch with ships is replaced by a level 1 stand-in that keeps the fleet.
- {ui:galaxy.system.actions.conversion} moves the agent to you, but never its ships. You can donate it back on the market. The teammate who claims it pays a market tax and needs a free slot.

More pages on agents are coming. Until then, ask your teammates how they train theirs.

## The example system

This is Lyceum on day twelve.

{shot:planner-basics-mid#accelerator,governor,yields|Lyceum in the system planner on day twelve.}

1. An {name:building.research_open} now stands on the second planet. Of the two habitable planets, it has the higher {name:bonus_pipeline_in.body_tec}.
2. The same Siderian has grown. Knowledge, the skill of a Scientist, now has 7 points.
3. Technology has doubled since day five. Ideology has grown even more.

Most buildings went up a level. Three were replaced.

This player did not pick one focus. A {name:building.monument_dome} and three {name:building.ideo_dome} buildings now make ideology beside the research. See what one focus would give. {planner:basics-mid|Open Lyceum on day twelve in the system planner} and swap the ideology buildings for something else.

Next: [[late-game]].

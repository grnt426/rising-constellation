---
title: The early game
kind: primer
terms: [early game, second system, scouting, valuable system, potentials]
related: [strategy-basics, resource-focus, late-game, colonization, system-limits, stellar-bodies, population]
sources:
  - lib/game/instance/stellar_system/stellar_system.ex:387-417
  - lib/game/instance/stellar_system/stellar_system.ex:1468-1497
  - lib/game/instance/stellar_system/starter_stellar_system_data.ex
  - lib/game/instance/character/actions/colonization.ex:14-97
  - lib/game/instance/character/actions/jump.ex:237-251
  - lib/game/instance/character/actions/make_dominion.ex:14-40
  - lib/game/instance/character/actions/conquest.ex:21-57
  - lib/game/instance/faction/stellar_system.ex:58-99
  - lib/game/instance/faction/faction.ex:126-138
  - lib/game/instance/faction/galactic_survey.ex:108-168
  - lib/game/instance/player/player.ex:421-459
  - lib/game/instance/player/player.ex:661-675
  - lib/game/instance/character/character.ex:113-117
  - lib/data/game/content/stellar-body.ex
  - lib/data/game/content/building-slow.ex
  - lib/data/game/content/doctrine-slow.ex:6-27
  - priv/planner/presets/basics-early.json
  - docs/system-specialization-analysis.md
status: reviewed
---
Learn how to grow your first systems broadly while you look for the system that will carry your focus later.

In a Legacy match the early game is roughly the first five real days.

## Build a bit of everything

Your first patents only unlock basic buildings. At this stage every player's systems look alike.

- Housing lets your [[population]] grow. Population pays credits and gives you [[workforce]].
- Every building except housing uses workforce. If they use more than the system has, all its outputs drop.
- A planet needs its [[infrastructure-building|infrastructure building]] before anything else can go on it. Your first system starts with one, on one planet.
- On a planet, no building can be upgraded above the level of that infrastructure building. See [[upgrades]].
- A growing population lowers [[stability]]. Some stability buildings will be needed.

Cheap buildings that pay back fast are the usual start. Two of them go on moons and asteroids.

- {name:building.factory_orbital} are the best early credits where the {name:bonus_pipeline_in.body_ind} is 4 or 5.
- An {name:building.research_orbital} is your early technology where the {name:bonus_pipeline_in.body_tec} is 3 or more. Its patent costs more technology than you start with, so it is not your first purchase.

You will want both early. Potentials are explained further down this page.

## Found a second system

A second system is the first big step. You need all of these.

- The patent [[patent/transport_1]], then a {name:ship.transport_1}. The ship needs no shipyard. It costs credits, technology and a lot of production. A system builds one order at a time, so the ship holds up the rest.
- A Navarch on the map to carry the ship. Your Navarch Limit starts at zero. [[lex/agent]] raises it. See [[agent-limits]].
- A free slot under your System Limit. [[lex/system_1]] gives the first extra slot. See [[system-limits]].
- A second lex slot. A lex only works while it sits in a slot, and both lexes above must be active together. You start with one slot. The second costs {const:initial_policy_slot_cost} ideology. See [[lexes]].
- An uninhabited system in a sector your faction holds, or in a sector next to one. See [[colonization]].

Your starting agent may not be a Navarch. Then you hire one in the {ui:minipanel.character_market.title} first.

The Navarch must wait in the system that builds the ship. It stays docked there until the ship is done.

Most players have a second system by day five.

## Borrow to get there sooner

The ship's technology and the lex's ideology are far more than you start with. A teammate with a surplus can donate either one. See [[strategy-basics]] for how. Production cannot be donated.

The same goes for agents. The {ui:minipanel.character_market.title} sometimes offers a high-rank agent you cannot afford yet. Teammates can chip in for those too.

Say what you need in your faction's chat. Give back when your own income grows.

## How to spot a valuable system

You see nothing inside a system until an agent of your faction has been there once. After that first visit you see its bodies, their tiles and their potentials for good. Any agent type will do. Systems your own faction holds are always visible.

Three things tell you what a system can become.

- **Tiles.** Each tile holds one building. Your first system has 34. In official matches the best late systems had about 50.
- **Body types.** Habitable planets and barren planets take different buildings. Moons and asteroids share a third set. See [[stellar-bodies]].
- **Potentials.** Each planet, moon and asteroid has three potentials. A higher number is better, and 5 is the top.

{shot:system-body#potentials|A planet's three potentials sit under its name.}

Many buildings multiply a potential of the body they stand on.

- {name:bonus_pipeline_in.body_ind} feeds production buildings such as the {name:building.mine_dome}. It also feeds the {name:building.factory_orbital}, which pay credits.
- {name:bonus_pipeline_in.body_tec} feeds research buildings such as the {name:building.research_open}.
- {name:bonus_pipeline_in.body_act} feeds buildings such as the {name:building.hab_open_rich} for credits and the {name:building.ideo_credit_open} for ideology.

Other buildings count population instead. The {name:building.market_open} pays credits for the population of its planet. Those want planets with many tiles for housing.

A planet with a high {name:bonus_pipeline_in.body_tec} is a technology site waiting to happen. A system with many planet tiles has room for housing, which suits credits and ideology.

The {ui:panel.empire.galactic_survey} tab of the empire panel lists every system your faction has scouted. You can sort it by each potential.

Autonomous systems are a second way to grow.

- A Siderian can take one as a dominion with {ui:galaxy.system.actions.make_dominion}. That needs a free slot under your Dominion Limit, which starts at zero.
- A Navarch with warships can take one as a system with {ui:galaxy.system.actions.conquer}. That needs a free slot under your System Limit.

Like a colony, the target must be in a sector your faction holds, or in a sector next to one.

You will need to decide whether to go wide or tall. Wide is many dominions and few systems. Tall is mostly systems and few dominions.

## The example system

Lyceum is a real system from an official match, renamed. A player colonized it in the first days. This is Lyceum on day five.

{shot:planner-basics-early#potentials,free-tile,governor,yields|Lyceum in the system planner on day five.}

1. The fourth planet has {name:bonus_pipeline_in.body_tec} 5 and {name:bonus_pipeline_in.body_ind} 5. That is what makes this system worth keeping.
2. Four planets still have a free tile.
3. The governor is a Siderian. Its Knowledge skill adds a share to the system's technology.
4. The system makes a little of everything, like most early systems.

The build is broad. Every planet has housing and a research building. Most also have something for credits or production.

This system could grow in many directions. {planner:basics-early|Open Lyceum on day five in the system planner} and see what you can do. Try to get the most ideology out of it, or the most technology, or both.

The planner only offers what this player had researched by then. Turn off "Limit to my patents" to see everything.

Then guess how the player developed Lyceum in the mid and late game. The next two pages show it.

Next: [[resource-focus]].

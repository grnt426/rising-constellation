---
title: The late game
kind: primer
terms: [late game, megastructure, fleet upkeep, bankruptcy, team banker, fleet holding]
related: [strategy-basics, early-game, resource-focus, stances, defense, stability, siege]
sources:
  - lib/game/instance/player/player.ex:421-459
  - lib/game/instance/player/player.ex:1244-1270
  - lib/game/instance/player/player.ex:1297-1348
  - lib/game/instance/player/market.ex:169-178
  - lib/game/instance/player/market.ex:486-538
  - lib/game/instance/player/market.ex:605-637
  - lib/game/instance/character/character.ex:441-453
  - lib/game/instance/character/character.ex:850-856
  - lib/game/instance/character/agent.ex:60-62
  - lib/game/instance/character/army.ex:237-326
  - lib/game/instance/character/actions/fight.ex:53-65
  - lib/game/instance/character/actions/fight.ex:338-383
  - lib/game/instance/character/actions/fight.ex:541-555
  - lib/game/instance/character/actions/jump.ex:70-73
  - lib/game/instance/character/actions/raid.ex:45-51
  - lib/game/instance/character/actions/encourage_hate.ex:29-96
  - lib/game/instance/character/actions/make_dominion.ex:36-124
  - lib/game/instance/character/actions/infiltration.ex:62-81
  - lib/game/instance/stellar_system/stellar_system.ex:474-492
  - lib/game/instance/stellar_system/stellar_system.ex:1200-1206
  - lib/game/instance/stellar_system/stellar_system.ex:1361-1395
  - lib/data/game/content/ship-slow.ex
  - lib/data/game/content/building-slow.ex
  - lib/data/game/content/doctrine-slow.ex:185-260
  - priv/planner/presets/basics-late.json
  - docs/system-specialization-analysis.md
status: reviewed
---
Learn how specialists reach their peak, why fleets cost more than one player earns, and how a team carries that load.

In a Legacy match the late game starts around the twelfth real day.

## Finish your focus

The last patents unlock the buildings that top off a specialist.

- The {name:building.monument_dome} pays ideology for the population of the whole system.
- The {name:building.high_factory_dome} pays production and technology from one barren planet.
- The {name:building.finance_orbital} and the {name:building.finance_open} pay credits for [[mobility]]. Both lower [[stability]].

Levels matter as much as new buildings. The last level of [[patent/infra_open]] lets the {name:building.infra_open} reach level 5. The other buildings on that planet can then follow. Barren planets and moons have patents of their own for that.

By the end, few systems make most of the output. In official matches, a quarter of all systems made two thirds of the technology and even more of the ideology.

That makes those systems targets. In the late game, a quarter of all build orders were for [[defense]], stability, Intelligence and Cybersecurity.

## Fleets

Warships are built in a system with a shipyard. Each warship class needs its own. The {name:building.shipyard_1_orbital} builds fighters and the {name:building.shipyard_4_orbital} builds capital ships.

- One of your Navarchs must wait in that system, with no orders, to receive the ships. It cannot move until they are finished.
- A ship costs credits when ordered, and most cost technology too. The system's production then builds it.
- No ship can be ordered in a system under [[siege]].
- A fleet holds {const:army_tile_count} squadrons.

Most teams build their warships in few systems with very high production. A Navarch governor with the Shipowner specialization helps there.

## Fleets cost more than you earn

Every finished ship costs credits all the time, for as long as it exists. A docked fleet costs the same as a moving one. Agents on the map and governors also draw a wage that grows with their level.

Big ships cost a lot. Two or three full fleets can cost more than all the credits one player makes. This is intended. Fleets are a team effort.

If your credits reach zero while your income is negative, you are bankrupt. The top bar shows "{ui:navbar.topbar.bankrupt}".

- Your agents go on strike and refuse new orders.
- Your Navarchs switch to the Deserter stance.
- You cannot order buildings or ships, or hire agents.

Nothing is destroyed. But your credits keep falling below zero, so the debt grows. It ends when your credits are above zero again, or when your income is no longer negative. Set your stances back afterward.

So fleet holders ask the team's bankers for credits, often and in large amounts. You can still {ui:minipanel.market.take.claim} a credit donation while bankrupt. Its tax is taken out of the donation.

## Who holds the fleets

A team has to balance three things.

- **Activity.** A fleet does the most in the hands of a player who is there to move it.
- **Credits.** A banker can pay for a fleet alone, but may not be the most active player.
- **Navarch slots.** Each fleet needs a Navarch. The Navarch Limit comes from active lexes. A Navarch that governs a system uses a slot too. See [[agent-limits]].

Fleets can change hands. You can donate a Navarch from the map with its fleet, while it has no orders. The taker needs a free Navarch slot and pays a tax in credits that grows with the fleet. From then on the taker pays the upkeep.

## Where fleets sit

A fleet does not add to a system's [[defense]]. It defends by fighting enemy fleets, and only in the system where it sits.

- The Navarch's stance decides when it fights. A new fleet is a Defender. It fights when an enemy starts to {ui:galaxy.system.actions.loot}, {ui:galaxy.system.actions.raid} or {ui:galaxy.system.actions.conquer} there. Two other stances also stop enemies as they arrive. See [[stances]].
- Teammates' fleets in the same system can join the battle, if their stance allows it.
- No stance stops a Siderian or an Erased. Those roll against the system's stability and Intelligence, or against the target agent's own Protection and Determination.
- A fleet without orders repairs itself, if it has ships that repair or its Navarch has Leadership points.
- Enemy S.L.S.D. only shows fleets that move. An enemy agent in the system still sees a parked fleet.

Decide with your team which systems need a fleet most.

## Choosing targets

A fleet can {ui:galaxy.system.actions.loot}, {ui:galaxy.system.actions.raid} or {ui:galaxy.system.actions.conquer} a system. See [[siege]].

The systems that hurt most to lose are a team's shipyard systems and its best credit, technology and ideology systems. That is as true for your rivals as for you.

Look before you strike. The more your faction sees of a system, the better you can judge it.

## Agents in the late game

This part of the manual is still short. More pages are coming.

- A Siderian's {ui:galaxy.system.actions.encourage_hate} lowers a system's stability. At zero stability or below, a system loses part of everything it makes.
- A Siderian's {ui:galaxy.system.actions.make_dominion} takes dominions and autonomous systems. It needs a free slot under your Dominion Limit. Low stability makes it easier.
- An Erased's {ui:galaxy.system.actions.infiltrate} shows your faction more of a system. In a system of another faction it also counts toward {name:victory.visibility}.
- An Erased's {ui:galaxy.system.actions.sabotage} hits a fleet where it sits.

These work best in groups and with timing. Ask your teammates for tips.

## The example system

This is Lyceum at the end of the match.

{shot:planner-basics-late#factory,accelerator,governor,yields,workforce|Lyceum in the system planner at the end of the match.}

1. A {name:building.high_factory_dome} stands on the fourth planet, the one with the two potentials of 5.
2. The {name:building.research_open} is at level 4.
3. The governor has 11 points in Knowledge. That alone adds more than half to the system's technology.
4. Technology has nearly doubled again since day twelve.
5. Only 64 of 90 workforce is in use.

Lyceum ended among the best technology systems of its match. It is good, not perfect.

Can you do better? {planner:basics-late|Open Lyceum at the end of the match in the system planner} and try. Raise the buildings that are still at level 3. Look at the unused workforce, the stability and the defense.

Back to [[strategy-basics]].

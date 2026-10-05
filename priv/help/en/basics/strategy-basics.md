---
title: Strategy basics
kind: primer
terms: [strategy, basics of play, teamwork, sharing resources, mutual aid, opening]
related: [early-game, resource-focus, late-game, game-time, patents, lexes]
sources:
  - lib/game/instance/victory/victory.ex:103-131
  - lib/game/instance/victory/victory.ex:180-208
  - lib/game/instance/victory/victory.ex:323-416
  - lib/game/instance/galaxy/sector.ex:51-95
  - lib/game/instance/galaxy/agent.ex:148-165
  - lib/game/instance/player/player.ex:148-162
  - lib/game/instance/player/player.ex:392-459
  - lib/game/instance/player/player.ex:476-477
  - lib/game/instance/player/player.ex:506
  - lib/game/instance/player/player.ex:524-542
  - lib/game/instance/player/player.ex:1100-1112
  - lib/game/instance/player/player.ex:1245-1270
  - lib/game/instance/player/market.ex:169-231
  - lib/game/instance/player/market.ex:357-386
  - lib/game/instance/player/market.ex:486-538
  - lib/game/instance/character/character.ex:113-121
  - lib/data/game/content/character.ex:49-51
  - lib/data/game/content/character.ex:93-95
  - lib/data/game/content/character.ex:137-139
  - lib/data/game/content/faction.ex:7-10
  - lib/data/game/content/constant-slow.ex:20-31
  - lib/data/game/content/patent-slow.ex:6-15
  - lib/data/game/content/patent-slow.ex:437-449
  - lib/data/game/content/patent-slow.ex:480-682
  - lib/data/game/content/doctrine-slow.ex:6-27
  - lib/data/game/content/ship-slow.ex:788-813
  - front/src/game/components/mini-panel/market/MarketSell.vue:16-36
  - docs/system-specialization-analysis.md
status: reviewed
---
Learn what your faction plays for, and how teams share resources to get moving faster.

This page and the three after it describe Legacy matches. They show how most teams play today. They are a starting point, not rules.

## What your faction plays for

A match is won by a faction. You win or lose with your team.

The {ui:navbar.topbar.victory_panel} button in the top bar opens the {ui:minipanel.victory.title} panel. It shows three paths. Each path has three milestones. Reaching a milestone gives your faction victory points.

- {name:victory.conquest} adds up the points of the sectors your faction holds. Sectors are worth different amounts.
- {name:victory.population} adds points for every system and dominion your faction holds. Bigger populations are worth more. See [[population-class]].
- {name:victory.visibility} counts how much your faction sees inside the systems of other factions. Erased agents raise that by infiltrating.

To take a sector, your faction needs more systems and dominions in it than any other faction. It must also outnumber the autonomous systems there.

A faction wins when it reaches the victory point target on that panel. If time runs out first, the faction in the lead wins.

## Three resources

Your systems make three resources that you can stock and share. See [[system-outputs]].

- {icon:resource/credit} **Credits** pay for buildings and ships. They also pay agent wages and fleet upkeep.
- {icon:resource/technology} **Technology** buys [[patents]]. Patents unlock buildings and ships. Most ships also cost technology.
- {icon:resource/ideology} **Ideology** buys [[lexes]] and lex slots. A lex raises your limits or adds a bonus while it is active in a slot.

Hiring an agent costs two of the three. A Navarch costs credits and technology. An Erased costs credits and ideology. A Siderian costs technology and ideology.

Production is different. It stays in its system and builds what you order there.

## One focus each

In Legacy matches today, most players focus on one resource and share it with their team.

Teams usually split into roles.

- A banker's systems make credits.
- A researcher's systems make technology.
- An ideologue's systems make ideology.
- A fleet builder uses production and credits to build fleets. They rely on the rest to fund the war effort.

Most players say what they plan to focus on at the very start of a match. No system is reserved for a player, so the team needs to know who should take which. It also keeps everyone from choosing the same resource.

Your systems still start out broad, whatever you choose. See [[early-game]].

Not everyone plays this way. A few strong players stay broad. They hold many systems and dominions and still supply the team. Both ways work, though we recommend you ask your team which roles they need filled.

## How sharing works

Open {ui:navbar.topbar.market_panel} in the top bar and choose {ui:minipanel.market.tabs.sell}. Under {ui:minipanel.market.category.aid}, pick "{ui:minipanel.market.types.aid_resources}".

- {ui:minipanel.market.aid.donation} puts credits, technology or ideology on offer for your faction. A teammate takes it with {ui:minipanel.market.take.claim}.
- {ui:minipanel.market.aid.request} asks for a resource. A teammate sends it with {ui:minipanel.market.take.fulfill}.
- You can also donate an agent, from your deck or from the map.

Only your faction sees {ui:minipanel.market.category.aid}. You can limit an offer to named teammates.

## Opening together

Every player starts with {const:player_starting_credit} credits, {const:player_starting_technology} technology and {const:player_starting_ideology} ideology. You also have one system, one lex slot and one agent in your {ui:minipanel.character_deck.title}. The agent's type depends on your faction.

No agent can leave the deck at first, because every agent limit starts at zero. [[lex/agent]] is the first lex that raises them. See [[agent-limits]].

The first patents and the first lex cost little. Each one you own makes the next one cost more. See [[price-scaling]].

Two early purchases cost far more than the rest.

- The {name:ship.transport_1} founds your second system. It costs credits, production and a lot of technology.
- [[lex/system_1]] raises your System Limit to two while it is active. It costs a lot of ideology. It also needs a second lex slot, so that [[lex/agent]] can stay active beside it.

[[early-game]] lists everything a second system needs.

This is where a team helps. A teammate who is ahead on technology or ideology can donate some. You reach your second system sooner and return the favor later. In official matches the first offers changed hands within hours of the start.

Warships work the same way. [[patent/shipyard_1]] is cheap and opens the first shipyard. The patents for bigger ships cost much more technology. Fleet builders often get that technology from teammates with a surplus.

Talk to your faction early. Ask what the team needs, and say what you are short of.

Next: [[early-game]].

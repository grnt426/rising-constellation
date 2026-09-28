---
title: System outputs
icon: resource/production
kind: guide
terms: [system outputs, outputs, bonus stacking, flat bonus, percentage bonus]
aliases: [bonus-stacking#how-bonuses-add-up]
related: [production, credit, technology, ideology, defense, system-penalties]
sources:
  - lib/game/core/bonus.ex:13-96
  - lib/game/instance/stellar_system/stellar_system.ex:1272-1392
  - lib/game/instance/stellar_system/stellar_system.ex:1819-1868
  - lib/game/instance/player/player.ex:1005-1060
  - lib/data/game/content/bonus-pipeline-in.ex
  - lib/data/game/content/building-slow.ex:1264-1320
  - lib/data/game/content/building-slow.ex:1522-1640
  - lib/data/game/content/building-slow.ex:1790-1845
  - front/src/game/components/galaxy/system/Properties.vue
status: reviewed
---
A system makes five outputs: production, credit, technology, ideology and defense. Each one goes to a different place.

{shot:system-properties#defense,credit,technology,ideology|The highlighted readouts are 1 defense, 2 credit, 3 technology and 4 ideology.}

## Where each output goes

- {icon:resource/production} Production stays in the system and builds its queue. See [[production]].
- {icon:resource/credit} Credit goes to your empire's stock. See [[credit]].
- {icon:resource/technology} Technology goes to your empire's stock. See [[technology]].
- {icon:resource/ideology} Ideology goes to your empire's stock. See [[ideology]].
- {icon:resource/defense} Defense stays in the system and protects it. See [[defense]].

Your [[dominions]] add a share of their credit, technology and ideology to your stock. See [[dominion-tax-rate]].

## Where an output comes from

An output adds up from these sources:

- Base values, like base production or [[taxes]].
- [[buildings|Buildings]], some of which grow with their body's [[stellar-bodies|potential]] or [[population]], or with the system's [[workforce]].
- Lexes, traditions and agent skills.

Finally, [[system-penalties|penalties]] can reduce the total.

A system has other lines too: [[mobility]], S.L.S.D., Intelligence, Cybersecurity and the starting experience of new ships. They belong to other chapters.

## How bonuses add up

A bonus is either flat, like +10, or a percentage, like +10 %.

- Flat bonuses add up first.
- Each percentage then adds its share of that flat total.
- Percentages add up. They do not multiply each other.
- A percentage adds nothing while the total is below zero.

Every output adds up in this order. For example, with production:

    flat bonuses:        {rate:100|production}
    add a +10 % bonus:   {rate:100|production} + {rate:10|production} = {rate:110|production}
    add a +20 % bonus:   {rate:100|production} + {rate:10|production} + {rate:20|production} = {rate:130|production}

A building that grows with the system's defense, mobility or workforce counts as a flat bonus. So percentages also apply to what it adds.

A bonus that turns one value into another, like the {ui:resource-detail.misc.population_mobility} turning mobility into credits, can miss that value's percentage bonuses. See [[mobility]].

# How players specialize their systems

Internal analysis, October 2026. Source material for tuning bot strategies and
for the player manual's "Basics of Play" pages. It is not a player-facing
document.

What the top-producing systems for credit, technology and ideology are built
from, how that changes from early to late game, and whether fleet-production
systems are the fortresses they are meant to be. Based on the four finished
official Legacy matches (June to September 2026).

**About the names.** Players are not named. Each player gets a role name per
match that hints at what they did in that match: "the Citadel Banker", "the
Ham'burger Castellan". A role name belongs to one match only. Two role names
in different matches may or may not be the same person, and this document
never says. System names are the real in-game names.

## What the data shows

1. **Specialization is a mid-game invention.** On day 5 the top quarter of
   systems produce 43 to 53% of each income type and are built like everyone
   else's capital. By the final readings they produce 59% of all credit, 67%
   of technology and 72% of ideology, and each type has its own recipe.
2. **A specialist is a signature building or two, a matching governor, and a
   sixth to a quarter of the workforce.** Erased govern 53% of top credit
   systems, Siderians 46 to 47% of top technology and ideology systems,
   Navarchs 56% of top production systems. The rest of each system is the
   same general-purpose base everyone builds.
3. **The long-term bet is placed between day 5 and day 12.** In Citadel, 76%
   of systems founded before day 8 finished in a top income quartile; 21% of
   those founded on day 14 or later did. Capitals drop out: half of them were
   turned into dominions, mostly between days 5 and 11.
4. **Fleet yards are few and unmistakable.** Nineteen systems took 90% of all
   warship production ordered in the three longer matches. Seventeen sit in
   the top production quartile and eighteen are run by a Navarch.
5. **The fortress around the yard is a personal habit, not the norm.** Seven
   of the nineteen yards reach the top quartile for defense, the same number
   for stability, S.L.S.D. and intelligence, and five for cybersecurity. Six
   are top-quartile in production and nothing else. The most productive yard
   in Citadel was destabilized into uprising, abandoned by its owner and
   taken by the enemy on the final day.

## Scope

An official match is one flagged as official in the Legacy lobby and played at
slow speed. Four have finished. A fifth, Broken Beyond, is still running and
is a Rebel Defense match, so it is left out.

Two sources carry the analysis. **System readings** come from decoded server
snapshots: output, buildings, governor and owner of every system at one
moment. Citadel has a reading for almost every day; the earlier matches only
kept their last days. **Orders** come from the action log, which holds every
build order and ship order of all four matches with a timestamp. Orders are
what cover early and mid game outside Citadel.

| Match | Played | Days | Players | System readings | Build orders | Ship orders |
| --- | --- | ---: | ---: | --- | ---: | ---: |
| Golden Bridge | 2026-06-19 to 06-29 | 10 | 15 | 1 (day 10) | 3,223 | 455 |
| Center's Mystery | 2026-06-29 to 07-16 | 17 | 14 | 1 (day 17) | 11,841 | 2,821 |
| Ham'burger | 2026-07-21 to 08-17 | 27 | 17 | 5 (days 24 to 27) | 31,409 | 4,504 |
| Citadel | 2026-08-22 to 09-13 | 22 | 14 | 22 (days 1 to 22) | 21,029 | 2,665 |

**Stages.** Early is the first five days, mid runs from day 5 to day 12, late
is day 12 onward. The boundaries follow patents: the median player holds 16 to
18 patents on day 5 in every match and 25 to 29 on day 12 in the three that
lasted that long, so a calendar day means the same toolbox everywhere.

**Specialists.** For each income type, the top quartile is the best 25% of
player-run systems by output at a reading, taken within its own match.
Dominions are excluded. Fleet yards are identified from what they did, not
what they look like: the systems where warships were ordered.

## The patent clock sets what a system can be

The tools of specialization arrive in a fixed order. Players in all four
matches reached each signature building at nearly the same point, which is why
the three stages look so different from one another.

**When players first build each signature building** (all four matches, 60
players; the middle half is the 25th to 75th percentile of the players who
built it):

| Group | Building | Median first build (day) | Middle half of builders (days) | Earliest (day) | Players who built it |
| --- | --- | ---: | ---: | ---: | ---: |
| Credit | Commercial Artery | 4.9 | 3.3 to 9.3 | 1.5 | 39 of 60 (65%) |
| Credit | Orbital Terminus | 13.6 | 8.9 to 18.9 | 7.6 | 18 of 60 (30%) |
| Credit | Orbital Link | 12.7 | 10.1 to 15.9 | 7.5 | 12 of 60 (20%) |
| Credit | Business Arch | 13.1 | 9.3 to 17.1 | 6.3 | 15 of 60 (25%) |
| Credit | Reflect District | 14.7 | 13.4 to 18.4 | 12.6 | 7 of 60 (12%) |
| Technology | Accelerator | 7.0 | 5.2 to 13.0 | 2.6 | 31 of 60 (52%) |
| Technology | Metamaterials Factory | 15.1 | 13.6 to 17.2 | 10.7 | 9 of 60 (15%) |
| Ideology | Floating Gardens | 2.2 | 1.0 to 3.9 | 0.6 | 52 of 60 (87%) |
| Ideology | Holodome | 5.4 | 4.1 to 8.3 | 1.8 | 32 of 60 (53%) |
| Ideology | Artificial Islands | 8.9 | 6.7 to 14.8 | 4.0 | 23 of 60 (38%) |
| Ideology | Monolith | 10.9 | 8.7 to 16.5 | 6.8 | 12 of 60 (20%) |
| Fleet | S-01 Assembly Line | 3.9 | 1.4 to 10.5 | 0.3 | 38 of 60 (63%) |
| Fleet | S-02 Assembly Line | 10.1 | 5.8 to 14.9 | 2.1 | 22 of 60 (37%) |
| Fleet | Space Dock | 11.6 | 8.9 to 17.2 | 6.1 | 15 of 60 (25%) |
| Fleet | Assembly Superstructure | 18.3 | 14.9 to 20.9 | 12.5 | 9 of 60 (15%) |
| Fleet | Military Academy | 10.9 | 10.1 to 13.1 | 6.1 | 10 of 60 (17%) |
| Protection | Integrated Proxy Systems | 6.2 | 4.8 to 9.9 | 3.1 | 33 of 60 (55%) |
| Protection | S.L.S.D. Network | 9.4 | 6.7 to 11.4 | 4.5 | 28 of 60 (47%) |
| Protection | Planetary Shield | 14.8 | 10.0 to 16.9 | 5.7 | 33 of 60 (55%) |
| Protection | C.N.D. | 13.3 | 10.7 to 15.1 | 7.1 | 29 of 60 (48%) |
| Protection | Orb-INTEL | 14.2 | 11.1 to 16.3 | 8.1 | 15 of 60 (25%) |

Early game has no specialist tools at all. Commercial Artery and Holodome
appear around day 5, the Accelerator around day 7, the S.L.S.D. Network around
day 9. Everything that defines a late specialist arrives from day 11 on:
Monolith, Orbital Link, Business Arch, Reflect District, Metamaterials
Factory, Orb-INTEL. The megastructures stay rare: 12 of 60 players ever built
a Monolith and 9 a Metamaterials Factory.

The same clock shows in what players spend their build queue on.

**Share of build orders by building purpose** (all four matches pooled, 67,502
build and upgrade orders; the range across matches is in brackets):

| Building purpose | Early (10,244 orders) | Mid (21,190) | Late (36,068) |
| --- | ---: | ---: | ---: |
| Credit | 26.5% (25 to 28) | 16.8% (15 to 19) | 13.9% (12 to 17) |
| Technology | 19.6% (19 to 20) | 11.0% (11 to 15) | 5.3% (5 to 7) |
| Ideology | 9.0% (8 to 10) | 10.6% (10 to 11) | 6.5% (6 to 8) |
| Production | 8.8% (8 to 10) | 15.1% (12 to 16) | 15.1% (14 to 16) |
| Shipyards and academy | 0.6% (0 to 2) | 1.3% (1 to 2) | 2.4% (2 to 3) |
| Housing | 20.7% (18 to 22) | 22.9% (22 to 24) | 23.7% (23 to 24) |
| Infrastructure | 8.5% (8 to 9) | 9.5% (8 to 10) | 8.5% (8 to 9) |
| Stability | 3.9% (3 to 4) | 6.5% (4 to 7) | 10.2% (8 to 10) |
| Defense | 1.6% (0 to 6) | 3.3% (2 to 6) | 10.0% (8 to 10) |
| Intelligence and cyber | 0.8% (0 to 2) | 2.9% (0 to 4) | 4.4% (3 to 5) |
| **Income: credit, technology, ideology** | **55%** | **38%** | **26%** |
| **Protection: stability, defense, intelligence** | **6%** | **13%** | **25%** |

**Early orders chase income that pays back now.** Credit and technology
buildings are 46% of everything ordered in the first five days. Refining Ducts
alone are 22% of all new buildings started in that window and Experiment
Stations another 10%: cheap orbital buildings that the first patents allow.

**Technology is planted once.** Its share of orders falls from 20% to 5%.
Later technology growth comes from upgrading a handful of research systems,
not from adding research everywhere.

**Protection takes over the queue.** Defense, stability and intelligence
buildings grow from 6% of orders to 13% and then 25%. Production doubles at
mid game and holds. The pattern repeats in every match: late-stage defense
orders range only from 8 to 10% across the three matches that reached it.

## Output concentrates in a quarter of the systems

**Share of all system output produced by the top 25% of systems.** An even
split would give the top quarter 25%.

| Reading | Player-run systems | Credit | Technology | Ideology | Production |
| --- | ---: | ---: | ---: | ---: | ---: |
| Citadel day 1 | 11 | 32% | 41% | 32% | 31% |
| Citadel day 3 | 16 | 36% | 33% | 41% | 33% |
| Citadel day 4 | 21 | 42% | 41% | 48% | 38% |
| Citadel day 5 | 25 | 44% | 43% | 53% | 39% |
| Citadel day 6 | 28 | 38% | 39% | 48% | 36% |
| Citadel day 7 | 32 | 39% | 43% | 50% | 36% |
| Citadel day 8 | 34 | 42% | 50% | 56% | 42% |
| Citadel day 9 | 37 | 43% | 51% | 57% | 42% |
| Citadel day 10 | 40 | 42% | 52% | 61% | 43% |
| Citadel day 11 | 46 | 46% | 60% | 69% | 44% |
| Citadel day 12 | 49 | 45% | 60% | 69% | 45% |
| Citadel day 13 | 48 | 47% | 61% | 67% | 46% |
| Citadel day 14 | 55 | 47% | 59% | 69% | 47% |
| Citadel day 15 | 55 | 50% | 64% | 70% | 49% |
| Citadel day 16 | 58 | 54% | 65% | 75% | 51% |
| Citadel day 17 | 62 | 56% | 66% | 77% | 52% |
| Citadel day 18 | 63 | 55% | 67% | 78% | 53% |
| Citadel day 19 | 72 | 56% | 67% | 79% | 55% |
| Citadel day 20 | 76 | 52% | 67% | 76% | 54% |
| Citadel day 21 | 78 | 55% | 68% | 76% | 50% |
| Citadel day 22 | 72 | 57% | 64% | 73% | 51% |
| Citadel day 22 | 76 | 57% | 64% | 74% | 51% |
| Golden Bridge day 10 | 32 | 45% | 46% | 44% | 38% |
| Center's Mystery day 17 | 55 | 51% | 58% | 62% | 51% |
| Ham'burger day 27 | 98 | 64% | 74% | 76% | 55% |

The other matches land where Citadel's curve says they should for their
length, so the trend is a property of the game and not of one map. Ideology
concentrates fastest and furthest, technology next, then credit. Production is
the flattest because every system needs some.

**The typical system does not get better at technology or ideology.** In
Citadel the median system's technology output peaks at 57 on day 7 and sits
between 33 and 42 from day 11 on, while the best system climbs from 111 to
472. Ideology does the same: the median stays between 24 and 47 for the whole
match while the best goes from 97 to 651. In the late game three in four
systems make about 22 of each.

**Top systems also become single-purpose.** On day 5, 42% of the systems in a
top income quartile are top in exactly one type; the rest lead in two or three
because they are simply the most developed capitals. At mid game it is 50%, in
the late game 66%.

## The three income recipes

Each table compares the top quartile for one income type with all other
player-run systems at the same readings ("top vs others"). The second table
lists the buildings that separate the two groups most: the share of
top-quartile systems that have the building against the share elsewhere.

### Credit

| Stage | Readings | Top quartile | Median credit output | Workforce in credit buildings | Erased governor | Median Mafioso points | Median population | Capitals |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Early | Citadel day 5 | 7 of 25 | 1,024 vs 587 | 34% vs 20% | 0% vs 17% | n/a | 50 vs 46 | 57% vs 44% |
| Mid | Citadel day 12 + Golden Bridge day 10 | 21 of 81 | 1,367 vs 604 | 23% vs 16% | 19% vs 8% | 7 vs 5 | 85 vs 56 | 5% vs 32% |
| Late | Citadel day 22 + Ham'burger day 27 + Center's Mystery day 17 | 57 of 225 | 2,949 vs 845 | 27% vs 11% | 53% vs 9% | 9.5 vs 7 | 98 vs 74 | 4% vs 8% |

| Stage | Buildings that set the top quartile apart (share of top quartile / share of other systems) |
| --- | --- |
| Early | Residential Archipelago 100% / 67%; Commercial Artery 57% / 28%; Refining Ducts 100% / 78%; Citadel 100% / 78%; Delta Polytech 100% / 78% |
| Mid | Accelerator 76% / 18%; Business Arch 48% / 10%; Orbital Terminus 52% / 15%; Residential Archipelago 95% / 58%; Industrial Hub 48% / 17% |
| Late | Business Arch 51% / 12%; Industrial Spaceport 40% / 14%; Space Elevator 46% / 20%; Orbital Terminus 51% / 25%; Residential Archipelago 72% / 50% |

Credit specialists are mobility machines. Population pays 2 credits a head
plus a tenth of a credit per head for every point of mobility, and the two
finance buildings pay per point of mobility again. So the late recipe is a
stack of mobility (Industrial Spaceport, Space Elevator, Orbital Terminus)
under a Business Arch or Reflect District, run by an Erased. The governor
matters most here: the median Erased on a top credit system has 9.5 Mafioso
points, and governors supply 18% of those systems' credit.

The Erased only arrive late. At mid game the top credit systems are still
mostly run by Siderians and overlap heavily with the top technology systems,
which is why the Accelerator shows up in the mid credit list.

### Technology

| Stage | Readings | Top quartile | Median technology output | Workforce in technology buildings | Siderian governor | Median Scholar points | Median population | Capitals |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Early | Citadel day 5 | 7 of 25 | 64 vs 40 | 23% vs 17% | 57% vs 33% | 2.5 vs 0.5 | 50 vs 46 | 71% vs 39% |
| Mid | Citadel day 12 + Golden Bridge day 10 | 21 of 81 | 96 vs 28 | 24% vs 14% | 48% vs 22% | 6.5 vs 1 | 93 vs 56 | 24% vs 25% |
| Late | Citadel day 22 + Ham'burger day 27 + Center's Mystery day 17 | 57 of 225 | 117 vs 22 | 15% vs 6% | 47% vs 12% | 7 vs 1 | 90 vs 76 | 9% vs 6% |

| Stage | Buildings that set the top quartile apart (share of top quartile / share of other systems) |
| --- | --- |
| Early | Residential Archipelago 100% / 67%; Holodome 43% / 11%; Refining Ducts 100% / 78%; Citadel 100% / 78%; Delta Polytech 100% / 78% |
| Mid | Accelerator 67% / 22%; Impact Research Center 90% / 65%; Hive Cities 62% / 38%; Experiment Station 100% / 78%; Array of Excavators 71% / 50% |
| Late | Impact Research Center 74% / 31%; Metamaterials Factory 46% / 5%; Accelerator 47% / 18%; Experiment Station 82% / 55%; Delta Polytech 54% / 29% |

The cut-off for the top technology quartile barely moves (60, then 66 to 69,
then 74 to 77) while the median of the top quartile nearly doubles and
everyone else's falls from 40 to 22. Technology has two late routes. The
research campus stacks an Accelerator, an Impact Research Center and
Experiment Stations under a Siderian with a median of 7 Scholar points. The
industrial route is the Metamaterials Factory, which pays production and
technology from the same planet: 46% of top technology systems have one
against 5% elsewhere, and three of the nine late technology leaders get their
best technology output from a fleet yard.

### Ideology

| Stage | Readings | Top quartile | Median ideology output | Workforce in ideology buildings | Siderian governor | Median Philosopher points | Median population | Capitals |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Early | Citadel day 5 | 7 of 25 | 48 vs 22 | 21% vs 12% | 71% vs 28% | 4 vs 2 | 49 vs 46 | 86% vs 33% |
| Mid | Citadel day 12 + Golden Bridge day 10 | 21 of 81 | 82 vs 22 | 24% vs 11% | 62% vs 17% | 5 vs 1 | 85 vs 56 | 14% vs 28% |
| Late | Citadel day 22 + Ham'burger day 27 + Center's Mystery day 17 | 57 of 225 | 180 vs 22 | 19% vs 9% | 46% vs 12% | 8 vs 5 | 102 vs 73 | 2% vs 8% |

| Stage | Buildings that set the top quartile apart (share of top quartile / share of other systems) |
| --- | --- |
| Early | Floating Gardens 100% / 61%; Holodome 43% / 11%; Omnimarket 71% / 44%; Citadel 100% / 78%; Refining Ducts 100% / 78% |
| Mid | Holodome 81% / 23%; Floating Gardens 95% / 50%; Residential Archipelago 95% / 58%; Citadel 95% / 60%; Monolith 48% / 13% |
| Late | Monolith 82% / 20%; Citadel 70% / 34%; Holodome 58% / 23%; Floating Gardens 68% / 38%; Artificial Islands 54% / 30% |

Ideology is the most recipe-driven of the three. By late game 82% of top
ideology systems hold a Monolith against 20% elsewhere. The Monolith pays per
head of the whole system's population, so these are also the most populous
systems in the game (a median of 102 against 73). The Monolith does not have
to be self-built: in Ham'burger 14 of the 23 Monoliths in top ideology systems
were inherited from neutral systems and in Center's Mystery 5 of 7, while in
Citadel all 17 were ordered by players.

### Who governs the specialists in late game

Governor type of the systems in each group at the final readings of Citadel,
Ham'burger and Center's Mystery.

| Group | Systems | Erased | Siderian | Navarch | No governor |
| --- | ---: | ---: | ---: | ---: | ---: |
| Top credit quartile | 57 | 53% | 25% | 18% | 5% |
| Top technology quartile | 57 | 12% | 47% | 28% | 12% |
| Top ideology quartile | 57 | 18% | 46% | 28% | 9% |
| Top production quartile | 57 | 19% | 11% | 56% | 14% |
| Fleet yards | 19 | 0% | 0% | 95% | 5% |
| All late systems | 225 | 20% | 21% | 30% | 29% |

The pairing follows the governor skills: Mafioso multiplies credit, Scholar
technology, Philosopher ideology, Shipowner production, each by 5% a point. An
ungoverned system is almost never a specialist: 29% of all late systems have
no governor, against 5 to 12% of the top income quartiles.

What specialists share is as telling as what separates them. Even in the top
quartile only 15 to 27% of the workforce sits in the specialty's buildings
(twice the share elsewhere). The remainder is the common base of
infrastructure, production, stability and housing. Buildings supply 62 to 89%
of a top system's specialty output, the governor 12 to 18%.

## What the leading players do

The three players with the highest system output of each type at the final
readings of the three longer matches. The leading player makes 14 to 32% of
the whole match's output of that type. Output here is what the player's
directly run systems make; dominion and lex income are not counted (see the
addendum for why that matters).

| Type | Match | Player | Share of match output | Systems in top quartile | From top-quartile systems | From best system | Best system (output) | Its governor |
| --- | --- | --- | ---: | ---: | ---: | ---: | --- | --- |
| Credit | Citadel | 1. the Citadel Banker | 24% | 5 of 5 | 100% | 27% | Ephi (6,820) | Erased |
| Credit | Citadel | 2. the Citadel Merchant | 13% | 4 of 6 | 89% | 25% | Teinekenk (3,403) | Siderian |
| Credit | Citadel | 3. the Citadel Orator | 13% | 3 of 8 | 70% | 30% | Nargak (3,929) | Erased |
| Credit | Ham'burger | 1. the Ham'burger Banker | 21% | 6 of 10 | 87% | 31% | Mong (11,978) | Erased |
| Credit | Ham'burger | 2. the Ham'burger Magnate | 12% | 2 of 8 | 82% | 66% | Kacth (15,152) | Erased |
| Credit | Ham'burger | 3. the Ham'burger Financier | 11% | 2 of 3 | 98% | 52% | Djara (10,660) | Erased |
| Credit | Center's Mystery | 1. the Mystery Banker | 14% | 3 of 6 | 65% | 26% | Marib (2,680) | Erased |
| Credit | Center's Mystery | 2. the Mystery Financier | 14% | 3 of 3 | 100% | 36% | Altra (3,546) | Erased |
| Credit | Center's Mystery | 3. the Mystery Polymath | 11% | 2 of 5 | 53% | 27% | Practar (2,150) | Siderian |
| Technology | Citadel | 1. the Citadel Scholar | 21% | 2 of 5 | 94% | 50% | Homarfis (472) | Siderian |
| Technology | Citadel | 2. the Citadel Polymath | 18% | 5 of 10 | 84% | 31% | Akheria (247) | Siderian |
| Technology | Citadel | 3. the Citadel Merchant | 9% | 2 of 6 | 67% | 37% | Asithara (142) | Siderian |
| Technology | Ham'burger | 1. the Ham'burger Shipwright | 23% | 4 of 6 | 100% | 47% | Boras (650) | Navarch |
| Technology | Ham'burger | 2. the Ham'burger Castellan | 14% | 4 of 5 | 94% | 32% | Gurcalrib (264) | Navarch |
| Technology | Ham'burger | 3. the Ham'burger Engineer | 13% | 5 of 7 | 92% | 41% | Kitibur (301) | Siderian |
| Technology | Center's Mystery | 1. the Mystery Conqueror | 19% | 3 of 6 | 87% | 41% | Alniros Ali (236) | Navarch |
| Technology | Center's Mystery | 2. the Mystery Polymath | 15% | 4 of 5 | 96% | 28% | Prion (127) | Navarch |
| Technology | Center's Mystery | 3. the Mystery Banker | 10% | 2 of 6 | 73% | 47% | Sedima (150) | Siderian |
| Ideology | Citadel | 1. the Citadel Preacher | 32% | 6 of 11 | 90% | 25% | Thern (612) | Siderian |
| Ideology | Citadel | 2. the Citadel Orator | 16% | 3 of 8 | 97% | 52% | Ousse (651) | Siderian |
| Ideology | Citadel | 3. the Citadel Polymath | 14% | 3 of 10 | 67% | 34% | Hasma (381) | Siderian |
| Ideology | Ham'burger | 1. the Ham'burger Preacher | 21% | 5 of 7 | 97% | 35% | Arnen (531) | Siderian |
| Ideology | Ham'burger | 2. the Ham'burger Dockmaster | 15% | 3 of 10 | 90% | 41% | Adii (436) | Siderian |
| Ideology | Ham'burger | 3. the Ham'burger Banker | 12% | 3 of 10 | 62% | 25% | Sakenchis (223) | Navarch |
| Ideology | Center's Mystery | 1. the Mystery Surveyor | 21% | 3 of 4 | 89% | 42% | Jas (333) | Siderian |
| Ideology | Center's Mystery | 2. the Mystery Abbot | 19% | 2 of 4 | 93% | 68% | Thanka (490) | Siderian |
| Ideology | Center's Mystery | 3. the Mystery Chaplain | 13% | 3 of 6 | 61% | 22% | Gaka (113) | Siderian |

**Leaders run a line of specialists, not one giant.** Most of a leader's
output comes from top-quartile systems (53 to 100%, with a median of 89%), but
the best single system typically holds only a quarter to a half of it. The
Citadel Banker's credit lead is five systems that all sit in the top credit
quartile. The Citadel Preacher led ideology with eleven systems, six of them
in the top quartile, and the Ham'burger Banker led credit with ten.

**The single giant exists too.** The Ham'burger Magnate's Kacth made 15,152
credit, the largest system output in the data and 66% of its owner's total.
The Mystery Abbot's Thanka made 68% of its owner's ideology, and the Citadel
Scholar's two research systems made 94% of the technology that led Citadel.
These players reach the top three on two systems.

**The best system's governor almost always matches.** Seven of the nine late
credit leaders have an Erased on their best credit system and eight of nine
ideology leaders a Siderian. Technology splits: five Siderians and four
Navarchs, three of the Navarchs sitting on a Metamaterials Factory in a fleet
yard.

On day 5 none of this is visible. The leaders of each type hold two or three
systems of nearly equal output and nothing in their build separates them from
the field.

## Where the specialists come from

The systems that carry a player's income at the end are chosen early in mid
game, and they are not the capital.

**Share of Citadel's final systems that ended in a top income quartile, by
founding day** (the 72 player-run systems at the day-22 reading, grouped by
the day their owner first held them):

| Founded | Systems | Ended in a top income quartile |
| --- | ---: | ---: |
| before day 8 | 21 | 76% |
| days 8 to 13 | 22 | 64% |
| day 14 or later | 29 | 21% |

The median top-quartile system in Citadel was founded on day 7 or 8 for all
three income types; the median of all other systems on day 14. Fleet
production is the exception: the top production quartile was founded later
(day 13), once the shipyard patents existed.

**Specialists sit on bigger sites.** Late top-quartile income systems have a
median of 48 to 51 building tiles and 90 to 102 population, against 41 to 42
tiles and 73 to 76 population elsewhere. Most were colonized from empty
systems: of the 18 systems in each of Citadel's final top quartiles, 10 to 14
began as uninhabited systems, 3 to 5 as the player's own dominions and at
most 3 as conquered neutrals.

**The capital is retired.** The starter capital has 34 tiles. On day 5 in
Citadel, capitals are 57 to 86% of every top income quartile. In the late game
they are 2 to 9%. Players do not just outgrow the capital; they hand it to a
dominion to free the system slot.

| Match | Capitals | Run directly | Dominion | Lost | Converted on day |
| --- | ---: | ---: | ---: | ---: | --- |
| Golden Bridge | 15 | 15 | 0 | 0 | none |
| Center's Mystery | 14 | 7 | 7 | 0 | 7, 7, 7, 10, 11, 11, 16 |
| Ham'burger | 17 | 5 | 8 | 4 | 5, 6, 8, 9, 10, 10, 17, 20 |
| Citadel | 14 | 4 | 8 | 2 | 4, 5, 6, 7, 8, 8, 9, 10, 14, 16 |

The table counts where each starting capital stood at the final reading. In
the three matches long enough to show it, 23 of 45 ended as dominions of their
original owner. The conversions cluster between day 5 and day 11, with a
median of day 9; the table lists every conversion, including two capitals that
were converted and later lost. Golden Bridge ended on day 10 with all 15
capitals still run directly.

## Fleet yards

A fleet yard here is a system that actually built the fleets: the smallest set
of systems covering 90% of the warship production ordered in a match
(fighters, corvettes, frigates and capital ships, weighted by production cost;
transports excluded). That gives 19 player-run yards across Citadel,
Ham'burger and Center's Mystery. Golden Bridge ended before real fleet
production began.

**Fleet building is concentrated in a few hands and, in two of three matches,
in the last third.** The three largest fleet builders ordered 84 to 99% of
each match's warships. In Citadel and Ham'burger 97 and 99% of warship
production was ordered after day 12; Center's Mystery went to war early, with
47% ordered in mid game.

**A yard is unmistakable on the production side.** Every yard has an S-01
Assembly Line and a Space Dock, 95% an S-02 and 68% an Assembly
Superstructure. Nearly half have a Military Academy, a building that almost no
other system has. Half carry a Metamaterials Factory. 52% of a yard's
workforce sits in production and shipyard buildings against 21% elsewhere, and
18 of 19 are governed by a Navarch with a median of 8 Shipowner points. Median
production is 1,489 against 362.

| Building | Yards that have it | Mean level | Other systems | Mean level |
| --- | ---: | ---: | ---: | ---: |
| S-01 Assembly Line | 100% | 4.3 | 36% | 3.1 |
| S-02 Assembly Line | 95% | 3.9 | 27% | 3.0 |
| Space Dock | 100% | 3.7 | 34% | 3.5 |
| Assembly Superstructure | 68% | 3.5 | 11% | 3.1 |
| Military Academy | 47% | 3.8 | 1% | 1.3 |
| Metamaterials Factory | 53% | 3.3 | 12% | 2.4 |
| Self-drilling Swarm | 84% | 4.8 | 60% | 3.8 |
| Array of Excavators | 79% | 3.9 | 29% | 3.1 |
| S.L.S.D. Network | 58% | 4.2 | 49% | 3.7 |
| C.N.D. | 53% | 3.9 | 36% | 3.0 |
| Interception Tunnels | 53% | 3.8 | 43% | 3.2 |
| Constellation of Lures | 37% | 4.0 | 51% | 3.7 |
| Planetary Shield | 11% | 4.0 | 33% | 3.1 |
| Orb-INTEL | 26% | 3.2 | 28% | 3.0 |
| Convention Center | 21% | 3.2 | 20% | 2.3 |
| Integrated Proxy Systems | 58% | 4.0 | 44% | 3.0 |

**The 19 fleet yards against the fortress checklist.** Each yard is ranked
among all player-run systems in its own match.

| Criterion | Yards in their match's top quartile | Yards above their match's median | Median, yards | Median, other systems |
| --- | ---: | ---: | ---: | ---: |
| Production | 17 of 19 | 18 of 19 | 1,489 | 362 |
| Defense | 7 of 19 | 13 of 19 | 69 | 36 |
| Stability | 7 of 19 | 10 of 19 | 62 | 64 |
| S.L.S.D. | 7 of 19 | 11 of 19 | S.L.S.D. level 3 | none |
| Intelligence | 7 of 19 | 12 of 19 | 126 | 91 |
| Cybersecurity | 5 of 19 | 12 of 19 | 100 | 80 |

**Production is the only criterion yards meet as a group.** On the other five
they are spread across the whole range. The typical yard is better protected
than the typical system on four of them (median defense 69 against 36,
intelligence 126 against 91, cybersecurity 100 against 80, and 58% have an
S.L.S.D. Network against 49%), but the margin is modest. On stability there is
no difference at all: a median of 62 against 64.

**The full fortress is a player's signature.** Three yards meet five or six of
the six criteria and four more meet four. The Ham'burger Castellan's three
yards account for three of those seven (Taris meets all six, with defense 524
and stability 324). At the other end, the single largest yard in the data, the
Ham'burger Shipwright's Boras, built 5.3 million production of warships with a
defense of 104, no S.L.S.D. and nothing but production in the top quartile.
The Ham'burger Dockmaster's three yards have defenses of 20, 36 and 46.

Bold cells are in the top quartile of their match. Warships ordered are
counted up to the reading: Citadel at day 19, before the attack described
below, Ham'burger at day 27 and Center's Mystery at day 17. Alas is read under
its captor. Two systems in Center's Mystery share the name Prion; the yard is
the Mystery Banker's.

| Match | Yard | Owner | Warships ordered | Share of match | Production | Defense | Stability | S.L.S.D. | Intelligence | Cyber | Top quartile on |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Citadel | Mectain | the Citadel Shipwright | 4.47M | 62% | **1,939** | 24 | **105** | **L4** | **190** | 96 | 4 of 6 |
| Citadel | Ringor | the Citadel Admiral | 2.25M | 31% | **2,083** | 26 | 18 | **L5** | 126 | **193** | 3 of 6 |
| Ham'burger | Boras | the Ham'burger Shipwright | 5.29M | 17% | **3,774** | 104 | 99 | none | 130 | 240 | 1 of 6 |
| Ham'burger | Gurcalrib | the Ham'burger Castellan | 4.62M | 15% | **2,528** | **343** | **243** | **L5** | 120 | 220 | 4 of 6 |
| Ham'burger | Drasse | the Ham'burger Dockmaster | 4.41M | 14% | **2,240** | 46 | 58 | none | **256** | 220 | 2 of 6 |
| Ham'burger | Taris | the Ham'burger Castellan | 3.69M | 12% | **2,450** | **524** | **324** | **L5** | **341** | **380** | 6 of 6 |
| Ham'burger | Orba | the Ham'burger Dockmaster | 2.09M | 7% | **1,489** | 36 | 10 | none | 90 | 40 | 1 of 6 |
| Ham'burger | Realnilis | the Ham'burger Dockmaster | 1.35M | 4% | **1,451** | 20 | 62 | L4 | **301** | 252 | 2 of 6 |
| Ham'burger | Nalat | the Ham'burger Engineer | 1.17M | 4% | **1,698** | **225** | 47 | **L5** | 193 | **277** | 4 of 6 |
| Ham'burger | Molmarlis | the Ham'burger Castellan | 1.12M | 4% | **1,644** | **234** | **116** | none | **267** | 120 | 4 of 6 |
| Ham'burger | Porar | the Ham'burger Picket | 1.08M | 4% | **1,382** | 158 | 46 | L4 | 149 | 76 | 1 of 6 |
| Ham'burger | Grien | the Ham'burger Engineer | 0.91M | 3% | **863** | 69 | 71 | L3 | 145 | 65 | 1 of 6 |
| Ham'burger | Ceidentat | the Ham'burger Sentinel | 0.87M | 3% | **2,385** | **206** | 32 | none | 45 | 100 | 2 of 6 |
| Center's Mystery | Alsaim | the Mystery Conqueror | 2.50M | 30% | **1,148** | 21 | 14 | none | 27 | 60 | 1 of 6 |
| Center's Mystery | Prion | the Mystery Banker | 1.95M | 24% | **713** | **182** | 62 | none | 62 | 20 | 2 of 6 |
| Center's Mystery | Was | the Mystery Polymath | 1.95M | 24% | **1,424** | 60 | **130** | **L4** | **113** | **96** | 5 of 6 |
| Center's Mystery | Alas | the Mystery Conqueror | 0.62M | 7% | 0 | **100** | **95** | **L4** | **117** | **136** | 5 of 6 |
| Center's Mystery | Alsaif | the Mystery Banker | 0.42M | 5% | 337 | 63 | **130** | none | 53 | 20 | 1 of 6 |
| Center's Mystery | Alniros Ali | the Mystery Conqueror | 0.29M | 4% | **960** | 16 | 24 | L3 | 46 | 72 | 1 of 6 |

### Two yards changed hands

**Mectain, Citadel.** The Citadel Shipwright's Mectain took 5.2 of the 9.8
million warship production ordered in the match. On day 19 it met four of the
six criteria: production 1,939, stability 105, an S.L.S.D. at level 4 and
intelligence 190. Its defense was 24, mid-table. That night the Citadel
Preacher ran Destabilization on it with seven Siderians at once, and with six
more ten hours later. All thirteen attempts succeeded, seven of them
critically. Stability went from 105 to 5 to minus 57, the system rose in
uprising and production fell to 418. A day later its owner abandoned it, and
the Citadel Admiral, the opposing faction's own fleet builder, conquered the
empty system an hour and a half before the match ended.

**Alas, Center's Mystery.** The Mystery Polymath ordered 460,000 production of
warships at Alas between days 9 and 11. By day 15 the system belonged to the
Mystery Conqueror of the opposing faction, who ordered another 158,000 there
before the match ended. It is the one case in the data of a captured yard
building fleets for its captor.

Both losses bear out the premise that a yard is worth fortifying. Mectain also
shows which wall matters. It was never taken by force against its defense; it
was lost to a stability attack that a reading of 105 could not absorb, and
stability is the one criterion on which yards are no better than ordinary
systems.

## Three things worth a second look

**Stability is the practical attack surface of a yard.** Thirteen
Destabilization runs inside half a day erased a stability of 105 and
everything that depended on it. If yards are meant to be defensible, the
question is what stability a concentrated Siderian strike can remove, and
whether any build can hold against it.

**The capital is not worth a system slot after day 9.** Half the capitals are
converted to dominions and the top quartiles are almost free of them. That
reads as a consequence of the 34-tile starter layout against 48 to 51 tiles on
the sites players choose.

**Technology and ideology do not spread.** Three quarters of late systems make
about 22 of each, less technology than the same group made on day 5. A
leader's research and ideology live in two to six systems, which makes those
systems as valuable a target as any yard. The top technology systems are the
least defended group in the data: a median defense of 27, against 49 for all
late systems and 69 for yards.

## Addendum: sharing, and the wide generalist

Added 2026-10-05, after the main analysis. The sections above only look at
what systems produce. Two things they miss explain how teams actually use that
production.

### Specialists exist to supply the team

All four matches predate the Mutual Aid offers (September 2026). Players
shared through ordinary market offers restricted to their faction, at token
prices. Three patterns are consistent.

**Everything shared stays in the faction.** All but one of the 2,207
technology and ideology offers that sold were bought by a member of the
seller's own faction.

| Match | Technology shared | Ideology shared | Share moved in the late stage | Credits moved | Navarchs handed over |
| --- | ---: | ---: | ---: | ---: | ---: |
| Golden Bridge | 245,000 | 64,000 | none (ended on day 10) | 2.4M | 7 |
| Center's Mystery | 3.8M | 3.6M | 50 to 58% | 37M | 67 |
| Ham'burger | 12.7M | 22.8M | 91 to 92% | 305M | 122 |
| Citadel | 9.6M | 11.6M | 84 to 89% | 163M | 42 |

Sharing starts within hours (the first sold offer comes between 20 minutes and
5 hours into each match, and 12 to 29 offers sell in the first two days), but
the early volumes are small: 58,000 to 190,000 technology in the first five
days. The bulk moves once the specialists exist.

**One or two producers supply about half of each resource.** The largest
technology supplier provided 46% of all shared technology in Center's Mystery
and in Ham'burger, 60% in Golden Bridge and 23% in Citadel (with a second
supplier at 22%). The largest ideology supplier provided 49 to 56% in every
match. In Citadel the suppliers are exactly the leaders from the tables above:
the Citadel Scholar is the top technology supplier and the Citadel Preacher
supplied 56% of the ideology.

**The receivers are the fleet builders.** In Citadel the Citadel Admiral and
the Citadel Shipwright took 66% of the shared technology between them. In
Ham'burger the Ham'burger Castellan took 32% of it.

**Credits flow from bankers to fleet holders.** Before Mutual Aid, credits
were moved by selling one point of technology for a large price. Counting
those offers, 163 million credits changed hands in Citadel, 87% of them in the
late stage. The Citadel Banker paid 56% of that, and the two fleet builders,
the Citadel Admiral and the Citadel Shipwright, received 75%. In Ham'burger
305 million credits moved (94% late): four payers covered 84% and the three
largest yard owners, the Ham'burger Castellan, the Ham'burger Shipwright and
the Ham'burger Dockmaster, received 64%. Fleet upkeep takes 23 to 37% of all
gross credit income in the late stage, and it lands on a handful of players
who cannot pay it from their own systems.

**Fleets change hands too.** Between 42 and 122 deployed Navarchs were handed
to another player in each of the three longer matches, nearly all of them in
mid and late game.

For bots, this means a system specialization only makes sense together with a
transfer policy: a technology bot that keeps its technology, or a fleet bot
that has to fund its own upkeep, is not playing the game the humans play.

### The wide generalist

One role does not fit the specialist picture: the Surveyor of each match (the
Bridge, Mystery, Ham'burger and Citadel Surveyors). The leaders tables above
rank players by what their directly run systems produce. By that measure the
Surveyor leads early (all three types in Golden Bridge at day 10, credit and
technology in Citadel at day 5) but appears in the late tables only once. By
total income the picture is different.

| Match | Credit rank, days 3 to 12 | Ideology rank, days 3 to 12 | Systems and dominions held, day 5 (median player) | Day 8 | Day 12 | Day 15 |
| --- | --- | --- | ---: | ---: | ---: | ---: |
| Golden Bridge | 1st to 3rd | 1st to 4th | 4 (2) | 6 (2) | ended | ended |
| Center's Mystery | 1st to 5th | 1st to 3rd | 5 (4) | 6 (5) | 9 (6) | 10 (6) |
| Ham'burger | 1st | 1st | 3 (3) | 8 (5) | 13 (7) | 19 (7) |
| Citadel | 1st to 6th | 1st to 3rd | 3 (3) | 6 (4) | 8 (6) | 11 (8) |

From day 3 the Surveyor is in the top three for total credit and ideology
income at almost every reading, and first in Ham'burger throughout. Technology
income starts mid-table and reaches the top three by day 8 to 10. The income
comes from breadth.

- **More holdings, sooner.** A second system by day 3 and more holdings than
  the median player at every later reading. In Ham'burger the count reaches
  19 by day 15 against a median of 7, and 30 by the end.
- **Dominions carry it.** At the mid and late readings 32 to 62% of the
  Surveyor's gross credit and 54 to 85% of the technology comes from
  dominions, against 22 to 31% of credit for the field as a whole. The Ham'burger Surveyor held 19
  dominions at the final reading; the median player held 4.
- **The surplus is given away.** The Surveyor is the largest supplier of
  shared ideology in three matches (49 to 56%) and of shared technology in
  two (46%), and paid 36% of all credits moved in Ham'burger.

The lead does not always last. In Citadel the Citadel Surveyor slips from
the top three to fifth in credit and sixth in technology over the last week,
as the specialists' megastructures come in and the dominion count stops
growing.

For bots, the wide generalist is a distinct, viable archetype: expand to the
system and dominion limits as early as the lexes allow, keep every holding
broadly built, and act as the team's supplier. It trades the late-game ceiling
of a specialist for the strongest economy of the first two weeks.

## How this was measured

**Readings pooled per stage.** Early: Citadel day 5 (25 player-run systems).
Mid: Citadel day 12 and Golden Bridge day 10 (81 systems). Late: Citadel day
22, Ham'burger day 27 and Center's Mystery day 17 (225 systems). Top quartiles
are always taken within one match reading and then pooled.

**Workforce shares** count the workforce of built buildings by their main
purpose. Housing uses no workforce and is left out of those shares.

**Founding day** is the first daily reading at which a system is player-run,
so it is known for Citadel only.

**Sharing** counts market offers with status sold. An offer is read as a
credit transfer when its price is at least 100 credits per point of the
resource it nominally sells. Total income ranks in the addendum come from the
per-player statistics the server records every few minutes.

**Limits.** The early-stage system profile rests on one match and 25 systems;
the order log confirms the early build mix in all four, but not the
system-level picture. Ship orders are orders, not launches: cancelled
production cannot be attributed to a hull type. Governors are whoever sat in
the system at the reading. Golden Bridge, at ten days, contributes nothing to
the late stage.

**Reproducing it.** Snapshots are decoded with a plain Elixir script in a
one-off container (`:erlang.binary_to_term`, structs read as maps) into one
JSON line per system, player and agent. Orders, offers and player statistics
are read-only exports of the `replays`, `offers` and `player_stats` tables.
The per-match role names are assigned from a private key that is not in the
repository.

# Agent training impact

Internal analysis, October 2026. An estimate of what three proposed
agent-training features would change: passive experience at a Delta Polytech,
skill reallocation at a "university" building, and the Great Pilgrimage. It is
source material for deciding whether and how to build them, not a player-facing
document.

It rests on the engine code, the four finished official Legacy matches (June to
September 2026), and a counterfactual replay of the Citadel match.

**About the data.** Players are not named. The scripts and extracted data behind
these figures are kept out of the repository because the raw data names players;
the method section at the end says what they do. All rates are at Legacy speed,
20 ticks per real hour.

## The proposal

1. **Passive experience with a Delta Polytech.** Building a Delta Polytech
   unlocks one deployment slot for an agent. While deployed there the agent
   gains passive experience like a governor, and its Protection and
   Determination are halved. Only the building's owner may use the slot, from
   agent level 1.
2. **Skill point reallocation.** Agents can be deployed to a Monolith
   (Siderians), an Orb-INTEL (Erased) or a Military Academy (Navarchs). After
   about four hours of settling in, the agent gains experience at twice the
   governor rate and earns one reallocation credit every 24 hours, to a maximum
   of five; it then leaves and waits to be recalled, when the owner chooses
   which skill points to move. Each building offers one to five slots by level.
   Protection and Determination are halved. The fee per tick, multiplied by the
   agent's level, is 5 ideology (Siderian), 5 technology (Navarch) or 50
   credits (Erased). Faction-mates may train agents of level 5 or higher, one
   agent per player per building.
3. **Great Pilgrimage.** A level 10+ agent leaves the deck for 48 hours or
   more and cannot be recalled. The cost per tick per agent level is, for
   example, 20 ideology, 20 technology or 200 credits. On return the owner
   replaces one passive skill with a passive skill of another agent type,
   chooses a new secondary skill, and may pick a new portrait.

In today's content the Delta Polytech is the building `university_open`, the
Monolith `monument_dome`, the Orb-INTEL `counterintelligence_open` and the
Navarch academy `military_school_dome` (Aerospace Military Academy). "Military
Academy" is also the name of the lex `admiral_3`, which is unrelated.

## Summary

- **The premise needs one correction.** Active training today is not high risk
  for high reward. Neutral space is the safest place an agent can stand, nobody
  hunts trainees, and the typical day on the board earns less experience than a
  governor's seat. What active training costs is attention, and three or four
  players per match pay it.
- **The Polytech slot is a small change, and smaller once it uses an agent
  slot.** Agent slots are what players are short of, and the working assumption
  here is that a trainee occupies one. Then the Polytech adds about 4% to all
  experience earned in a match with one slot per player, or 7 to 9% with one per
  building, and it only matters when every governor seat is full. Outside the
  limit it would add 7% and 18 to 24%. Either way it helps the less active
  players most and takes no agents off the map.
- **The university is the large change, and its prize is the skill points more
  than the experience.** One five-day course takes a specialist's main skill
  from a median of 5 to the cap of 12. In Citadel 19 of 275 agents ended the
  match at the cap. My central estimate is 54, and 5 capped assassins against 1.
- **At 2 experience per hour the university beats nearly everything players
  really do.** It out-earns 97% of the five-day stretches that level 5+ agents
  had in Citadel. Navarch pillaging is the one activity that stays ahead.
- **The halving penalty lands a trainee at about a governor's risk, which is too
  little to draw a hunter.** A failed Delete at the victim's home costs the
  attacker its own agent about half the time. Hunting starts to pay when the
  whole defence is cut by a third to a half.
- **Presence decides the Polytech, and it differs by agent type.** A Navarch can
  queue most of a day's experience in one visit. An Erased can queue about three
  actions, though players usually queue one. A Siderian needs three well-spaced
  visits to beat the slot and cannot reach the university's rate at all.
- **The Great Pilgrimage is expensive, late, and mostly for the richest ideology
  producers.** Alone it does little. Combined with a university course it
  roughly doubles what a governor is worth, and it cannot be built without
  changing how skills are stored.

## What training looks like today

The comparison that decides adoption is the experience an agent would have
earned anyway. Daily readings of every agent in Citadel give that directly.

**Experience per agent per real day**

Legacy speed. Observed values are from 1,505 on-board agent-days in Citadel.

|  | Experience per day | Series | Note |
| --- | --- | --- | --- |
| Deck | 0 | Observed today | An agent in the deck earns nothing. A third of all agent-days. |
| On board, median day | 13 | Observed today | Half of all on-board agent-days earn 13 or less. |
| On board, mean | 20 | Observed today |  |
| Governor seat | 24 | Observed today | 1 per hour, every hour, for every governor. |
| Polytech slot | 24 | Proposed | Proposed: the governor rate. |
| On board, 90th percentile day | 46 | Observed today | One on-board agent-day in ten reaches 46. |
| University | 48 | Proposed | Proposed: twice the governor rate, after four hours of settling in. |
| Navarch on a training day, median | 70 | Observed today | 2.9 per hour on days with pillage orders (event history, 180 Navarch training days). |
| Best 5 days by any agent | 88 | Observed today | The highest five-day average in the match. |
| Best single day | 175 | Observed today | One Navarch, one day. |
| Pillage ceiling, no travel | 260 | Mechanical ceiling | One undefended neutral, re-queued every hour. Nobody did this. |

The owner's figure of 6 per hour is 144 a day. It was reached on 4 agent-days of
1,505, all by one player. With no travel, pillaging one undefended neutral every
hour would pay about 260 a day; nobody did that.

- **Most field time earns less than a seat.** 65% of on-board agent-days fall
  below a governor's 24, and 29% earn nothing.
- **Training is done by very few people.** Across the four matches, 35% of all
  resolved agent actions were training, but the top three players of each match
  did 74 to 91% of it. They were the match leaders. One of them trained 30
  agents on 26 of 27 days.
- **Those players then give the agents away.** 351 of 354 agent sales went to a
  faction-mate, at a median price of 1 credit. 84 of the agents were level 10 or
  higher. Active training is a service a few very active players provide to
  their team.
- **The cost is attention.** Ordinary training takes about three sessions a day.
  The days that reached 4 experience per hour needed orders in a median of 6.5
  different clock hours for one Navarch; the one player who reached 6 per hour
  issued training orders in 12 clock hours a day.
- **A third of all agent-days are spent in the deck earning nothing.** A deck
  holds three or more agents on 63% of player-days.

**Agents removed per 100 agent-days, by where they stood**

Delete and Seduce by enemies, four official matches, 633 attempts.

|  | Removed per 100 agent-days | Note |
| --- | --- | --- |
| On board, neutral system | 0.39 | 25 removals. Almost all were Siderians building dominions. |
| Governor seat | 0.88 | 23 removals in 2,622 governor-days. |
| On board, at home | 1.10 | 71 removals. |
| On board, enemy territory | 4.40 | 284 removals. This is where agents die. |

The three on-board figures share one denominator (all on-board days), because
time per zone cannot be rebuilt from the event tables. They compare zones with
each other; the governor figure has its own denominator.

Only 13 of the 633 attempts hit an agent that had trained in the previous 24
hours, and one trainee was ever attacked while standing on a neutral. No
pillaging Navarch was caught in a battle at a neutral system. The emergent hunt
described in the proposal's framing has not happened in any official match.
Agents die in enemy territory, doing real operations.

## How much attention beats a passive slot

Nobody is online all day, so the answer turns on how long each action takes and
how many can be queued. The times below are the engine's, and the real chains in
the event history match them.

| Action | Time at zero defence | Time against some defence | Queue rule | What players queue per sitting |
| --- | --- | --- | --- | --- |
| Pillage | 1 h, plus travel | Up to 2 h at even odds | One per target; the chain runs alone | One in 62% of sittings, three or more in 22% |
| Infiltrate | 2.5 h | 3.2 h at token Intelligence, up to 5 h at even odds | Any number, until cover drops under 75 (about three) | One in 75% of sittings, three or more in 6% |
| Destabilize | 2.5 h, then a 2 h cooldown | Same; a failure makes the cooldown 5 h | One, and none during the cooldown | One |

Travel between pillage targets is the largest term. Real chains queued in one
sitting ran a median 2.8 hours per pillage (2.3 in Citadel, 1.65 for the fastest
tenth). Re-pillaging the same undefended system takes exactly 1 hour, but needs
a new order each time. A pillage needs only one ship: against zero defence any
bombing power above zero succeeds with no hull damage, and 184 real zero-defence
pillages were made with bombing power of 10 or less. Against any defence,
bombing power sets both the time and the damage taken, so a training Navarch
still needs a ship that can bombard and a slot to hold it.

| Experience per agent per day, by visits per day (zero defence) | 1 | 2 | 3 | 4 | 5 | Hourly, 17 h awake |
| --- | --- | --- | --- | --- | --- | --- |
| Navarch, one pillage per visit | 11 | 22 | 33 | 43 | 54 | 65 to 98 |
| Navarch, 3 targets per visit (an 8 h chain) | 33 | 33 to 65 | 65 to 98 | 65 | 81 to 97 | 81 to 98 |
| Navarch, 6 targets per visit (a 17 h chain) | 65 | 65 | 65 to 98 | 86 | 81 to 98 | 87 to 98 |
| Erased, one infiltration per visit | 11 | 21 | 32 | 43 | 53 | 54 to 57 |
| Erased, queued until discovered (about three) | 37 to 39 | 38 to 42 | 47 to 51 | 50 to 56 | 50 to 55 | 56 to 59 |
| Siderian, one destabilization per visit | 11 | 21 | 32 | 42 | 42 | 42 |
| **Polytech slot** | **24, with no visits** |  |  |  |  |  |
| **University** | **48, with no visits** |  |  |  |  |  |

Tick-level model: visits spread evenly over a 17-hour day, the agent already in
place, level 5 to 10. Ranges cover the real travel pace (2.3 to 2.8 hours per
pillage) and agent level. A visit is one sitting in which the player gives that
agent orders. A row can dip when evenly spaced visits land while a queue is
still running. A Siderian fits four destabilizations into a waking day, so a
fifth visit adds nothing. Against token defence an infiltration takes 3.2 hours,
so single actions lose little until the fifth visit (41 in place of 53) and
chains lose 15 to 30%; the other rows barely move. A level 15+ Erased on a
zero-Intelligence neutral always scores a critical success and reaches 56 from
one chained visit.

- **Navarch: the slot wins only against a player who queues one pillage a visit
  and visits twice or less.** Three targets in one visit already pay 33, and six
  pay 65, more than the university. A real Navarch on a training day earned a
  median 70.
- **Erased: it depends on queue depth.** Queued one at a time, as players do in
  three sittings of four, an Erased needs three visits to beat the Polytech and
  five to beat the university. Queued until discovered, one visit beats the
  Polytech and three or four match the university. A real Erased on a training
  day earned a median 30, from two sittings.
- **Siderian: the Polytech wins below three well-spaced visits, and the
  university always wins.** A Siderian tended every waking hour reaches 42.

How often this happened in the four matches, per tended agent per day:

| Actions in one day by one agent | Median | Top tenth | Most | Days with 5 or more |
| --- | --- | --- | --- | --- |
| Infiltrations of neutrals | 3 | 5 | 9 | 25% |
| Pillages of neutrals | 4 | 8 | 15 | 49% |
| Destabilizations of neutrals | 2 | 4 | 5 | 1% |

Days on which the agent did at least one such action: 633, 185 and 369
agent-days.

Cover is why infiltrations go in one at a time, and it is also what caps them. A
success costs about 10 cover, which is two hours of idle recovery, and recovery
stops while anything is queued. That makes one infiltration every 4.5 hours the
steady pace however the orders are grouped; queueing three only saves visits. A
new Erased starts at 80 cover and is discovered under 75, so its first
infiltration is the only one it can queue, and players who re-queue as soon as
an action ends keep cover near 90, where one more fits and two do not. Snapshots
agree: Erased caught mid-infiltration hold a median 91 cover. Level matters more
than attack here, because critical successes cost half the cover: at zero
Intelligence they are 31% of results below level 5, 66% at levels 10 to 14 and
all of them from level 15.

That is the ceiling for an agent someone is tending. What players get across all
the agents they hold is lower, because attention is split and most on-board
agents have a job other than training.

| Owner's activity that day (clock hours with any command) | Agent-days | Mean experience | Beat 24 | Agents given a training order: mean | Beat 24 | Beat 48 |
| --- | --- | --- | --- | --- | --- | --- |
| 0 to 2 hours | 110 | 3 | 0% | none |  |  |
| 3 to 5 hours | 365 | 16 | 25% | 40 | 67% | 37% |
| 6 to 8 hours | 326 | 25 | 52% | 45 | 71% | 42% |
| 9 to 12 hours | 287 | 19 | 31% | 38 | 58% | 30% |
| 13 hours or more | 417 | 26 | 38% | 52 | 81% | 47% |

Citadel, on-board agents, joined to the owner's command log for the same day.
The median player-day has commands in 6 clock hours (quartiles 4 and 9).
Training orders are pillage, bombardment and infiltration of neutrals.

So the Polytech's 24 a day equals what the average on-board agent earns for a
player active in six or more clock hours, which is the median player-day. Below
that the slot wins on average, and at any activity level it beats the agents
nobody is tending. An agent that is given training orders beats 24 about two
times in three even for a player with three to five active hours. Against the
university's 48 that falls to under half, at every level of activity.

## Passive experience at a Delta Polytech

The Polytech needs no patent and costs 1,500 credits. Every Citadel player owned
two within 17 hours of the start, and three to four in their own systems from
day 5. The building is free and universal from the first day. The agent slot is
not.

**Working assumption: a trainee occupies an agent slot of its type.** This is
the owner's reading, and it follows from how players weigh agents. A slot comes
from a lex, which costs ideology to buy, a lex slot to hold, and whatever else
that lex slot could have carried. A player with four Navarch slots and four jobs
for them has nothing to train with, however many Polytechs they own. In Citadel
61% of the agent-days spent in a deck belonged to a type whose limit was already
full.

**Extra experience, as a share of all experience earned in the match**

Citadel replayed with waiting deck agents placed in slots. Under the slot
assumption the figures count only what a Polytech adds beyond the empty governor
seats a player already has. "Realistic use" scales each player by how often they
keep governor seats filled today.

|  | Extra experience | Note |
| --- | --- | --- |
| Uses a slot: one per player, realistic use | +3.5% |  |
| Uses a slot: one per player, always filled | +4.5% |  |
| Uses a slot: one per Polytech, realistic use | +7.1% |  |
| Uses a slot: one per Polytech, always filled | +8.7% |  |
| Outside the limit: one per player, realistic use | +7.0% |  |
| Outside the limit: one per Polytech, realistic use | +17.9% | The proposal read literally, with players as diligent as they are about governor seats. |
| Outside the limit: one per Polytech, always filled | +23.9% | The ceiling. |

- **The slot competes with the governor seat, and usually loses.** A seat pays
  the same 24 a day, adds the governor's bonus and carries no penalty. 59% of
  player-days in Citadel had an empty seat, and filling those seats alone would
  add 3.5 to 5.5% to all experience today. The Polytech adds something on 35% of
  player-days: when every seat is full, a slot of the right type is free and an
  agent is waiting.
- **It narrows the gap either way.** With one slot per Polytech under the slot
  assumption, the less active seven players gain 26% more experience and the
  more active seven 3%. Outside the limit it is 47% and 11%.
- **Players already leave the same thing unused.** On 42% of player-days a
  player had an empty governor seat and an agent that could fill it, and left
  it. All 14 players did this at some point.
- **What it changes is the buying decision.** A player takes a slot only for an
  agent that will be useful in time. With passive training a cheap hire with the
  right primary becomes that agent without attention: level 5 in 2.1 days, level
  10 in 6.2. That makes buying ahead of need, and buying cheap, worth a slot.
- **It does not empty the map.** The trainees come from the deck, which is off
  the map today. If anything it adds targets to home systems.
- **It feeds the other two features.** Level 5 is the university's gate and
  level 10 the Pilgrimage's.

### The trade-off is nearly empty at low level

Only the agent's own Protection is halved in the natural reading; the host
system's Intelligence still counts in full. A level 1 agent has 10 to 19
Protection, so there is almost nothing to halve.

| Siderian trainee in a Polytech system | Day 8 | Day 16 | Day 22 |
| --- | --- | --- | --- |
| Level 1 | 97% → 99% | 82% → 84% | 75% → 76% |
| Level 5 | 81% → 94% | 65% → 76% | 59% → 69% |
| Level 10 | 49% → 81% | 41% → 65% | 41% → 59% |

Chance that one Delete attempt removes the trainee, today → with its Protection
halved. Attackers are the real attempts recorded in that week of the four
matches; hosts are the real Polytech systems of Citadel on that day.

A low-level trainee in a Polytech is easy to kill with or without the penalty,
and a kill pays the assassin 12 experience. Whether enemies bother is a
behaviour question the data cannot answer: today they attack a governor's seat
1.8 times per 100 days.

## The university and skill reallocation

Five days at twice the governor rate is 240 experience, which is ten days of
governing. A level 8 agent leaves at level 16. Then come the five reallocated
points.

### What the points are worth

- **Five points on the main skill equal about ten levels, and what that costs
  depends on where the agent starts.** The draw puts roughly one point in two on
  the main skill. Earned at a governor's 24 experience a day, those five points
  take a median of 10 days in the seat for an agent starting at level 5, 13 days
  starting at level 8, and 15 days starting anywhere from level 10 to 15. Above
  level 15 most agents have less than five points of room under the cap.
- **Outside the main skill, levelling never gets there.** Five points on the
  hidden second skill take 21 to 30 days of governing. On any other skill they
  take about 110, longer than any match.
- **It widens the market.** Take one governor skill a player wants at 8 points
  or more. Of random Outstanding hires, 12% get there after ten days in a seat;
  with one course, 29 to 35% do. For Exceptional hires it is 20% against 42%.
  Nearly all of the gain is agents whose hidden second skill is the wanted one.
  A course for a level 5 agent costs about 118,000 ideology or technology, or
  1.2 million credits. A late Exceptional Erased cost about 750,000 credits in
  Citadel and arrives with 7 or 8 points in its main skill, so school competes
  with the top of the market.
- **Course plus reallocation reaches the cap.** In the replay the median agent
  enters with 5 points in its main skill and leaves with 12. The seven or eight
  levels gained supply three or four points and the reallocation supplies the
  rest.
- **Demand is broad.** 84% of late governors hold five or more points outside
  the skill that matches their system, and every player has one.

**Agents with a skill at the cap of 12 by the end of Citadel**

Today, and with the courses each adoption case would have run.

|  | Agents at the cap | Note |
| --- | --- | --- |
| Today | 19 | 19 of 275 agents alive on the last full day. |
| Low adoption | 32 | 13 more, capped by a course and still alive at the end. |
| Central | 54 | 35 more, capped by a course and still alive at the end. |
| High adoption | 95 | 80 capped by a course and alive at the end; 4 of them were capped anyway. |

Counts are agents alive on the last full day, across all 14 players. Assassins
at the cap: 1 of 39 today; 3, 5 and 6 in the three cases. Courses capped 2, 7
and 9 assassins, and some were lost before the end.

This is a military change before it is an economic one. Replaying the 104 real
Delete attempts made on agents at home in weeks three and four, a capped
assassin succeeds 73 to 80% of the time where the real attackers succeeded 43%.

### Would players have used it

| Adoption case | Who is sent | Courses | Players (of 14) | Net experience | Fees, share of all net income |
| --- | --- | --- | --- | --- | --- |
| **Low** | Deck agents only; fees under 10% of the player's income; one course per agent; no Navarch host | 14 | 8 | +6% | 1% ideology, 3% credits |
| **Central** | Deck agents and on-board agents earning under 12 a day; fees under 25% of income | 52 | 11 | +22% | 10% ideology, 7% credits, 2% technology |
| **High** | Any agent the course beats, governors included; fees under 50% of income | 125 | 13 | +41% | 27% ideology, 16% credits, 6% technology |

Replay of Citadel with the real host buildings, levels, incomes and agents of
each day. Slots are the levels of buildings in own systems. A student taken from
the deck needs a free agent slot of its type; an agent already on the map keeps
the one it has. Without that rule the low and central cases run 22 and 67
courses. Courses start from day 8 to 10, when the first hosts and level 5+
agents exist, and the median course starts on day 15.

- **On experience alone the course wins almost always.** It beats 97% of the
  real five-day stretches of level 5+ agents, and 97% of the on-board ones. Only
  8 agents, owned by 2 players, beat 48 a day over any five days.
- **Erased and Siderians have no active answer.** Their sustained loops
  (infiltrating or destabilising neutrals, practising on a teammate's agent) pay
  1.7 to 2.5 per hour with a re-queue every action or two. The university pays
  2.0 with none.
- **Navarchs keep pillaging.** A Navarch on a training day earns a median 2.9
  per hour, and the Academy barely exists as a host: 4 of 14 Citadel players
  ever held one, 1 at the end.
- **Use spreads wider than active training does.** The top three players run 44
  to 57% of courses, against 74 to 91% of today's training actions.

### The fees are steep, and uneven

| Fee for a level 10 agent, share of net income | Day 8 | Day 12 | Day 22 |
| --- | --- | --- | --- |
| Siderian (50 ideology per tick), median player | 52% | 25% | 15% |
| Siderian, top-quarter ideology player | 28% | 10% | 4% |
| Navarch (50 technology per tick), median player | 32% | 22% | 13% |
| Erased (500 credits per tick), median player | 21% | 10% | 6% |

- **Levels rise as fast as income.** For a player's own best agent the fee is
  about half of net ideology until day 8 and 27 to 32% after. It stays near 19
  to 24% of net technology and 8 to 19% of net credits.
- **The 10:1:1 ratio does not match incomes.** The median player earns 20
  credits per technology and 13 per ideology. In income terms the Navarch fee is
  about twice the Erased fee.
- **Monolith owners are the ideology-rich.** At the end of Citadel the seven
  owners earned 1,276 ideology per tick and the others 109. A level 10 Siderian
  course costs an owner 4% of income and a teammate without a Monolith 46%.

### What a training budget buys

Suppose a player will spend 10 to 25% of net income of the fee's resource on
training. Dividing by the fee gives the agent levels that budget pays for, as
one agent or several. The gate is level 5.

| Median player in Citadel | Day 5 | Day 8 | Day 12 | Day 16 | Day 22 |
| --- | --- | --- | --- | --- | --- |
| Siderian levels at 10% / 25% of ideology | 1 / 4 | 2 / 5 | 4 / 10 | 4 / 11 | 7 / 17 |
| Level of their best Siderian | 7 | 10 | 12 | 14 | 18 |
| Players who can pay for it, at 10% / 25% | 0 / 0 of 13 | 0 / 1 of 13 | 3 / 5 of 12 | 4 / 5 of 13 | 4 / 6 of 13 |
| Navarch levels at 10% / 25% of technology | 2 / 4 | 3 / 8 | 5 / 11 | 5 / 13 | 8 / 19 |
| Level of their best Navarch | 7 | 9 | 13 | 15 | 17 |
| Players who can pay for it, at 10% / 25% | 0 / 1 of 6 | 0 / 5 of 8 | 1 / 5 of 8 | 1 / 5 of 10 | 3 / 7 of 12 |
| Erased levels at 10% / 25% of credits | 3 / 7 | 5 / 12 | 10 / 24 | 9 / 22 | 17 / 43 |
| Level of their best Erased | 7 | 10 | 12 | 16 | 17 |
| Players who can pay for it, at 10% / 25% | 0 / 5 of 8 | 1 / 7 of 10 | 3 / 9 of 11 | 4 / 8 of 12 | 6 / 8 of 12 |

"Players who can pay" counts those holding a level 5+ agent of the type whose
budget covers their best one at its entry level. If the fee follows the level,
it rises by about half during the course.

- **At 10% almost nobody can train their best agent before day 12.** By the end
  it is a third of players for Siderians, a quarter for Navarchs and half for
  Erased.
- **At 25% the Erased course is affordable to most players from day 8, the
  Navarch course to about half, and the Siderian course to under half all
  match.** The median player's Siderian budget stays one or two levels short of
  their best Siderian from day 12 to the end.
- **The top quarter is in a different position on ideology.** At 25% they can
  pay for 26 Siderian levels on day 12 and 64 at the end, enough for three or
  four agents at once.
- **The Pilgrimage is out of range at these budgets for most.** It costs four
  times as much per tick. At 25% the median player can pay for a level 3
  Siderian or Navarch on day 12 and a level 6 Erased, below the level 10 gate.
  Players who could pay for a level 10 pilgrim at 25%: 1, 0 and 2 of 13 on day
  12 (Siderian, Navarch, Erased), and 4, 2 and 7 at the end.
- **Nothing is hoarded.** Players spent 83 to 89% of everything they earned, so
  a fee displaces patents, lexes and buildings one for one.
- **For a governor the course does not pay for itself.** A level 11 Siderian
  pays 55 rising to 90 ideology per tick, about the whole ideology output of the
  median system it governs (76). Counting the fee and the five days out of the
  seat, the median payback is 22 to 24 days for a Siderian and 18 to 44 for an
  Erased, depending on the day. Among the governors whose fee and output share a
  currency, none sent on day 8, 12 or 16 would have earned the cost back before
  the match ended.

So the rational use is a field specialist, sent by a player who can spare the
income, or a governor sent by one of the few rich ideology producers.

### Hosts are rare and late

| Building | Players ever owning (of 14) | Fastest | Median player | Slots against eligible agents at the end |
| --- | --- | --- | --- | --- |
| Monolith (Siderians) | 7 | day 7.7 | day 20.7 | 104 slots, 49 Siderians |
| Orb-INTEL (Erased) | 8 | day 9.7 | day 18.7 | 70 slots, 126 Erased |
| Aerospace Military Academy (Navarchs) | 4 | day 8.7 | never | 9 slots, 54 Navarchs |

Allied access is what makes the feature reach most players: every faction had a
Monolith by day 8 to 10 and an Orb-INTEL by day 10. The Navarch half is close to
absent unless a shipyard is meant; 13 of 14 players had one, the median by day
8.

### The risk to a trainee

| One attempt, today → own stat halved | Level 5 | Level 10 | Level 15 |
| --- | --- | --- | --- |
| Siderian in a Monolith system, Delete, day 16 | 52% → 64% | 30% → 52% | 16% → 40% |
| Siderian in a Monolith system, Seduce, day 16 | 39% → 62% | 12% → 39% | 3% → 22% |
| Erased in an Orb-INTEL system, Delete, day 16 | 44% → 52% | 29% → 44% | 18% → 36% |
| Erased in an Orb-INTEL system, Seduce, day 16 | 53% → 69% | 27% → 53% | 13% → 39% |

- **Over a whole course the loss risk is modest unless enemies change
  behaviour.** At the rate governors are attacked today, a trainee has about a
  6% chance of being lost during a course, against 4.5% for a governor over the
  same days. If attempts double it is 12%. If trainees are hunted as hard as
  agents in enemy territory it is 20%.
- **An Erased student has to be made visible by rule.** Today an on-board Erased
  with cover above 75 is removed from every other faction's view of the system.
  The owner's intent is that a student is plainly in one place, so the training
  state needs its own visibility, and the Erased rows in these tables assume it.
- **Seduction is the larger swing and the smaller threat.** Halving roughly
  triples the odds, but only 86 Seduce attempts on enemies were made in four
  matches, against 547 Deletes.
- **A teammate's trainee becomes practice.** Friendly Seduce is legal and a
  success moves the agent to the seducer. Teams that do this pass one agent back
  and forth, and halved Determination makes each pass more likely to land. The
  server does not check the seducer's agent limit, and a seduced student
  presumably leaves its slot, so the feature needs a ruling on both.
- **Halving the whole defence would be a different feature.** If the system's
  share is halved too, the level 10 Siderian above goes to 70% per Delete
  attempt.

### What penalty would make a student worth hunting

The action costs nothing, but the attempt does. After a failed Delete on an
agent at home, the attacking Erased was itself removed within a day 52% of the
time (67 cases). After a success it was 25%. A hunter therefore pays in
assassins, and the question is how many per student.

| Rule for a student's defence | Siderian L10, Monolith | Erased L10, Orb-INTEL | Siderian L15 | Erased L15 | Assassins lost per student removed |
| --- | --- | --- | --- | --- | --- |
| No penalty | 31% | 29% | 17% | 19% | 1.4 to 2.8 |
| Own stat halved (the proposal) | 52% | 42% | 41% | 36% | 0.7 to 1.2 |
| Whole defence × 0.67 | 54% | 52% | 39% | 42% | 0.7 to 1.1 |
| **Whole defence × 0.5** | **69%** | **67%** | **56%** | **58%** | **0.5 to 0.7** |
| Whole defence × 0.4 | 78% | 76% | 67% | 69% | 0.4 to 0.5 |
| Whole defence × 0.33 | 84% | 83% | 76% | 77% | 0.3 to 0.4 |
| No system bonus, own stat intact | 61% | 77% | 38% | 59% | 0.4 to 1.1 |

Chance that one Delete attempt removes the student, averaged over the real host
systems of days 12, 16 and 22 and the real attackers of those weeks. For
reference, Delete succeeded 48% of the time on governors and 65% on level 10 to
14 agents caught away from home (52% at level 15+).

- **The proposal sets a student at a governor's risk.** A hunter loses about one
  assassin per student removed, and the assassin is usually the more valuable
  agent. That is a poor trade, so few would try.
- **Half of the whole defence makes school as exposed as enemy territory.** It
  matches the real rate for agents caught away from home at both levels, and a
  hunter loses one assassin for every one and a half to two students.
- **A workable range is the whole defence at 0.5 to 0.67.** Above 0.67 nobody
  hunts. Below 0.4 a student near any enemy assassin is lost more often than
  not, and the building's own Intelligence stops mattering.
- **Scale the whole defence, not the agent's stat alone.** Halving the stat does
  nothing at low level, fades late in the match as system Intelligence grows,
  and treats types unevenly. Dropping the system bonus altogether hits Erased
  far harder than Navarchs and gives a host no reason to fortify.
- **Seduction follows the same multiplier.** At half the whole defence a level
  10 student is seduced 44% (Siderian) to 59% (Erased) of the time per attempt,
  against 8% and 21% with no penalty.
- **The multiplier sets the odds; visibility sets the rate.** At a 50% chance
  per attempt a course is lost 5% of the time if students are attacked as rarely
  as governors, and 21% if they are attacked as often as on-board agents are
  today.

### Does it pull play back into home systems

Partly. In the central case the agents sent would otherwise have spent 8% of all
on-board time in enemy systems and 7% of the time on neutrals, and they were
mostly idle there. In the high case it is 31% and 13%, plus 24% of governor
time. Infiltrating neutrals and friendly dominions is about 60% of today's
training actions, and it is what the university replaces for anyone who can pay.
Enemy-territory operations are replaced only if players start pulling working
agents home for the points.

## The Great Pilgrimage

- **The pool is small and late.** No level 10+ agent sat in a deck before day 7
  in Citadel. There were 2 to 8 on days 8 to 12 (2 to 6 players) and 18 to 25
  from day 16 (7 to 11 players).
- **It costs days of income.** A level 10 agent costs 192,000 ideology or
  technology, or 1.92 million credits. On day 12 that is 2.0 days of the median
  player's net ideology, 1.8 days of technology or 0.8 days of credits, and
  while it runs it takes all of the median player's ideology income.
- **The portrait is theme, and costs nothing in balance.** Nothing in the game
  keys off it. There are 45 portraits today, 15 per type, shared between agents.
- **The secondary skill only steers future level-ups.** It is hidden even from
  the owner today. Choosing it earns the chosen skill a point about every 3
  levels in place of every 11.
- **The swap matters only for governors.** The nine passive skills are read only
  while an agent governs. Governor skills are also the only percentage bonus on
  a system's credits, technology and ideology, so a second economy skill on one
  governor is new ground.

For 25 of the 36 level 10+ governors in Citadel on day 16, all of them Siderians
or Navarchs, the best skill to import was Finance. Filled to 8 points it would
add a median 390 to 560 credit-equivalents per tick, between 0.7 and 2 times the
governor's whole current economic bonus. But the swapped slot arrives holding
one or two points. Filling it takes a new secondary skill and levels, or a
university course. The combination is about seven days and 400,000 or more
ideology for one agent, which only the top quarter of ideology producers can
pay.

Two side effects follow. Siderians with Finance erode the Erased's place as the
credit governor, which they hold on 53% of top credit systems today. And if the
Pilgrimage can be repeated, all three passive slots become free picks and an
agent's type means little more than its Protection curve.

The engine cannot represent this today. Skills are six numbers looked up by
agent type and position, and a foreign skill key crashes the next level-up.

## Who would use what

The cost to a player is paid in three currencies: agent slots, attention and
income. The Polytech needs only the first, active training the first two, the
university the first and the third. A player would reason in this order.

1. **Do I have a free slot of that type?** If not, there is nothing to decide. A
   slot is only worth buying for an agent that will be useful in time, and
   passive training is what makes a cheap hire that agent.
2. **Is a governor seat empty?** Seat the agent. Same experience, plus the
   bonus, and no penalty. The Polytech is for when every seat is full.
3. **Is it a Navarch?** Queue pillages. Three targets in one sitting beat the
   Polytech and six beat the university, so a Navarch goes to school only for
   the reallocation.
4. **How often will I be back today, at the right times?** For an Erased or a
   Siderian, three well-timed visits roughly match the Polytech and five match
   the university. Most players manage two or three.
5. **Can I afford it?** This limits the university to one student at a time, the
   best one, for the points. One level 10 Erased in school costs as much as the
   wages of six fielded level 10 agents.

| Player | Polytech slot | University | Pilgrimage |
| --- | --- | --- | --- |
| **The three or four heavy trainers** | Yes, when a slot is free, for hires waiting in the deck | Courses for their best Erased and Siderians, for the points. Navarchs keep pillaging. The mass of agents still trains on neutrals, because ten level 10 Erased in school would cost half to all of a top-quarter credit income. | A few, late |
| **Resource specialists** (banker, researcher, ideologue) | When a slot is free and every governor seat is full | The ideologue hosts and pays almost nothing. The banker pays in credits easily. Governors are sent only by those two. | The ideologue; the banker for an Erased |
| **Fleet builders** | Rarely. Their Navarch slots are taken by fleets. | Rarely. The fee is technology, which they already ask teammates for, and there is almost no host. | No |
| **Players with three sessions a day** | Yes, when a slot is free. This is where it helps most. | One course for their best field agent once a teammate has a host, if the fee stays under a quarter of income | No |
| **Casual players** | Sometimes. The two least active players fill 36 to 38% of their governor seats today. | No. The fee is half their ideology income on day 8. | No |

The second-order effect is on the team. Today a faction's supply of levelled
agents depends on whether it has a heavy trainer. The university lets a team buy
that with income in place of attention. That removes a reason to be on the map,
and it removes a dependency on one or two people.

## The wording that swings the result

| Question the text leaves open | Effect |
| --- | --- |
| One Polytech slot per player, or one per building | About 4% or 7 to 9% more experience under the slot assumption; 7% or 18 to 24% outside the limit. The building is one per habitable planet, so a system can hold several. |
| Does a trainee use an agent slot | Working assumption: yes. Then the Polytech adds something only when every governor seat is full, and a student taken from the deck needs a free slot. Outside the limit the Polytech effect roughly doubles and the low-adoption university case grows from 14 courses to 22. |
| Is the trainee in the deck or on the map | Deck agents cannot be targeted, pay no wages and do not count. The Polytech and university read as on the map, the Pilgrimage as off it. |
| Halve the agent's own stat, or the whole defence | Level 10 Siderian, one Delete attempt: 31% with no penalty, 52% or 69%. The first is a governor's risk, the second an agent's in enemy territory. |
| Is an Erased student visible to enemies | Under today's rules it is hidden while its cover holds, and the penalty does nothing. |
| Can an agent re-enrol, and must moves respect the cap of 12 and the rule that no skill passes the main one | Without limits a skill can reach 17, and draining the main skill makes every later level refill it. In the high case one agent took two courses. |
| Is the fee fixed at entry or does it follow the level | A level 10 course costs 124,000 fixed, about 160,000 following. |
| Do buildings in a dominion give slots | Monolith capacity is 1.2 times higher in Citadel and 2.4 times in the longest match. |
| Which building hosts Navarchs | The Academy (4 of 14 players) or a shipyard (13 of 14). |
| How does an ally's agent enter your building | No code places an agent in a system its owner does not hold. |
| Is the Pilgrimage repeatable, and does the swapped slot keep its points | Decides whether agent types stay distinct. |

## Against the game's own design notes

- **"Planning is strictly better than presence."** All three features fit: each
  is set once and left. The university goes further and makes presence-based
  training of Erased and Siderians pointless for anyone with income.
- **Neutral content should fade after the early game,** and the notes name
  low-level agent experience. Today it does not fade: Citadel saw 220 neutral
  pillages in week three, with median loot of 320 credits. The university gives
  an alternative from about day 10 but does nothing to make neutral experience
  taper.
- **Anti-snowball should be opportunity for trailing players.** The Polytech
  slot is. The university and the Pilgrimage favour whoever owns Monoliths and
  ideology, who are the leaders.
- **The existing sizing of a passive building is far lower.** The faction
  Training Center gives 0.42 experience per hour at level 5, to one random
  agent, and its first level alone costs the faction treasury 300,000 credits. A
  Polytech slot gives 1.0 to a chosen agent for 1,500 credits, and the
  university 2.0. Both make the Training Center pointless.
- **No respec exists anywhere in the game today.** Reallocation would be the
  first, and it replaces the two substitutes players use now: swapping governors
  and waiting for the market to rotate.

## How this was estimated, and where it is weak

- **Mechanics** were read from the engine at the current master commit. The
  level curve was checked against 7,975 real agent records and the dice formula
  against 1,535 recorded rolls, with no mismatch in either.
- **Behaviour** comes from the four finished official Legacy matches: daily
  state snapshots (22 readings for Citadel, fewer for the others) and the full
  event and order history.
- **The replay** walks Citadel day by day and applies each feature to the
  agents, incomes and buildings that existed. Adoption rules are assumptions,
  stated in each table. A trainee or student is assumed to occupy an agent slot.
  Kill odds use the real attackers of each week.
- **One match carries the time series.** The other three confirm the shape at
  one or a few readings. Each match has 14 to 17 players, largely the same
  people, and two or three individuals set most totals.
- **Players would adapt.** They would build more Monoliths, keep Polytechs they
  now abandon, and enemies might start hunting trainees. The replay holds
  behaviour fixed, so supply is a lower bound and risk is the least certain
  part.
- **Experience is not power.** The replay counts experience and skill points. It
  does not simulate the battles, infiltrations and removals that stronger agents
  would then win.

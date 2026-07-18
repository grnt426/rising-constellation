# Human strategy feedback

Primary-source answers from the user (an experienced player) to targeted
questions about how humans actually play Fast/Flash, gathered 2026-07-18
to shape DT design and the personality-gene space. Companion docs:
`game-ai-v3.md` (architecture), `game-ai-training-handbook.md` (ops),
`game-ai-learnings.md` (results). When a DT change cites "human
doctrine", this file is the citation.

## Colonization

### Lane count follows income velocity, not a lane target (2a)

Humans usually run **one** colonization lane. What makes expansion fast
is not parallel Navarchs but **how quickly income re-covers a colony
ship's cost**: when the tech cost is re-earned in ~1 minute, the next
colony is nearly free to contemplate; at ~10 minutes, a deployed Navarch
carries heavy opportunity cost (could be scouting, or not deployed at
all). Same logic for credit. Mid/late game the ship cost is large but
not *that* large relative to everything else — there are techs worth
saving for more (bigger econ multipliers).

DT implications:
- Lane count is a **derived quantity**: `lanes = f(cost recovery time)`,
  not a genome target. A second lane unlocks when tech/credit income
  covers a transport's cost within a threshold window.
- Pipelining beats parallelism first: order the next transport while the
  current one sails; the Navarch is the scarce asset, not the shipyard.
- The transport purchase should never head-of-line-block a strictly
  better econ multiplier purchase — expansion pool, not global priority.

### Siting: quality dominates distance (2b)

Quality is superior to distance almost always. Exceptions: choke
points, adjacency to enemy sectors, excessive distance from where the
colony ship is produced. Higher quality offsets those concerns — better
econ return AND better production multipliers, so buildings complete
faster: a general multiplier on the whole economy. A chokepoint system
is usually better developed as a **fortress** (high defense/stability +
production) than as an econ colony.

DT implications:
- Target scoring: quality-dominant, with distance as a soft penalty and
  a hard cap on absurd voyages. Chokepoint/border flags change the
  *development plan* for the system (fortress spec), not primarily the
  colonize/don't-colonize decision.

## Mid-game doctrine

### Strategy is opponent-relative (2c)

The human mid-game question is "what strength do I have over my
opponent, and what are they weak to — then double down." Examples: bad
production systems or wrong tech/lex for fleets → go heavy
dominion/colony + infiltration; opponent took early military losses →
keep up the bombing campaign (near-impossible to recover from), then
pursue whatever victory path is convenient.

DT implications:
- Consolidation/endgame phase should read *relative* standings (my
  strengths vs. each opponent's), not absolute thresholds only.
- This is a natural personality axis for the GA: how aggressively to
  commit to the identified edge vs. hedge.

### Dominions: wide vs. tall (2d)

Two styles. **Wide**: take as many dominions as possible; flip own
systems to dominions and dominions to systems, developing them for high
econ; tax lexes make improving dominions worth it. **Tall**: take only
as many dominions as there are slots; little flipping — dominion taxes
are so low that flipping a high-production system loses nearly all its
econ. Flipping is only worth it if tax lexes (or a long-term tax-lex
strategy) let you keep the econ.

DT implications:
- Gate `make_dominion` on available slots (tall default). Wide play is
  only coherent WITH the tax-lex line — a package deal, not a knob.
- Wide-vs-tall is a legitimate **personality gene**, but it must select
  the whole package (dominion appetite + tax-lex priority) or it's a
  trap.

## Victory & late game

### Track choice: infiltration, then conquest (3a)

Realistic human closes are **infiltration** first, **conquest** second.
Influence is very difficult — for stalling games only, and needs very
high-quality systems deliberately overbuilt with housing. Sprinting is
tough to time or set up in Flash.

DT implications:
- Endgame DT track priors: shadows/infiltration ≥ conquest ≫
  population. The current victory-track DT should weight accordingly
  rather than treating tracks symmetrically.

### System development: specialize, but production floor first (3b)

Humans think in **system specializations** — this system looks good for
fleet production / credit / tech / ideo — and maximize in that
direction without trading away everything else. Governors with passive
output multipliers reinforce the specialization.

The universal build pattern:
1. Just enough housing/stability that pop grows immediately (excess pop
   works jobs).
2. Production on the most valuable orbitals (5-prod, or 4 if necessary):
   build speed compounds everything. **Floor: 100–200 prod in every
   system regardless of role.**
3. Blend in the specialization while keeping pop growth at maximum via
   housing/stability.
4. **Cap ~3–4 houses per planet** — more cuts into planets with high
   prod/sci/appeal modifiers. Pop target is "enough to work all jobs",
   not maximum; knock things down for houses late-game only if forced
   into influence.

DT implications:
- Development ladder per system: stability/housing gate → prod floor →
  specialization blend, with jobs-coverage (not raw pop) as the target.
- Specialization assignment at claim time (from planet modifiers +
  faction need) is code; *which* specializations a bot favors can be
  personality.

### Agent doctrine: train on neutrals, strike in groups (3c)

Humans train agents by **destabilizing neutrals** — safe from enemy
removal/seduction — to level ~7–8 in the intended skill, then use them
on enemies with high protection/resolve. Cross-training trick: any
skill's missions level the agent, so a lucky destab point trains a
seducer/propagandist safely. This avoids buying expensive market
agents.

When not training: flip dominions when slots are free, sit on systems
defending (seducers), or wait to group up for coordinated
**destab trains** (multiple destabilizers striking one system for huge
damage). Momentum, opportunity, coordination. A known alternative
style: constant streams of cheap low-level agents to force whack-a-mole
and degrade the opponent's decisions.

DT implications:
- Agent lifecycle DT: hire → train-on-neutrals until level ~7–8 →
  employ (enemy missions / dominion flips / defense) — replaces
  blind infiltrate spam.
- Group-strike coordination is a later, stateful behavior (task-system
  shaped: a CovertCampaign owning several agents).
- Whack-a-mole streaming vs. elite-group play is a personality axis.

### Fleets: defensive posture default, conquest is a gamble (3d)

Two classes: **defensive** fleets sit on own systems to prevent
catastrophic losses (opportunity cost paid to avoid a bigger loss);
**offensive** fleets are rarely conquest fleets unless neighboring
sectors and slots are free. Holding a slot free specifically to steal a
system is a *huge* gamble (forgone econ). Conquest only when it takes
victory-track points or denies the enemy resources/production. The
other offensive mode is making the fleet pay for itself in harm:
bombardment and pillaging — both very risky.

DT implications (deferred with DT-4):
- Default military posture = defensive garrison; offense is exceptional
  and goal-driven (VP or denial), not opportunistic.
- Current bots can barely afford fleets, so DT-4 stays behind the econ
  work — but when built, its skeleton is posture-first, not
  fleet-count-first.

## Where the GA gets space (summary)

Legitimate style axes surfaced by this feedback: opponent-edge
commitment (2c), wide-vs-tall dominion package (2d), specialization
preference (3b), elite-vs-stream covert style (3c), aggression/risk on
offense (3d), plus the existing expansion-appetite and threshold genes.
Mechanically-correct play (income-gated lanes, quality siting, prod
floors, train-on-neutrals) is **code, not genes**.

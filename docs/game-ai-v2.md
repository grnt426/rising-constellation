# Game AI V2 — evolvable decision structure

Status: **adopted 2026-07-04**, supersedes the V1 policy design in
`docs/game-ai.md` §7 (the V1 doc remains the reference for the training
infrastructure, fitness design, and research survey — none of that changes).

## Why V2

V1 proved the pipeline end-to-end: headless turbo runner, genome-driven
policy, niche archives, arena-bred fleet blueprints, unattended marathon
training. It also exposed a ceiling, diagnosed in play data:

1. **The genome tuned a fixed program.** Every bot ran the same decision
   pipeline; genomes only biased it. A weight can't express a behavior the
   pipeline can't produce — targeting was hard-coded "nearest eligible
   system", fleet building was hard-coded "one ship per decision when the
   production queue is idle". Militant genomes existed (raid weight 4.3)
   whose phenotype attempted **zero raids in a full game**, because the
   fleet path is ~25 serial decisions while infiltration is one.
2. **Options were silently missing.** The build catalog exposed 14 of 34
   Fast-mode buildings (no defense, no counterintelligence, no markets), so
   the counter-play layer around fleets didn't exist in bot games at all.
3. **Shadows dominance is partly an artifact.** Infiltration is the only
   aggression the V1 policy could cheaply express. In human games fleets
   dominate the map; bot games couldn't reproduce that meta.

V2's thesis: **strategy structure must itself be evolvable**, and the
action space must contain the real game.

## Architecture

Three changes, in dependency order.

### 1. Macro-actions (action abstraction)

*The insight: a human "builds a fleet" as one intention, not 18 decisions.*

- **Fleet commission** — when the strategy layer wants a fleet (blueprint
  chosen by the aggression/mix/investment genes, exactly as V1), the
  admiral's system enqueues **the whole composition in one decision**,
  bounded only by current resources (the engine deducts per order; the
  production queue has no idle requirement — that gate was V1 policy code,
  not an engine rule). Unaffordable remainder tops up in later waves under
  the same commitment.
- **Fleet employment** — a separate stage watches for *built, idle* fleets
  at or above a readiness fraction (`fleet_readiness` gene) and assigns
  them to raid / conquest / defense targets through the evolvable targeting
  layer below. The strategy node never plans an 18-step sequence; it spawns
  assets, a cheaper layer spends them.

This mirrors the temporal-abstraction lesson from large-scale game RL
(options framework — Sutton, Precup & Singh 1999; AlphaStar and OpenAI Five
both required hand-engineered action abstraction despite million-game
budgets): macro-actions are designed, not discovered, at any budget we can
afford.

### 2. Evolvable utility targeting (structure in the genome)

*The insight: "which system to hit" is a ranking over all visible
candidates, and the ranking function should be evolvable structure, not
frozen code.*

- A **typed consideration library** (`Headless.Bot.Considerations`): each
  consideration maps a candidate system to a normalized 0..1 score using
  only bot-visible state (galaxy summaries: position, population,
  development, sector VP, owner). Examples: `proximity`, `population`
  (pillage/economy value), `development` (progress to degrade),
  `sector_vp`, `leader_target` / `weak_owner` (hit the winner vs. the
  weak).
- The genome gains a **structural section** — for each decision point
  (`colonize`, `raid`, `conquest`, `defend`, `infiltrate`, `destabilize`) a
  *list* of `[consideration, weight]` pairs. Candidates are scored by the
  weighted sum; the argmax is the target. Legality filters (scope, reserved
  targets, lane reachability) remain code.
- **Structural mutation operators**: add a consideration from the library,
  remove one, replace one, perturb weights. Crossover is not used by the
  current search (mutation + fresh randoms), which sidesteps the competing
  conventions problem for now.
- **Complexification, not pruning** (NEAT — Stanley & Miikkulainen 2002):
  default genomes start *minimal* (each decision point = the V1 behavior,
  e.g. raid = `[[proximity, 1.0]]`), and structure grows by mutation. A
  new consideration usually hurts fitness before its weight is tuned, so
  structural innovations need protected niches —
- **Structural niching**: the marathon archive bucket key gains a
  structure-size dimension alongside the behavioral exp/mil/shd axes, so a
  structurally novel genome competes against its own kind while its
  weights adapt (NEAT speciation, implemented on the existing MAP-Elites
  machinery — Mouret & Clune 2015).

Why this and not free-form genetic programming: grammar-constrained
composition of a typed library (grammatical evolution — Ryan & O'Neill;
strongly-typed GP) guarantees every genome is valid and keeps champions
*readable* — "scores raid targets 0.7·development − 0.3·proximity" is a
strategy document, and reading champions has been our main balance-signal
instrument. The industry-adjacent form is utility AI with evolvable
considerations (Dave Mark's Infinite Axis Utility System).

Note the difference V2 honors: a **weight of zero** is "I have this choice
and rank it nowhere"; an **absent node** is "this choice isn't part of my
program". Absent nodes keep the search space small (complexification) while
the library keeps re-adding them cheap — the evolvability sweet spot the
CGP neutrality literature points at (Miller & Thomson 2000).

### 3. Complete option space

- **All 34 Fast-mode buildings** in the build catalog (V1 had 14) — adds
  every defense building, counterintelligence, radar, markets, lifts,
  finance, spatioports, monuments, high factories, the military school.
- **All 39 Fast-mode patents** (V1 had 27 after the military extension) —
  adds the economy branch (open_defense, dome_defense_2, open_research,
  open_happiness, dome_ideo, dome_industries, open_credit, dome_mobility,
  open_mobility, open_island, dome_academy) and transport_2 (invasion).
- Doctrines/lexes remain the curated 16 — completing that catalog is a
  follow-up (the doctrine tree needs the same data-dump treatment).

Nothing in the option space is pre-judged: every building/patent gets a
weight gene, threshold ≥ 0.5 = "ever buy", magnitude = priority.

## Genome v2 shape

- **Flat genes** (unchanged mechanics): ~89 purchase weights (34 build +
  39 patent + 16 doctrine), mission weights, economy scalars, fleet
  doctrine (`blueprint_aggression`, `blueprint_mix`, `fleet_investment`,
  `army_size`, new `fleet_readiness`, new `w_defend`), 4 focus-family
  multipliers. JSON-serializable floats keyed by string.
- **Structural genes**: `genome["targets"]` = map of decision point →
  list of `[consideration_name, weight]`. Variable length. Archived V1
  genomes lack the key and are seeded with the minimal default on first
  mutation — backward compatible with every existing archive.
- `dist_weight` is retired (subsumed by the `proximity` consideration).

## V2.1 — opener books, desire propagation, deployment gates (adopted 2026-07-05)

Driven by a live finding (user analysis, "Bot Test" instance): the shipped
tetrarchy champion — 4/4 training "wins", fitness 481 — was a bot that
**cannot play the game**. Its genome pruned `w_build_ideo_open` to 0.00
(zero ideology income, ever), pruned `w_patent_shipyard_1` to 0.00
(silently unreachable ship tree, so its `capital_1 = 10.0` and conquest/
raid genes were dead code), evolved a 14.8k `credit_floor` that starved
early development, and priced `transport_1` last in its purchase order
(~75k cumulative tech away — no colony would ever be attempted). Its
training record *says so*: `colonies: 0.0, military: 0.0` across every
evaluation game. It "won" anyway — clock-out attrition against opponents
playing equally badly, plus covert VP. Three structural conclusions:

### 1. Opener books (the forced opening is code, not strategy)

The first ~200 UT of every faction's game are rote and near-forced —
build the starter tech building (Delta Polytech / `university_open`),
housing (`hab_open_poor`), unlock `citadel` at 50 tech, build the Citadel
(`ideo_open`), buy + activate the first lex (Age of Exploration /
`agent`), buy Urbanization (`infra_open_1`). Refusing any of these makes
a real game unwinnable; *there is zero chance to win a normal game
without them*. Evolution spending budget rediscovering — or, as shipped,
successfully avoiding — a forced sequence is pure waste.

So the opening becomes **code** (`Headless.Bot.Opener`), under the same
V2 principle that legality is code: declarative steps with observable
completion predicates (policies never see execution results), engine
refusals treated as waits, one **filler house** allowed while a purchase
step saves income (user rule), a timeout valve (600 UT) so a pathological
map can't trap a bot in book mode, and the genome's `credit_floor`
deliberately ignored for opener purchases (a pathological evolved floor
must not be able to starve the forced opening).

The genome keeps exactly one opening choice: `opener_variant` selects a
variant from the faction's book (currently: install the starting deck
agent as **governor** vs. **deploy** it on-board for scouting). Books are
per-faction so variants can diverge later (lex-save targets, sterile-
planet beeline vs. second habitable) — deliberately *not* over-prescribed
beyond a strong foundation. Handover to the evolved policy is explicit
(`mem.opener.done`); opener completion is reported per game and feeds
both stats and deployment gates.

### 2. Desire propagation on prerequisite trees

A weight of zero on a prerequisite could sever an entire branch the
genome *wanted* (shipyard_1 = 0.00 under capital_1 = 10.0; likewise
`system_1` is the ancestor of every dominion lex). V2.1 semantics:
purchase stages rank by **effective weight** = `max(own, 0.9 × best
descendant)`, recursively up the patent/doctrine trees. Zero now means
"never *for its own sake*" — a stepping stone is bought when something
above it is wanted, at a small depth discount. Doctrine *activation*
(scarce slots) still uses raw weights: stepping stones get bought, not
seated.

### 3. Deployment gates (training fitness ≠ shipping eligibility)

Training fitness stays relative and permissive — that's the gradient,
and the archive deliberately preserves weird niches as breeding stock.
Shipping to humans is a different question, so `mix
headless.export_personalities` now applies **absolute viability gates**
per champion: `games ≥ 2`, mean `colonies ≥ 1`, `mean_vp ≥ 6`, and
`opener_rate ≥ 0.9` (fraction of eval games whose opener completed;
absent in pre-V2.1 archives → passes, the colonies gate carries). These
are "can speak the game's verbs" checks, not strategy prescriptions — a
covert specialist or dominion-rusher passes all of them. The Generalist
fails three.

Two training-side nudges accompany the gates: every evaluation now
includes the scripted **HomeDev baseline** as one opponent (self-play
pools drift into private equilibria; "beat the baseline" anchors fitness
to something a human game resembles), and the **win bonus is discounted
for stalemate wins** (300 → 120 when the winner never reached 8 VP) so
clock-out attrition can't dominate selection. Archives are kept as-is
across the transition: stale exp0 fossils stay as diversity, the export
gates keep them out of the pack, and opener-equipped genomes land in
different (exp1) buckets anyway.

## V2.2 — Econ ROI module + boomer pace-setter (adopted 2026-07-07)

Trigger: an 86-hour fitness plateau (best flat at 570–670 since the
slot-first window) plus a live bot-opponent game where a human
out-developed the shipped champion 3–4x on every axis (pop 88 vs 35,
tech output 188 vs 20) — the bot sat on 67k idle credits behind a
patent wall its 20 tech/min could not break. Diagnosis: coevolution
equilibrated at a slow tempo because bots only ever had to beat bots,
and static build weights cannot notice "tech income is my binding
constraint."

Two additions, both respecting the code-vs-genome rule:

- **`Headless.Econ`** — a bottleneck-relief strategy module (code). Per
  system it classifies the binding constraint (housing-bound /
  labor-surplus / labor-starved / slots-bound) from population,
  habitation, and free workforce; empire-wide it finds the patents that
  block *wanted* buildings (tech-starvation signal). Build candidates
  get additive score bonuses (per system — a housing-bound colony and a
  labor-surplus core world want different things on the same decision);
  blocked patents get desire boosts on the per-decision genome copy.
  Bottleneck relief handles chained ROI without a forward simulator: a
  refinery is worthless without free workforce → workforce needs housing
  → housing needs tiles → tiles need infrastructure; whichever link
  binds NOW is the highest-marginal-value purchase, and relieving it
  exposes the next link. Hoard-vs-invest falls out for free: hoarding is
  only right when no purchase relieves a bottleneck. One new gene,
  `w_econ_roi` {0,3}, sets trust in the module (0 = off — inert
  onboarding for legacy champions; 3 = full trust).

- **The boomer** (`Headless.Econ.boom_genome/0`) — a hand-tuned econ
  racer at full module trust, covert program zeroed, expansion-lex
  ladder maxed. It replaces HomeDev as the permanent baseline opponent
  in every marathon evaluation: the pace-setter races econ on the
  assumption the opponent is doing the same, so a genome that can't
  beat or out-tempo it stops winning evals. Fitness stays pure
  (defeat-the-opponent; no development-velocity proxy terms — user
  ruling 2026-07-07): tempo pressure comes from WHO you must beat, not
  from reward shaping. Because the boomer lives in Tunable's own gene
  space, evolution can copy any part of the recipe that wins; it is
  also injected as an immortal `seed_boom` archive entry (fitness 550)
  in all five factions.

## What stays from V1

Headless turbo runner and Scenario maps; CRN paired seeds; victory-first
fitness; niche archives + marathon loop; the arena-bred blueprint table
(`mix sim.blueprints`) as the fleet-composition source; §4 control-theory
guards (dwell times, cost gates, strict-priority saving); crash isolation.

## Roadmap after V2.0

1. **Response curves** on considerations (quadratic/logistic gene per
   pair) once linear weights plateau.
2. **Neuroevolved scorers**: replace hand-written considerations with tiny
   shared-weight nets (~12 features → 8 → 1) scoring each candidate,
   evolved by CMA-ES on the same harness (permutation-invariant candidate
   scoring — Deep Sets, Zaheer 2017). Feasible at our ~34k games/day; deep
   RL from raw state is not (AlphaStar/OpenAI Five scale).
3. **LLM-as-mutation-operator over the library** (Eureka 2023 / FunSearch
   2023 / AlphaEvolve 2025, already locked in V1 plan): the LLM reads
   telemetry and *writes new consideration functions*; evolution decides
   if they earn their keep. This is the "stop hand-coding every option"
   machine — humans review survivors instead of anticipating filters.
4. Doctrine catalog completion; enemy-fleet visibility for a true threat
   consideration; counter-blueprint selection from the arena cross-play
   matrix when scouting exists.
5. **Campaign nodes (user design, 2026-07-05)**: a reservation-based
   coordination layer above the stage pipeline. A campaign node RESERVES
   heterogeneous assets (fleet + Siderians + Erased) against a single
   objective (e.g. conquest of one system), waits for readiness, then a
   campaign manager sequences the combined-arms execution — destabilize
   to drop defense, counter-agent screen against the defender's
   removal/seduction plays, then the invasion — and releases assets on
   conclusion (a healthy surviving force can be immediately re-reserved).
   This is hierarchical temporal abstraction (options-over-options); the
   reservation ledger lives in policy mem, campaign trigger/composition
   thresholds are genes, and execution sequencing is code (legality/
   choreography, not strategy). Prerequisite: none — macro-actions and
   counter-agent play (both live) are the building blocks. This is the
   biggest known gap between bot play and skilled human play, which
   coordinates exactly such multi-agent convoys around critical swings.
6. **Known expressibility gaps** (mismatch audit 2026-07-05): sabotage
   missions not yet in the policy; enemy system STABILITY not visible to
   targeting (Earthquaker probes approximate it via population); no
   reactive/conditional weights (e.g. "being infiltrated → build
   counterintelligence") — considerations are static per-genome.

## Literature index

NEAT / complexification / speciation: Stanley & Miikkulainen 2002.
Quality-diversity & niches: Mouret & Clune 2015 (MAP-Elites), Lehman &
Stanley (novelty search). Neutrality: Miller & Thomson 2000 (CGP).
Grammar-constrained program evolution: Ryan & O'Neill (grammatical
evolution), Montana (strongly-typed GP), behavior-tree evolution (Perez et
al. 2011, Mario AI). Utility AI: Dave Mark, IAUS (GDC). Temporal
abstraction: Sutton, Precup & Singh 1999 (options); Vezhnevets 2017
(FeUdal). Scale references: Vinyals 2019 (AlphaStar), OpenAI Five 2019.
Entity-set scoring: Zaheer 2017 (Deep Sets). LLM-guided evolution: Eureka
(Ma 2023), FunSearch (Romera-Paredes 2023), AlphaEvolve (2025).

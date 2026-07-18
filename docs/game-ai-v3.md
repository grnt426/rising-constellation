# Game AI V3 — the strategist owns strategy

Status: **adopted 2026-07-14**. Supersedes V2's core thesis. V2's doc
(`game-ai-v2.md`) remains the reference for macro-actions, opener books,
desire propagation, deployment gates, and the Econ ROI module — all of
which V3 keeps. V1's doc keeps the training infrastructure and research
survey.

Migration status (2026-07-18):
- **Phase 1 strategist — DONE** (8d2321f): phases + per-phase directives
  + phase telemetry. Since extended with the ideology bootstrap,
  research-chain completion, growth rungs (phase-aware priorities), and
  the endgame victory-track DT.
- **Phase 2 budget pools — DONE** (50493c2 + c26ef4d): two corrections
  found by regression — splits must be per-RESOURCE (scarce tech/ideology
  concentrate on the critical path; abundant credit partitions), and
  purchasing saves PER POOL (a global save-target head-of-line blocks
  funded pools).
- **Phase 3 tasks — PARTIAL**: colony-task lifecycle telemetry shipped
  (order/built/dispatch/claim stamps → stats.colony_cycle); full
  asset-ownership tasks (ConquestTask etc.) remain.
- **Phase 4 genome shrink — NOT STARTED.**

Operational learnings and results live in `game-ai-learnings.md`;
day-to-day operations in `game-ai-training-handbook.md`.

## Why V3 — the two-week verdict on the V2 thesis

V2's thesis was *"strategy structure must itself be evolvable."* Two weeks
of marathon training (~85k games, ~17k evals) returned a verdict:

1. **Every step-change came from hand-coded decision structure.** The
   expansion critical path, the tech bootstrap, the happiness gate, the
   growth-curve node, colonizer hiring — each broke its wall the day it
   was coded, never before. Between code changes, mean fitness drifted
   0–5%/day; within-era population medians were flat.
2. **The GA never crossed a structural valley.** `orbital_research` sat at
   weight 1.0 for a week, unbought, while tech starved everything — no
   gradient exists toward a multi-step ladder whose intermediate rungs are
   fitness-neutral. The credit reservation was selected *down* rather than
   routed around. No lineage assembled happiness→population→tech until we
   injected it as hand-designed seeds — which then outperformed the
   population immediately (+21% mean fitness).
3. **The arithmetic doesn't support scalar-fitness GA at our scale.** One
   noisy scalar per ~6-game eval, ~80 evals/hour, over a 2,400-UT game
   with thousands of decisions: the information throughput cannot do
   credit assignment for sequential strategy. Shipped 4X/RTS AIs are
   overwhelmingly hand-crafted decision systems with small tuned
   components; the learned-from-scratch exceptions cost compute measured
   in GPU-decades.

User verdict (2026-07-13): the decision layer is where all the progress
came from; the GA is a tiny slice deciding when/how the hand-built layer
acts, and it is inefficient in both time and CPU. **V3 inverts the
premise: code owns strategy; genes own personality.**

The original V1 survey actually locked this architecture — *"utility
strategist + budget pools + taskmaster portfolio."* V2 built the
portfolio (the decision nodes) and deferred the other two pillars to
evolution. V3 builds them.

## Architecture — three pillars

### 1. Phase strategist (explicit state machine)

The top-level controller. Phases, detected from observable state with
hysteresis (no flapping):

| phase | entry (sketch) | owns |
|---|---|---|
| `:opening` | game start | the opener book, unchanged (code) |
| `:foundation` | book done | growth curve (stability>24, headroom>10, pop→target), university/research ladder, first colony chain |
| `:expansion` | first colony + foundation invariants met | lanes = open slots, colonies toward the genome's target, foundation invariants re-established on every new system |
| `:consolidation` | colony target met or map share capped | colony development, defense posture, covert screen, second-wave economy (research_open, high_factory) |
| `:endgame` | victory tracks near thresholds (any faction) | pick a track from standings (conquest / population / shadows), sprint |

Each phase declares **goals** (checkable predicates), a **budget split**
(pillar 2), and a **node gating/priority table** (which of the existing
taskmaster nodes run hot, warm, or off). Phase and goal state are
telemetry: recorded at checkpoints, aggregated in results.jsonl, visible
on the dashboard (phase timing distributions become a first-class chart).

Everything the current `apply_expansion_priority` + growth arms do
piecemeal migrates into phase goal logic — same knowledge, one owner,
ordered by design instead of by 11.0-weight collisions.

### 2. Budget pools (replaces reservations, floors, and priority hacks)

A per-decision allocator splits each resource's *spendable* amount
(current value above a solvency floor) across pools:
**expansion / economy / military / covert**, by the phase's split table ×
the genome's lean multipliers. Nodes spend only from their pool; an
unspent pool **rolls over**, which is how saving for a 12k transport or a
2,000-tech ship happens *without* strict-priority reservations.

This retires an entire recurring bug class — every regression of the last
week was a shared-resource starvation (ship credit vs development, admiral
tech vs patents, covert hires vs the colonizer arm's one-hire-per-tick
claim). Deleted on arrival: `reserve_first_colony`/`reserve_followup_colony`
mechanism, scattered `credit_floor` gates, the colonizer-first hire arm's
special-casing. One-per-decision limits relax where pools make them safe
(each pool can hire).

### 3. Task system (V2 roadmap §5 "campaign nodes", generalized)

A task is `{goal, owned assets, budget grant, state, deadline, telemetry}`
living in policy mem. First implementation: **ColonyTask** — "establish a
colony at X" reserves an admiral, orders the ship from the expansion pool,
sails, claims, and reports a duration breakdown (ship-build wait, travel,
claim). Tasks replace per-tick re-decisions for multi-step goals and
give us the cycle-time telemetry that the current sys=3 plateau hides.
Later: ConquestTask (the combined-arms campaign the user designed —
destabilize → counter-agent screen → invasion), CovertCampaign.

## Genome V3 — personality, not policy (~24 genes)

Dropped (~120 genes): all `w_build_*` (34), `w_patent_*` (~40),
`w_doc_*` (40), most `w_mission_*`, the reserve pair, `credit_floor`,
`hire_reserve`. Building/patent/lex choice inside a pool comes from the
coded ladders plus the Econ ROI module for surplus — the genome no longer
holds an opinion on every SKU.

Kept/added (illustrative):

- `opener_variant` — which book
- phase thresholds: `foundation_pop_target`, `expansion_colony_target`,
  `endgame_trigger_margin`, phase-entry hysteresis
- pool leans: `econ_lean`, `military_lean`, `covert_lean`,
  `expansion_lean` (per-phase multipliers on the split table)
- posture: `aggression`, `risk`, `covert_focus`, `blueprint_aggression`,
  `blueprint_mix`, `army_size`
- targeting: the `targets` consideration lists stay (small, genuinely
  tunable structure — scoring *which* system, not *whether* to expand)
- growth: `growth_pop_target` (the ~70-pop knee is personality)

A ~24-gene space over a strong skeleton is where a GA actually earns its
CPU: personality diversity per faction, archive opponents, and regression
benchmarking of every strategist change. Optional: densified fitness
(checkpoint-economics bonus terms) so tuning has gradient before game end.

## What stays unchanged

The marathon harness, niche archives, seeds mechanism, golden-line
benchmark, funnel/blocks telemetry, dashboard, opener books, Econ module,
arena-bred blueprints, the employment doctrine, View/Act plumbing, and the
V2 macro-action space. V2 champions remain runnable as benchmark
opponents forever (the Tunable policy module is not deleted).

## Migration plan — four phases, each gated

Gate for every phase: no regression on golden-line frontier metrics or
winrate vs the frozen V2 archive champions.

1. **Strategist** (`Headless.Strategist`): phase detection + per-phase
   directives, initially *driving the existing Tunable nodes* (absorbs
   `apply_expansion_priority`/growth arms as phase logic). Phase enters
   telemetry. Behavior change minimal; control structure lands.
2. **Budget pools**: allocator + node pool-spending; delete the
   reservation/floor/priority hacks. This is the deepest edit of Tunable.
3. **ColonyTask**: task lifecycle in mem; colonization moves onto it;
   cycle-time telemetry answers the sys-plateau question and drives the
   next fix from measurement.
4. **Genome shrink + marathon migration**: v3 genome, fresh v3 archives
   (v2 archives frozen as opponents), seeds re-expressed as v3
   personalities, dashboard genome explorer + policy page updated.

Acceptance for V3 overall: the **default, un-evolved** V3 bot beats V2
archive champions >55% and reaches the golden line's cp50 systems/pop
marks; evolution then tunes personalities from a winning baseline instead
of searching for one.

## Risks

- **Ossified meta**: a hand-coded strategist plays "our" game. Mitigation:
  personality diversity via the GA + niche archives; the V2 roadmap's
  LLM-as-mutation-operator still applies to the consideration library and,
  later, to strategist goal parameters.
- **Overfitting the golden line** (one casual human game): mitigate with
  additional focused human games when the bots get close.
- **Migration churn**: phases are individually shippable and individually
  revertible; V2 keeps running in the marathon until Phase 4 flips it.

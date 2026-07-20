# Game AI — learnings and results

What two-plus weeks of training bots taught us about the game, about
training methodology, and what the bots can actually do now. Companion to
`game-ai-training-handbook.md` (operations) and `game-ai-v3.md`
(architecture). Last updated 2026-07-18, game version 1.1.0.

## Part 1 — the game's causal economy (Fast mode, prod data)

The single most important discovery: bot strength was never blocked by
"strategy" in the abstract — it was blocked by a chain of concrete
economic gates, each invisible until instrumented. The chain, in causal
order:

**Stability (happiness) gates population.** Growth per tick =
`(base 0.03 + stability×0.002, stability useful to 25) ×
(habitation + 0.75 − pop) × 0.1 × pop_factor`, NEGATIVE below 0
stability. Fast-mode base is only 12. The one ungated hab
(`hab_open_poor`) costs −5 each; mines charge crowding (−0.25×body pop);
finance −32. Bots spammed poor habs and literally built themselves into
population decline. Player playbook (confirmed in data): housing headroom
> 10 AND stability > 24 while pop < ~70 (the 120-cap factor halves the
rate there); push past 70 only for workforce or population VP. The two
rules bind IN SEQUENCE on a young system: housing first at modest
stability (growth is multiplicative and headroom binds first), then the
24 line — a bar of 24 from the start blocks the only early housing, a
bar near 0 floods poor habs into stability collapse; ~6 forces the
alternation a human plays.

**Population gates both unlock currencies.** Tech and ideology are
pop-scaled twins: `university_open` and `ideo_open` each yield
`4 + 0.6 × body_pop` (ungated, one per body); `monument_dome` yields
1×system pop. Everything else is patent-gated: `research_orbital`
(3×body_tec, 1,200-tech patent), `research_open` (22×body_tec, 4,500 +
84k credits), `high_factory_dome` (20×body_tec, deep chain),
`ideo_credit_open` (7×body_act behind the cheap 1,200-tech
`open_island`), happy-pots (act-scaled, also pay tech).

**The unlock currencies gate everything else.** Every patent is paid in
tech (first colony = 600 patent + 2,000 ship = 2,600 tech); every lex in
ideology (expansion ladder: agent 50 → system_1 1,200 → dominion_1 3,000
→ sys_dom_2 6,000 → system_4 8,000, with per-owned inflation). Credit is
NEVER the long-run constraint — bots repeatedly hoarded 0.5–2M idle
credits while tech/ideology trickled. Any analysis that says
"unaffordable" must name the resource.

**Body ratings are multipliers.** Bodies carry
technological/activity/industrial factors and population; rating-scaled
buildings placed first-fit throw the multiplier away. Smart siting
(research on the highest-tec body, universities/ideo on the populated
body) moved cp75 tech income ~50% in one batch.

**Colonization is a logistics pipeline**, and its cost is time, not
money: order → build (production-bound at the DOCK's output; a fresh
colony is the worst shipyard in the empire) → idle → sail → claim.
Measured ~345 UT per colony round trip (1/7 of the game) before
hub-routing; the ship wait dominates travel ~2:1. Serial-by-default:
one Navarch = one lane; bots bought admiral-cap lexes for days without
ever hiring into them.

**The market always stocks agents** (slots refill on purchase); "can't
hire" is always an affordability gate, usually early-game credit for the
cheapest common admiral (1.2–3k credit + 400–700 tech, ×21/×36 at higher
ranks, with per-repurchase inflation).

## Part 2 — methodology learnings (paid for in wall-clock)

**Telemetry before theory, always.** Every wall of the project was
mis-theorized at least once and settled by instrumentation: the
"credit-starved transport" was tech-starved; the "tech-starved" hires
were credit-starved; the market "absence" was affordability; my own
tech-cost theory of hiring was wrong within one deployed telemetry
split. Rules distilled:
- Never let one gate name cover two failure causes (absence vs
  unaffordable; credit vs tech). Split first, conclude second.
- A funnel must report the FIRST unmet link (strict prerequisites), not
  the furthest stage reached — otherwise later stages mask earlier ones.
- Aggregates lie by composition: happiness means diluted by young
  colonies (success lowered the metric), voyage means inflated by a
  random band-map draw (looked like an engine regression). Segment by
  system, by map class, by cohort before reading any mean.
- Verify SVG/UI by rendered geometry, not by counting elements in
  source (`class=axl/>` — one unquoted attribute blanked every chart for
  days while the HTML "looked correct").

**GA economics.** A weight-vector GA at ~40 evals/hour on a noisy
6-game scalar cannot do credit assignment for multi-step strategy.
Measured: 0–5%/day drift between code changes; every step-function gain
was hand-coded structure. The GA never crossed a valley whose
intermediate rungs were fitness-neutral (`orbital_research` sat unbought
at weight 1.0 for a week). What the GA is genuinely good for: tuning
numbers inside a strong skeleton, maintaining diverse opponents
(niches), and regression-testing changes. Corollaries:
- New genes must be RANDOM-SEEDED across the population's range
  (`Tunable.seed_missing/2` in archive load). A uniform default has zero
  variance — selection cannot see it; the gene is "added" in name only.
- Hand-designed seed genomes are legitimate and cheap: the synthetic
  champions (+21% mean fitness immediately) put a causal ladder into the
  gene pool that evolution then refined — myrmezir's top champion is a
  seed descendant.
- Bugs become selection pressure: evolution routed around a broken
  policy-slot purchase by down-weighting the gene that triggered it.
  If a mechanism looks "selected off", first ask whether it works.

**Shared-resource design.** The V2-era recurring bug class was two
consumers fighting over one unpartitioned stock or one one-per-decision
slot (ship credit vs development, covert hires vs the colonizer arm —
the latter collapsed win rate 44→28% in three hours). Budget pools fixed
the class, with two non-obvious requirements discovered by regression:
splits must be PER-RESOURCE (credit is abundant and partitions fine;
scarce tech/ideology need concentration on the phase's critical path),
and purchasing must save PER-POOL (a single global save-target creates
cross-pool head-of-line blocking — a funded pool stalls behind a saving
one).

**Merge hygiene.** Never bulk `--ours`/`--theirs` a conflicted file
where both sides added functions — reconstruct (their base + our
call-site edits); we shipped a boot-crashing UndefinedFunctionError by
keeping "our" file wholesale. After any merge, the first eval batch's
game-length sanity check (phase-decision totals) is mandatory: crashed
engines produce plausible-looking numbers on garbage 26-decision games.

**Attribution discipline.** One lever per restart wherever possible;
telemetry for the lever ships WITH the lever; acceptance metric named in
the commit message. The rotation of results.jsonl on a schema change
(and merging history back) matters — the dashboard's time-window filter
plus the regime-boundary timestamp made mixed-schema data readable.

## Part 3 — results timeline (each wall, with numbers)

| date | wall | fix | measured effect |
|---|---|---|---|
| 07-08 | Champions hoarded millions on one system; colony patents starved behind strict priority | Expansion critical path (code-forced lex/patent/ship chain) | colonies 0 → 4+, slot use 80–100% |
| 07-09 | One colonizer sailing back and forth; agents idle | Parallel-admiral lex + unified agent employment | spies 26→97% on enemies, myrmezir winrate 36→51% |
| 07-10 | "Colonization stalls" misread as credit | Funnel (8-stage) + blocks telemetry + ln(50x) colony fitness | Named the true gates; win-colonies climbing since |
| 07-11 | Tech, not credit: 2,600-tech colony chain vs 14–28/tick income; 555k idle credits | Tech bootstrap (universities/research forced) + tech-only reservation | trap named; setup for growth work |
| 07-12 | Population flatlined 23→27 all game: happiness death spiral (poor-hab spam, −5 each) | Happiness gate + delta-aware bar; opener fillers → universities | pop growing for the first time; tech followed |
| 07-12 | Pop ceilinged at habitation; stability pinned below 24 | Growth-curve node (stability>24, headroom>10, pop-target genes) + growth patents | frontier stability 32–43, pop 50→90 |
| 07-13 | Median ONE Navarch forever; colonization serial | Need-scoped colonizer hiring (one lane per open slot) — after a cap-scoped version starved covert hiring (win 44→28%, reverted in 3h) | cp75 navarchs 1→2–3; winners' colonies 1.6→1.9 |
| 07-14 | V3 pivot: code owns strategy, genes own personality | Strategist phases; budget pools (after per-resource + per-pool-saving corrections) | zero-colony 49→24–29%; expansion phase 4→32% of decisions |
| 07-15 | 220-UT ship wait; sys plateau at 2–3 | Cycle decomposition (build 215 vs idle 30) + shipyard-hub routing + research-chain completion | build 215→~170; research_open 0.5×/game → 12/12 evals; tech/sys 29→56–60 |
| 07-16 | Endgame steered nothing (17% of decisions) | Victory-track DT (population/conquest/visibility from standings) | win 49% last third; converting economy → VP |
| 07-17 | cp25 opener-bound; hab=pop=36 zero headroom | Infra in the opening book (async step) + early housing window (bar 6) | cp50 recovery; col/eval records 1.7–2.1 |
| 07-17 | Ideology invisible; both currencies under-produced; first-fit siting | Ideology telemetry + bootstrap + open_island rung + smart siting | cp75 tech 130 (was 83–89); ideo_credit from zero to standard; frontier tech/sys ~90 vs human 101 |
| 07-18 | One-DT-per-day dev pace; 12h attribution wait per change | Experiment flags (per-iteration A/B, evolver-only) + fixed-seed smoke suite + human-strategy doc; round-2 batch F1–F4 behind flags | smoke PASS both arms, guarantee counters firing; first flag-stratified night = round2b |
| 07-18 | Victory agent crashed at EVERY game end since the 1.1 merge; evals/h 78→50 | Merge dropped `headless:` metadata key — restored (206efa1) | 5,373 crashes/night → 0 in 24h; steady 54 evals/h (remaining 54-vs-78 gap = pivot-cost suspect, benchmarked separately) |
| 07-19 | Round-2 A/B verdicts (24h, n=1165): five flags, five answers in one day | WINNERS hard-coded: first_colony_guarantee (zero-col 22% vs 29%), dominion_slot_gate (win 48.7% vs 44.6%). LOSERS deleted: cap_rung_guarantee (col 1.41 vs 1.78 — ideology starvation), income_gated_lanes (fit −19), train_on_neutrals (fit −24 — visibility-VP delay) | consolidation shipped with round-3 flags: quality_siting (2b), dev_ladder (3b: prod_floor gene, specialization blend, 4-hab/body cap) |
| 07-20 | Round-3 A/B (12h, n=524): dev_ladder decisive, colony COUNT re-identified as THE gap | dev_ladder WON (win 53.2% vs 46.5%, fit +27, cp50 income 524 vs 407, build time 166 vs 179 UT) → hard-coded. quality_siting marginal (win −1.8) → held one night. Diagnosis: per-system economics now near golden parity on the frontier; navarch median stuck at 1 while admiral_1 bought 5.4×/eval → colony count is the whole gap | round-4 flags: second_lane (raw-stock 2nd navarch hire), expansion_ideo_share (cap-ladder pool boost) |
| 07-20 | Round-4 first 3h: engine-error FLOOD (109k vs round-3's ~5k), best=0.0, 84-min stall — marathon wedged | RCA: the branch (base Jul-17) lacks the orchestrator SELF-HEAL fix (9ac5be8), so a lost orchestrator round-trip leaves a character permanently `:locked`; big-map games hang → hit the 10-min kill-timeout in series → iteration stalls. round-4's aggressive expansion (more jumps/hires) tipped a background wedge into a cascade. NOT a policy bug; the bot was the victim (View `Game.call` timeouts → 6-19 decisions/game). Fix: cherry-picked 9ac5be8 (jump-interception gate 67bd7b3 was already present). NOTE: these fixes are on feature branches, NOT origin/master — master has the wedge too |

**Standing at last clean read (2026-07-18):** win ~50%, colonies/eval
1.4–1.6, zero-colony 23–29% (was ~50% for the first two weeks). Golden
line per-system: income at parity (574–688 vs 577), tech near parity on
the frontier (~90/sys vs 101), population still the big gap (30–48 vs
65) — colonies land late and ramp slow; that is the current frontier of
the work, alongside colony-count itself (2–3 systems vs 6). First
nonzero gold passes: systems 7–9%, income 7–11% at cp75 on the frontier.

## Part 4 — what's next (agreed roadmap)

1. **Colony COUNT is now THE gap** (round-3 finding): per-system
   economics reached near-golden parity on the frontier, but median
   systems is 2 (frontier 3) vs the human's 6, and navarch median is
   stuck at 1 all game though admiral_1 is bought 5.4×/eval. Round-4
   flags attack it: `second_lane` (guarantee the 2nd colonizer hire from
   raw stock when the expansion pool starves it) and
   `expansion_ideo_share` (boost the expansion pool's ideology so the
   cap-lex ladder climbs, attacking the 960k transport_no_slot wall).
2. Throughput: the 1.1-merge +13% per-game engine cost is unresolved
   (unlock-currency pivot exonerated by benchmark); steady 54 evals/h.
   Bisect the merge's engine changes under a concurrent-load harness if
   pursued.
3. V3 Phase 3 completion (asset-owning tasks: ConquestTask = the
   combined-arms campaign design) and Phase 4 (personality genome ~24
   genes, fresh archives, v2 champions frozen as benchmarks, dense
   checkpoint-aware fitness with unlock-currency terms).
4. Ideology gold target (query instance 7 player_stats or set pace
   targets); golden-line refresh with focused human games when bots
   close in.
5. DT-4: war/consolidation (the military pool barely spends; the last
   credit sink and the next win-rate lever).

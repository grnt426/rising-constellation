# Game AI training handbook

Operational reference for the bot-training system. Companion documents:
`game-ai.md` (V1 survey + infrastructure design), `game-ai-v2.md` (the
evolvable-structure era), `game-ai-v3.md` (current architecture: the
strategist owns strategy), `game-ai-learnings.md` (mechanics knowledge,
methodology lessons, results timeline), `game-ai-human-strategy.md`
(primary-source human doctrine — cite it when a DT encodes player
knowledge).

Last updated: 2026-07-18, on game version 1.1.0.

## Components

| thing | where | what |
|---|---|---|
| Marathon trainer | `mix headless.marathon` | Unattended GA loop: per iteration picks a faction, format ({1v1,2v2,3v3,4v4,3v3v3,2v2v2}), and map; evaluates mutants + a fresh random against benchmark opponents (boomer + sampled archive champions); updates niche archives; appends one line per eval to results.jsonl |
| Bot driver | `Headless.Bot` | One GenServer per bot: builds a View, asks the policy to decide (~every 250ms real), executes via `Headless.Bot.Act`, tracks all telemetry |
| Policy | `Headless.Policies.Tunable` | The taskmaster portfolio (all decision nodes) driven by the V3 Strategist + Budget pools |
| Strategist | `Headless.Strategist` | Game-phase state machine + per-phase code directives (V3 pillar 1) |
| Budget | `Headless.Budget` | Per-resource, per-phase pool ledger in policy mem (V3 pillar 2) |
| Dashboard | `mix headless.dashboard --watch 90` | Self-contained HTML at `/uploads/bot_dashboard.html` (+ `bot_policy.html` pipeline anatomy page); i18n names, faction colors, time-window filter |
| Experiment flags | `Headless.Flags` | Parallel A/B attribution: each DT change lands behind a flag; the marathon assigns a random on/off set per iteration (evolver only, opponents baseline) and stamps it into results.jsonl (`flags` key, plus a `--tag` code label) |
| Smoke suite | `mix headless.smoke` | Fixed-seed 6-game sanity run (~minutes): engine-alive, opener, colonization, flag-counter checks. Run after EVERY policy change, before the marathon inherits it |
| Seeds | `scripts/seed_synthetic_champions.exs` | Injects hand-designed champions into archives (run with marathon STOPPED) |
| Map pool | `tmp/map_pool/*.json` | Production-map exports (<1000 systems, Fast rule); synthetic "bands" maps mixed at 20% for the buffer-crossing curriculum |
| Archives | `tmp/marathon_night/archive_<faction>.json` | Niche champions per faction; `seed_*` keys are synthetic (dashboard-filtered) |
| Results | `tmp/marathon_night/results.jsonl` | One JSON line per eval — the analytical record |

## Operations

Everything runs inside the worktree's Docker container (host Elixir is
off-limits). Ports come from `.dev-ports.json` (this worktree: Phoenix
4850). Rules that have bitten us:

- **Fast mode, prod data, 14 VP, maps < 1000 systems.** Never the beta
  rebalance, never a changed VP threshold — user rulings.
- Start the marathon under a respawn wrapper (a clean 10h completion
  exits 0 and would otherwise silently stop training):

```bash
docker compose exec -u rc rc bash -lc 'cd /data && while true; do \
  RC_DATA_MEMORY_MODE=shared SPEEDUP=240 ERL_FLAGS="+S 6" \
  mix headless.marathon --hours 10 --concurrency 5 --out tmp/marathon_night \
  >> tmp/marathon_night/marathon.log 2>&1; sleep 10; done'
```

- Kill with bracket-escaped patterns (`pkill -9 -f 'headless[.]marathon'`)
  so the kill command's own argv never matches itself.
- SPEEDUP is runtime (`Core.Tick.speedup/0`, cached per BEAM); the
  `RC_DATA_MEMORY_MODE=shared` flag is redundant since 1.1 made shared
  the default, but harmless.
- Reseed synthetics only with the marathon stopped (it saves archives at
  iteration end and clobbers concurrent writes).
- **After every restart, verify the first eval batch** before believing
  anything: game-length sanity first (sum of `stats.phases` per eval —
  healthy is 1000+, a crashed engine produces ~26), then the metric you
  changed. First batches are restart-truncated; medians swing ±30% at
  n=12. Never tune off a first batch — deploy telemetry, wait for hours.

### The parallel-experiment workflow (2026-07-18 pivot)

One-lever-per-restart capped development at ~1 change/day; attribution
now comes from stratifying the data, not serializing the calendar:

1. Every DT change lands behind a flag in `Headless.Flags` (default OFF
   = shipped behavior). New genes a flag reads still go into `spec()` +
   `default()` (they random-seed into archives regardless).
2. `SPEEDUP=240 mix headless.smoke` after the change ("is it broken?" in
   minutes — engine-alive/opener/colonization checks + flag counters
   prove the new code path fires). `--flags none` for baseline, csv for
   a specific arm. The marathon must NEVER inherit a smoke-failing build.
3. Restart the marathon with `--tag <label>` naming the code state. Each
   iteration randomizes flags for the evolver only; every results line
   carries `flags` + `tag`.
4. Analysis: split any window's evals per flag by `flags["<name>"]` —
   ~50% land in each arm. Class-conditional metrics keep the three
   problem classes readable in one night: zero-colony%/funnel (early
   game), median cp75 sys + col/eval (mid game), top-20%-fitness
   frontier vs the golden line (champions).
5. A flag that wins gets hard-coded and deleted; a loser is deleted or
   reworked. Flags are treatment assignment, not configuration — never
   let one live for weeks.

## Telemetry reference (results.jsonl `stats`)

- `games, wins, colonies, mean_vp, mean_their_vp, mean_win_vp,
  mean_win_colonies, mean_duration_ut` — outcomes. Win-gated means exist
  because the export gate asks "when this champion wins, does it look
  like a real player's win?"
- `usage` — per-key counts of every successful purchase/order, grouped
  `patent/doctrine/build/ship/mission`. "Which lexes do winners buy" is a
  query, not an inference.
- `blocks` — policy gate tallies (%{reason => count}): WHY a node didn't
  act. Names are load-bearing: the transport gates are split by RESOURCE
  (`transport_no_tech` vs `transport_no_credit`) and hires by resource
  (`hire_admiral_no_*`) because a conflated gate cost us a full
  misdiagnosis each time it existed.
- `funnel` — for ZERO-colony games, the FIRST unmet link toward a first
  colony (strict prerequisite chain, 8 stages: citadel → ship patent →
  system lex → navarch → deployed → ship built → dispatched → colonized).
- `colony_cycle` — %{n, wait, build, idle, voyage} mean UT per completed
  colony task. wait = order→dispatch = build (production-bound) + idle
  (dispatch-bound); voyage = dispatch→claim. **Only compare per map
  class** — bands maps run ~2× pool-map voyages by geometry.
- `phases` — decisions per Strategist phase (opening never appears: the
  book intercepts upstream of decide_main).
- `checkpoints` — economy snapshots at 25/50/75% of the victory clock:
  sys, pop, income, tech, **ideo**, hoarded, happy, hab, navarch, erased,
  siderian. CAVEATS: happy/hab are MEANS ACROSS SYSTEMS, so young
  colonies dilute them (colonization success lowers the number) — use
  per-system decomposition or treat as trend-only; pop is empire total.

## The golden line

A human's development pace (instance 7, a deliberately casual game — a
floor, not a ceiling). 25%/50% are measured; 75% extrapolates the first
half's slope (the player coasted late).

| cp | systems | population | credit income | tech income |
|---|---|---|---|---|
| 25% | 2 | 100 | 1,028 | 201 |
| 50% | 4 | 245 | 2,246 | 404 |
| 75% | 6 | 390 | 3,464 | 607 |

Per-system at cp75: **65 pop · 577 income · 101 tech** — the standing
gap analysis divides by system count before concluding anything.
Ideology income has no gold value yet (not captured from the human;
either query instance 7's player_stats or set pace targets — open item).
Agent soft target: ~5 Siderians / 3 Navarchs / 3 Erased by late game.

## Analysis recipes

1. **Era analysis** (after any change): split the era in halves/thirds;
   col/eval, zero-colony %, win %, fitness mean/best, winners' colonies.
   Compare against the immediately-prior era, not all-time.
2. **Gold-line decomposition** (standing, user directive): per-system
   economics vs the human's per-system line, bucketed by system count.
   This is what separated "income at parity, gap = colony count" from
   "tech genuinely deficient per system".
3. **Cycle decomposition**: build vs idle vs voyage, per map class.
4. **Frontier vs population**: all-eval medians are exploration-diluted
   by construction (mutants + randoms + covert niches); the top-20%
   fitness frontier is the ship-quality question. The dashboard's golden
   panel shows both.
5. **Era boundaries**: `iter == 0` transitions mark marathon restarts,
   but the newest restart's first eval lags ~7 minutes — confirm with
   line-count deltas from the restart time before attributing.

## Known open items (2026-07-19)

- Eval throughput, final accounting (controlled same-map solo benchmark
  2026-07-19): the dropped `headless:` metadata key (Victory crashes +
  autosave + handoff sleeps; restored in 206efa1) recovered 50→54
  evals/h steady. The unlock-currency pivot is EXONERATED (33.0 vs
  33.4s/game). The remaining gap to the old ~78/h has two parts: +13%
  per-game engine cost that arrived with the 1.1 master merge (37.4 vs
  33.4s/game solo; boot itself got FASTER — the cost is elsewhere in
  the merge's engine machinery), and an unmeasured concurrency-side
  share (iteration-barrier stragglers, Repo pool, election machinery
  under load). FK-failing faction/diplomacy audit inserts are now gated
  off for headless games (2394999) — correct but didn't move solo wall.
  If pursued further: bisect the merge's engine changes under a
  5-concurrent load harness.
- V3 Phase 3 (full asset-ownership tasks) and Phase 4 (personality
  genome + fresh archives + dense fitness) remain; see game-ai-v3.md.
- Ideology gold target; golden-line refresh with more human games once
  bots get close.

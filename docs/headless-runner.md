# Headless turbo runner (Phase 0 of the game-AI plan)

Runs full Fast-mode games in-memory at high speed with in-process bot
players, and reports wall-clock + outcome + load. This is the evaluation
substrate everything in [game-ai.md](game-ai.md) §8 gates on: balance
simulation (U1), AI training fitness evaluation, and bot regression tests
(U4).

## Usage (dev container)

```
RC_DATA_MEMORY_MODE=shared SPEEDUP=480 \
  mix headless.run --games 8 --parallel 8 --bots 1 \
                   --time-limit 120 --victory-points 999
```

- `--games G` / `--parallel P` — G games total, P at a time
- `--bots N` — bot players per faction (`--no-bots` for engine-only)
- `--time-limit M` — wall-minute budget of the scenario clock (the fixture
  default is a real Fast game: 120)
- `--victory-points V` — win threshold override; the test fixture ships
  with 2 (fast tests), pass 999 to force full-timer games
- `SPEEDUP` — the engine's dev speed multiplier, now read **at runtime**
  (once per BEAM; previously compile-time)
- `RC_DATA_MEMORY_MODE=shared` — serve game content zero-copy from
  `persistent_term` (the release/1.1 memory fix, ported here); use it for
  all headless work

Modules: `Headless.Runner` (boot/run/report), `Headless.Bot` (in-process
driver skeleton), `Headless.Scenario` (fixture loading),
`Mix.Tasks.Headless.Run`.

## Design decisions

- **The engine's wall-clock time model is kept as-is.** Game-time is
  derived from wall time × `factor × SPEEDUP` (`Core.Tick.delta`), so
  acceleration needs no logic changes: the whole game — economy rates,
  action durations, the victory timer — compresses proportionally. The
  price is *tick granularity*: when an agent's tick handler lags, it
  processes a larger time delta in one step. Accrual stays rate-correct;
  only event timing coarsens. Per direction, this error is tolerated and
  **measured** rather than eliminated.
- **Fidelity gauge**: the victory agent declares the winner when
  `ut_time_left` crosses 200 (the engine's end-window). Its distance below
  200 at declaration = victory-tick lateness in game-days. Observed: ~0 UT
  at SPEEDUP=120, ~15–20 UT at 240–960 (≈1% of a Fast game) — flat across
  1-game and 8-game concurrency.
- **No RNG replicability requirement** (per direction). For paired A/B
  evaluations, scenario-level seeding is available:
  `RC_DETERMINISTIC_GENERATION=1` makes a `game_data` seed reproduce the
  same galaxy (ported with the memory fix); intra-game determinism is not
  pursued.
- **Boot mirrors `Daily.Boot`**: in-memory instance model (no scenario /
  instance DB rows) → `Instance.Manager.create_from_model` → `:start`.
  Bot profiles are real DB rows (created once, reused) so player agents
  boot production-shaped. A `"headless" => true` key in `game_data` flows
  into the instance metadata (`Instance.Mutators.headless?/1`) and gates
  every headless-specific engine behavior; it defaults to false, so
  normal games are untouched.

## Measured results (dev box: 16 schedulers, Docker on Windows, 269-system fixture galaxy, 2 factions)

Full-length Fast game (120 wall-minutes of game clock):

| Config | wall | run-queue avg/max | peak mem |
|---|---|---|---|
| SPEEDUP=120, `:legacy` | 60.5 s (+0.8%) | 11.4 / 100 | 491 MB |
| SPEEDUP=120, `:shared` | 60.0 s (+0.03%) | 5.7 / 54 | 152 MB |
| SPEEDUP=240, `:shared` | 30.1 s | 7.6 / 69 | 154 MB |
| SPEEDUP=480, `:shared` | 15.1 s | 8.5 / 28 | 151 MB |
| SPEEDUP=960, `:shared` | 7.5 s | 12.1 / 50 | 152 MB |

Every configuration held its expected wall-clock (game clock is
wall-derived, so games *end* on schedule; lag shows up as tick
coarsening, not slowdown).

Parallel throughput (SPEEDUP=480, `:shared`, full-length games):

| Config | batch | throughput |
|---|---|---|
| 8 games × 8-parallel | 20.4 s | **≈ 34,000 games/day/box** |

Marginal memory per concurrent game ≈ 40 MB in `:shared` mode (content is
node-shared), so concurrency is CPU-bound, not memory-bound.

## The neutral baseline: 50-system galaxy, 2 players, engine-only

The "basic performance" reference (players exist but do nothing; neutrals
run their normal behavior): `Headless.Scenario.small/1` downsamples the
fixture to 25 systems per sector (2 sectors, one per faction), 1 player
per faction, `--no-bots`.

    ERL_FLAGS="+S 10" RC_DATA_MEMORY_MODE=shared SPEEDUP=960 \
      mix headless.run --games 40 --parallel 20 --no-bots \
                       --systems-per-sector 25 --time-limit 120 --victory-points 999

Measured (16-core box, BEAM capped to 10 schedulers ≈ the 60%-CPU host
budget):

| Metric | value |
|---|---|
| CPU per game (batch-attributed) | **2.5 busy scheduler-seconds** (1.4–2.0 solo) |
| Marginal memory per concurrent game | **~15–17 MB** (`:shared` mode) |
| Wall per game | 7.5 s @960 · 3.8 s @1920 · 1.9 s @3840 |
| Serial throughput | 7.1/min @960 · **11.4/min @1920** · ~16/min @3840 |
| 20-parallel throughput @960 | **72.8 games/min** (104,893/day) at 15% of the capped CPU |
| Fidelity (victory-tick lateness) | ~19 UT @960, ~10 UT @1920 (≤1% of game); ~100 UT @3840 (~4%) |

**The shape of the limit**: game time is wall-clock-derived, so a game
*occupies* `time_limit×60/SPEEDUP` seconds of wall time regardless of CPU —
at 50 systems the engine idles at ~1% utilization waiting for its own
clock. Per-game latency is set by SPEEDUP; throughput is set by
concurrency; CPU and RAM are nowhere near binding:

- **CPU ceiling** (60% of 16 cores = 9.6 sched): 576 CPU-s/min ÷ 2.5
  CPU-s/game ≈ **~230 games/min**, reached at ~30+ concurrent games.
- **RAM ceiling** (64 GB): ~3,700 concurrent games at ~17 MB marginal —
  irrelevant, CPU binds first (even 300 concurrent ≈ 5 GB).

The 10 games/min target is met **serially** at SPEEDUP≥1920 and exceeded
7× at modest parallelism — no further engine performance work is needed
for the neutral baseline. Boot remains the soft spot under high
parallelism (avg 3.2 s, max 9.6 s at 20 concurrent boots — galaxy-gen
contention plus a Horde telemetry-poll timeout warning); stagger boots or
accept the amortized cost.

One race fixed during this pass: at extreme SPEEDUPs the winner→close
window (200 UT) shrinks below the runner's poll interval, and the victory
agent's headless self-destroy could tear the instance down before the
runner read the outcome. Headless games no longer self-destroy on close —
the runner owns teardown.

## Bottlenecks found and fixed (first pass, 269-system galaxy)

1. **`:legacy` content-memory mode** — every `Data.Querier` lookup copied
   the ~130 KB content map onto the caller's heap (players do one per
   tick-interval computation). The ported release/1.1 `:shared` mode
   (persistent_term, zero-copy) **halved average run-queue pressure**
   (11.4→5.7) and cut peak memory 3.2×. Use `:shared` for all headless
   work; it is also the recommended prod flip after soak.
2. **Autosave against nonexistent DB rows** — the Time agent's periodic
   stop→snapshot→start cycle can only fail for in-memory instances (and
   perturbs the sim while failing). Skipped when `headless?`.
3. **Endgame DB bookkeeping crash-loop** — at the deadline the Victory
   agent closes/records/ranks via DB rows that headless games don't have;
   the crash restarted the agent with a fresh timer, so games never ended.
   Headless branch: set the winner, skip the bookkeeping (the runner reads
   the outcome from agent state), self-destroy on close.
4. **Handoff sleeps dominated teardown** — three separate graceful-shutdown
   paths save cluster-handoff state and sleep 10 s (bounded by 5 s
   supervisor kill): `Core.TickServer.graceful_terminate` (every agent),
   `Instance.Manager.terminate`, and `Spatial.Handoff`. Destroys queue
   through the single Horde supervisor, so this serialized whole batches:
   destroy was a flat 5 s per game (8-game batch: 58.5 s). All three skip
   save+sleep when `headless?` → destroy ≈ 0.1–1.8 s, batch 20.4 s.
5. **Compile-time SPEEDUP** — was a module attribute; changing the env
   var silently kept the old value, and bind-mounted checkouts made the
   "just recompile" fallback unreliable (mtime caching). Now runtime-read
   and cached per BEAM (`Core.Tick.speedup/0`).

## Known remaining costs (acceptable for now)

- **Boot: 1.4 s solo, ~3.4 s at 8-parallel.** Galaxy generation for 269
  systems contends for cores across concurrent boots, and
  `Instance.Manager.create/2` contains an unconditional 500 ms sleep
  (Horde registration grace). Training scenarios will likely use much
  smaller galaxies (30–60 systems), which shrinks both.
- **Run-queue bursts** (max 28–104 across configs) — transient saturation
  during simultaneous system-tick storms; per-game fidelity was unaffected
  up to 8×480. Past that, watch the fidelity gauge, not wall time.
- **MVP bots don't hire yet** in Fast games: character hire costs
  technology/ideology, which Fast starts at 0 and bots don't develop —
  refusals are `not_enough_technology/ideology`. Fine for load purposes;
  real taskmaster bots (game-ai.md Phase 1) build economy first.
- Per-run BEAM startup (mix app boot) is a few seconds; amortize by
  running many games per invocation (`--games`).

## Phase 1: bot framework + first validated strategies

Architecture (per game-ai.md §7, thin v1): `Headless.Bot.Policy` behaviour
(pure `decide(view, mem) → {actions, mem}`) · `Headless.Bot.View`
(per-decision snapshot: player, owned systems, market, galaxy, active
characters, game time) · `Headless.Bot.Act` (the ONE place that knows
engine payload shapes) · driver with game-time cadence
(`--bot-interval-ut`, default 3 UT) and per-phase timing. Policies:
`idle`, `home_dev` (economy only), `colonizer` (full race loop). Matchups:
`--policies colonizer,home_dev` assigns per faction in order.

    RC_DATA_MEMORY_MODE=shared SPEEDUP=240 mix headless.run \
      --games 4 --parallel 4 --systems-per-sector 25 --time-limit 120 \
      --victory-points 999 --policies colonizer,home_dev

**The colonization race validates** (the full loop: economy → citadel/
shipyard/transport patents → ideo_open → :agent + :system_1 doctrines +
policy slot → admiral → shipyard building → transport → jump → colonize):

| Matchup (n games) | outcome |
|---|---|
| Colonizer (tet.) vs HomeDev | **4/4 wins**, colony at 470–957 UT of ~2400 |
| HomeDev vs Colonizer (myr.) | Colonizer colonized 2/4 → won both 7–4; stalled 2/4 → 4–4 tie |
| HomeDev vs Idle | 4–4 every game — **economy alone moves no VP**; expansion is the VP driver |

**Scoring**: the runner reports each settled colony's **strength** (Σ body
prod/sci/appeal factors) as the matchup tie-breaker — rewards settling GOOD
systems, not just settling first. The Colonizer targets by
`strength − λ·distance` (λ is a Phase-2 knob; candidate scoring currently
reads unscouted systems omnisciently — real scouting later). Diagnostics:
policies tally *why* each pipeline stage declined (`blocks` in bot stats),
which is how every failure below was isolated in one game apiece.

Findings the harness surfaced (each cost a debugging iteration; all are
encoded in the policies and several are game-design data):

- **The §4 governor rule is real, in both directions**: no credit floor →
  bankruptcy (strikes are literally `player_is_bankrupt` propagated to
  characters); too high a floor → blocked *income* buildings → upkeep
  drains you into the same bankruptcy. A scalar floor can't tell
  investment from splurge — the budget-pool architecture exists for this.
- **Sequencing beats greed**: three separate stalls came from stages
  outbidding each other (military patents starving hire tech; `system_1`
  pinning ideology at zero before the hire; construction spending credit
  down past the hire threshold forever). The fixes are orderings and
  reservations, not new capabilities — prime genome material.
- **Jumps are star-lane constrained** (`Galaxy.check_jump` →
  `:invalid_jump` off-lane) and invalid queued actions are *silently
  swallowed* — distant targets need BFS multi-hop paths over
  `galaxy.edges`. Nearest-target bots worked by accident.
- **Engine rules bots must encode**: bodies addressed by `uid` (moons
  nested under planets carry the orbital slots); infra tile before normal
  tiles (non-orbital); `unique_system` vs `unique_body` limits; army-tile
  ships must be `:filled` (a planned ship passes naive checks but fails
  colonization).
- **A false balance signal, caught and retracted**: the bot briefly
  "proved" myrmezir couldn't complete the race — but the blocker was OUR
  bug: an agent-produced API reference hallucinated the colony ship's row
  (cheap, shipyard-gated) when the real `transport_1` needs **no shipyard**
  (the only ship class ungated by shipyard buildings) and costs **12k
  credit / 2k tech / 6.3k production** (verified in ship-fast.ex). With
  the correct data both factions complete the loop; the honest residual is
  myrmezir settling ~500 UT later (market-hire detour: Navarchs are always
  listed, ~1.2–1.4k credit, vs tetrarchy's free deck Navarch). Lesson for
  the whole program: verify data-file claims against the file, and treat
  bot-derived balance conclusions as hypotheses until a strategy SEARCH
  (not a fixed script) fails to close the gap.
- **Bot cost is view-latency, not compute** (as predicted): ~97% of bot
  time is `Game.call` round-trips building views; at SPEEDUP=960 reads
  queue behind busy agents (~1.5 s/view) — run bot games at ≤480.
  With 2 bots @3 UT cadence: 4.5–4.9 CPU-s/game (vs 2.5 neutral); ~1,150
  decisions/bot/game; throughput stays far above the 10 games/min bar.

Status: with corrected ship data, the Colonizer completes the full loop as
**both** factions (tetrarchy ~875–1165 UT, myrmezir ~1410–1555 UT — both
winning their matchups). Bots have no privileges: every action goes through
the same `Player.Agent` validation as the UI (no cheat channel); their one
allowance is omniscient *reading* (fog-free views), flagged in §View.

## Phase 2 begins: strategy search over genome policies

`Headless.Policies.Tunable` re-expresses the bot as capabilities + genome:

- **Legality is code** — lane-graph BFS, `:filled` checks, idle-gates,
  takeability, tile eligibility stay hard-wired (physics, not strategy).
- **Strategy is genome** — a flat JSON map of floats: a weight per
  building/patent/doctrine option (including branches the fixed bots never
  used) and scalars (credit floor, hire reserve, target distance λ). None
  of the hand-discovered sequencing rules are encoded; the optimizer must
  find orderings itself — or find better ones.

`mix headless.search` runs a (μ+λ) evolution strategy over genomes:
mutate → evaluate on PAIRED SEEDS (deterministic galaxy generation forced,
so every genome faces identical maps) against a fixed opponent → select.
Fitness: 10×VP-margin + 50×win + 0.3×Σ colony strength + settle-speed
bonus. Per-generation results persist as JSON under tmp/headless_search/.

    RC_DATA_MEMORY_MODE=shared SPEEDUP=240 mix headless.search \
      --faction myrmezir --opponent home_dev \
      --generations 6 --population 6 --seeds 2

This is the first rung of the strategem-ladder plan: give bots basic
commands and goals, let them search; observed high-fitness patterns get
encapsulated as named strategems; repeat one level up (see game-ai.md §7 —
the discovered patterns become the taskmaster/posture library the overseer
composes).

**First search result (myrmezir vs HomeDev, 6 gens × 6 genomes × 2 paired
seeds = 72 games, ~10 min):**

    gen 1–3: fitness 0   (nothing colonizes on these maps — incl. the
                          hand-built default genome)
    gen 4:   best=187.3  colonized 2/2, first colony ~740 UT, wins 2/2
    gen 6:   best=190.8  colonized 2/2, first colony ~656 UT, wins 2/2
    population mean: 0 → 31 → 81 → 113 (textbook ES progress)

The evolved myrmezir settles at **~656 UT — roughly 2× faster than the
hand-built strategy ever managed for that faction** (~1410–1555 UT) and
faster than hand-built tetrarchy (~875–1165). **The "myrmezir is slower"
residual was also mostly strategy, not faction power.** The discovered
opening is qualitatively different from anything hand-written: thriftier
floors (credit_floor +3.4k, hire_reserve +7k — bank credit early for the
12k transport, hire LATE but well-funded), it buys the happiness/research
branches no fixed bot used (happy_pot_dome +9.5, orbital_research +9.0),
and demotes the hand-picked favorites (factory_orbital −6.0, agent-lex
priority −7.1).

Caveats before believing any number: 2 seeds (overfit-to-map risk), one
fixed opponent, 2 games per evaluation. The known cures are already in the
plan: more seeds, opponent pools, and the exploitability probes from
game-ai.md §5.8. Artifacts: tmp/headless_search/myrmezir_gen*.json +
myrmezir_best.json.

### Widened search + the 3-colony objective

Second iteration of the harness and genome:

- **Opponent pools**: `--opponents home_dev,colonizer,champion` — every
  genome is scored against ALL listed opponents on ALL seeds. `champion`
  loads the opposing faction's best evolved genome from a previous run —
  the first rung of the anti-cycling league (game-ai.md §5.6).
- **3-colony objective**: fitness adds 40 × colonies settled (a win-sized
  chunk each), so multi-colony play dominates. Reported per genome as
  `mean_colonies`.
- **Expanded capability surface** (all genome-weighted, none prescribed):
  the full expansion-lex ladder (`system_1`, `sys_dom_2`, `system_4` —
  3 colonies requires stacking these, which requires policy slots),
  Navarch capacity lexes (`agent`, `admiral_1`) — **fleet size is an
  emergent choice**: hiring fills whatever cap the lex weights buy —
  and the economy/happiness branches (`tech_2`, `ideo_2`, `credit_1/2/3`,
  `stab_2` to offset expansion happiness maluses, `prod_2` for faster
  transports).
- **Multi-admiral missions**: transports are ordered wherever an idle
  Navarch is docked (colonies become production sites as they develop);
  each idle Navarch with a built transport dispatches independently, with
  in-flight targets reserved via the action queue's end-position.

What the first widened campaign taught (2×6 generations, ~250 games):

- **Engine hardening under swarm load** (real U4 payoff): boot storms and
  mid-restart windows made the per-instance rand agent unreachable, and
  THREE separate call sites fed the resulting `Game.call` error values into
  `Enum`/`.key`/arithmetic — crash-looping the character market from inside
  its own creation (a poison pill: restart → `new/1` → crash, zeroing any
  faction that must market-hire). Fixed centrally with
  `Instance.Rand.Safe`: seeded rand-agent access with semantically-faithful
  unseeded fallbacks behind a 1s process-local circuit breaker (a down
  agent costs one retry cycle, not hundreds), used by `Character.random/2`,
  `Data.Picker.random/3`, and the uniform call sites; plus per-slot
  rescue-and-retry in `fill_empty_slots` as defense-in-depth. Regression
  tests in test/game/instance/character_market/; the 16-concurrent-boot
  reproduction now runs crash-free, and battle-determinism tests confirm
  seeded behavior is unchanged when the agent is up. The search also
  staggers instance boots and caps concurrency at 8.
- **Champions converge on shared macro-truths**: both factions' evolved
  genomes independently slashed the credit floor (spend hard) and shifted
  income from buildings to LEXES (tetrarchy swapped the university for
  `tech_2` + bought `admiral_1` capacity; myrmezir took `credit_1` +
  `prod_2`). Myrmezir's champion also re-discovered the high hire-reserve
  pattern the first search found.
- **Colony #2's real wall was knowledge, not economics**: the tetrarchy
  champion built its second transport and then burned 814 refusals on
  `:doctrine_locked` — lexes have ANCESTOR chains (verified:
  agent → system_1 → dominion_1 → sys_dom_2 → system_4) and costs
  inflate per owned doctrine. The genome catalog now models both; the
  3-colony ladder costs ≥10k base ideology plus inflation — a genuine
  design datapoint for Fast-mode expansion pacing.

**Ladder-aware campaign (2×8 generations, 336 games): the 3-colony
objective fell in one generation of having the knowledge.**

| Leg | result |
|---|---|
| Tetrarchy vs HomeDev | gen 2 jumped 1.0 → **5.67 colonies/game**; converged at **6.0 colonies**, first colony ~750–910 UT, 3/3 wins (champion fitness 722) |
| Myrmezir vs HomeDev + that champion | 3 colonies by gen 2, **4.25 colonies** and **3/4 wins — beating the 6-colony champion** by gen 8 (fitness 490) |

Champion gene-shift readouts (vs the hand-tuned default): both factions
again slashed the credit floor and demoted the `agent` lex weight (its
ancestry role makes a high weight redundant); tetrarchy leaned on
`sys_dom_2` + happiness (`happy_pot_dome` — offsetting expansion maluses)
+ `credit_1`; myrmezir went deeper — `system_4` (+3 systems), `credit_2`,
an extreme hire reserve (+6.7k), and *dropped* `factory_orbital` almost
entirely. Nobody hand-designed a 6-colony Fast-mode opening; the search
found it in ~150 games once the lex ladder was legible.

Open threads for the next session: seed/opponent-pool breadth before
trusting exact colony counts; alternating-champion iterations (true league
turns); encapsulating the discovered patterns as named strategems.

### v3: covert agents, governors, and victory-first evaluation

The genome now plays most of the agent game (fleet combat remains the
deliberate exception — see below):

- **Erased (spies)**: travel-then-`infiltrate` missions against enemy
  systems — informers feed the visibility/shadows victory track. Covert
  lex branch modeled (agent → admiral_1 → defense_1 → spy_1 →
  infiltration).
- **Siderians (speakers)**: travel-then-`encourage_hate` (destabilization)
  against enemy systems.
- **Governors**: spare deck characters of ANY type are installed at owned
  systems lacking one (passive bonuses), gated by `w_governor`.
- **Generalized rosters**: hire/activate across all three types; caps come
  from capacity lexes, so *how many agents of each kind* is an emergent
  genome choice. Assassination ("removal", spy) and conversion
  ("seduction", speaker) payloads are verified (`data.target` +
  `data.target_character`) and slot into the same travel-then-act plumbing
  when wanted.
- **Victory-first evaluation**: search games default to the real 14-VP
  threshold (decisive games end early); fitness = win ≫ VP margin/total ≫
  small shaping. The smoke test produced a genuine points victory.

Two design lessons this iteration forced, both now policy mechanics:

1. **Strict-priority purchasing with saving** — greedy
   buy-whatever-is-affordable lets cheap low-weight lexes drain ideology
   and (via per-purchase cost inflation) tax the expansion ladder; weight
   order must BE purchase order for genomes to control sequencing.
2. **Bugs become selection pressure**: the old policy-slot logic never
   bought slots when the top-weighted lex was already active — earlier
   champions' unexplained down-weighting of `:agent` (−6.5 gene shifts)
   was evolution routing around that bug. Behavioral anomalies in
   champions are worth auditing as potential harness bugs.

**Victory-rules campaign (2×8 generations, 480 games) — emergent faction
identities.** Both champions win consistently under real rules (tetrarchy
6/6 at mean VP 15.7; myrmezir 4/4 at mean VP 19.0 — both with only ~2.5
colonies, far leaner than the colony-fitness era). The genome readout shows
they evolved into DIFFERENT archetypes:

- **Tetrarchy — the administrator**: governors everywhere (w_governor 5.8),
  the full expansion-lex ladder, happiness lexes, moderate infiltration.
- **Myrmezir — the shadow operative**: heavy infiltration (5.2) and
  destabilization (4.7), zero governors, VP flowing through the
  visibility/shadows track (mean VP 19 on 2.25 colonies).

Nobody told the spy faction to play spy — victory-first fitness plus the
covert toolkit produced the faction fantasy on its own. Champion-vs-
champion showcase (paired map, real rules): **myrmezir 14VP — 7VP
tetrarchy, a decisive points victory**, both sides running colonies,
governors/covert missions, and multi-slot lex builds. These divergent
champions are exactly the personality seeds the MAP-Elites catalog
(game-ai.md §5.5) will formalize. Headroom noted: covert usage is light
(2–3 missions/game) — multi-spy rotations and re-infiltration cycles
remain unexplored by the search.

### v4 + the overnight marathon

Tunable v4 closes most of the remaining action surface: **warfleets**
(shipyard patents/buildings, fighter construction into non-colonizer
admirals' armies, `army_size` gene), **military missions** (conquest of
enemy/neutral systems, raids on enemies, raids on NEUTRALS as safe Navarch
XP-training), **combat reactions** (gene-bucketed stance per admiral),
**the dominion cycle** (flip weakest owned system → dominion when
slot-capped — the wide-play squeeze-flip — and back; speaker
`make_dominion` captures neutrals by propaganda), **covert neutral
training** for spies/speakers, and an **archetype-commitment layer**
(focus_expansion/military/shadows/economy multipliers over weight
families — soft postures the GA can push to extremes without being
restricted). Maps: `Headless.Scenario.generate/1` synthesizes 2–6 banded
sectors from the fixture pool — spawn sectors at the ends, NEUTRAL buffer
bands between, varied per-sector victory points (sector-valuation
pressure). All five factions playable.

**Production map pool** (`tmp/map_pool/*.json`): real map geometry
exported from the prod `scenarios` table (`is_map: true`, filtered to
<1000 systems — the Fast rule). Maps are pure geometry;
`Headless.Scenario.from_map/2` layers on the scenario: a random distinct
spawn-sector pair, seeded per-sector victory points, `sector` keys on
systems, and the fixture's Fast settings (always 14 VP). The marathon
samples the pool at 80% (20% synthetic bands for the buffer-crossing
curriculum) and stamps the map name into `results.jsonl`. Rationale: the
synthetic bands maximize spawn distance and offer a single frontier,
which structurally taxes fleet play — real topologies vary contact
distance and flanking. Re-export with the rpc + scp recipe in the
git history if prod gains maps.

`mix headless.marathon --hours N` is the unattended trainer: round-robin
over factions, random maps and opponents, populations seeded from
per-faction NICHE ARCHIVES (best genome per behavior bucket —
expansionist × militant × shadow — so distinct strategies are preserved
rather than collapsed), opponents sampled from the rival faction's
archive (league pressure), every game and iteration crash-rescued,
archives + results.jsonl persisted continuously (resumable; stop any
time). Smoke: 7 iterations/9 min, 5 factions, zero crashes → ~5–9k games
per 8-hour night. Launch (detached, chat-independent; output lands in the
worktree at tmp/marathon_night/):

    docker compose exec -dT rc su rc -c 'cd /data && \
      RC_DATA_MEMORY_MODE=shared SPEEDUP=240 \
      mix headless.marathon --hours 8 --out tmp/marathon_night \
      > /tmp/marathon_night.log 2>&1'

    # progress:  docker compose exec -T rc tail -5 /tmp/marathon_night.log
    # stop:      docker compose exec -T rc pkill -f headless.marathon

**Fleet blueprints (v4.1)**: individual ship choice is OUT of the genome.
The fleet builder assigns each warfleet admiral a BLUEPRINT (whole-fleet
composition + fill order, gated by patents) and the genome encodes fleet
DOCTRINE only: `blueprint_aggression` (which blueprint, by proximity),
`blueprint_mix` (variety across admirals), `fleet_investment`
(over/under-build vs army_size). Strategy training stays big-picture;
composition quality is the arena's job. The current three-blueprint table
(scout_screen / strike_wing / assault_line) is PROVISIONAL hand-curation on
fast-mode **prod** ship data (never the beta/rebalance overrides) — the
real per-role champions come from `mix sim.blueprints` (below). The
colonizer's lone transport remains its own blueprint.

**Blueprint arena (`mix sim.blueprints`, `Sim.Blueprints`)**: the
availability-conditioned champion source. A fleet builder can only build
what its patents unlock, so "best fleet" is conditional on the buildable
set — even if one ship dominates, a builder without its patent needs the
champion of the remaining pool, and a builder that scouted the enemy needs
the counter. The task walks 8 cumulative patent tiers derived from the
real fast/prod patent tree (t1_scouts = {shipyard_1} → t8_capitals =
everything; a tier's pool is exactly the ships whose `patent` is owned —
merge-stack variants carry their own patents, so stack caps fall out of
the data). Per tier it evolves an NSGA-II champion per strategic goal
(`Sim.Strategy.strategies/0`: defense / raid_soft / raid_hard / intercept)
against a tier-appropriate gauntlet, then a best-response COUNTER to each
champion, then cross-plays everything for the tier's counter matrix.
Results land as JSON per tier (existing tier files are skipped on rerun —
crash-safe resume; `--force` redoes) plus a combined `blueprints.json`:

    docker compose exec -T rc su rc -c "mkdir -p /data/tmp/fleet_arena"
    docker compose exec -dT rc su rc -c 'cd /data && ERL_FLAGS="+S 4" \
      mix sim.blueprints --out tmp/fleet_arena > tmp/fleet_arena/run.log 2>&1'

Knobs: `--pop 32 --gens 20 --battles 8 --cross-battles 40 --seed 1`,
`--tiers t4_corvettes,t5_strike_groups`, `--no-counters`. Dataset is
always fast/prod with no overrides. Runs appless (pure battle sim — no
Phoenix port, safe next to a live marathon; `+S 4` keeps it inside the
CPU budget). Champion picks skip empty fleets ("build nothing" is
Pareto-optimal on the cost axis whenever every design loses).

**Marathon resource budget**: night-one crash (a bot pattern-matching a
CONQUERED-TO-ZERO player's empty system list; link semantics propagated it
past every rescue) is fixed — dead players idle gracefully, evaluation
uses `async_stream_nolink`, and lex/policy churn is dwell-limited. The
marathon now runs at a ~40% CPU budget: `ERL_FLAGS="+S 6"` (scheduler cap)
+ `--concurrency 5`.

**V2 (2026-07-04, docs/game-ai-v2.md)**: the policy architecture above is
superseded — fleets are now COMMISSIONED (whole blueprint enqueued in one
decision; the production queue never gated ships, that was policy code)
and EMPLOYED by a separate stage that spends built idle fleets on
raid/conquest/defense targets ranked by evolvable consideration lists
(`Headless.Bot.Considerations`; genome carries structure per decision
point, complexifying from minimal defaults). Build catalog covers all 34
fast-mode buildings, patents all 39. Marathon niches gained a
structure-size dimension (24 buckets/faction).

Remaining fleet scope: sabotage (Erased) alongside deeper fleet play;
response curves + neuroevolved scorers + LLM-proposed considerations per
game-ai-v2.md roadmap.

## What's next (per game-ai.md §8)

1. Real scenario source for training: generated small-galaxy `game_data`
   (parameterizable systems/factions) instead of the fixed test fixture.
2. Phase 1 scripted baseline bot (strategist + taskmasters) behind
   `RcBot`-style policy, driven in-process by `Headless.Bot`.
3. The measurement rig: seed-batched round-robin runner, TrueSkill
   ledger, per-game telemetry (economy curves, pool series) persisted for
   analysis.

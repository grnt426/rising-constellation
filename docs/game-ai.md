# Game AI — survey, architecture, and training plan

Research review and proposal for building intelligent AI players for
Tetrarchy Falls: what the field actually uses for 4X/RTS AI, which
optimization methods fit a CPU-only indie budget, where LLMs genuinely help,
and a concrete architecture + training pipeline for us. Fast mode (2 h) is
the primary target; every design choice below is checked against "will this
still work at Legacy scale (2–4 weeks)".

**Why we want this** (the five use cases, referenced as U1–U5 throughout):

- **U1 — balance simulation**: mass headless games to test stats/mechanics.
- **U2 — PvE opponents**: compelling AI players so the game isn't
  PvP-or-nothing (the current perception drives bounce-off).
- **U3 — richer neutrals**: smaller "live" PvE elements inside PvP matches,
  replacing today's docile do-nothing neutrals.
- **U4 — automated testing**: bots that exercise the real game loop as
  regression checks.
- **U5 — design prototyping**: try a mechanic, watch a thousand simulated
  games, read the outcome.

---

## 1. The headline findings from the research pass

A deep multi-source research sweep (adversarially verified claims; sources
at the bottom) produced a picture that is unusually consistent:

1. **Every shipped strategy game with verifiable evidence uses hand-authored,
   data-driven decision systems** — utility/priority scoring, budget pools,
   scripted hierarchies — not end-to-end learning. Stellaris (per Paradox's
   own GDC 2017 talk) is a data-driven script/weight system. So were
   Civilization, Kohan II, AI War 1/2, Prismata. Learning shows up **offline**
   (tuning, testing), not in the shipped decision loop.
2. **Raw game-tree search is provably out**: RTS/4X state spaces
   (StarCraft ≈ 10^1685 states, per-frame branching 10^50–10^200) admit no
   direct tree search or vanilla MCTS. Search only works **over
   abstractions** — portfolios of scripted behaviors, budgets, postures.
3. **Hierarchical "overseer + executors" is a recurring, validated
   tractability pattern** (it collapses a combinatorial joint action space
   into a multiplicative one) — but the research pass explicitly *refuted*
   the claim that it is the proven-optimal architecture. It's a good
   default, not a law.
4. **Stability is engineered, not learned.** Production games solve
   goal ping-ponging and economic self-destruction with explicit control
   mechanisms: goal-commitment terms (Kohan II), budget-pool inertia with
   cap-overflow donation (AI War 2), or removing the failure mode outright
   with an asymmetric AI economy (AI War 1). This validates your control-
   theory instinct — the field converged on the same fixes.
5. **Evaluation must be population-based.** The StarCraft competition record
   shows strong non-transitivity among bots (documented rock-paper-scissors
   triangles: Skynet beats UAlbertaBot 26/30, UAlbertaBot beats AIUR 29/30,
   AIUR beats Skynet 19/30). Single-opponent win-rate is a misleading
   fitness signal. Round-robin + Elo/TrueSkill over a diverse frozen pool is
   the proven harness; headless multi-client simulation is production-proven
   in grand strategy (Stellaris built exactly this).
6. **"AI as entertainment" is a design axis, not a cheat.** Soren Johnson
   (Civ III/IV): difficulty tiers *are* tuned cheat magnitudes; a shipped 4X
   AI deliberately does not maximize win-rate. For U2/U3 this is liberating —
   we tune for *compelling*, and handicaps are a legitimate difficulty knob.

The strongest single production-proven pattern for a small CPU-only team is
**Hierarchical Portfolio Search** (Prismata): scripted "partial players" per
domain propose candidate moves, and a cheap top-level search picks among
them. It shipped, ran ~1M games against humans at top-25% ladder strength on
≤3 s/move, and — critically for us — **stayed robust through 20+ balance
patches without reworking per-unit logic**, because the portfolio pieces are
small and legible.

---

## 2. Survey: decision architectures

What exists, what it costs, and what it's good for. Roughly in order of
increasing machinery:

### 2.1 Scripts, FSMs, decision trees

Fixed if-then policy. Cheap, predictable, and how most commercial RTS AI
historically shipped. Weaknesses: brittle under design change (every patch
touches the tree), no adaptation, exploitable once learned. Your instinct
that a hand-built DT is "highly sensitive" matches the literature — decision
*trees* specifically encode thresholds in topology, which is the worst place
to put tunable knobs. **Verdict: right for probe bots and neutral behaviors;
wrong as the main brain.**

### 2.2 Utility AI (priority scoring)

Every candidate goal/action gets a score from a hand-shaped function of
game-state features (`score = Σ wᵢ·fᵢ(state)` plus curves/multipliers);
highest score wins. This is the workhorse of shipped strategy AI (Stellaris
weights, Civ's flavor system, Kohan II's goal priorities). Two properties
matter for us:

- **Weights live in data, not code** → tunable by black-box optimization and
  writable/critiquable by an LLM. The scoring function is the *genome*.
- **Degenerate modes are known and fixable** (§4): flip-flopping is cured
  with commitment terms and hysteresis, not by abandoning the approach.

**Verdict: the strategic layer should be utility-based, not a DT.** Same
expressive role as your overseer, but with continuous, tunable, analyzable
knobs instead of brittle branch structure.

### 2.3 Behavior trees

Reactive task decomposition with clean fallbacks; the industry standard for
*unit-level* control. Good for our agent micro (a Navarch executing a raid
pipeline) — poor for strategy selection (same threshold-brittleness as DTs).

### 2.4 GOAP / HTN planning

Backward-chaining (GOAP) or recipe-decomposition (HTN) planners that emit
action sequences toward a declared goal. HTN suits 4X better than GOAP: our
"goals" are stable pipelines (scout → research lex → recruit Navarch → load
colony ship → dispatch — exactly the colonization pipeline already sketched
for the bot). But full planners add replanning-instability and debugging
cost. **Verdict: encode the known pipelines as explicit multi-step
taskmaster programs (degenerate HTN with hand-authored methods); skip the
general planner.**

### 2.5 Hierarchical decomposition (overseer + executors)

The recurring pattern across seven analyzed StarCraft competition bots and
AI War 2's production design: a slow strategic layer (AI War 2: a
"consciousness" thread thinking for seconds) above fast bounded tactical
executors (its "subconscious", ~30 ms/cycle). Two non-obvious lessons from
AI War 2:

- **Budget pools as the strategy interface.** Faction income accumulates
  into named pools (waves, reinforcement, hunter fleet…); strategy is
  *rate allocation into pools*, execution is *spending from pools*. This
  single idea buys: bounded spending (can't bankrupt what isn't in the
  pool), natural inertia (stocks change slowly even when rates change),
  and legible telemetry (pool time-series tell you what the AI "wants").
- **Two time scales are native to the design.** Slow deliberate strategy +
  fast bounded execution is exactly our Fast/Legacy split — the same
  architecture serves both modes by retuning cadence constants.

### 2.6 Portfolio methods (HPS) — the production sweet spot

Prismata's Hierarchical Portfolio Search: each domain module ("partial
player") proposes a few candidate moves; the turn's action is chosen by a
small search (Negamax/MCTS) over the cross-product of candidates. The search
is optional — at its cheapest, a greedy arbiter just takes each domain's top
proposal under a shared budget. **This is the architecture that fits us**
(§7): we get the modularity of scripted domain experts, a small tunable
surface, and a clean upgrade path (greedy arbiter → 1-ply lookahead using
the fitness function → shallow MCTS over postures) without rearchitecting.

### 2.7 MCTS and friends

Directly searching the real game: intractable (finding 2). Searching an
*abstracted* game (postures × budget splits, one node per strategic
re-evaluation): feasible and worth having on the roadmap once a fast
forward-model exists (§8 Phase 0 gives us one). Research-validated hybrid
(microRTS "StrategyTactics", IEEE competition winner): a tiny learned policy
picks among scripted strategies (~3 ms), search handles local combat. Note
its training recipe — **distill a slow expensive search into a fast policy
via supervised learning** (~2,190 training games, one consumer GPU) — as the
cheap way to buy "learned" quality later.

### 2.8 End-to-end deep RL (AlphaStar, OpenAI Five)

State of the art in raw strength; catastrophically out of budget (grand-scale
TPU/GPU fleets, years of simulated play per day — exact verified figures in
§5), and fragile under game patches (OpenAI documented "surgery" procedures
to survive their own balance updates; we patch constantly). **Verdict: the
architecture serves as inspiration (league training, exploiters), the
compute model does not transfer. We take their evaluation ideas, not their
training bill.**

---

## 3. Survey: neutrals and PvE-specific patterns (U2, U3)

- **Asymmetric economies for non-player factions** (AI War 1, verified):
  the AI does not play the player's game — it runs on its own simple
  resource rules (reinforcement points, escalation counters) while sharing
  tactical rules. This *removes* the self-bankruptcy failure mode and most
  degenerate economic exploits, and it's dramatically cheaper to build.
  **Neutrals (U3) should be asymmetric-economy agents**: raider camps with
  a strength budget that grows until culled, trade stations that pay rent
  to whoever protects them, guardian fleets on escalation timers. They need
  posture logic, not full 4X play.
- **Difficulty = tuned handicap, not smarter search** (Civ, verified):
  per-difficulty resource/vision bonuses are the shipped-game norm and
  players accept them. Our PvE ladder (U2) should be personality × handicap
  grid, not N different brains.
- **Emergence from simple per-unit rules** (AI War): coordinated-looking
  group behavior fell out of per-unit target scoring with no group
  coordination code. Cheap richness for neutral fleets.

---

## 4. Stability and control — the ping-pong problem

Your control-theory framing is correct and the field's fixes map onto it
directly. The strategic layer should ship with all of these from day one;
they are cheap and they compose:

| Control concept | Concrete mechanism in the strategist |
|---|---|
| Hysteresis (Schmitt trigger) | A challenger posture must beat the incumbent's utility by margin **δ** (e.g. 15–25%) to displace it — two thresholds, not one. |
| Dwell time / lockout | Minimum commitment period per posture (e.g. no re-evaluation for N game-days after a switch), scaled by mode (Fast: minutes; Legacy: days). |
| Commitment term (Kohan II, verified) | Incumbent posture gets an explicit utility bonus that decays over time — young commitments are sticky, stale ones contestable. |
| Low-pass filter | Utility inputs are EMAs of game signals (income trends, threat estimates), never instantaneous readings — a lost fleet shouldn't flip grand strategy in one tick. |
| Rate limiting | Posture changes adjust budget *allocation rates*, never instantly reallocate pool *stocks* (AI War 2, verified). |
| Anti-windup | Pools have caps; overflow is donated to under-cap pools (AI War 2's documented mechanism) — prevents infinite hoarding and starving. |
| Governor / hard constraint layer | Invariants checked *outside* the utility system: upkeep ratio floor, minimum credit reserve (as a multiple of per-tick burn), never abandon last system, cap simultaneous wars. Vetoes, not scores. |
| Dither | Small random utility noise (Kohan II shipped this) — reduces exploitable predictability and, in optimization, smooths the fitness landscape. |

Two additional degenerate modes you named, and their fixes:

- **Sub-optima**: a single hand-tuned weight vector *will* sit in a local
  optimum. The fix is not a cleverer single bot but a **population** —
  optimization with restarts/niching (§5) plus diverse frozen opponents
  (§5.6). Diversity is the anti-local-optimum tool at every level.
- **Economic self-destruction**: the governor layer plus budget pools make
  bankruptcy structurally hard for AI *players*; for neutrals the
  asymmetric economy removes the concept entirely.

One honest caveat from the research pass: these mechanisms trade
responsiveness for stability (AI War 2 explicitly refuses to surge-refund a
whittled-down fleet). That's the correct trade for Legacy and for PvE
believability; for Fast mode we tune δ and dwell times down, not out.

---

## 5. Survey: optimization and training methods

The decision architecture (§2) determines *what* is tunable: a genome of
~30–150 numbers (utility weights, thresholds, pool allocation tables,
build-order priorities) plus small policy programs. This section is about
how to tune them when one evaluation = one simulated game.

> Working cost model: assume Phase 0 (§8) gets a headless Fast game to
> ~10–60 s of CPU, embarrassingly parallel across cores. A 16-core box
> then yields roughly 25k–150k games/day. That is the budget everything
> below is measured against.

### 5.1 Local search: hill-climbing, simulated annealing — the day-one tools

Mutate the genome, evaluate vs the opponent pool, keep if better (SA:
sometimes keep if worse, cooling over time). Trivial to implement,
embarrassingly parallel (parallel restarts), no hyper-parameters that can
silently break. Documented precedent at exactly our scale: GVGAI
"skill-depth" work tuned game parameters by random-mutation hill-climbing
with a budget of **5,000 game evaluations per trial** (with 5–69
resamples per point for noise) and reliably evolved deep, balanced game
variants — note that this is a *game-balance* result (U1) as much as an
optimizer benchmark.

With noisy fitness, use **paired evaluations on common random numbers**
— the exact CRN technique `Sim.Arena.matchup/3` already uses for battles.
The variance arithmetic is worth knowing: paired-seed evaluation cuts
comparison variance by `(2/n)·cov` between the paired outcomes, giving an
effective-sample-size gain of ≈ `1/(1−ρ)`; measured seed-level
correlations in multi-agent sims typically exceed 0.9 → **~10× fewer
games per comparison**. (Caveat: pairing only helps when outcomes
correlate across seeds — verify ρ on our sims early.) The racing pattern
(irace/F-Race: evaluate all candidates on the same seed block, eliminate
statistically-worse ones early, spend survivors' budget on more seeds)
runs whole tuning campaigns in ~5,000 evaluations in the algorithm-
configuration literature. **Use first. Its job is to be the baseline that
everything fancier must beat.**

### 5.2 CMA-ES — the serious continuous-parameter tool

Covariance-Matrix-Adaptation Evolution Strategy: samples a population of
genomes from an adaptive multivariate Gaussian, ranks them by fitness,
shifts/reshapes the distribution toward the best. The standard choice for
expensive, noisy, black-box continuous optimization in ≤ ~100 dimensions:

- Population per generation is small: λ = 4 + ⌊3·ln n⌋ (Hansen's verified
  default; λ ≈ 16 for n = 60). Verified benchmark counts: ~1,000–1,200
  evaluations to solve 10-D sphere, ~5,000–6,000 for 10-D
  Rosenbrock/ellipsoid — roughly **100n–600n evaluations on smooth
  problems**. Our fitness is noisy and multimodal, so budget an order of
  magnitude more: order 10⁴ evaluations, i.e. **days, not months, at our
  game rates** (§5 cost model).
- Noise tolerance is structural (only fitness *ranks* matter — verified
  invariance property) but not free: increase λ on noisy functions
  (Hansen's own recommendation), use CRN seed batches per generation, and
  re-evaluate elites before accepting them.
- Restarts with population doubling (IPOP-CMA-ES, verified: ×2 per
  restart, better than local restarts on 29/60 CEC'05 problems) address
  multi-modality — our sub-optima concern.

**Use for: strategist weights, taskmaster thresholds, neutral personality
parameters, and U1 balance searches ("find the stat vector that equalizes
faction win-rates").**

### 5.3 SPSA — the cautionary production datapoint

Stockfish's fishtest tunes engine parameters with SPSA — just **two game
evaluations per iteration regardless of parameter count** (a paired game
between the +δ and −δ perturbations) — yet documented tuning sessions burn
**30,000–100,000 super-fast games**, and their SPRT acceptance tests
routinely need ~38k games (short time control) to ~91k (long) to resolve a
≤2-Elo question; even 50,000 games only pins Elo to about ±1.5. That is
the price of pure win/loss fitness on a noisy game. The lesson is not
"avoid SPSA" but **avoid binary-outcome-only fitness**: CRN pairing
(§5.1's ~10× effective-sample gain) plus margin-of-victory-style
continuous fitness — we have victory-point tracks and tie-break ratios for
free — recovers orders of magnitude of signal per game.

### 5.4 Genetic algorithms — and the documented balance-tuning cases (U1)

Crossover + mutation over a population. Strictly dominated by CMA-ES for
pure continuous genomes, but the right tool when the genome is **structural**
(build-order sequences, posture graphs, rule sets) where crossover of
program-shaped things is meaningful. Also the substrate the LLM loop (§6)
plugs into — LLM-as-mutation-operator needs an evolutionary outer loop.

The verified game-*balance* case studies live here, and they calibrate U1:

- **Hearthstone meta balancing** (IEEE CoG 2019): GA (population 100)
  tuning 180 card-attribute deltas, fitness = 300 simulated games per
  candidate, 12–47 generations ≈ **a few hundred thousand games per
  balancing run** — comfortably within our §5 cost model. NSGA-II
  (multi-objective) found metas equally balanced with **less than half
  the total stat changes** — directly the shape of question we'll ask
  ("smallest patch that fixes the win-rate skew").
- **Candy Crush** (IEEE CIG 2018, production at King): deep-learned
  *human-like* playtesting bots predict level difficulty for new content
  at a fraction of MCTS's compute — production proof that bot-based
  content evaluation is a shipped industry practice, and a pointer for
  later: once we have human game logs, "predict what players do" is a
  viable bot flavor for balance work.

### 5.5 Quality-Diversity: MAP-Elites — the PvE goldmine

Instead of one best genome, MAP-Elites keeps a **grid of elites indexed by
behavior descriptors** — e.g. axes of (military budget share, expansion
rate, covert activity). Each cell holds the highest-fitness genome *with
that behavior*. Search pressure plus mandatory diversity:

- Output is not one bot but a **catalog of distinct viable personalities**
  — aggressive rusher, wide expander, spy-heavy schemer, turtle — each as
  strong as that style allows. This *is* the U2 difficulty/personality
  matrix and the U3 neutral variety pack, produced by the same compute that
  would otherwise make one bot.
- The archive doubles as the diverse frozen opponent pool §5.6 requires —
  QD directly attacks both the sub-optima problem and the non-transitivity
  problem.

**Highest-leverage "fancy" method on our list.** Verified budgets span
~10² to ~10⁷ evaluations depending on grid resolution and evaluation cost
(Mouret & Clune's original experiments); the closest game application —
Hearthstone deck-space illumination (GECCO 2019) — used 10⁴ evaluations ×
200 games each. Our coarse grid (~48 cells, §8 Phase 3) sits at the small
end: order 10⁴–10⁵ game evaluations — about a week of one box, amortized
forever.

### 5.6 League design — why naive self-play fails, with verified numbers

This is the best-quantified area of the whole research pass, and it decides
how our optimization loop measures fitness.

**The failure mode is proven, not folklore.** AlphaStar's paper states
naive self-play "may chase cycles indefinitely"; its ablations quantify the
damage: pure self-play reached high Elo (1519) but retained only a **46%
minimum win-rate against its own past versions**, vs **71%** for the league
mix at similar Elo — improvement that forgets is not improvement. Their
league's payoff matrix contained ~3,000,000 rock-paper-scissors cycles.
Lanctot et al. (NeurIPS 2017) showed the same disease in *gridworlds*:
independently-trained agents lose 34–72% of expected reward when paired
with a differently-trained partner (their JPC metric), and framed the cure
as **PSRO** — iterate: compute a best response to a *mixture over a policy
pool*, add it to the pool. Every league design below is a PSRO instance.

**The recipes, from expensive to cheap:**

- **AlphaStar's full league** (per race): 3 main agents + 3 *main
  exploiters* + 6 *league exploiters*, ~900 frozen snapshots as opponents;
  mains train 35% self-play / 50% prioritized fictitious self-play against
  all past players / 15% against forgotten+exploiter players, with PFSP
  weighting opponents by `f_hard(x) = (1−x)^p` — spend games on opponents
  you *haven't* beaten. Rationale, verbatim: "playing to win is
  insufficient" — exploiters exist purely to expose the champion's flaws.
- **OpenAI Five's minimal league**: 80% of games vs the current policy,
  20% vs a dynamically-weighted pool of frozen past selves. No exploiters,
  no meta-solver — the cheapest documented anti-collapse mechanism.
- **Ubisoft's Minimax Exploiter** (AAMAS 2024, For Honor): the
  indie-relevant existence proof — a **100-hour** league run producing 16
  converged exploiter generations and a main agent winning >66% vs all
  peers, by densifying the exploiter's reward with the frozen champion's
  own value estimates. League training is not inherently datacenter-scale
  when evaluations are cheap.

**Theory for sizing the pool** (Czarnecki et al., NeurIPS 2020): real games
of skill have a "spinning top" geometry — a transitive strength axis with
non-transitive width that is *largest at mid-level skill*. Required
population size tracks the game's non-transitive structure, not compute.
(Their idealized theorem — cover a full Nash cluster and beating the pool
guarantees real improvement — survived verification; the quantitative
league-size formula derived from it did **not**, so pool size remains an
empirical question, §9.2. Note the practical corollary: mid-strength bots —
ours — live in the *widest* part of the top, where diversity matters most.)

**Our adaptation** (genomes, not networks, so everything is cheaper):
fitness is always measured against a **diverse frozen pool** — hall-of-fame
champions + MAP-Elites archive cells + scripted probes — refreshed as new
elites emerge, with opponent sampling weighted `f_hard`-style toward
opponents the candidate hasn't beaten. Start with OpenAI-Five-simple
(current + frozen pool); add a dedicated exploiter *optimization run*
(champion frozen as fitness target) only when the champion plateaus. PBT
proper (Jaderberg et al.) — live population copying + perturbing winners —
is overkill at our genome sizes; the league structure is the part that
transfers.

### 5.7 Reinforcement learning — the honest assessment

- **End-to-end deep RL**: out of scope, now with verified price tags.
  AlphaStar: 12 training agents × 32 TPUv3 × 44 days, ~192,000 concurrent
  StarCraft matches, learners consuming ~50,000 agent steps/second — for
  Grandmaster (>99.8% of ranked humans). OpenAI Five: 770±50 PFlops/s-days
  over 10 months (~180 years of Dota per wall-clock day; up to 1,536 GPUs
  + 172,800 rollout CPUs), including 20+ model "surgeries" to survive game
  patches — and their clean-code rerun still cost 150 PFlops/s-days. That
  is 4–6 orders of magnitude beyond a CPU-only indie budget, for a
  patch-fragile artifact. Nothing about our problem needs this.
- **Small RL in narrow slots**: genuinely useful later. Once the fitness
  pipeline exists, the strategist's posture-selection function is a small
  contextual policy over ~20 features and ~6 actions — learnable by
  distillation from slow search (microRTS recipe, §2.7) or bandit methods.
- **Bandits now**: UCB over the posture/opening portfolio *across* games
  vs the same opponent is competition-proven adaptation (6 of 10 entrants
  in the 2012 StarCraft competition, including the top 4, persisted
  opponent models; UAlbertaBot used UCB). Nearly free to implement, and a
  natural "the AI learns your habits" PvE feature.

### 5.8 Fitness design (for self-play improvement, U-all)

- **Primary signal**: match outcome vs the frozen pool, aggregated as
  TrueSkill/Elo (handles win/loss/draw and uneven pairings cleanly).
- **Dense shaping**: the victory system already computes three 10-point
  tracks + continuous tie-break ratios — a ready-made margin-of-victory
  scalar that slashes fitness noise vs binary win/loss. Keep shaping
  weights small relative to outcome to avoid optimizing the proxy.
- **Behavioral regularizers**: penalties for bankruptcy events, idle
  characters, zero-expansion stalls — these encode "don't be degenerate"
  directly into fitness.
- **Anti-reward-hacking**: hold out scripted probe bots (rush/turtle/greed)
  that are *never* in the training pool, as an exploitability test suite;
  a genome that aces the pool but folds to a probe is overfit, and the
  probe suite is the regression gate (U4).
- **Variance reduction everywhere**: CRN seed batches, mirrored-position
  pairs (A-vs-B and B-vs-A on the same map seed), early termination of
  decided games.

---

## 6. LLMs in the loop — where they actually help

The 2023–26 research wave sorts into four patterns. Ordered by fit for us:

### 6.1 LLM-as-designer/tuner in an evolutionary outer loop (best fit)

The Eureka / FunSearch / AlphaEvolve pattern: **the LLM is the mutation
operator; the simulator is the fitness function.** Verified figures:

- **Eureka** (NVIDIA, ICLR 2024): GPT-4 is fed the **raw environment
  source code** as context, writes candidate reward functions (16
  candidates × 5 iterations per run), and training statistics flow back as
  "reward reflection" text that steers the next generation. Result:
  outperformed human-expert rewards on **83% of 29 Isaac Gym tasks**, +52%
  average normalized improvement. The entire "LLM reads the code and
  shapes the training signal" thesis, demonstrated.
- **FunSearch** (DeepMind, Nature 2024): evolves only the critical
  heuristic function inside a fixed program skeleton; island-based
  evolution; ~10^6 LLM samples with a *small* code model, evaluated by
  **150 CPU evaluators vs only 15 LLM samplers** — the compute lives in
  evaluation, not in the LLM. Found the largest cap-set improvement in
  20 years and new bin-packing heuristics.
- **AlphaEvolve** (DeepMind, 2025): the scaled successor — evolves whole
  files in any language, needs only **thousands** of LLM samples (vs
  FunSearch's millions) by using frontier models with rich feedback in
  context, optimizes multiple metrics. Results: first improvement over
  Strassen's 4×4 complex matrix multiplication in 56 years (48
  multiplications); new SOTA on 14 matmul algorithms; and — most relevant
  to us — a production datacenter-scheduling **heuristic** recovering
  ~0.7% of Google's fleet compute, explicitly chosen over deep RL for
  "interpretability, debuggability, predictability". Google's
  infrastructure team made the same architecture bet we're making:
  evolved legible heuristic code over an opaque learned policy.

This is precisely your stated goal — "LLMs can read code, game docs, and
the actual presented game mechanics to inform the shape of the AI." Applied
to us, the loop is:

```
game code + docs + genome + telemetry from lost games
        │
        ▼
LLM proposes K mutations           ← "reflection": match summaries,
  (weight changes, new utility        economy curves, cause-of-loss
   features, new taskmaster           analysis per genome
   heuristics as code)
        │
        ▼
headless sim evaluates vs frozen pool (CRN, TrueSkill)
        │
        ▼
elites survive → archive (MAP-Elites grid) → repeat
```

Why this beats blind mutation: the LLM's edits are *semantically directed*
("this genome loses to rushes because the military pool allocation ramps
too late; here are three targeted fixes, including a new input feature the
utility function was blind to"). Blind CMA-ES cannot invent a new feature;
the LLM can. Why it beats LLM-alone: every proposal is graded by thousands
of real games before it survives. Token cost is modest because calls happen
per *generation* (dozens per day), not per game decision.

### 6.2 LLM-as-programmer of policies-as-code (Voyager pattern)

Voyager (Minecraft, 2023) showed an LLM iteratively writing a **library of
small verified skill programs** — each skill authored by GPT-4, checked by
a self-verification critic, stored as an executable program, and thereafter
run and composed *without further LLM calls*. Effect sizes: 3.3× more
unique items than prior agents, key tech-tree milestones up to 15.3×
faster. The 2024–25 literature has since applied exactly this to fast
game policies:

- **PORTAL** (Tencent, 2025): LLM generates **behavior trees in a DSL**
  for FPS bots; policies are "instantaneously deployable", updated within
  minutes on designer feedback, zero LLM inference during gameplay.
- **Generative code optimization** (2025): game policies as plain Python,
  refined by an LLM from execution traces — matched or beat DQN on Atari
  with **52–98% less training time** (e.g. Pong solved in 43 min vs DQN's
  10 h), and the finished policy is just code.
- **Strategist** (2024): LLM writes and refines the **value heuristic
  (as Python) inside MCTS**, improved via population self-play
  round-robins — the LLM-writes/sim-grades/league-evaluates loop end to
  end, on strategy games (GOPS, Avalon), beating RL baselines with ~40×
  fewer improvement steps.

Our taskmasters are exactly such a library: `expand.choose_colony_target/2`,
`military.fleet_composition/2` — each small, testable against the sim, and
regenerable when patches change the game. The LLM writes and repairs the
library offline; runtime never calls it. (This is also how the framework
stays maintainable through balance patches — the Prismata lesson.)

### 6.3 LLM-as-analyst for balance and design (U1, U5)

Mass-sim output (win-rate matrices by faction/opening/map, economy curves,
metric distributions) is exactly the kind of corpus an LLM digests well:
generate balance reports, propose stat-change hypotheses, then close the
loop by re-simulating the proposed change. Same harness as 6.1, pointed at
game data instead of bot genomes. Also: generating scenario configs and
invariant checks for U4 (an LLM writing property-based tests against the
game's actual rules is cheap and effective).

### 6.4 LLM-as-inline-player (poor fit — with one interesting exception)

Direct LLM play of strategy games remains research-grade, and the verified
numbers say why:

- **CivRealm** (ICLR 2024, Freeciv benchmark): both RL *and* LLM agents
  "struggle to make substantial progress in the full game" — the full-4X
  problem is unsolved even as research; LLM baselines run on GPT-3.5 with
  hierarchical advisor stacks and still crawl the early tech tree.
- **TextStarCraft2** (2023): GPT-4-Turbo beats the *built-in* SC2 AI at
  difficulty 5 of 10 in 12/20 games — years of hobbyist scripted bots do
  better for free.
- **SwarmBrain** (2024) measured the latency wall directly: ~20 s per
  GPT-4 response, ~3 inferences/minute — its fix was precisely our
  architecture (LLM macro-strategist + a fast condition-response state
  machine for tactics), winning 76% vs the Hard built-in AI.
- **Cicero** (Science 2022) is sometimes cited against this, but it's a
  hybrid — the LM handles *dialogue and intent modeling* while a classical
  planner picks the moves (top 10% of human players over 40 league games,
  >2× the average score). It supports, not contradicts, the "LLM outside
  the inner decision loop" rule.

High token cost, seconds-scale latency, weak play relative to scripted
baselines: fine for benchmarks, wrong for our training loops, wrong for
Fast mode.

**The exception: Legacy-mode strategic cadence.** In a 2–4-week game,
strategic decisions are hours apart. An LLM strategist that receives a
curated situation report every few game-hours and sets posture + pool
allocations for the scripted executors is entirely affordable (order of
100–1000 calls per multi-week game) and could produce the most human-like
PvE opponent available — including flavor: in-fiction diplomatic messages,
taunts, negotiated betrayals. Worth a Phase-5 prototype; the architecture
(§7) makes it a drop-in strategist swap because the strategist⇄taskmaster
interface is just (posture, pool rates).

### 6.5 Boundary conditions

Findings 6.1–6.3 come with a discipline: **the LLM never grades itself.**
Every artifact it emits — weights, code, balance hypotheses — is accepted
or rejected by the simulator. That's what made Eureka/FunSearch work at
all; a proposal loop without a ground-truth evaluator is a hallucination
amplifier. Phase 0 (the evaluator) is therefore the gate for *all* LLM
ambitions, not just the classical ones.

---

## 7. Proposed architecture for Tetrarchy Falls

Three layers; each maps to a verified production pattern. All tunable
numbers live in one declarative data structure (the **genome**); all
strategy-relevant code is small pure functions (LLM-writable, sim-testable).

```
┌─ STRATEGIST (slow: minutes in Fast, hours in Legacy) ────────────┐
│ Utility-based posture arbitration over ~6 postures:              │
│   Expand · Develop · MilitaryPush · CovertOps · Defend · VPRace  │
│ + full §4 control stack (hysteresis, dwell, commitment, EMA,     │
│   governor vetoes)                                               │
│ Output: active posture + budget-pool allocation RATES            │
├─ POOLS (economy interface, AI War 2 pattern) ────────────────────┤
│ expansion · military · development · covert · reserve            │
│ income splits by rate; taskmasters spend only from their pool    │
├─ TASKMASTERS (portfolio of scripted partial players, per domain) ┤
│ Economy: build orders per system archetype                       │
│ Expansion: scout→lex→Navarch→colony-ship pipeline                │
│ Military: fleet build (informed by Sim.Arena counter tables),    │
│           target selection, defense assignments                  │
│ Covert: Erased ops (infiltrate/sabotage/assassinate/convert)     │
│ Research: patent/doctrine paths as precomputed graphs            │
│ Each proposes (action, cost, urgency) candidates                 │
├─ ARBITER (fast, every decision tick) ────────────────────────────┤
│ Greedy merge of proposals under pool budgets + action-queue      │
│ constraints → emits actions via the existing RcBot.Policy        │
│ behaviour (decide_actions(player_view) → [actions])              │
│ Upgrade path: greedy → 1-ply lookahead → shallow MCTS over       │
│ posture×allocation nodes (HPS proper)                            │
└──────────────────────────────────────────────────────────────────┘
```

Design commitments and why:

- **Utility + control stack instead of a decision tree** — continuous
  tunable surface (optimization-friendly, LLM-writable), degenerate modes
  have known cures (§4).
- **Budget pools as the strategist⇄taskmaster contract** — bounded
  spending kills the bankruptcy class of bugs; inertia falls out of stocks
  vs rates; pool time-series are the primary debugging/telemetry view; and
  the same contract lets us swap strategists (scripted ↔ learned ↔ LLM)
  without touching executors.
- **Taskmasters as small pure functions over the player view** — testable
  in isolation, evolvable by the §6 loop, robust to balance patches
  (Prismata's maintainability result).
- **Fast/Legacy is a retune, not a rewrite** — cadences, dwell times, and
  pipeline constants scale with the mode's tick factor; posture set and
  pool structure are mode-invariant. Whether *tuned genomes* transfer
  across modes is an explicit experiment (§9), not an assumption.
- **Neutrals (U3) are a fourth, tiny stack**: asymmetric economy (strength
  budget + escalation timer), one posture dial (dormant/raid/defend/
  escalate), reuse of military taskmaster only. No full-game play.

## 8. Proposed training & evaluation pipeline

**Phase 0 — the enabler: headless turbo runner + eval harness.**
*Status: runner built and measured — see [headless-runner.md](headless-runner.md).
Full 269-system games: ~34k/day/box. Training-scale 50-system baseline:
**~73 games/min measured (105k/day) at 15% of a 60%-CPU budget**, 2.5 CPU-s
and ~17MB per game — the cost model below is beaten by ~10×. Remaining
Phase-0 scope: TrueSkill ledger, telemetry persistence.*
Synchronously-stepped, seeded, in-memory full-game instances (the daily-
challenge boot path already proves the in-memory instance shape; what's new
is turbo tick-stepping and N-player bot drivers in-process). Target: a full
Fast game in ≤ ~1 min of CPU; thousands/day/box. Plus the measurement rig:
seed-batched round-robin runner, TrueSkill ledger, per-game telemetry
(economy curves, pool series, action counts), win-rate matrices. *Every
subsequent phase — classical or LLM — is gated on this.*

**Phase 1 — scripted baseline that finishes games.**
*Status: framework + first policies built and validated — see
[headless-runner.md](headless-runner.md) Phase 1 section. The colonization
race loop runs end-to-end; Colonizer beats HomeDev beats-or-ties Idle;
the §4 governor rule and a real faction-asymmetry balance signal both
surfaced in the first day of games.*
Hand-written (LLM-drafted, human-reviewed) taskmasters + strategist with
sane default genome. Acceptance: ≥95% vs `Policy.Dumb`, zero governor
violations, completes Fast games unattended. This bot immediately serves
U4 (regression gate: "bot-vs-bot game completes, invariants hold") and
makes U1 minimally real (self-play balance stats, however weak).

**Phase 2 — classical optimization.**
Hill-climb/SA on the genome vs a starter pool (Dumb + Phase-1 + 3 scripted
probes: rusher, turtle, eco-greed). Graduate to CMA-ES (n ≈ 40–80 params).
Build the hall-of-fame protocol: each optimization epoch's champion is
frozen into the pool; fitness is always vs the *pool*, never the latest
champion (anti-cycling, §5.6). Probes stay held out as the exploitability
suite.

**Phase 3 — MAP-Elites for the personality catalog.**
Behavior axes: military share × expansion rate × covert share (coarse
4×4×3 grid). Output: U2's difficulty/personality matrix (cell + handicap
level), U3's neutral parameter variety, and a rich frozen pool for all
future fitness evaluation.

**Phase 4 — the LLM outer loop.**
Wrap Phase 2/3 in the §6.1 harness: telemetry-informed LLM mutations
(weights *and* code — new utility features, new taskmaster heuristics),
sim-graded, archived. Also stand up the U1/U5 balance-analyst reports on
the same infrastructure.

**Phase 5 — selective sophistication, by measured need.**
Arbiter upgrade to shallow search (HPS proper); UCB opponent-adaptation
across a PvE series; distilled posture policy if the scripted strategist
plateaus; the Legacy-mode inline-LLM strategist prototype (§6.4).

## 9. Open questions the pipeline must answer empirically

1. **Fast→Legacy transfer**: do Fast-tuned genomes hold up in Legacy sims,
   or do the two modes need separate tuning runs? (Legacy sims are ~10×
   costlier even headless; if transfer fails, Legacy tuning leans harder
   on CRN and lower-fidelity proxies.)
2. **Pool size for stable ratings**: how many diverse frozen opponents
   until TrueSkill rankings stop reshuffling? (Competition history says
   "more than one"; the right number for us is an experiment.)
3. **LLM mutation hit-rate**: what fraction of LLM-proposed genome/code
   mutations survive sim grading, vs blind CMA-ES proposals, per dollar?
   (This decides how central §6.1 becomes.)
4. **PvE fun ≠ Elo**: which personality cells do humans actually enjoy
   losing to? (Playtest question; MAP-Elites just guarantees we have
   options.)

## 10. Sources

Verified primary sources from the research pass (adversarial 3-vote
verification; full evidence log with verbatim quotes, votes, and refuted
claims in [game-ai-research-appendix.md](game-ai-research-appendix.md)):

- Paradox, GDC 2017 — *Creating Complex AI Behavior in Stellaris Through
  Data-Driven Design* (gdcvault.com/play/1024223)
- S. Johnson, GDC 2008 — *Playing to Lose: AI and Civilization*
  (archive.org/details/GDC2008Johnson2)
- Ontañón et al., IEEE TCIAIG 2013 — StarCraft AI survey
  (hal.science/hal-00871001)
- Robertson & Watson, AAAI AI Magazine 2014 — RTS AI review (incl. Kevin
  Dill's Kohan II goal-commitment account)
- C. Park (Arcen) — *Designing Emergent AI* series + AI War 2 official
  wiki, *AI Mechanisms* & threading model pages
- Churchill & Buro — *Hierarchical Portfolio Search in Prismata*
  (GameAIPro 3, ch. 30; AIIDE 2015)
- Barriga, Stanescu & Buro, AIIDE 2017 — CNN strategy selection +
  tactical search in microRTS (arXiv:1709.03480)
- Paradox — Stellaris postmortem (headless multi-client harness)
  (gamedeveloper.com)

From the second pass (RL at scale & league design, all 3-0 verified
against primary papers):

- Vinyals et al., Nature 2019 — AlphaStar: league architecture, PFSP,
  self-play ablations, compute (nature.com/articles/s41586-019-1724-z)
- Berner et al., 2019 — OpenAI Five: PPO at scale, 80/20 past-self pool,
  surgeries, compute (arXiv:1912.06680; openai.com/index/openai-five)
- Lanctot et al., NeurIPS 2017 — joint-policy correlation, PSRO
  (arXiv:1711.00832)
- Czarnecki et al., NeurIPS 2020 — *Real World Games Look Like Spinning
  Tops* (arXiv:2004.09468)
- Ubisoft La Forge, AAMAS 2024 — *The Minimax Exploiter* (For Honor
  league at 100-hour scale) (arXiv:2311.17190)

From the targeted verification pass — LLM thread (all checked against
primary papers/pages; figures quoted in §6):

- Ma et al., ICLR 2024 — *Eureka: Human-Level Reward Design via Coding
  LLMs* (arXiv:2310.12931)
- Romera-Paredes et al., Nature 2024 — *FunSearch*
  (nature.com/articles/s41586-023-06924-6)
- Google DeepMind, 2025 — *AlphaEvolve* white paper (arXiv:2506.13131)
- Wang et al., 2023 — *Voyager* (arXiv:2305.16291)
- Meta FAIR, Science 2022 — *Cicero* (Diplomacy; abstract-verified
  figures only — full text paywalled)
- Qi et al., ICLR 2024 — *CivRealm* (arXiv:2401.10568); CivAgent
  follow-up (arXiv:2502.20807)
- *TextStarCraft2* (arXiv:2312.11865); *SwarmBrain* (arXiv:2401.17749)
- Policies-as-code 2024–25: PORTAL (arXiv:2503.13356), generative code
  optimization for game agents (arXiv:2508.19506), PolicyEvolve
  (arXiv:2509.06053), Strategist (arXiv:2408.10635)

From the targeted verification pass — black-box budgets & balance cases
(figures quoted in §5):

- Hansen — *The CMA Evolution Strategy: A Tutorial* (arXiv:1604.00772) +
  cma-es.github.io benchmark counts; Auger & Hansen, CEC 2005 —
  IPOP-CMA-ES
- Stockfish — chessprogramming.org *Stockfish's Tuning Method* & *SPSA*;
  official fishtest wiki (SPRT example runs, Elo error-bar tables)
- Liu et al., 2017 — GVGAI skill-depth tuning via hill-climbing
  (arXiv:1703.06275)
- de Mesentier Silva et al., IEEE CoG 2019 — *Evolving the Hearthstone
  Meta* (arXiv:1907.01623)
- Gudmundsson et al., IEEE CIG 2018 — *Human-Like Playtesting with Deep
  Learning* (Candy Crush; abstract-verified, full text paywalled)
- Mouret & Clune, 2015 — *Illuminating search spaces by mapping elites*
  (arXiv:1504.04909); Fontaine et al., GECCO 2019 — Hearthstone
  MAP-Elites (arXiv:1904.10656)
- López-Ibáñez et al., 2016 — *The irace package* (iterated racing
  budgets); paired-seed CRN variance analysis (arXiv:2512.24145)

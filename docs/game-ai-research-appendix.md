# Game AI research appendix — verified evidence log

Raw output of the two deep-research passes behind docs/game-ai.md.
Each finding survived 3-vote adversarial verification against primary
sources (votes shown); refuted claims and coverage caveats are included
because they scope what the main document may and may not assert. The
black-box-budget and LLM-thread figures quoted in game-ai.md SS5-SS6 were
verified separately, directly against the primary papers listed in its
sources section.

---

# PASS 1 — decision architectures, stability/control, evaluation

# SUMMARY

For a small team without GPU clusters, the production-proven path to a competent 4X AI is hand-authored, data-driven decision architectures — utility/priority systems, budget-pool allocation, and hierarchical "strategic overseer + tactical executor" designs — not end-to-end learning: every shipped game with verified evidence (Civilization, Stellaris, Kohan II, AI War 1/2, Prismata) uses scripted/data-driven strategy layers, and vanilla tree search or MCTS is provably intractable on full RTS/4X state spaces without heavy abstraction. The strongest CPU-only pattern with production validation is portfolio-style hierarchy: scripted "partial player" modules propose candidate moves per domain and a small search (alpha-beta/MCTS over the cross-product) picks among them — Prismata's HPS ran ~1M games against humans at top-25% ladder strength on ≤3s/move, robust through 20+ balance patches; research further shows a slow strategic search can be distilled into a ~3ms supervised policy to free the frame budget for tactical search. Long-horizon stability comes from explicit engineering, not learning: goal-commitment terms in utility scores (Kohan II), budget inertia with cap-based overflow instead of reactive reallocation (AI War 2), and asymmetric AI economies that remove the self-bankruptcy failure mode entirely (AI War). For evaluation, headless multi-client simulation is proven in grand-strategy production (Stellaris), and the StarCraft competition record shows mass automated round-robin plus Elo ladders is the right harness — while warning that win-rates are strongly non-transitive (rock-paper-scissors among top bots), so single-opponent fitness is misleading; simple UCB bandits over strategy portfolios delivered real inter-game adaptation. Notably, no claims about RL/evolutionary training methods or LLM-informed approaches (Eureka, FunSearch, Cicero, CivRealm) survived adversarial verification, so those threads of the question remain evidence-light in this report; separately, practitioners (Soren Johnson) frame shipped 4X AI as an entertainment-design problem where tuned cheating and deliberately not maximizing win-rate are legitimate choices.

# FINDINGS

## Finding 0: [high / 3-0 (merged from claims 0, 13, 17)]

CLAIM: Shipped commercial strategy-game AI is overwhelmingly hand-authored and data-driven — scripting, FSMs/hierarchical FSMs, decision trees, rule-based systems, and designer-exposed data files — not academic learning/planning methods; and most commercial implementations cheat by ignoring fog-of-war (seeing the whole map, sometimes simulating fake scouting). Stellaris's NPC empires are data-driven script/weight systems (per its own GDC 2017 developer talk); StarCraft's built-in AI is a static script choosing randomly among a few predetermined behaviors. Hard-coded approaches succeed in production but struggle to encode adaptive behavior and are exploitable by adaptive opponents.

EVIDENCE: Three independent primary sources agree: Paradox's GDC 2017 talk 'Creating Complex AI Behavior in Stellaris Through Data Driven Design' (verbatim: 'design and implementation of data driven AI, to create NPCs with unique and non static personalities'); the peer-reviewed IEEE TCIAIG 2013 StarCraft survey ('Hard-coded approaches have been extensively used in commercial RTS games... finite state machines... Hierarchical FSMs... most AI implementations cheat, since the AI can see the complete game map at all times'); and the AAAI AI Magazine 2014 survey ('scripting, finite state machines, decision trees, and rule-based systems are still the most commonly used... the built-in AI of StarCraft uses a static script which chooses randomly among a small set of predetermined behaviors'). Caveat: the FSM-dominance and fog-of-war-cheating characterizations describe pre-2013/2014 commercial practice; later titles diversified into behavior trees/utility systems.

SOURCES: https://www.gdcvault.com/play/1024223/Creating-Complex-AI-Behavior-in | https://hal.science/hal-00871001/document | https://www.cs.auckland.ac.nz/research/gameai/publications/Robertson_Watson_AIMag14.pdf

## Finding 1: [high / 3-0 (merged from claims 1, 2, 3)]

CLAIM: Production 4X AI is framed by its own practitioners as a game-design problem as much as a technical one: Soren Johnson (Civ III co-designer, Civ IV lead designer/AI programmer) explicitly treats AI cheating and deliberately NOT maximizing win-rate ('playing to lose') as legitimate, per-difficulty-tunable design choices, and asks whether the game design itself should be adjusted to accommodate AI limitations rather than only making the AI stronger. Shipped Civilization AI is designed as a compelling entertainment opponent, not a win-rate-maximizing agent.

EVIDENCE: Primary practitioner source: full audio recording of Johnson's GDC 2008 talk 'Playing to Lose: AI and Civilization' (archive.org), description verbatim: 'Can the AI behave like a human? Should it? Should the game design be adjusted to accommodate the limitations of the AI?... How do we make the AI fun? Should the AI cheat? If so, how much? Do we even want the AI to win?'. Verifiers corroborated via GDC Vault, Johnson's designer-notes.com, and shipped Civ4 XML handicap data confirming per-difficulty hidden bonuses (barbarian combat bonus, reduced unit support/inflation costs, war weariness reductions) even at the 'balanced' Noble level, plus explicit gang-up-on-the-leader code. Actionable for the research question: win-rate is not the only production objective; difficulty tiers are tuned cheat magnitudes.

SOURCES: https://archive.org/details/GDC2008Johnson2

## Finding 2: [high / 3-0 (claim 12)]

CLAIM: Full-scale RTS/4X games are combinatorially beyond direct game-tree search: StarCraft's estimated state space is ~10^1685 with a per-frame branching factor of 10^50–10^200 (vs b≈35 for Chess, b≈30–300 for Go) and depth ≈36,000 frames — so standard tree search and vanilla MCTS cannot be applied to full RTS/4X-scale games without heavy abstraction of states and actions. MCTS-style methods only worked in small-scale RTS settings as of the survey.

EVIDENCE: Peer-reviewed IEEE TCIAIG 2013 survey (Ontañón, Synnaeve, Uriarte, Richoux, Churchill, Preuss), 1000+ citations; all figures verified verbatim, including the conclusion 'standard techniques used for playing classic board games, such as game tree search, cannot be directly applied to solve RTS games without the definition of some level of abstraction'. Corroborated by AlphaStar (2019) abandoning tree search for policy-network league self-play. Figures are acknowledged back-of-envelope estimates but are static combinatorial properties, so the 2013 date does not stale them. Engineering implication: any search-based 4X AI must search over abstractions (portfolios, scripts, budgets), not raw actions.

SOURCES: https://hal.science/hal-00871001/document

## Finding 3: [high / 3-0 (merged from claims 18, 14)]

CLAIM: Hierarchical decomposition — a strategic overseer influencing individually-controlled units/modules — recurs across RTS AI systems because it collapses the decision space from a combinatorial (exponential per-unit joint) action space to a multiplicative one. Source-code analysis of seven top StarCraft competition bots (BroodwarBotQ, Nova, UAlbertaBot, Skynet, SPAR, AIUR, BTHAI) confirms the pattern in practice: nearly all pair reactive low-level unit control with a scripted/FSM strategy layer on top, coordinated via blackboards, arbitrators, or resource-prioritization managers. Notable exceptions: UAlbertaBot planned all economic build orders with online search instead of hard-coding, and AIUR randomized among six 'moods'.

EVIDENCE: Two peer-reviewed surveys, both verified verbatim: AAAI AI Magazine 2014 ('Similar hierarchical decomposition appears in many RTS AI approaches because it reduces complexity from a combinatorial combination of possibilities... down to a multiplicative combination') and IEEE TCIAIG 2013 Fig. 3 bot-architecture analysis ('all of them (except AIUR) are reactive at the lower level... most if not all of them, are scripted at the highest level of abstraction... An interesting exception... UAlbertaBot, which uses a search algorithm in the Production Manager to find near-optimal build orders'). Important scoping from the refuted-claims list: the stronger claim that three-tier decomposition is THE dominant, empirically most successful architecture was rejected 0-3 — hierarchy is a recurring, validated tractability pattern, not a proven optimum.

SOURCES: https://www.cs.auckland.ac.nz/research/gameai/publications/Robertson_Watson_AIMag14.pdf | https://hal.science/hal-00871001/document

## Finding 4: [high / 3-0 (merged from claims 4, 5, 6)]

CLAIM: AI War: Fleet Command (shipped 2009) rejected the centralized decision-tree architecture of most RTS games in favor of decentralized per-unit agent intelligence from which group behavior emerges: three decision tiers (strategic, sub-commander, individual-unit) where the strategic tier is explicitly programmed but the sub-commander tier — coordinated multi-group attacks splitting into 2-3 groups hitting multiple targets simultaneously — is fully emergent from per-unit rules with no explicit group-coordination code. The AI's heavy computation ran on a separate thread on the host machine as LINQ (database-style) bulk queries, controlling 20,000+ ships on 2009-era dual-core consumer hardware without gameplay lag — production proof that large-scale strategy AI needs no GPU compute.

EVIDENCE: Primary source: lead developer Chris Park's 'Designing Emergent AI' series, all quotes verified verbatim ('simulating intelligence in each of the individual units, rather than simulating a single overall controlling intelligence'; 'the sub-commander logic is completely emergent... never explicitly programmed'; 'The AI runs on a separate thread on the host computer only... using LINQ'). Corroborated by Wikipedia, contemporaneous interviews (Three Moves Ahead ep. 37, Co-Optimus), and Arcen's companion optimization post confirming 30,000-60,000 ships in real campaigns. Qualifications from verification: not purely decentralized — a centralized global commander handles planet reinforcement/wave targeting; LINQ was later replaced with raw list sorts for speed (the durable enabler was the separate-thread bulk-query architecture); 'no lag' is developer self-report and degrades at pathological late-game counts far beyond 20k.

SOURCES: https://arcengames.com/designing-emergent-ai-part-1-an-introduction/

## Finding 5: [high / 3-0 (merged from claims 8, 9)]

CLAIM: AI War 2 (shipped 2019) is a documented production example of the 'strategic overseer + tactical executor' design with explicit time budgeting: a strategic 'consciousness' layer runs on one background thread per non-human faction type, making higher-level decisions over several seconds, while a tactical 'subconscious' runs on the main simulation thread capped at roughly 30ms per cycle for targeting/movement/collision avoidance. Its strategic layer is budget-driven rather than plan-driven: faction income continuously accumulates into named budget pools (waves, planet reinforcements, cross-planet attacks, warden, reconquest waves, hunter fleet, praetorian guard, wormhole invasions), and strategic behavior emerges from how those pools fill and spend.

EVIDENCE: Primary source: Arcen's official developer wiki (AI War 2:AI Mechanisms, content attributed to lead dev Chris McElligott Park), verified by direct fetch, corroborated by the separate 'Threading Model' wiki page ('one background thread per non-human faction type... higher level thinking... a few seconds at a time'; 'the main AI Sentinels logic... allocates budget income to its budget items, and those build up'). Minor precision note: the ~30ms figure is the stated per-cycle target maximum inside a ~100ms absolute ceiling. This maps directly onto the research question's two-time-scale problem: slow deliberate strategy thread + fast bounded tactical loop, with income-allocation-as-strategy replacing explicit plans.

SOURCES: https://wiki.arcengames.com/index.php?title=AI_War_2%3AAI_Mechanisms

## Finding 6: [high / 3-0 (merged from claims 16, 10, 7)]

CLAIM: Production strategy games solve objective ping-ponging and self-destructive behavior with explicit control mechanisms, not learning: (a) Kohan II: Kings of War's shipped utility-style goal-priority AI added an explicit goal-commitment term to each priority value to prevent flip-flopping once a goal was selected, plus a random term to reduce predictability — reported to make the AI both fun and easier to maintain through design changes; (b) AI War 2 deliberately avoids reactive budget reallocation to prevent oscillating/rubber-banding — if the player destroys most of the hunter fleet the AI does not surge funding back into it; recovery happens gradually via a cap-based overflow system where budget for at-cap items is donated to items not at cap; (c) AI War 1 sidestepped the AI-bankrupts-its-own-economy failure mode entirely by giving the AI wholly asymmetric economic rules (internal reinforcement points, wave countdowns, an 'AI Progress' number) while keeping tactical and most strategic rules symmetric with the player.

EVIDENCE: Three independent primary/near-primary sources, all verified verbatim: AAAI AI Magazine 2014 survey citing Kevin Dill's first-hand account (Dill 2006, AI Game Programming Wisdom 3: 'a goal commitment value (to prevent flip-flopping once a goal has been selected) and a random value (to reduce predictability)'); Arcen wiki ('if the humans whittle down the hunter fleet to next to nothing, the AI won't suddenly give a surge of income to the hunters... it will donate the budget that would have gone to the PG to other purposes based on what is NOT at cap'); Arcen dev blog ('the AI in AI War follows wholly different economic rules than the human players (but all of the tactical and most strategic rules are the same)'). Caveats: AI War 2's stated rationale is player-experience fairness (the anti-oscillation gloss is a fair paraphrase); the hunter fleet also recovers via sentinel donations, so cap-overflow is not literally the only path; AI War's asymmetry was motivated by variety/exploit-resistance, with bankruptcy-immunity as a logically entailed consequence. Together these are the confirmed evidence base for the question's hysteresis/commitment/anti-self-destruction thread: commitment bonuses in utility scores, budget inertia with slow donation-based recovery, and removing the economy the AI could wreck.

SOURCES: https://www.cs.auckland.ac.nz/research/gameai/publications/Robertson_Watson_AIMag14.pdf | https://wiki.arcengames.com/index.php?title=AI_War_2%3AAI_Mechanisms | https://arcengames.com/designing-emergent-ai-part-1-an-introduction/

## Finding 7: [high / 3-0 (merged from claims 19, 20, 21)]

CLAIM: Hierarchical Portfolio Search (HPS) is a production-proven, CPU-only architecture directly suited to a small team: a bottom layer of scripted 'partial players' grouped by tactical phase (defense/ability/buy/breach in Prismata) each proposes candidate partial moves, and a top-level game-tree search (Negamax/alpha-beta/MCTS) searches the cross-product of candidates to pick the turn's move — reducing an intractable action space to a searchable one. It shipped in Prismata, ran 2+ years across ~1M games against humans, stayed robust through 20+ balance patches without per-unit logic rework, and its strongest configuration (12 partial players + 3-second MCTS) covertly reached Tier 6 (top 25% of the human ranked ladder) in ~200 games/48 hours, later estimated at Tier 8 (stronger than all but the top 10-15% of humans) — all on per-move CPU budgets of 3 seconds or less, no GPUs or training runs.

EVIDENCE: Primary source: GameAIPro3 Ch. 30 by Churchill & Buro (the Prismata AI authors), full text verified including Listing 30.1's literal crossProduct implementation; corroborated by the peer-reviewed AIIDE 2015 paper (same covert ladder experiment, bot 'MyNameIsJeff'), a GDC 2017 talk, and the open-sourced production C++ engine (github.com/davechurchill/PrismataAI). Caveats: the 2-year/1M-game/20-patch figures and the Tier 8 estimate are developer self-reports (Tier 8 never verified by a second ladder run); Prismata was a live paid-alpha/beta during the window (full Steam release 2018); Prismata is a turn-based economy/combat game — closer to a 4X turn than to real-time micro, which strengthens its transferability to the user's 4X but means the ladder percentiles are Prismata-specific.

SOURCES: http://www.gameaipro.com/GameAIPro3/GameAIPro3_Chapter30_Hierarchical_Portfolio_Search_in_Prismata.pdf

## Finding 8: [high / 3-0 (merged from claims 22, 23)]

CLAIM: The two-layer 'strategic learner + tactical searcher' hybrid is validated in research and comes with a compute-frugal distillation recipe: in microRTS, a CNN choosing among a small set of abstract scripted strategies for all units, plus NaiveMCTS refining actions of only the units near combat, beat both components alone and other state-of-the-art microRTS agents (88.3% tournament win rate; the same architecture won the first IEEE microRTS competition as 'StrategyTactics'). The CNN was trained by supervised learning to predict the output of a slow strategic search (Puppet Search), after which it ran in ~3ms of the 100ms frame budget, freeing nearly the entire budget for tactical search — an offline 'distill expensive planning into a cheap policy' pattern achievable on a single desktop (~2,190 training games, one consumer GPU).

EVIDENCE: Peer-reviewed AIIDE 2017 paper (Barriga, Stanescu, Buro, arXiv:1709.03480), verified verbatim ('the policy network uses a fixed time (around 3ms), and the remaining time is assigned to the tactical search'; 'higher win-rates than either of its two independent components and other state-of-the-art microRTS agents'), plus external validation via the official IEEE CIG 2017 microRTS competition results (first place, Standard and Non-deterministic tracks). Caveats: research-only, not a shipped game; 'full RTS' means full microRTS (128x128 maps favorable to the strategic layer), not commercial scale; 3ms inference measured on a GTX 1070; the combined agent only partially compensates for policy-net weaknesses vs specific opponents. For the user's setting the transferable pattern is: hand-write a small strategy portfolio, use slow search offline to label states, train a tiny policy to pick strategies, spend runtime CPU on tactical search.

SOURCES: https://arxiv.org/pdf/1709.03480

## Finding 9: [high / 3-0 (merged from claims 11, 15)]

CLAIM: Evaluation methodology with production and competition provenance: (a) Paradox built a headless graphics-free build of Stellaris to run multiple game clients on one machine as an automated multiplayer testing harness — production evidence that headless multi-client simulation is practical for grand-strategy games; (b) the StarCraft AI competitions evolved to automated mass round-robin play (1,170 games on 20 machines in 2011; 4,240 in 2012) specifically to eliminate bracket luck, plus a continuous Elo-rated bot ladder; (c) results exposed strong non-transitivity (AIIDE 2011: Skynet beat UAlbertaBot 26/30, UAlbertaBot beat AIUR 29/30, yet AIUR beat Skynet 19/30); (d) simple bandit methods deliver real inter-game adaptation — in 2012, 6 of 10 entrants including the top 4 used persistent storage for opponent-specific strategy selection, UAlbertaBot via UCB; yet (e) non-adaptive hard-coded newcomers (KillerBot, Ximp) still topped the Elo ladder because no existing bot could adapt a counter.

EVIDENCE: Two primary sources verified verbatim: the Game Developer/Gamasutra Stellaris postmortem authored by the game director and project lead ('a version of the game that runs without any graphics, allowing him to run multiple clients on the same machine'), and the IEEE TCIAIG 2013 survey co-authored by the AIIDE competition organizer (all game counts, the 26/29/19 rock-paper-scissors triangle, the UCB usage, and the KillerBot/Ximp Elo passages verified). Key caveat: the Stellaris harness was built for desync/OOS regression testing, not AI-strength evaluation — its use for balance/AI ladders is an inference. Engineering implications: build the headless harness early; evaluate against a population (round-robin/ladder), never a single champion, because non-transitivity makes single-opponent win-rate a misleading fitness signal; cheap UCB-style bandits over a strategy portfolio are a proven, near-free adaptation mechanism.

SOURCES: https://www.gamedeveloper.com/design/postmortem-paradox-development-studio-s-i-stellaris-i- | https://hal.science/hal-00871001/document

# OTHER KEYS

{
 "caveats": "Coverage gaps are the biggest caveat: of the five requested threads, only (1) decision architectures, (3) stability/control, and (5) evaluation have confirmed claims. NO claims survived verification for thread (2) optimization/training methods (PPO, league self-play, CMA-ES, MAP-Elites, population-based training, simulated annealing \u2014 including their sample-efficiency tradeoffs) or thread (4) LLM-informed approaches 2023-2026 (Eureka, FunSearch/AlphaEvolve, Cicero, Voyager, CivRealm/CivAgent, LLM-designed policies-as-code) \u2014 those sections of any final report rest on zero verified evidence from this pass and must be researched separately or clearly marked unverified. Time-sensitivity: the commercial-practice characterizations (FSM dominance, fog-of-war cheating, StarCraft's static script) describe pre-2013/2014 industry practice; the Stellaris data-driven evidence describes the 2016-2017 shipped implementation before the 2.x/3.x AI reworks; no confirmed evidence covers Old World, Distant Worlds, or any post-2019 shipped 4X, despite the question naming them. Self-report risk: the AI War ship counts/no-lag claims and Prismata's 1M-games/Tier-8 figures are unaudited developer statements (though from detailed technical writeups, not marketing). Scope inferences flagged by verifiers: AI War is not purely decentralized (a central strategic commander exists); the Stellaris headless build was for desync testing, and generalizing it to AI evaluation is an inference; 'full RTS' in the microRTS result means full microRTS, not commercial scale. One refuted claim matters for framing: the assertion that strategy/tactics/reactive three-tier decomposition is the dominant, empirically most successful architecture was rejected 0-3 \u2014 hierarchy should be presented as a recurring, validated pattern, not a proven optimum.",
 "openQuestions": [
  "Do LLM-informed methods (Eureka-style reward/heuristic writing, FunSearch/AlphaEvolve-style program search, or an offline LLM reading the game's Elixir codebase to design and tune a scripted utility/portfolio policy) actually transfer to a slow-simulation indie 4X, and at what token/compute cost? None of the 2023-2026 LLM claims survived verification, so this remains the largest unanswered thread of the original question.",
  "What are realistic wall-clock and sample-efficiency numbers for CPU-only weight tuning (CMA-ES, hill-climbing/annealing, MAP-Elites, population-based training) when one game simulation takes minutes to hours \u2014 and does the 2-hour 'fast' mode serve as a valid tuning proxy for the 2-4 week 'legacy' mode, or do tuned weights fail to transfer across time scales?",
  "How do modern shipped 4X titles (Old World, Humankind, post-rework Stellaris 3.x+, Distant Worlds 2) implement their AI? The confirmed production evidence ends around 2017-2019, and Old World in particular (Soren Johnson's own studio) likely embodies updated versions of the design philosophy confirmed here.",
  "Given the strong non-transitivity documented in the AIIDE data, what population/league structure and fitness design keeps a self-play improvement loop from chasing rock-paper-scissors cycles at indie scale \u2014 e.g., how many diverse frozen opponents are enough for a stable Elo/TrueSkill signal on a small CPU budget?"
 ],
 "refuted": [
  {
   "claim": "The dominant, empirically most successful architecture for full strategy-game AI is hierarchical task decomposition into strategy (macro, minutes-scale), tactics (group-level, spatial/temporal), and reactive control (per-unit, second-by-second) \u2014 holistic single-technique agents (e.g., pure MCTS, monolithic CBR/RL) only work in small-scale RTS settings and do not scale to StarCraft-sized games.",
   "vote": "0-3",
   "source": "https://hal.science/hal-00871001/document"
  }
 ],
 "unverified": [],
 "sources": [
  {
   "url": "https://www.gdcvault.com/play/1024223/Creating-Complex-AI-Behavior-in",
   "quality": "primary",
   "angle": "Shipped-game practice (practitioner)",
   "claimCount": 4
  },
  {
   "url": "https://archive.org/details/GDC2008Johnson2",
   "quality": "primary",
   "angle": "Shipped-game practice (practitioner)",
   "claimCount": 5
  },
  {
   "url": "https://arcengames.com/designing-emergent-ai-part-1-an-introduction/",
   "quality": "primary",
   "angle": "Shipped-game practice (practitioner)",
   "claimCount": 5
  },
  {
   "url": "https://wiki.arcengames.com/index.php?title=AI_War_2%3AAI_Mechanisms",
   "quality": "primary",
   "angle": "Shipped-game practice (practitioner)",
   "claimCount": 5
  },
  {
   "url": "https://www.civfanatics.com/2023/01/01/gdc-2022-soren-johnson-my-elephant-in-the-room-an-old-world-postmortem/",
   "quality": "secondary",
   "angle": "Shipped-game practice (practitioner)",
   "claimCount": 2
  },
  {
   "url": "https://www.gamedeveloper.com/design/postmortem-paradox-development-studio-s-i-stellaris-i-",
   "quality": "primary",
   "angle": "Shipped-game prac
---

# PASS 2 — RL at scale, league design

# SUMMARY

The verified evidence in this pass decisively covers Thread A(1) (RL at scale) and Thread C (league design), but no claims survived for Thread A(2)/(3) (CMA-ES/GA/SPSA budgets, balance-tuning case studies) or Thread B (LLM-informed approaches) — those remain open. Production-proven league self-play exists at exactly one documented scale: datacenter (AlphaStar: 12 agents x 32 TPUv3 x 44 days, ~192,000 concurrent games, ~900 frozen league players; OpenAI Five: 770+/-50 PFlops/s-days over 10 months, ~180 years of gameplay/day, up to 1,536 GPUs and 172,800 rollout CPUs) — 4-6 orders of magnitude beyond an indie CPU budget. The transferable lessons are (a) why naive self-play fails — non-transitive strategy cycling and forgetting, quantified by AlphaStar's ablations (pure self-play retains only 46% min win-rate vs past versions, vs 71% for the PFSP+self-play league mix) and ~3,000,000 rock-paper-scissors cycles in the league payoff matrix — and (b) the concrete anti-cycling recipes: AlphaStar's 35/50/15 PFSP mix with f_hard(x)=(1-x)^p opponent weighting and exploiter agents, OpenAI Five's much cheaper 80% current / 20% frozen-past split, PSRO as the unifying framework, and spinning-top theory tying required population size to the game's non-transitive structure (Theorem 6: covering a full Nash cluster guarantees transitive improvement) rather than to compute. The most indie-relevant compute datapoint is Ubisoft's Minimax Exploiter on For Honor: a 100-hour league run producing 16 converged exploiters and a Main Agent winning >66% against all peers — industry-tested but not live-deployed.

# FINDINGS

## Finding 0: [high / 3-0 (4 merged claims, all unanimous)]

CLAIM: AlphaStar's league architecture is fully specified in the Nature 2019 paper and is deliberately NOT plain self-play: 12 training agents (3 main agents, 3 main exploiters, 6 league exploiters — per StarCraft race) with asymmetric objectives, producing ~900 frozen 'players' as league opponents. Main agents train 35% self-play, 50% prioritized fictitious self-play (PFSP) against all past league players, and 15% PFSP against forgotten/exploiter players; PFSP weights opponents by f_hard(x)=(1-x)^p so no games are wasted on already-beaten opponents; a frozen snapshot joins the league every 2x10^9 steps; main agents never reset; exploiters join the league at >70% win-rate or on timeout and are periodically reset to supervised parameters. The exploiters exist solely to expose main-agent weaknesses because 'playing to win is insufficient.'

EVIDENCE: Verified verbatim against the primary Nature paper PDF: 'three main agents..., three main exploiter agents..., and six league exploiter agents'; 'a proportion of 35% SP, 50% PFSP against all past players in the League, and an additional 15% of PFSP matches against forgotten main players... Main agents never reset'; 'Choosing f_hard(x) = (1-x)^p makes PFSP focus on the hardest players... no games are played against opponents that the agent already beats'; 'almost 900 distinct players were created.' Blog confirms the design rationale: 'playing to win is insufficient: instead, we need both main agents whose goal is to win versus everyone, and also exploiter agents that focus on... exposing its flaws.' Merged from 4 claims, each verified 3-0.

SOURCES: https://storage.googleapis.com/deepmind-media/research/alphastar/AlphaStar_unformatted.pdf | https://www.nature.com/articles/s41586-019-1724-z | https://deepmind.google/blog/alphastar-grandmaster-level-in-starcraft-ii-using-multi-agent-reinforcement-learning/

## Finding 1: [high / 3-0 (3 merged claims, all unanimous)]

CLAIM: Naive self-play demonstrably fails via non-transitive strategy cycling and forgetting, with hard numbers: AlphaStar's paper states self-play 'may chase cycles indefinitely'; in ablations pure self-play (SP) reached high Elo (1519) but retained only a 46% minimum win-rate against past versions, versus 71% for the PFSP+SP league mix (FSP 1143 Elo/69%, pFSP 1273/70%, pFSP+SP 1540/71%). The league's internal payoff matrix contains ~3,000,000 rock-paper-scissors cycles (>=70% win-rate threshold), with exploiters generating nearly all non-transitivity (~200 cycles involve only main agents) while main agents improve transitively.

EVIDENCE: All figures verified verbatim in the primary PDF: 'Self-play algorithms... may chase cycles (for example, where A defeats B, and B defeats C, but A loses to C) indefinitely without making progress'; Fig. 3C/D numbers (Elo 1143/1273/1519/1540; min win-rate vs past 69%/70%/46%/71%); 'Naive self-play has high Elo, but is more forgetful'; Extended Data Fig. 8: 'around 3,000,000 rock-paper-scissor cycles (with requirement of at least 70% win rates to form a cycle)... around 200 that involve only main agents... The main agents behave transitively.' Note: ablations ran at reduced scale (10^10 steps, main agents only). Merged from 3 claims, each verified 3-0.

SOURCES: https://storage.googleapis.com/deepmind-media/research/alphastar/AlphaStar_unformatted.pdf | https://www.nature.com/articles/s41586-019-1724-z | https://deepmind.google/blog/alphastar-grandmaster-level-in-starcraft-ii-using-multi-agent-reinforcement-learning/

## Finding 2: [high / 3-0 (3 merged claims, all unanimous)]

CLAIM: Independent per-agent RL (of which naive self-play is a special case) overfits to training co-players even in trivial environments — quantified by the joint-policy correlation (JPC) metric introduced by Lanctot et al. (NeurIPS 2017): in a small, almost fully observable laser-tag gridworld, pairing with a different independently-trained agent costs 34.2% of expected reward (62.5% and 71.7% on slightly larger maps). The same paper defines PSRO (Policy-Space Response Oracles): each iteration computes an approximate best response to a meta-strategy mixture over the policy pool, and it generalizes independent RL, iterated best response, double oracle, and fictitious play — the standard menu of anti-cycling league designs.

EVIDENCE: Verified verbatim against the primary NeurIPS 2017 paper: 'policies learned using InRL can overfit to the other agents' policies during training, failing to sufficiently generalize during execution. We introduce a new metric, joint-policy correlation, to quantify this effect'; Table 1 confirms R- = 0.342/0.625/0.717 for small2/small3/small4; abstract confirms PSRO 'generalizes previous ones such as InRL, iterated best response, double oracle, and fictitious play.' Merged from 3 claims, each verified 3-0.

SOURCES: https://arxiv.org/abs/1711.00832

## Finding 3: [high / 3-0 (4 merged claims, all unanimous)]

CLAIM: AlphaStar's documented compute is far beyond indie budgets: each of the 12 training agents used 32 TPUv3 devices for 44 days; per agent the infrastructure ran 16,000 concurrent StarCraft II matches (~192,000 concurrent games total), 16 TPUv3 actor tasks for inference, CPUs 'roughly equivalent to 150 processors with 28 physical cores each' for game instances, and a central 128-core TPU learner processing ~50,000 agent steps/second. The final agents reached Grandmaster level for all three races, rated above 99.8% of officially ranked human players in blind Battle.net play — making league self-play production-proven, but only at datacenter scale.

EVIDENCE: All numbers verified verbatim in the primary PDF's Infrastructure section ('16,000 concurrent StarCraft II matches and 16 actor tasks... roughly equivalent to 150 processors with 28 physical cores each... about 50,000 agent steps per second... 12 separate copies'). Independent corroboration: SCC paper (arXiv:2012.13169) reports '3072 TPU cores and 50,400 preemptible CPU cores for 44 days' = exactly 12x these figures. Result verified in the Nature abstract: 'rated at Grandmaster level for all three StarCraft races and above 99.8% of officially ranked human players.' Caveat: 'production-proven' means live-ladder research deployment under pro-vetted APM/camera limits, not a shipped game product; critics dispute superhuman framing but not the ladder result. Merged from 4 claims, each verified 3-0.

SOURCES: https://storage.googleapis.com/deepmind-media/research/alphastar/AlphaStar_unformatted.pdf | https://www.nature.com/articles/s41586-019-1724-z | https://deepmind.google/blog/alphastar-grandmaster-level-in-starcraft-ii-using-multi-agent-reinforcement-learning/

## Finding 4: [high / 3-0 (3 merged claims, all unanimous)]

CLAIM: OpenAI Five's documented cost: ~10 months of training (June 30, 2018 - April 22, 2019, with over twenty model 'surgeries') consuming 770+/-50 PFlops/s-days of optimization compute before defeating world champions Team OG on April 13, 2019; at the June 2018 snapshot it consumed ~180 years of Dota 2 gameplay per wall-clock day on 256 GPUs and 128,000 CPU cores (scaled PPO), later fluctuating between 480-1,536 optimizer GPUs and 80,000-172,800 rollout CPUs. The from-scratch 'Rerun' reproduction with final code needed only 2 months and 150+/-5 PFlops/s-days (512 GPUs, 51,200 rollout CPUs) — i.e., ~80% of the headline compute was overhead from continual training/surgery, and even the cheap reproduction is far beyond indie scale.

EVIDENCE: Verified against the primary paper: 'After ten months of training using 770+/-50 PFlops/s-days of compute, it defeated the Dota 2 world champions'; 'Rerun took 2 months and 150+/-5 PFlops/s-days'; Table 2 GPU/CPU ranges confirmed; 'we performed over twenty surgeries.' Blog verified: '180 years worth of games against itself every day... 256 GPUs and 128,000 CPU cores.' Caveats: 770 is optimization compute only (~30% of the run's total, which also includes rollout forward passes and CPUs); compute figures are self-reported by OpenAI. Merged from 3 claims, each verified 3-0.

SOURCES: https://arxiv.org/abs/1912.06680 | https://openai.com/index/openai-five/

## Finding 5: [high / 3-0 (1 claim, unanimous; related over-broad variant refuted 0-3)]

CLAIM: The cheapest documented anti-cycling mechanism in a production-grade system is OpenAI Five's minimal league: to avoid 'strategy collapse' (cycling/forgetting), 80% of games were played against the current policy and 20% against a dynamically-weighted pool of frozen past versions — no exploiter agents, no explicit game-theoretic meta-solver. This is the most directly indie-adaptable design from the RL-at-scale literature.

EVIDENCE: Blog verified verbatim: 'To avoid "strategy collapse", the agent trains 80% of its games against itself and the other 20% against its past selves.' Corroborated by the paper (Appendix N): 'play the latest policy against itself for 80% of games, and play against older policies for 20% of games,' with a dynamic quality-score opponent-sampling scheme (past-opponent learning rate 0.01). Note: the 'cycling/forgetting' gloss on 'strategy collapse' comes from the AlphaStar literature — the OpenAI Five paper itself documents the mechanism but does not articulate that failure-mode framing (a related over-attributed claim was refuted 0-3 for exactly that reason; this finding is scoped to what the sources actually say).

SOURCES: https://openai.com/index/openai-five/ | https://arxiv.org/abs/1912.06680

## Finding 6: [high / 3-0 (3 merged claims, all unanimous; quantitative sizing corollary refuted 1-2)]

CLAIM: Theory for sizing a league: real-world games from Tic-Tac-Toe to StarCraft II have a 'spinning top' geometry (Czarnecki et al., NeurIPS 2020) — a vertical transitive-strength axis and a radial non-transitive axis widest at mid-level skill, proven for a wide class of games. This structure explains why populations (not naive two-agent self-play) are required for stable training and ties required population size to the game's non-transitive structure rather than compute budget. Theorem 6 gives a concrete design rule: if the training population contains at least one full Nash cluster, training a new agent to beat everyone in it guarantees transitive (real) improvement.

EVIDENCE: Verified verbatim: abstract states the geometry 'clarifies why populations of strategies are necessary for training of agents, and how population size relates to the structure of the game' and 'We prove the existence of this geometry for a wide class of real world games'; Theorem 6 verified verbatim (full Nash cluster coverage + beating all members => transitive improvement). Independent corroboration: chess study of ~1B human games (arXiv:2110.11737) reproduces the spinning-top shape. Caveats: the proof covers an abstract class (k-layered Games of Skill) real games are argued to instantiate; Theorem 6 is an idealized sufficiency rule (you cannot easily verify Nash-cluster coverage in practice); the sharper quantitative corollary — fixed-memory fictitious play converges if the population is at least as large as the lowest occupied non-transitive layer — was REFUTED in verification (1-2) and should not be relied on as a usable indie-scale sizing formula. Merged from 3 claims, each verified 3-0.

SOURCES: https://arxiv.org/abs/2004.09468 | https://proceedings.neurips.cc/paper/2020/hash/ca172e964907a97d5ebd876bfdd4adbd-Abstract.html

## Finding 7: [high / 3-0 (2 merged claims, all unanimous)]

CLAIM: The most indie-relevant documented league-training compute point is Ubisoft's Minimax Exploiter (AAMAS 2024, tested on For Honor — 36 discrete actions, 160-dim state): it makes AlphaStar-style exploiters more data-efficient by reusing the frozen Main Agent's own Q-values as a dense reward for the exploiter instead of sparse win/loss rewards. In a 100-hour training run it produced 16 converged exploiter generations vs 13 for the vanilla exploiter, and the resulting Main Agent won >66% against all other Main Agents. Industry-tested in a AAA studio's pipeline, but not live-deployed to players.

EVIDENCE: Verified verbatim against the primary paper (peer-reviewed AAMAS 2024, Ubisoft La Forge + McGill): Minimax reward Eq. 3 densifies the exploiter's sparse reward with the frozen opponent's max-Q of the next state; 'The Minimax Exploiter is able to generate 16 converged Exploiters, while the Vanilla Exploiter only generated 13'; 'win-rate above 66% against all other Main Agents'; Figure 1 caption confirms testing environment, not live play. Caveats: self-reported by the method's authors, no independent replication; baseline is a vanilla DQN exploiter within their league, not a literal AlphaStar reproduction; the technique requires access to your own frozen agent's Q-function (fine for a league of your own bots). Merged from 2 claims, each verified 3-0.

SOURCES: https://arxiv.org/html/2311.17190

# OTHER KEYS

{
 "caveats": "Coverage gap is the dominant caveat: all 22 surviving claims fall under Thread A(1) (RL at scale) and Thread C (league design). Nothing survived verification for Thread A(2) (CMA-ES/hill-climbing/simulated-annealing/GA/PBT/quality-diversity sample-efficiency and evaluation budgets), Thread A(3) (game-balance tuning via mass simulation, Stockfish SPSA, TrueSkill fitness), or Thread B (Eureka, FunSearch, AlphaEvolve, Cicero, Voyager, CivRealm, LLM-as-designer costs) \u2014 so this report cannot answer the evaluation-count-budget or LLM-informed portions of the research question, which are arguably the most actionable for a CPU-only indie budget. Other caveats: (1) all compute figures (AlphaStar TPU counts, OpenAI Five PFlops/s-days and experience-years) are self-reported by DeepMind/OpenAI, not independently audited, though internally consistent and corroborated by third-party papers; (2) AlphaStar's self-play-vs-league ablations ran at reduced scale (10^10 steps, main agents only); (3) 770 PFlops/s-days is optimization compute only (~30% of the run's total resource envelope); (4) three related claims were refuted, most importantly the quantitative fixed-memory-fictitious-play league-size criterion (refuted 1-2) \u2014 the spinning-top paper's qualitative population arguments stand, but no verified quantitative minimum-league-size formula exists in this evidence set; (5) 'production-proven' means live-ladder research deployment (AlphaStar) or public exhibition matches (OpenAI Five), and Ubisoft's For Honor results are from a testing environment, not shipped AI \u2014 no claim here documents league-trained RL agents shipped in a commercial game; (6) sources are 2017-2024 and historical in nature, so time-sensitivity is low, but the absence of 2024-2026 LLM-thread evidence means the report may understate the current state of the art for the offline LLM-as-designer approach.",
 "openQuestions": [
  "What are realistic evaluation-count budgets for derivative-free optimizers (CMA-ES, GA, SPSA, simulated annealing) tuning 10-100 utility-weight parameters when each evaluation is a minutes-long 4X game simulation \u2014 and which documented game-balancing case studies (Stockfish SPSA fishtest, card-game GA balancing, city-builder tuning) give concrete simulation counts? (Thread A2/A3, unanswered)",
  "Do the 2023-2026 LLM-as-designer results (Eureka's reward-writing loop, FunSearch/AlphaEvolve program evolution, Voyager's skill library, CivRealm/CivAgent baselines) verify against their primary papers, and what are the documented token/cost figures that make offline LLM-written scripted policies preferable to inline LLM play? (Thread B, entirely unanswered)",
  "What is the minimal viable league at indie CPU scale \u2014 is OpenAI Five's 80/20 past-self pool sufficient for a 4X's non-transitive strategy space, and is there any cheap empirical proxy for the game's Nash-cluster width (spinning-top radius) to size the frozen-opponent pool, given the quantitative fixed-memory-FSP criterion was refuted?",
  "Are there documented indie- or academic-scale (single-machine, CPU-only) league/PSRO training successes on slow simulators \u2014 e.g., PSRO variants with surrogate fitness models or match-outcome prediction to cut game-evaluation counts?"
 ],
 "refuted": [
  {
   "claim": "OpenAI Five's self-play scheme was not pure latest-vs-latest: 80% of games were played against the current policy and 20% against a pool of older policy versions, a mechanism for opponent diversity. Note: the paper documents the 80/20 mix but does not explicitly articulate 'strategy cycling/forgetting' as the failure mode of naive self-play \u2014 that framing comes from secondary sources and the AlphaStar literature, not this paper.",
   "vote": "0-3",
   "source": "https://arxiv.org/abs/1912.06680"
  },
  {
   "claim": "According to this paper (citing Vinyals et al. 2019 and Sun et al. 2020), AlphaStar trained a 139-million-parameter model in 44 days using roughly 5x10^5 CPUs and 3x10^3 GPUs, while TLeague trained a 20-million-parameter model in 57 days with roughly 1.3x10^4 CPUs and 144 GPUs \u2014 documenting the compute scale of league-based competitive self-play.",
   "vote": "0-3",
   "source": "https://arxiv.org/html/2311.17190"
  },
  {
   "claim": "Fixed-memory fictitious self-play provably converges in layered Games of Skill provided the frozen-opponent population is at least as large as the lowest non-transitive layer currently occupied \u2014 a quantitative minimum-league-size criterion usable at indie/small-compute scale.",
   "vote": "1-2",
   "source": "https://arxiv.org/abs/2004.09468"
  }
 ],
 "unverified": [],
 "sources": [
  {
   "url": "https://storage.googleapis.com/deepmind-media/research/alphastar/AlphaStar_unformatted.pdf",
   "quality": "primary",
   "angle": "primary/RL-at-scale compute & self-play failure",
   "claimCount": 5
  },
  {
   "url": "https://arxiv.org/abs/1912.06680",
   "quality": "primary",
   "angle": "primary/RL-at-scale compute & self-play failure",
   "claimCount": 5
  },
  {
   "url": "https://deepmind.google/blog/alphastar-grandmaster-level-in-starcraft-ii-using-multi-agent-reinforcement-learning/",
   "quality": "primary",
   "angle": "primary/RL-at-scale compute & self-play failure",
   "claimCount": 5
  },
  {
   "url": "https://openai.com/index/openai-five/",
   "quality": "primary",
   "angle": "primary/RL-at-scale compute & self-play failure",
   "claimCount": 5
  },
  {
   "url": "https://arxiv.org/pdf/2408.01072",
   "quality": "secondary",
   "angle": "primary/RL-at-scale compute & self-play failure",
   "claimCount": 5
  },
  {
   "url": "https://arxiv.org/html/2311.17190",
   "quality": "primary",
   "angle": "primary/RL-at-scale compute & self-play failure",
   "claimCount": 5
  },
  {
   "url": "https://arxiv.org/abs/1711.00832",
   "quality": "primary",
   "angle": "game-theoretic league design on small compute",
   "claimCount": 5
  },
  {
   "url": "https://www.nature.com/articles/s41586-019-1724-z",
   "quality": "primary",
   "angle": "game-theoretic league design on small compute",
   "claimCount": 5
  },
  {
   "url": "https://arxiv.org/abs/2004.09468",
   "quality": "primary",
   "angle": "game-theoretic league design on small compute",
   "claimCount": 5
  },
  {
   "url": "https://arxiv.org/abs/1806.02643",
   "quality": "primary",
   "angle": "game-theoretic league design on small compute",
   "claimCount": 5
  },
  {
   "url": "https://proceedings.neurips.cc/paper/2020/file/e9bcd1b063077573285ae1a41025f5dc-Paper.pdf",
   "quality": "primary",
   "angle": "game-theoretic league design on small compute",
   "claimCount": 5
  },
  {
   "url": "https://arxiv.org/abs/1604.00772",
   "quality": "primary",
   "angle": "black-box optimization budgets for expensive evaluations",
   "claimCount": 5
  },
  {
   "url": "https://www.chessprogramming.org/Stockfish's_Tuning_Method",
   "quality": "secondary",
   "angle": "black-box optimization budgets for expensive evaluations",
   "claimCount": 5
  },
  {
   "url": "http://www.cmap.polytechnique.fr/~nikolaus.hansen/ws1p34.pdf",
   "quality": "primary",
   "angle": "black-box optimization budgets for expensive evaluations",
   "claimCount": 5
  },
  {
   "url": "https://arxiv.org/pdf/2606.06555",
   "quality": "primary",
   "angle": "black-box optimization budgets for expensive evaluations",
   "claimCount": 5
  },
  {
   "url": "https://arxiv.org/pdf/1705.01080",
   "quality": "primary",
   "angle": "black-box optimization budgets for expensive evaluations",
   "claimCount": 5
  },
  {
   "url": "https://official-stockfish.github.io/docs/fishtest-wiki/Fishtest-Mathematics.html",
   "quality": "primary",
   "angle": "black-box optimization budgets for expensive evaluations",
   "claimCount": 5
  },
  {
   "url": "https://arxiv.org/abs/1603.03795",
   "quality": "primary",
   "angle": "practitioner/production tuning case studies",
   "claimCount": 5
  },
  {
   "url": 
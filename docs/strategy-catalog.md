# Strategy-node catalog

A battery of strategy and tactic concepts for the bot architecture, swept
from classical doctrine (Sun Tzu, Clausewitz, Boyd), RTS bot literature
(StarCraft: Brood War / SC2 bot ladders, where most published game-bot
strategy work lives), 4X AI (Civilization, AI War, Stellaris), and general
game theory — each mapped to what Tetrarchy Falls' engine can actually
express. Written 2026-07-05 so we stop inventing nodes one frustration at a
time; this is also the seed curriculum for the LLM-mutation loop
(game-ai-v2.md roadmap §3), whose job is to keep extending it from
telemetry.

**Node types**: `consideration` (candidate scorer in the targeting
library), `reaction` (threat signal × gene multiplier), `gene` (scalar/
threshold), `stage` (pipeline step), `campaign` (reserved multi-asset
operation, roadmap §5), `blueprint` (fleet composition), `fitness`
(evaluation shaping). **Status**: ✅ expressible today · 🔧 needs a small
sensor/plumbing addition · 🏗 needs the campaign layer · ❌ engine can't
express.

## A. Economy & tempo

1. **Opening book** (SC:BW bots; chess) — fixed early build sequences that
   are provably efficient, searched as a unit rather than move-by-move.
   TF: purchase weights already encode an implicit opening; an explicit
   opening = a short ordered list gene ("first 6 purchases") bypassing
   utility scoring, evolution picks WHICH book. `gene` 🔧
2. **Timing window** (SC) — attack exactly when your tech/fleet spike lands
   and theirs hasn't. TF: fleet_readiness is a crude form; a true version
   triggers employment when own-fleet-power/enemy-visible-power ratio
   peaks. Needs enemy fleet visibility sensor. `reaction` 🔧
3. **Powering vs teching** (SC) — spend on economy now vs unlock better
   units. TF: already the patents-vs-buildings weight tension. ✅
4. **Worker saturation curve** (SC macro) — know when a base is "full" and
   expansion beats reinvestment. TF: system_strength/tile exhaustion as a
   colonize-trigger consideration ("my empire is saturated"). `reaction` 🔧
5. **Tempo theft / harassment economics** (BW mutalisk harass) — cheap
   attacks whose value is the opponent's ATTENTION and rebuild cost, not
   kills. TF: raids already damage buildings; the missing half is fitness
   credit for enemy time-loss — partially captured via VP margin. ✅
6. **Float discipline** (all RTS bots) — unspent resources = dead tempo.
   TF: credit_floor/hire_reserve exist; an "overfloat penalty" reaction
   (floor greatly exceeded → boost spending weights) closes the loop.
   `reaction` 🔧
7. **Snowball denial** (MOBA bots) — deny the leader's compounding
   advantage early. TF: `leader_target` consideration exists ✅; a
   dedicated reaction (enemy VP velocity > mine → aggression up) is 🔧.

## B. Information warfare

8. **Scouting cadence** (every SC bot) — periodic cheap intel sweeps; never
   fight blind. TF: Erased/explorer passes; a `stage` that keeps one cheap
   agent circulating for contacts (visibility ≥1) rather than
   VP-infiltrating. `stage` 🔧
9. **The five agents** (Sun Tzu XIII) — local, inward, converted, doomed,
   surviving spies. TF mapping is startlingly direct: infiltrators
   (local), governors-of-flipped-dominions (inward), CONVERTED enemy
   agents via seduction ✅ (conversion literally implements this), feints
   via visible fleet movement (doomed) 🏗, retreating scouts (surviving) ✅.
10. **Counterintelligence doctrine** (Sun Tzu XIII; modern CI) — hunting
    enemy agents beats absorbing their effects. TF: assassination/
    conversion hunts + counterintel buildings + the two-phase shadow
    reaction. ✅ (this session)
11. **Intel-before-strike** — never commit a campaign without visibility ≥3
    on the target. TF: instability consideration is the first use;
    campaign preconditions should require it. `campaign` 🏗
12. **Denial of scouting** — kill/expel enemy eyes before your own buildup.
    TF: hunt weights already do this incidentally; a reaction ("enemy
    visibility on MY systems rising → hunts up") makes it deliberate — the
    defensive mirror of #10, sensor = own systems' contact levels as seen
    by... engine tracks per-faction contacts; own-infiltration-suffered is
    visible via own systems' visibility values. `reaction` 🔧
13. **Sandbagging / track concealment** (poker slow-play) — hold the
    visibility track BELOW stage 2 (the reaction threshold humans and now
    bots watch) until a coordinated burst crosses two stages at once.
    ✅ shipped 2026-07-05 — `sandbag` gene holds infiltration at 85% of the next milestone until >= 3 Erased sit idle, then crosses in one burst.

## C. Military operations

14. **Force concentration** (Lanchester; Clausewitz Schwerpunkt) — one big
    fleet beats two half fleets superlinearly. TF: army_size/investment
    genes exist; employment currently spends fleets independently — a
    "mass before moving" gene (readiness ≈ 1.0) approximates; true
    concentration = multi-fleet rendezvous. `gene` ✅ / rendezvous 🏗
15. **Harassment doctrine** (BW) — continuous low-cost raids on undefended
    infrastructure. TF: raid + development/population targeting. ✅
16. **Containment** (BW) — park force on the enemy's expansion path;
    fight their reinforcements, not their base. TF: defend-move to
    CHOKEPOINT systems (lane-graph articulation points) adjacent to enemy
    territory. Needs a `chokepoint` consideration (graph betweenness on
    galaxy.edges — computable, cheap). `consideration` 🔧
17. **Defense in depth vs forward defense** — garrison interior vs border.
    TF: defend targeting currently scores population; `border` consideration (fraction of lane-neighbors enemy-held). ✅ (2026-07-05)
18. **Mobile defense / interior lines** (Napoleonic) — central reserve
    reaching any front fast. TF: defend-move to the graph-centroid of own
    territory; `centrality` consideration. `consideration` 🔧
19. **Decapitation raid** — hit the CAPITAL/production hub, not the
    nearest system. TF: galaxy summaries lack capital flag; system score
    (body count) proxies development ✅; a true `is_capital` sensor 🔧.
20. **Attrition vs annihilation** (Delbrück) — grind their economy vs
    destroy their fleet. TF: raid-vs-intercept blueprint choice +
    targeting; expressible as posture already. ✅
21. **Retreat discipline / force preservation** (every good bot) — a fleet
    at 30% hull retreating to repair beats dying. TF: engine has repair
    mechanics; recall stage shipped 2026-07-05 — a fleet under `fleet_retreat_hp` surviving-unit fraction goes home before employment can spend it. ✅
22. **Timing attack on reaction lag** (SC all-in) — strike during the
    window between enemy tech commitment and its payoff. Needs enemy
    build visibility. 🔧 (sensor) / partially 🏗
23. **Feint / demonstration** (Sun Tzu I: "appear where you are not") —
    visible fleet movement drawing defense to the wrong system, real blow
    lands elsewhere. TF: fleets ARE radar-visible while moving, so the
    physics exist; needs campaign layer to coordinate the two forces. 🏗
24. **Escort doctrine** — covert/colonist convoys under fleet protection.
    TF: characters travel independently; co-movement needs campaign
    choreography. 🏗
25. **Siege relief** — when own system is besieged, converge forces.
    TF: siege state is visible on own systems ✅; shipped 2026-07-05 — `r_siege_defense` spikes w_defend during sieges and defense targeting triages besieged systems first. ✅

## D. Covert operations

26. **Infiltration economy** (this meta) — visibility VP as the primary
    win engine. ✅ (the incumbent champion strategy)
27. **Cover-life accounting** — an Erased's expected VP before discovery;
    rotate them out (home cooldown) before cover breaks. TF: cover value
    is on the character; a gene thresholding "come home at cover < X".
    `gene` 🔧
28. **Assassination priority** — kill the agent whose LOSS costs most
    (high level, mid-mission). TF: hunts target nearest; blip/system data
    could carry level. `consideration` 🔧
29. **Seduction ROI** (this session) — converting a leveled enemy agent =
    two-agent swing cheaper than training one. ✅
30. **Destabilization stacking** (Earthquaker) — multi-Siderian
    happiness dogpile below zero. ✅ (covert_focus)
31. **Sabotage** (engine has it, policy doesn't) — infrastructure attack
    without a fleet. `stage` 🔧 — known gap, payload verified.
32. **Dominion theft chains** (squeeze-flip) — propaganda-capture of
    neutrals as VP + forward bases. ✅ (make_dominion + flip cycling)

## E. Position & map control

33. **Chokepoint control** (BW walling; AoE) — the lane graph has
    articulation points; holding them partitions the map. `consideration`
    (graph betweenness) 🔧 — feeds #16, #17.
34. **Buffer states** — keep neutral systems between you and the enemy
    unconquered as shock absorbers; colonize AROUND rather than toward.
    TF: colonize targeting with a negative `border` weight. 🔧 (same
    sensor as #17)
35. **Denial expansion** (Civ forward-settling) — take a system BECAUSE
    the enemy needs it (their expansion path), not because it's good.
    `consideration` ("enemy_reach" — distance from THEIR homeland) 🔧
36. **Sector-set victory math** — sector VP is won by system majority per
    sector; taking the CHEAPEST system that flips a sector majority is
    worth more than a better system elsewhere. `consideration` ✅ shipped 2026-07-05 (plurality math per the engine's sector rule: 1.0 = capture flips the sector to me, 0.4 = strips the current leader).
37. **Interior consolidation** (turtle) — fewer, denser, defended systems.
    ✅ (expansion weights low + defense buildings + defend stage)

## F. Victory-track play

38. **Track racing** — pick the track with least interference and commit.
    ✅ (focus genes express commitment; fitness rewards it)
39. **Track denial** — the -5-VP stage knockdown via counterintel. ✅
    (this session — burst/sustain reaction)
40. **Track switching** — abandon a contested track mid-game when the
    marginal VP gets expensive. Needs own-track-velocity sensor.
    `reaction` 🔧
41. **Dual-track ambiguity** — keep two tracks live so the opponent's
    reaction investment splits. Emergent from middling focus genes ✅;
    deliberate version needs #40's sensor.
42. **Closing sprint** — when ut_time_left is low and you lead, convert
    everything to VP-now actions (flips, infiltration bursts); when you
    trail, gamble. TF: time is in view.victory ✅; ✅ shipped 2026-07-05 — `r_sprint_lead` (VP-now plays) / `r_sprint_trail` (gambles) fire in the last ~20% of the clock by score differential.

## G. Grand-strategy postures

43. **Rush / boom / turtle triangle** (RTS folk theorem) — the RPS of
    macro postures. ✅ (focus genes span it; niches preserve all three)
44. **Fabian strategy** — refuse engagement, trade space for time, win on
    tracks while the aggressor overextends. ✅ expressible (flee stance +
    covert focus) — has arguably ALREADY evolved as the covert meta.
45. **Decapitation opening** (cheese) — all-in early aggression before
    economies diverge. Pirate seed probes this. ✅
46. **War of attrition with sanctuary** (AI War's core loop) — strike
    from untakeable positions. TF has no untakeable systems; nearest
    analog is dominion-backed raiding. Partial ✅.
47. **Commitment signaling** (game theory) — visible irreversible
    investment deterring attack. TF: defense buildings are visible at
    vis ≥1? If so, turtling IS a signal; no bot reads it yet.
    `consideration` 🔧
48. **OODA-loop tempo** (Boyd) — react faster than the enemy re-plans.
    TF: bots re-plan every 250ms uniformly; tempo advantage would come
    from ACTING on reactions faster (burst genes already shortcut
    deliberation). Mostly ✅ structurally.

## H. Coordination (campaign-layer material, roadmap §5)

49. **Combined-arms conquest** (user's motivating case) — destab to drop
    defense → agent screen → invasion column. 🏗
50. **Sequenced softening** — raid the same system repeatedly until
    defense < threshold, THEN conquest. Expressible WITHOUT full
    campaigns: conquest consideration reading `instability`/damage.
    Partial 🔧
51. **Convoy escort** — see #24. 🏗
52. **Theater rotation** — healthy post-campaign force immediately
    re-tasked (user's re-reservation note). 🏗
53. **Economy of force** (Clausewitz) — minimum assets on secondary
    theaters, maximum at the Schwerpunkt. This is the campaign layer's
    resource-ledger discipline. 🏗

## Priority recommendation

Highest value-per-effort, given current data: **#36 sector_swing**, **#21
retreat/recall stage**, **#25 siege reaction**, **#42 closing sprint**,
**#13 sandbagging**, **#12 scouting-suffered reaction** — all 🔧-class
(days, not weeks), all attack observed blind spots rather than
hypothetical ones. The 🏗 items (#49-53, #23-24) all wait on one campaign
layer, which should be built once, after the current injection experiment
reads out.

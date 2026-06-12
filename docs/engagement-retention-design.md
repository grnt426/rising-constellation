# Engagement & retention design notes

Working notes from a design analysis session (June 2026) on two linked
problems: **per-login engagement** (players should always find something
they *want* to do, without fake busywork or forced check-ins) and
**anti-snowball** (runaway teams/players shouldn't make the match feel
decided by week 2). Slow speed — weeks-long, real-time — is the
reference format throughout.

Status legend: **endorsed** = direction agreed; **proposed** = concrete
design awaiting a decision; **open** = needs more thought or data.

---

## Diagnosis

Every loop in the game has the same shape: *move → one big weighted
decision → long wait*. On slow speed: colonization 150 time units,
conquest ~150 scaled by defense ratio, speaker lockouts 60–220 turns,
character-market refresh 200 units, spy cover regen 0.25/tick
(`lib/data/game/content/constant-slow.ex`).

The decisions are good but almost all **durable** — queuing a building
now vs. six hours from now produces nearly the same outcome. Nothing
decays if a login is skipped, so a session offers few choices beyond
"are my timers done." Well-paced async games nest three loops:
per-login (small reactive choices), per-day (queue management — exists),
per-week (conquest arcs, tech trees — exists). The innermost loop is
missing.

Sharper version: **the player who is behind has the fewest timers
running, therefore the fewest reasons to log in** — and the comeback
toolkit (spies, speakers; the cheap-resource asymmetric tools) is
currently the *lowest*-cadence part of the game (speaker lockouts are
the longest cooldowns in the data). That's inverted: cadence should run
inverse to capital intensity.

### Where players are lost

1. **Week 1** — not enough to do. Hardest problem; some of these
   players bounce regardless once they grasp the multi-week format.
2. **Weeks 2–3** — team fell behind too fast, or took early hits from a
   neighbor. Worst in 3+ faction matches. Best retention opportunity.
3. **Late game** — team can't win, or own empire mauled (typically
   Siderian dominion-stealing). Underdog comebacks *have* happened and
   are part of the game's identity; players leave before discovering
   their residual leverage.

---

## Governing principle (endorsed)

> **Decisions must be *available* at login, never *demanded* by
> timers. Absence costs opportunity; it never incurs punishment.**

This kills "staged long actions" (sub-timers with decision points): a
siege stage that resolves mid-sleep-cycle forces players back to the
game to their own detriment (the Neptune's Pride failure mode —
presence itself becomes the winning resource). Any future engagement
mechanic gets tested against this principle.

Corollaries, also endorsed:

- Perishable opportunities must be **emergent** (derived from player
  and sim activity), never spawned quest content.
- Keep choice sets in **threes** — the game's design ethos (three
  agents × three actives × three passives, three resources, faction
  triangle).
- Neutral-faction content serves the **early game only** and must fade
  intrinsically; late game, neutrals are stepping stones. Neutrals must
  never outshine faction-vs-faction play.

---

## Proposal: action stances (endorsed direction)

Long actions carry a chosen **mode** committed at enqueue, switchable
mid-action when the player happens to be online — but never required.
More choices *in the moment*, full long-term planning when away.

Examples (each a triple):

| Agent | Action | Stances |
|---|---|---|
| Navarch | Siege/bombardment | hit-and-run · military targets only · long bombardment |
| Siderian | Dominion campaign | impassioned speech (longer, higher odds) · shock and awe (shorter, lower odds, stability damage on failure) · patient sermon (longest, lowest profile, no loss on failure) |
| Erased | Infiltration | deep cover (slow, minimal cover loss, fewer informers) · smash-and-grab (instant dossier, heavy cover burn) · ghost (reduced effect, near-zero discovery risk) |

The game already contains a stance triple — fleet stances `:defend` /
`:attack_enemies` / `:attack_everyone`
(`lib/game/instance/character/actions/fight.ex`) — so this extends an
existing pattern rather than adding a new system.

Two refinements that keep stances from re-introducing a presence arms
race:

1. **Live switches propagate with delay; pre-set contingencies fire
   instantly.** A mid-action stance switch takes effect after a
   propagation delay (orders crossing the void). At enqueue, each
   action carries **one contingency slot** — "if an enemy fleet enters
   the system, switch to hit-and-run" — which fires immediately when
   triggered (the order was already given). Net effect: *planning is
   strictly better than presence*, which is exactly what a slow
   strategic game should reward, and it is the offline player's
   shield. A Strategist skill or doctrine could grant a second slot
   (progression hook).
2. **Switching restrictions/costs** (frequency limits or resource
   cost) so stance churn isn't free even for the always-online.

---

## Proposal: neutrals as reactive terrain (proposed)

Lore constraint: nothing supports neutral factions *acting*. Balance
constraint: neutrals must not outshine faction play. Both are solved by
the same framing: **neutrals never act with agency — they respond to
faction behavior according to legible rules.** They are the medium
through which factions interact before borders touch, which makes every
neutral mechanic secretly a faction-vs-faction mechanic.

Three loops, one per agent type:

- **Influence (Siderian loop).** Each neutral system tracks
  per-faction influence — moved by speaker actions, escorts, trade,
  raids (negative), proximity. Threshold benefits: trade income,
  recruitment discounts, intel sharing, and at the top *voluntary
  dominion* (drastically cheaper Make Dominion). Influence is
  **relative** — your 60 means nothing against their 80 — so every
  point is contested. Week 1, the neutral belt between factions is the
  first battleground, fought with speakers and credits before fleets
  can reach each other.
- **Convoys (Navarch loop — the week-1 answer).** Neutral populations
  trade; convoys move on visible routes between neutral systems —
  emergent perishables available from day one. Response triple:
  **escort** (credits, influence, XP) · **tax** (tribute; moderate
  credits, small influence hit) · **raid** (big loot, big influence
  loss, neutral drifts toward your enemies). When one player escorts
  what another raids: a small week-1 fleet battle — combat XP,
  formation practice, a debris field — at a scale where losing costs
  little and teaches much.
- **Underworld (Erased loop).** Neutral systems are intel bazaars:
  informers placed there report on *every* faction with presence or
  influence in the system; cover regenerates faster (safehouses).
  Day-one spy gameplay: seed an early-warning network in the neutral
  belt. Counterplay already exists (Cleaner specialization,
  remove-contact).

**Intrinsic fade-out:** neutral count only decreases; convoys, bazaars,
and influence gauges vanish as systems are absorbed. By week 3 the
survivors are border pawns — the stepping stones we want — with no
switch to flip. Balance guards: denominate neutral rewards in things
that matter early and plateau (flat credits, low-level agent XP,
influence), not scaling production; let accumulated influence
**convert at absorption** (faster conquest, less post-conquest unrest)
so early neutral play builds toward mid-game rather than away from it.

---

## Synthesis: the 6th faction's mechanical home

Faction triangle: top = Conquest/Tech/Navarch (Tetrarchy the fanatical
sword, Synelle the prudent shield); left = Shadows/Credit/Erased
(Cardan fanatical, ARK prudent profit); right = Growth/Ideology/
Siderian (Myrmezir fanatical voice — alone in its corner).

The planned 6th faction — quiet conversion through strength of ideas,
"height rather than reach" — finds its identity in the influence
system: Myrmezir converts loudly (speaker present, dominion by force of
voice); the 6th converts by gravity — superior influence drift,
influence radiating passively from their systems, and uniquely,
neutrals crossing the voluntary-dominion threshold *without a speaker
present*. Pair structure completes: sword/shield, zeal/profit,
voice/idea.

**Sequencing argument:** build the neutral influence layer first as a
faction-agnostic system that improves week 1 for everyone; the 6th
faction then becomes a tuning exercise on proven mechanics instead of
shipping with an untested system on its back.

---

## Other engagement proposals (proposed)

- **Intel as a harvestable, decaying resource.** Infiltration already
  drops 0–2 informers. Let networks accumulate dossiers (capped) with a
  push-your-luck collection choice: harvest now (small, safe) or let it
  ripen (bigger, but a counter-intel sweep wipes it). Dossiers spend
  three ways: reveal an enemy fleet's composition (feeds the formation
  game), boost a sabotage/assassination roll, or feed the visibility VP
  track. Defender mirror: active CI sweeps — choose which systems to
  sweep this login.
- **Between-battles tactical layer for Navarchs.** Combat already
  resolves in waves (6 rows of 3, released turns 1/3/5), so line
  ordering is a real tactical variable the sim already respects —
  expose it. Post-battle report → re-rig formation against known enemy
  composition → set fleet posture (aggressive/balanced/evasive).
- **Emergent perishables from combat.** Battles leave **debris fields**
  (decaying salvage, claimable by any Navarch — scavengers can collide);
  large raids displace **refugee convoys** (intercept for population,
  escort for happiness/ideology); failed dominion attempts leave
  **unrest** any speaker can fan or quell. All zero-sum, time-limited,
  authored by players. Scales naturally with the weeks-2–3 activity
  curve.

---

## Anti-snowball

- **Concrete finding:** slow-speed patent/doctrine cost escalation is
  **0.05** per unlock vs 0.2 (fast) and 0.3 (medium) —
  `constant-slow.ex:28-29`. The main compounding brake is nearly
  disabled in the format where snowballing matters most. Verify this
  was chosen, not inherited; cheap to test, worth testing first.
- **Track-mirrored backlash** (fits the threes ethos): each victory
  track, as a faction climbs it, opens a vulnerability exploitable by
  the matching agent type of trailing factions — conquest leader →
  partisan unrest in recently conquered systems (enemy *speakers* get
  encourage-hate/dominion bonuses there); population leader → big
  populations are spy playgrounds (enemy *Erased* infiltrate more
  easily, richer informer drops); visibility leader → their intel
  apparatus is exposed (their spies easier to discover, CI against them
  cheaper). Principle: **anti-snowball as opportunity for the
  trailing players, not a tax on the leader** — taxes feel bad and give
  losers nothing to do; backlash converts leader success into underdog
  engagement.
- **Raid/loot yields scale with target stockpile** — the leader becomes
  the juiciest target; with debris fields, even a losing battle against
  the leader's expensive fleet leaves profitable salvage.
- The visibility VP track is already quietly anti-snowball (leader has
  the most intel surface area); weighting intel on the VP-leading
  faction higher would sharpen it.
- **Avoid** heavy rubber-banding (production penalties, score-scaled
  costs beyond the escalation fix): in a team game with fog, erasing
  earned leads reads as unfair; coalition pressure plus
  harassment-profitability is usually enough.

---

## Late-game retention

A doomed faction's spies and speakers remain fully operational when its
fleets are gone, and three-track scoring means they can still decide
who wins (unrest on the conquest leader, intel feeding visibility).
Kingmaking is intrinsic motivation that survives elimination from
contention. The mechanics already permit it; the gap is **legibility** —
players can't feel their residual leverage, so they leave before
discovering it. Cheap fix: faction-level outcome notifications ("your
sabotage campaign cost Tetrarchy the Kessari sector").

---

## Existing evidence that perishability works

The character market is the one existing perishable system and it is
genuinely contested: hour-1 hiring rushes, faction-mates pooling
resources to deny enemy factions strong agents (every strong agent an
enemy takes is likely used against you later), occasional accidental
intra-faction sniping. The playerbase responds to perishable, contested
resources — the proposals above extend that proof point.

---

## Open questions

- Stance propagation delay: what duration at slow speed lands between
  "twitch advantage" and "why bother switching"? Likely hours, scaled
  by `speed.factor`.
- Contingency triggers: which condition set is expressive enough
  without becoming a programming language? Start with "enemy fleet
  enters system," "system defense changes," "cover drops below X"?
- Influence model: per-faction scalar per neutral system vs. drift
  toward triangle corners? Scalar is simpler and faction-count-agnostic
  (matches run 2–5 factions).
- Convoy economy sizing: rewards must beat idling in week 1 and lose to
  faction warfare by week 3 — needs a curve, not a constant.
- Does the 0.05 slow escalation constant get raised, or replaced by
  per-track escalation?

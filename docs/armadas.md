# Armadas — implementation analysis & design proposal

Status: pre-implementation design.
Source: player-facing proposal (2026-08-03) + codebase survey.
Scope: grouping 2-3 of one player's Navarchs into an "Armada" that travels
and arrives as one unit; owner-only visuals; naming.

This document covers four things:

1. What the codebase already provides, and where the defender advantage
   actually lives in code (it is not where the proposal assumes).
2. A proposed architecture that is smaller than the feature sounds: an
   embedded state map, an order-redirect rule, and attached transit (the
   lead moves; members ride) with atomic arrival. The fight engine itself
   needs no changes.
3. UI/UX notes grounded in the two system-view implementations and the
   three.js map.
4. A naming proposal that answers the open question in the source doc.

---

## 1. What the codebase already provides

| Need | Existing substrate | Where |
|---|---|---|
| N-vs-M battles | `Fight.Manager.fight/2` takes plain lists per side; armies stay distinct (`Fight.Army.id` = character id) | lib/game/fight/manager.ex:22-53, lib/game/fight/army.ex:8-16 |
| Multi-army stagger | `order_armies/1` sorts by experience and assigns `delay: index * 2` per side | lib/game/fight/manager.ex:58-69 |
| Same-side joining | `fetch_admirals_in_system/3`: same faction, `action_status == :idle`, reaction in `[:defend, :attack_enemies, :attack_everyone]` | lib/game/instance/character/actions/fight.ex:42-58, 351-365 |
| Arrival interception | `Jump.arrival_interception/2` → `Fight.check_interception/3`, reaction list from `Jump.interception_reactions/1` | lib/game/instance/character/actions/jump.ex:137-154, fight.ex:158-212 |
| Uniform travel time | `travel_time = distance * character_movement_factor`; no per-army speed stat anywhere | lib/game/instance/character/actions/jump.ex:29 |
| Single-writer per player | All order entry goes through the owning `Player.Agent` (`{:add_character_actions, ...}` with ownership check) | lib/game/instance/player/agent.ex:751-764 |
| One-besieger rule | `StellarSystem.siege.besieger_id` (one integer), guarded in conquest/raid/loot `start` | lib/game/instance/stellar_system/siege.ex:8-13, actions/conquest.ex:56 |
| Per-viewer visibility | `obfuscate` ladders on system/faction character payloads; radar blips sanitized per recipient | lib/game/instance/stellar_system/character.ex:38-59, lib/game/instance/faction/character.ex:73-136 |
| Snapshot-tolerant fields | `default:`/`enforce: false` + `Map.get` idiom, documented in Victory and Fight.Ship | lib/game/instance/victory/victory.ex:25-28, lib/game/fight/ship.ex:252-257 |
| Test harness | `fleet_scenario.ex` (784 lines) + interception/engagement scenario suites | test/support/fleet_scenario.ex |
| Name pools | `Data.Picker` registry; with-replacement draws (characters, capital ships) and seeded-unique dealing (systems) | lib/data/picker.ex:2-20, 83-107 |

What does not exist at all:

- **Any grouping primitive between characters.** No escort, convoy, or
  follow; `docs/engagement-retention-design.md:164-177` proposes convoys
  but nothing is built. Armadas would be the first.
- **A shared clock.** Each character is its own `Core.TickServer` with an
  independent tick schedule; there is no rendezvous machinery.
- **Batched arrival.** Each `Jump.finish` runs its own interception pass;
  two admirals sent together arrive on separate ticks and fight separate
  battles.
- **Fleet or armada names.** A fleet is identified by its admiral's name;
  `Character.Army` has no name field.

### 1.1 Where the defender advantage actually lives

The proposal frames the asymmetry as structural. It is not;
`Actions.Fight.start/2` builds both sides through the identical
`fetch_admirals_in_system/3` call. The asymmetry is emergent, from two
filters:

1. Joiners must be `action_status == :idle` (fight.ex:363). A parked
   defender is idle by definition; an attacker's companions are `:moving`
   mid-jump or `:raid`/`:conquest` mid-action, so they never qualify.
2. Interception is evaluated once per arrival. Each co-arriving attacker
   triggers its own `check_interception` on its own tick, so the defenders
   fight them serially, at full strength each time.

This is good news: the fix is not a combat-engine change, it is an arrival
scheduling change. Everything downstream (multi-army sides, delay stagger,
per-character fight callbacks, XP, death handling) already works.

The proposal's screen-fleet scenario half-works today: once an armada is
*in* a system, a member starting a conquest gets joined by its idle
co-faction companions through the existing intervention path. Only the
arrival case is broken.

---

## 2. Locked decisions, annotated

The source proposal locks these; each lands well against the code:

- **Same player only.** This is the single biggest simplifier: the owning
  `Player.Agent` is already the serialization point for every order a
  player issues, so armada state has a natural single writer with no
  cross-player coordination.
- **2-3 members, no count limit, free to form/break.** Pure validation
  rules; no timers, no cost plumbing.
- **No travel malus.** There is nothing to penalize anyway; travel time is
  a flat per-instance constant, which also means members never drift apart
  in transit. Lockstep is free.
- **Stances unchanged.** The stance system composes cleanly with armadas
  (see 3.4); the fury-screen-plus-prudent-bomber pattern falls out of
  existing semantics.
- **Owner-only visuals.** Already the architecture: galaxy-map triangles
  are built exclusively from `player.characters` (character.js:126), and
  everyone else sees anonymized radar blips with ids stripped server-side.

On the mind-games point: an armada in transit is **one radar blip**,
indistinguishable from a lone Navarch; per the design intent, and by
construction rather than by filtering (3.4). The inversion is worth
stating plainly: three fleets sent in rapid succession still show three
blips, so enemies *can* distinguish "armada" from "three fleets flying
close"; what they cannot distinguish is an armada from a single fleet,
which is the stronger bluff. Every blip on the map might be three
Navarchs. An enemy watching a system can still infer an armada by seeing
three Navarchs vanish as one blip departs; that reveal is inherent to any
design where formation happens in public view, and no client payload
exists from which a modified client could recover the member count.

---

## 3. Proposed architecture

### 3.1 State: an embedded map, not a new agent

Armada state lives on each member's `%Character{}` as one new field:

```elixir
# lib/game/instance/character/character.ex
field(:armada, nil | map(), default: nil, enforce: false)

# shape (plain map, snapshot-friendly):
%{id: integer, name: String.t(), member_ids: [integer], lead_id: integer}
```

- `id` is the forming character's id at creation, immutable until
  dissolution; it exists only for UI keying.
- `lead_id` names the member that embodies the armada's motion (3.3); it
  starts as the forming character and promotes to the lowest surviving
  member id if the lead detaches.
- The map is duplicated across members and kept in sync by the single
  writer (3.2). Duplication is acceptable at 2-3 copies with one writer;
  it buys us zero new processes, zero snapshot-module changes, and crash
  recovery for free.
- Reads go through `Map.get(state, :armada)` per the snapshot idiom
  (victory.ex:25-28 has the canonical "pre-field snapshot" comment). The
  field is a plain map, not a `Core.Value`, so `compute_bonus/1`'s
  Enumerable sweep leaves it alone. The only new atoms (`:armada` and the
  map keys) appear as literals in loaded modules, satisfying
  `Util.Storage`'s safe-decode.

A dedicated Armada process was considered and rejected for v1: it would
need `@snapshot_allowed_modules` membership, tick exemptions, and its own
wedge-failure modes (see the News.Server incident) for no truth the
lead's ordinary character state does not already hold. Section 3.4
develops this against the specific variant of an armada that moves as its
own entity for crash-recovery purposes.

### 3.2 Formation, joining, breaking

Three new player-channel events beside `deactivate_character`
(player_channel.ex:261): `form_armada`, `join_armada`, `break_armada`.
All are handled in `Player.Agent`, which owns every member.

Validation (all-or-nothing, checked at handle time):

- all characters owned by the caller, type `:admiral`, status `:on_board`
- all in the same system, `action_status == :idle`, not `on_strike`
- resulting size 2 or 3 (`join_armada` on a full armada returns the error
  the greyed button displays)
- a character can belong to at most one armada

On success the Player.Agent casts the updated armada map to each member's
`Character.Agent` and refreshes its own character cache (the existing
`{:update_character, ...}` path; note the cancel-ship desync incident —
every armada mutation must send it). Break clears the field on all
members. No cost, no timer, no news event in v1.

Formation across systems (the proposal's "or anywhere else" case) is
deferred: v1 requires co-location. The natural sugar later is the existing
itinerary-prepend used by `map:addAction` (map.js:771-815): click a
distant own Navarch, get travel-then-form enqueued. Not needed to ship.

### 3.3 Movement: the lead moves, members ride attached

Rule: **exactly one member executes movement.** Any movement order
addressed to any armada member is redirected to the lead by the
Player.Agent, which already intercepts every order a player issues
(`{:add_character_actions, ...}`, agent.ex:751-764). Non-movement actions
(conquest, raid, loot, colonize) stay individual, exactly as today.

When the lead starts a jump, its start hook detaches the other members
from the system the way `leave_system` does today (releasing any siege
they hold, dropping them from the system's character list) and parks them
in a new `:attached` action_status with `system: nil` and an empty queue.
An attached member has no motion state at all: no `started_at`, no
`virtual_position`, no spatial-index entry. Motion state that does not
exist cannot desynchronize; this is the whole fault-tolerance argument,
and it is stronger than any synchronization scheme over N movers, because
there is nothing to synchronize.

An earlier draft of this design kept per-member jumps and fanned every
queue mutation to all members with an all-or-nothing validation guard
(`ActionImpl.pre_validate_action/2` swallows failures silently,
action_impl.ex:29-45, so a naive fan-out desyncs a member with no
surfaced error), then repaired arrival skew with a materialization
barrier. Attached transit deletes that machinery wholesale: only the
lead's queue exists, validated through the unmodified single-character
path, and multi-hop queues need no per-hop rendezvous because the group
never separates.

### 3.4 Transit and arrival: one body, atomic materialization

**Transit.** The lead is an ordinary moving character; nothing about its
jump execution changes. The radar consequence falls out for free: blips
are generated per spatial-index entry, each faction's radar tick querying
the index and calling the detected character's `:get_position`
(`Faction.update_detected_object/1`, faction.ex:303-357), and the sole
insertion point into that index is `Jump.start` (jump.ex:47), which
attached members never run. An armada in transit is therefore exactly one
blip; not because a filter collapses N blips into one, but because the
other N-1 objects do not exist anywhere in the game state. This was the
deciding argument against keeping per-member movement and merging blips
at the radar or channel layer: a merge is filter discipline that must be
applied at every surface that ever serializes in-transit characters, and
the one surface someone forgets is precisely the fingerprint a modified
client harvests. Here there is no payload from which member count could
be recovered, hacked client or not.

**Arrival.** The lead's `Jump.finish` materializes every member into the
destination (system, position, `:idle`; synchronous calls from an
orchestrated hook are the normal pattern), then runs the single
interception pass. Arrival is atomic because it is one event on one
timeline: no barrier, no last-arriver detection, no epsilon window, and
no interval in which a picket can engage a partial armada. Multi-hop
queues need nothing special; the group cannot straggle at an intermediate
hop because there is no second timeline to straggle on. Departure is the
mirror image: the lead's `Jump.start` hook detaches members from the
system before the armada leaves (3.3).

Stance semantics for the group arrival: the interception pass uses the
**most aggressive member stance** to pick the reaction list
(`interception_reactions/1`, jump.ex:150-154), and seeds `Fight.start`
with that member as initiator, materialized members joining per their own
stances through the unmodified `fetch_admirals_in_system`. Rationale: the
proposal's core scenario is a prudent bomber escorted by fury screens; if
the lead happened to be the bomber, evaluating the lead's stance would
never let the screens initiate. With most-aggressive semantics the fury
screen leads the charge and the prudent bomber stays out of the battle
unless directly targeted, which is exactly what its stance promises;
Deserter and Prudent members do not join, same as any parked admiral
today. The 50% Deserter escape roll on the *defending* side is untouched;
it already fires once per interception episode, and an armada arrival is
exactly one episode instead of N.

**Crash recovery, and why the armada is not a process.** The proposal of
an Armada entity that moves alongside the agents, holding the canonical
queue so a crashed member can recover it, is answered by attached transit
without the entity:

- A lead that crashes and recovers mid-leg arrives on schedule: in-flight
  `started_at` values are already rebased into the live clock frame on
  restore (character/agent.ex:11-27), and position is derived from
  `started_at` by lerp, not integrated, so recovery rejoins the exact
  timeline.
- A lead restored from a pre-departure snapshot re-runs the leg, and the
  whole armada is late *coherently*; a delay, never a desync, because
  members have no timeline of their own to diverge on.
- A member that recovers stale (believing itself idle in some earlier
  system) is corrected by a small recovery hook: its restored `armada`
  map names the lead, it asks the lead for ground truth and re-attaches;
  if the armada dissolved while it was down, it stays where it is as a
  plain character and the normal detachment path has already shrunk
  `member_ids`. Under single-blip rules this correction has no observable
  artifact for enemies, because attached members were never visible in
  transit to begin with.

The canonical state the entity would hold already exists, replicated
three ways: the lead's ordinary character state, each member's `armada`
map, and the Player.Agent's character cache. A fourth copy in a new
supervised child adds no truth, and it reopens the class of failure this
codebase has already paid for once; a non-TickServer child under the
instance supervisor wedged production by breaking the Manager's
start/stop/snapshot fan-outs (the News.Server incident), and armadas
forming and dissolving at runtime would make it a *dynamic* child, which
multiplies the lifecycle surface. If armadas later grow entity-level
features (armada-wide stances, shared order UI, persistent armada
identity across reforms), that is the moment to revisit a process; v1
should not.

### 3.5 Sieges: no model change

`besieger_id` stays a single integer and all four release paths stay as
they are. An armada does not conquer as a unit; one member runs the siege
action (enlarged icon, unchanged rule), the others sit idle in-system
where the existing intervention path already makes them useful. If the
player orders the armada to jump away mid-siege, the besieging member's
`leave_system` releases the siege exactly as today.

### 3.6 Dissolution and detachment

Detachment removes one member; below 2 members the armada dissolves. With
attached transit, members run no actions and fight no battles while the
armada moves, so every detachment trigger fires either in-system or at
materialization. The complete list:

| Trigger | Handling |
|---|---|
| successful flee roll (`Character.flee/2`, character.ex:345-368) | detach; the fleeing member jumps home alone |
| death in battle (`kill_character/1`, fight.ex:335-349) | detach via the existing fight callback (agent.ex:816-820) |
| bankruptcy strike (forces `:flee`, blocks orders; character.ex:306-315) | in-system: detach immediately; in transit: nothing to interrupt, detach at the next materialization |
| recall/dock (`deactivate_character`) | in-system: detach, then dock; rejected while `:attached` |
| manual "Break from Armada" | new event (3.2); in-system only, rejected while any member holds a siege |
| lead hook failure (orchestrator abort, action_orchestrator/agent.ex:113-117) | the armada halts coherently: the lead idles per existing abort semantics and members materialize at its location; armada intact, the player re-orders |

Detachment is a Player.Agent responsibility since every trigger already
routes through it. If the lead detaches in-system, `lead_id` promotes to
the lowest surviving member id (3.1). Note what is absent from this
table compared to a per-member-movement design: there is no "member
stranded behind the armada" row, because a member cannot be somewhere the
lead is not.

The UI constraint from the proposal ("Break only when no action underway
in-system") is a client-side affordance plus the server-side siege check;
battles resolve synchronously inside a single orchestrated hook, so
"mid-battle" is not a persistent state that needs guarding.

### 3.7 Testing

`test/support/fleet_scenario.ex` plus the interception/engagement scenario
suites are the harness; `Fight.find_hostiles/3` and
`Jump.interception_reactions/1` are already extracted as public seams.
New scenarios: armada arrival vs. single interceptor (one battle, N
attacker armies), mixed-stance arrival (fury screen initiates, prudent
bomber abstains), order redirect (movement queued on a non-lead member
lands on the lead's queue), departure fan-out (a member's siege releases
and system character lists shrink when the armada jumps), multi-hop queue
through a picketed intermediate system (one battle per hop, never a
partial engagement), member flees mid-episode (detach + remainder
coherent), stale-member recovery (re-attach to the live lead; fall back
to plain character when the armada dissolved while it was down),
formation rejection when a candidate is on strike, attached members are
absent from the spatial index and from every system character list. The
`RC.DebugFlags.fleet_interception?/0` structured trace (fight.ex:286-325)
is the diagnostic tool when engagement sets look wrong.

---

## 4. UI/UX notes

### 4.1 Galaxy map: punched triangles are cheap, with two facts to absorb

The triangles are three.js `Sprite`s textured from
`front/public/map/characters/admiral.png` (three-utils.js:113-135), built
only from `player.characters` — owner-only display costs nothing, it is
already the architecture. Two facts reshape the proposal slightly:

1. **Only moving characters get triangles.** Idle admirals render as text
   labels (character.js:307-326). So the punched-hole marker exists only
   in transit; at rest, the system view carries the information. This
   matches where the player actually needs it.
2. Holes should be real alpha holes, not a dark mask: the map shows
   through, which reads better over varied backgrounds. Two options:
   author `admiral_armada2.png`/`admiral_armada3.png` from the existing
   `source.svg` (it is literally an Inkscape 3-sided star), or punch holes
   procedurally via canvas; `icon-textures.js:41-72` is a working
   SVG-to-CanvasTexture precedent. Static assets are simpler; start there.

Attached transit simplifies this view for free: only the lead carries
jump state, so an armada renders as exactly one triangle (the punched
variant) with no overdraw and nothing to deduplicate; members produce no
triangle, no path line, and no label. One required fix remains: the
cached mesh identity check (character.js:265-276) only rebuilds a sprite
when faction or type changes, so a lead whose armada formed or dissolved
between flights would reuse a stale texture; add armada size to that key.
One addition: centering on an attached member (map.js:293-313 re-derives
the lerp from the character's own jump state) must fall back to the
lead's jump state.

### 4.2 System view: design for the fan, degrade for legacy

Two implementations exist (View.vue:140-145 switches on the
`agent_fan_display` beta flag) and every visual here costs double if both
get full treatment. Recommendation: the fan display is the go-forward
surface and gets the full design; legacy gets adjacency ordering and the
badge, no oval.

**Adjacency** is nearly free in both: the fan's `innerAngles` math is
index-driven, so sorting `ownEntries` (Actions.vue:312-315) by armada
groups members automatically; legacy's desktop arc rotates by `nth-child`,
so sorting `systemCharacters` suffices there too.

**The arced oval** (fan only) is an absolutely-positioned
`<svg pointer-events:none>` under `.system-actions`, reusing the same
`orbitStyle` trig for arc endpoints. Two geometry facts from the survey:

1. The ring is an ellipse, not a circle; `.system-content` is ~100px wider
   than tall (main.scss:11-18), and `left`/`top` percentages resolve
   against different axes. The overlay must apply the same anisotropic
   scaling or it will drift from the badges.
2. **A besieging member leaves the inner ring entirely** — `ownEntries`
   excludes the besieger, which is re-slotted onto the *outer* fan at 64px
   (Actions.vue:314, 371-384). No clean arc can span two rings at two
   radii. Recommendation: exempt the besieging member from the oval and
   let the armada badge on its enlarged icon carry the membership signal.
   This contradicts the proposal's "make the oval larger" idea, but the
   proposal assumed the enlarged icon stayed in place; it does not, and
   un-relocating own besiegers is a layout change with blast radius far
   beyond this feature.

Spacing/clickability is preserved automatically: members remain ordinary
`.orbit-item`s at ordinary angular steps; the oval is a background
decoration, not a container.

### 4.3 The armada badge

The system-view icon's level number sits bottom-*right* (actions.scss:
46-60); the level-in-faction-dot-top-right treatment from the proposal is
on the *card* icon (cards.scss:116-129). Both have a free bottom-left
slot, and the card already has a direct precedent there: the `.group`
hotkey badge (cards.scss:132-144). The armada badge mirrors that pattern
in both places, plus two mobile rules (`.mobile-agent-icon`,
`.bubble-icon` in mobile.scss). Content: the member count (2/3), echoing
the punched-hole count on the map triangle.

### 4.4 Buttons

- **Break from Armada**: third `<svgicon>` in `.selection-status-actions`
  beside Center and Recall (selection/View.vue:12-27); zero layout work,
  greyed with tooltip while a member is mid-siege or mid-battle.
- **Form Armada / Join Armada**: the per-agent toolbox (AgentBadge.vue
  action list). The current code returns an empty action list for
  own-vs-own pairs by construction (Actions.vue:275 and its legacy twin at
  ActionsLegacy.vue:373); relax that guard and add an `armada` validator
  to `actionValidation.js`, whose `{status, icon, name, reasons}` shape
  already supports the greyed-out-with-explanation state the proposal
  wants for a full armada. Do **not** route through `map:addAction`;
  formation is a state change, not a queued action, and gets its own
  channel push (3.2).

### 4.5 Visibility: owner-only by construction

Only the player-channel payload (`lib/game/instance/player/character.ex`)
gains the `armada` field. The system and faction character payloads are
untouched, so nothing leaks to anyone; there is no obfuscation work at
all. The owner's system view gets armada data by client-side merge: it
already holds `player.characters`, and system occupants carry ids, so the
fan component looks its own agents up in the roster. (If faction-mates
should eventually see groupings, the `obfuscate` tier machinery at
faction/character.ex:73-136 is the hook; not in v1.)

Every player broadcast already re-fetches the open system and selected
character (websockets.js:196-201), so armada changes propagate to the UI
with no new plumbing. For attached members in transit, the owner's roster
and detail views derive display state client-side: a member with
`action_status: :attached` shows as "with <armada name>, in transit",
with position and countdown taken from the lead's jump state.

---

## 5. Naming

Survey findings, because they change the answer space:

- Agent names are **not unique**: two independent with-replacement draws
  (character.ex:88-116), lastnames from a pool of 20 per culture.
  Collisions are frequent and accepted.
- Capital ships already do exactly what an armada needs: a with-replacement
  draw from a 173-entry evocative pool ("The Redoubtable", "The
  Cataclysm") at creation time (character.ex:397-403, `ship.txt`).
- The seeded-unique machinery (`Data.Picker.unique/3`, systems) exists but
  needs a per-instance used-set to guarantee uniqueness across incremental
  draws; armadas form incrementally, so true uniqueness would require
  state with no natural home once we reject a coordinator agent.

Recommendation: **a dedicated `armada.txt` pool, drawn with replacement at
formation, name freed on dissolution.** Registering it is one entry in
`Data.Picker.index/0` (picker.ex:2-20); path resolution is generic, and
the pool becomes available to the front via the existing `random_name`
endpoint for free. Content: ~200 evocative formation names in the
`ship.txt` register ("The Iron Concord", "The Long Watch"), distinct in
flavor from both personal names and ship names. `ship.fr.old.txt` (173
unregistered legacy entries) is available as seed material to translate.

This meets every stated requirement: stateless, no numbering, no Greek
letters, never colliding with agent names (different pool by
construction), referenceable across factions. It gives up guaranteed
uniqueness; with a 200-name pool and a handful of concurrently live
armadas per instance, collisions will be rarer than the character-name
collisions players already live with, and the seeded draw keeps them
reproducible. If that ever proves annoying, `extend_unique`-style suffix
dealing can be added behind the same key without changing callers.

One hygiene note: the daily-objective key `:fleet_in_being_armada`
(lib/daily/objective.ex:175-176) predates this feature and will pollute
greps; it is a single fleet's upkeep objective, unrelated. Internal naming
here should use `:armada` consistently and leave the objective alone.

---

## 6. Data model summary

One new runtime field: `Character.armada` (nil-defaulted plain map
`%{id, name, member_ids, lead_id}`, duplicated across members,
snapshot-tolerant via `Map.get`). One new `action_status` value,
`:attached`, for members riding with the lead in transit; it appears as a
literal in character.ex so `Util.Storage`'s atom-safe decode accepts
snapshots on both sides of the deploy, and it carries no motion state of
its own. One new name pool: `priv/data/name/armada.txt` plus its
`Data.Picker.index/0` entry. Three new player-channel events:
`form_armada`, `join_armada`, `break_armada`, all handled in
`Player.Agent`. One modified serialization: `player/character.ex` gains
`armada`. No new DB tables, no new agents, no new snapshot modules, no
fight-engine changes, no siege changes.

---

## 7. Phasing

| Phase | Contents | New risk |
|---|---|---|
| 1 — mechanics | `armada` field, form/join/break events + validation, order redirect to the lead, attached transit (`:attached` members, departure/materialization fan-outs), atomic arrival with most-aggressive stance, detachment rules, stale-member recovery hook, scenario tests | Departure/materialization bookkeeping and detachment edge cases; entirely covered by the existing fleet_scenario harness |
| 2 — core UI | Badge (card + system view + mobile), Form/Join/Break buttons + validator, fan adjacency sort, owner payload + client-side merge | Low; every piece has a named precedent |
| 3 — polish | Map triangle variants + mesh identity fix, fan-display oval (ellipse-corrected, besieger-exempt), legacy adjacency sort, `armada.txt` content pass | Cosmetic only; feature is playable without it |

Phase 1 is playable standalone through existing controls plus the three
events; a player with the badge-less build still gets the entire combat
benefit. That ordering also front-loads the only part with real design
risk.

---

## 8. Implemented Phase 1 (2026-08-17, user feedback)

Phase 1 mechanics are built and tested (41 armada tests plus the full
suite green). The user's test-class list amended the combat semantics
of §3; where this section conflicts with §3, this section wins.

### 8.1 Rule deltas

1. **Every member fights.** An armada represented on a battle side
   pulls ALL its members into that side; stance decides join order,
   never participation. Supersedes §3.4's "Deserter and Prudent
   members do not join". A Prudent member joins last of its block.
2. **Join and initiation priority** is Fury → Interdiction → Defender
   → Prudent → Deserter (`Armada.stance_priority/1`), with equal
   stances flipped on a seeded shuffle. The initiation winner's whole
   armada block enters the battle before any other joiner on its side;
   experience is the tiebreak within a stance, no longer the primary
   sort. `Fight.Manager.order_armies` now assigns the reinforcement
   delay by caller order — `Fight.start` orders both sides through
   `Armada.order_battle_side/2`. (Sim.* callers inherit caller-order
   delays; single-fleet sims are unaffected.)
3. **The Deserter stance is forbidden inside an armada** — rejected at
   formation, rejected on stance change (`:armada_flee_stance_forbidden`),
   and bankruptcy no longer forces it onto armada members (on_strike
   already blocks their orders).
4. **The lead is dynamic, not stored.** The first member to enqueue
   any action becomes the lead; every other member's enqueue is
   rejected with `:armada_led_by_other` until the armada is idle
   again. A jump is additionally rejected with
   `:armada_member_docking` while any member is building ships. The
   `lead_id` field of §3.1 is dropped — the lead is derived (the one
   busy member), so there is nothing to keep in sync.
5. **A beaten armada flees together.** The first member to reach its
   `fight_callback(:fleeing)` becomes the flee-lead and enqueues the
   single retreat jump; every later member clears to idle and is
   re-attached by the flee-lead's `Jump.start`. Flee-lead detection is
   stateless (the member whose queue is exactly one pending jump).
   Supersedes §3.6's flee row (detach): defeat no longer splits the
   armada.
6. **A defending armada intercepts with its most aggressive member's
   stance** (one Fury member makes every idle member an interceptor),
   mirroring §3.4's arrival rule on the defense side.

### 8.2 Implementation map

- `lib/game/instance/character/armada.ex` — pure core: membership
  map, validation, stance priorities, `effective_reaction/1`,
  `busy?/1`, `order_battle_side/2`.
- `lib/game/instance/player/armada_impl.ex` — Player.Agent-side
  orchestration: form/join/break, the enqueue and reaction gates,
  detach/dissolve, flee-role detection. Membership applies through
  `{:update_armada}` on the member agents; the player cache syncs via
  the standard `{:update_character}` cast.
- `lib/game/instance/character/character.ex` — `:armada` field
  (nil default, Map.get/Map.put discipline), cleared on deactivation;
  strike no longer forces `:flee` onto members.
- `lib/game/instance/character/agent.ex` — `{:update_armada}`,
  `{:armada_attach}`, `{:armada_materialize}`, `:armada_clear_to_idle`.
- `lib/game/instance/character/actions/jump.ex` — attach fan-out in
  `start/2`, materialization + effective-stance interception in
  `finish/2`.
- `lib/game/instance/character/actions/fight.ex` — armada expansion of
  both sides, `order_battle_side` ordering, effective reaction in
  `find_hostiles`, stance-ordered + seeded-flip hostile ordering.
- `lib/game/fight/manager.ex` — `order_armies` preserves caller order.
- `lib/game/instance/player/agent.ex` — form/join/break handlers,
  gates wired into `add_character_actions`/`update_reaction`, detach
  on death/assassination/deactivation, armada-wide flee in
  `fight_callback(:fleeing)`.
- `lib/portal/channels/controllers/player_channel.ex` — `form_armada`,
  `join_armada`, `break_armada` events.
- `lib/game/instance/player/character.ex` — owner-only `armada` field
  in the roster payload.
- `lib/data/picker.ex` + `priv/data/name/armada.txt` — the name pool
  (~250 formation names, with-replacement draw at formation).

### 8.3 Test map

- `test/game/instance/character/armada_test.exs` — pure unit tests:
  priorities, validation, busy predicate, side ordering (classes 1,
  3, 4, 6, 9, 9a at the logic layer).
- `test/game/instance/character/armada_scenarios_test.exs` — the nine
  test classes end-to-end: real Character.Agents for
  form/join/break/detach/gates/flee-roles and the Jump attach/
  materialize fan-outs (with a real per-instance Spatial tree); the
  full `check_interception → Fight.start → Fight.Manager` pipeline
  for the combat classes, with fight_callback ORDER as the join-order
  assertion.
- `test/support/fleet_scenario.ex` extensions — `{:take_random}` on
  FakeRand (with a `:reverse_take_random` knob that flips the
  initiation coin), `push_character` on FakeStellarSystem, FakeFaction
  (drop_explorer), `spawn_real_character`, `spawn_spatial`, and
  FakeCharacter now dies on `:prepare_kill` like production.

Surfaced while testing and FIXED (2026-08-17): in a battle where both
sides end with no ships on the field and no reinforcement,
`do_check_outcome`'s left/right reduce did not halt — the right-side
pass overwrote the verdict and the ATTACKER was declared victorious
over two annihilated sides. The both-defeated case is now an explicit
draw: `victory` stays `:undefined` (the same shape as a max-turn
timeout), every shipless combatant dies, and a combatant whose ships
escaped the field flees. Pinned by
test/game/fight/manager_outcome_test.exs; the armada scenarios assert
callback ids/order, never survival, so they are verdict-agnostic.

Stale-member recovery is implemented as the **attached-state watchdog**
(2026-08-20). An `:attached` member otherwise never ticks; it now wakes
every 3 ut and probes the invariant that some live co-member still
lists it AND is `:moving` (the lead mid-jump). The probe runs in a
spawned process and reports back as an `{:armada_watch_result, _}`
cast — probing synchronously from inside the tick was a mutual-call
stall between two attached members that starved the lead's materialize
calls at arrival (caught by the browser E2E, which is exactly the kind
of interception-adjacent bug it exists to catch). One failed verdict is
forgiven — the attach hook runs milliseconds before the lead's own
`:moving` write lands — and a second consecutive failure triggers
self-recovery: the member materializes into the system at its recorded
position, clears its local membership, and casts
`{:armada_recovered_member, ...}` to its Player.Agent, which mends the
survivors' maps through the normal detach path. Every trigger (and
every membership update skipped over an unreachable member) logs at
warning level tagged `[armada]` — grep production logs for that tag to
find affected players. Armada+gateway support remains explicitly
unfinished (`:armada_no_gateway`).

**Visible formations (2026-08-20, user feedback — supersedes the
owner-only visuals of §2/§4.5):** armada GROUPING is now public in the
system view. `Instance.StellarSystem.Character` carries `armada_id`
(revealed at visibility level 2, alongside the agent's identity), and
`{:update_armada}` refreshes the system's summary copy, so every
viewer sees which visible Navarchs stand in formation — own,
same-faction, and hostile alike. The armada NAME and member map still
ride only the owner's roster payload, and the radar/galaxy surfaces
are unchanged (one blip, one triangle). Case matrix implemented: own
inner-ring bands (fan) / arc bands (legacy); foreign collapsed
clusters wear a capsule when they contain an armada; unfurled cluster
members band together (fan, pixel space); legacy draws one continuous
band from the arc's exact geometry (pivot mid-top, radius
0.402·width + 25, 7° steps), asymmetrically thicker toward the arc's
inner side where no name plates compete. All three surfaces share one
construction: `armadaUtil.capsulePath` — a closed capsule outline
(outer arc, inner arc, rounded caps) filled with a subtle wash and
stroked with a thin bright border, which is what keeps adjacent
armadas distinct. The dev fixture takes `armada_layout`
(%{own/friendly/hostile => [sizes]}) and pre-forms every case through
the real player-agent calls; friendly groups re-register puppet 2 into
the caller's faction.

The count/band visuals were reworked twice on user feedback
(2026-08-20): first the per-Navarch count pips moved to a
formation-owned chip; then the chip was dropped entirely — at 2-3
members the count is visually self-evident, and the capsule alone
carries the grouping. Legacy mobile keeps an accent edge on member
rows; cards keep a glyph-only membership mark (no number).

### 8.4 Implemented Phase 2 UI + E2E (2026-08-20)

- **Badges**: armada member count bottom-left on the system-view agent
  icon (fan `AgentBadge` + legacy desktop/mobile), top-left on the
  roster cards (bottom-left there belongs to the hotkey-group square).
- **Formation arc** (fan display only, per §4.2): one SVG band along
  the inner ring per own armada with 2+ members present —
  `viewBox 0 0 100 100` + `preserveAspectRatio: none` stretches a
  circle arc into the ring's true ellipse, `non-scaling-stroke` keeps
  the band width constant. Armada members are grouped adjacent in the
  fan/legacy orderings (`front/src/utils/armada.js#groupAdjacent`).
- **Form/Join Armada** in the per-agent toolbox for own admiral pairs
  (`actionValidation.armada`, client-side reasons incl. the greyed
  full-armada state); pushes `form_armada`/`join_armada` directly on
  the player channel. **Break from Armada** in the selection panel
  beside Center/Recall, greyed while any member is busy; armada
  name + n/3 line under the status block. en/fr locales incl. every
  server rejection atom and the `:attached` status.
- **Client data**: armada rides ONLY the player roster
  (`player.characters[].armada`); the system view merges by id lookup,
  so foreign viewers can't even be leaked to by accident. The
  `{:update_character}` cast → `player_player` broadcast path keeps
  the roster fresh after every membership change.
- **Gateways** (master-merge interaction): gateway travel has no
  attach fan-out, so armada members are refused gateway actions
  (`:armada_no_gateway`) — support is future work.
- **E2E**: `e2e/tests/armada-flow.spec.js` drives the real SPA +
  server: form (named from the pool) → double-form rejected → join to
  3 → 4th rejected `armada_full` → fan badges + formation arc in the
  DOM → Deserter ban (member rejected, solo allowed) → lead jump with
  member enqueue rejected `armada_led_by_other` → all three
  materialize together at the neighbor system → break → dissolve.
  The dev fixture accepts `own_admirals: N` for the co-located
  navarchs. Run: `pwsh bin/e2e.ps1 -Grep armada`.

---

## 9. Open questions for design

1. **Arrival stance semantics** — is most-aggressive-member the right
   group stance, or should the lead's own stance decide?
   (Recommendation: most-aggressive; a lead-stance rule silently breaks
   the escort scenario the feature exists for whenever the bomber is the
   lead.)
2. **Faction-mate visibility** — strictly owner-only, or should faction
   mates see groupings? (Recommendation: owner-only in v1; it is free, and
   widening later is a payload change, not a redesign.)
3. **Legacy system view parity** — adjacency + badge only, or full oval?
   (Recommendation: adjacency + badge; the legacy layout is pure CSS with
   no geometry to hook, and the fan is the go-forward surface.)
4. **Besieging member and the oval** — exempt from the oval with the badge
   carrying the signal, or re-anchor own besiegers to the inner ring?
   (Recommendation: exempt; un-relocating besiegers has blast radius far
   beyond armadas.)
5. **Beta gating** — ship behind an `armada` account feature flag, or
   straight to everyone? Armadas are opt-in by use and additive, but they
   shift attacker/defender balance for players who never form one.
   (Recommendation: no flag, but announce in the news ticker; a
   per-account UI flag cannot gate a balance change others feel anyway.)
6. **In-transit join/break** — v1 rejects both; is a mid-flight break
   worth supporting later? (Recommendation: revisit only if players ask;
   a departing member would need freshly minted jump state and a radar
   blip appearing from nowhere, for marginal benefit.)

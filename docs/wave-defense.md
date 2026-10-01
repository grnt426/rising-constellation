# Wave Defense ("Rebellion") — design and implementation plan

Status: **planned 2026-09-12; MVP slice built 2026-09-13 (§0).** This document
is the brief for the implementation agents. It is deliberately explicit about file paths, function
names, formulas and the decisions already taken, so each phase in §12 can be
handed to an agent without re-deriving the survey.

Short verdict: **yes, the mode is buildable on what exists.** Three
foundations carry most of the weight:

1. The **Daily Challenge** instance recipe (`Daily.Boot.boot_persisted/2`) —
   real scenario/instance/registration rows, no lobby magic needed.
2. The **SystemAI behavior-tree engine** (`SystemAI`, `SystemAI.Actions`,
   `Instance.SystemAI.Parser`, `priv/data/system_ai/behavior_tree.json`) —
   the decision-tree format the user wants agent scripting encoded in.
3. The **unmerged game-AI branch** `origin/claude/game-ai-bot-training-run-9d05c1`
   (== `origin/claude/relaxed-morse-0d03c9`, head `c29b43f`) — an in-process
   bot driver, an engine-payload adapter, a lane pathfinder, a `bot_faction`
   instance column with registration lock, and an arena-bred fleet
   blueprint table. Master has none of it. It merges into master with only
   two trivial conflicts (`.gitignore`, `lib/game/system_ai/actions.ex`),
   but we port selected files rather than merge the 15.9k-line branch (§2.2).

Everything else — roles, targeting, recruitment, construction, waves — is new
code under `lib/wave/`.

---

## 0. MVP slice (built 2026-09-13)

A deliberately small first slice that proves the load-bearing plumbing before
any combat AI is written. It answers seven questions: can a new faction exist
with a bot as its only member; can a game-time timer initiate actions; can the
bot buy agents and receive ships without construction; can it manage agents
end to end; can limits be bypassed for the bot without leaking to humans; does
a new behavior tree run; and does the bot's territory develop on it.

### What it does

- **The Rebellion is a real faction.** `:rebellion` in `Data.Game.Faction.Content`
  with a `:rebel` culture (name lists alias the stelloliberalism corpus in
  `Data.Picker.index/0` until rebel lists exist), four traditions, an original
  icon (`front/src/icons/faction/rebellion*.js`), colors in
  `front/src/utils/factions.js` (`BOT_FACTIONS`, kept out of the playable
  roster), and en/fr text. The catalog struct gained `playable` (false for the
  Rebellion), and player-facing faction lists such as `RC.ProfileIcons.faction_keys/0`
  filter on it. `Instance.Faction.Government.Rules.module_for/1` gained a
  fallback so an unknown faction can never crash a faction agent.
- **One bot, alone in its faction.** `Wave.Boot.start/1` rewrites a scenario
  (default: the bundled two-sector test map) to Legacy speed and
  `game_mode_type: "wave"`, hands one rival start sector to the Rebellion,
  creates a public late-registration instance with a capacity-1 Rebellion
  faction, registers the shared `is_bot` profile `wave-rebellion@tetrarchyfalls.local`,
  and starts the game. `Portal.RegistrationController.join/2` refuses the
  Rebellion with `:bot_faction_locked` (`Wave.locked_faction?/2`).
- **The Warlord.** `Wave.Warlord.Agent` is a `Core.TickServer` started by
  `Instance.Manager` inside the instance tree (and on the snapshot allow-list),
  ticking every 1 ut. Its pure state and decisions live in `Wave.Warlord`.
  Each pass: marks the bot player connected, tops credit/technology/ideology up
  to floors, and every `hire_interval_ut` (120 ut = 6 real hours at Legacy)
  runs a hire cycle.
- **Hire cycle.** Buys the cheapest one-star (`:common`) Navarch from the
  shared character market with `{:hire_character, id}`, deploys it on-board at
  the capital with `{:activate_character, …}`, and materializes a
  `transport_1` into tile 1 with the character agent's
  `{:order_ship, {nil, 1, :transport_1, nil}}` + `{:put_ship, 1, 0}` — no
  production, credits, patents or shipyard.
- **Agent management.** An idle Navarch carrying a colony ship gets a lane-hop
  itinerary plus a colonization order toward the nearest uninhabited system in
  a takeable sector (owned or adjacent), never a target another coloniser
  holds (`Wave.Nav`, `Wave.Warlord.colonisation_target/4`). Orders are read
  back, because `add_character_actions` answers `:ok` even when validation
  drops them. Once a dispatched Navarch is idle with its ship spent, it is
  recalled with `{:deactivate_character, id}` and dismissed with
  `{:dismiss_character, id}` (dismissal has no deck cooldown). A Navarch that
  can't be recalled because it isn't in owned space is walked home first.
- **Bot-only bypasses.** `Wave.Config.player_bonuses/1` adds +500 systems,
  +500 dominions and +50 of each agent type to the bot player only, through
  `Instance.Player.Player.extract_bonus/2`. `Player.detect_bankruptcy/2`
  ignores the bot faction, so its agents never go on strike.
- **Rebel Dominion tree.** `priv/data/system_ai/behavior_tree_wave.json`,
  generated from the vanilla tree with: upgrade odds 25% (was 50%), a new
  branch `sequence[no_free_tiles?, select[upgrade_any, done]]` so a built-out
  system upgrades instead of terminating, and `upgrade_any` in place of
  `upgrade_random`. `SystemAI.Actions.upgrade_any/1` draws only from upgrades
  the engine accepts (`SystemAI.Helper.get_legal_upgrades/1`), including the
  infrastructure tile, which fixes the level-1 freeze for rebel systems. The
  Rebel Workforce subtree uses `build_housing/1` instead of the vanilla
  `build_workforce/1`, whose body-type filter never matches: without housing
  a young colony used up its workforce and sat idle until population growth
  freed more (a colony paused at ten buildings on the first test game). With
  `build_housing/1` the same colonies raised habitation steadily. Housing
  spam costs stability, so watch happiness when tuning.
- **Five-minute cadence.** `StellarSystem.auto_actions/2` routes through
  `Wave.Config.system_ai/2`: rebellion-held systems **and** dominions run
  `:rebel_dominion` every `ai_interval_ut` (1.667 ut = 5 real minutes);
  everything else is unchanged. `compute_next_tick_interval/1` wakes rebel
  systems for their AI turn. The queue gate (`wait_if_queue_is_busy`) is kept,
  so "no delay" means the next order lands within five minutes of the last
  one finishing.
- **Safety net.** `SystemAI.step/1` now has a 1,000-evaluation budget and
  returns `{:error, :bt_runaway}` instead of hanging a system agent.

### Breakout: Siderian capture, idle-Navarch cap, pass cost (2026-09-15)

**Why.** On the production Citadel map (scenario 145) colonization alone
stalled at 1 of 19 sectors. A sector changes hands only when a faction has
strictly more inhabited systems there than the current holder, and neutral
systems vote as a `nil` faction. Harara's only neighbour, Persiennes, has 3
neutrals and 2 open systems, so colonizing could never take it and the
Rebellion was walled in. The 20 idle colonisers meanwhile retried every pass.

**Siderian capture.** The Warlord keeps up to its daily Siderian ceiling (below),
never more than there are capture targets. The first is hired at once and
each further one after `siderian_hire_interval_ut`. An idle Siderian that
isn't resting after an attempt rolls a sector class (frontier 80, border 15,
internal 5, renormalized over classes that have targets). It then sends a
`make_dominion` itinerary at a neutral system or foreign dominion. Frontier
picks prefer the sector closest to changing hands, then the nearest system.
A captured dominion votes for the Rebellion, which is what breaks the wall.
Outcomes are scored when the Siderian goes idle again.

**Capable Siderians only.** Capture attack is the Siderian's own
`speaker_make_dominion` bonus, and only the proselyte skill grants it (+10 per
point). The Rebellion's +15% tradition and any doctrine just multiply that
base. The first Warlord bought the cheapest speaker on the market, and in the
150× Citadel re-run that meant a scholar and a philosopher: attack 0, six
failed rolls out of six, and no way to recover, because a Siderian slot was
never freed. The Warlord now buys only Siderians with capture strength (the
strongest of the preferred rank, else of any rank, cheaper on ties). When the
market has none it looks again after `siderian_retry_ut` (10), and it recalls
and dismisses any tracked Siderian with no strength.

### Siderians scale with the match (2026-09-15)

**Ceilings scale with the humans.** One bot player faces a whole faction, so
matching the single strongest player undersizes it. `Warlord.agent_ceiling/2`
sets the ceiling for each agent kind to a per-player value for the match day
times the human players in the game, never fewer than `scale_players_min`,
rounded and at least 1. The per-player value is the 62.5th percentile of what
every human player in the four official Legacy matches (i20, i49, i87, i121)
had on board that day. That is the middle of the second-highest quartile,
slightly better than half the players. The curves are held non-decreasing so
the Rebellion only grows, and later days keep the last value. Knobs:
`siderians_per_player_by_day`, `erased_per_player_by_day` and
`navarchs_per_player_by_day`. Match day is elapsed game time over `ut_per_day`
(480 at Legacy speed). The Warlord may hold fewer: Siderians never exceed the
capture targets, and colonisers never exceed 1.5× the open systems in reach.

How the curves were built. On-board counts per player per day were rebuilt
from the replay log (hire, activate, deactivate and dismiss orders),
assassination and conversion events, and battle deaths (`fight` rows mark dead
admirals). Types come from type-only orders and events plus snapshot rosters.
Against nightly snapshots the rebuild was exact for 85–100% of Siderian and
70–91% of Erased player-samples. Navarchs were worse (36–74%): totals agree,
but some Navarchs land on the wrong player, which drags the per-player
quantile down. Their curve takes the higher of the rebuild and i121's
snapshots, which cover every match day of that match. Days after 22 come from
i87 alone.

| Match day | 1 | 2 | 5 | 7 | 12 | 16 | 17 | 19 | 21 | 23 | 26+ |
|---|---|---|---|---|---|---|---|---|---|---|---|
| Siderians per player | 0 | 1 | 1 | 2 | 2 | 2 | 2 | 2 | 2 | 3 | 3 |
| Erased per player | 0 | 0.875 | 2 | 2 | 2.5 | 4 | 4.5 | 5 | 5 | 5 | 5 |
| Navarchs per player | 0 | 1 | 1 | 1 | 1 | 2 | 2.25 | 2.25 | 3.125 | 3.125 | 4 |
| Rebellion vs 15 humans (S / E / N) | 1 / 1 / 1 | 15 / 13 / 15 | 15 / 30 / 15 | 30 / 30 / 15 | 30 / 38 / 15 | 30 / 60 / 30 | 30 / 68 / 34 | 30 / 75 / 34 | 30 / 75 / 47 | 45 / 75 / 47 | 45 / 75 / 60 |
| Whole human faction, match average (S / E / N) | 5 / 5 / 5 | 10 / 8 / 11 | 19 / 22 / 14 | 23 / 26 / 16 | 23 / 52 / 23 | 29 / 73 / 43 | 30 / 76 / 46 | 36 / 90 / 48 | 30 / 100 / 50 | 43 / 104 / 80 | 39 / 106 / 78 |

The Rebellion keeps pace with a whole faction's Siderians. It fields fewer
Erased and Navarchs than the faction later on, because a few heavy players
carry those totals. The median player never had more than 2 Siderians, 5
Erased or 2 Navarchs on board. Test games with a single human set
`scale_players_min` to an official match's size (the Citadel runs use 15).

**Spreading.** A Siderian no longer skips every target another Siderian is
working on. A target with `n` Siderians committed is admitted with probability
`capture_overlap_falloff^n` (0.2): a second Siderian joins a target 20% of the
time, a third 4%, a fourth 0.8%. When nothing else is left, the
least-committed targets are admitted. Admitted targets then go through the
usual sector-class roll and preference order.

**Pace and restraint.** Unchecked (run 4), the Rebellion bordered Citadel's
center sector, Zinavitzan, at day 4.8 and held 14 of 19 sectors by day 8.3.
In i121 the faster human faction, Myrmezir, bordered it at day 9.3. Two rules
slow it down:

- *Sector pace.* It opens new fronts (works frontier sectors) only while it
  holds fewer sectors than `sector_share_by_day` allows, looked up
  `sector_pace_lead_days` (1) ahead because flipping a sector takes time. The
  curve is the leading human faction's share of Citadel's 19 sectors in i121,
  by match day: 1, 1, 2, 2, 3, 3, 4, 5, 5, 6, 7, 8, 8, 8, 8, 9, 10, 11, 11, 11,
  13, 13. From Harara the sixth sector is the first to border the center.
- *Hold margin.* Inside its own sectors it colonizes and captures only while
  its vote lead over the next voter (neutrals included, except on an untouched
  start sector) is below `hold_margin` (2). A comfortably held sector is left
  alone, so humans can still flip it by out-building a thin lead, and a lead
  that humans erode pulls the Rebellion back in.
- *No overshoot.* Every sector, frontier or owned, takes only as many
  colonisations and captures as it still needs to lead by the hold margin
  (`Geometry.sector_need/3`), counting agents already on their way and
  dispatches made earlier in the same pass. Without it, run 5 kept sending
  colonisers at Urnuzi while it was still frontier and ended with 13 rebel
  systems against 2 neutrals.

**Behaviour log.** The Warlord charges game time to each Siderian's observed
state every pass: `moving` (including docking), `acting` (controlling or
destabilizing), `resting` (idle with its cooldown running) and `idle` (waiting
for orders). Attempts are scored `captured`, `failed` (the action ran and the
system didn't turn) or `aborted` (the action never started). Totals appear in
the harness status under `warlord.telemetry`, per Siderian under
`warlord.siderians[id].time_ut`. The same story is written to
`instance_event_log`:

| Kind | Written when | Payload |
|---|---|---|
| `wave_siderian_hired` | a Siderian is bought and deployed | day, strength, level, specialization, roster, cap |
| `wave_siderian_dispatched` | a capture order is accepted | day, class, sector, hops, overlap, from |
| `wave_siderian_started` | the Siderian is seen performing the action | day, target, action, travel_ut |
| `wave_siderian_resolved` | the attempt concludes | outcome, travel_ut, action_ut, total_ut, dispatch info |
| `wave_siderian_released` / `_lost` | dismissed / gone (killed or converted) | day, stage, target, time_ut |
| `wave_daily` | the first pass of each match day | cumulative stats, gauges, Siderian time, systems, dominions |

Read them with `GET /api/harness/wave/:iid/events?kind=…&limit=…` or SQL on
`instance_event_log`.

**Idle-Navarch cap.** Colonisers are capped at `idle_navarch_factor` (1.5)
times the open systems left in reachable sectors, rounded down, under
the Navarch ceiling (see below) and an optional `max_active_colonisers` hard
cap. Hiring stops at the cap, and surplus idle colonisers
are recalled and dismissed. Dispatched ones are never interrupted.

**Pass cost.** `Wave.Geometry` turns one galaxy read into lane adjacency,
owned and reachable sectors, sector classes, ownership deficits and candidate
lists, shared by every decision in the pass. Hop distances are memoized per
source system. Only agents the player roster reports idle get a full state
read, with a full refresh every `state_refresh_passes` (20). A due hire only
triggers a galaxy read when the last reading left room for one. Measured with
`Wave.Profile` on the stalled Citadel game at 200×:

| Measure | Before | After |
|---|---|---|
| Node reductions in 10 s | 157.7 M | 11.2 M |
| Warlord share of node work | 88% | 57% |
| Container CPU | 55–73% | 30–53% |
| Warlord pass cost | not measured | about 3.5 ms |

**Bot player load.** Once the breakout reached ~190 systems, CPU moved to the
Rebellion's player agent: every owned system casts its full state there on
each change, and each apply recomputed bonuses across the whole empire and
re-broadcast the player. Three fixes followed:

- `Instance.Player.SystemUpdateBatch` coalesces a bot player's
  `{:update_system}` / `{:update_dominion}` casts for `system_update_batch_ms`
  (500 wall ms) and `Player.update_systems/3` applies them with one bonus
  recomputation. Human players keep the immediate path.
- Every player-agent broadcast goes through `broadcast_player/2`, which skips
  bot-held players (no client ever subscribes).
- The Warlord's hire clock, held "due" at a full roster, used to shrink the
  tick interval to its 0.05 ut floor — about 20 passes a second at 200×, each
  rebuilding the geometry. A held-due hire now keeps the normal cadence, and a
  hire only counts as pending while the roster is below its last cap.

Same Citadel game at 200×, 5-second samples (the empire grew between runs):

| Reductions in 5 s | Before (194 systems) | Batching + broadcast skip (203) | + held-due fix (219) |
|---|---|---|---|
| Whole node | 30.4 M | 14.2 M | 15.9 M |
| Bot player | 21.4 M | 2.9 M | 6.7 M |
| Star systems | 6.8 M | 6.2 M | 6.0 M |
| Warlord | under 0.4 M | 3.0 M (spinning) | under 0.2 M |

After the last fix the Warlord runs about 1.5 passes a second, and an idle pass
costs about 1,400 reductions. The bot player remains the largest consumer; each
recomputation still does two game-data lookups per bonus across the empire.
Star-system work is the rebel build AI on a 5-minute cadence, and like the rest
it scales with game speed.

### Erased: removal, sabotage, infiltration (2026-09-18)

The Erased are the first role that hunts *people* rather than ground, so they
needed a second kind of sight. `Wave.Recon` builds one hostile reading per
Erased pass — the faction's contacts, one call per human player, then the
systems those agents are standing in, capped — and `Wave.Intel` turns that
into a resolved visibility per system and, from `Core.Dice`, the odds of an
attack. `Wave.Erased` holds the decisions; `Wave.Warlord.Agent` gives the
orders. Deliberately, the Rebellion is held to what it can see: every field an
Erased weighs is gated on the same visibility tier the engine's own obfuscator
uses, so a defence it cannot read arrives as "unknown" rather than as the truth.

**Theatres.** Every Erased rolls a theatre once, at hire: `erased_home_share`
(0.25) stay inside the sectors the Rebellion owns, the rest work outward. The
split is by *sector depth* — `Wave.Geometry` now computes hops through sector
adjacency from the nearest owned sector, so depth 0 is home and 1..`erased_field_depth`
is the field.

| | home (depth 0) | field (depth 1..2) |
|---|---|---|
| Removal | enemy agents standing on rebel ground | enemy agents in enemy sectors |
| Sabotage | fleets operating in rebel space, sieges first | enemy fleets |
| Sabotage floor | 4 filled tiles | 6 filled tiles |
| Infiltration | training only (neutral ground) | enemy systems and dominions |
| Slots per target | 7 | 5 |

**Training and graduation.** A home Erased too green for either attack
(fewer than `erased_home_duty_points` across removal and sabotage) trains by
infiltrating the neutral systems inside rebel borders. It graduates once its
informer skill reaches a target rolled per agent in `erased_train_points`
(3–6), then takes a permanent posting: a roll on `erased_graduate_home_share`
for home removal/sabotage work, anything else to the field. The home half of
that roll is only offered to an agent that has since earned the two points —
otherwise the field takes it whatever it rolled.

**Restraint.** Three rules keep the Erased from piling onto one target.

* *Slots.* At most `erased_target_cap` work a target at once, and each extra
  joins with probability `erased_overlap_falloff^n` (0.35), so a second is
  uncommon and a third rare. Commitments are read off the live roster, so a
  slot frees the moment its holder is removed or seduced away.
* *Odds.* Removal is the one strike thrown away on a single roll, so it is
  gated: an unreadable defence is a flat 20% gamble
  (`erased_removal_gate.unknown`), a readable one runs through a logistic
  centred on an even chance, which is near-certain above 65% and near-zero
  below 35%. In practice that splits cleanly by theatre — the Rebellion always
  sees its own systems at visibility 5, so home removals are calculated, while
  a field removal needs six informers on the target's system before protection
  becomes legible, and is a blind gamble until then.
* *Worth.* Sabotage ignores fleets already broken below the floor, unless the
  fleet carries a colony ship — a colony the Rebellion would rather never
  happen is worth stopping at any size. Ship keys are visibility-4
  information, so the exemption only fires where the Rebellion can read the
  fleet; filled tile counts are public at any visibility
  (`Instance.Character.Tile.obfuscate/2` hides a filled tile's ship, never the
  fact that it is filled).

Two rules the spec calls out by name are enforced in `Wave.Erased`: a
replacement officer (`CMO #…`) is left alone until it has earned a level past
1, and nothing infiltrates a system already resolved at visibility 5, where
another informer buys nothing.

**Scoring a strike.** Infiltration takes game time, so a pass catches it
mid-action. Removal and sabotage resolve inside the tick that starts them and
are never seen running — but every spy action costs cover, and cover only
climbs back on its own, so a drop since the dispatch is proof the strike
happened. Whether a removal *worked* needs its own tell: a Navarch holding a
fleet is not killed outright, the engine rebuilds it as a level-1 CMO under the
same character id (`Instance.Character.Character.replace_agent_with_default/2`),
so the roster diff shows nothing and only the changed name gives it away.

**Two engine facts worth knowing before tuning this.**

* A spy that acts falls out of cover (threshold 75, start 80) and recovers at
  0.25 per ut, so one strike costs roughly 100–150 ut of lying low — five to
  seven real hours at Legacy. That is the game's own spy tempo, not something
  the Warlord chooses, and it is what the `resting` bucket in the telemetry
  measures.
* `Instance.Diplomacy.Agent` only pushes stances to the faction agents on a
  diplomacy *event*, and a two-faction game's opening war is set at genesis
  without one. The `−1` war modifier on enemy visibility is therefore inert in
  a wave game, for the Rebellion and for humans alike. `Wave.Intel.visibility/2`
  mirrors the engine rather than the intent, so if that ever gets seeded the
  Erased will lose a visibility tier in enemy space and field removals will go
  permanently blind.

**Warlord fix that came out of the test.** Activation is refused under siege.
A Rebellion down to one besieged system used to buy an agent it could not
deploy on every pass until the character deck filled — and a full deck refuses
every later hire, long after the siege lifts. `hire_agent/4` now resolves a
deployable home *before* spending, dismisses a card it could not activate, and
both the Siderian and Erased hire clocks defer on any market-stage failure
instead of retrying every pass.

**Driving it.** Beyond the endpoints below, `POST …/place` mints an agent (and
a fleet) for a chosen human player in a chosen system — with a forced level,
skills, specialization or name, so a `CMO #` or a colony ship can be put
exactly where a rule needs proving; `POST …/order` pushes an itinerary for it
(a `raid` on a rebel system lays a real siege); `POST …/informers` hands the
Rebellion the contact an infiltration would have bought; and
`GET …/galaxy?sector=&status=&detail=1` lists system ids with the Rebellion's
contact on each, plus who is standing there. See `Wave.Fixture`.

#### Tuning pass (2026-09-18)

Five decisions from watching the first run, in the user's words where they
settled a question.

1. **The resting is the point.** Spies wait for a good target, and a strike
   blows their cover for a while. No change: the `resting` bucket measuring
   100–150 ut between strikes is the mode working, not stalling.

2. **Removers ride on visibility, never on infiltrators.** Pairing a remover
   with an infiltrator is a fine human play, but wiring it in would tie the
   remover's success to the infiltration's — two failures for the price of
   one. The Erased were already reading only the visibility that exists, but
   there was an accidental version of the same coupling: a rebel agent standing
   in a system is worth visibility 2 *there*, so a remover could cross the map
   for a target it could only see because an infiltrator happened to be parked
   next to it, and lose sight of it the moment that agent moved on.
   `Wave.Recon` now reads each system twice — with and without its own agents —
   and `Erased.committable?/3` lets borrowed sight justify a strike only within
   `erased_transient_hops` (1). Sight from informers keeps, and carries any
   distance.

3. **The war modifier: a correction.** The `−1` is applied *only* when the
   stance map says `:war`, and the default (no entry) is no modifier at all —
   so it is not "always subtracting one". The map is empty here because
   `Diplomacy.Agent.push_stances/2` only fires on a diplomacy event and the
   two-faction opening war is set at genesis without one. So the live
   behaviour is exactly what a player expects: nobody there is 0, an agent
   standing there is 2, and four or so successful infiltrations reach 5 and
   keep it after the agent leaves. Nothing to change — but if that push is
   ever seeded, enemy systems lose a tier and field removals go permanently
   blind, because `protection` needs 5.

4. **The Rebellion can afford anything, so price cannot be the brake.** Market
   rank is now gated by match day (`rank_unlock_days`): one star from the
   start, two from day 5, three from day 8, for every role.
   `Warlord.pick_candidate/3` takes the unlocked ranks and never falls back
   outside them. Training stays rare by design — an agent that can already do
   the work does it — but early agents are now green because that is all the
   market will sell the Rebellion. Note the interaction: a one-star character
   gets one or two randomly-placed skill points, so roughly half of them have
   nothing in the three offensive skills and are refused as `no_candidate`.
   Early Erased are therefore scarce as well as weak, which the day-1 ceiling
   of ~1 per player already wanted.

5. **Roaming.** An Erased with no legal strike no longer stands still: it
   repositions to ground the Rebellion is blind on — dominions first, since
   that is where Navarchs colonise and Siderians push, then held systems, then
   neutral ground — because an agent in a system is worth visibility 2 there,
   and everything it sees feeds the next pass's targeting. It rolls
   `erased_roam_chance` (0.35) per idle pass, so the roster still reads as
   lying in wait rather than milling about, and it holds a slot on its
   destination so roamers spread out. A blown Erased may roam but not strike —
   the walk is free and waiting somewhere blind is worth more than waiting
   somewhere already seen. Roams are move-only itineraries and score nothing
   on arrival (stage `:roaming`, not `:dispatched`).

Verified live: with a rebel agent planted in the enemy capital, four hostiles
there became visible (`hostile_borrowed_sight: 4`) and the field remover
**declined all four** and roamed five hops to blind ground instead — zero
dispatches at that system. Hires on day 1 were all `common`, level 1.

#### Practice and scouting (2026-09-29)

The first live match (instance 185) showed the gap: its only Erased was a
saboteur that rolled field removal, had nobody within reach to remove, and
spent a day walking between two neighbouring neutral systems. The roam rule
picked the nearest system below visibility 2, and the system it had just left
dropped back below 2 the moment it walked out. Duties are still fixed at hire;
what changed is what an agent does when its duty has nothing to strike (user
decisions, 2026-09-29):

1. **Practise while green.** Below `erased_train_max_level` (5) an idle
   Erased trains. Any informer point means infiltration practice: neutral
   systems and other factions' dominions in its theatre. The engine lets a
   zero-point agent infiltrate (the in-game action is never greyed out; only
   Sabotage and Removal are at 0), rolling an attack of 0: about 53% against
   Intelligence 0, a certain failure against anything more, some experience
   either way. Nobody can read a system's Intelligence before infiltrating it,
   so practice goes anywhere until one of our results has reported it (the
   defence in the result report, kept in `erased_intel`); after that a
   known-soft system comes first and one below `erased_train_min_chance`
   (0.25) is skipped. Real field infiltration skips known-hopeless systems too.
2. **The training Navarch.** An agent with sabotage points and no informer
   points sabotages the Rebellion's own Navarch instead, the loop teams run
   between two teammates, when it is within `erased_dummy_max_travel_ut` (480
   ut, a day at Legacy) by lane length × `character_movement_factor`. The
   engine refuses to let a player sabotage its own Navarch; one clause in
   `Instance.Character.Actions.Sabotage.start/2` exempts the bot faction. The
   dummy is the Rebellion's unused starting Navarch card (bought from the
   market only if that is gone), carries no ships (a sabotage roll pays its
   experience whether or not there is a fleet to hit), and is walked to the
   nearest unheld system, because a Navarch in its own faction's system adds
   that system's Intelligence to its defence. Practice is counted apart from
   the strikes (`erased_practice`, `practice_resolved`, `practice_aborted`).
3. **Then scout.** At the level cap, or with nothing to practise on, an idle
   Erased walks to the nearest system the Rebellion has never seen, of any
   kind, within `erased_roam_max_hops`, still at `erased_roam_chance` per idle
   pass. The engine files an explorer contact on every system an agent jumps
   into, and a contact never lapses, so a system seen once stays seen and
   scouts fan out. With everything in reach seen, the agent waits.
4. **A discovered Erased waits where it stands.** The engine refuses to move a
   discovered spy (`Jump.pre_validate/2`), so the old "a blown Erased may
   roam" rule only produced refused orders.

### Siderians: destabilization and seduction (built 2026-09-30)

Today every Siderian is a capturer: the Warlord only buys proselyte points
and only orders `make_dominion`. This adds the other two Siderian trades.
User direction (2026-09-30): destabilization softens capture targets, but its
bigger use is **mass destabilization** — several agitators on one enemy
system at once, crushing its production and defence and keeping the enemy
economy down; agitators **train** by clustering on one neutral system, the
way sabotage practice works but with no Navarch needed; **seduction follows
the removal rules**, weighing the target's stability instead of Intelligence.
Decided 2026-09-30: agitators travel at most a day for a target, at most 5
work one target, converts are put to work on top of the ceilings, and
seducers may target governors. Defaults still open to change are marked ⚑.

#### Engine facts the design rests on

- **Destabilize** (`EncourageHate`, 50 ut) works on the system the Siderian
  stands in: a neutral, dominion or player system not owned by its own player.
  It rolls the agitator coefficient (14 per agitator point, before faction
  bonuses) against `max(happiness, 0)`. The outcome sets the target's
  happiness penalty and the Siderian's cooldown: critical failure 0 / 120 ut,
  failure 5 / 100 ut, success 15 / 40 ut, critical success 20 / 30 ut
  (experience 0.1 / 0.3 / 1 / 1.2 × base). Even a failure costs the target 5.
- **Penalties stack and decay slowly**: each decays on its own at 0.01 ut⁻¹
  (slow speed), so a success lasts about 1,500 ut (three match days). Each one
  lowers the defence the next roll faces, which is why clustering works.
- **What unhappiness does** (`PopulationStatus`): happiness ≤ 0 is
  discontent (10% cut), ≤ −10 demonstration (25%), ≤ −20 uprising (50%),
  ≤ −30 general uprising (80%). The cut multiplies production, credits,
  technology, ideology, defence, Intelligence, cybersecurity and all four
  ship-class levels; population also shrinks below 0 and faster below −10.
  There is no revolt: −30 is where the effect tops out.
- **The same number defends against capture**: `make_dominion` also rolls
  against `max(happiness, 0)`, so a destabilized neutral or dominion is a soft
  capture target.
- **Seduce** (`Conversion`) targets an on-board character in the Siderian's
  system, owned by another player: seducer coefficient (13 per point) against
  the target's **determination**, plus the system's happiness when the target
  stands in its own faction's system — so negative happiness *lowers* the
  defence (floored at 0). Cooldown 220 / 180 / 120 / 100 ut. Success kills the
  target and hands the bot a copy of it, **without its fleet**
  (`Character.deactivate/1` clears the army; the fleet stays with the human
  under a stand-in commander).
- **UI parity**: the in-game Destabilize and Seduce actions are greyed out at
  0 points in their skill (unlike Infiltrate), so the bot never orders either
  without a point.
- **What the Rebellion can see**: a system's characters at visibility 2, its
  happiness and population at 3, a character's determination and a system's
  Intelligence and production at 4 (`Instance.Faction.StellarSystem.obfuscate/4`,
  `Instance.StellarSystem.Character.obfuscate/2`). An agent standing in the
  system gives only 2, so as with Intelligence the bot mostly learns
  happiness from its own results: every destabilize report shows the defence
  rolled against (`max(happiness, 0)`) and the penalty applied. Below 0 the
  report only says 0, so from there the bot runs on its own penalty ledger.
  `Wave.Intel` needs a `happiness: 3` tier.

Live calibration, instance 185 on 2026-09-30:

- Myrmezir systems sit at happiness 3–11 (one at 24).
- The neutrals around rebel space sit at 7–36.
- Myrmezir are already training agitators the clustered way on Edee, in
  their home sector: six stacked penalties, happiness −13, demonstration.
- Myrmezir determination: Navarchs 13–26, Erased 11–44, Siderians 17–85.

Odds from `Wave.Intel.success_chance/3`, level 1, before faction bonuses:

| happiness | 0–6 | 10 | 15 | 20 | 24 | 30 |
|---|---|---|---|---|---|---|
| 1 agitator point | 1.00 | 0.73 | 0.47 | 0.29 | 0.18 | 0.05 |
| 2 agitator points | 1.00 | 1.00 | 0.90 | 0.73 | 0.61 | 0.47 |

| determination | 11 | 17 | 26 | 44 | 68 |
|---|---|---|---|---|---|
| 1 seducer point | 0.62 | 0.34 | 0.09 | 0.00 | 0.00 |
| 2 seducer points | 1.00 | 0.78 | 0.51 | 0.18 | 0.00 |
| 3 seducer points | 1.00 | 1.00 | 0.77 | 0.44 | 0.17 |

So a single one-point agitator takes a typical Myrmezir system from about 6
to below −30 in three successes, which is the 80% cut.

#### 1. Roles and hiring

- Every Siderian has a **role** — capture (proselyte), destabilize
  (agitator), seduce (seducer) — kept for life, like an Erased duty. A hire
  takes the role it was bought for; a seduced convert rolls one among the
  trades it has points for, weighted by `siderian_role_weights` × (1 +
  points). A Siderian with no point in its role is dismissed, as capturers
  with no proselyte points always were. Roster entries from before roles
  were capturers.
- **Hiring** keeps the Siderian ceiling as the total and splits it into role
  quotas (`Wave.Siderian.quotas/3`): capture takes its 40% share only up to
  the capture targets there are, and the rest of the ceiling goes to
  destabilization and seduction by weight (30 / 30), largest remainder first
  so the quotas add up to the ceiling. The bot buys for the role furthest
  below its quota, scoring candidates by that role's strength (the
  `speaker_make_dominion` / `speaker_encourage_hate` / `speaker_conversion`
  bonus × points); with nobody on the market for that role it tries the next,
  then backs off `siderian_retry_ut`. The rank schedule is unchanged. ⚑
- On 185 this is what would have bought agitators already: capture is
  waiting for day 4, but training ground exists now.

#### 2. Mass destabilization

An idle agitator with no cooldown picks, in order:

1. **The focus.** Agitators converge on one enemy system at a time: a human
   player system or dominion within `destab_max_travel_ut` (480 ut, a day;
   lane length × `character_movement_factor`, as for the training Navarch).
   There is no fall-off as with Erased slots — joining the focus is the
   point — only a cap of `destab_focus_cap` (5) agitators on one system. A new focus is
   chosen only when the current one reaches the floor or drops out of reach.
2. **Choosing a focus** ⚑: (a) enemy systems in sectors the Rebellion works
   (frontier and border), since those also decide sector votes and fights;
   then (b) the most valuable system it can read (population at visibility 3,
   production at 4); then (c) the lowest estimated happiness; then
   (d) nearest.
3. **Floor and upkeep.** Stop adding strikes when the estimate reaches
   `destab_floor` (−30, general uprising). After that a single agitator keeps
   it there, striking again once the estimate climbs back above
   `destab_floor + destab_rehit_margin` (10). The estimate is the last
   reported defence, minus the bot's own penalties since then, each decaying
   at 0.01 ut⁻¹, and is re-anchored on every report.
4. **Capture support.** With no enemy target in reach, soften the capture
   target a capture Siderian is heading for, when its estimated happiness is
   above `capture_soften_above` (10). ⚑ Whether this outranks an enemy focus
   in reach is open.

#### 3. Destabilization practice

Below `siderian_train_max_level` (5), an agitator with no strike practises:

- **Ground**: a neutral inhabited system. The user's "neutral dominion" is
  read as a neutral system, since dominions always have an owner.
- **Clustering**: all practising agitators share one ground, because every
  penalty makes the next roll easier. The current ground is kept while it is
  within `siderian_train_max_travel_ut` (480 ut, a day) of the agent.
  Otherwise the agent picks the ground nearest to it, preferring
  (a) neutrals the capture Siderians will want (practice softens them),
  then (b) the lowest estimated happiness.
- No cap on trainees and no floor: a deeper ground just means surer wins.
- At the level cap, or with no ground in reach, it scouts never-seen systems,
  else waits, as the Erased do.

#### 4. Seduction (removal rules, stability instead of Intelligence)

- **Candidates**: the same pipeline as Erased removal (`reachable_hostiles`):
  - visible on-board human agents in reach;
  - the borrowed-sight rule (`erased_transient_hops`);
  - the same slots (`erased_target_cap` 5, fall-off 0.35);
  - level-1 stand-in commanders are left alone.
- **Governors are fair game** for seduction (not for removal): a governor
  shows at visibility 2 in its system, and seducing one takes the governor
  and its system bonuses away from the human. The recon roster gains the
  human players' governors, flagged so removal keeps ignoring them. A
  governor always stands in its own faction's system, so its defence always
  includes that system's happiness.
- **Odds**: `success_chance(conversion_coef, level, defence)`, where defence
  is determination (legible at 4), plus the system's happiness when the
  target stands in its own faction's system (legible at 3, or estimated from
  our destabilization ledger). An unreadable determination is a flat
  `seduce_gate.unknown` (0.2) gamble; a readable one runs through the same
  logistic as removal (`Wave.Intel.attempt_chance/2`). The top three
  candidates are walked best odds first.
- **Synergy**: agents standing in a system under mass destabilization get
  cheaper to seduce as its happiness drops below 0.
- **Converted agents are put to work, on top of the day's ceilings.** They
  arrive without a fleet. A converted Erased joins the Erased roster with a
  rolled posting; a converted Siderian joins with a rolled role; a converted
  Navarch joins the colonisers when colonisation needs one and otherwise
  waits at home. Converts are tracked apart (`converted: true`) so the hire
  logic does not count them against the ceilings.
- **Idle seducers** ⚑: with agitator points they practise destabilization on
  the shared ground; otherwise they scout or wait (there is no way to
  practise seduction without a victim). A level-up can hand a seducer its
  first agitator point, and from then on it practises. Without a fresh
  hostile reading a seducer waits for the next one rather than wander off.

#### 4b. Evasion (user direction, 2026-09-30)

Unlike the Erased, a Siderian cannot hide, and one resting on its cooldown is
easy for enemy Siderians to seduce or Erased to remove. Nothing intercepts a
Siderian while it moves, so outside rebel-held sectors a Siderian on its
cooldown keeps moving: one lane at a time to a random neighbour, never
straight back while there is another way, until the cooldown ends
(`siderian_evade`, on by default). In rebel-held sectors — the backline, where
practice usually happens — it simply rests. Evasion hops hold no target slot
and are counted (`evasions`).

#### 5. Bookkeeping, telemetry, snapshots

- Roster entries gain `role` (`:capture | :destab | :seduce`, literal atoms)
  and, for converts, `converted: true`.
- The Warlord keeps `siderian_intel`
  (`%{system_id => %{anchor:, at:, ledger: [%{penalty:, at:}], held:}}`),
  `destab_ground` (system id or nil) and `convert_navarchs` (the reserve),
  all back-filled by `upgrade/1`. There is no stored focus: every agitator
  ranks the same targets the same way, and the one already being worked
  ranks first, so they converge on their own.
- The strike outcome is read the way the player reads it off the agent: the
  cooldown duration the Siderian came back with (`Core.CooldownValue.initial`
  120 / 100 / 40 / 30 → penalty 0 / 5 / 15 / 20). The defence the report
  showed is `max(happiness_now + penalty, 0)`.
- Counters: `destabs_attempted`, `destab_resolved`, `destab_aborted`,
  `destab_penalty`, `destab_practice`, `destab_practice_resolved`,
  `destab_practice_aborted`, `seductions_attempted`, `seductions_succeeded`,
  `seductions_failed`, `seductions_aborted`, `evasions`, `siderian_scouts`,
  `converts_adopted`, `converts_employed`, `siderian_action_started`.
- Diagnostics rows: "Destabilization", "Destabilization practice",
  "Seduction", "Converts", "Siderian movement"; agents are labelled with
  their role and "(convert)"; reserve Navarchs are listed.
- Log kinds: `wave_siderian_*` payloads carry `role`, `action`, `purpose`
  (`mass` / `soften` / `practice`) and `training`; adopting a convert logs
  `wave_convert_adopted` (whitelisted).
- The recon view is now shared by the Erased and the agitators and seducers
  (one reading per `erased_recon_interval_ut`), and its hostile roster holds
  governors too (`governor?: true`), which removal and sabotage skip.

Knobs: `siderian_role_weights`, `destab_max_travel_ut` (480), `destab_focus_cap` (5),
`destab_floor` (−30), `destab_rehit_margin` (10), `capture_soften_above` (10),
`siderian_train_max_level` (5), `siderian_train_max_travel_ut` (480),
`seduce_gate` (like `erased_removal_gate`), `siderian_evade` (true).

Verified live on a dev game (2026-09-30, 150×): the bot hired for the short
roles; an agitator took a mass-destabilization target; a seducer that levelled
into an agitator point practised on the shared neutral in rebel space (penalty
15 against happiness 12, estimate −3), rested there without evading, then
seduced a planted human Siderian in the same system; the convert was put to
work as a seducer.

### Deviations from the plan below

| Plan | MVP | Why |
|---|---|---|
| Any scenario faction becomes the bot faction | A new catalog faction `:rebellion` | The user asked for a defined faction |
| Recruits synthesized in a skill range | Real market purchase of a one-star Navarch | MVP spec; proves agent purchasing |
| Navarch combat roles | Colonization only | MVP spec |
| Faction-scoped mutators for caps and Rebel Zeal | `Wave.Config.player_bonuses/1` in `extract_bonus/2`; Rebel Zeal not built | Smallest change that proves bot-only bypass |
| Tree map on the galaxy agent | `SystemAI.Trees` parses extra trees once into `:persistent_term`; the vanilla tree still rides the galaxy | No snapshot shape change, no galaxy round trip per AI turn |
| Remove `wait_for_population_growth` | Kept | It only short-circuits builds that would fail on workforce anyway |
| `choose_upgrade_category` + synthetic infra category | One legality-aware `upgrade_any` | Simpler, and it fixes the infra ceiling directly |
| Port the `bot_faction` column | `Wave.locked_faction?/2` over `game_data` plus capacity 1 | No migration for an MVP |

Known gaps: the bot's cached copy of a system can lag behind AI orders on its
own `:inhabited_player` systems (humans read systems directly, so they are
unaffected); a pause/resume re-sends `:connect`, inflating the bot's
connected-client count (harmless, it only needs to be above zero); the vanilla
`build_workforce/1` bug is untouched.

### Driving it (dev only)

The harness endpoints are gated by the shared secret and a non-prod
environment. Read `.dev-ports.json` for this worktree's Phoenix port; the
docker-compose secret is `dev-harness-secret`.

```bash
curl -s -X POST localhost:$PORT/api/harness/wave/start -H 'x-harness-secret: dev-harness-secret' -H 'content-type: application/json' -d '{"email":"user1@abc","knobs":{"hire_interval_ut":2}}'
```

```bash
curl -s localhost:$PORT/api/harness/wave/$IID/status -H 'x-harness-secret: dev-harness-secret'
```

`GET /api/harness/wave/profile?ms=10000` attributes node CPU to agent types
over a sampling window. The start body also accepts inline `game_data` and
`game_metadata` (e.g. a scenario copied from production) and a
`win_points_target` override, and status reports per-sector owner, vote
counts and adjacency. `POST …/force_hire` runs a hire cycle now; `POST …/run` runs one Warlord pass;
`POST …/speed` with `{"multiplier": n}` applies the runtime speed cheat (the
start body also accepts `"speedup"`). At Legacy speed a colonization round trip
takes hours of real time, so tests normally run at 100–200×. The creator can
also use the in-game speed cheat, capped at 50×, since wave instances are
created with cheats enabled.

### Going live: the lobby path (2026-09-28)

Players reach the mode ("Rebel Defense" in the UI) the ordinary way; the
harness above stays for tests. `Wave.Lobby` holds the server side.

1. **Forge** (`create/Scenario.vue`). Step I has a Game mode radio; Rebel
   Defense is offered on Legacy speed only. In step II the map-maker paints
   exactly two factions and picks which one is the **rebel start**; on "Next"
   that faction's sectors are rewritten to `"rebellion"` and
   `game_data.game_mode_type = "wave"`. The scenario changeset re-validates
   (`Wave.Lobby.validate_scenario/1`: Legacy, one playable faction + the
   Rebellion, a sector each) and mirrors the mode into `game_metadata` for the
   list badge. The mutator list in step I is folded by default.
2. **New game** (`play/New.vue`). A wave scenario shows the explainer, gives
   the Rebellion a fixed "1 seat · game AI" row and hides faction government.
   `RC.Instances.create_instance/3` calls `Wave.Lobby.prepare_instance/2`,
   which forces `game_mode_type: "wave"`, government off, the Rebellion's
   capacity to 1 and writes `game_data["wave"]` (`bot_faction`,
   `human_faction`; every other knob defaults at runtime through
   `Wave.Config`). A stray `"wave"` mode on a non-wave scenario falls back to
   casual.
3. **Publish / Start.** `Portal.InstanceController.publish/2` seats the shared
   Rebellion bot profile (`Wave.Lobby.ensure_rebellion_registered/1`,
   idempotent); `do_fresh_start/3` re-checks before building the world. The
   Manager spawns the Warlord as for any wave instance.
4. **Lobby** (`Instance.vue`, `InstanceRow.vue`). Rules blurb on the overview,
   the human faction listed first, the Rebellion card tagged "Enemy · AI" with
   no join controls, and an orange "Rebel Defense" badge in game lists.
5. **Diagnostics** (admins). `GET /api/instances/:iid/wave/diagnostics`
   (`Wave.Diagnostics`) and the portal page `/instance/:iid/rebellion`, linked
   from the lobby's manage box: clock and Warlord lag, pass cost, bot player
   health, the **order ledger** (`Warlord.order/3`: every hire, itinerary,
   recall and dismissal the engine took or refused, by reason), outcome rates,
   agents holding one stage longer than 120 ut, untracked engine-side agents,
   and the last 60 `wave_*` events.

**Real-speed behaviour (checked 2026-09-28 at 1×).** Every Warlord knob is in
game time, so compressed test runs and a weeks-long Legacy match make the same
decisions per ut; only wall-clock time differs. One pass per
`tick_interval_ut` (1 ut ≈ 3 real minutes), orders only to agents the roster
reports idle, about 0.5 ms per pass. One trap fixed: the TickServer `tick`
decorator runs the tick before every call, so each diagnostics read, harness
status or autosave `get_state` used to run a full pass. `Warlord.pass_due?/1`
now gates the pass on the schedule the last pass set (`since_pass` /
`next_pass_in`); calls only advance the clocks. Refusal tallies cap at 40 keys
each so a long match can't grow the snapshot.

**Stats and the end screen.** Rebel Defense matches count toward a profile's
official Legacy participations but never its wins (`RC.ProfileStats`). The
in-game victory banner adds a mode line (`instanceInfo.wave_bot_faction` from
the global-channel join payload).

**Victory weighting (§3.2), built.** In a wave game `update_tracks/1` gives
every faction the humans' headcount when computing milestone thresholds, so
the one-player Rebellion is not weighted at 0.5 and its population track is
not capped at a single player's share. The stored `player_count` stays real
(the victories row reports it).

---

## 1. Player-facing rules (normalized spec)

Terminology: UI names map to internal actions as follows (from
`lib/game/instance/character/action_impl.ex` and `front/src/locales/en/game.json`).

| UI / spec word | Internal action | Actor | Target |
|---|---|---|---|
| Pillage | `loot` | Navarch (`:admiral`) | system |
| Bombard | `raid` | Navarch | system |
| Conquer | `conquest` | Navarch | system |
| Capture dominion / Control | `make_dominion` | Siderian (`:speaker`) | system (`:inhabited_neutral` or `:inhabited_dominion` only) |
| Destabilize | `encourage_hate` | Siderian | system |
| Seduce | `conversion` | Siderian | character (must be in the same system) |
| Infiltrate | `infiltrate` | Erased (`:spy`) | system |
| Remove / Delete | `assassination` | Erased | character (same system) |
| Sabotage | `sabotage` | Erased | character (Navarch, same system) |
| Move | `jump` (one per star lane) | any | — |

### 1.1 Setup

- Created from any Forge scenario at **Legacy speed** (`:slow`, factor 1:
  1 ut = 1 in-game day = **3 real minutes**; 20 ut per real hour, 480 ut per
  real day). Only Legacy is offered in v1 (the constants below are Legacy).
- The creator picks the **human faction** and the **rebellion faction** (any
  two of the scenario's factions). Sectors that belong to other factions in
  the scenario are rewritten to unowned (`"faction" => nil`) so the map has
  exactly one human start and one rebellion start (§3.2, knob to give the
  rebellion the extra start sectors instead).
- Humans register into the human faction through the normal lobby; the
  rebellion faction is locked to humans (`:bot_faction_locked`). Late
  registration is allowed and the rebellion scales with the live human count.
- The two-faction diplomacy rule already starts the game at war
  (`Instance.Diplomacy.Diplomacy.new/2`).
- Victory conditions are unchanged for both factions (default 14 VP on the
  three tracks, or time-out ranking).

### 1.2 Timeline

- **Spawn phase**: 0 → 3 real days (0 → **1440 ut**). The rebellion builds
  its economy, recruits, and constructs fleets, but issues no offensive
  orders. Siderians may still capture frontier dominions (their 80% bucket)
  because that is expansion, not attack; knob `assault_only_after_spawn`
  defaults to `false` for capture, `true` for everything else.
- **Assault phase**: from 1440 ut onward, all roles are live. Waves are
  expressed as a **roster schedule** (how many agents of each type the
  rebellion keeps alive) and a **tech-tier schedule** (which blueprints are
  eligible) — see §5.5 and §7.3.

### 1.3 Roles (the user's spec, with interpretations marked ⚑)

**Siderian**

- *Capture dominions*: candidates are `:inhabited_neutral` or
  `:inhabited_dominion` systems (owned by the humans or unowned), never the
  rebellion's own, and **takeable** for the rebellion
  (`Galaxy.check_system_takeability/3`: in a rebellion-owned sector or
  adjacent to one). Bucket weights 80 / 15 / 5:
  - 80 — system's sector is **uncontrolled** (`owner == nil`) and adjacent to
    a rebellion sector ("frontier");
  - 15 — system's sector is a **border** sector: rebellion-owned but touching
    a non-rebellion sector, contested (both factions hold inhabited systems in
    it), or human-owned and adjacent to rebellion territory ⚑;
  - 5 — system's sector is a rebellion **interior** sector (all neighbours
    rebellion-owned).
  Empty buckets are dropped and weights renormalized; within a bucket pick by
  proximity (nearest hop count, ties by rand).
- *Destabilize*: 80 — a human `:inhabited_player` system; 20 — a human
  dominion located in an uncontrolled sector. Nearest first.
- *Seduce*: 50 — governor mode (travel to a human system with a governor,
  attempt the governor); 50 — agent mode (any visible human non-governor
  character: Navarchs, Siderians, discovered Erased). If nothing is visible,
  roam (§6.6).
- Role split among Siderians (not in the spec) ⚑: 40% capture / 30%
  destabilize / 30% seduce. Knob.

**Erased**

- *Infiltrate*: human-owned systems where the rebellion's **resolved
  visibility < 5** (`Instance.Faction.Faction.resolve_system_visibility/2`);
  75 — human dominions, 25 — human systems.
- *Remove*: once per real day (480 ut) roll `governors_allowed` at 10% and
  `unknown_attempt_day` at 25% (both faction-wide). Candidates are visible
  human characters (governors only on allowed days). Each candidate gets a
  **chance class** (§6.4): `:unknown` (defender stat not visible),
  `:fail` (band entirely below 0.5), `:mixed`, `:success` (band entirely
  above 0.5). Attempt gate per candidate per day: unknown → only on an
  `unknown_attempt_day`; fail → 25%; mixed → 50%; success → 95%. Survivors are
  sorted by expected success (band midpoint) descending and dealt to the
  available removers round-robin, nearest remover first.
- *Sabotage*: same attempt gate as remove. A saboteur always prefers a human
  fleet **in its current system or one hop away**. 75% of saboteurs are
  **wreckers** (station themselves in human systems/dominions and attack
  fleets sitting there); 25% are **guards** (roam rebellion-owned systems and
  hit visiting fleets).
- Role split among Erased ⚑: 40% infiltrate / 30% remove / 30% sabotage.
  Knob.

**Navarch**

- 30% **defense**: 60% of them post on border systems (rebellion systems in
  border/contested sectors or adjacent to uncontrolled ones), 40% on core
  systems (interior sectors, capital first). A rebellion system under siege
  pulls the nearest defender regardless of post.
- 70% **offense**: 80% **frontline** — targets in contested sectors or human
  sectors bordering uncontrolled/contested sectors (depth 0); 20% **deep
  strike** — human systems at sector depth ≥ 1, weighted `0.5^depth` ⚑ so
  the first target is much more likely one sector in than three.
- Offense action: 70 pillage (`loot`) / 30 bombard (`raid`), rolled per
  sortie.
- Fleets are **constructed, not produced** (§5.6): when a Navarch is at a
  rebellion-owned system, one ship from its blueprint materializes every
  **15 real minutes (5 ut)** until the blueprint is complete; then the
  Navarch is released to its role. An empty Navarch elsewhere travels home
  first.
- Wounded fleets (< 35% surviving hull ⚑) retreat to the nearest owned
  system and re-enter construction to refill lost tiles.

### 1.4 Agent strength

- Every 3 real days (1440 ut) compute, per type, the **average non-governor
  skill points** of all human characters of that type
  (`Enum.sum(Enum.take(character.skills, 3))` — indices 0..2 are the
  `:army`/`:spy`/`:speaker` skills for every type; 3..5 are the
  `:stellar_system` governor skills). Include deck, governor and on-board
  characters. Fall back to the other types' average, then 0.
- Target range: Siderian/Erased `[ceil(0.8·avg), ceil(1.1·avg)]`; Navarch
  `[ceil(0.5·avg), ceil(0.95·avg)]`. Never negative. If `hi − lo < 2`,
  widen by one on each side; if that would push `lo` below 1, push the
  deficit onto `hi` (so `[1,1] → [1,3]`, `[4,4] → [3,5]`, `[0,0] → [1,3]`).
- Recruits are created inside the range (§5.2). Existing agents whose
  non-governor points fall below `lo` at a review join the **training pool**:
  they travel back to the rebellion home sector and earn **2 XP per real
  hour (0.1 XP/ut)** passively until back in range, then return to duty.

### 1.5 Rebellion economy

- Systems owned by the rebellion (its `:inhabited_player` systems **and** its
  dominions) are developed by a **wave copy of the dominion behavior tree**
  ("Rebel Dominion", §4.3) with: no cadence delay, "if no slot is empty, go
  to upgrades instead of terminating", and 25% upgrade odds (down from 50%)
  when slots are empty.
- **Rebel Zeal**: ×2.5 system production for the rebellion faction only
  (§4.1).
- Because ships and agents are synthesized, the rebellion's production and
  credits do **not** gate its military; they feed defence buildings, pillage
  value, and the optional market recruitment mode.

---

## 2. Architecture

### 2.1 Process model

```
Instance.Supervisor (per instance)
 ├─ … existing agents (time, rand, market, galaxy, victory, diplomacy,
 │     factions, orchestrator, players, stellar systems, characters)
 └─ Wave.Warlord.Agent   ← NEW, one per wave instance, a Core.TickServer
        state: %Wave.Warlord{}  (roster/roles/pools/blueprint progress/timers)
        tick:  every 1.67 ut ± 0.5 (≈5 real min ± 90 s at Legacy)
        does:  build Wave.View → for each idle rebellion agent run its role
               tree (BT) → collect orders → execute via Wave.Bot.Act against
               the rebellion Player.Agent → record telemetry
```

Decisions:

- **One rebellion player, one commander.** The rebellion is a single real
  profile/registration (`wave-rebellion@tetrarchyfalls.local`, `is_bot: true`)
  in the bot faction, so every agent, system and dominion hangs off one
  `Instance.Player.Agent`. The Warlord is the faction brain. This avoids the
  cross-player pool coordination an N-bot design (the branch's `RC.Bots`)
  would need. Player caps are lifted by a wave bonus set (§4.2).
- **The Warlord is a `Core.TickServer` inside the instance tree**, not an
  external overseer. It is then started/stopped/paused/speed-cheated with the
  instance, snapshotted and restored by `Instance.Manager`, and its timers are
  pause-safe. Requirements: implement `on_call/3`, `on_cast/2`,
  `on_info(:tick, state)`, `do_next_tick/2`, `Wave.Warlord.compute_next_tick_interval/1`,
  start it in `Instance.Manager.do_init_from_model/4` when the instance is a
  wave game, and **add `Wave.Warlord.Agent` to `@snapshot_allowed_modules`**
  in `lib/game/instance/manager.ex` (otherwise snapshot restore rejects it).
  Do not use a plain GenServer (the `Game.News.Server` `@no_tick`/`@no_snapshot`
  wedge).
- **Engine state is the source of truth.** The Warlord persists only what the
  engine does not know: role assignments, pool membership, blueprint per
  Navarch and construction cursor, daily rolls, review timers, telemetry.
  On restore it re-derives the roster from the player state and drops
  assignments for characters that no longer exist. Every struct field is
  read with `Map.get/3` and written with `Map.put/3` (snapshot tolerance
  convention, `lib/game/instance/player/player.ex:88-104`).
- **Decision trees, not running behaviour trees.** Each idle agent is
  evaluated once per Warlord tick with a fresh tree (exactly how `SystemAI`
  uses the library). Long actions are the engine's action queue; the tree
  only decides *what to enqueue next*. No `:running` state is needed.
- **The rebellion reads the world omnisciently but acts on its own
  intelligence.** `Wave.View` reads galaxy/system/character state directly
  (cheap, and every shipped 4X AI does this), while the chance-class and
  infiltrate rules explicitly use the rebellion faction's *resolved
  visibility* so "unknown chances" means what it means for a human.

### 2.2 What is reused, ported, or new

| Concern | Source | Action |
|---|---|---|
| BT engine + parser + `mix extract_actions` | master (`lib/game/system_ai/*`, `lib/game/util/parser.ex`, `term_parser.ex`, hex `behavior_tree 0.3.1`) | reuse; add a keyed tree registry (§8.1) |
| Instance recipe | master `Daily.Boot.boot_persisted/2`, `Portal.InstanceController.do_fresh_start/3` | reuse pattern in `Wave.Boot` |
| Bot profile creation | master `Daily.Boot.ensure_profile/2` | copy pattern |
| Engine payload adapter | branch `lib/headless/bot/act.ex` (97 lines) | **port** as `Wave.Bot.Act` |
| Lane pathfinder (BFS hops) | branch `lib/headless/bot/nav.ex` (62 lines) | **port** as `Wave.Nav`, add Dijkstra by edge weight for travel time |
| Per-decision view builder | branch `lib/headless/bot/view.ex` (109 lines) | **port** as `Wave.View`, trimmed to one player |
| Driver GenServer | branch `lib/headless/bot.ex` | do **not** port; the Warlord replaces it. Borrow two ideas: `{:update_client_status, :connect}` on start so the bot player counts as active, and the per-kind ok/refused tallies |
| `bot_faction` column, registration lock, lobby tag, create-form select | branch migration `20260705150000_add_bot_faction_to_instances.exs`, `lib/rc/instances.ex`, `lib/rc/instances/instance.ex`, `lib/portal/controllers/registration_controller.ex`, `lib/portal/views/instance_view.ex`, `front/src/portal/pages/Instance.vue`, `front/src/portal/pages/play/New.vue`, locale keys | **port** |
| Orchestrator stale-lock self-heal | branch commit `9ac5be8` (`action_queue.ex` `lock_expired?/2`, `character.ex` `recover_from_stale_lock/1`); on branches `claude/great-chatelet-d96fae` etc., **not on master** | **port** — dozens of bot characters queuing continuously will hit lost round-trips |
| Interception death leaves a wedged head | branch diff to `conquest.ex`/`loot.ex`/`raid.ex` (`Character.abort_action` in the fled/died branch) | verify on master; port if the `else` branch still returns `{character, []}` |
| Runtime `SPEEDUP` | branch `lib/game/core/tick.ex` `speedup/0` (persistent_term) | **port** — makes soak runs tunable without recompiling |
| `Instance.Rand.Safe`, market `generate_character` rescue, galaxy `get_initial_system` nil-safety, player `:claim_initial_system` guard | branch | port opportunistically (hardening; low risk) |
| Arena blueprint generator | branch `lib/sim/blueprints.ex` + `mix sim.blueprints` (appless) | **port** — seeds the pool when mined data is thin (§7.4) |
| `RC.Bots`, `RC.Bots.Overseer`, `Headless.Policies.*`, marathon/dashboard tooling, `Headless.Strategist/Budget/Econ/Fitness` | branch | not needed |
| Everything under `lib/wave/` | — | new |

### 2.3 Module map (new code)

```
lib/wave/
  wave.ex                  Wave — mode constants, game_data["wave"] schema, knobs
  boot.ex                  Wave.Boot — instance creation, bot profile, registration, start
  config.ex                Wave.Config — read/validate knobs from metadata (rescue-guarded like Instance.Mutators.daily?/1)
  warlord.ex               Wave.Warlord — pure state + tick logic (roster, pools, phases, schedules)
  warlord/agent.ex         Wave.Warlord.Agent — the Core.TickServer wrapper
  view.ex                  Wave.View — per-tick snapshot (ported)
  nav.ex                   Wave.Nav — hop paths + weighted travel time (ported + Dijkstra)
  geometry.ex              Wave.Geometry — sector classes, depth, posts (pure)
  intel.ex                 Wave.Intel — visibility-aware chance classes (pure)
  recruit.ex               Wave.Recruit — skill ranges, recruit synthesis, spawn placement
  roles.ex                 Wave.Roles — pool targets, deficit-biased assignment, reviews
  training.ex              Wave.Training — training pool drip + homing
  blueprints.ex            Wave.Blueprints — pool loading, tiers, eligibility/deprecation, pick
  blueprints/miner.ex      Wave.Blueprints.Miner — extraction from player_report / player_events / snapshots
  construction.ex          Wave.Construction — the 15-min ship materialization loop
  schedule.ex              Wave.Schedule — roster + tech-tier schedules
  trees.ex                 Wave.Trees — loads priv/data/wave/*.json, runs a tree for an agent
  actions/common.ex        Wave.Actions.Common — BT actions shared by all roles
  actions/navarch.ex       Wave.Actions.Navarch
  actions/siderian.ex      Wave.Actions.Siderian
  actions/erased.ex        Wave.Actions.Erased
  bot/act.ex               Wave.Bot.Act — abstract order → Game.call payload (ported)
  telemetry.ex             Wave.Telemetry — counters + status map for /api/harness/wave
priv/data/wave/
  navarch.json  siderian.json  erased.json      the role decision trees (BT editor format)
  blueprints.json                               mined pool (committed artifact)
  blueprints.seed.json                          arena seed pool
priv/data/system_ai/behavior_tree_wave.json     "Rebel Dominion" build tree
lib/mix/tasks/wave.mine_blueprints.ex, wave.soak.ex, wave.preview_trees.ex
```

### 2.4 Time conversions used throughout (Legacy)

| Real | ut | Notes |
|---|---|---|
| 3 min | 1 | `Core.Tick.@unit_time_divider 180_000 / factor 1` |
| 5 min | 1.667 | Warlord cadence (jitter ±0.5 ut) |
| 15 min | 5 | construction cadence |
| 1 h | 20 | 2 XP/h = 0.1 XP/ut |
| 1 day | 480 | Erased daily rolls; note `Instance.Diplomacy.@ut_per_day 480` uses the same convention |
| 3 days | 1440 | spawn phase; strength review |
| 30 days | 14400 | default Legacy `time_limit` 43200 min |

Travel: `edge.weight × constant.character_movement_factor` (Legacy 7.2) ut per
hop; lanes are ≤ 12 units (`SpatialGraph.@max_dist`), so a hop is ≤ 86 ut
(≈ 4.3 real hours). Legacy action durations: `conquest_time 150`,
`raid_time 40`, `loot_time 20`, `make_dominion_time 150`,
`encourage_hate_time 50`, `infiltration_time 50` ut, the dice-based ones
multiplied by `Core.Dice.ratio_to_factor/1` (1.0–2.0). Timers must be kept
in ut and advanced from `elapsed_time` in `do_next_tick/2` — never
`Process.send_after` — so pause/resume and the speed cheat behave.

---

## 3. Instance lifecycle

### 3.1 Creation flow

`front/src/portal/pages/play/New.vue` → `POST /api/instances` →
`Portal.InstanceController.create/2` → `RC.Instances.create_instance/3`,
unchanged, plus:

- `game_mode_type: "wave"` (a new value; there is no server whitelist,
  `create_instance/3` copies it into `game_data` verbatim). Ranked is
  refused for wave games.
- `bot_faction: "<key>"` (ported column; validated to be one of the
  instance's factions).
- `game_data["wave"]` block written by `Wave.Boot.prepare_game_data/3`:

```elixir
%{
  "bot_faction" => "myrmezir",
  "human_faction" => "tetrarchy",
  "spawn_phase_ut" => 1440,
  "roster" => %{"base" => %{"admiral" => 1.0, "speaker" => 0.75, "spy" => 0.75},
                "per_wave" => %{"admiral" => 1, "speaker" => 0.5, "spy" => 0.5},
                "cap" => %{"admiral" => 12, "speaker" => 8, "spy" => 8},
                "wave_interval_ut" => 960},
  "tech" => %{"tiers_per_wave" => 1, "catch_up" => true, "ship_level_by_tier" => true},
  "roles" => %{"speaker" => %{"capture" => 0.4, "destabilize" => 0.3, "seduce" => 0.3},
               "spy" => %{"infiltrate" => 0.4, "remove" => 0.3, "sabotage" => 0.3,
                          "wreckers" => 0.75},
               "admiral" => %{"defense" => 0.3, "border" => 0.6, "frontline" => 0.8,
                              "pillage" => 0.7, "retreat_hull" => 0.35}},
  "recruitment" => "synthesize",          # | "market"
  "rebel_territory" => "home_sector",     # | "all_other_starts"
  "solvency_floor" => 50_000
}
```

  Defaults live in `Wave.defaults/0`; the form only exposes a handful
  (factions, difficulty preset). `Instance.Manager.do_init_from_model/4`
  caches `wave: game_data["game_mode_type"] == "wave"` and
  `wave_config: game_data["wave"]` in the metadata keyword list next to
  `daily:` (`lib/game/instance/manager.ex:350-376`); `Wave.Config.enabled?/1`
  and `Wave.Config.get/1` read them like `Instance.Mutators.daily?/1`.
- `mutators` gets the two rebellion entries appended (§4.1) with the faction
  scope.
- Sectors: every sector whose `"faction"` is neither the human nor the bot key
  becomes `"faction" => nil` (or the bot key when
  `rebel_territory == "all_other_starts"`).
- `faction_gov_enabled` is written **explicitly `false`** (an absent key
  grandfathers government ON at Legacy — `Instance.Faction.Government.enabled?/2`).
  The rebellion faction cannot vote and government adds nothing to the mode.
- `cheats_enabled` untouched (creator's choice).

### 3.2 Bot faction registration and start

After `publish_instance/2` (the user publishes from the instance page as
today), `Wave.Boot.ensure_rebellion_registered/1` registers the shared
rebellion profile into the bot faction
(`RC.Registrations.register_profile(faction, profile)`); this runs from the
publish path when `game_mode_type == "wave"` and is idempotent. The profile is
created like `Daily.Boot.ensure_profile/2` with `is_bot: true` set directly on
the account (`RC.Bots.mark_bot/1` pattern) so it is excluded from rankings and
search. One shared profile is fine: player agents are keyed
`{instance_id, :player, profile_id}`.

Start is the standard `do_fresh_start/3` sequence
(`create_from_model` → `Manager.call(:start)` → `Instances.start_instance/2`),
which is what the "Start" button already does; wave games use
`start_setting: "manual"` or `"auto"` like any other. At `:start` the Warlord:

1. `Game.call(iid, :player, bot_pid, {:update_client_status, :connect})` —
   without it the bot player flips `is_active: false` and
   `Instance.Victory.Faction.reset_player_count/2` counts 0 players for the
   rebellion, which collapses its population thresholds and inflates the
   humans' (`faction_weighting`). Re-issued after every restore, because
   snapshot restore zeroes `connected_clients`.
2. Reads `home_sector_ids` (sectors owned by the bot faction at boot) and the
   bot player's initial system.
3. Enters phase `:spawn`.

**Victory weighting** ⚑: even with one active bot player, a 5-human faction
gets `faction_weighting ≈ 1.29` and the rebellion `0.5`. For a survival mode
this asymmetry is wrong-way (bot milestones cheaper). Add a wave-only rule in
`Instance.Victory.Victory.update_tracks/1`: when `Wave.Config.enabled?/1`,
use `player_count = max(human_count, 1)` for **both** factions so the
weighting is 1.0 on each side. Gate strictly on the wave flag.

### 3.3 Humans

- Join via the lobby as today; `Portal.RegistrationController.join/2` refuses
  the bot faction with `:bot_faction_locked` (ported guard), `Instance.vue`
  shows the locked card.
- Late joins (`registration_type: "late_registration"`) hot-add through the
  existing `Instance.Manager.call(id, {:add_player, ...})`; the Warlord picks
  up the new human count on its next tick (roster schedule is a function of
  `n_humans`).
- Client mode flag: the game store currently infers mode from
  `time.speed === 'daily'`; that cannot work at Legacy. Add `wave: %{...}`
  to the `instanceInfo` payload assembled in `Portal.Controllers.GlobalChannel`
  (consumed at `front/src/game/store.js:137`) — see §10.

### 3.4 End of game

Unchanged: `Instance.Victory.Agent` ranks both factions, `record_victory/2`,
rankings (bot account excluded by `is_bot`), Discord post. The Warlord stops
with the tree. `RC.ProfileStats` already excludes dailies by
`game_mode_type`; extend the same filter to `"wave"` so PvE results don't
count toward career stats ⚑ (decision: exclude from ranked stats, include in
"games played").

---

## 4. Rebellion economy

### 4.1 Faction-scoped mutators ("Rebel Zeal", "Rebel Command")

Mutators are instance-global today (`Instance.Mutators.bonus_entries/1`).
Add a faction scope:

- `Data.Game.Mutator` catalog (`lib/data/game/mutator.ex`), two new entries,
  `daily_eligible: false`, `hook: :on_bonus`:
  - `:rebel_zeal` — `%Core.Bonus{from: :sys_production, to: :sys_production, type: :mul, value: 1.5}`
    (`:mul` adds `input × value` on top of the additive base, so 1.5 ⇒ ×2.5;
    cf. `:industrial_surge` = "+40%" with `value: 0.4`).
  - `:rebel_command` — `bonuses:` list of `:add` bonuses `direct → player_system +30`,
    `direct → player_dominion +30`, `direct → player_admiral +20`,
    `direct → player_spy +20`, `direct → player_speaker +20` (pipeline-out
    keys in `lib/data/game/content/bonus-pipeline-out.ex` map to
    `max_systems/max_dominions/max_admirals/max_spies/max_speakers`).
- `game_data["mutators"]` entries gain an optional `"faction"`:
  `%{"key" => "rebel_zeal", "faction" => "myrmezir"}`.
- `Instance.Mutators.bonus_entries/2` (new arity, `faction_key`) returns only
  entries whose scope is absent or equal to the faction; `Instance.Player.Player.extract_bonus/2`
  (`lib/game/instance/player/player.ex:1190`) calls it with `state.faction`.
  `active_keys/1` keeps its shape (used by `cost_multiplier` etc.).
- The bonus reaches systems through the existing
  `{:update_bonuses, :player, system_bonuses}` pushes on claim / policy
  events; nothing else to wire. Verify with a test that a human system in the
  same instance does **not** carry the `{:mutator, :rebel_zeal}` value part.

### 4.2 Solvency

Character wages and fleet maintenance drain `player_credit` via `:direct_last`;
`Player.is_bankrupt` (`credit.value <= 0 and credit.change < 0`) puts every
character `on_strike` and refuses hires/orders. The Warlord runs a solvency
guard each tick: if the bot player's `credit.value < solvency_floor`, cast
`{:add_resources, floor - value, 0, 0}` (engine-internal handler on
`Instance.Player.Agent`, used by loot). Telemetry counts top-ups so the drain
is visible when tuning.

### 4.3 "Rebel Dominion" build tree

Fork `priv/data/system_ai/behavior_tree.json` to
`priv/data/system_ai/behavior_tree_wave.json`, tree title `"Rebel Dominion"`
(keep the vanilla `"Dominion"` byte-identical; the SystemAI tests parse it by
name). Tree edits, using the node ids from the survey:

| Change | Edit |
|---|---|
| (d) 25% upgrade odds | `Upgrade` tree node `63d8bb01-…`: `"title": "SystemAI.Actions.succeed_upgrade?(0.25, 10)"` (`name` unchanged) |
| (a) no cadence | remove root child `36a8ab88-…` (`wait_for_population_growth(4)`); **keep** `f478322b-…` (`wait_if_queue_is_busy()`) so the queue holds one item at a time — "no delay" means the next order is placed the tick the previous completes |
| (c) upgrade when full | insert before the final `sequence[get_random_body, …]` root child: `sequence[ Wave.SystemAI.no_free_tiles?() ; Wave.SystemAI.choose_upgrade_category() ; SystemAI.Actions.upgrade_random() ; SystemAI.Actions.done() ]` — the trailing `done()` is the root-fail-loop guard |

Engine changes behind it (all in master files):

1. **Keyed tree registry.** `Instance.Galaxy.Galaxy.behavior_tree` becomes
   `%{dominion: node, rebel_dominion: node}` loaded from a list in
   `config :rc, RC.SystemAI` (`trees: [dominion: {path, name}, rebel_dominion: {path, name}]`);
   `Instance.Galaxy.Agent.on_call({:get_behavior_tree, key}, …)`;
   `SystemAI.do_action/3` takes the key (default `:dominion`). Better: cache
   the parsed tree in the system agent state on first use — at zero cadence
   the galaxy round trip per evaluation is waste.
2. **Cadence.** `@ai_next_action_unit_days 50` in
   `lib/game/instance/stellar_system/stellar_system.ex:10` becomes
   `ai_action_interval(state)` — `0` for rebellion systems, `50` otherwise.
3. **Scheduler.** `StellarSystem.compute_next_tick_interval/1` (`:191`) must
   include the AI's next-action time for AI-driven statuses; today it returns
   `:never` for an idle system with a flat population and `Core.Tick.next/2`
   cancels the timer, so "no delay" would mean "never runs again".
4. **Bot-owned player systems.** `auto_actions/2` (`:912`) guard gains
   `or (state.status == :inhabited_player and Wave.Config.bot_system?(state))`
   where `bot_system?` compares `state.owner.faction` to the cached
   `wave_config["bot_faction"]`. Tree key: `:rebel_dominion` for rebellion
   systems and dominions, `:dominion` for everyone else.
5. **Infra/hab upgrade eligibility.** `SystemAI.Helper.get_upgradable_tiles/3`
   filters by profile output; `infra_*` (`[:hab, :happiness]`) and `hab_*`
   (`[:hab]`) never qualify, and `order_building_production/2` throws
   `:not_upper_than_infra` for any non-orbital tile above the infra level, so
   a saturated body freezes at level 1. `Wave.SystemAI.choose_upgrade_category/1`
   therefore adds a synthetic `:infrastructure` category (tile 1 of each
   planet, then habitations) and picks a category weighted by `ai_profile`
   **restricted to categories with a non-empty upgradable set** (the
   `get_categories_proportion_built` consistency doctrine at
   `helper.ex:108-117` — a drawn-but-empty category is how the tree hangs).
6. **`build_workforce/1` bug** (`actions.ex:261-277`): filters body `type in
   [:open, :dome]` but body types are `:habitable_planet | :sterile_planet |
   :moon | :asteroid`, so it always fails, and would `CaseClauseError` if it
   passed. Fix: `type in [:habitable_planet, :sterile_planet]` and map
   through `Helper.body_type_to_biome_key/1`. ⚑ This also changes vanilla
   neutral behaviour (they will start building workforce buildings) — confirm
   with the user before shipping; it is a real bug.
7. **Player copy staleness.** AI orders bypass `Player.update_stellar_system/2`.
   Tag `:player_update` in the change set after an AI order on a bot-owned
   `:inhabited_player` system so the bot player's cached system list stays
   coherent (only matters for the rebellion's own reads).

Keep the anti-loop regression test shape from
`test/game/system_ai/unique_building_filter_test.exs` ("a saturated body ends
the action instead of looping") for the new tree — a broken tree **hangs**
the suite rather than failing it.

#### Happiness before housing (2026-10-01)

Instance 185, day 3: the Rebellion's two-day-old colony Mons stood at
happiness −8.2 (discontent, a 10% cut to everything, population shrinking) and
its capital Peth at 0.9. The live breakdown on Mons: population cancels the
base exactly (35 − 35), five finance stations cost 25, seven cheap-housing
blocks cost 10, infrastructure and two happiness buildings give back 27. The
tree caused it three ways:

1. **Workforce outranked happiness.** With three or fewer free workers — nearly
   always — it built housing first, until every planet tile was housing
   (habitation 65 for a population of 36) and nothing was left for the planet
   happiness buildings.
2. **A happiness build could silently do nothing.** `Helper.build/2` ends the
   turn as done when workforce is short, and an unhappy system does not grow,
   so it never gets the workforce to fix itself.
3. **Nothing stopped it digging deeper** with buildings that cost happiness
   while already in unrest.

The fix, in `priv/data/system_ai/behavior_tree_wave.json` and two new actions
(the vanilla tree and its actions are untouched):

- The root now runs **Happiness** before **Workforce**. Happiness (at ≤ 10)
  uses `improve_happiness/1`: a new happiness building on any body with a
  usable tile and the workforce to staff it, otherwise an upgrade of a building
  that outputs happiness, which needs no workforce. It fails only when neither
  is possible.
- **Unrest hold**: at happiness ≤ 0 with nothing that would help, the turn
  ends rather than build anything else.
- Housing is built only while `housing_short?(10)`: habitation less than ten
  above the population, which is where growth stops improving
  (`StellarSystem.population_growth/4`).

---

## 5. Recruitment, strength, roles, construction

### 5.1 Roster and reviews

`Wave.Schedule.desired_roster(config, day_ut, n_humans)` (pure):

```
w        = if day_ut < spawn_phase_ut, do: 0, else: 1 + div(day_ut - spawn_phase_ut, wave_interval_ut)
desired  = min(cap[type], ceil(base[type] * n_humans) + floor(per_wave[type] * w))
```

Each tick, for each type with `alive_count < desired`, recruit at most one
agent per type per tick (throttle knob `recruits_per_tick`). Losses are
therefore replaced within minutes; the roster ratchets up one wave at a time.
Telemetry records `wave_index` transitions and emits a news-ticker entry
(`Game.News.emit(iid, "wave.started", %{wave: w, ...})`) so humans see the
escalation in the ticker.

Every `review_interval_ut` (1440): recompute skill ranges (§1.4), move
under-range agents to the training pool, rebalance roles against the pool
targets (§5.4). Also re-read `n_humans`.

### 5.2 Recruit synthesis (default) and market mode

`Wave.Recruit.range(avg, type)` implements §1.4 exactly (unit-tested against
the examples). `Wave.Recruit.synthesize(iid, type, range, faction_key)`:

1. `{:ok, id} = Game.call(iid, :character_market, :master, :get_next_character_id)`.
2. `Character.Character.new(id, type, rank, nth, iid, %{culture, spec1, spec2, skills})`
   — the `initial_data` clause pins `skills` (a 6-list) and sets
   `initial_skill_points = 0`, `initial_experience = 15`. Choose
   `spec1/spec2` from the type's non-governor specializations; distribute
   `total = rand(lo..hi)` points across indices 0..2 weighted 8/5/1 toward
   `spec1/spec2`, zero in 3..5; rank by total (`:common` < 4, `:remarkable`
   < 9, `:exceptional` otherwise) so protection/determination ranges match
   what a human of that strength would have (`Data.Game.CharacterRank`).
   Culture from `Data.Game.Faction` of the bot faction.
3. Place: `Game.call(iid, :player, bot_pid, {:convert_character, character, system_id})`
   — the dev-fixture spawn primitive (`lib/game/instance/player/agent.ex:773`):
   mints the id, activates `:on_board` at `system_id`, starts the character
   agent, pushes it into the system. No slot check beyond the caps, no cost.

Market mode (`"recruitment" => "market"`): read
`Game.call(iid, :character_market, :master, :get_state)`, filter slots by type
and `sum(take(skills,3)) in lo..hi`, hire with
`{:hire_character, id}` (needs credit/tech/ideology — the solvency guard
tops up credit only, so market mode also needs tech/ideology floors), then
`{:activate_character, id, :on_board, system_id}` (own systems only). Fall
back to synthesis when no slot matches. Market mode competes with humans for
the shared 24-slot market (refill cooldown `market_cooldown_duration` 200 ut
at Legacy ≈ 10 real hours) — ship it as an option, not the default.

### 5.3 Spawn placement

`Wave.Recruit.spawn_system(view, geometry)`: 80% a rebellion-owned system in
a **border** sector, 20% one in a **core** sector (both as classified by
`Wave.Geometry`, §6.1). With a single rebellion sector everything is border;
the 20% then falls back to the capital. Spawn locality is recorded on the
roster entry (`:border | :core`) for role assignment.

### 5.4 Roles and pools

`Wave.Roles.targets(config, counts)` turns the ratios into integer targets per
role per type (largest-remainder rounding). `Wave.Roles.assign(entry, pools)`
picks the role with the largest deficit `target − assigned`; ties prefer the
role matching spawn locality (border → offense/border-defense/wreckers;
core → core-defense/guards/infiltrators). At each review, agents are
re-shuffled only when a role's deficit exceeds 1 (hysteresis, so agents don't
ping-pong). Roles:

| Type | Roles |
|---|---|
| `:admiral` | `:defense_border`, `:defense_core`, `:offense_frontline`, `:offense_deep`, plus transient states `:constructing`, `:training`, `:retreating` |
| `:speaker` | `:capture`, `:destabilize`, `:seduce`, `:training` |
| `:spy` | `:infiltrate`, `:remove`, `:sabotage_wrecker`, `:sabotage_guard`, `:training` |

### 5.5 Tech tier schedule

`Wave.Schedule.tech_tier(config, w, human_signal)` = `min(8, 1 + tiers_per_wave × w)`
before catch-up; with `"catch_up" => true`, never lower than
`human_best_fielded_tier − 1`, where the human signal is the highest tier
(by `Sim.Blueprints`' ladder) of any ship key seen in human armies
(`Wave.View` reads human character armies directly). Tiers reuse the branch
ladder (`t1_scouts … t8_capitals`, cumulative patent sets). Tier changes are
telemetry + ticker events.

### 5.6 Navarch construction

`Wave.Construction` per Navarch: `{blueprint_id, cursor}`.

- Trigger: Navarch is `:idle`/`:docking`, queue empty, at a rebellion-owned
  system, and has empty tiles relative to its blueprint. If it has **no**
  ships and is not at an owned system, enqueue a move-only path home first.
- Every 5 ut (per-Navarch timer advanced from `elapsed_time`): take the next
  `{tile, ship_key}` of the blueprint that is not filled and
  `Game.call(iid, :character, cid, {:order_ship, {nil, tile, ship_key, nil}})`
  then `Game.cast(iid, :character, cid, {:put_ship, tile, initial_xp})` — the
  `Sim.Fleet.build/2` path; no production, credits, tech, patents or shipyard
  involved. `initial_xp` = 0, or the tier's ship level when
  `"ship_level_by_tier"` (difficulty lever; ship level scales strikes +1%/lvl
  and hull handling, `lib/game/fight/ship.ex:31`).
- Complete ⇒ role released; stance set once per Navarch
  (`{:update_reaction, cid, :attack_enemies}` — Interdiction; `:flee` while
  retreating).
- Losses: wounded fleets (`army_health < retreat_hull`) get a move-only path
  to the nearest owned system and re-enter construction there. Ship
  destruction empties the tile; construction refills it from the blueprint.
- A blueprint is chosen at Navarch spawn by role (defense roles →
  `:defense`/`:intercept` blueprints, offense → `:raid_*`), from the tiers the
  rebellion has unlocked (§7.3). When a Navarch's blueprint is deprecated by a
  tier change it finishes the current one; the next rebuild (after losses)
  re-picks.

### 5.7 Training pool

`Wave.Training`: an entry below its range is tagged `:training`; if it is
outside `home_sector_ids` it receives a move-only path to the capital (or
nearest home-sector owned system). Each tick the Warlord casts
`{:add_experience, 0.1 × elapsed_ut}` to every trainee's character agent
(`Instance.Character.Agent.on_cast({:add_experience, amount}, …)`, the
Training Center hook). Level-ups add a skill point weighted 8/5/1 toward the
character's specializations (`Character.add_skill_point/2`), so with
non-governor `spec1/spec2` most points land where they count. When
`sum(take(skills,3)) >= lo`, the agent leaves the pool and is re-assigned.

---

## 6. Targeting library

All pure functions over a `%Wave.View{}`; unit-tested with hand-built
`Instance.Galaxy.Galaxy` structs (`Test.FleetScenario` builders).

### 6.1 `Wave.Geometry`

Inputs: `galaxy.sectors` (`owner`, `adjacent`, `division`, `starter?`),
`galaxy.stellar_systems` (`faction`, `status`, `sector_id`), the two faction
keys `r` (rebellion) and `h` (human).

Definitions (all recomputed per tick; ownership only changes on claims):

- `held(s, f)` = count of inhabited systems (`class != nil`) in sector `s`
  with `faction == f` (the same rule `Sector.update_owner/2` uses).
- `contested?(s)` = `held(s, r) > 0 and held(s, h) > 0`.
- Sector class for `r`:
  - `:core` — `owner == r`, not contested, every adjacent sector `owner == r`;
  - `:border` — `owner == r` and (contested or any adjacent sector `owner != r`);
  - `:frontier` — `owner == nil` and adjacent to a sector with `owner == r`;
  - `:enemy_border` — `owner == h` and (contested or adjacent to a non-`h` sector);
  - `:enemy_interior` — `owner == h`, all adjacent `owner == h`;
  - `:far` — everything else.
- `depth(s)` for human sectors = BFS distance over `adjacent` from the nearest
  sector with `owner != h` (0 = enemy_border).
- `posts(view)`: `border_posts` = rebellion systems in `:border` sectors,
  sorted by number of adjacent non-rebellion sectors desc, then by proximity
  to the nearest human system; `core_posts` = rebellion systems in `:core`
  sectors, capital first. With one rebellion sector, `core_posts` falls back
  to the capital.
- Human targets: `frontline_targets` = human systems in `:enemy_border`
  sectors (depth 0) plus systems in contested sectors; `deep_targets` =
  human systems with depth ≥ 1, each with weight `0.5^depth`.

### 6.2 `Wave.Nav` (ported + extended)

- `path_hops(galaxy, from, to)` — BFS hop pairs (branch code).
- `travel_ut(galaxy, from, to, movement_factor)` — Dijkstra over
  `galaxy.edges` weights × factor; used to break ties by real distance and to
  estimate arrival for the "distribute by distance" rules.
- Adjacency is built once per tick and cached in the view (`galaxy.edges` is
  flat; BFS per agent over 6k systems is fine at a 5-minute cadence but do not
  rebuild the map per call).

### 6.3 Legality filters (code, never tree data)

Every terminal action re-checks the engine's own preconditions so orders are
not silently dropped (`ActionImpl.pre_validate_action/2` swallows throws and
`Act` cannot see it):

- `make_dominion`: speaker not on cooldown (`Speaker.locked?`), rebellion
  `available_dominion_slot?`, target status in `[:inhabited_neutral, :inhabited_dominion]`,
  `{:check_system_takeability, id, r} == {:ok, :takeable}`, not own.
- `loot`/`raid`: Navarch has ships, target inhabited, not own, `siege == nil`,
  no duplicate of the same action queued.
- `conversion`/`assassination`/`sabotage`: target character currently in the
  target system (re-read on arrival — the tree runs again when the agent is
  idle in place; the terminal action is issued only when the agent is
  **already** in the target system, so travel and attempt are two decisions).
- `infiltrate`: target inhabited; no duplicate queued.
- Every itinerary is one `add_character_actions` push: hop jumps + terminal
  action, with `data.target` equal to the queue's `virtual_position` after the
  hops (strict chaining). After the push, read back
  `{:get_character_state, cid}`; if the queue is shorter than pushed, count a
  refusal and let the next tick retry.
- Reserved targets: a per-tick `MapSet` of systems/characters already
  claimed by another agent this tick (stacking allowed only for
  `encourage_hate` and for wreckers in the same fleet-rich system).

### 6.4 `Wave.Intel` — chance classes

Mirror of `Core.Dice` (`lib/game/core/dice.ex`) and the client preview
(`front/src/game/components/galaxy/system/ActionOverview.vue:56-67`):

```
ratio = attacker / (attacker + defender)   (0.5 when both 0)
lo    = max(ratio - 0.20 + 0.01 * min(level, 20), 0)
hi    = min(ratio + 0.20, 1)
class = cond do hi <= 0.5 -> :fail; lo >= 0.5 -> :success; true -> :mixed end
midpoint = (lo + hi) / 2
```

Inputs per action (from the action modules):

| Action | attacker | defender | "known" when rebellion visibility of the target system is… |
|---|---|---|---|
| `assassination` | `spy.assassination_coef.value` | `target.protection` (+ `system.counter_intelligence.value` if the target's faction owns the system) | ≥ 5 for `protection` (`StellarSystem.Character.obfuscate/2`), ≥ 4 for CI |
| `sabotage` | `spy.sabotage_coef.value` | same as above | same |
| `conversion` | `speaker.conversion_coef.value` | `max(target.determination (+ system.happiness if same faction as owner), 0)` | ≥ 4 determination, ≥ 3 happiness |
| `infiltrate` | `spy.infiltrate_coef.value` | `system.counter_intelligence.value` | ≥ 4 |
| `encourage_hate`, `make_dominion` | speaker coef | `max(system.happiness.value, 0)` | ≥ 3 |
| `loot`/`raid` | `army.raid_coef.value` | `system.defense.value` | ≥ 2 |

Visibility = `Instance.Faction.Faction.resolve_system_visibility(faction_state, system).value`
using the rebellion's faction state (`Game.call(iid, :faction, r_id, :get_state)`,
read once per tick) and the full system state. Unknown ⇒ `:unknown`. The
Erased daily gates consume the class; Navarch and Siderian roles use the
class only for ordering ties (not requested as a gate) — knob
`erased_only_gating: true`.

### 6.5 Erased daily distribution

`Wave.Actions.Erased.plan_removals(view, removers, rolls)`:

1. candidates = visible human characters (`system.characters` for systems
   with visibility ≥ 2; governors from `system.governor` on
   `governors_allowed` days; undercover Erased excluded).
2. class + gate per candidate per day (rolls cached in
   `warlord.daily[day_index][candidate_id]` so a target is decided once per
   day, not per tick).
3. sort by midpoint desc; assign round-robin to removers sorted by
   `travel_ut` to the candidate; each remover gets at most one target per
   day; a remover already travelling keeps its target.

Same planner for saboteurs with `target.type == :admiral` and the "fleet
within one hop of the agent" override applied first.

### 6.6 Roaming

When a role has no legal target: Siderians in seduce mode and Erased
removers/wreckers move to the nearest human system with the highest
`population` among those with visibility < 5 (explore + get visibility), else
to the nearest frontline human system; guards patrol between `border_posts`.
Roaming is a move-only itinerary of at most 3 hops per decision.

---

## 7. Fleet blueprint pool

### 7.1 Data shape (`priv/data/wave/blueprints.json`)

```json
{ "generated_at": 1780000000, "speed": "slow",
  "blueprints": [
    { "id": "bp_9f3a…",
      "slots": [[1,"fighter_4v2",0],[2,"fighter_4v2",0],[4,"corvette_1",0]],
      "counts": {"fighter_4v2": 2, "corvette_1": 1},
      "patents": ["shipyard_1","fighter_2","fighter_4","merge_fighter_1","shipyard_2","corvette_1"],
      "tier": 4,
      "roles": ["raid"],
      "evidence": {"pillages": 3, "bombards": 1, "fights_won": 2, "fights_survived": 4},
      "score": {"margin": 0.31, "win_rate": 0.7, "bomb": 24.0, "credit": 61400},
      "sources": [{"instance_id": 121, "event": "loot", "id": 88123}]
    } ] }
```

Tile positions are kept: `Fight.Army.get_ready_ships/2` commits one line of
three tiles every two turns, so tiles 1–3 are the vanguard and 16–18 arrive
around turn 11. Two fleets with the same counts and different layouts are
different designs. `patents` = `Sim.Cost.required_patents(slots)`; `tier` =
the lowest ladder tier whose cumulative patent set covers `patents`.

### 7.2 Mining (`Wave.Blueprints.Miner`, `mix wave.mine_blueprints`)

Run against a **locally restored production backup** (`db-restore.sh`),
never the live DB. Filter instances with `game_data->>'speed' = 'slow'`
(knob `--speeds`). Sources, in order of value:

1. `player_report` (`type = 'fight'`): `report::json -> initial.attackers[] / defenders[]`
   carry both sides' full 18-tile armies (`army.tiles[].ship.{key,level,units[].hull}`);
   `metadata::json ->> 'result'` is the owning player's status
   (`victorious | dead | fleeing`). One row per participating player; take
   the winner's side as `fights_won`, `fleeing` survivors with ≥ 50% hull as
   `fights_survived`.
2. `player_events` (`type = 'box'`, `key IN ('loot','raid')`,
   `data->>'side' = 'attacker'`, `outcome IN ('normal_success','critical_success')`):
   `data -> 'admiral' -> 'current' -> 'army' -> 'tiles'` is the attacker's
   fleet (vis 5 on the attacker's own row; defender rows have `ship: null`).
   `loot` rows carry the amounts and `balance_of_power`.
3. Optional: the last snapshot ETF per finished instance
   (`instance_snapshots.name` → S3 `snapshots/<name>` or `priv/_storage/`,
   `:erlang.binary_to_term(_, [:safe])`): every `Instance.Character.Agent`
   state's `data.army.tiles` — "what people kept fielded".

Normalization: drop empty/planned tiles, keep `{tile, key, level}`, hash the
sorted slot list, merge evidence per hash, discard fleets with fewer than 4
ships or containing `transport_1`. Role tags: `raid` from loot/raid events
and fights won as attacker; `defense` from fights won as defender;
`intercept` from fights won as attacker with no siege in the same
`instance_event_log` window (best effort — fine to skip in v1). Score each
survivor offline with `Sim.Arena.matchup/3` against the tier's gauntlet
(`Sim.Blueprints.gauntlet_keys/1`) so the pool has a strength ordering.

### 7.3 Eligibility and deprecation

`Wave.Blueprints.eligible(pool, unlocked_patents, role)`:

- every `patent` ∈ `unlocked_patents`;
- **not deprecated**: no ship key in `slots` has an unlocked `merge_to`
  successor (`Data.Game.Ship.merge_to`, e.g. `fighter_1 → fighter_1v2` once
  `merge_fighter_1` is unlocked). Merge tiers have identical combat stats and
  2×/4×/8× the units, so deprecation is exactly "the pool moves to stronger
  fleets".
- If a role's eligible set is empty, **promote**: substitute each deprecated
  key with its highest unlocked successor in place and use that (tagged
  `promoted: true` in telemetry).

Pick: weighted by `score.margin` (defense/intercept) or `score.bomb`
(raid), with a `blueprint_mix` knob choosing among the top 3 so fleets vary.

### 7.4 Seed pool

Port `Sim.Blueprints` and run `mix sim.blueprints` once (appless, hours of
CPU; use `ERL_FLAGS="+S 4"`); convert its per-tier champions/counters into
`blueprints.seed.json` with roles `defense | intercept | raid` mapped from
the arena goals. The loader unions seed + mined pools and prefers mined
entries when both exist for a tier/role. Also carry the branch's two
hand-crafted `invasion_column_*` blueprints if conquest is enabled later.

---

## 8. Behavior-tree encoding

### 8.1 Engine generalization (small, in master files)

- Move the BT plumbing to `lib/game/bt/`: `Game.BT.Parser` (was
  `Instance.SystemAI.Parser` in `lib/game/util/parser.ex`),
  `Game.BT.TermParser`, and a new `Game.BT.Runner.run/3` that is
  `SystemAI.step/1` generalized: `run(tree, context, state)` → `{:ok, state}
  | {:error, reason}`, same action contract (`:succeed | :fail |
  {:succeed, map} | {:done, state} | {:error, reason}`). `SystemAI` delegates.
  Keep module aliases so `mix extract_actions` and the tests still resolve.
- Add a **step budget** to the runner (e.g. 500 steps → `{:error, :bt_runaway}`)
  so a root-fail loop can never hang a process again; log the tree name.
- Delete or implement the dead editor node types (`wait`, `log`, `error`,
  `succeed_rate`, `done` compile to a non-existent `BT.Actions` module and
  crash at step time). Implement `Game.BT.Actions` with those five so trees
  authored in the editor work.
- Keyed loading: `Game.BT.Trees.load(spec)` returns `%{key => Node}` from a
  keyword config; galaxy holds the dominion pair (§4.3), the Warlord holds
  the wave trio (parsed once at init; the JSON is data, not snapshot state —
  do not store parsed nodes in the snapshot, reload on restore).
- Randomness stays **in actions** via the instance rand agent
  (`Game.call(iid, :rand, :master, {:uniform})`), never the library's
  `random`/`random_weighted` nodes (they use the process PRNG and break
  determinism and the `FakeRand` test recipe).

### 8.2 Tree evaluation contract for agents

`Wave.Trees.decide(tree, view, entry, warlord)`:

- `context` (the blackboard): `%{view:, agent:, entry:, role:, r:, h:, geometry:, intel:, rolls:, reserved:}`
  plus whatever actions merge in via `{:succeed, map}` (e.g. `bucket`,
  `target`, `hops`).
- `state` (mutated only by terminal actions): `%Wave.Decision{orders: [], reserve: [], note: nil}`.
- Terminal actions return `{:done, %Wave.Decision{}}`; the Warlord executes
  `orders` through `Wave.Bot.Act`, merges `reserve` into the tick's reserved
  set, and records `note` in telemetry.
- Non-terminal actions are conditions (`:succeed | :fail`) or choosers
  (`{:succeed, %{target: id}}`). Weights are **tree arguments**, e.g.
  `Wave.Actions.Siderian.pick_capture_target(80, 15, 5)`, so designers tune
  them in JSON without code changes.

### 8.3 Tree sketches (authored in `priv/data/wave/*.json`)

**navarch.json**
```
select
├─ sequence[ Common.role_is?(:training) ; Common.go_home() ]
├─ sequence[ Navarch.wounded?() ; Navarch.retreat_home() ]
├─ sequence[ Navarch.construction_pending?() ; Navarch.construct_or_go_home() ]
├─ sequence[ Common.phase_is?(:spawn) ; Navarch.hold_post() ]
├─ sequence[ Common.role_in?([:defense_border, :defense_core]) ;
│            select[ sequence[ Navarch.siege_nearby?() ; Navarch.relieve_siege() ] ,
│                    Navarch.hold_post() ] ]
├─ sequence[ Common.role_is?(:offense_frontline) ; Navarch.pick_frontline_target() ;
│            Navarch.pick_sortie(70) ; Navarch.sortie() ]
├─ sequence[ Common.role_is?(:offense_deep) ; Navarch.pick_deep_target(0.5) ;
│            Navarch.pick_sortie(70) ; Navarch.sortie() ]
└─ Common.idle()
```

**siderian.json**
```
select
├─ sequence[ Common.role_is?(:training) ; Common.go_home() ]
├─ sequence[ Siderian.on_cooldown?() ; Common.idle() ]
├─ sequence[ Common.role_is?(:capture) ; Siderian.pick_capture_target(80, 15, 5) ; Siderian.travel_or_act("make_dominion") ]
├─ sequence[ Common.role_is?(:destabilize) ; Common.phase_is?(:assault) ; Siderian.pick_destabilize_target(80, 20) ; Siderian.travel_or_act("encourage_hate") ]
├─ sequence[ Common.role_is?(:seduce) ; Common.phase_is?(:assault) ;
│            select[ sequence[ Common.roll(50) ; Siderian.pick_governor_target() ] ,
│                    Siderian.pick_agent_target() ] ;
│            Siderian.travel_or_act("conversion") ]
├─ Common.roam()
└─ Common.idle()
```

**erased.json**
```
select
├─ sequence[ Common.role_is?(:training) ; Common.go_home() ]
├─ sequence[ Erased.fleet_within_one_hop?() ; Common.role_in?([:sabotage_wrecker, :sabotage_guard]) ;
│            Erased.attempt_gate("sabotage") ; Erased.travel_or_act("sabotage") ]
├─ sequence[ Common.role_is?(:infiltrate) ; Common.phase_is?(:assault) ; Erased.pick_infiltrate_target(75, 25) ; Erased.travel_or_act("infiltrate") ]
├─ sequence[ Common.role_is?(:remove) ; Common.phase_is?(:assault) ; Erased.assigned_removal_target?() ; Erased.travel_or_act("assassination") ]
├─ sequence[ Common.role_is?(:sabotage_wrecker) ; Common.phase_is?(:assault) ; Erased.pick_wrecker_station() ; Common.travel_only() ]
├─ sequence[ Common.role_is?(:sabotage_guard) ; Erased.pick_guard_station() ; Common.travel_only() ]
├─ Common.roam()
└─ Common.idle()
```

`travel_or_act(action)` is the key composite: if the agent is already in the
target system it emits the terminal action; otherwise it emits the hop
itinerary only (arrival makes the agent idle in place; the next tick re-runs
the tree, re-validates, and acts). Each action module lists its functions
with `@doc` so `mix extract_actions --actions-dir lib/wave/actions/` publishes
the palette for the editor.

---

## 9. Engine change checklist

**Must (mode does not work without):**

| File | Change |
|---|---|
| `lib/game/instance/manager.ex` | start `Wave.Warlord.Agent` in `do_init_from_model/4` for wave games; add to `@snapshot_allowed_modules`; cache `wave:`/`wave_config:` metadata |
| `lib/game/instance/mutators.ex`, `lib/game/instance/player/player.ex:1190`, `lib/data/game/mutator.ex` | faction-scoped mutators + `rebel_zeal`/`rebel_command` |
| `lib/game/instance/stellar_system/stellar_system.ex` | cadence per system, scheduler includes AI timer, `auto_actions` guard for bot `:inhabited_player`, tree key selection, `:player_update` tag |
| `lib/game/system_ai/*`, `lib/game/util/parser.ex`, `config/config.exs` | keyed tree registry; `Wave.SystemAI` actions; upgrade-category fix; runner step budget |
| `lib/game/instance/galaxy/galaxy.ex`, `galaxy/agent.ex` | tree map + `{:get_behavior_tree, key}` |
| `lib/game/instance/character/action_queue.ex`, `character/character.ex` | port stale-lock self-heal (`9ac5be8`) |
| `lib/game/instance/character/actions/{conquest,loot,raid}.ex` | verify/port abort-on-interception-death |
| `lib/game/instance/victory/victory.ex` | wave-only equal `player_count` weighting |
| `lib/rc/instances/instance.ex`, `lib/rc/instances.ex`, migration | `bot_faction` column + validation (ported) |
| `lib/portal/controllers/registration_controller.ex`, `lib/portal/views/instance_view.ex` | `:bot_faction_locked`, expose `bot_faction` (ported) |
| `lib/portal/channels/controllers/global_channel.ex` | `instanceInfo.wave` |
| `lib/rc/profile_stats.ex` | exclude `"wave"` like `"daily"` |
| `lib/game/core/tick.ex` | runtime `SPEEDUP` (ported) |

**Should (quality/hardening):** `Instance.Rand.Safe`, market
`generate_character` rescue, `Galaxy.get_initial_system/3` nil-safety,
`Player.Agent :claim_initial_system` guard, `build_workforce` bug fix (after
confirmation), `Game.BT.Actions` for the editor's built-in nodes, BT module
relocation.

---

## 10. Frontend

- `front/src/portal/pages/play/New.vue`: game mode radio gains `wave`
  (visible on `slow` scenarios; the `canBeRanked` forcing to `casual` at
  lines 334-336 must not override it), human/rebellion faction selects
  (rebellion select = ported `bot_faction` select), a difficulty preset
  (maps to `game_data["wave"]` knobs). Ranked disabled.
- `front/src/portal/pages/Instance.vue`: rebellion faction card locked
  (ported), wave badge, "humans vs rebellion" copy.
- `front/src/portal/pages/Play.vue` + `router.js`: a `/play/wave` entry
  listing open wave games (model on `Legacy.vue`, not `Daily.vue` — this is
  lobby play).
- In game: `store.js` `instanceInfo.wave` → a small **Rebellion panel/banner**
  (wave index, next wave ETA, rebellion tech tier, roster counts if the
  design wants them visible; at minimum wave index + ETA). Ticker already
  shows `wave.started` news.
- Locales: `page.play.new.game_mode_types.wave`, `page.play.wave.*`,
  `page.instance.bot_faction_*` (ported), `game.wave.*`, and
  `data.mutator.rebel_zeal/rebel_command` names in `en/fr/de`.

---

## 11. Testing and tuning

- **Pure units** (fast, `async: true`): `Wave.Recruit.range/2` (the four
  worked examples + negatives + avg 0), `Wave.Schedule` (roster/tier tables),
  `Wave.Geometry` (hand-built 4-sector galaxies: core/border/frontier/enemy
  depth), `Wave.Intel.chance_class/…` against the Dice band, `Wave.Blueprints`
  eligibility/deprecation/promotion, `Wave.Roles` largest-remainder targets
  and deficit assignment with hysteresis, faction-scoped `bonus_entries/2`.
- **Tree units**: the `unique_building_filter_test.exs` recipe — parse the
  JSON, register a fake galaxy `:get_behavior_tree`, use
  `Test.FleetScenario.spawn_fake_rand/2` (`uniform_value`, `random_index`) to
  steer bucket rolls, assert the emitted `%Wave.Decision{orders: …}`. One
  test per role per branch, plus a "no legal target ⇒ idle, never loops" test
  for each tree and for `Rebel Dominion` (the runner step budget turns a hang
  into a failure).
- **Instance boot test** (`test/wave/boot_test.exs`, DB, `async: false`):
  build a 2-faction Legacy `game_data` from `test/support/scenario_game_data.json`
  (or port `Headless.Scenario.generate/1` as `Test.WaveMap` for a 4-band
  30-system map), run `Wave.Boot`, assert the Warlord is registered, the bot
  player is active, `rebel_zeal` is on the rebellion's system and not on the
  human's, and a `{:debug, :force_phase, :assault}` call followed by a
  `{:debug, :tick, 10}` call produces recruits and orders (debug handlers are
  compiled only when `Mix.env() in [:dev, :test]`).
- **Soak** (`mix wave.soak --days N --speedup 40`): dev container, runtime
  `SPEEDUP` + `{:cheat_set_speedup, 50}` (both multiply the factor), Legacy
  content, an idle human faction (systems still grow), prints per-wave
  telemetry: recruits by type, orders ok/refused by kind, pillage credit
  taken, dominions captured, agents removed, bankruptcies avoided, BT step
  counts. This is the tuning loop for the knob defaults; run it before the
  first human playtest. At 50× a 3-day spawn phase is ~1.7 real hours.
- **E2E** (`bin/e2e.ps1`): create a wave game from the UI, join the human
  faction, verify the rebellion card is locked, start, see the wave banner.

All Elixir tests run through `docker compose exec` (host Elixir is
forbidden); chown new host-created files to `rc` first; read
`.dev-ports.json` before touching the app.

---

## 12. Implementation phases (hand-offs)

Each phase lands as its own branch off `master` (follow-ups never stack on a
merged branch), with tests, and updates this doc's status line.

**Phase 0 — Foundations port.** Port from the game-AI branch: `bot_faction`
migration/schema/validation/lock/view, `Wave.Bot.Act`, `Wave.Nav`,
`Wave.View`, stale-lock self-heal, interception-death abort (verify first),
runtime `SPEEDUP`, `Sim.Blueprints` + task, hardening items. Generalize the
BT runner with a step budget and keyed loading; implement `Game.BT.Actions`.
*Accept:* existing suites green; `mix sim.blueprints --tiers t1_scouts --gens 1`
runs; a tree with an unconditional root fail returns `{:error, :bt_runaway}`.

**Phase 1 — Lifecycle skeleton.** `Wave`, `Wave.Config`, `Wave.Boot`
(game_data preparation, sector rewrite, rebellion profile, registration on
publish), manager metadata + Warlord `Core.TickServer` with phases and
telemetry only (no roles yet), victory weighting, `instanceInfo.wave`,
profile-stats exclusion, harness status endpoint `GET /api/harness/wave/:iid/status`.
*Accept:* boot test passes; instance survives `:make_snapshot` → restore with
the Warlord intact; pausing the instance freezes Warlord timers.

**Phase 2 — Rebellion economy.** Faction-scoped mutators, `rebel_zeal`,
`rebel_command`, solvency guard, `behavior_tree_wave.json`, keyed tree
registry, cadence/scheduler/guard changes, upgrade-category action, infra
upgrade eligibility, (confirmed) `build_workforce` fix.
*Accept:* rebellion system shows ×2.5 production detail; a saturated
rebellion system upgrades instead of freezing; vanilla `"Dominion"` tests
unchanged; human systems unaffected.

**Phase 3 — Recruitment and construction.** `Wave.Recruit`, `Wave.Roles`,
`Wave.Schedule`, `Wave.Training`, `Wave.Blueprints` loader with the seed
pool, `Wave.Construction`. Agents spawn, get roles, Navarchs fill their
blueprints one ship per 5 ut, trainees drip XP and go home.
*Accept:* soak shows roster tracking the schedule, blueprints completing,
review moving under-range agents to training and back.

**Phase 4 — Targeting library.** `Wave.Geometry`, `Wave.Intel`, `Wave.Nav`
travel time, reserved-target bookkeeping, legality filters. Pure + tested.

**Phase 5 — Navarch trees.** `navarch.json`, `Wave.Actions.Navarch`,
posts, siege relief, frontline/deep sorties, pillage/bombard roll, retreat.
*Accept:* soak shows sorties landing with `loot`/`raid` outcomes in
`player_events`, defenders parked on border posts, wounded fleets returning.

**Phase 6 — Siderian trees.** `siderian.json`, capture buckets, destabilize,
seduce modes, cooldown handling, roaming.

**Phase 7 — Erased trees.** `erased.json`, daily rolls, chance gating,
removal distribution, wreckers/guards, infiltrate buckets.

**Phase 8 — Blueprint mining.** `Wave.Blueprints.Miner`, `mix wave.mine_blueprints`,
run against a restored backup, commit `blueprints.json`, offline scoring,
loader union rules, tier catch-up signal.

**Phase 9 — Frontend, docs, tuning.** New/Instance/Play pages, in-game
banner, locales, `docs/wave-defense.md` status, memory note, first soak-tuned
knob defaults, then a human playtest instance.

Dependencies: 0 → 1 → 2 and 3 (parallel) → 4 → 5/6/7 (parallel) → 8 (any
time after 3) → 9.

---

## 13. Decisions taken (⚑ = confirm with the user if it matters)

1. Recruits are **synthesized** in range by default; market purchase is an
   option. ⚑ (The spec says "attempt to purchase from the market"; synthesis
   is deterministic and does not drain the humans' market.)
2. Ships are **materialized** directly (order_ship + put_ship on the
   character agent), never produced; the rebellion economy does not gate
   fleets. Consistent with "simulate their construction".
3. Role splits for Siderian (40/30/30) and Erased (40/30/30) ⚑ — not in the
   spec.
4. Roster and tech-tier schedules as in §3.1 defaults ⚑ — "increasing waves"
   needed numbers.
5. Sector bucket definitions in §6.1 ⚑ — the spec's "border" is read as
   either side's frontline; "internal" as rebellion interior.
6. Deep-strike weight `0.5^depth` ⚑.
7. Wounded threshold 35% hull ⚑.
8. Extra scenario factions' sectors become uncontrolled by default ⚑;
   option to hand them to the rebellion.
9. Victory weighting equalized for wave games ⚑; conquest thresholds and
   `win_points_target` remain scenario-controlled.
10. "Day" and "hour" in the spec are **real** time at Legacy (480 / 20 ut).
11. Single rebellion player with lifted caps (not N bot players).
12. Colonization, conquest and armadas are **out of v1** for the rebellion
    (Siderian capture is its expansion; Navarchs pillage/bombard only).
13. Blueprints are mined from Legacy games only by default ⚑.
14. Rebellion display name stays the catalog faction's name in v1; a
    per-instance "Rebellion" label is cosmetic follow-up ⚑.
15. Faction government is forced off for wave games.

---

## 14. Risks and mitigations

- **Silent order drops** (`pre_validate_action/2` swallows throws): every
  push is read back; refusals are counted per kind and surfaced in the
  harness status. Legality filters mirror engine checks.
- **Orchestrator round-trip loss** under many characters: the ported
  self-heal plus the Warlord's own watchdog (an agent `:locked` for more than
  N ticks is logged; the self-heal recovers it).
- **Rand agent as a serialization point** at zero build cadence across a big
  rebellion: cache the tree per system agent; if profiling shows contention,
  give the wave tree a per-system `:rand` stream seeded from the instance
  seed + system id (determinism preserved).
- **Runaway trees**: runner step budget; anti-loop tests per tree.
- **Bankruptcy strike**: solvency guard; telemetry on top-ups.
- **Bot player restore**: `connected_clients` zeroed on restore → the Warlord
  re-issues `:connect` on `:start`; roster re-derived from engine state.
- **Human fairness perception**: ships and agents appear from nowhere; keep
  the ticker honest ("Rebellion reinforcements arrive at X") ⚑ and expose the
  wave index so escalation is legible.
- **Map dependence**: a scenario where the rebellion's start sector is not
  adjacent to anything the humans can reach yields a passive game; the
  create form should warn when the two start sectors are not within 2
  sector hops (computable from `game_data["sectors"]` polygons with the same
  SAT adjacency the engine uses).

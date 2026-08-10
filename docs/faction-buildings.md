# Faction Buildings & System Build Slots

Status: foundation AND the gateway system (linking + portal travel)
implemented; Training Center XP drip and Cyber Command effects are
follow-up phases. Source: user design (July 2026), superseding the
older "gateway as player-built body building" sketch in
docs/faction-government.md §5.2.

## Concept

Every star system carries a small orbital **station**: a 2×2 grid of
**system build slots** (4 slots), rendered as a box in the top-left of
the system view. Unlike body tiles, these slots are managed **only by
the faction government** — cabinet seats order construction, the
faction treasury pays build costs and upkeep, and demolition is a
government act. Benefits apply to the system itself unless the
building says otherwise (sector-wide or faction-wide effects).

Some faction buildings span multiple slots (1×2, 2×2) — the first
multi-cell construction concept in the game.

## Rules

- Slots are interactable only while the system is **directly
  controlled by a player** (`:inhabited_player`) of the government's
  faction — dominions and neutral systems are read-only, exactly like
  body buildings.
- **Ordering**: the building's `seat` (`:military` / `:economy`) must
  order it; `seat_access/4` applies, so the Tetrarch's royal
  prerogative (overreach) works here too. The gating faction patent
  must be owned. Cost is debited from the treasury up front.
- **Construction** runs on a labor track *parallel to* the system's
  production queue: it advances at `production.value` points per ut but
  does **not** occupy or slow the player's own queue. (Decision: the
  government must never be able to clog a member's build queue.)
- **Cancel** refunds the full treasury cost. **Demolish** is instant
  and free (gateway link guards arrive with the link phase).
- **Upkeep** accrues per faction tick (`rate × elapsed ut`) against the
  treasury. If the treasury cannot cover the faction's whole station
  upkeep for the elapsed period, nothing is paid and every station
  building of that faction is **unpowered** (no benefits) until the
  treasury recovers — all-or-nothing for v1, surfaced with an event.
- **Capture/abandon**: buildings persist physically but become
  `:disabled` (no benefits, no upkeep, not usable by the captor —
  keyed to faction command codes). They re-enable automatically when a
  player of the owning faction regains direct control.
- **Visibility**: v1 exposes the station only at contact level 5 (own
  faction). Scouting foreign stations can come later.
- The whole feature inherits the Faction Government gate
  (`Government.enabled?/2`): Legacy + creation opt-in.

## Slot geometry

Slots are indexed row-major: `0 1` / `2 3`. A building's `shape` is
`%{cols, rows}`; placement is by **anchor** (top-left slot). Valid
anchors: 1×1 → any; 2×1 → 0 or 2; 1×2 (vertical) → 0 or 1; 2×2 → 0.
All covered slots must be free (built or under construction both
block).

## Data model

`Data.Game.FactionBuilding` (speed-independent content, like
`FactionPatent`):

```
key, seat (:military | :economy), patent (faction patent gate),
shape %{cols, rows}, unique (per system), effect (atom, dispatch
marker), levels [%{level, cost %{credit, technology, ideology},
labor, upkeep %{credit, technology, ideology}, bonus [%Core.Bonus{}]}]
```

Runtime state:

- `Instance.StellarSystem.Station` — new `:station` field on
  `StellarSystem` (snapshot-tolerant: all access via `Map.get`,
  lazily created). Holds `buildings` (`%{id, key, level, faction_id,
  slots, status: :built | :disabled}`), `construction` (`%{building_id,
  key, level, slots, total_labor, remaining_labor, kind}`), `powered`,
  `next_building_id`.
- `Government.station_buildings` — the billing registry:
  `[%{system_id, building_id, key, level, status}]`, kept in sync by
  system→faction casts on completion / status change / demolition.
  `Government.station_powered` tracks the all-or-nothing power state.

## The three buildings

| | Gateway | Training Center | Cyber Command |
|---|---|---|---|
| Seat | Military | Economy | Military |
| Shape | 2×2 (all four) | 2×1 | 2×2 |
| Levels | 1 | 5 | 1 |
| Cost L1 | 2M c / 75k t / 20k i | 300k c / 12k t / 10k i | 500k c / 25k t / 5k i (TBD) |
| Labor L1 | 256k (≈16h @ 800 prod) | 48k (≈6h @ 400 prod) | 100k (TBD) |
| Upkeep | 500 c + 50 t /ut | 100 c + 20 t + 30 i /ut | 200 c + 40 t /ut (TBD) |
| Patent | `gateway_theory` | `orbital_engineering` | `cyber_warfare_program` |
| Effect | paired portal travel | +1 XP per 12h per level to a random same-faction agent in-system | sector malware census |

"Malware" is the established flavor term for spy infiltration
contacts (see `remove_contact` / infiltration strings) — Cyber Command
periodically reconciles a noisy public count of enemy contacts across
its sector (every 6h: too low → +0..3, too high → −0..2; multiple
commands in a sector sum).

## Gateway system (implemented)

Authority model: **the government owns both the link records and the
transit lock** (`government.gateway_links`). All gateway use is
same-faction, so one serialized faction agent removes any need for
cross-system locking — two agents charging from opposite ends can
never both win. The systems' station buildings carry only a display
stamp (`link: %{status, target_system_id, busy}`), pushed by the
faction agent on every link event.

Link records: `%{id, endpoints: [%{system_id, building_id} ×2],
status: :linking | :linked | :unlinking, remaining, transit}` where
`transit` is `nil | %{character_id, phase: :charging | :jumping |
:wind_down, remaining}`.

- **Link** (Military rep, overreach applies): both gateways `:built`,
  neither already in a link. Forms over `gateway_link_time`, billed
  per ut (3000c + 500t) through the station-upkeep pool — if the
  treasury can't pay (all-or-nothing power-down), link formation and
  teardown PAUSE until it can. **Unlink**: one-time 150k c + 20k t,
  `gateway_unlink_time` of teardown; refused while forming or while
  any transit holds the pair. **Demolition** of a gateway is refused
  in any link state.
- **Transit** is a chained character action: `gateway_charge`
  (attackable in-system, non-idle so no interception pools, no recall)
  → charge-finish asks `{:gateway_begin_jump}` (the capture-race
  backstop) → `gateway_jump` (removed from the system, `system: nil` =
  untargetable; queue-clearing a running jump is refused — it would
  strand the traveler) → arrival + `{:gateway_begin_wind_down}` →
  `gateway_fatigue` (present, targetable, starts nothing, can't be
  recalled; fleet stance changes stay open). The pair stays locked for
  a government-side wind-down equal to the fatigue window — killing
  the arrived traveler does NOT shorten it. A `:charging` transit
  bills +250c +50t per ut.
- **Interruption releases the lock** (only a `:charging` transit ever
  releases): orders cleared, flee, fight death, assassination (both
  the kill branch and the fleet-survives-under-default-agent branch),
  seduction (routes through the assassinate step). A liveness sweep on
  the faction tick frees locks whose traveler process died without any
  hook firing. Capture of an endpoint breaks the link, aborts a
  charging traveler in place, and lets a mid-jump traveler land
  normally.
- A failed/aborted charge **stands down**: queue cleared and
  `virtual_position` repinned to the standing system (otherwise the
  stale target poisons every later order — the flee-path trap).
- **Portal arrival triggers interception exactly like a normal jump
  arrival** (user decision 2026-08-07): the finish reuses
  `Jump.arrival_interception/2`, so a hostile picket camping the exit
  gateway engages the arriving fleet under the standard defender-stance
  matrix. A traveler that dies or flees in the arrival battle takes no
  fatigue; the gateway pair winds down regardless.

Testing: `test/game/instance/faction/government_gateway_test.exs` (15
engine tests) + `bin/gateway-e2e.ps1` — a 21-check live scenario
(fixture: POST /api/harness/dev/gateway-fixture) covering the full
transit, per-phase interaction windows, busy locks on both ends,
cancellation on clear/kill, guards, and unlink/demolition. Dev
harness: gov-debug ops `gateway_link`/`gateway_unlink`, POST
`station-complete`, GET `char-status`, POST `char-op`.

## Gateway spec (user, verbatim intent — kept for reference)

- Link two gateways: 3000 c + 500 t per ut for 6h, then linked.
  Unlink: one-time 150k c + 20k t, takes 2h. Demolish free only when
  unlinked. Base upkeep applies linked or not.
- Portal travel (agent action chain): **charge** 6h (agent locked,
  still attackable in-system; gateway upkeep +250 c +50 t /ut) →
  **portal jump** 2h (agent untargetable, in transit; leaves the
  system like a jump) → arrival → **portal fatigue** 2h (agent can
  perform no actions; fleets may still change stances — no gate on
  `update_reaction`). The gateway pair is locked for the whole
  sequence plus a wind-down equal to the fatigue window.
- No unlink/demolish while any agent is charging/travelling/fatigued,
  while a link is forming, or while unlinking.

Implementation notes for that phase: model as a new character action
type (`portal_transit`) registered in `ActionImpl.@actions`;
"charging" keeps `system` set with a non-idle `action_status` (already
excluded from interception, still directly targetable); the jump leg
replicates `Jump.start`'s `remove_character` + `leave_system` for
untargetability, with `source_position`/`target_position` populated so
`Character.get_position/2` keeps working; fatigue mirrors the speaker
cooldown pattern (`pre_validate` throws + recall block) rather than
`on_strike` (which would wrongly block stance changes).

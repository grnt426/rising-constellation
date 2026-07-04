# Faction Government — implementation analysis & design proposals

Status: analysis / pre-design. Source: "TF Government" design doc (July 2026) +
full codebase survey. Scope: Legacy games only (`game_data["speed"] == "slow"`;
dailies use the `:daily` speed key so they are excluded automatically).

This document covers three things:

1. An implementation analysis of the government system as written — what the
   codebase already gives us, what must be built, and a proposed architecture.
2. A per-faction analysis, with particular attention to Cardan and ARK —
   where the written complexity is real, where it dissolves under the right
   abstraction and UI.
3. Proposals for the unwritten half: laws/policies, faction tech, faction
   lexes, and faction actions — anchored to the design constraint that
   government should *focus the faction toward victory* and *expand player
   agency*, with flat bonuses/maluses kept under half the content.

---

## 1. What the codebase already provides

The survey found that far more of the substrate exists than the design doc
assumes. The genuinely new subsystems are elections, roles, and diplomacy —
almost everything else is an extension of a proven pattern.

| Government need | Existing substrate | Where |
|---|---|---|
| Per-faction runtime state + broadcast | `Instance.Faction.Agent`, one per faction, already holds roster, chat, radar, icons, and participates in snapshot/restore | `lib/game/instance/faction/faction.ex:40`, `lib/game/instance/faction/agent.ex` |
| Faction treasury | `faction.market_taxes` is already a per-faction pooled `%Market{credit, technology, ideology}` of `DynamicValue`s — the treasury is a straight generalization | `lib/game/instance/faction/market.ex:17` |
| Tax hook on player income | All player income flows through one function, `Player.extract_bonus/2`, which already applies negative income (wages, fleet maintenance) — a tax rate slots in beside them | `lib/game/instance/player/player.ex:903-1033` |
| Atomic resource transfer | `send_resources` (player→player via faction, already taxed) + `{:try_debit_send, ...}` check-and-debit pattern | `lib/game/instance/faction/market.ex:44`, `lib/game/instance/player/agent.ex:234` |
| Faction tech tree | Player patent tree: ancestor-linked nodes, scaling costs, unlock lists — mirror it 1:1 at faction level, paid from treasury | `lib/data/game/patent.ex`, purchase at `player.ex:397` |
| Faction lex tree + active laws | Player doctrine/policy model: buy doctrines from a tree, activate a limited set as policies with an escalating cooldown — mirror it 1:1 | `lib/data/game/doctrine.ex`, `player.ex:426-523` |
| Faction-wide buffs/debuffs | The bonus pipeline (`Core.Bonus`, `from`/`to`/`add`/`mul`); faction traditions already inject faction-wide bonuses into every member's `extract_bonus` — lexes/tech use the same injection point | `lib/game/core/bonus.ex:38`, `player.ex:972-981` |
| Timed decaying debuffs ("-10 stability for 24h") | Happiness-penalty decay (per-tick reduction, auto-expiry) and `Core.CooldownValue` | `stellar_system.ex:733-747`, `lib/game/core/cooldown-value.ex` |
| Election timers | `Core.CooldownValue` on the faction tick — game-time based, so pauses and deploys don't eat election windows (Legacy factor = 1, so game time ≈ real time while running) | `lib/game/core/tick_server.ex` |
| Ranked voting (Tetrarchy) | Per-player scoreboard (`points`, production, systems) already recorded and broadcast | `lib/rc/instances/player_stat.ex`, `global_channel.ex:81` |
| Victory focus | Victory is three tracks — conquest (sectors), population, visibility — each 0/2/5/10 points, win at ≥14. These are *exactly* the axes a government should coordinate | `lib/game/instance/victory/victory.ex:268-350` |
| Government UI | Faction panel tab architecture, `ProfileCard`, patent/doctrine tree components, `Counter`/`CircleProgressValue` countdowns, full-screen overlay pattern for the election sub-panel | `front/src/game/components/panel/FactionPanel.vue`, `card/ProfileCard.vue`, `mini-panel/PatentMiniPanel.vue` |
| Audit trail | `faction_event_log` table with extensible `event_type` | `lib/rc/instances/faction_event_log.ex` |
| Per-viewer secrecy | FactionChannel already sanitizes broadcasts per recipient (used for `detected_objects`) — the same interception point keeps Cardan's secret offers secret | `faction_channel.ex:308-363` |

**What does not exist at all:**

- **Diplomacy.** No pacts, alliances, war state, treaties — zero references.
  The design doc gives the Leader "pacts, alliances, declare war" as their core
  power; that is an entire subsystem the doc implicitly assumes. See §4.
- **Roles/permissions.** `Instance.Faction.Player` is `{id, name}` — no
  leader, no seats, no permission gating anywhere.
- **Elections/voting** in any form.
- **Faction fleet / command transfer.** Armies are welded to an admiral
  character, characters to an owner. No delegation or transfer machinery.
- **Faction-level resource pool spending** (the pool exists as market taxes,
  but nothing spends it).

---

## 2. Proposed architecture

### 2.1 One ballot engine, five rule modules

The five faction designs look wildly different but reduce to one primitive:
**a ballot where voters attach a stake to a candidate**. What differs is the
currency, the weight function, and the failure/renewal rules:

| Faction | Stake currency | Weight | Quorum / failure | Renewal trigger |
|---|---|---|---|---|
| Tetrarchy | free vote | 3/2/1 by scoreboard third | none | deposition vote (same weights) |
| Myrmezir | free vote | 1 | none | fixed 7-day cycle |
| Synelle | free vote | 1 | simple majority approval | 11-day term, snap elections, ¾ crisis vote |
| Cardan | pledged ideology *income* (secret) | pledge size | sum ≥ 5% of faction ideology income, else re-vote at half length (min 24h) | loss-of-faith pledge ≥ 10% |
| ARK | escrowed credits (public) | bid size | none (highest sum wins; losers refunded, winner's sum → treasury) | bid-to-challenge protocol |

So the design is a generic election engine plus a behaviour:

```elixir
defmodule Instance.Faction.GovernmentRules do
  @callback seats() :: [:leader | :economy | :military]
  @callback ballot_kind(seat_or_event) :: :plurality | :approval | :stake
  @callback eligible?(player, seat, gov_state) :: boolean
  @callback nominate(...)         # who may put names forward
  @callback vote_weight(player, gov_state) :: weight_spec
  @callback stake_currency() :: nil | :ideology_income | :credit
  @callback quorum(ballot, faction_state) :: :met | :not_met
  @callback on_success(ballot, gov) :: gov      # seat filling, council appointment
  @callback on_failure(ballot, gov) :: gov      # Cardan re-vote, etc.
  @callback renewal_events(gov) :: [event]      # term expiry, deposition, challenge
  @callback acting_heads?(seat) :: boolean
end
```

with `Tetrarchy`, `Myrmezir`, `Synelle`, `Cardan`, `Ark` implementations.
Ballot lifecycle (open → collect → close → tally → apply/fail) is engine
code written once, driven by `CooldownValue` timers in the Faction tick.
This is the single most important structural decision: it converts "five
bespoke election systems" into "one engine + five parameter sets", and it is
what makes Cardan and ARK affordable (§3).

### 2.2 State placement and durability

- **Runtime state**: add a `:government` field to `Instance.Faction.Faction`
  holding `%Government{seats, council, active_ballots, treasury, tax_rates,
  active_lexes, faction_patents, stability_penalties, action_cooldowns}`.
  The Faction.Agent already snapshots, so government state survives deploys
  for free. **Snapshot tolerance is mandatory**: existing Legacy games will
  restore Faction structs without the new field, so all access must go
  through `Map.get`/back-fill at the agent boundary (this bit us before —
  see the snapshot-tolerant-fields convention).
- **DB journal as source of truth for ballots**: crash recovery restores
  agents from the last periodic snapshot (≤5 min old), and votes/stakes are
  exactly the kind of thing players will dispute. Journal every ballot
  action to Postgres (`faction_elections`, `faction_votes` tables), treat
  agent state as a cache, and re-tally from the journal on restore. This
  also gives the audit trail. Stakes (ARK bids, Cardan pledges) get a DB
  row at escrow time for the same reason.
- **Keep government state out of Player.Agent.** A Player.Agent crash
  reverts that player to genesis state (known failure mode); anything
  government-related stored there would be silently wiped. Escrow and
  pledge records live at faction level + DB only.
- **Secrecy**: Cardan offers and interim sums never leave the server. The
  channel broadcast carries only `quorum_met: true/false`. The existing
  Jason-encoder field exclusion + per-viewer `handle_out` sanitization
  pattern covers this.

### 2.3 Treasury and taxes

- Generalize `market_taxes` into `Government.treasury` (same
  `DynamicValue` triple). Market taxes flow into it; election proceeds
  (ARK) flow into it; income taxes flow into it.
- Tax hook: in `Player.extract_bonus/2`, after income bonuses are
  assembled, apply the faction tax rate as a multiplicative reduction and
  cast the withheld amount to the Faction.Agent (async, mirroring the
  market's seller-credit pattern). Cardan's election tithe is *the same
  mechanism* — a temporary per-player negative income entry plus an even
  redistribution entry, both expiring after 72h. Building taxes and the
  tithe on one hook keeps them consistent and cheap.
- **Hard caps on tax rates by design** (see §5.1) — this is the main
  "don't punish dissenters" lever.
- Faction→player grants mirror `send_resources` with the treasury as
  sender (`{:try_debit_treasury, ...}` on the Faction.Agent, atomic).

### 2.4 Timing, liveness, and degenerate cases

- All durations (72h founding period, 48h elections, terms) run on game
  time via faction-tick cooldowns: pauses freeze them, deploys restore
  them. In Legacy (factor 1) game time ≈ wall time while running, which
  matches the doc's intent.
- **Officeholder absence**: a seat whose holder hasn't connected for N
  hours (say 72h, configurable) is flagged "vacant — by-election
  available"; any member can trigger the faction's renewal mechanism free
  of the usual cost. Without this, one player quitting soft-locks a
  faction's government for the rest of a months-long Legacy game. Presence
  is already tracked (Phoenix.Presence on the faction channel).
- **Nobody runs / nobody votes**: seats stay vacant; a vacant seat's powers
  are simply dormant (no taxes levied, no actions). Any member may trigger
  a by-election at any time while a seat is vacant. No caretaker
  auto-appointment — appointing an AFK player is worse than an empty
  chair.
- **Tiny factions**: if a faction has ≤3 active members, seats merge (one
  "Leader" holds all three portfolios; election elects one person). The ¾
  crisis-vote and top-5 rules all degrade gracefully once seats merge.
- **Bots**: Legacy instances can contain bots. v1: bots neither vote nor
  stand; all quorum percentages compute over human registrations. (A later
  pass can give bots simple ideology: vote for the top-scoring human.)

### 2.5 Phasing

| Phase | Contents | New risk |
|---|---|---|
| **1 — Government core** | Roles + permissions, ballot engine + 5 rule modules, election UI (panel + overlay), event-log extensions, treasury (fed by existing market taxes + ARK proceeds only) | Ballot engine correctness; snapshot back-fill |
| **2 — Economy** | Income tax (capped), faction→player grants, faction market offers, Cardan tithe mechanics on the tax hook, treasury UI | Economic balance |
| **3 — Trees & actions** | Faction lex tree + active-law slots, faction tech tree, faction actions with cooldowns, stability debuffs (Tetrarchy tyranny etc.) | Content balance |
| **4 — Big-ticket content** | Gateways, SLSD command uplink, Siderian concordat, battle-plan map layer, faction fleet (delegation model) | Map/combat balance |
| **5 — Diplomacy** | Leader-driven pacts/war as its own feature (see §4) | Whole new subsystem |

Phase 1 is deliberately playable on its own: elections + roles + a treasury
that accrues from market taxes give factions something to fight over before
any of the spending content exists.

---

## 3. Per-faction analysis

### Tetrarchy (monarchy) — low complexity

Weighted plurality vote; weights 3/2/1 by scoreboard third (PlayerStat
`points`, computed at ballot open, frozen for the ballot); only the top 5
eligible for leader; leader appoints council freely. Deposition = same
ballot inverted. The tyranny mechanic ("Tetrarch acts as a council seat →
-10 faction stability for 24h") maps directly onto the decaying-penalty
pattern, surfaced as a multiplicative malus on member income via the bonus
pipeline. Nothing here strains the engine. One design note: freeze the
voter-weight snapshot at ballot open, or late scoreboard swings mid-vote
change already-cast weights.

### Myrmezir (democracy) — low complexity, one design gap

Positional ballots (candidates file for one seat, plurality per seat),
7-day cycle, acting heads throughout. The doc's open TBD — "how can
Myrmezir feel more like a democracy?" — has a clean answer once faction
actions/lexes exist (§5): **make consequential government acts referendums**.
Concretely for Myrmezir: enacting/repealing a lex, changing tax rates, and
funding a gateway each require a 24h faction majority vote (the engine's
ballot primitive again, `ballot_kind :approval`), and any member can launch
a *citizen initiative* — propose a lex activation or faction action
directly, bypassing the cabinet, if they gather signatures from 20% of
members. That is direct democracy, mechanically distinct from Synelle's
"elect people and approve their appointments" representative flavor, and it
*adds* agency to every rank-and-file Myrmezir player, which is precisely
the design constraint. The cabinet remains the executor (and tie-breaker),
so seats still matter.

### Synelle (republic) — medium complexity, engine-friendly

Nomination → leader vote → leader nominates cabinet → approval votes; 11-day
terms; snap elections in both directions; ¾ crisis vote. This is the most
*states* of any faction but every state is an engine ballot with different
`on_success` wiring. The snap-election rules ("leader dissolves cabinet" /
"both cabinet members agree to dissolve leader") are just renewal events
with role-gated triggers. Fully covered by the behaviour; no simplification
needed.

**Cabinet approval rules (decided, implemented):** each nomination runs a
**24-hour** approval vote that passes only when at least **half the
faction's active members** vote approve — silence counts against the
nominee, so an ignored nomination is a failed nomination. **Three
consecutive failed nominations dissolve the government**: the leadership is
deemed insolvent, the leader abdicates immediately, and a fresh leader
election opens. This bounds a cabinet-less republic to ~3 days instead of
the full 11-day term, and it is NOT too complex for players: the rank and
file only ever see "approve/reject within 24h" plus a strike counter on
rejections; the pressure lives entirely on the leader, which is the point.

*Known gap:* the three-strikes clock only arms when the leader actually
nominates — a leader who nominates **nobody** stalls indefinitely until
their 11-day term lapses. Proposed close (not yet implemented): a cabinet
seat left vacant with no pending approval vote for 24h counts as a failed
round. That preserves the same 3-day bound with no new UI.

### Cardan (theocracy) — the complexity is smaller than it reads

Written out, the tithe election sounds intricate. Reduced to mechanics, a
Cardan ballot is:

1. Nomination of *someone else* per seat (one engine rule).
2. Each voter secretly sets a **pledge slider**: "offer X% of my ideology
   income" toward a candidate.
3. Quorum check: Σ(pledged income) ≥ 5% of faction ideology income —
   surfaced to players *only* as a boolean lamp.
   > **Revised (implemented):** the boolean was promoted to a
   > **four-stage candle**: dark below ⅓ of the quorum, half-lit to ⅔,
   > guttering until met, aflame when the offering suffices. Built from
   > the Interception Tunnels glyph with a flame that only ignites at
   > quorum; hover gives the stage descriptor, no text or numbers. The
   > stage is bucketed server-side before broadcast, so exact sums still
   > never leave the agent — a deliberate, bounded relaxation of the
   > original secrecy rule in exchange for vote legibility.
4. On success: winner takes the seat; every pledger gets a 72h negative
   income modifier for what they offered, and the total is redistributed
   to all members evenly (72h positive modifier).
5. On failure: automatic re-vote at half duration, floor 24h.

Point 4 is the crucial realization: **the tithe is the tax mechanism**
(§2.3) — temporary income modifiers on the existing hook, not new economy
code. Point 3 is the existing per-viewer broadcast sanitization. The
"apparent complexity" of Cardan is almost entirely *description*
complexity; the player-facing UI is three elements: candidate cards, one
slider, one quorum lamp. I recommend implementing Cardan **as written**,
with two small trims:

- Cap consecutive failed re-votes (e.g. after 3 failures, the cheapest
  candidate set wins anyway or seats go vacant until someone re-triggers)
  so a checked-out faction doesn't ballot-spin forever.
- Redistribution "even split to all members" includes pledgers themselves
  (as written). Note the self-dealing shape: a whale pledging heavily gets
  1/N of their own tithe back — mildly progressive, fine as-is; just
  don't exempt pledgers from the split or small factions get weird.

The loss-of-faith vote (10% threshold, instant trigger when reached) is the
same ballot with a running-total quorum instead of a deadline — one more
`quorum` variant.

### ARK (oligarchy) — the election is easy; the challenge protocol is the outlier

The *election* is a public auction: escrowed credit bids per candidate,
highest sum wins, losers refunded, winning sum → treasury. That's a stake
ballot with a refund rule — engine-native, and thematically the founding
deposit of the faction treasury.

> **Revised (implemented): every seat is auctioned.** The original design
> had the winning bid elect only the leader, who then appointed the
> council — but a gifted chair isn't very oligarch. All three seats now
> run concurrent auctions (Executive, Board of Commerce, Industrial Arms
> Overseer), each winning pool banks to the treasury, and ARK has no
> appointment power at all. Open question: one player can currently win
> multiple auctions in the same cycle but the single-seat invariant keeps
> only the last-closed seat (earlier pools still bank) — decide whether
> multi-chair oligarchs should be allowed, blocked at bid time, or
> auto-refunded on the surplus win.

**Proposed govern mechanic — the Circle of Insiders (design only, needs
the treasury/actions phase):** the three sitting oligarchs may freely
perform each other's role actions *for a fee*. Executing another head's
action costs **2% of max(government treasury, faction-wide credit
total)**, paid into the government treasury; executing an action of the
Executive costs **4%**. No permission is asked and none is needed — the
fee IS the authorization. This turns the government into a circle of
insiders acting semi-independently, semi-cooperatively: any oligarch can
move on any front if they judge it worth the price, the price scales with
the faction's wealth so it stays meaningful all game, and every
cross-role act enriches the treasury the next challenger will fight
over. Pairs naturally with the bid-to-challenge protocol (a treasury
fattened by fees is a bigger prize and a bigger war chest).

The **bid-to-challenge** protocol is the one genuinely stateful, multi-turn,
poker-like mechanic in the whole document: challenge stake ≥0.5% of faction
total credit → oligarchs match (personal or, first round only, government
funds) → challenger raises (doubles) or withdraws (10% penalty, 72h
lockout; auto-withdraw if insufficient funds) → oligarchs must now match
from pooled personal funds → failure/forfeit = deposed, challenger seeds
the new election with 1.5× their bid as vote strength, oligarchs lose 20%
to treasury...

Assessment: it *is* implementable (it's a small explicit state machine with
timers, and the engine's DB-journaled ballots give it durability), and it
is thematically excellent. But it is the highest defect-surface-per-player-
minute item in the doc: many terminal states, escrow in flight across
multiple players, timeout behavior on both sides, and an interaction
(1.5× vote-strength seeding) that couples it back into the election. Two
options:

- **Option A — ship it as written, as a wizard.** The complexity is
  *sequential*, which UI handles well: a 3-step guided flow (Stake →
  Response → Raise/Withdraw) where every button shows its consequence
  before commit ("Raise to 2.0% — if the oligarchs fail to match within
  24h, government falls and your 1.5× stake leads the new vote" /
  "Withdraw — lose 10% of stake, locked out 72h"). Each side always has
  exactly one decision pending with a countdown; there is never a screen
  with more than two buttons. Written complexity dissolves; *implementation*
  complexity remains.
- **Option B — v1 simplification: single-round sealed match.** Challenger
  stakes ≥0.5% of faction credit. Oligarchs get 24h to collectively match
  1:1 (personal funds; government funds allowed once per real-time week).
  Matched → challenger loses 10% to treasury, 72h lockout. Unmatched →
  deposed, oligarchs lose 20% of the shortfall-adjusted stake, challenger
  seeds the new election at 1.5×. This keeps the economic brinkmanship
  ("how much is the throne worth to you?") and every penalty number from
  the doc, drops only the raise-doubling loop, and cuts the state machine
  from ~9 states to 4. The raise loop can be layered on later without
  schema changes because ballots are journaled events.

Recommendation: **Option B for the first release, Option A as a fast
follow** once the engine has soaked in production. The doc's own
anti-spam rule (government funds only on the first challenge) signals the
designer already worries about the loop's abuse surface — the sealed match
sidesteps most of it.

### Seat titles

Decided (implemented as i18n; trivially changeable):

| Faction | Leader | Economy | Military |
|---|---|---|---|
| Tetrarchy | Tetrarch | Quaestor | Strategos |
| Myrmezir | President | Economic Advisor | Department of Defense |
| Synelle | President | Interior Ministry | Foreign Affairs |
| ARK | Executive | Board of Commerce | Industrial Arms Overseer |
| Cardan | Eminence *(provisional)* | Circle of the Golden Palm | Circle of the Iron Palm *(provisional)* |

Cardan rationale (lore: the Siderian Order codifies every gesture;
secretive, hierarchical, fanatically anti-abolitionist but not
technophobic): **Eminence** reads as the éminence grise — the shadow
power behind a throne — without leaning monastic; the **Golden Palm**
keeps the requested left-hand-of-the-king money flavor and lands on the
gesture-codification lore; the **Iron Palm** mirrors it for war, giving
the two councillors a paired-hands identity beneath the Eminence.
Alternatives considered for military if Iron Palm feels too matched:
*Warden of the Flame* (ties the candle/offering motif), *Sword of the
Tenets* (fanaticism of the Order). Leader alternatives: *Hierarch*,
*Voice of the Order*.

### Cross-faction note

Cardan and ARK being "stake ballots" and Tetrarchy being a "weighted
ballot" means the *interesting* mechanical diversity survives any
simplification: each faction's election couples to a different resource
(rank, ideology income, credit) and therefore creates different in-faction
politics. That's the part worth protecting; the raise-loop and re-vote
minutiae are not where the flavor lives.

---

## 4. The diplomacy gap

The Leader's headline power — "set pacts, alliances or declare war" — has
no substrate: there is no diplomatic state between factions anywhere in the
engine, and combat/interception is permanently all-against-all. Building
real diplomacy (relation state, mechanical teeth like interception rules or
market access, victory interactions, UI on both sides) is a feature the
size of the government system itself.

Recommendation: **decouple it.** In v1 the Leader gets:

- **Declarations** (war/hostility/neutrality per rival faction): stored in
  government state, broadcast, shown on faction panels and map overlays,
  logged. No hard mechanical enforcement yet — but wire them into *faction*
  content: e.g. some lexes/actions read the declared stance ("Mobilization
  is cheaper against factions we've declared war on"). This gives
  declarations teeth without a diplomacy engine, and gives Myrmezir's
  "diplomatic actions require a faction vote" rule something real to vote
  on.
- Council management, focus directives (§5.3), lex proposals — the powers
  that already have substrate.

Full pacts (non-aggression with enforcement, shared-vision treaties,
market access between factions) become Phase 5, designed once government
has shipped and the cross-faction politics it creates are observable.

---

## 5. Proposals: laws, faction tech, faction lexes, faction actions

Framing that keeps everything coherent with the existing game: **the
faction government is the player economy, one level up.** Players buy
patents with technology and doctrines with ideology, then slot a limited
set of doctrines as active policies. The faction buys *faction patents*
with treasury technology and *faction lexes* with treasury ideology, then
the government slots a limited number of lexes as **active laws** (with an
escalating change cooldown — which is exactly what the doc's "Tetrarchy
faction policies cooldown -10%" trait presupposes). Faction *actions* are
one-shot abilities with treasury cost + cooldown, gated by seat. All four
reuse shipped models (patent tree, doctrine tree, policy slots, character
action cooldowns).

The design constraint: ≤50% flat bonuses. The inventory below is roughly
70% agency/coordination mechanics, 30% flat — each entry is tagged.

### 5.0 Implemented Phase 2 slice (taxes, treasury, first trees)

Now live behind the same Legacy gate as elections:

- **Income taxes**: the Head of Economy sets per-resource rates, hard
  engine-capped at `government_tax_cap` (10%). Applied in the player
  bonus pipeline as an honest ×(1 − rate) entry (visible in income
  tooltips with a `{:government, :tax}` reason), withheld only from
  POSITIVE income, accumulated player-side and remitted to the treasury
  on the stats interval. Every rate change is written to the faction
  audit log with the actor. Per-faction flavor caps remain open (§8).
- **Faction research** (`Data.Game.FactionPatent`, treasury technology,
  bought by the Head of Economy, passive once owned):
  `research_compact` (+2 tech/member) → `deep_space_relay` (+0.5 radar)
  → `counterintel_grid` (+10 CI), and → `standardized_freight` (−5%
  fleet upkeep) → `chartered_shipyards` (+15% fleet repair).
- **Faction lexes** (`Data.Game.FactionLex`, treasury ideology, bought
  by the Leader, then ENACTED into `government_max_laws` (2) law slots
  with a `government_law_cooldown` (24h) change cooldown — the
  faction-level mirror of player policies): `assembly_charter` (+2
  ideology/member) → `civic_pride` (+3 happiness) → `sanctuary_accord`
  (+10% defense), and → `mobilization_act` (+10% mobility) →
  `war_footing` (+10% invasion).
- **Distribution**: purchased patents + enacted laws + tax rates are
  pushed to every member Player.Agent on each government change plus a
  periodic self-heal sync, cached player-side, and injected into
  `extract_bonus` exactly like faction traditions.

This first slice is deliberately bonus-only (the marquee agency nodes —
gateways, uplink, war bonds, lend-lease — arrive with their systems);
the flat-bonus ceiling from the design constraint applies to the FULL
tree, not this bootstrap slice. **Deliberate v1 simplification:** lex
enactment is Leader-fiat in every faction for now — Myrmezir's
referendum-based enactment (its democratic identity, §3) should replace
that before this ships to players.

### 5.1 Guardrails first (the "don't punish dissenters" rules)

- **Tax caps are structural, not elected.** Income tax is capped low
  (suggest 10%; per-faction flavor caps: ARK 15%, Myrmezir 8% etc.), and
  the cap is engine-enforced. Whatever a hostile Head of Economy does,
  a player who ignores government entirely loses at most a sliver — and
  visibly gets it back through subsidies, actions, and infrastructure.
- **No negative-sum laws targeting members.** Lexes may *redirect*
  incentives (bonuses somewhere) but never apply maluses to members who
  don't participate. The only member-affecting maluses in the whole system
  are the faction-wide, government-caused stability debuffs already in the
  doc (tyranny, deposition) — which punish the *government's* choices, not
  a dissenting player's.
- **Opt-in infrastructure.** Anything that reveals a player's assets
  (uplink, concordat) requires that player's own build/opt-in, and pays
  them for it (they see everyone else's in return).
- **Focus ≠ mandate.** Directives (below) add bonuses inside the focus;
  they never subtract outside it.

### 5.2 Faction tech tree (treasury technology; unlocked by Head of Economy, or referendum for Myrmezir)

1. **Gateway Network** — the player-requested marquee item; 3-node line.
   [agency/coordination]
   - *T1 — Gateway Construction*: unlocks the **Gateway** building
     (orbital biome, `:unique_body`, very expensive, high workforce).
     Any member can build one on a system they own; the *faction* tech is
     the gate, the *player* pays the construction — buy-in is distributed
     and voluntary.
   - *Pairing model (recommended)*: gateways do nothing alone. The Head of
     Military activates a **link** between exactly two built gateways for a
     treasury fee; a gateway holds one link (T3 allows 2). Implementation:
     the galaxy's `check_jump` (lib/game/instance/galaxy/galaxy.ex:83-99)
     returns a gateway edge with a small fixed weight when both endpoints
     hold an active linked gateway and the character's faction owns them —
     travel time becomes `gateway_weight * character_movement_factor`
     (minutes, not hours). Arrival code path is untouched.
   - *Why pairs, not a free network at T1*: a network collapses map
     geometry — interception, front lines, and the conquest track all
     assume distance matters. Pairs make the *placement* of the link a
     strategic government decision (and a debate — this is where
     Myrmezir referendums and ARK treasury politics get interesting).
     T3 ("Gateway Nexus") can relax to hub-and-spoke late game.
   - *Counterplay*: a gateway system under siege has its link suppressed;
     if the system is captured the gateway is disabled (not usable by the
     captor — it's keyed to faction command codes) until rebuilt. Transits
     are visible events on the radar layer (a gate flash), so heavy use
     leaks information. Optional: per-character transit cooldown to
     prevent instant army shuttling (start with 1h, tune).
   - *T2 — Gate Logistics*: link activation cheaper, +transit of trade:
     resources sent via `send_resources` between linked systems' owners
     skip the market tax. [flat-ish sweetener]
2. **SLSD Command Uplink** — solves the real coordination gap the players
   identified. [coordination, opt-in]
   - Unlocks the **Command Uplink** building (`:unique_body`,
     infrastructure). Every member who builds one joins the *command
     network*: their moving navarchs become visible faction-wide (outside
     radar range) **to other network members only**. Build it → reveal
     yours + see everyone else's; don't → status quo. Implementation is
     the low-effort path found in the survey: a lex/tech flag checked in
     `Faction.update_detected_object` (faction.ex:228) adding own-faction
     moving admirals of network members to `detected_objects` with a
     `source: "command_uplink"` tag (and indexing speakers/admirals of
     members in the existing Spatial tree).
3. **Deep-Space Relay Array** [coordination → visibility track]
   - Faction action enabler: pooled informer intelligence. Systems where
     any member has informer contact count their intel for *all* members
     (contact-detail sharing at faction level). Directly moves the
     visibility victory track, which is otherwise the least
     player-legible track.
4. **Chartered Shipyards** [agency]
   - Members may repair/refit fleets at *any* member's system with a
     shipyard (not just their own), with the treasury paying a configurable
     share of the repair cost. Turns member territory into shared military
     infrastructure without transferring anything.
5. **Flat tech nodes** (≤2 of ~7): e.g. *Standardized Freight* (-5% fleet
   maintenance faction-wide), *Research Compact* (+X technology
   faction-wide). [flat]

### 5.3 Faction lex tree (treasury ideology; enacted as active laws in limited slots)

1. **Siderian Concordat** — the proposal from the doc/user. All members'
   speakers share positions faction-wide (visibility level 5 in
   `detected_objects`). Slot cost makes it a real choice against other
   laws. [coordination]
2. **War Bonds Act** [agency, voluntary]
   - While active, any member may buy bonds: credits into the treasury
     now, repaid at +15% after 10 game-days, +25% if the faction gains a
     victory-track tier before maturity. Funds gateways/actions; gives
     rich players a way to bankroll the faction *by choice* and ties the
     payoff to collective victory progress.
3. **Lend-Lease Act** [agency — the faction-fleet on-ramp]
   - Enables *commissioning*: a member may flag one of their admirals'
     fleets as commissioned; the treasury pays 50–100% of its maintenance
     and the Head of Military gains **stance + battle-plan tasking**
     rights over it (reaction setting + a "requested destination" marker
     the owner can follow or ignore; the owner keeps actual movement
     control and may de-commission at any time, with a 24h cooldown).
     This is the doc's "faction fleet" reframed as delegation instead of
     ownership transfer — implementable with a `stance_controller_id`
     style field, no character-ownership surgery, no new upkeep economy.
     Full faction-owned fleets (ownership transfer) stay a Phase 4+
     option if delegation proves insufficient.
4. **Colonial Charter** [coordination → population track]
   - The Leader designates up to N charter systems (uncolonized/frontier).
     Colonization and population-building costs there are subsidized by
     the treasury (e.g. 25%), and the colonizer gets a one-time grant.
     Pulls the faction toward the population track by paying volunteers,
     never penalizing players expanding elsewhere.
5. **Doctrine of the Claimed Sector** [coordination → conquest track]
   - The Leader claims one sector as the faction objective. Members
     fighting there get focused bonuses (invasion/raid coef, repair) and
     contribution is surfaced on the scoreboard ("liberation credit").
     Rotatable with a cooldown. The map already has sectors with victory
     point values; this makes the conquest track a shared campaign
     rather than an emergent accident.
6. **Emergency Powers Act** [timed decision, generalizes Tetrarchy tyranny]
   - While active (max 48h, long re-enact cooldown): faction action
     cooldowns halved and the Leader may act as any seat — at a growing
     faction-wide stability debuff per use. High-agency lever with a
     built-in cost borne by the government's choice, not by dissenters.
7. **Electoral/By-Law lexes** [meta-agency, later phase]
   - Small set letting factions tune their own government within bounds:
     term length ±, tax cap flavor swaps, add a 4th seat. Powerful
     replayability lever; defer until the base system is stable.
8. **Flat lexes** (≤2): *State Religion* (+ideology%), *Civic Pride*
   (+happiness faction-wide). [flat]

### 5.4 Faction actions (one-shot, treasury cost + cooldown, seat-gated)

| Action | Seat | Effect | Tag |
|---|---|---|---|
| Sector Priority Directive | Leader | 48h: claimed-sector bonuses (see lex 5) without the standing law — the "we push NOW" button | coordination |
| General Mobilization | Military | 24h: +15% fleet speed faction-wide | flat, timed |
| Intelligence Sweep | Military | Reveal all enemy contacts in one sector for 2h (visibility-track push) | coordination |
| Economic Stimulus | Economy | Grant package: split a treasury sum across members' next building orders in designated systems | agency |
| Propaganda Campaign | Economy | 24h: +happiness in all member systems (counter-plays sieges/unrest waves) | flat, timed |
| Census | Leader | Snapshot report: per-track victory progress vs. each rival faction, delivered as a report card to every member | coordination/legibility |

Census is cheap to build (victory data exists) and deceptively important:
the "focus the faction toward victory" goal starts with members *seeing*
the three tracks clearly.

### 5.5 Battle plans (Head of Military)

Extend the existing shared system-icon layer rather than building an
annotation engine: add role-gated plan icon kinds (attack/defend/regroup/
stage) plus an ordered "route" grouping (sequence index on icons), rendered
client-side as arrows. The icon system already has placement RPCs, rate
limits, per-faction broadcast, and an audit log — battle plans are ~90% a
frontend feature. Combined with Lend-Lease tasking markers, this covers the
doc's "special filter allowing drawing battle plans."

### 5.6 Content mix check

Of the ~20 items above: 6 are flat or flat-ish (Standardized Freight,
Research Compact, Gate Logistics sweetener, State Religion, Civic Pride,
Mobilization, Propaganda), ~14 are agency/coordination mechanics. That
comfortably satisfies the ≤50%-flat constraint, and every coordination item
is anchored to a specific victory track: conquest (Claimed Sector,
Directive, gateways as force projection), population (Colonial Charter,
Stimulus), visibility (Relay Array, Intelligence Sweep, Uplink, Concordat).

---

## 6. UI/UX notes

- **Government panel**: new `government` tab in `FactionPanel.vue`
  (tab array + sibling component, established pattern). Seats as
  `ProfileCard` variants with term countdown (`Counter` /
  `CircleProgressValue` already exist and are tick-synced); treasury as a
  `DynamicValue` triple like the player HUD; ongoing-votes list with the
  standard countdown; faction bonuses list stays (traditions + active
  laws + unlocked tech).
- **Election overlay**: the full-screen overlay pattern
  (`opened-player.vue`) with candidate `ProfileCard`s — matches the
  mockups' right-side election panel.
- **Faction trees**: `PatentMiniPanel`/`DoctrineMiniPanel` are directly
  reusable (`Tree.fromList` → grid, node status badges, slot-selection
  logic for active laws) — the lex tree with law slots is literally the
  doctrine component pointed at faction data.
- **Cardan**: candidate cards + one pledge slider ("Offer X% of your
  ideology income") + one quorum lamp ("The offering suffices / The
  offering is wanting"). No numbers beyond the player's own pledge —
  secrecy is a *simplification* for the UI, not a complication.
- **ARK**: auction-house framing for elections (per-candidate bid totals,
  escrow indicator, outbid button). Challenges as a wizard: one pending
  decision per side at a time, each button carrying a consequence preview
  and a deadline. If Option B (§3) ships first, the wizard is 2 screens.
- Government events (election opened/won, law enacted, challenge declared)
  should emit through the existing notification/event-card system so they
  appear in the report/event panel — this is most of how non-engaged
  players learn the government exists.

---

## 7. Data model summary

New tables: `faction_governments` (or fields on `factions`),
`faction_elections`, `faction_votes` (journal; includes stake amount +
escrow state), `faction_treasury_ledger` (every credit/debit with reason —
cheap, and the single best anti-grief/dispute tool), extended
`faction_event_log` event types. New runtime: `:government` on
`Instance.Faction.Faction` (snapshot back-filled), `GovernmentRules`
behaviour + 5 modules, ballot engine in the Faction tick, tax hook in
`Player.extract_bonus/2`, treasury RPCs on FactionChannel. New content
data: `Data.Game.FactionPatent`, `Data.Game.FactionLex`, faction action
definitions — all following the existing `Data.Game.*` content-module
pattern with `-slow` variants only (Legacy-gated).

---

## 8. Open questions for design

1. **Tax caps** — agree the principle (§5.1)? Suggested global cap 10%
   with per-faction flavor deltas.
2. **ARK challenge** — Option A (as written, wizard UI) or Option B
   (single-round sealed match) for first release? (Recommendation: B.)
3. **Gateways** — confirm pairs-with-activation over free network at T1;
   confirm "captured gateways are disabled, not usable by captor."
4. **Faction fleet** — is Lend-Lease delegation (owner keeps movement,
   Head of Military gets stance + tasking + treasury-paid upkeep) an
   acceptable v1 realization of "create a faction fleet and transfer its
   command," or is true ownership transfer a hard requirement?
5. **Diplomacy** — accept declarations-without-enforcement for v1, with
   mechanical pacts deferred to their own feature?
6. **Election clock** — confirm game-time (pause-safe) over wall-clock
   for all government timers.
7. **Bots** — abstain entirely (recommended v1) or vote-for-top-scorer?
8. **Myrmezir** — adopt referendums + citizen initiative as the answer to
   the doc's TBD?

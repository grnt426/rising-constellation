# Daily challenge expansion — selected objectives, boons, banes

The curated expansion set for the daily, selected from the first
brainstorm pass. The launch daily has seven objectives (credit/tech/
ideology totals and incomes, peak production) and rolls 2 boons + 1 bane
from roughly a dozen wired mutators; the rotation repeats fast and every
goal is a flavor of "make the number go up." Everything below is
approved design; specs are as concrete as we can make them before
implementation, and numbers are tuning defaults, not commitments.

Companion docs: [daily-challenge.md](daily-challenge.md) (architecture),
[mutator-ideas.md](mutator-ideas.md) (the general mutator roadmap).

## Ground rules the ideas must respect

- **Determinism is the leaderboard.** Everyone who plays a date gets the
  identical system, mutators, and (new) event schedule, all derived from
  the date digest. Contested-action dice stay random per run; that's
  already true of every action today. What must match is the *starting
  conditions and the script*, not the rolls.
- **The daily is solo.** There are no NPC fleets anywhere in the engine:
  armies only exist attached to player admirals, and SystemAI only ever
  builds buildings. Anything with an enemy in it needs new machinery
  (the Director, below). Additionally, informers/contacts belong to a
  *faction*, so even the dice-only infiltration days need a puppet enemy
  faction present in the game_data.
- **Scoring rides `PlayerStat`.** An objective is nearly free when its
  stat is already snapshotted; it costs a schema change otherwise.
- **30 minutes.** Ideas that need a long arc must be tuned against the
  `:daily` tick factor, not rejected outright; the clock is a tuning
  constant.

## The four unlocks

Almost every selected idea hangs off one of four infrastructure
investments. Building them in this order turns each into a batch of new
days, cheapest first.

### 1. Scoring shapes (small)

`Daily.Objective` today is "one stat, higher wins." Extend each catalog
entry with a `mode` and an explicit `tiebreak`:

- `:max_stat` — today's behavior.
- `:race` — the day defines a goal predicate; score = **seconds left on
  the clock when you complete it** (0 for did-not-finish, tiebreak =
  progress toward the goal). This keeps "higher is better" so the
  leaderboard sort never changes.
- `:min_stat` — for "end with the least X" days: score = `cap − X`.
- `:composite` — score computed from several stats at finalize time
  (min-of-three, weighted sum). No new columns; `finalize/1` already has
  the live player in hand.

Tiebreaks get stored in the `daily_entries` breakdown and shown with the
goal ("ranked by time, ties by remaining credit"). Publishing the
tiebreak is part of the day's contract.

Some selected days are **packages**: an objective bundled with a fixed
setup (The Bequest's fortune and drain, The Gauntlet's wave script)
rather than an independent objective + random mutator roll. The
generator needs a notion of a scripted day that pins or restricts the
mutator roll.

### 2. Pre-seeded adversity (small)

The world-gen mutator path (`on_galaxy_spawn` post-processing) can hurt
you at spawn, not just help: seeded enemy contacts, distorted starting
balances, a puppet enemy faction with embedded agents. The adversity is
baked into the generated system and the tick loop does the rest.

### 3. Sector dailies (medium)

`Daily.Generator` is parametric; a second archetype emits K systems in
one sector instead of one — the player's starter plus a scripted mix of
uninhabited / neutral / dominion systems with chosen defense, workforce,
and factor profiles. SystemAI already runs the neutrals. This unlocks
the expansion and offense families and gives `total_systems` something
to count. Victory stays clock-only (the daily already sets the VP target
unreachably high).

### 4. The Director (large, two stages)

A deterministic scheduler owned by the instance: a list of
`{t_seconds, event}` derived from the date digest, fired off the
existing tick/timer plumbing, announced through the news ticker so the
player sees waves coming.

- **Director v1 — system effects only.** Events that need no enemy
  entities: apply a happiness penalty (a destabilization "wave" is
  mechanically `add_happiness_penalty` with flavor text), roll an
  infiltration attempt as a bare `Core.Dice` against the system's CI and
  raise the puppet faction's visibility on success, damage a building.
  This fakes enemy *agents* convincingly: the player experiences
  "Erased of increasing skill arrive every 3 minutes" as escalating
  attack values on a schedule; no character process ever exists.
- **Director v2 — an adversary shell.** A hidden enemy faction with a
  puppet player (no account), whose characters and armies are created
  through the normal `Character` / army paths — the sim harness
  (`lib/sim/fleet.ex`) already knows how to assemble an arbitrary army
  from a grid spec. The Director scripts their actions (arrive, sit in
  orbit with `:defend`, begin a conquest after a grace period). This is
  the most expensive item in this doc and the biggest variety unlock;
  interception, sieges, raids, sabotage, and assassination all exist and
  work — they've just never had a target in a solo instance.

---

## Objectives

Feasibility legend: **shapes** / **seeded** / **sector** / **v1** /
**v2** — needs that unlock.

### Economy

| Name | Spec | Needs |
|---|---|---|
| **The Triumvirate** | Score = the *lowest* of your three income rates at the deadline; only balance scores. | shapes (composite) |
| **The Bequest** | Start with 100,000,000 credits and a flat drain of 5,000 credits per minute; end with the most left. A strong enough economy can swing the net positive right at the end, which is exactly the race we want at the top of the board. | shapes + seeded (package day: fixed setup, scoring = stored credit) |

### Races (score = seconds remaining at completion)

| Name | Spec | Needs |
|---|---|---|
| **Charter of Prosperity** | Push *this system* (not the empire) to 800 credit / 50 tech / 40 ideology income simultaneously, fastest. | shapes |
| **The Destroyer's Blueprint** | Research the Destroyer ship patent fastest. (Maps to the internal patent key at implementation; the pattern generalizes to other named patents later.) | shapes |
| **Monumental** | Complete the day's named wonder (`monument_dome` / `high_factory_dome`) fastest. | shapes |
| **Fleet in Being: Raiders** | Field a fleet totalling ≥ 50 bombing (raid) power, fastest. | shapes |
| **Fleet in Being: Vanguard** | Field a fleet totalling ≥ 50 conquest (invasion) power, fastest. | shapes |
| **Fleet in Being: Armada** | Field a fleet costing ≥ 500 credits of upkeep, fastest. | shapes |
| **Spring Cleaning** | The system spawns already compromised by an enemy faction: pre-planted contacts and embedded enemy Erased of increasing level. Fully clean house fastest — wiping contacts (remove-contact) and seducing the embedded agents (conversion) both count. | shapes + seeded + puppet faction |

### Defense and survival

| Name | Spec | Needs |
|---|---|---|
| **Quiet Halls** | Enemy Erased of escalating infiltrate skill attempt infiltration every ~3 minutes. Score = the enemy faction's **visibility value** on your system at the deadline, lower wins. Each successful infiltration raises it by 1 (2 on a critical); the normal 0–5 visibility clamp is raised to **20** for this day so the board doesn't collapse into ties. Tiebreak: counter-intelligence. | shapes (min) + v1 + puppet faction + configurable visibility cap (the 0–5 clamp lives in `Core.VisibilityValue.force_value/1` and a few `== 5` max-visibility checks) |
| **The Gauntlet** | At 10:00 the first fleet arrives; a new wave lands every 5:00, each with conquest power 50 higher than the last (ship comps computed to hit the target). Conquest must be tuned to take ≤ 1 minute at daily speed, so a survived wave leaves ~4 minutes to rebuild. A failed conquest deletes the attacking fleet. Surviving wave n pays n × (50,000 credits + 5,000 tech + 5,000 ideology) — numbers to balance. Score = time survived until conquered. | shapes + v2 |

### Offense

| Name | Spec | Needs |
|---|---|---|
| **The Leviathan** | A powerful NPC fleet sits in orbit (fixed comp from the day seed); destroy it fastest. Variant A: no Erased on the market (pure fleet build). Variant B: Erased available — sabotage the leviathan first. | shapes + v2 |
| **Scorched Path** | Five neutral systems of escalating defense; deal the most cumulative raid damage before the clock. | sector + a damage-dealt counter |
| **Siegebreaker** | Five defended neutral systems; conquer all five fastest (progress tiebreak for those who don't finish). | shapes + sector |
| **Convoy Season** | Starting at 10:00 and every 2:00 after, a mono-fleet crosses your system: one ship type per wave, in escalating order — scouts ×2, colony ship, light fighters ×2, fighter-bombers ×2, interceptors ×2, then the ×4 variants of those, light corvettes ×2, heavy corvettes ×2, and so on up the classes. Destroy as many ships as possible (reaction stances and pickets finally matter solo). | v2 |
| **Headhunter** | Enemy governors and agents populate neighboring systems; assassinate the most. Generated systems must carry enough workforce + counter-intel, in increasing amounts, to eventually trip an Erased — and bombing a system first to knock its intel down is a legitimate line, not an exploit. Tiebreaks: highest-level Erased, then accumulated Erased XP. | sector + v2 |

### Expansion and agent-craft

| Name | Spec | Needs |
|---|---|---|
| **Hegemon** | A sector of neutral and dominion systems; hold the most dominions at the deadline (Siderian `make_dominion` versus happiness defenses). | sector |
| **Land Rush** | A sector of uninhabited systems; colonize the most. Transports, the `max_systems` cap, and the expansion doctrines become the whole game. | sector |
| **Cover of Night** | Most successful spy actions without your Erased ever dropping below the cover threshold; one discovery ends the streak. | shapes + v1 or v2 targets |

---

## Boons

The bonus pipeline (`Instance.Mutators.bonus_entries/1`) makes any
`from → to` routing a one-entry mutator; those are marked **wired** and
ship in the first implementation batch. The rest name the hook they
need. Values are tuning defaults.

| Name | Effect | Needs |
|---|---|---|
| **Prosperous Masses** | Population pays taxes: each point of workforce adds 2 credit income (`sys_pop → sys_credit`). | wired |
| **Joyful Industry** | Happiness feeds production: each point of happiness adds 1 production (`sys_happiness → sys_production`). | wired |
| **Festival Days** | +10 happiness; faster growth, uprising headroom. | wired |
| **Panopticon** | Counter-intelligence and remove-contact +50% each. The natural boon for infiltration days. | wired |
| **Veteran Shipwrights** | All four ship XP levels +10; combat-day partner. | wired |
| **Open Court** | +1 to every agent cap. | wired |
| **Expansion Charter** | +1 max systems, +2 max dominions; sector-day partner. | wired |
| **Field Docks** | Army repair twice as effective. | wired |
| **Cheap Steel** | Army maintenance halved. | wired |
| **Silver Tongues** | Siderian *actions* twice as effective (conversion / destabilize / vassalize coefs). | wired |
| **Ghost Protocols** | Erased action coefs +50% (infiltrate / sabotage / assassination). | wired |
| **Prodigies** | Agents earn double experience. | **shipped** (on_xp hook: scales action XP at `Character.add_experience` and governors' passive XP at `Character.next_tick`) |
| **Demographic Dividend** | Everything that scales with population scales twice as hard (double `sys_pop` / `body_pop` as read by the pipeline). | medium: input-side scaling, a new pipeline concept |
| **Radiant Court** | Every Siderian present in the system grants +10% ideology and technology income; their stats don't matter, their presence does. | medium: on_tick presence predicate |
| **Doctrine of the Masses** | Siderian *passive* skills (leader / scholar / philosopher) doubled. | medium: skill-bonus scaling |
| **Pioneer Charter** | Start with a named patent unlocked. | cheap: on_player_init |
| **Subsidized Yards** | Ships cost half production. | **shipped** (on_cost hook) |
| **Open Science** | Patents cost half technology. | **shipped** (on_cost hook) |

## Banes

| Name | Effect | Needs |
|---|---|---|
| **Hungry Mouths** | Population drains credits: each point of workforce subtracts 2 credit income (`sys_pop → sys_credit`, negative). Upkeep tracks how big you grow — the self-balancing cut of "houses cost credits." | wired |
| **Crowded Slums** | Habitation 25% less effective; the pop ceiling bites early. | wired |
| **Sullen Populace** | −10 happiness; the uprising thresholds loom. | wired |
| **Blind Watch** | Counter-intelligence and remove-contact −50% each. | wired |
| **Porous Borders** | System defense −30%; raid-wave days sharpen. | wired |
| **Brittle Hulls** | Army repair half as effective. | wired |
| **Agitators Abroad** | Siderians of rising skill destabilize the system every 3–5 minutes (scheduled happiness penalties of growing size). | v1 |
| **The Reavers Come** | Bombardment fleets arrive at fixed times (e.g. raid strength 30 at 10:00, 60 at 20:00), hold orbit briefly, then fire. | v2 |
| **Crumbling Ground** | Every 5 minutes a quake damages 1–3 buildings. The *count* is rolled from the date digest so it's identical for every player that day; which buildings get hit may vary per run (players build different systems anyway). | v1 |
| **Tides of Industry** | Production oscillates ±25%, flipping direction every 5 minutes; time your builds to the boom. | on_tick |

## Rotation and pairing

Two different collision rules, deliberately opposite:

- **Objective × mutator collisions are welcome.** A bane that nerfs the
  scored resource (Luddite Backlash on a tech-income day) is a rare,
  especially challenging day — the whole board suffers it together, and
  that's the point. No exclusion logic; the rarity is the design.
- **Boon × bane collisions on the same lever are forbidden.** Rolling
  "+50% tech income" alongside "−40% tech income" isn't broken, it's
  *boring*: the day reads as having nothing interesting to offer. Every
  mutator gets an `axis` tag naming the lever it pulls
  (`:technology_income`, `:happiness`, `:intel`, `:fleet_repair`, ...);
  the generator rolls its two boons first, then filters the bane pool to
  exclude any bane sharing an axis with a rolled boon (with a fallback
  to the unfiltered pool if that ever empties). Same-polarity overlaps
  (two credit boons) remain legal — stacking is fine, contradiction is
  not. Event-style banes (Agitators Abroad, Crumbling Ground) get their
  own axes: Festival Days alongside Agitators Abroad is a defense-vs-
  attack pairing, not a contradiction.

Other rotation notes carried forward:

- Tag objectives with what they `require` (shapes / sector / director /
  puppet faction) so the generator weights rotation by what's actually
  wired, exactly like `daily_eligible` today.
- Anchor the heavier formats to weekdays (combat day is always Friday,
  sector day always Sunday) so the rotation reads as a ritual rather
  than a shuffle; the economy days fill the gaps.
- Publish the tiebreak with the goal, every day, as part of the
  contract.
- Package days (The Bequest, The Gauntlet) pin or restrict the mutator
  roll rather than taking the standard 2 + 1.

## Suggested build order

| Investment | Size | Days it unlocks |
|---|---|---|
| Wired boon/bane batch (bonus pipeline entries) — **shipped** | tiny | 11 boons + 6 banes immediately |
| Axis tags + conflict-aware roll — **shipped** | tiny | the pairing rule above |
| Scoring shapes — **shipped** (modes + tiebreaks + The Triumvirate + the Charter of Prosperity race + package days incl. The Bequest) | small | Triumvirate, The Bequest, the whole race family |
| Pre-seeded adversity + puppet faction | small | Spring Cleaning; prerequisite for every infiltration day |
| on_cost hook — **shipped** (Subsidized Yards, Open Science, Lost Sciences) | small | patent + ship-production cost mutators |
| on_xp hook — **shipped** (Prodigies, Inexperienced Court) | small | action + passive XP mutators |
| on_tick hook | medium | Tides of Industry, Radiant Court, Hyperlane Mastery |
| Sector archetype | medium | Hegemon, Land Rush, Siegebreaker, Scorched Path, Headhunter's map |
| Director v1 | medium | Quiet Halls, Agitators Abroad, Crumbling Ground |
| Director v2 | large | The Leviathan, The Gauntlet, Convoy Season, Headhunter, The Reavers Come |

## Cut in the first curation pass

Kept here so the ideas aren't lost; any can be revived.

- Objectives: Teeming Throngs, Hands to the Wheel, Reconstruction, The
  Quiet Uprising, Lean Machine, Prodigious, Full House, The Last Patent
  (generalized form of the Destroyer race), Hold the Line (The Gauntlet
  covers the niche), War Economy, The Apprentice.
- Boons: Teeming Masses (stays a scenario-forge roadmap entry, out of
  the daily rotation).
- Banes: Rusting Fleets, Whisper Campaign (folded into Quiet Halls),
  Silent Market, Landlord's Due (Hungry Mouths ships instead).
- Neutral scheduled events (windfalls, flares) — revisit once Director
  v1 exists.

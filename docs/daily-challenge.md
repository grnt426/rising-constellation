# Daily challenge

A once-a-day variant of the standard game: a single procedurally-generated
star system, seeded from the calendar date, that each player optimises solo
for ~10–45 minutes. Everyone who plays a given day faces the **identical**
system and mutators (determinism = a fair leaderboard); only their decisions
differ. The goal is some resource-optimisation target that rotates daily.

## Why it's a thin layer, not a new engine

A daily reuses the existing scenario → instance → tick pipeline wholesale. A
"galaxy" is just a `game_data` map with a list of systems and sectors, so a
**single-system galaxy is a `game_data` whose `systems`/`sectors` lists have
one entry** (see `Instance.Manager.init_from_model/4` and
`test/support/scenario_game_data.json`). The economy/tick loop, mutator
plumbing, and `RC.Instances.PlayerStat` scoring substrate all run unchanged.

The Sim harness (`:sim`, `lib/sim/*`) is deliberately *not* the base: it
skips the economy/tick loop and only resolves battles, whereas a daily is
entirely about the economy loop.

## Lifecycle

```
date ──hash──▶ Daily.Generator ──▶ game_data (1 system, hidden, Legacy)
                                       │  per player
                                       ▼
        per-player instance ──▶ economy tick loop (prod·credit·tech·ideo)
                                       │  time limit
                                       ▼
              freeze + score ──▶ Daily leaderboard (ranked)
```

## What's built (pure core)

- `Daily.Generator` — `for_date(date)` → deterministic `game_data` for one
  system, one sector, one faction (the solo player), no opponents/neutrals.
  Two seed layers: the date's SHA-256 digest picks archetype / objective /
  mutators; the in-game `"seed"` (3 ints) drives the engine's body/tile/factor
  generation.
- `Daily.Objective` — the seven rotating goals (credit/tech/ideology *total*
  by deadline; credit/tech/ideology/production *income*) and `score/2`, which
  reads a `PlayerStat`-shaped map so ranking needs no engine coupling.
- `Data.Game.Mutator` — catalog extended with `polarity` + `daily_eligible`
  tags and the full mutator roadmap (world-gen twists, pacing boons, banes).
  The generator rolls **2 boons + 1 bane**, restricted to wired mutators
  unless asked for the full roster.
- **World-gen mutators wired** (`on_galaxy_spawn`) — Worlds of Plenty /
  Hardscrabble Worlds / Gilded Orbitals (force body factors to their range
  max/min) and Sprawling / Open Frontier (extra building tiles) apply in
  `Instance.StellarSystem.StellarBody.new/5` as pure post-processing of the
  seeded rolls — the RNG stream is untouched, so a daily without them is
  identical to vanilla. Logic + tests are pure
  (`test/daily/mutator_gen_test.exs`), and confirmed live below. Note: the
  player's home system is a standardized *starter*, so
  `transform_to_starter_system/1` applies these mutators too — otherwise a
  single-system daily (whose only system is the home) would never reflect
  them. Vanilla games have no active mutators, so it's a no-op there.
- **Live MVP boot** (`Daily.Boot`, `POST /api/harness/daily/start`) — builds
  an in-memory instance from a generated daily (tutorial-style: no DB
  scenario/instance rows), stands up the live supervision tree
  (`Instance.Manager.create_from_model` + `:start`), and reads the economy
  back (`GET /api/harness/daily/:iid/status/:pid`). A demo account/profile is
  created idempotently. Confirmed live in Docker: the player owns the
  procedural system, the economy ticks at the daily clock, and both
  resource-scaler and world-gen mutators take effect. Player stats aren't
  persisted (the in-memory ids fail the `PlayerStat` FK and are discarded —
  harmless), so no leaderboard yet.
- `Daily` — assembles the day's definition and the `create_scenario` attrs.
- `mix daily.preview [date] [--all]` — print a day's challenge.
- **`:daily` speed** (`Data.Game.Speed{,.Content}`) — a dedicated speed that
  *is* Legacy: every speed-branching Data module falls back to its `:slow`
  spec for `:daily`, so the content is identical, but the tick factor is fast
  (240 = 2× `:fast`). It's `selectable: false`, and `Portal.DataController`
  strips non-selectable speeds from `/api/data`, so the scenario editor never
  offers it — only generated dailies use it.
- Tests: `test/daily/generator_test.exs`, `test/daily/objective_test.exs`,
  `test/daily/speed_test.exs` (locks `:daily` content == `:slow` + factor +
  hidden).

## Open decisions captured

- **Goal rotation:** a different objective each day; most days score *at the
  deadline*. (Confirmed.)
- **Retries:** allowed; leaderboard keeps each player's *best*. (Confirmed.)
- **No opponents or neutrals** in v1 — a pure economy sandbox. (Confirmed.)

## Next milestones (not yet built)

1. **Persisted per-player instances + lobby hiding.** The MVP boots an
   *in-memory* instance via the harness endpoint (above) — great for a live
   demo, but nothing is persisted. Next: create real
   `create_scenario` → `create_instance` → register rows (a single faction,
   `capacity: 1`, `public: false`) so `PlayerStat` and the leaderboard work,
   add a `:daily` value to `InstanceGameType` so dailies never list in the
   lobby (`RC.Instances.list_instances/3` already filters `public == true`),
   and trigger from a player-facing JWT endpoint instead of the harness secret.
2. **"Daily Complete" freeze + scoring.** Replace `Instance.Victory`'s
   14-points/timeout → destroy with: on time-up, *freeze* (pause, don't
   destroy), compute `Daily.Objective.score/2` from the final `PlayerStat`,
   write the leaderboard entry. Needs `stored_technology` / `stored_ideology`
   columns on `PlayerStat` (only `stored_credit` exists today) for the two
   tech/ideology *total* objectives.
3. **Persistence.** `daily_challenges` (one row/day: date, seed, game_data,
   objective, mutators) and `daily_entries` (date + profile → best score,
   breakdown, completed_at) tables + ranked query.
4. **Remaining mutator hooks.** The `on_galaxy_spawn` factor/tile family is
   wired (above). Still to do: the habitability pair (Garden Worlds / Barren
   Crucible — needs body-type classification), Teeming Masses (+pop at system
   claim), and the `on_tick` / `on_cost` / `on_xp` / `on_action` boons & banes
   (income multipliers, mobility, patent cost, governor xp, no agents). The
   daily is the testbed: ship a mutator here, watch the leaderboard, then
   promote the winners to ranked.
5. **Frontend.** Portal daily page (system preview, mutators, goal, your best,
   leaderboard, Start) + in-game goal banner and Daily-Complete screen. The
   in-game view is reused, scoped to the lone system (auto-select it, hide the
   galaxy zoom).

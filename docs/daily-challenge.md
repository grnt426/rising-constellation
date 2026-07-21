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
- **Expansion batch + axis rule** (see docs/daily-challenge-ideas.md for the
  full selected design) — 11 new boons and 6 new banes wired through the
  bonus pipeline (multi-lever entries carry a `bonuses:` list, normalized by
  `Mutator.bonuses/1`; `Instance.Mutators.bonus_entries/1` emits one entry
  per bonus). Every catalog entry now carries an `axis` tag naming the lever
  it pulls; the generator's bane roll excludes any axis a rolled boon already
  pulls, so a day never both boosts and nerfs the same number
  (objective-vs-mutator collisions stay legal — those are deliberately hard
  days). Tests: `test/daily/mutator_catalog_test.exs` + the axis-conflict
  sweep in `generator_test.exs`.
- **Scoring shapes** — every objective declares a `mode` (`:max_stat` — the
  original seven; `:composite`; `:race`) and `Daily.Objective.evaluate/3`
  returns `%{score, tiebreak}`; `daily_entries.tiebreak` (migration
  20260721000001) makes keep-best lexicographic and the leaderboard /
  `player_rank` tiebreak-aware. Two new objectives join the rotation:
  **The Triumvirate** (`:composite` — score = the lowest of the three income
  rates, ties on the sum) and **Charter of Prosperity** (`:race` — first
  system to 800 credit / 50 tech / 40 ideology income at once; score = real
  seconds left at completion, DNF scores 0 with progress as tiebreak). Race
  completion is detected live: the player agent's tick calls
  `Daily.Boot.race_tick/2` (no-op outside dailies; sets a snapshot-tolerant
  `:daily_race_won` flag so it records exactly once), which reads
  `ut_time_left` from the Victory agent and converts via the speed factor
  (`seconds = ut × 180 / factor`). Tests: `objective_test.exs` (modes,
  predicate, progress), `entry_test.exs` (lexicographic keep-best, ranked
  ties).
- **Race family** — race specs are shape-dispatched
  (`Daily.Objective.race_progress/2`): `%{system_income: %{...}}` (Charter of
  Prosperity), `%{patent: key, cost: n}` (**The Destroyer's Blueprint** —
  `:capital_1`, the Destroyer's internal key, 80k tech behind shipyard 4; DNF
  ties break on patents researched + banked tech), and `%{army: %{metric: n}}`
  (**Fleet in Being: Raiders / Vanguard / Armada** — a SINGLE fleet reaching
  50 raid / 50 invasion / 500 upkeep; best-fleet ratio is the DNF tiebreak).
  The army races read new `army_raid` / `army_invasion` fields on the
  player's character summaries (`Instance.Player.Character.convert/1`,
  tolerant reads so old snapshots stay safe). All five ride the same
  `race_tick` completion detection.
- **Package days + The Bequest** — an objective may carry `package_mutators`;
  the generator pins those instead of rolling 2 boons + 1 bane (the scripted
  setup IS the day). First package: **The Bequest** — start with 100,000,000
  credits (`Mutator.credit_override/1`, an absolute override in `Player.new`
  that wins over the multiplier path) bleeding 5,000/minute (a
  `:the_bequest_estate` mutator bonus: `direct_last → player_credit` −62.5
  per ut at the daily factor 240); score = stored credit at the deadline,
  ties on credit income (`tiebreak_field` on `:max_stat` objectives). The
  estate mutator is `daily_eligible: false` — only the package pins it.
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
- **Browser-playable** (`Daily.Boot.boot_persisted/2`, `POST /api/daily/play`,
  `GET /api/daily/today`) — the persisted path: real scenario + instance +
  registration rows (single faction, `public: false`), booted to "running".
  `play` returns the same join payload as `Portal.GameController.join/2`, so
  the SPA feeds it straight into its game store and goes to `/game` — no
  lobby/registration UI. Frontend: a "Daily Challenge" entry under
  `/play/daily` (`front/src/portal/pages/play/Daily.vue`, modeled on
  `Tutorial.vue`) that previews today's goal/mutators and has a Play button.
  Each play creates a fresh instance (retries = new instances). Because it's
  persisted, `PlayerStat` writes now succeed — the leaderboard can read them.
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

1. **Leaderboard — DONE (storage + read + daily-page UI).** `daily_entries`
   (one best score per profile+date, keep-best upsert) is written by
   `Daily.Boot` (see #2); `Daily.leaderboard/2` + `Daily.player_rank/2` rank
   it; `GET /api/daily/leaderboard` serves it; the portal `Daily.vue` page
   shows the ranked table + "your best". Still to do: an **in-game**
   leaderboard view, plus the `:daily` game_type, and i18n of the hardcoded
   `Daily.vue` strings.
2. **Deadline freeze + scoring — DONE.** At time-up the `Instance.Victory`
   agent's `:victory` tick (fires once, when `ut_time_left` first hits zero)
   routes dailies to `Daily.Boot.finalize/1` instead of the multiplayer
   ranking path: it `:stop`s every tick server (economy frozen — no more
   building/income on the victory screen) and then records the score *exactly
   once* from the frozen player. A safety net (`Daily.Boot.autosave/2`, driven
   by a **dedicated 60s wall-clock timer** in the player agent —
   `:start_daily_autosave` kicks it off, the `:daily_autosave` message
   reschedules) upserts the live score every minute so a crash/disconnect
   pre-deadline still scores; `autosave/2` returns `:stop` once finalized,
   ending the loop. Objective/date are cached in instance metadata
   (`daily_objective` / `daily_date`) so scoring needs no per-tick DB read.
   `stored_technology` / `stored_ideology` are derived from the live player at
   score time (no `PlayerStat` column needed).

   **Lifecycle (start-on-connect, drop-tolerant).** The economy does *not*
   start at boot. `boot_persisted` only instantiates + sets DB state; the tick
   clock starts on the **first client connect** (`Daily.Boot.ensure_started/1`,
   called from the player agent's `:connect` handler, idempotent), so the
   3-minute clock doesn't burn during the ~20s the browser spends loading.
   Symmetrically, a websocket **disconnect does nothing** — no score write, no
   teardown — because a transient drop during loading was tearing the game down
   under the player ("can't interact"). The instance keeps running so the
   player can reconnect and continue; the wall-clock autosave (server-side,
   independent of the client) is the only safety net needed. The sim does *not*
   pause while disconnected (no pause-on-empty exists), so the clock keeps
   burning — a disconnect costs the player the wall-time they're away but never
   ends the run or writes a "final" score. The *intentional* exit (in-game
   "Exit") pushes `quit_daily` on the player channel → `Daily.Boot.quit/1`
   (record + finish + destroy) and routes to `/play/daily`. An abandoned run
   runs to its deadline (where `finalize/1` writes the final score) and is
   reaped on the player's next start.

   **Anti-pileup:** `Daily.Boot.reap_running_dailies/1` runs at the top of
   `boot_persisted` — before a player starts a new daily it tears down (and
   keep-best-records) every non-`ended` daily instance they still own
   (`running_daily_instance_ids/1`, scoped by `game_mode_type` so multiplayer
   games are never touched). This closes the start-abandon-repeat DoS vector
   even when the disconnect that should have ended a run never lands. A halted
   instance the player never disconnects from still lingers until their next
   daily reaps it (or they disconnect); a time-based reaper is future work.

   **Time limit:** `@time_limit_minutes` is **30** (in `Daily.Generator`) — the
   design default within its 10–45 min window.
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

# Foresight — match predictions with tokens

Design document. Status: **implemented** (2026-08-15, branch
`claude/match-prediction-wagering-628a68`) through phase 4 of the plan
below; the phase-5 polish items (FP leaderboard, dedicated icon,
listing-row pool chip, `victories.winning_faction_id` hardening) remain
future work. Backend lives in `lib/rc/foresight*`, portal UI in
`front/src/portal/components/ForesightPanel.vue`; gated behind the
`foresight` beta flag.

Foresight is a light-hearted prediction game layered over regular matches.
Before and during a match, any account can commit **Foresight Tokens (FT)**
to the faction they believe will win. When the match concludes, correct
predictions recover their tokens plus a share of the tokens committed to the
other factions, and mint **Foresight Points (FP)** — a pure bragging-rights
score. Nothing here has, or will ever have, monetary value; the language and
mechanics are deliberately friendly and low-stakes.

## Goals

- Reward *conviction* (committing early, before the outcome is obvious) and
  *contrarianism* (backing the faction the crowd doesn't).
- Keep FP whole-valued and bounded — impressive numbers, not absurd ones.
- Keep the FT economy roughly conserved so balances stay meaningful.
- Never let a player go broke out of the game: a small courtesy allowance is
  always available.
- Zero gambling framing anywhere player-facing (see Vocabulary).

## Vocabulary (player-facing language)

Never use: bet, wager, gamble, stake, odds, pot, payout, winnings, cash out,
house, jackpot, earn/pay. Use instead:

| Concept              | Player-facing term                          |
|----------------------|---------------------------------------------|
| The feature          | **Foresight**                                |
| A wager              | a **prediction** / "calling the winner"      |
| Placing a wager      | **commit tokens** to a faction               |
| Stake                | **tokens committed**                         |
| The pot              | the **token pool**                           |
| Payout               | **settlement** / "predictions settled"       |
| Winnings             | **tokens recovered** + **points awarded**    |
| Odds                 | the **crowd's lean** (per-faction totals)    |
| Currency             | **Foresight Tokens (FT)**                    |
| Score                | **Foresight Points (FP)**                    |

Internal code follows the same discipline: `Foresight` context,
`Prediction` schema, `settle/1`, `tokens`, `points`.

## Rules

1. Every account starts with **100 FT**. FT are spent by committing them to
   a prediction and recovered (plus more) only by predicting correctly.
2. FP only ever go up. They are minted at settlement, never spent, never
   traded. They exist to show off.
3. Predictions are made from the **portal** (pre-game lobby), on Legacy,
   Flash, and Tactical matches, from the moment a match **starts** until its
   **winner is decided**. Not-yet-started matches can't be predicted:
   faction switching is only possible up to match start, so opening the
   window at the start line means the own-faction rule can't be dodged by
   predicting first and joining later. (A decided match lingers in a
   post-victory grace period before it tears down — predictions close at
   the decision, not the teardown, or sure-thing commits would be
   possible.) The portal also shows the current per-faction token totals
   and your own predictions.
4. Any number of tokens may be committed, up to your balance — with one
   exception: the **courtesy allowance**. Regardless of balance, an account
   may always commit up to **5 FT** on a match. Only **one** such credited
   prediction may be outstanding at a time, account-wide, until the match it
   rides on settles. (Prevents zero-balance spam.)
5. A player registered in a match may only commit tokens to **their own
   faction** — never against it. Accounts not in the match may back any
   faction — but if a spectator with active predictions later **joins** the
   match (late registration), those predictions are automatically returned
   (debited tokens come back; any courtesy-minted portion dissolves) and
   may be re-made under the participant rules. No pre-join gaming.
6. All of one account's predictions within a match must target the **same
   faction** (you can't hedge across factions).
7. Predictions are **final** — no cancelling, no reducing. You may add
   further predictions later (e.g. small early, bigger once confident); each
   is settled independently with its own timestamp.
8. A match's predictions **settle** only if all of these hold at match end:
   - more than two human players participated in the match;
   - at least **two distinct factions** received predictions;
   - the match produced a winning faction (not a manual kill/retirement).
   Otherwise the match is **void**: every committed token is returned, no
   points are minted. (Void is not a "refund" of a live prediction — it's
   the whole match's Foresight being called off.)
9. If the winning faction received **no predictions**, nobody recovers
   anything: all committed tokens are simply lost. The crowd was wrong.
10. Losing predictions lose exactly the tokens committed — nothing else.

## Settlement algorithm

All math happens once, at match end, when the true duration is known.

### Inputs

For a match that started at `t0` and whose winner was decided at `t1`, with
winning faction `w`:

- Each prediction `i`: tokens `s_i`, faction `f_i`, placement time `t_i`.
- `S_f` = total tokens committed to faction `f`; `S_total` = Σ over factions.
- `L` = Σ `S_f` for all `f ≠ w` (the losing side of the pool).

### Earliness weight

```
e_i = clamp((t_i − t0) / (t1 − t0), 0, 1)      # elapsed fraction; pre-start commits clamp to 0
E_i = 1 − e_i                                   # earliness, 1 = at match start
w_i = 1 + TIME_BOOST × E_i                      # TIME_BOOST = 1.0 → weight ∈ [1, 2]
```

Because `e_i` is a *fraction of the actual match duration*, the same rule
self-scales from a 3-week Legacy match to a 2-hour Flash match. A day-one
call is worth up to twice a last-minute one; steepness is one constant.

### Token settlement (conserved)

Winners get their own tokens back, and the losing pool `L` is divided among
them in proportion to their **time-weighted tokens**:

```
share_i = L × (s_i × w_i) / Σ_j (s_j × w_j)     # j over winning predictions
recovered_i = s_i + ceil(share_i)
```

Every fractional reward in the system **rounds up** — pool shares, the
early-call bonus, points. Remainders favor *every* player instead of being
assigned to one; the pool may over-distribute a few tokens per match, and
that is by design: the token economy is deliberately a little inflationary
(see the early-call bonus below), player attrition is the natural
counterweight, and seasonal resets are the escape hatch if growth ever
runs hot.

### Early-call bonus (the deflation offset)

Pure redistribution plus attrition would slowly starve the economy — lost
accounts take their tokens with them, and rule 9 burns more. The offset is
a small **minted** bonus that also nudges players toward the interesting,
early predictions:

```
B = ceil(BONUS_RATE × S_total)                  # 5% of the whole match pool
shares(account) = (1 if any correct prediction with e ≤ 0.5)
                + (1 if any correct prediction with e ≤ 0.25)
bonus(account)  = ceil(B × shares / Σ shares)
```

Shares are flat per account, not token-scaled — a whale gets the same
share as a 1-token caller — and only accounts whose predictions were
**correct** qualify (see open question 6; paying early losers would make a
1-token early commit on every match a farming strategy). Example: three
accounts predicted correctly within the first half, one of them (Brett)
also within the first quartile → 4 shares; Brett takes ceil(B × 2/4), the
other two ceil(B × 1/4) each. If no correct prediction was early, no bonus
is minted for that match.

### Point minting (positive-sum, whole, bounded)

```
U = clamp(S_total / S_w, 1, CONTRARIAN_CAP)     # crowd's lean against the winner
FP_i = min(ceil(s_i × U × w_i), MAX_POINTS_PER_PREDICTION)
```

- `U` is the parimutuel-style multiplier the user asked for: 50 FT on
  Tetrarchy vs 200 FT on Myrmezir → `U = 250/50 = 5` when Tetrarchy wins.
- Bounded: `U ≤ 5`, `w ≤ 2` → FP per prediction ≤ 10× tokens committed,
  hard-capped at `MAX_POINTS_PER_PREDICTION`.
- `U, w ≥ 1` → a correct prediction always mints at least its token count
  in FP, so whole values need no floor tricks.

### Constants (one config module, all tunable)

| Constant                    | Default | Meaning                                  |
|-----------------------------|---------|------------------------------------------|
| `STARTING_TOKENS`           | 100     | seed balance per account                  |
| `COURTESY_LIMIT`            | 5       | always-available commitment               |
| `TIME_BOOST`                | 1.0     | earliness steepness (weight = 1+boost×E)  |
| `CONTRARIAN_CAP`            | 5.0     | max crowd-lean multiplier                 |
| `BONUS_RATE`                | 0.05    | minted early-call bonus (share of pool)   |
| `MAX_POINTS_PER_PREDICTION` | 500     | FP hard cap per prediction                |
| `MIN_PLAYERS`               | 3       | humans required for settlement            |

### Worked example (the motivating one)

18-day match, Tetrarchy vs Myrmezir. Myrmezir is the crowd favorite with
**200 FT**; Tetrarchy has Alice (**30 FT on day 2**) and Bob (**20 FT on
day 12**). Tetrarchy wins.

| | Alice | Bob |
|---|---|---|
| Earliness `E` | 1 − 2/18 = 0.889 | 1 − 12/18 = 0.333 |
| Weight `w` | 1.889 | 1.333 |
| Weighted tokens | 56.7 | 26.7 |
| Share of 200-FT pool | **136 FT** | **64 FT** |
| Tokens recovered | 30 + 136 = **166** (5.5×) | 20 + 64 = **84** (4.2×) |
| Early-call bonus (B = ceil(5% × 250) = 13) | day 2 → first quartile → 2 of 2 shares → **+13** | day 12 → past halfway → **0** |
| FP (`U` = 250/50 = 5, capped) | ceil(30×5×1.889) = **284** | ceil(20×5×1.333) = **134** |

Myrmezir backers lose their 200 FT and mint nothing. Same tokens, same
faction, but Alice's week-1 conviction beats Bob's week-2 caution in pool
share, points, *and* the early-call bonus — she walks away with 179 FT on
a 30-FT commitment.

Counter-example, favorite wins: Cardan 200 FT vs Ediya 50 FT, Cardan wins.
`U = 250/200 = 1.25`; a 20-FT mid-match Cardan backer (w = 1.5) recovers
20 + ~7 and mints ceil(20×1.25×1.5) = 38 FP. Backing the obvious pick
pays modestly — the interesting numbers come from early, contrarian calls.

### Why FP stays sane

- FP throughput is bounded by FT throughput × 10, and FT grows slowly and
  predictably: inflow is the 100-FT seed, courtesy mints, round-ups, and
  the 5% early-call bonus; rule-9 burns, lost predictions, and player
  attrition are the sinks. If a season ever runs hot, a seasonal reset is
  the sanctioned valve.
- The per-prediction cap (500) stops one whale-sized lucky call from
  dwarfing a season of good ones. An engaged, accurate predictor nets
  ~100–300 FP per match — thousands over a season, never millions.
- If leaderboards ever skew toward large-balance players, the escape hatch
  is a sublinear stake term (`√s` instead of `s`) — noted, not needed for v1.

### Edge cases

- **Ties**: the engine cannot produce one. Faction ranking is a total order
  (equal victory points fall through to a continuous tie-break score —
  `lib/game/instance/victory/victory.ex:246-279`), so exactly one faction
  gets `final_rank = 1`. A Flash match hitting its time limit still yields
  a normal single winner (`victory_type: "win_on_time"`) and settles
  normally — it is not a draw.
- **Winner unbacked** (rule 9): all tokens burn, nothing distributed.
- **Void** (rule 8): every prediction returns the tokens that were actually
  debited from the balance; any courtesy-minted portion simply dissolves
  (the courtesy slot frees up), and no FP are minted. Returning the minted
  portion would let players farm tokens by committing the allowance to
  matches likely to void.
- **Spectator joins after predicting**: handled at join time — their active
  predictions on that match are returned automatically (rule 5). Settlement
  keeps a backstop: any faction-mismatch prediction that slips through is
  voided individually — tokens returned, no points.
- **Paused matches**: earliness is wall-clock between actual start and end;
  pauses distort it slightly and we accept that for v1.
- **Rounding**: everything rounds up, per prediction and per account —
  pool shares, bonus, FP. Nobody is ever shorted a fractional token.

## Data model

House conventions apply throughout: serial PKs, `timestamps(type:
:utc_datetime_usec)`, explicit indexes right after the table, a commented
rationale block above `def change` (see
`priv/repo/migrations/20260713000001_create_account_features.exs`).

### `accounts` — two new columns

```elixir
add(:foresight_tokens, :integer, null: false, default: 100)
add(:foresight_points, :integer, null: false, default: 0)
```

Pattern: `20260601000001_add_token_version_to_accounts.exs`. The
`default: 100` backfills every existing account — that *is* rule 1, no
seeding step needed. Both fields follow the house discipline for
system-owned counters (`lib/rc/accounts/account.ex:35-45`): never in a
user-castable changeset, written only by narrow context functions; added
to the `jason()` whitelist (`account.ex:12`) and to `account.json`
(`lib/portal/views/account_view.ex:16-31`, next to `money`).

### `foresight_predictions`

Template: `rankings` (`lib/rc/accounts/ranking.ex:6`) for shape,
`daily_entries` (`20260621000001`) for the no-FK decision.

| Column             | Type / constraint                                     |
|--------------------|-------------------------------------------------------|
| `account_id`       | `references(:accounts, on_delete: :delete_all)`, not null |
| `instance_id`      | plain `:bigint`, not null — **deliberately no FK**    |
| `faction_id`       | `:bigint`, not null — the per-instance `factions` row |
| `faction_ref`      | `:string`, not null — denormalized (`"tetrarchy"` …)  |
| `tokens`           | `:integer`, not null, validated > 0                   |
| `credited_tokens`  | `:integer`, not null, default 0 — courtesy-minted part; debited = `tokens - credited_tokens` |
| `status`           | `:string`, not null, default `"active"` — `active \| correct \| incorrect \| void` |
| `tokens_recovered` | `:integer`, nil until settled                         |
| `bonus_tokens`     | `:integer`, not null, default 0 — early-call bonus, credited on the account's earliest qualifying prediction |
| `points_awarded`   | `:integer`, nil until settled                         |
| `settled_at`       | `:utc_datetime_usec`                                  |
| timestamps         | `inserted_at` **is** the placement time `t_i` — never rewritten |

No FK on `instance_id` because instances are deletable in several states
(`lib/portal/controllers/instance_controller.ex:390`) and we need both
history to survive and the sweeper to *void* orphaned predictions rather
than have them silently cascade away with the tokens still debited —
exactly the rationale `daily_entries` documents. `faction_ref` keeps
history renderable after deletion.

Indexes:

```elixir
create(index(:foresight_predictions, [:instance_id]))
create(index(:foresight_predictions, [:account_id]))
# rule 4: at most one outstanding courtesy prediction per account
create(unique_index(:foresight_predictions, [:account_id],
  where: "credited_tokens > 0 AND status = 'active'",
  name: :foresight_predictions_one_active_courtesy))
```

### `foresight_settlements` — the exactly-once latch

Pattern: `victories` unique index (`lib/rc/instances/victory.ex:19`) +
`discord_daily_blasts` latch ("the unique index is the authority",
`lib/rc/discord/daily_blast_log.ex`).

| Column                | Notes                                              |
|-----------------------|-----------------------------------------------------|
| `instance_id`         | `:bigint`, **unique index** — settlement authority  |
| `outcome`             | `settled \| unbacked \| void_no_winner \| void_min_players \| void_single_faction \| void_instance_deleted` |
| `winning_faction_ref` | nil on voids                                        |
| `pool_tokens`, `tokens_recovered`, `points_minted` | summary ints, for ops/dashboard |
| `inserted_at`         | `timestamps(updated_at: false)`                     |

Settlement begins by inserting this row; a unique-violation means another
process already settled — stop. This makes the inline hook and the sweeper
safely concurrent.

## Backend integration

### Where "the match is decided" actually lives

Two-phase endgame, and the gap is load-bearing:

- **Decision** — `Instance.Victory.Agent.do_next_tick/2`, normal-multiplayer
  branch (`lib/game/instance/victory/agent.ex:151-179`): calls
  `RC.Instances.record_victory/2` (`lib/rc/instances.ex:740-755`), which in
  one Multi inserts the `victories` row (`victory_type`, unique per
  instance) and stamps `factions.final_rank` (1 = winner). **This is the
  only durable winner record** — there is no winner column anywhere; the
  winner is `factions WHERE instance_id = ? AND final_rank = 1`.
- **Teardown** — up to 200 unit-days later (and only once all players
  disconnect), the instance transitions to `"ended"` and its supervisor is
  destroyed (`agent.ex:183-194`).

Consequences: settlement (and the close of the prediction window) keys on
**the `victories` row, never on `state == "ended"`** — a decided match
stays `"running"` through its tail, and `"ended"` is also reached by
winner-less paths. `RC.Discord.DailyBulletin` already implements this
predicate (`left_join` victories, `where is_nil(v.id)` —
`lib/rc/discord/daily_bulletin.ex:88-99`); copy that shape.

Timing inputs (`instances` has no start/end columns):

- `t0` = `MIN(inserted_at)` of the instance's `instance_states` rows with
  `state = "running"` (MIN because resume/restart also write `"running"`).
- `t1` = `victories.inserted_at`.

### New modules

- **`RC.Foresight`** — context: placement, queries, settlement
  orchestration.
- **`RC.Foresight.Settlement`** — *pure* math module (no DB): takes
  predictions, `t0`, `t1`, winning `faction_id`, human player count →
  returns a settlement plan (per-prediction status, tokens, points, plus
  the match outcome). All the algorithm-section math lives here,
  exhaustively unit-testable like the `lib/daily` pure core.
- **`RC.Foresight.Sweeper`** — safety-net GenServer (below).
- **`Portal.ForesightController`** + routes.

### Placement — `RC.Foresight.commit(account, instance_id, faction_id, tokens)`

Precondition chain (`with` + atom sentinels, the
`Portal.RegistrationController.join/2` shape at
`lib/portal/controllers/registration_controller.ex:67-124`):

1. beta flag `foresight` enabled — note this is the **first server-side
   feature-flag check** in the codebase (existing flags are client-honored
   only); a small `RC.Accounts.feature_enabled?/2` helper over
   `list_features/1` (`lib/rc/accounts.ex:939`).
2. instance exists; `game_data["speed"] ∈ {"slow","medium","fast"}` (=
   Legacy/Tactical/Flash; excludes `"daily"`); not `is_bot_only`; not
   tutorial; state ∈ running/paused/not_running (i.e. the match has
   started — `"open"` is too early, rule 3).
3. **no `victories` row yet** (window closed at decision).
4. `faction_id` belongs to this instance; `faction_ref` snapshotted from it.
5. own-faction rule: if the account is registered in this match
   (`RC.Registrations.get_faction_id/2` via the profile join — remember
   registrations key on `profile_id`, not `account_id`, and have no
   `instance_id`; always go through `RC.Registrations` helpers), the
   predicted faction must equal their faction.
6. same-faction consistency: any prior predictions by this account on this
   instance must target the same `faction_id` (rule 6).
7. tokens > 0; balance/courtesy check (below).

Debit is race-safe without locks, using the codebase's one concurrency
idiom — conditional `update_all` (`RC.Offers.transition_status/3`,
`lib/rc/offers.ex:62-73`):

- Normal path: `UPDATE accounts SET foresight_tokens = foresight_tokens -
  $n WHERE id = $id AND foresight_tokens >= $n`; zero rows affected →
  insufficient.
- Courtesy path (only if insufficient **and** `tokens ≤ COURTESY_LIMIT`):
  compare-and-swap the remaining balance to zero, set `credited_tokens` to
  the shortfall; the partial unique index rejects a second outstanding
  courtesy prediction at insert time.

Debit + prediction insert compose in one `Ecto.Multi` (the
`update_account_money/4` + `money_transactions` shape,
`lib/rc/accounts.ex:404-411`). Rate-limit the endpoint with the inline
`Portal.Plug.AccountRateLimit` pattern
(`lib/portal/controllers/scenarios/map_controller.ex:43-56`).

### Join-time refund hook

`Portal.RegistrationController.join/2` gains one call on its success path:
`RC.Foresight.return_on_join(account_id, instance_id)` — voids the
account's active predictions on that match and returns the debited tokens
(rule 5), freeing the courtesy slot. Never-raise, same contract as the
settlement hook.

### Settlement — `RC.Foresight.settle(instance_id, ranking \\ nil)`

1. Insert the `foresight_settlements` latch; unique violation → already
   settled, return.
2. Load active predictions for the instance; none → record outcome, done.
3. Resolve winner: the `ranking` handed by the Victory agent (fast path) or
   `factions.final_rank == 1` (sweeper path). No winner → void.
4. Eligibility: human players ≥ `MIN_PLAYERS` (registrations ⋈ factions ⋈
   profiles, `profiles.is_bot == false` — the denormalized fast path,
   `lib/rc/accounts/profile.ex:16`); ≥ 2 distinct backed factions.
   Fail → void.
5. Individual voids (backstops — the join-time refund hook is the primary
   defense): predictor registered in a faction ≠ predicted; account with
   predictions on 2+ factions (race backstop for rule 6 — all that
   account's predictions in the match void).
6. Compute the plan in `RC.Foresight.Settlement` (pure), apply it as one
   reduce-into-Multi transaction (the `RC.Rankings.update_rankings/1`
   shape, `lib/rc/rankings.ex:104-116`): per-prediction status/results +
   per-account `update_all inc:` balance/points credits.
7. After commit, push per affected account on the existing authenticated
   per-account portal topic:
   `Portal.Controllers.PortalChannel.broadcast_change("portal:user:#{id}",
   %{foresight: ...})` (`lib/portal/channels/controllers/portal_channel.ex:18,135`)
   — reaches connected players with zero new plumbing; the prediction rows
   themselves are the durable record for everyone else.

### Hook + sweeper (both, deliberately)

- **Inline hook**: in the Victory agent's normal-multiplayer branch,
  immediately after `RC.Rankings.update_rankings/1`
  (`lib/game/instance/victory/agent.ex:157`):
  `RC.Foresight.settle(instance_id, export.ranking)`. Wrapped
  **never-raise** (the `RC.Instances.GovernmentStates.persist/5` pattern,
  `lib/rc/instances/government_states.ex:30-53`) — a settlement bug must
  not crash the Victory tick server — and nil-safe for engine instances
  with no DB row (the codebase's "headless" convention). The tutorial and
  daily branches already return before this point, which is exactly the
  exclusion we want.
- **`RC.Foresight.Sweeper`**: self-scheduling GenServer (no Oban/cron
  exists; template: `RC.Discord.RoleSync.deactivate_ended_matches/0`,
  `lib/rc/discord/role_sync.ex:256-273`, and `RC.BotMonitoring.Pruner`).
  Every 60s, for instances that still have active predictions:
  - `victories` row exists but no settlement → `settle/2` (missed hook,
    node restart);
  - state ∈ ended/maintenance with no `victories` row, or the `instances`
    row is gone → **void**;
  - `"not_running"` past a staleness horizon → void.
  `init/1` returns `:ignore` in `:test`
  (`lib/rc/discord/daily_challenge_blast.ex:61-62` precedent). Registered
  in `lib/rc/application.ex`.

The latch makes hook + sweeper concurrency-safe; the sweeper makes every
winner-less ending (admin Finish at
`lib/portal/controllers/instance_controller.ex:171-200`, LiveView
force_end, bot-only retirement, deletion, crash) resolve to a void instead
of tokens stuck in limbo forever.

### API

Routes in the plain authenticated scope (`lib/portal/router.ex:231`, same
as `/features` and `/daily/*`) — **not** the `:group_resource_authorization`
instance scope (see the trap documented at `lib/portal/router.ex:369-376`):

| Route | Purpose |
|---|---|
| `GET /api/instances/:iid/foresight` | per-faction totals ("crowd's lean"), your predictions, window open/closed |
| `POST /api/instances/:iid/foresight` | `{faction_id, tokens}` → commit |
| `GET /api/foresight` | balances + recently settled predictions ("what happened while you were away") |

Controller style: plain `json/2` maps like `Portal.DailyController`
(whose `leaderboard` + `you` shape at
`lib/portal/controllers/daily_controller.ex:88-104` matches the totals +
mine payload). Balances additionally ride on `account.json`.

### Beta gate

Add `foresight` to `@known` in `lib/rc/accounts/account_feature.ex:15` and
to `front/src/portal/pages/account/BetaFeatures.vue` (the documented
two-place recipe), plus the server-side `feature_enabled?/2` check in the
controller — new ground, since no existing flag is enforced server-side.

## Portal frontend

The SPA is Vue 2 + Vuex 3 + vue-i18n (en/fr/de), served at `/portal/`.
All strings go through i18n — add keys to all three locale files
(`front/src/locales/{en,fr,de}/portal.json`).

### Surfaces

1. **Instance detail page** (`front/src/portal/pages/Instance.vue`, route
   `/instance/:iid`) — the primary surface. It already shows factions,
   state, and speed before joining, and has a three-column layout:
   - **Right aside, overview branch** (`Instance.vue:178-214`): add a
     `<foresight-panel :iid>` next to the existing `<news-ticker>`
     (`Instance.vue:213`). Model it on
     `front/src/portal/components/NewsTicker.vue` — a self-contained,
     prop-driven, self-polling `panel-aside-info` block that drops in with
     one line. The panel shows: per-faction token totals ("the crowd's
     lean"), your predictions on this match, and the commit form
     (faction picker + token amount + confirm).
   - The commit form's disabled-state machine copies the registration
     panel (`Instance.vue:216-267`): balance check (`enoughFt` computed,
     like `enoughMoney` at `:387-393`), own-faction restriction, match
     ended, etc.
   - **Crowd's-lean bar**: reuse the faction-button capacity gauge
     (`Instance.vue:109-119`, styles
     `front/src/styles/portal/panel/instance.scss:52-93`) with
     `faction_tokens/total_tokens` instead of
     `registrations_count/capacity` — faction theme colors already tint
     the fill.
2. **Navbar token chip** (`front/src/portal/layouts/Default.vue:68-100`):
   the unread-messages button (`:86-93`) is an icon+badge pattern — copy
   it for a globally visible FT counter. FP can live beside it or only on
   the account page.
3. **Account page** (`front/src/portal/pages/account/Info.vue:47-64`):
   two read-only rows for FT balance and FP total. (There's a dormant
   `page.account_money` locale block showing this was the intended
   pattern for currency display.) Optionally later: a dedicated
   `/account/foresight` tab (3-step recipe used by Beta Features:
   route child in `front/src/router.js:99-101`, nav link in
   `Account.vue:26-28`, page component) listing prediction history and
   settlement results.
4. **Listing rows** (`front/src/portal/components/InstanceRow.vue`,
   optional polish): a small "pool: N FT" chip on matches with active
   predictions.
5. **Standings** (`front/src/portal/pages/Standings.vue`, future): an FP
   leaderboard is a near-copy of the existing elo table.

### Data flow

- No repository layer — components call `this.$axios` directly
  (wrapper: `front/src/plugins/axios.js`, auto-attaches the bearer token).
  Store-owned data goes through Vuex actions like the beta-features pair
  `fetchFeatures`/`setFeature` (`front/src/portal/store.js:275-286`).
- Add FT/FP to the account payload (`Portal.AccountView`
  `account.json`, which already carries `money`) or a small
  `/api/foresight` balance endpoint; mirror the existing
  `updateAccountMoney` mutation (`front/src/portal/store.js:110-112`)
  for optimistic decrement on commit.
- Faction identity: predictions key on the per-instance faction row
  (`faction.id` from `instance_full.json`) with `faction_ref` for
  display — name via i18n `data.faction.<ref>.name`, logo via
  `<svgicon :name="'faction/' + ref">`, color via `theme-<theme>` class.

### Icon

`vue-svgicon` with hand-authored icon modules. Placeholder options that
exist today: `eye` (thematically on-the-nose for Foresight), `victory`,
`resource/credit`, `ranking` (for FP). A proper icon later = new
`front/src/icons/resource/foresight.js` (copy `resource/credit.js`
format) + one `require` line in `front/src/icons/resource/index.js`;
art can come from the style-LoRA pipeline when ready.

## Implementation phases

All tests run in the container (`docker compose exec rc mix test ...`).

1. **Pure core + schema.** Migrations (accounts columns,
   `foresight_predictions`, `foresight_settlements`);
   `RC.Foresight.Settlement` pure module + config constants; exhaustive
   unit tests: pool conservation (Σ shares == L exactly, largest-remainder),
   earliness clamping, caps, unbacked winner, every void variant, courtesy
   dissolution on void, whole-value invariants. No game code touched.
2. **Placement + API.** `RC.Foresight.commit/4` with the full precondition
   chain and race-safe debit; `Portal.ForesightController` + routes; beta
   flag `foresight` (schema whitelist + server-side check); controller
   tests including courtesy-index and same-faction conflicts.
3. **Settlement wiring.** Latch table logic, `settle/2`, the never-raise
   Victory-agent hook, the sweeper, the `portal:user:<id>` push.
   Integration tests: decided match settles once (hook + sweeper racing),
   admin Finish voids, deleted instance voids.
4. **Portal frontend.** Vuex additions (balances on account payload),
   `ForesightPanel` on `Instance.vue`, navbar token chip, account Info
   rows, locale keys ×3 (en/fr/de).
5. **Polish / later.** FP leaderboard on Standings, a proper token icon
   (style-LoRA pipeline; `eye` svgicon as placeholder), `InstanceRow` pool
   chip, optional hardening: add `winning_faction_id` to `victories`
   inside `record_victory/2` (it already holds the winner at
   `lib/rc/instances.ex:741-742`) so the winner stops being derivable only
   via `final_rank`.

## Chosen defaults & open questions

Items 1–4 started as defaults and are now **confirmed decisions**
(user-reviewed 2026-08-15):

1. **Spectators may predict** any faction; participants only their own.
   A spectator who joins a match they've predicted gets those predictions
   auto-returned at join time and may re-commit (rule 5).
2. **Any inconclusive ending returns all committed tokens** — "no refunds"
   means no voluntary cancellation only.
3. **Prediction window = match start → winner decided.** Opening at start
   (not at visibility) removes the predict-then-switch-faction problem
   outright, since faction choice is locked once the match starts. Closing
   at the decision (the `victories` insert, not teardown) blocks
   sure-thing commits during the post-victory tail.
4. **Continuous earliness** rather than week-tier cliffs — nothing to game
   at tier boundaries, and it scales to Flash durations automatically.
5. **Beta-gated** at launch behind an account feature flag (`foresight`),
   using the existing beta-features touchpoint recipe.

Still open (flagged, not blocking):

6. **Bonus eligibility reading**: "split among those that earned anything"
   is implemented as *correct predictions only* — paying early losers
   would make a 1-token early commit on every match a farming strategy.
   One predicate in `RC.Foresight.Settlement` flips it if the friendlier
   reading (any early participant) is preferred.

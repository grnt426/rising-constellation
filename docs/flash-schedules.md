# Scheduled Flash matches

Weekly Flash matches at a fixed time, so players know when to show up.
Players can still create their own Flash matches.

## Pieces

| Piece | Where |
|---|---|
| Schedules, occurrences, lobby rules, start, expiry | `lib/rc/flash_schedules.ex` |
| Tables | `flash_schedules`, `flash_scheduled_matches`, `registrations.ready_at` (migration `20260917000001`) |
| Minute tick | `RC.FlashSchedules.Scheduler` (not started in test) |
| #lfg posts | `RC.Discord.FlashAnnouncer`, channel `DISCORD_LFG_CHANNEL_ID` |
| API | `Portal.FlashScheduleController` — `GET /api/flash/schedules`, admin `POST/PUT/DELETE /api/flash/schedules[/:id]`, `PUT /api/flash/matches/:iid/ready`, `POST /api/flash/matches/:iid/start` |
| Schedule page | `front/src/portal/pages/play/FlashSchedule.vue` (`/play/fast/schedule`), calendar + admin form under `front/src/portal/components/flash/` |
| Lobby panel | `front/src/portal/components/flash/ScheduledLobby.vue` on the instance page |

## Schedule

- One weekday + start time per schedule, in **US Eastern** wall-clock
  (DST-aware, via `RC.Discord.EasternTime`). The page shows every time
  in the viewer's own zone.
- Map pool (Flash scenarios) **rotates in order**, one map per week,
  counted in whole weeks from `anchor_date` (the day the schedule was
  created). Editing the pool keeps the week count.
- `mutator_keys`: `nil` keeps each map's own mutators, `[]` forces none,
  a list overrides them.
- `game_mode_type` ranked/casual. The admin form defaults Tuesday
  schedules to Ranked.
- `min_players` (≥ 2) and `faction_capacity` (blank = the New Game
  default, systems / 6 / factions).
- Disabling a schedule stops future lobbies; lobbies already created
  are unaffected.

## Lifecycle of a scheduled match

1. **T − 2h**: the scheduler creates a public, pre-registration Flash
   instance (owner = the schedule's admin), publishes it and inserts the
   `flash_scheduled_matches` row (the unique `(schedule_id,
   scheduled_start_at)` index makes this idempotent). If the server was
   down, a slot is still created up to 1h after its start. #lfg post.
2. **Lobby**: players join any faction and **ready up**. A ready player
   can't unjoin (`unready_first`) until they unready. The lobby panel
   polls with the instance page (5 s).
3. **Start**: allowed once the start time has passed, the ready count is
   at least `max(2, min_players, ceil(80% of joined players))`, and ready
   players sit in at least two factions. Any **ready** player may press
   Start. The row flips `open → starting` atomically, joins are refused,
   unready players are removed, and the world is built in a background
   task (`starting → started`, or back to `open` on failure).
4. **Expiry**: a lobby still `open` 48h after its start time is closed
   (`ended`, status `expired`).
5. **Result**: once a started match has a `victories` row, #lfg gets the
   winner, the winning faction's players and the VP standings.

The owner/admin **Start** button is hidden for scheduled matches so the
ready-up rules and the unready cleanup can't be bypassed.

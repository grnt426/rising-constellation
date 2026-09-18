# Scheduled Flash matches

Weekly Flash matches at a fixed time, so players know when to show up.
Players can still create their own Flash matches.

## Pieces

| Piece | Where |
|---|---|
| Schedules, occurrences, lobby rules, start, expiry | `lib/rc/flash_schedules.ex` |
| Tables | `flash_schedules`, `flash_scheduled_matches`, `registrations.ready_at` (migrations `20260917000001`, `20260918000001`) |
| Minute tick | `RC.FlashSchedules.Scheduler` (not started in test) |
| #lfg posts | `RC.Discord.FlashAnnouncer`, channel `DISCORD_LFG_CHANNEL_ID` |
| Discord guild scheduled events | `RC.Discord.FlashEvent` |
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

1. **T − 48h**: the scheduler creates a public, pre-registration Flash
   instance (owner = the schedule's admin), publishes it and inserts the
   `flash_scheduled_matches` row (the unique `(schedule_id,
   scheduled_start_at)` index makes this idempotent). If the server was
   down, a slot is still created up to 1h after its start. #lfg post, and
   a **Discord guild scheduled event** linking the new lobby.
   The lobby description is the schedule's text (or a short default)
   followed by a fixed line: "Players not ready at start are removed. If
   not started within 48hrs of start time, this match auto-closes."
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

## Discord guild scheduled event

Each occurrence also gets an event in the community guild
(`RC.Discord.FlashEvent`), so members can mark themselves interested and
be pinged when it starts. It is an `EXTERNAL` event whose **location is
the lobby URL**; the #lfg announcement links back to it.

- Created with the lobby at T − 48h, never for a lobby whose start has
  already passed (Discord refuses a start time in the past).
- Runs from the scheduled start to start + the scenario's `time_limit`
  (wall-clock minutes; 120 if the map doesn't say).
- The description carries the live counts — registered players, ready
  players, how many more are needed — and is re-pushed only when they
  change (`discord_event_digest`), so an idle lobby costs no API calls.
- Status follows the match: `SCHEDULED` while open, `ACTIVE` once it
  starts (with the player count), `COMPLETED` with the final standings
  on a victory, `CANCELLED` when the lobby expires. Discord only allows
  `SCHEDULED → ACTIVE → COMPLETED`, so the scheduler advances one step
  per tick.
- **The bot needs the *Manage Events* permission in the community
  guild.** Without it the create is refused once, the row is latched to
  `discord_event_status = "failed"` so ticks don't retry every minute,
  and the match still gets its #lfg post. Clear the column to retry.

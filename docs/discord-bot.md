# Discord bot (Tetrarchy Falls)

The Discord bot lives in the main `RC.*` namespace under `RC.Discord.*` and
runs as a sub-tree of the main OTP supervisor. It is **disabled by default**:
without `DISCORD_BOT_TOKEN` set in env at boot, `RC.Discord.init/1` returns
`:ignore` and nothing about the rest of the app changes.

The bot operates in **one guild: the community server**. Until 2026-08
there was a second, Legacy-games guild; it has been retired and every
bot function folded into the community server (see "Legacy guild
retirement" below).

This document is the operator-facing setup; for the design rationale
(why guild commands, why Nostrum) see the earlier scoping discussion in
the project history.

## Files

| Path | Purpose |
| ---- | ------- |
| `lib/rc/discord.ex` | Supervisor + on/off entry point + guild-id helpers |
| `lib/rc/discord/consumer.ex` | Nostrum event handler (`:READY`, `:INTERACTION_CREATE`) |
| `lib/rc/discord/commands.ex` | Slash command registry + dispatch (incl. the /promote start-time modal) + retired-guild command cleanup |
| `lib/rc/discord/legacy_match.ex` | Promotion: faction categories + on-demand faction roles, pairwise diplomacy channels, announcements, teardown |
| `lib/rc/discord/news.ex` | Immediate-feed renderers + victory embeds (pure) |
| `lib/rc/discord/news_relay.ex` | Posts the immediate feed + victory announcements |
| `lib/rc/discord/bulletin.ex` | Daily-summary slot math + rendering (pure) |
| `lib/rc/discord/daily_bulletin.ex` | Daily-summary scheduler (posts once a day per match) |
| `lib/rc/discord/gov_relay.ex` | Faction-government election news + leadership role sync |
| `lib/rc/discord/role_sync.ex` | Faction role assignment during a match's active window |
| `config/runtime.exs` | Reads env vars, configures `:nostrum` and `:rc, RC.Discord` |
| `.env.example` | Documents the env-var contract |

## Env vars

| Var | Required? | Notes |
| --- | --------- | ----- |
| `DISCORD_BOT_TOKEN` | one of these two | Bot token, literal value |
| `DISCORD_BOT_TOKEN_FILE` | one of these two | Path to a file containing the trimmed token. Wins if both are set. Recommended for prod (keeps the token off `ps`) |
| `DISCORD_COMMUNITY_GUILD_ID` | required* | Server ID of the community guild — the bot's only guild |
| `DISCORD_GAME_GUILD_ID` | retired | Old Legacy-games guild. While still set, every boot bulk-deletes the bot's slash commands off that guild (client cleanup); nothing else touches it. Unset once the bot has been kicked from the old server |
| `DISCORD_NEWS_CHANNEL_ID` | optional | Channel id of the **match-feed** channel in the community guild. Gets the 5-minute rolling feed, VP roll-ups, the daily summary bulletin, election news, and victory posts. May be the SAME channel as `#game-news` below — every poster dedups when the two ids match. Unset = no rolling feed |
| `DISCORD_COMMUNITY_GAME_NEWS_CHANNEL_ID` | optional | Channel id of `#game-news` in the community guild (prod: `1533832123302023319`). Gets the 6-hour digest, a mirror of the daily summary bulletin (skipped when identical to the match-feed channel), and the daily-challenge winners blast. Unset = none of those post there |
| `DISCORD_DIPLO_CATEGORY_ID` | optional | Category id **in the community guild** under which `/promote` creates pairwise inter-faction diplomacy channels for matches with more than two factions. Verified at promote time — a category from another guild (e.g. the old diplo-ground id) is rejected with a warning and the bot creates its own per-match category instead. Unset = per-match category |

\* Without the community guild id the bot logs a warning and stays
dormant — there's nothing for it to do without somewhere to register
commands.

## Legacy guild retirement (2026-08)

All Legacy-match features were consolidated into the community server;
the old "Tetrarchy Falls - Legacy" guild is dead weight. What changed
in the bot:

- `/promote`, `/teardown`, `/cleardeploy` register on the community
  guild (they were game-guild-only).
- Faction roles (`tetrarchy-legacy` … `ark-legacy`) and leadership
  roles (`faction-leader`, `cabinet-econ`, `cabinet-military`) are
  **created on demand** on the community guild — no manual role setup.
- Faction emoji render from the community guild's uploads everywhere
  (the old game-guild emoji ids died with the bot's membership there).
- On every boot, while `DISCORD_GAME_GUILD_ID` is still set, the bot
  bulk-deletes its slash commands from the old guild.

Prod env checklist for the cutover (`/etc/rc/env`):

1. Point `DISCORD_NEWS_CHANNEL_ID` at a community-guild channel — the
   simplest merge is the `#game-news` id (`1533832123302023319`); a
   dedicated `#match-feed` channel keeps the rolling feed separate
   from digests. (The old value was the Legacy `#news`, which the bot
   can no longer post to.)
2. Ensure `DISCORD_COMMUNITY_GAME_NEWS_CHANNEL_ID=1533832123302023319`.
3. Remove `DISCORD_DIPLO_CATEGORY_ID` (old value was a Legacy-guild
   category; the bot now creates a per-match category), or set it to a
   community-guild category id.
4. Restart, watch for the "cleared all commands from retired game
   guild" log line, then kick the bot from the Legacy server (Server
   Settings → Members) and delete `DISCORD_GAME_GUILD_ID` from env.

## Role hierarchy — keep bot-managed roles below `bots`

Discord only lets the bot grant/remove roles that sit strictly BELOW
its own top role (`bots`). Roles the bot creates on demand (faction,
seat, `TZ:`) land at the bottom of the role list, which satisfies
this. **If you reorder roles in Server Settings, keep them below
`bots`** — dragging a faction role above it makes every assignment
fail with `403` code `50013` (this stranded role sync on 2026-08-22;
the log hint now names the fix). Color/hoist are fine at any allowed
position. `RC.Discord.RoleSync` runs a drift pass every 10 minutes
that re-reconciles every account in every active match, so once the
order is corrected, stranded members heal automatically.

## What posts where (feature map)

All game-event posting is gated on the instance being `discord_ready`.
Times below are US Eastern wall time (`America/New_York`, so EST/EDT is
automatic).

**Player profile cards (`/player <username>`).** Renders a
PNG stats card (avatar art, favorite faction/icon, official-legacy
wins, daily-challenge podiums, factions played) for the named profile —
but only when the owning account enabled **Show Profile in Discord** on
the Account → Link Discord page. Data assembly (`RC.Discord.PlayerCard`)
is the privacy boundary: game stats and profile flavor only, never
account fields. Falls back to a text summary when no rasterizer backend
is available. The command's description doubles as the picker tooltip
("opt-in snapshot — no personal info").

**Timezone role tags (`RC.Discord.TimezoneRole`).** Accounts that set a
timezone and enable the role tag get a guild role like `TZ: Europe/Paris`
on their linked member. Roles are
created **on demand** — never pre-generated (there are hundreds of IANA
zones) — looked up case-insensitively by name, and swapped out when the
player's timezone changes, on unlink, or when the opt-in is turned off.
Sync is event-driven (account update, link, unlink) and best-effort;
empty leftover roles are not garbage-collected today.

**Promotion (`/promote legacy`).** After picking the instance, a modal
asks for the real start time (`YYYY-MM-DD HH:MM` Eastern, or a unix
timestamp). That time is what the registration announcement renders —
`opening_date` is only a fallback — and it also drives the role-sync
activation window (start − 6h). Faction categories + channels are
created in the community guild; any missing faction role
(`tetrarchy-legacy` etc.) is **created on demand** at promote time.
For matches with **more than two factions**, promotion additionally
creates one private text channel per faction pair (`#ark-card`,
`#card-myr`, …), visible to both factions' roles, under
`DISCORD_DIPLO_CATEGORY_ID` (or a bot-made category). `/teardown`
removes exactly the channels the bot created.

**Rolling feed (match-feed channel, 5-minute buckets).** Only events every
player can already see on the galaxy map post: sector control changes,
every colonization, every dominion flip (incl. liberations and
abandonments), and victory-point movement. Battles, bombardments,
pillages, conquests, covert ops, and galaxy firsts do NOT post live.
Map-ownership changes batch into one message per 5-minute bucket — the
first event posts, followers EDIT that message into a digest; sector
control changes ride in the same bucket as the ownership changes that
caused them. VP movement keeps its own per-faction roll-up message.

**Community feed (`#game-news`, 6-hour buckets).** The same events
accumulate into one message per instance per 6 hours (edited in
place), organized as one section per faction — sectors gained/lost,
systems settled/lost, dominions flipped/lost, every entry signed
`+`/`−` — plus a victory-track line with each faction's latest VP and
a running total of system/dominion changes by faction (signed) and by
sector at the bottom. When the match-feed channel is a distinct
channel it additionally gets a territory-only card per window;
same-channel setups get the full card once.

**Daily-challenge blast (all configured news channels).** At 07:45 UTC — 45
minutes after the daily rotates (`Daily.today/0`, 07:00 UTC) — the bot
congratulates the ended day's top 3 (in-game name, plus Discord
display name when linked; plain text, never an @-mention) and previews
the newly-active challenge using the objective/mutator copy the daily
page serves. Latched per date in `discord_daily_blasts`.

**Daily summary bulletin (match-feed channel + `#game-news` mirror
when distinct).** Once a day per running
match, in a random 30-minute slot between 12:00 and 14:00 Eastern, the
bot posts a digest: battle counts with per-faction win/loss records
and ratios, conquest/bombard/pillage tallies, and the window's galaxy
firsts (named). The data cutoff is a *hidden* random 30-minute slot
between 07:00 and 11:00 Eastern — both slots derive deterministically
from (date, stored per-match random secret), so they reshuffle daily
and can't be predicted or reconstructed by players. Two-faction
matches get full detail (player records, system names); matches with
more factions get faction-level tallies only. A missed or paused day
folds into the next bulletin; nothing is dropped.

**Victory.** When a `discord_ready` match concludes, the bot posts
"Congrats to [faction]!" embeds to the community announce channel and
the match-feed channel (once, when those are the same channel).

**Faction government (match-feed channel).** Election lifecycle news
only: elections opening, seats filled (with the player's Discord
display name appended when linked — never an @-mention), failed
elections, depositions, dissolutions, ARK challenges. Patents, lexes,
taxes, and policy changes never broadcast. Seat holders also get/lose
the leadership roles (`faction-leader`, `cabinet-econ`,
`cabinet-military` — looked up by name on the community guild and
created on demand; see `RC.Discord.GovRelay`).

## Local dev setup

1. Populate `.env` at the repo root. The simplest path is to point the
   bot at the secret file directly:

   ```
   DISCORD_BOT_TOKEN_FILE=F:/projects/rising-constellation/.secrets/bot_token.txt
   DISCORD_COMMUNITY_GUILD_ID=1513721325162594435
   ```

2. Bring up the dev stack: `docker compose up` (after running the
   worktree port-setup script — see the worktree's `CLAUDE.md`).

3. Watch the Phoenix logs. On boot you should see:

   ```
   [info] [RC.Discord] starting bot supervisor
   [info] [RC.Discord] gateway connected as <bot-name>#0000
   [info] [RC.Discord.Commands] registered /ping on guild 1513...
   ```

4. In the community server, type `/ping`. The bot should respond
   with `pong — N game instances in the database`.

## Prod setup

The prod env file at `/etc/rc/env` (per `prod_ssh_access.md`) is the right
place. Either:

- Drop the token into AWS Secrets Manager alongside other secrets and
  have `rc-fetch-secrets` write it into the env file as
  `DISCORD_BOT_TOKEN=...`, **or**
- Place the token in a root-owned file (e.g. `/etc/rc/discord-token`,
  mode 0400) and set `DISCORD_BOT_TOKEN_FILE=/etc/rc/discord-token`.
  The file approach keeps the token from showing up in `systemctl
  show rc.service --property=Environment` output.

Restart with `systemctl restart rc.service` and tail the journal to
confirm the same boot-time log lines as in dev.

## Account linking

The bot can recognize game accounts via Discord-side commands once a
player links the two together. The flow:

1. Player logs into the game website, goes to **Account → Link Discord**,
   and clicks **Generate code**. The Vue page POSTs to
   `/api/discord/link-code`; the backend mints a one-time code (8 chars
   from a Crockford-style alphabet, displayed as `XXXX-XXXX`) with a
   5-minute TTL and returns it.
2. Player runs `/link code:XXXX-XXXX` in Discord. The bot looks up the
   code in `discord_link_codes`, validates it, and in a single
   transaction marks it consumed + writes `accounts.discord_id`.
3. Subsequent bot features (role assignment, DMs, slash queries) can
   look up the player via `RC.Accounts.Discord.get_account_by_discord_id/1`.

`/unlink` clears the link. Because it's destructive, it shows an
ephemeral confirmation message with a "Confirm unlink" button rather
than acting immediately. The `custom_id` on the button encodes the
invoker's Discord ID so a button click from a different user (which
can't normally happen — ephemeral messages are user-scoped — but
defense-in-depth) is rejected.

### Code format & security

- Alphabet: `23456789ABCDEFGHJKLMNPQRSTUVWXYZ` (no O/0/I/L/1 — easy to
  read aloud or copy from a phone). 32^8 ≈ 1.1 trillion combinations.
- TTL: 5 minutes from mint to use. Past that, `consume_code/2` returns
  `:expired`.
- One live code per account at a time: minting a new code
  best-effort expires any prior unconsumed codes for the same account.
- Rate limit: 30 mints per hour per source IP, via `Portal.Plug.RateLimit`.
- Unique constraint on `accounts.discord_id` means a single Discord
  identity can only attach to one game account; second attempt gets
  `:discord_already_linked`.

### Schema

```
accounts.discord_id : string, nullable, unique
discord_link_codes  : code (unique), account_id (FK), inserted_at,
                      consumed_at (nullable for one-shot semantics)
```

See migration `20260609000001_add_discord_linking.exs`. The choice of
`:string` (not `:decimal` like `steam_id`) is documented there — short
version: Discord's API always returns snowflakes as strings.

## Adding a new slash command

Single place to touch: `lib/rc/discord/commands.ex`.

1. Add a map to `@commands` with at least `name`, `description`, and
   `type: @cmd_type_chat_input`. See [Discord's
   ApplicationCommand](https://discord.com/developers/docs/interactions/application-commands)
   reference for `options` (sub-arguments) if the command takes input.
2. Add a `handle/2` clause matching the new command name.
3. Redeploy. On next `:READY` (which fires immediately on bot start),
   `register_all/0` POSTs the updated definitions to each configured
   guild — Discord upserts by name, so no manual cleanup needed.

Removing a command requires a separate `delete_guild_command/3` call —
unregistered commands stick around in the Discord client until removed
explicitly. Worry about that when we actually retire one.

## Design notes worth preserving

- **`runtime: false` on the `:nostrum` dep** in `mix.exs` is deliberate.
  Nostrum's application supervisor crashes hard if it boots without a
  configured token. We start it manually from `RC.Discord.init/1` only
  after confirming a token is present, so dev environments without the
  secret don't blow up the whole release.
- **Guild commands, not global commands.** Guild commands propagate to
  the Discord client cache instantly; global commands can take up to
  an hour. Since the bot is intentionally private to one known guild,
  there's no downside to guild scope.
- **Token-from-file support** in `runtime.exs` exists so the token can
  live in a 0400 file rather than the process env. AWS Secrets Manager
  rotation can write to that file without restarting the process —
  though Nostrum doesn't currently watch for token changes, so a
  restart is still needed to pick up a rotated token.

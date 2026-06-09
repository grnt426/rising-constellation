# Discord bot (Tetrarchy Falls)

The Discord bot lives in the main `RC.*` namespace under `RC.Discord.*` and
runs as a sub-tree of the main OTP supervisor. It is **disabled by default**:
without `DISCORD_BOT_TOKEN` set in env at boot, `RC.Discord.init/1` returns
`:ignore` and nothing about the rest of the app changes.

This document is the operator-facing setup; for the design rationale (why
two servers, why guild commands, why Nostrum) see the earlier scoping
discussion in the project history.

## Files

| Path | Purpose |
| ---- | ------- |
| `lib/rc/discord.ex` | Supervisor + on/off entry point + guild-id helpers |
| `lib/rc/discord/consumer.ex` | Nostrum event handler (`:READY`, `:INTERACTION_CREATE`) |
| `lib/rc/discord/commands.ex` | Slash command registry + dispatch |
| `config/runtime.exs` | Reads env vars, configures `:nostrum` and `:rc, RC.Discord` |
| `.env.example` | Documents the env-var contract |

## Env vars

| Var | Required? | Notes |
| --- | --------- | ----- |
| `DISCORD_BOT_TOKEN` | one of these two | Bot token, literal value |
| `DISCORD_BOT_TOKEN_FILE` | one of these two | Path to a file containing the trimmed token. Wins if both are set. Recommended for prod (keeps the token off `ps`) |
| `DISCORD_COMMUNITY_GUILD_ID` | optional* | Server ID of the public community guild |
| `DISCORD_GAME_GUILD_ID` | optional* | Server ID of the Legacy-games guild |

\* At least one guild ID must be set, or the bot logs a warning and stays
dormant — there's nothing for it to do without somewhere to register
commands.

## Local dev setup

1. Populate `.env` at the repo root. The simplest path is to point the
   bot at the secret file directly:

   ```
   DISCORD_BOT_TOKEN_FILE=F:/projects/rising-constellation/.secrets/bot_token.txt
   DISCORD_COMMUNITY_GUILD_ID=1513721325162594435
   DISCORD_GAME_GUILD_ID=1513870799583576215
   ```

2. Bring up the dev stack: `docker compose up` (after running the
   worktree port-setup script — see the worktree's `CLAUDE.md`).

3. Watch the Phoenix logs. On boot you should see:

   ```
   [info] [RC.Discord] starting bot supervisor
   [info] [RC.Discord] gateway connected as <bot-name>#0000
   [info] [RC.Discord.Commands] registered /ping on guild 1513...
   ```

4. In either Discord server, type `/ping`. The bot should respond
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
  an hour. Since the bot is intentionally private to two known guilds,
  there's no downside to guild scope.
- **Token-from-file support** in `runtime.exs` exists so the token can
  live in a 0400 file rather than the process env. AWS Secrets Manager
  rotation can write to that file without restarting the process —
  though Nostrum doesn't currently watch for token changes, so a
  restart is still needed to pick up a rotated token.

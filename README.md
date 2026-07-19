# Tetrarchy Falls (formerly Rising Constellation)

## License

This project contains parts released under different licenses:

### Images / Visuals

All images or visual assets are released under [Attribution-NonCommercial 4.0 International (CC BY-NC 4.0)](https://creativecommons.org/licenses/by-nc/4.0/), *Copyright 2021 Clément Chassot / Loïc Lebas*.

### Music

All music files or sound assets are released under [Attribution-NonCommercial 4.0 International (CC BY-NC 4.0)](https://creativecommons.org/licenses/by-nc/4.0/), *Copyright 2021 Jérôme Clavien*.

### Source Code

The combined source code of this project is released under the [PolyForm Noncommercial License 1.0.0](https://polyformproject.org/licenses/noncommercial/1.0.0), *Copyright 2026 Grant Kurtz*. See [LICENSE](LICENSE) for the full text.

This project began as a fork of work originally released under the MIT license, *Copyright 2021 Gil Clavien*. That original MIT grant remains in effect for the code it covers; the MIT notice is preserved in [LICENSE-MIT](LICENSE-MIT) as required by the MIT license.

## Local Setup (Docker)

The recommended local setup runs everything inside Docker — no need to install Erlang, Elixir, or Node on the host. Works on Linux, macOS, and Windows (Docker Desktop).

### Prerequisites

* Docker (with Docker Compose v2)
* `make` (optional but recommended; the Makefile wraps the common `docker compose` invocations)

### Quick Start

```sh
docker compose up -d
```

First boot takes a few minutes (downloads deps, compiles Elixir, runs `npm install`, creates and seeds the DB). Subsequent boots are fast — the entrypoint hashes `mix.lock` and the npm lockfiles and only re-runs the installs when something changed.

When it's up:

* **Phoenix:** <http://localhost:4000>
* **Portal (Vue), via Phoenix dev proxy:** <http://localhost:4000/portal/> — works but slow on first load; Phoenix's HTTPoison-based dev proxy buffers the 7MB chunk-vendors.js in memory before sending. Fine for occasional access.
* **Portal (Vue), direct:** <http://localhost:8080/portal/> — recommended. Vue dev server proxies `/api` and `/socket` back to Phoenix on :4000, so the session works.
* **Postgres:** `localhost:5432` (user `postgres`, password `postgres`, database `gateway_dev`)

### Daily Commands

If you have `make` installed:

```sh
make up           # start the stack in the background
make logs         # tail rc logs
make shell        # bash inside the rc container (as the rc user)
make iex          # iex -S mix inside the rc container
make psql         # psql into the dev database
make migrate      # run pending migrations
make seed         # (re)run priv/repo/seeds.exs
make reset-db     # drop, create, migrate, seed (DESTROYS dev data)
make test         # run mix test inside the container
make format       # mix format
make credo        # mix credo --strict (advisory)
make down         # stop containers (volumes preserved)
```

Without `make`, the equivalents are visible in the [Makefile](Makefile).

### What's inside the stack

* **`db`** — `postgres:12`, data persisted in the `pgdata` named volume.
* **`rc`** — the Phoenix app (`mix phx.server`) plus two file watchers (`webpack` for `assets/` and `vue-cli-service serve` for `front/`). The Phoenix dev proxy fetches `/portal/*` from `localhost:8080` server-side, so you only need to talk to port 4000 from your browser. Code is bind-mounted from your working tree, so edits hot-reload.
* Named volumes (`rc-deps`, `rc-build`, `rc-assets-node-modules`, `rc-front-node-modules`, `rc-state`) hold `deps/`, `_build/`, and the two `node_modules/` trees so that Linux-only NIFs and Windows host IO don't fight each other.

The `rc` container runs as user `rc` (uid 1001), matching the prod image.

### Restoring a Production DB Backup

Production backs itself up nightly (`pg_dump` + game-snapshot tarball) to
`s3://rc-prod-backups-553872001542/` via `rc-db-backup.timer` — see
[`deploy/DISASTER-RECOVERY.md`](./deploy/DISASTER-RECOVERY.md) for the
restore drill and the full rebuild runbook.

To load a dump into the local dev stack, see
[`db-restore.sh`](./db-restore.sh) — note that the script references a
hard-coded dump filename; edit it before running.

## Tests

```sh
make test                                   # via Makefile (Docker)
docker compose exec -u rc rc \
  bash -c 'MIX_ENV=test mix do deps.get --only test, ecto.create --quiet, ecto.migrate --quiet, test'
```

The test config honors `RDBMS_HOST` so the in-container run hits the compose `db` service.

## Distributed Local Setup (legacy, host-side)

The `make a` / `make b` / `make c` targets still spin up named Erlang nodes locally if you want to play with libcluster manually. These require a host install of Elixir/Erlang and aren't part of the Docker stack.

To shut down a node, type `:init.stop` in its iex prompt.

## Frontend Assets

### Vue Project (`front/`)

* For images and fonts referenced as `url()` in CSS or `src=""` in HTML, put assets in `public/` (e.g. `public/foo/bar.png`) and reference them as `~public/foo/bar.png`.
* Other static assets: put them in a subfolder of `public/` (e.g. `public/media/foo.pdf`) and they become available at `/portal/media/foo.pdf`. From a Vue component, link with a relative URL, e.g. `href="media/foo.pdf"`.

### Phoenix (HTML / LiveView) Assets

Files under `assets/static/` are served at `/`. For example, `assets/static/FOO/logo.png` is served at `/FOO/logo.png`.

## Deployment

You changed code and want it on https://tetrarchyfalls.com. Two steps:
**build** a release tarball, then **deploy** it (scp → stop → extract →
migrate → start, with running games snapshotted and restored around the
restart).

### Where to run everything

**All commands below run in your local terminal — git-bash on Windows,
the system shell on Linux/macOS.** They drive Docker and SSH; nothing
is typed into PowerShell, into the EC2 host directly, or in WSL.

The **build itself runs inside a Docker container**, not on your dev
machine. The dev machine doesn't need Elixir, Erlang, or Node installed —
only Docker Desktop. `docker buildx` ships your repo into an Ubuntu image
that has all three, compiles there, and pops the tarballs back out via
`docker cp`. This is why the recipe works identically on Windows, macOS,
or Linux.

Prerequisites already on this dev machine:
- Docker Desktop running.
- The EC2 key pair at `~/.ssh/rc-prod.pem` (git-bash sees this as
  `/c/Users/<you>/.ssh/rc-prod.pem`).
- `nodes.sh` defaults to the live host — no `RC_SSH_HOST` / `SSH_KEY` /
  `RC_SSH_PORT` env vars needed unless you're deploying somewhere else.

### Production host

**Match the build's platform to where the build will run.** Local
development — `docker compose up` for the dev stack — runs natively on
your dev machine: amd64 on Windows/Linux x86 hosts, arm64 on Apple
Silicon. The dev image's bits never reach prod, so native is always
right for it; don't add a `--platform` flag to anything in the [Local
Setup (Docker)](#local-setup-docker) flow. The deploy build is the
opposite case: the tarballs `docker buildx` produces below ARE the prod
binary, so they must be compiled for the **prod instance's**
architecture — not yours.

Prod is currently **arm64** (Graviton2). Every deploy build recipe below
uses `docker buildx build --platform linux/arm64 --load` to target it.
NIFs in the release tarball (argon2_elixir, appsignal, ssl_verify_fun)
are arch-specific .so files; a tarball built without the platform flag
on an amd64 host will fail to start on prod with `Exec format error`.
On an amd64 dev machine the deploy build runs under QEMU emulation:
about 25–40 min for a full build (Vue + backend), 15–20 min for
backend-only — slower than native but unattended. On an Apple Silicon
dev machine, the same recipe runs natively at full speed.

If prod's instance type is ever swapped to a different arch (e.g. back
to x86 on an m6i, or forward to a newer Graviton ISA), the `--platform`
value in the deploy recipes is the one place that needs to change.

| Property | Value |
| --- | --- |
| Instance ID | `i-017d81bd1155ebfb3` |
| Type | `t4g.large` (Graviton2, 2 vCPU, 8 GB RAM) |
| Architecture | `arm64` (`aarch64-unknown-linux-gnu`) |
| AMI | `ami-0210135d98f11a45f` (Ubuntu 22.04 jammy, arm64) |
| Public DNS | `ec2-98-91-16-141.compute-1.amazonaws.com` |
| Region / AZ | `us-east-1` / `us-east-1c` |
| Public URL | <https://tetrarchyfalls.com> (via ALB `rc-prod-alb`) |
| Target group | `rc-prod-tg` (HTTP:80) |
| Root volume | 30 GB gp3, `DeleteOnTermination=false` |

On disk:
- `/home/rc/rc/` — current release (overwritten on each deploy)
- `/home/rc/www-root/asylamba/{static,front}/` — Vue + Phoenix assets
- `/var/lib/rc-snapshots/` — game-state snapshots (survive deploys)
- `/etc/rc/secret.json` — raw secret JSON (mode 0600 root:root). **This
  is the actual source of truth for prod env vars** — the
  `rc-fetch-secrets` service is configured with an
  `RC_SECRET_FILE=/etc/rc/secret.json` override (see
  `/etc/systemd/system/rc-fetch-secrets.service.d/override.conf`),
  which makes it read the local file and skip AWS Secrets Manager
  entirely. To change a secret in prod: edit this file, then
  `sudo systemctl restart rc-fetch-secrets.service && sudo systemctl restart rc.service`.
- `/etc/rc/env` — derived `KEY='value'` lines for `systemd EnvironmentFile`
- Postgres 14 is local on the box; no host port binding
- `rc-db-backup.timer` dumps the DB + snapshot dir to S3 nightly at
  08:47 UTC (see `deploy/DISASTER-RECOVERY.md`)

**Rollback target.** The previous amd64 host (`i-0e47138cd400b3a5d`,
t3.small, x86_64) is retained in a stopped state with its root volume
preserved. If a deploy or the new host needs to be backed out within the
first weeks after the swap, start that instance, register it with the
ALB target group, deregister the arm64 host. The volume on the old
instance has `DeleteOnTermination=false` so it survives even an
accidental terminate.

### One command

```sh
./deploy/release.sh           # build HEAD and ship it
./deploy/release.sh <git-ref> # build a specific ref and ship it
```

That's the whole deploy. The script does: stamp `priv/VERSION` → preflight
ssh to prod (fail-fast reachability check + raise the player-facing
deploy notice via `RC.Deploy`) → build arm64 tarballs (`--no-cache` by
default) → extract → `deploy/bin/deploy.sh` → verify the deployed
revision against the request → run a per-instance maintenance-state
recovery pass → clear/finish the deploy notice → print a pass/fail
summary.

The preflight connection also triggers the SSH-key approval prompt
(1Password) at the start of the run — while you're still watching —
instead of after a half-hour build.

### Deploy notice

The preflight calls `RC.Deploy.start_deploy()` on prod, which flips a
persistent flag (survives the mid-deploy restart) and announces the
upcoming interruption to players: the portal news marquee switches to a
deployment banner, every live game's chat gets a SYSTEM line, late
joiners get the line re-asserted on join, and while an instance is
paused mid-deploy the in-game "Paused" headband reads "Interruption for
updates. Please reconnect" instead. On success (`PASS`/`PARTIAL`) the
script calls `finish_deploy()` — flag down plus an "update applied,
refresh recommended" chat line. On failures, interrupts (ctrl-C), and
`set -e` aborts, it best-effort calls `clear_deploy()`.

If the script dies without clearing (killed terminal, network gone), the
notice stays up: an admin clears it with the **`/cleardeploy`** Discord
slash command (admin-linked accounts only, registered on the game
guild), or via rpc on the host:
`./rc/bin/rc rpc 'RC.Deploy.clear_deploy()'` (env-source first).

A successful run ends with:

```
========================================
  RELEASE SUMMARY (f9e221e)
========================================
  prod revision : f9e221e (match)
  restored      : 1 10
  failed        : none
========================================
  RELEASE: PASS
```

A revision-mismatch failure (the 2026-06-07 incident — Docker layer cache
silently shipping an old `priv/VERSION`) ends with `RELEASE: FAIL` and a
nonzero exit. A partial — deploy succeeded but some game instance
couldn't be brought out of maintenance — ends with `RELEASE: PARTIAL`
and exits 2; the failing IDs and reasons are listed in the summary so
the operator can `ssh` in and investigate.

Wall-clock on amd64-emulating-arm64: ~30–50 min for the full build,
~15–25 min for backend-only. On Apple Silicon it runs natively.

### Options

```sh
RC_BACK_ONLY=1   ./deploy/release.sh   # skip the Vue rebuild
RC_SKIP_BUILD=1  ./deploy/release.sh   # reuse existing build/*.tar.gz
RC_NO_CACHE=0    ./deploy/release.sh   # allow Docker layer cache
VUE_APP_BASE_URL=https://example ./deploy/release.sh   # override public URL
```

`RC_NO_CACHE=1` is the default because cache poisoning of the `COPY .`
layer has shipped a stale revision to prod before. Set `RC_NO_CACHE=0`
only when iterating fast and verifying the result by inspection.

`RC_BACK_ONLY=1` does NOT touch `build/vue.tar.gz`. The existing one is
re-shipped; if its sha256 matches the one stored at
`.secrets/last_vue_sha`, `deploy.sh` skips the CloudFront invalidation
automatically.

### Prerequisites on the dev machine

* Docker Desktop running.
* EC2 key at `~/.ssh/rc-prod.pem`.
* `bash` (Windows: git-bash; Linux/macOS: system shell).
* AWS CLI + `.secrets/access_key.csv` (only needed for CloudFront
  invalidation; without them the deploy still succeeds and prints a
  warning).

### Make wrappers

`make build` / `make build-back` / `make deploy` are thin shims over
`release.sh` and work the same way. The script is the source of truth;
the Makefile targets exist so `make` users don't have to re-learn the
flags. On Windows (no `make`), call `release.sh` directly.

### Failure classification

The pass/fail logic lives in [deploy/release.sh](deploy/release.sh) at
the "verify deployed revision" and "per-instance maintenance recovery"
sections. If you need to extend the deploy with a new check, add it
there and emit a `[release] ...` progress line plus a summary line —
don't add a new manual step to this README.

Edge cases the script does NOT handle (and what to do):

- **`rc.service` won't start after deploy** — the script will hang at
  `[release] running deploy/bin/deploy.sh`. Investigate on the host:
  `OnFailure=` writes capture files to `/var/log/rc/`;
  `sudo cat /var/log/rc/index.log` lists every failure.
- **`Exec format error` on boot** — release tarball was built for the
  wrong architecture. Should not happen via `release.sh` (always
  `--platform linux/arm64`), but if you hand-built with plain
  `docker build`, rebuild via the script. Verify on the host:
  `file /home/rc/rc/erts-*/bin/beam.smp` should report `ARM aarch64`.
- **Migration failed mid-deploy** — service stays stopped; the script
  fails at the same point `deploy.sh` does. Fix the migration on disk,
  redeploy.
- **Concurrent deploy** — `deploy.sh` flocks `/tmp/rc-deploy.lock` on
  the remote (10-min wait). The script doesn't add its own lock; don't
  fire two `release.sh` runs in parallel.
- **Vue change didn't take effect in the browser** — CloudFront edge
  cache (script invalidates `/portal/*` automatically when `vue.tar.gz`
  changed) or browser cache. Hard refresh.

For env-var contract and broader context, see [DEPLOYMENT.md](./DEPLOYMENT.md)
and [.env.example](./.env.example).

### AWS provisioning credentials

The `deploy.sh` path above is SSH-only and doesn't need AWS API access.
But anything that touches AWS resources directly (provisioning a new
host, updating the CloudFront distribution, rotating Secrets Manager
values, etc. — see [deploy/aws-setup.md](./deploy/aws-setup.md) for the
IAM user and its policy) reads credentials from `.secrets/` at the
repo root. The directory is gitignored.

Expected layout:

```
.secrets/
  access_key.csv       # console-exported CSV for the rc-prod IAM user
                       # (header: "Access key ID,Secret access key")
```

The CSV is the unmodified file you download from the IAM console when
you create the access key. To use it with the AWS CLI in this shell:

```sh
# Skip the BOM + header, read the single data row.
read -r AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY < <(
  tail -n +2 .secrets/access_key.csv | tr -d '\r\xef\xbb\xbf' | tr ',' ' '
)
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
export AWS_REGION=us-east-1
```

If `aws sts get-caller-identity` returns an unexpected user — e.g. one
from a different project that happens to be your shell default — that's
the signal to run the snippet above before re-issuing the command.

Other files under `.secrets/` are cached provisioning artifacts (ALB
ARN, ACM cert ARN, hosted-zone ID, etc.) written by ad-hoc setup runs.
They're informational and safe to delete; re-running the relevant `aws`
describe calls will reproduce them.

## Troubleshooting (Docker stack)

**Container won't start / port 4000 already taken** — `docker compose ps` and `docker compose logs rc`. If port 4000 is in use on the host, stop the other process or edit the port mapping in [`docker-compose.yml`](./docker-compose.yml).

**First boot fails on `mix deps.get` or `npm install`** — usually a transient network issue. Re-run `docker compose up -d`; the entrypoint resumes where it left off (hashes are only written on success).

**Stale node_modules after a `package.json` change** — `docker compose down && docker volume rm rising-constellation_rc-front-node-modules && docker compose up -d`. (Same pattern for `assets`.)

**"too many clients already" from postgres during tests** — already mitigated; the compose file boots postgres with `max_connections=200`. If you bump test pool size, raise this too.

**Want to wipe everything and start fresh** — `docker compose down -v` removes all named volumes (DB included).

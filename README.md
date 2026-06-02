# Rising Constellation

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

See [`db-restore.sh`](./db-restore.sh) — note that the script references a hard-coded dump filename; edit it before running.

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

You've got a code change and want it on https://tetrarchyfalls.com. Two
steps: **build** a release tarball in Docker, then **deploy** it (scp →
stop service → extract → migrate → restart).

`deploy/bin/deploy.sh` does the deploy half. It reads three env vars to
find the host:

```sh
RC_SSH_HOST=rc@ec2-98-91-17-9.compute-1.amazonaws.com
SSH_KEY=$HOME/.ssh/rc-prod.pem
RC_SSH_PORT=22
```

(Defaults in `nodes.sh` are placeholders. The current values are also
recorded in `.secrets/provisioned.txt`.)

### Backend-only change (Elixir/EEx)

Fastest path — skips Vue rebuild. Tarball is ~150 MB (priv/static gets
bundled when build-front.sh is skipped); the scp uplink is the slow part.

On Linux/macOS:
```sh
VUE_APP_BASE_URL=https://tetrarchyfalls.com make build-back
RC_SSH_HOST=rc@ec2-98-91-17-9.compute-1.amazonaws.com \
SSH_KEY=$HOME/.ssh/rc-prod.pem \
RC_SSH_PORT=22 \
  ./deploy/bin/deploy.sh
```

On Windows (no `make` installed — current dev machine):
```sh
docker build -t rc_build_image \
  --build-arg APP_REVISION=$(git --no-pager describe --always --dirty) \
  --build-arg BACK_ONLY=true \
  --build-arg VUE_APP_BASE_URL=https://tetrarchyfalls.com \
  --build-arg VUE_APP_APPSIGNAL_FRONT= \
  .
docker rm -f extract 2>/dev/null
docker create --name extract rc_build_image >/dev/null
docker cp extract:/home/rc/build/rc.tar.gz ./build/
docker rm extract
RC_SSH_HOST=rc@ec2-98-91-17-9.compute-1.amazonaws.com \
SSH_KEY=$HOME/.ssh/rc-prod.pem \
RC_SSH_PORT=22 \
  ./deploy/bin/deploy.sh
```

### Frontend change (Vue, assets)

Full build — also produces fresh `vue.tar.gz` for nginx to serve.
`BACK_ONLY=false`. Adds ~5–10 min for npm + webpack + vue-cli-service.

On Linux/macOS:
```sh
VUE_APP_BASE_URL=https://tetrarchyfalls.com make build
RC_SSH_HOST=rc@ec2-98-91-17-9.compute-1.amazonaws.com \
SSH_KEY=$HOME/.ssh/rc-prod.pem \
RC_SSH_PORT=22 \
  ./deploy/bin/deploy.sh
```

On Windows: same docker incantation as the backend case but
`--build-arg BACK_ONLY=false`, and `docker cp` both tarballs (add
`docker cp extract:/home/rc/build/vue.tar.gz ./build/`).

### Verify

```sh
# Service up?
curl -sI https://tetrarchyfalls.com/api/maintenance
# Live release revision (matches `git describe`):
ssh ubuntu@ec2-98-91-17-9.compute-1.amazonaws.com \
  'sudo journalctl -u rc.service -n 1 --no-pager | grep -oE "releases/[^/]+"'
# Tail the service for a minute to make sure no crash:
ssh ubuntu@ec2-98-91-17-9.compute-1.amazonaws.com \
  'sudo journalctl -fu rc.service'
```

`deploy.sh` itself ends with a `systemctl status rc.service` snapshot;
the `active (running) since ...` line at the bottom is the green light.

### When something goes wrong

- **Migration failed mid-deploy** — service stays stopped (deploy.sh
  exits on the failed step). Investigate via journalctl, fix, redeploy.
- **rc.service won't start after deploy** — `OnFailure=` writes a
  capture file to `/var/log/rc/`. `sudo cat /var/log/rc/index.log` lists
  every failure; the file itself has journal, memory snapshot, dmesg.
- **Vue change didn't take effect in browser** — old bundle cached.
  Hard refresh (Ctrl+Shift+R), or clear browser cache.

For broader context — env-var contract, full provisioning history,
architecture — see [DEPLOYMENT.md](./DEPLOYMENT.md).

## Troubleshooting (Docker stack)

**Container won't start / port 4000 already taken** — `docker compose ps` and `docker compose logs rc`. If port 4000 is in use on the host, stop the other process or edit the port mapping in [`docker-compose.yml`](./docker-compose.yml).

**First boot fails on `mix deps.get` or `npm install`** — usually a transient network issue. Re-run `docker compose up -d`; the entrypoint resumes where it left off (hashes are only written on success).

**Stale node_modules after a `package.json` change** — `docker compose down && docker volume rm rising-constellation_rc-front-node-modules && docker compose up -d`. (Same pattern for `assets`.)

**"too many clients already" from postgres during tests** — already mitigated; the compose file boots postgres with `max_connections=200`. If you bump test pool size, raise this too.

**Want to wipe everything and start fresh** — `docker compose down -v` removes all named volumes (DB included).

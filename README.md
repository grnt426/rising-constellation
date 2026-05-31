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
* **Portal (Vue):** <http://localhost:4000/portal/>
* **Vue dev server (direct, for HMR):** <http://localhost:8080>
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

```sh
make build upload
```

* `make build` compiles the 3 frontends into a tar.gz and the backend as a release into a tar.gz, then extracts these archives. Done inside Docker so the build matches the prod target OS.
* `make upload` `scp`s the archives to a remote server (see `nodes.sh`).

Prod servers don't have the source code or Node installed; they only run the release.

### Adding a Production Node

1. Create an instance from image `prod-template-1`.
2. Add the IP as an A record to `nodes.rising-constellation.com`.
3. In the node's bashrc, after the existing `APPSIGNAL_PUSH_API_KEY` and `RELEASE_COOKIE` exports:

```sh
export RELEASE_NODE=rc@163.172.181.27  # the new node's IP
```

## Troubleshooting (Docker stack)

**Container won't start / port 4000 already taken** — `docker compose ps` and `docker compose logs rc`. If port 4000 is in use on the host, stop the other process or edit the port mapping in [`docker-compose.yml`](./docker-compose.yml).

**First boot fails on `mix deps.get` or `npm install`** — usually a transient network issue. Re-run `docker compose up -d`; the entrypoint resumes where it left off (hashes are only written on success).

**Stale node_modules after a `package.json` change** — `docker compose down && docker volume rm rising-constellation_rc-front-node-modules && docker compose up -d`. (Same pattern for `assets`.)

**"too many clients already" from postgres during tests** — already mitigated; the compose file boots postgres with `max_connections=200`. If you bump test pool size, raise this too.

**Want to wipe everything and start fresh** — `docker compose down -v` removes all named volumes (DB included).

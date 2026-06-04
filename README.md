# Rising Constellation

## License

This project contains parts released under different licenses:

### Images / Visuals

All images or visual assets are released under [Attribution-NonCommercial 4.0 International (CC BY-NC 4.0)](https://creativecommons.org/licenses/by-nc/4.0/), *Copyright 2021 Clément Chassot / Loïc Lebas*.

### Music

All music files or sound assets are released under [Attribution-NonCommercial 4.0 International (CC BY-NC 4.0)](https://creativecommons.org/licenses/by-nc/4.0/), *Copyright 2021 Jérôme Clavien*.

### Source Code

Source code is released under the MIT license, *Copyright 2021 Gil Clavien*.

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
only Docker Desktop. `docker build` ships your repo into an Ubuntu image
that has all three, compiles there, and pops the tarballs back out via
`docker cp`. This is why the recipe works identically on Windows, macOS,
or Linux.

Prerequisites already on this dev machine:
- Docker Desktop running.
- The EC2 key pair at `~/.ssh/rc-prod.pem` (git-bash sees this as
  `/c/Users/<you>/.ssh/rc-prod.pem`).
- `nodes.sh` defaults to the live host — no `RC_SSH_HOST` / `SSH_KEY` /
  `RC_SSH_PORT` env vars needed unless you're deploying somewhere else.

### Backend-only change (Elixir / EEx / config)

Fastest path; skips the Vue rebuild. Docker build is ~1–2 min after the
layer cache is warm; the scp to EC2 is the slow part (~150 MB upload).

If you have `make` (Linux/macOS — `make` isn't on Windows by default):
```sh
VUE_APP_BASE_URL=https://tetrarchyfalls.com make build-back
./deploy/bin/deploy.sh
```

Without `make` (Windows git-bash, plain docker invocation — does the
exact same thing the Makefile target wraps):
```sh
docker build -t rc_build_image \
  --build-arg APP_REVISION=$(git --no-pager describe --always --dirty) \
  --build-arg BACK_ONLY=true \
  --build-arg VUE_APP_BASE_URL=https://tetrarchyfalls.com \
  .
docker rm -f extract 2>/dev/null
docker create --name extract rc_build_image >/dev/null
docker cp extract:/home/rc/build/rc.tar.gz ./build/
docker rm extract
./deploy/bin/deploy.sh
```

### Frontend change (Vue, assets, CSS)

Full build — also produces a fresh `vue.tar.gz` for nginx. Adds ~5–10
min on top of the backend build for npm install + webpack + vue-cli-service
(all inside the same Docker container — still no local Node needed).

With `make`:
```sh
VUE_APP_BASE_URL=https://tetrarchyfalls.com make build
./deploy/bin/deploy.sh
```

Without `make`: same as the backend recipe, but flip `BACK_ONLY=false`
and add a second `docker cp` for `vue.tar.gz`:
```sh
docker build -t rc_build_image \
  --build-arg APP_REVISION=$(git --no-pager describe --always --dirty) \
  --build-arg BACK_ONLY=false \
  --build-arg VUE_APP_BASE_URL=https://tetrarchyfalls.com \
  .
docker rm -f extract 2>/dev/null
docker create --name extract rc_build_image >/dev/null
docker cp extract:/home/rc/build/rc.tar.gz ./build/
docker cp extract:/home/rc/build/vue.tar.gz ./build/
docker rm extract
./deploy/bin/deploy.sh
```

### What the build args mean

| arg | what it does | when to change |
| --- | --- | --- |
| `APP_REVISION` | tag baked into the release (shows in `bin/rc start`'s `releases/$REVISION/...` path and in error reports). `$(git describe --always --dirty)` is the convention. | leave as-is |
| `BACK_ONLY` | `true` skips the Vue compile (no fresh `vue.tar.gz`). `false` does the full build. | `true` for backend-only changes |
| `VUE_APP_BASE_URL` | baked into the Vue bundle — Vue's axios uses this as the API root and WebSocket base. **Must match the public URL.** | only when changing the public hostname |
| `VUE_APP_APPSIGNAL_FRONT` | AppSignal frontend integration key. AppSignal is the third-party APM the codebase originally shipped with. We're not using it; it's optional and defaults to empty. | leave unset / omit |

### Verify

```sh
# Service up?
curl -sI https://tetrarchyfalls.com/api/maintenance

# Live release revision (should match `git describe` from the build):
ssh -i ~/.ssh/rc-prod.pem ubuntu@ec2-98-91-17-9.compute-1.amazonaws.com \
  'sudo journalctl -u rc.service -n 5 --no-pager | grep -oE "releases/[^/]+" | head -1'

# Tail the service to make sure no crash post-deploy:
ssh -i ~/.ssh/rc-prod.pem ubuntu@ec2-98-91-17-9.compute-1.amazonaws.com \
  'sudo journalctl -fu rc.service'
```

`deploy.sh` itself ends with a `systemctl status rc.service` snapshot;
`active (running) since ...` is the green light.

### Watching for game preservation

When a game is mid-play, the deploy output should include:

```
[remote] deploy lock acquired (pid …)
[remote] snapshotting running instances
[pre-stop] N instance(s) to snapshot
[pre-stop] snapshotted instance …
…
[remote] waiting for new release to accept rpc
[remote] restoring snapshotted instances
[post-start] N instance(s) to restore
[post-start] restored instance …
```

If you see `[pre-stop] FAILED` or `[post-start] rpc never became
reachable`, the game is in maintenance state on the server and won't
auto-resume. Recover with:

```sh
ssh -i ~/.ssh/rc-prod.pem rc@ec2-98-91-17-9.compute-1.amazonaws.com \
  'cd /home/rc && set -a && . /etc/rc/env && set +a && \
   ./rc/bin/rc rpc "
     import Ecto.Query
     RC.Repo.all(from i in RC.Instances.Instance, where: i.state == \"maintenance\", select: i.id)
     |> Enum.each(fn iid ->
       i = RC.Instances.get_instance(iid)
       RC.Instances.restore_instance(i, 1) |> IO.inspect(label: \"restore \#{iid}\")
     end)
   "'
```

### When something goes wrong

- **Migration failed mid-deploy** — service stays stopped (deploy.sh
  exits on the failed step). Investigate via `journalctl`, fix, redeploy.
- **`rc.service` won't start after deploy** — `OnFailure=` writes a
  capture file to `/var/log/rc/`. `sudo cat /var/log/rc/index.log` lists
  every failure; each file has journal, memory snapshot, dmesg.
- **Vue change didn't take effect in the browser** — old bundle cached.
  Hard refresh (Ctrl+Shift+R), or clear the cache.
- **Concurrent deploy** — `deploy.sh` takes a flock on the remote
  (`/tmp/rc-deploy.lock`); a second deploy waits up to 10 min. Don't
  fire two deploys in parallel.

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

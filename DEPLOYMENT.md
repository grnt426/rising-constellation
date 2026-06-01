# Deployment

This document captures the current state of production deployment for Rising
Constellation. The codebase was originally deployed by its prior maintainers to
custom VMs at `a-new-rising.space` (planned) / `rising-constellation.com`
(historic), with secrets baked into the release at build time. This deploy is
being modernized for AWS (EC2 + Secrets Manager).

**Status:** in-progress modernization. Not yet production-ready.

## Target topology (intended end state)

- One EC2 instance running the Phoenix release (`mix release` tarball).
- nginx on the same instance, terminating TLS and serving static assets from
  disk; reverse-proxies `/api` and `/socket` to Phoenix on `localhost:4000`.
- PostgreSQL on RDS (or co-located on the EC2 instance for cheap single-node
  staging).
- Object storage (S3 or compatible) for Waffle user uploads.
- Mail via Mailjet (current adapter; swappable).
- Secrets in AWS Secrets Manager, materialized into env vars on the host
  before the release boots (e.g. via a systemd `EnvironmentFile=` populated by
  a small fetch script on instance start).
- Single-node only initially. Clustering is supported by the codebase
  (libcluster + Horde) but disabled by default — opt in via `RC_CLUSTER_DNS`.

## How a release boots

1. Build artifacts produced by `make build`:
   - `build/rc.tar.gz` — OTP release (Phoenix backend + digested Phoenix
     assets bundled inside `priv/static/`)
   - `build/vue.tar.gz` — `www-root/` tree containing the Phoenix static dir
     and the compiled Vue SPA
2. Both tarballs scp'd to the EC2 instance.
3. `rc.tar.gz` extracted under `/home/rc/` and started with env vars set.
4. `vue.tar.gz` extracted under `/home/rc/www-root/` (or similar); nginx
   docroot points at it.
5. Phoenix listens on `127.0.0.1:4000` for API + WebSocket.
6. nginx fronts everything on `:443`.

The current `make upload` script (and `nodes.sh`) targets the legacy host
`prod002` over SSH. EC2 deployment will need a refreshed `nodes.sh` or a
replacement deploy script — see TODO §3.

## Env-var contract

The release reads runtime configuration from environment variables via
`config/runtime.exs`. See [`.env.example`](.env.example) for the canonical list
with comments. In production these come from AWS Secrets Manager; in local
Docker dev they're either set in `docker-compose.yml` or fall back to defaults
in `config/dev.exs` / `config/config.exs`.

Missing required vars at boot will crash the release with a clear message —
intentionally, so misconfigured deploys fail loudly instead of silently
booting under a placeholder identity.

## Static asset hosting model

Three asset classes, each served differently:

| Asset class                | Built into                          | Served by               | Path           |
| -------------------------- | ----------------------------------- | ----------------------- | -------------- |
| Phoenix static (CSS/JS)    | `priv/static/` via `mix phx.digest` | nginx from `www-root/`  | `/`            |
| Vue SPA (game portal)      | `front/dist/` via `vue-cli-service` | nginx from `www-root/`  | `/portal/*`    |
| User uploads (Waffle)      | n/a, runtime                        | S3 directly             | `$S3_ASSET_HOST` |

In dev, Phoenix serves everything (including a proxy to the Vue dev server on
`:8080`). In prod, nginx serves static files directly; Phoenix never sees
those requests.

A reference nginx vhost lives at
[`deploy/nginx/rc.conf.example`](deploy/nginx/rc.conf.example). It is not
consumed automatically — copy it to the prod host and adapt.

## Deployment Readiness TODO

Tracks the work remaining to make this reproducibly deployable to a fresh EC2
instance. Move items between sections as they land; tick the box when done.

### Tier 1 — required for a first deploy

- [x] **Move dynamic prod config to `config/runtime.exs`.** URL host, rc_domain,
  mailer creds, S3, Stripe, secret_key_base, Guardian key, AppSignal, GELF,
  libcluster query — all env-driven. See `config/runtime.exs` and `.env.example`.
- [x] **Strip prod secrets / hostnames from `config/config.exs` and
  `config/prod.exs`.** Dev defaults remain in `config.exs` (clearly labeled);
  prod overrides come from env at runtime.
- [x] **Make Vue build env-driven.** `build-front.sh` reads `VUE_APP_BASE_URL`
  and `VUE_APP_APPSIGNAL_FRONT` from env (fails if not set). `steam-auth.js`
  uses the same Vue env var.
- [x] **Update user-visible templates.** CGU support email and press kit site
  URL read from config instead of being hardcoded.
- [x] **Check in a reference nginx vhost.** `deploy/nginx/rc.conf.example`.
- [x] **Document the env-var contract.** `.env.example`.
- [x] **Run Ecto migrations on release boot.** `RC.Release` already existed
  at `lib/release.ex` — invoked by `deploy/bin/deploy.sh` via
  `bin/rc eval "RC.Release.migrate()"` between extract and service start.
- [x] **Replace the SCP deploy with something EC2-aware.** `deploy/bin/deploy.sh`
  scps tarballs, stops rc.service, extracts, runs migrate, restarts. Hosts
  come from `nodes.sh` (now keyed off `RC_SSH_HOST` + `SSH_KEY` env vars).
  `make deploy` is the entry point.
- [x] **Write a systemd unit + bootstrap script for the rc user.** Units in
  `deploy/systemd/`, fetcher in `deploy/bin/rc-fetch-secrets` (pulls a JSON
  secret from AWS Secrets Manager → /etc/rc/env), and `deploy/bin/bootstrap-host.sh`
  is the one-shot installer for a fresh Ubuntu 22.04 EC2 instance.
- [x] **End-to-end deploy verified locally.** `deploy/test/run-local-test.sh`
  spins up a privileged Ubuntu 22.04 container, runs the same
  `bootstrap-host.sh` and `deploy.sh` we'd run on EC2 (using a local secret
  file instead of AWS Secrets Manager — see `RC_SECRET_FILE` mode in
  `deploy/bin/rc-fetch-secrets`), and confirms all four route classes
  return 200. Caught ~11 real bugs that would have failed silently on EC2.
- [ ] **Verify a clean boot end-to-end on AWS EC2.** Pending the AWS
  account-verification hold. See `deploy/aws-setup.md` — all upstream
  resources (key pair, security group, IAM role, Secrets Manager secret)
  already provisioned per `.secrets/provisioned.txt`.

### Tier 2 — first-deploy polish

- [ ] **Provision EC2 with a one-shot bootstrap script.** Keep IaC minimal:
  one bash script that installs nginx, drops the systemd unit, fetches secrets
  from AWS Secrets Manager into the env file, and creates the `rc` user.
- [ ] **Pick + provision the S3 bucket.** Current config references a defunct
  Scaleway bucket. Create a real bucket and update `S3_*` env vars.
- [ ] **Pick + provision the mail provider.** Mailjet template IDs in
  `config/config.exs` reference templates that no longer exist. Either
  recreate in your Mailjet account or swap adapters (Swoosh supports
  Postmark, SendGrid, SES, etc.).
- [ ] **Document a backup story for the DB.** `db-restore.sh` has a hardcoded
  dump filename and isn't fit for prod use. RDS automated backups are the easy
  path; document the restore drill.
- [ ] **Lock down LiveDashboard.** Currently mounted with no auth guard.

### Tier 3 — running a service

- [ ] **CI/CD.** GitHub Actions workflow that builds the release tarballs on
  tag push, uploads to S3 / a GH Release, and (optionally) triggers deploy.
  Existing `.github/workflows/elixir.yml` only runs tests.
- [ ] **Observability.** AppSignal is wired in but optional. Decide whether to
  use it (set `APPSIGNAL_PUSH_API_KEY`) or remove the dep. Replace the dead
  `log.malt.li` GELF target with either CloudWatch, a real GELF endpoint, or
  drop the GELF backend in favor of stdout logs.
- [ ] **Clustering decision.** Default is single-node. If you ever need
  multi-node, set `RC_CLUSTER_DNS` to a DNS name resolving to all node IPs;
  libcluster will discover them via DNSPoll. Otherwise leave unset.
- [ ] **Stripe.** Currently configured with a previous owner's TEST keys. If
  billing is out of scope for the relaunch, gut the integration.
- [ ] **Steam integration.** `front/steam-libs/steam-auth.js` ships a Steam
  ticket handshake against the API. Confirm intent before exposing the
  endpoint publicly.

### Known leaks / cosmetic cleanup

These are old branding references that don't break anything but should be
swept before going public:

- `lib/mix/tasks/patent_table.ex` — comment-only image URL.
- `lib/mix/tasks/update_data.ex` — Google service-account email in a comment.
- `front/src/portal/pages/play/Tutorial.vue:109` — `rising-constellation.fandom.com`
  wiki link; community wiki may still exist or you may want to point elsewhere.
- `front/public/map/characters/source.svg:17` — Inkscape export path on a
  developer's machine.
- `generate_wiki_tables.sh:2` — hardcoded developer path.
- `config/test.exs:11-12` — test fixtures use `rising-constellation.com`;
  harmless but ugly.
- README still references `nodes.rising-constellation.com` for A-record
  setup — needs updating once the new domain is picked.

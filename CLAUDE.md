# Tetrarchy Falls (formerly Rising Constellation) — agent notes

## Branching & releases

`master` is the **production trunk** — it's what `./deploy/release.sh <ref>`
deploys. Since v1.1 shipped (release/1.1 merged, July 2026), development
happens **directly on master**: feature branches commit/merge straight to
`master` as rolling "hotfixes" to the live version. There is currently no
active `release/*` branch.

A long-lived `release/X.Y` branch (next: `release/1.2`) is only cut when
production needs to freeze again — at that point master-vs-release rules
apply: hotfixes to the live version go to `master` and get forward-ported
into the release branch (`git merge origin/master`, keeping the branch's
higher version on conflict); the release branch promotes by merging into
`master`, tagging `vX.Y.0`, and deploying.

Versioning is semver with version-file bumps:

- App version lives in `mix.exs` (`version:`) and `front/package.json`
  (`"version"`) — bump both together. `assets/package.json` is a legacy
  pipeline (optional). `priv/VERSION` is auto-stamped by the deploy —
  **never edit it**.
- Tags are `vMAJOR.MINOR.PATCH`; production currently runs the v1.1 line.

The deploy script is ref-agnostic (any branch/tag/commit); CI
(`.github/workflows/elixir.yml`) runs on all branches but **never deploys**.

## Dev port assignment (worktree-aware Docker)

This repo supports running multiple Docker dev stacks in parallel — one per
git worktree — so feature work in different worktrees doesn't fight over
host ports.

**Before you bring the stack up in any worktree**, run the setup script:

- POSIX / Git-Bash: `bin/rc-worktree-setup`
- Native Windows: `bin/rc-worktree-setup.ps1`

It allocates a port slot for this worktree (idempotent — same worktree path
gets the same ports forever) and writes two files at the repo root:

- `.env` — `COMPOSE_PROJECT_NAME`, `RC_HTTP_PORT`, `RC_FRONT_PORT`. Compose
  picks this up automatically. Gitignored.
- `.dev-ports.json` — machine-readable summary. **Read this** to know which
  ports the running stack is on. Gitignored.

### When you (the AI agent) interact with the running app

**Always read `.dev-ports.json` first.** Do not assume Phoenix is on 4000 or
the Vue dev server is on 8080 — those are only the defaults for a single-
worktree setup. In a parallel-worktree workflow, this worktree's Phoenix
might be on 4300, another worktree's might be on 4070, etc.

```json
{
  "ports": {
    "phoenix": 4300,
    "vue_spa": 8380
  }
}
```

When `curl`-ing, driving Playwright, opening a preview, or telling the user
where the app is reachable: use these ports.

### Registry housekeeping

Slots are recorded in a per-machine registry outside the repo
(`%LOCALAPPDATA%\rc\worktree-ports.tsv` on Windows, `~/.config/rc/...` on
POSIX). To prune entries for worktrees that no longer exist on disk:

```
bin/rc-worktree-setup --gc        # POSIX
bin/rc-worktree-setup.ps1 -Gc     # Windows
```

### Postgres has no host port binding

`docker-compose.yml` does not expose 5432 on the host — the `rc` service
reaches Postgres via the internal Docker network as `db:5432`. For ad-hoc
host-side access: `docker compose exec db psql -U postgres`. (This is also
what lets parallel worktrees coexist: each worktree's Postgres is internal
to its own Compose project, identified by `COMPOSE_PROJECT_NAME`.)

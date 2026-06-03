#!/bin/bash
#
# Dev container entrypoint.
#
# Runs as root just long enough to fix volume ownership, then drops to the
# `rc` user (uid 1001) for everything else — matching the prod image.

set -eo pipefail

STATE=/var/lib/rc-state

# The named volumes mount in root-owned. Fix ownership for paths the rc user
# needs to write. Only chown if not already owned by rc to keep restarts fast.
mkdir -p "$STATE"
for dir in /data/deps /data/_build /data/assets/node_modules /data/front/node_modules "$STATE" /home/rc/.mix; do
    if [ -d "$dir" ] && [ "$(stat -c '%u' "$dir")" != "1001" ]; then
        chown -R rc:rc "$dir"
    fi
done

# Source-code trees mounted from the host show up with the host user's
# uid (kurtz on Windows = uid 197609, root on Linux = uid 0, etc.).
# Elixir's compile tracker calls `touch` on source files between
# cycles to record successful compilation; `touch` on Linux requires
# file ownership, so a fresh start with host-owned files crashes the
# compiler with `could not touch lib/...: not owner` on the first
# build cycle. We chown the trees mix actually walks.
for dir in /data/lib /data/test /data/priv /data/config; do
    if [ -d "$dir" ] && [ "$(stat -c '%u' "$dir")" != "1001" ]; then
        chown -R rc:rc "$dir"
    fi
done
for f in /data/mix.exs /data/mix.lock; do
    if [ -f "$f" ] && [ "$(stat -c '%u' "$f")" != "1001" ]; then
        chown rc:rc "$f"
    fi
done

# Re-exec as rc for the rest of the script. The marker prevents an infinite
# loop: gosu sets HOME=/home/rc but we use our own marker.
if [ "$(id -u)" = "0" ]; then
    exec gosu rc:rc "$0" "$@"
fi

set -x

# Wait for postgres.
until pg_isready -h "${RDBMS_HOST:-localhost}" -U postgres >/dev/null 2>&1 ; do
    echo "waiting for postgres at ${RDBMS_HOST:-localhost}..."
    sleep 1
done

# Helper: run `$2` only if the hash of `$1` differs from what's recorded in
# `$STATE/$3`. Writes the new hash on success.
run_if_changed() {
    local watch="$1" cmd="$2" marker="$STATE/$3"
    local current="missing"
    if [ -e "$watch" ]; then
        current=$(sha256sum "$watch" | cut -d' ' -f1)
    fi
    local previous=""
    if [ -e "$marker" ]; then
        previous=$(cat "$marker")
    fi
    if [ "$current" != "$previous" ]; then
        echo "[entrypoint] $watch changed — running: $cmd"
        eval "$cmd"
        echo "$current" > "$marker"
    else
        echo "[entrypoint] $watch unchanged — skipping: $cmd"
    fi
}

run_if_changed mix.lock                  "mix deps.get"                            mix.lock.sha
run_if_changed assets/package-lock.json  "npm --prefix assets install --no-audit"  assets.package-lock.sha
run_if_changed front/package-lock.json   "npm --prefix front  install --no-audit"  front.package-lock.sha

# Seed once. The marker lives in the rc-state volume, separate from pgdata,
# so wiping the DB volume re-runs seeds. Migrations run every boot
# (idempotent).
if [ ! -e "$STATE/seeded" ] ; then
    mix ecto.create
    mix ecto.migrate
    mix run priv/repo/seeds.exs
    touch "$STATE/seeded"
else
    mix ecto.migrate
fi

exec mix phx.server

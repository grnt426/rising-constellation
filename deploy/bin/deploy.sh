#!/bin/bash
#
# Deploy a built release to all hosts in nodes.sh.
#
# Run from the repo root after `make build`. The tarballs are expected at
# ./build/rc.tar.gz and ./build/vue.tar.gz.
#
# What this does, per host:
#   1. scp both tarballs to /home/rc/
#   2. Extract the Vue tarball under /home/rc/www-root (overwrite — nginx
#      picks up new files immediately).
#   3. Stop rc.service (brief downtime).
#   4. Extract the release tarball under /home/rc/rc (overwrite).
#   5. Run Ecto migrations via `bin/rc eval`.
#   6. Start rc.service.
#
# Idempotent. Safe to re-run.

set -euo pipefail

cd "$(dirname "$0")/../.."

if [[ ! -f ./build/rc.tar.gz || ! -f ./build/vue.tar.gz ]]; then
  echo "error: build/rc.tar.gz or build/vue.tar.gz missing — run \`make build\` first" >&2
  exit 1
fi

source ./nodes.sh

# Embedded remote script. We pipe this to `ssh bash -s` so the host doesn't
# need anything pre-installed beyond what bootstrap-host.sh put there.
REMOTE_SCRIPT=$(cat <<'EOF'
set -euo pipefail

cd /home/rc

# --- 1. Vue assets ---------------------------------------------------------
# vue.tar.gz archives /home/rc/www-root/asylamba/ — paths inside look like
# "home/rc/www-root/asylamba/static/...". strip-components=2 drops the
# leading "home/rc/", extracted into cwd (/home/rc), so the final layout is
# /home/rc/www-root/asylamba/static and .../front — matching nginx's docroot.
echo "[remote] extracting vue.tar.gz"
tar -xzf vue.tar.gz --strip-components=2 -C .

# --- 2. Stop the service before swapping the release -----------------------
# Absolute path matters: the sudoers.d rule in bootstrap-host.sh authorizes
# /bin/systemctl and /usr/bin/systemctl specifically. Bare `systemctl` only
# matches when sudo's PATH lookup hits one of those — which depends on the
# non-interactive shell's PATH. Using the absolute path is bulletproof.
echo "[remote] stopping rc.service"
sudo /usr/bin/systemctl stop rc.service || true

# --- 3. Extract release ----------------------------------------------------
# rc.tar.gz contains a top-level rc/ directory (from the mix release).
echo "[remote] extracting rc.tar.gz"
rm -rf rc.old
[ -d rc ] && mv rc rc.old
tar -xzf rc.tar.gz
chmod +x rc/bin/rc

# --- 4. Run migrations -----------------------------------------------------
# Pull env vars from the same source rc.service uses, so DATABASE_URL etc.
# are populated for the eval. /etc/rc/env is owned rc:rc mode 0600.
#
# stdin is redirected from /dev/null because `rc eval` (via the BEAM VM)
# consumes anything left on stdin. Without this, the remaining lines of
# this script — piped to `bash -s` over ssh — get eaten and the service
# is never started.
echo "[remote] running migrations"
set -a
. /etc/rc/env
set +a
./rc/bin/rc eval "RC.Release.migrate()" </dev/null

# --- 5. Start the service --------------------------------------------------
echo "[remote] starting rc.service"
sudo /usr/bin/systemctl start rc.service

# Wait a few seconds and report status. systemctl status doesn't need root
# for read-only info; running unprivileged sidesteps the issue that any
# sudo-allowed flag combination (e.g. --no-pager) has to be enumerated
# verbatim in /etc/sudoers.d.
sleep 3
systemctl --no-pager status rc.service | head -15 || true

# Tidy up the prior release after a successful start.
rm -rf rc.old
EOF
)

for node in "${NODES[@]}"; do
  echo
  echo "=== deploying to $node ==="

  echo "[deploy] uploading tarballs"
  scp "${SCP_OPTS[@]}" ./build/rc.tar.gz ./build/vue.tar.gz "$node:/home/rc/"

  echo "[deploy] running remote install"
  ssh "${SSH_OPTS[@]}" "$node" bash -s <<<"$REMOTE_SCRIPT"
done

echo
echo "=== deploy complete ==="

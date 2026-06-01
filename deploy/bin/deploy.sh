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
# vue.tar.gz contains ~/www-root/asylamba/{static,front}. Extract relative
# to /home/rc so it lands at /home/rc/www-root/asylamba/...
echo "[remote] extracting vue.tar.gz"
tar -xzf vue.tar.gz --strip-components=2 -C www-root
# strip-components=2 drops the leading "home/rc/" from the archive paths
# so the final layout is /home/rc/www-root/asylamba/static and .../front.

# --- 2. Stop the service before swapping the release -----------------------
echo "[remote] stopping rc.service"
sudo systemctl stop rc.service || true

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
echo "[remote] running migrations"
set -a
. /etc/rc/env
set +a
./rc/bin/rc eval "RC.Release.migrate()"

# --- 5. Start the service --------------------------------------------------
echo "[remote] starting rc.service"
sudo systemctl start rc.service

# Wait a few seconds and report status.
sleep 3
sudo systemctl --no-pager status rc.service | head -15

# Tidy up the prior release after a successful start.
rm -rf rc.old
EOF
)

for node in "${NODES[@]}"; do
  echo
  echo "=== deploying to $node ==="

  echo "[deploy] uploading tarballs"
  scp "${SSH_OPTS[@]}" ./build/rc.tar.gz ./build/vue.tar.gz "$node:/home/rc/"

  echo "[deploy] running remote install"
  ssh "${SSH_OPTS[@]}" "$node" bash -s <<<"$REMOTE_SCRIPT"
done

echo
echo "=== deploy complete ==="

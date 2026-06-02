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

# --- 2a. Snapshot every running/paused game before stopping ---------------
# Without this, deploys lose all in-memory game state: terminate/2 in
# Instance.Manager doesn't snapshot before exit, boot reconciliation
# downgrades state to "not_running", and the only UI path is "Restart"
# which goes through create_from_model — a fresh game from the blueprint.
#
# Using the existing maintenance_instance/restore_instance path (which is
# the same logic admins use for planned downtime) avoids touching the
# server lifecycle code. The post-start hook re-runs the inverse.
#
# Failure mode: if maintenance_instance fails for an instance, we log and
# proceed — that instance will reset on the way back up, but other
# instances aren't blocked. account_id=1 (admin) is used as the audit
# actor for the state transition.
if [ -d rc ] && [ -x rc/bin/rc ]; then
  echo "[remote] snapshotting running instances"
  set -a
  . /etc/rc/env 2>/dev/null || true
  set +a
  ./rc/bin/rc rpc '
    import Ecto.Query
    iids = RC.Repo.all(from i in RC.Instances.Instance,
      where: i.state in ["running", "paused"], select: i.id)
    IO.puts("[pre-stop] " <> Integer.to_string(length(iids)) <> " instance(s) to snapshot")
    Enum.each(iids, fn iid ->
      instance = RC.Instances.get_instance(iid)
      case RC.Instances.maintenance_instance(instance, 1) do
        {:ok, _} -> IO.puts("[pre-stop] snapshotted instance " <> Integer.to_string(iid))
        err -> IO.puts("[pre-stop] FAILED for " <> Integer.to_string(iid) <> ": " <> inspect(err))
      end
    end)
  ' </dev/null || echo "[pre-stop] rpc failed (release may not be running yet) — continuing"
fi

# --- 2b. Stop the service before swapping the release ---------------------
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

# --- 6. Restore maintenance instances --------------------------------------
# Counterpart to the pre-stop snapshot. restore_instance loads the most
# recent snapshot from RC_SNAPSHOT_DIR, recreates the Instance.Manager
# supervisor via create_from_snapshot, and transitions state back to
# whatever it was pre-maintenance (running/paused). For instances that
# weren't snapshotted (e.g., pre-stop failed for them), state stays
# "maintenance" and an admin can intervene manually.
#
# Brief sleep so the application boot finishes — RC.Repo, Game supervisor,
# Horde registry need to be up before restore_instance can spawn children.
echo "[remote] restoring snapshotted instances"
sleep 5
./rc/bin/rc rpc '
  import Ecto.Query
  iids = RC.Repo.all(from i in RC.Instances.Instance,
    where: i.state == "maintenance", select: i.id)
  IO.puts("[post-start] " <> Integer.to_string(length(iids)) <> " instance(s) to restore")
  Enum.each(iids, fn iid ->
    instance = RC.Instances.get_instance(iid)
    case RC.Instances.restore_instance(instance, 1) do
      {:ok, _} -> IO.puts("[post-start] restored instance " <> Integer.to_string(iid))
      err -> IO.puts("[post-start] FAILED for " <> Integer.to_string(iid) <> ": " <> inspect(err))
    end
  end)
' </dev/null || echo "[post-start] rpc failed — instances may remain in maintenance"

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

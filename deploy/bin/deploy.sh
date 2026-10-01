#!/bin/bash
#
# Deploy a built release to all hosts in nodes.sh.
#
# Run from the repo root after a build. The tarballs are expected at
# ./build/rc.tar.gz and ./build/vue.tar.gz.
#
# Usage:
#   deploy/bin/deploy.sh [--back-only]
#
#   --back-only   Backend-only release: ship and install rc.tar.gz alone and
#                 leave the front end on the host exactly as it is. A
#                 build/vue.tar.gz that happens to be lying around is NOT
#                 shipped: it is whatever the last full build on this
#                 machine produced, which can be older than what is live
#                 (remote builds never bring one back here), so shipping it
#                 would roll the front end back. Without this flag both
#                 tarballs are required.
#
# What this does, per host:
#   1. scp the tarball(s) to /home/rc/
#   1b. Wait for live daily challenges to finish (they have no snapshot;
#      a restart mid-run ruins them). Capped at 40min.
#   2. Extract the Vue tarball under /home/rc/www-root (overwrite — nginx
#      picks up new files immediately). Skipped with --back-only.
#   3. Stop rc.service (brief downtime).
#   4. Extract the release tarball under /home/rc/rc (overwrite).
#   5. Run Ecto migrations via `bin/rc eval`.
#   6. Start rc.service.
#
# Idempotent. Safe to re-run.

set -euo pipefail

cd "$(dirname "$0")/../.."

BACK_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --back-only) BACK_ONLY=1 ;;
    *) echo "error: unknown argument '$arg' (usage: deploy.sh [--back-only])" >&2; exit 1 ;;
  esac
done

if [[ ! -f ./build/rc.tar.gz ]]; then
  echo "error: build/rc.tar.gz missing — build first (deploy/release.sh)" >&2
  exit 1
fi
if [[ "$BACK_ONLY" == "0" && ! -f ./build/vue.tar.gz ]]; then
  echo "error: build/vue.tar.gz missing — build first (deploy/release.sh), or pass" >&2
  echo "  --back-only to release the backend and leave the front end as it is" >&2
  exit 1
fi

TARBALLS=(./build/rc.tar.gz)
[[ "$BACK_ONLY" == "0" ]] && TARBALLS+=(./build/vue.tar.gz)

# --- Pre-flight: capture vue.tar.gz hash for the post-deploy CloudFront ----
# invalidation decision. We compare against .secrets/last_vue_sha to detect
# whether the frontend assets actually changed or are being re-shipped
# unchanged (--skip-build of the same tarball). Empty NEW_VUE_SHA means we
# couldn't hash, in which case the post-deploy block skips invalidation
# entirely. A --back-only deploy ships no front end and never invalidates.
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    return 1
  fi
}
NEW_VUE_SHA=""
[[ "$BACK_ONLY" == "0" ]] && NEW_VUE_SHA=$(sha256_of build/vue.tar.gz 2>/dev/null || true)
LAST_VUE_SHA_FILE=".secrets/last_vue_sha"
LAST_VUE_SHA=""
[ -f "$LAST_VUE_SHA_FILE" ] && LAST_VUE_SHA=$(cat "$LAST_VUE_SHA_FILE")

source ./nodes.sh

# Embedded remote script. We pipe this to `ssh bash -s` so the host doesn't
# need anything pre-installed beyond what bootstrap-host.sh put there.
# BACK_ONLY reaches it as an environment variable on the ssh command line.
REMOTE_SCRIPT=$(cat <<'EOF'
set -euo pipefail

cd /home/rc

# --- 0. Lock so two `deploy.sh` runs against the same host don't ----------
# overlap. The previous failure mode was: deploy A's post-start rpc fired
# at the exact moment deploy B's systemctl stop took the BEAM down, hence
# `:noconnection`. flock blocks deploy B until A completes.
exec 200>/tmp/rc-deploy.lock
if ! flock -n 200; then
  echo "[remote] another deploy is in flight (lock /tmp/rc-deploy.lock held) — waiting up to 10min"
  flock -w 600 200 || { echo "[remote] timed out waiting for lock — abort"; exit 1; }
fi
echo "[remote] deploy lock acquired (pid $$)"

# --- 0a. The live server's build (GET /api/version → RC.Build) -------------
# Read now and again right before the stop (2b): the server being replaced
# must report the same revision and live_since for the whole deploy, even
# after the new front end is out (step 1). Its own files are only replaced
# after the stop, and RC.Build reads them once at boot — these two reads
# check that it stays that way.
# X-Forwarded-Proto: without it prod's Plug.SSL answers plain HTTP with an
# empty 301, which curl -f takes as success.
live_build() {
  command -v curl >/dev/null 2>&1 || return 0
  curl -fsS --max-time 5 -H X-Forwarded-Proto:https "http://127.0.0.1:${RC_HTTP_PORT:-4000}/api/version" 2>/dev/null || true
}
build_field() { printf '%s' "$1" | sed -n "s/.*\"$2\":\"\([^\"]*\)\".*/\1/p"; }
BUILD_BEFORE=$(live_build)
echo "[remote] live build before deploy: ${BUILD_BEFORE:-<no answer>}"

# --- 0b. Drain live daily challenges ---------------------------------------
# A daily has no snapshot and a hard 30-minute real-time clock, so a restart
# mid-run ruins it. release.sh's preflight raised the deploy flag, which
# already refuses NEW runs (RC.Deploy.dailies_locked?/0); here we wait for
# the runs in flight to finish before touching anything — Vue assets
# included, so a waiting deploy never serves the new bundle to the old
# backend. The probe prints `daily_drain live=N max_seconds_left=S ids=...`.
#   * no parseable line on the first probe → app stopped, or the live
#     release predates the probe: nothing to wait on / no way to tell.
#   * probe failures after a successful one → retried (3 strikes).
#   * DRAIN_MAX_SECONDS caps the wait against a wedged run: a full daily
#     plus the pre-connect grace is ~35min, so nothing legitimate is left.
DRAIN_MAX_SECONDS=2400
DRAIN_POLL_SECONDS=30
if [ -d rc ] && [ -x rc/bin/rc ]; then
  set -a
  . /etc/rc/env 2>/dev/null || true
  set +a
  drain_started=$(date +%s)
  drain_probed=no
  drain_strikes=0
  while :; do
    drain_line=$(./rc/bin/rc rpc 'RC.Deploy.daily_drain_status()' </dev/null 2>/dev/null | grep '^daily_drain ' | tail -1 || true)
    drain_waited=$(( $(date +%s) - drain_started ))

    if [ -z "$drain_line" ]; then
      if [ "$drain_probed" = "no" ]; then
        echo "[drain] daily probe unavailable (app stopped, or release predates it) — not waiting"
        break
      fi
      drain_strikes=$((drain_strikes + 1))
      if [ "$drain_strikes" -ge 3 ]; then
        echo "[drain] WARNING: daily probe failed 3x in a row after ${drain_waited}s — proceeding"
        break
      fi
      echo "[drain] daily probe failed (strike $drain_strikes/3) — retrying"
      sleep "$DRAIN_POLL_SECONDS"
      continue
    fi

    drain_probed=yes
    drain_strikes=0
    drain_live=$(echo "$drain_line" | sed -n 's/.* live=\([0-9]*\).*/\1/p')
    drain_left=$(echo "$drain_line" | sed -n 's/.* max_seconds_left=\([0-9]*\).*/\1/p')
    drain_ids=$(echo "$drain_line" | sed -n 's/.* ids=\([0-9,]*\).*/\1/p')

    if [ "${drain_live:-0}" = "0" ]; then
      echo "[drain] no daily challenges in progress (waited ${drain_waited}s)"
      break
    fi
    if [ "$drain_waited" -ge "$DRAIN_MAX_SECONDS" ]; then
      echo "[drain] WARNING: $drain_live daily challenge(s) still live after ${drain_waited}s (instances $drain_ids) — proceeding"
      break
    fi
    echo "[drain] waiting on $drain_live daily challenge(s) — longest ends in ~$(( (${drain_left:-0} + 59) / 60 ))m (instances $drain_ids, waited ${drain_waited}s)"
    sleep "$DRAIN_POLL_SECONDS"
  done
fi

# --- 1. Vue assets ---------------------------------------------------------
# vue.tar.gz archives /home/rc/www-root/asylamba/ — paths inside look like
# "home/rc/www-root/asylamba/static/...". strip-components=2 drops the
# leading "home/rc/", extracted into cwd (/home/rc), so the final layout is
# /home/rc/www-root/asylamba/static and .../front — matching nginx's docroot.
# A backend-only deploy ships no vue.tar.gz; whatever tarball an earlier
# deploy left in /home/rc stays unextracted and the docroot is not touched.
if [ "${BACK_ONLY:-0}" = "1" ]; then
  echo "[remote] backend-only deploy — leaving the front end as it is"
else
  echo "[remote] extracting vue.tar.gz"
  tar -xzf vue.tar.gz --strip-components=2 -C .
fi

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
BUILD_AT_STOP=$(live_build)
if [ -n "$BUILD_BEFORE" ] && [ -n "$BUILD_AT_STOP" ]; then
  before="$(build_field "$BUILD_BEFORE" version) $(build_field "$BUILD_BEFORE" live_since)"
  at_stop="$(build_field "$BUILD_AT_STOP" version) $(build_field "$BUILD_AT_STOP" live_since)"
  if [ "$before" = "$at_stop" ]; then
    echo "[remote] live build unchanged through the deploy: $at_stop"
  else
    echo "[remote] WARNING: the running server's build changed during the deploy: before=[$before] at stop=[$at_stop]"
  fi
fi

echo "[remote] stopping rc.service"
sudo /usr/bin/systemctl stop rc.service || true

# --- 3. Extract release ----------------------------------------------------
# rc.tar.gz contains a top-level rc/ directory (from the mix release).
echo "[remote] extracting rc.tar.gz"
rm -rf rc.old
[ -d rc ] && mv rc rc.old
tar -xzf rc.tar.gz
chmod +x rc/bin/rc

# --- 3a. Persistent uploads storage -----------------------------------------
# Forge thumbnails (and any future Waffle uploads in local mode) live in
# /home/rc/storage, OUTSIDE the release, so they survive the rc/ swap.
# Two symlinks per release:
#   - rc/priv/storage: Waffle.Storage.Local writes cwd-relative (it
#     silently relativizes absolute storage_dirs — learned the hard way),
#     and the service's WorkingDirectory is rc/, so writes land here.
#   - rc/lib/rc-*/priv/storage: the endpoint's /uploads Plug.Static reads
#     via Application.app_dir, which resolves into lib/.
# Idempotent.
echo "[remote] linking priv/storage -> /home/rc/storage"
mkdir -p /home/rc/storage /home/rc/rc/priv
ln -sfn /home/rc/storage rc/priv/storage
for priv in rc/lib/rc-*/priv; do
  rm -rf "$priv/storage"
  ln -sfn /home/rc/storage "$priv/storage"
done

# --- 3b. Sync news-card fonts ----------------------------------------------
# The Discord news images are rasterized by rsvg-convert (librsvg,
# installed by bootstrap-host.sh), which resolves fonts through
# fontconfig. The release ships Nunito/Montserrat under priv/fonts;
# expose them to the rc user's fontconfig without root. Idempotent —
# cp -u only copies changed files; skipped entirely when fontconfig
# isn't installed (news falls back to text posts).
if command -v fc-cache >/dev/null 2>&1; then
  echo "[remote] syncing news-card fonts"
  mkdir -p "$HOME/.local/share/fonts/rc"
  find rc/lib -path '*/priv/fonts/*.ttf' -exec cp -u {} "$HOME/.local/share/fonts/rc/" \; 2>/dev/null || true
  fc-cache -f "$HOME/.local/share/fonts/rc" >/dev/null 2>&1 || true
else
  echo "[remote] fontconfig not installed; skipping news-card fonts (image news disabled)"
fi

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

# Re-source env explicitly: while the migrations block above already
# exported RELEASE_NODE/RELEASE_COOKIE, deploys that overlap (a second
# `deploy.sh` while the first is still in this phase) can drop our env
# on the floor and `rc rpc` fails with `:noconnection`. Cheap to redo.
set -a
. /etc/rc/env 2>/dev/null || true
set +a

# Wait until the new BEAM actually accepts rpc calls before invoking
# restore. Service "Started" in systemd doesn't mean RC.Repo +
# Game.Supervisor + the Horde registry have all come up. Try a no-op
# rpc with retries; bail to the noop branch if 30s isn't enough.
echo "[remote] waiting for new release to accept rpc"
rpc_ready=no
for i in 1 2 3 4 5 6; do
  if ./rc/bin/rc rpc ":ok" </dev/null >/dev/null 2>&1; then
    rpc_ready=yes
    break
  fi
  sleep 5
done

if [ "$rpc_ready" != "yes" ]; then
  echo "[post-start] rpc never became reachable (overlapping deploy? cookie mismatch?)"
  echo "[post-start] instances may remain in maintenance — check with:"
  echo "  ./rc/bin/rc rpc 'RC.Instances.list_instances() |> Enum.filter(&(&1.state == \"maintenance\"))'"
else
  echo "[remote] restoring snapshotted instances"
  ./rc/bin/rc rpc '
    import Ecto.Query
    iids = RC.Repo.all(from i in RC.Instances.Instance,
      where: i.state == "maintenance", select: i.id)
    if length(iids) == 0 do
      IO.puts("[post-start] nothing in maintenance — skipping restore")
    else
      IO.puts("[post-start] " <> Integer.to_string(length(iids)) <> " instance(s) to restore")
      Enum.each(iids, fn iid ->
        instance = RC.Instances.get_instance(iid)
        case RC.Instances.restore_instance(instance, 1) do
          {:ok, _} -> IO.puts("[post-start] restored instance " <> Integer.to_string(iid))
          err -> IO.puts("[post-start] FAILED for " <> Integer.to_string(iid) <> ": " <> inspect(err))
        end
      end)
    end
  ' </dev/null || echo "[post-start] rpc errored mid-restore"
fi

# Tidy up the prior release after a successful start.
rm -rf rc.old
EOF
)

for node in "${NODES[@]}"; do
  echo
  echo "=== deploying to $node ==="

  if [[ "$BACK_ONLY" == "1" ]]; then
    echo "[deploy] uploading rc.tar.gz (backend-only: no front end)"
  else
    echo "[deploy] uploading tarballs"
  fi
  scp "${SCP_OPTS[@]}" "${TARBALLS[@]}" "$node:/home/rc/"

  echo "[deploy] running remote install"
  # Keepalives: the daily drain can hold this session open for ~40min.
  ssh "${SSH_OPTS[@]}" -o ServerAliveInterval=30 "$node" "BACK_ONLY=$BACK_ONLY bash -s" <<<"$REMOTE_SCRIPT"
done

# --- Post-deploy: CloudFront invalidation (frontend asset changes only) ---
# Skip if any of these conditions hold — emit a clear warning in each case,
# but never fail the deploy. The deploy itself succeeded; an inability to
# invalidate just means edge caches age out naturally up to their TTL.
#
# .secrets/ lives in the main repo checkout, not in git worktrees. If you
# deploy from a worktree, either symlink .secrets/ in or accept the warning
# and run the invalidation manually:
#   aws --profile rc-prod cloudfront create-invalidation \
#     --distribution-id "$(cat /path/to/main/.secrets/cf_distribution_id.txt)" \
#     --paths '/portal/*'
if [[ "$BACK_ONLY" == "1" ]]; then
  echo "[deploy] backend-only deploy — front end unchanged, no CloudFront invalidation"
elif [[ -z "$NEW_VUE_SHA" ]]; then
  echo "[deploy] WARNING: no sha256 tool available — skipping CloudFront invalidation"
elif [[ "$NEW_VUE_SHA" == "$LAST_VUE_SHA" ]]; then
  echo "[deploy] vue.tar.gz unchanged since last deploy — skipping CloudFront invalidation"
elif [[ ! -f .secrets/cf_distribution_id.txt ]]; then
  echo "[deploy] WARNING: .secrets/cf_distribution_id.txt missing — skipping CloudFront invalidation"
elif ! command -v aws >/dev/null 2>&1; then
  echo "[deploy] WARNING: aws CLI not installed — skipping CloudFront invalidation"
else
  CF_DIST_ID=$(cat .secrets/cf_distribution_id.txt)
  echo "[deploy] vue.tar.gz changed — invalidating CloudFront /portal/* on $CF_DIST_ID"
  if aws --profile rc-prod cloudfront create-invalidation \
       --distribution-id "$CF_DIST_ID" \
       --paths '/portal/*' \
       --query 'Invalidation.[Id,Status]' --output text; then
    # Only persist the new SHA on success. If invalidation failed, leaving
    # LAST_VUE_SHA pointing at the older hash makes the next deploy attempt
    # detect the mismatch again and retry — self-healing across transient
    # AWS errors or a missed --profile.
    echo "$NEW_VUE_SHA" > "$LAST_VUE_SHA_FILE"
  else
    echo "[deploy] WARNING: invalidation failed — last_vue_sha NOT updated (will retry next deploy)"
  fi
fi

echo
echo "=== deploy complete ==="

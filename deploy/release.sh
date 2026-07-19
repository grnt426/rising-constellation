#!/bin/bash
#
# release.sh — single-command production deploy
#
# Wraps build → extract → ship → verify → recover into one reproducible
# pipeline. Exits 0 only when prod is verified running the requested
# revision AND the post-deploy maintenance-recovery pass left no
# instances stuck.
#
# Usage:
#   ./deploy/release.sh [flags] [<git-ref>]
#
# Flags:
#   --remote             Build on a transient AWS Graviton spot instance
#                        (native arm64) instead of locally via QEMU. Ships
#                        tarballs builder→prod directly. ~5-10min vs ~35min
#                        local. Requires AWS profile rc-prod and a one-time
#                        `deploy/bin/setup-builder.sh` run.
#   --build-only         Build + extract tarballs, then exit. With --remote,
#                        pulls tarballs back to ./build/ and skips deploy.
#   --back-only          Skip the Vue rebuild (backend-only release).
#   --skip-build         Reuse existing build/*.tar.gz instead of rebuilding.
#                        Ignores --remote (no builder needed for deploy-only).
#   --cache              Allow Docker layer cache. Default is --no-cache
#                        because cache poisoning of the COPY layer has
#                        shipped wrong revisions to prod in the past.
#   --on-demand          Skip the spot attempt, launch on-demand. With --remote.
#   --keep               Don't terminate the builder on exit (debug only).
#   --builder-type <t>   EC2 instance type for the remote builder.
#                        Default: c7g.4xlarge.
#   --vue-base <url>     Public URL baked into the Vue bundle.
#                        Default: https://tetrarchyfalls.com
#   --vue-appsignal <k>  AppSignal frontend key. Default: empty.
#   -h, --help           Show this and exit.
#
# Exit codes:
#   0  PASS         — prod runs the requested revision, no failures.
#   1  FAIL         — build, deploy, or revision-match verification failed.
#   2  PARTIAL      — deploy succeeded and revision matches, but one or more
#                    instances failed to come out of maintenance. They are
#                    listed in the summary; investigate via ssh.
#   3  INCONCLUSIVE — build+deploy ran but prod was unreachable over SSH, so
#                    the revision could not be verified. Usually a network /
#                    security-group reachability problem, not a build error.
#
# All steps emit "[release] ..." progress lines so the operator does not
# need to read intermediate output. The closing summary block is the
# canonical pass/fail signal.

set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
cd "$REPO"

# === flags ====================================================================
REV_INPUT="HEAD"
BUILD_REMOTE=0
BUILD_ONLY=0
BACK_ONLY=0
SKIP_BUILD=0
ALLOW_CACHE=0
ON_DEMAND=0
KEEP_BUILDER=0
BUILDER_TYPE="c7g.4xlarge"
VUE_BASE="https://tetrarchyfalls.com"
VUE_APPSIGNAL_KEY=""

usage() {
  sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --remote)         BUILD_REMOTE=1; shift ;;
    --build-only)     BUILD_ONLY=1; shift ;;
    --back-only)      BACK_ONLY=1; shift ;;
    --skip-build)     SKIP_BUILD=1; shift ;;
    --cache)          ALLOW_CACHE=1; shift ;;
    --on-demand)      ON_DEMAND=1; shift ;;
    --keep)           KEEP_BUILDER=1; shift ;;
    --builder-type)   BUILDER_TYPE="${2:?--builder-type requires a value}"; shift 2 ;;
    --vue-base)       VUE_BASE="${2:?--vue-base requires a value}"; shift 2 ;;
    --vue-appsignal)  VUE_APPSIGNAL_KEY="${2:?--vue-appsignal requires a value}"; shift 2 ;;
    -h|--help)        usage; exit 0 ;;
    --)               shift; REV_INPUT="${1:-HEAD}"; break ;;
    -*)               echo "[release] unknown flag: $1" >&2; echo "  run --help for usage" >&2; exit 1 ;;
    *)                REV_INPUT="$1"; shift ;;
  esac
done

# === 1. resolve target revision ===============================================
if ! REVISION=$(git rev-parse --short "$REV_INPUT" 2>/dev/null); then
  echo "[release] fatal: unknown git revision '$REV_INPUT'" >&2
  exit 1
fi
echo "$REVISION" > priv/VERSION
echo "[release] target revision: $REVISION"

# === preflight: reach prod + raise the deploy notice ==========================
# Contact prod BEFORE the (long) build. This
#   * fails fast when prod is unreachable — no point building,
#   * triggers the operator's SSH-key approval (1Password) now, while
#     they are still watching, so the post-build connections reuse it,
#   * raises the deploy-notice flag (RC.Deploy) so players get the
#     heads-up in the news ticker and in-game chat for the whole
#     build+deploy window.
# ssh exit 255 = transport failure → abort. Any other failure only warns:
# the app may be stopped, or prod may still run a release that predates
# RC.Deploy — the deploy itself can proceed either way.

source ./nodes.sh
HOST="${NODES[0]}"
DEPLOY_NOTICE_SET=0

# Run one of RC.Deploy's zero-arg entry points (start_deploy /
# finish_deploy / clear_deploy) on prod via the env-source + rc rpc
# idiom. Stdout+stderr combined for the caller to report.
deploy_notice_rpc() {
  local fn="$1"
  ssh "${SSH_OPTS[@]}" -o ConnectTimeout=15 "$HOST" bash -s <<REMOTE 2>&1
set -e
cd /home/rc
set -a; . /etc/rc/env; set +a
./rc/bin/rc rpc "RC.Deploy.${fn}()"
REMOTE
}

# Best-effort flag clear for failure paths (no player-facing message).
clear_deploy_notice() {
  [[ "$DEPLOY_NOTICE_SET" != "1" ]] && return 0
  echo "[release] clearing deploy notice on prod"
  if ! deploy_notice_rpc clear_deploy >/dev/null; then
    echo "[release] WARNING: could not clear the deploy notice — run /cleardeploy on Discord" >&2
  fi
  DEPLOY_NOTICE_SET=0
}

# Flag down + "update applied" chat message. For PASS and PARTIAL paths
# (the new code is live either way).
finish_deploy_notice() {
  [[ "$DEPLOY_NOTICE_SET" != "1" ]] && return 0
  echo "[release] finishing deploy notice on prod (update-applied message)"
  if ! deploy_notice_rpc finish_deploy >/dev/null; then
    echo "[release] WARNING: could not send the deploy-finished notice — run /cleardeploy on Discord" >&2
  fi
  DEPLOY_NOTICE_SET=0
}

on_interrupt() {
  trap - INT TERM
  echo
  echo "[release] interrupted — attempting to clear the deploy notice"
  clear_deploy_notice
  exit 130
}
trap on_interrupt INT TERM

# Safety net for every other failure exit (set -e aborts, explicit exit
# 1/2/3 paths). Success/failure paths that already finished or cleared
# the notice set DEPLOY_NOTICE_SET=0 first, making this a no-op.
on_exit() {
  local code=$?
  if [[ "$code" -ne 0 && "$DEPLOY_NOTICE_SET" == "1" ]]; then
    echo "[release] exiting (code $code) with the deploy notice still up — attempting to clear"
    clear_deploy_notice
  fi
}
trap on_exit EXIT

if [[ "$BUILD_ONLY" == "1" ]]; then
  echo "[release] --build-only — skipping prod preflight (no deploy will happen)"
else
  echo "[release] preflight: connecting to prod ($HOST)"
  set +e
  PREFLIGHT_OUTPUT=$(deploy_notice_rpc start_deploy)
  PREFLIGHT_EXIT=$?
  set -e

  if [[ "$PREFLIGHT_EXIT" -eq 255 ]]; then
    cat >&2 <<EOF
[release] fatal: cannot reach $HOST over SSH (exit 255) — aborting before
  the build. Fix reachability first (security group / VPN / instance
  state), then re-run.
EOF
    exit 3
  elif [[ "$PREFLIGHT_EXIT" -ne 0 ]]; then
    echo "[release] WARNING: prod reachable but deploy notice not raised (exit $PREFLIGHT_EXIT)"
    echo "[release]   likely: app stopped, or prod release predates RC.Deploy — continuing without notice"
    echo "$PREFLIGHT_OUTPUT" | tail -3 | sed 's/^/[release]   rpc: /'
  else
    DEPLOY_NOTICE_SET=1
    echo "[release] deploy notice raised — players see the heads-up now"
  fi
fi

# === 2. build =================================================================
if [[ "$BACK_ONLY" == "1" ]]; then BACK_ONLY_BOOL=true; else BACK_ONLY_BOOL=false; fi
REMOTE_USED=0

if [[ "$SKIP_BUILD" == "1" ]]; then
  echo "[release] --skip-build — reusing build/*.tar.gz"
  if [[ "$BUILD_REMOTE" == "1" ]]; then
    echo "[release]   (ignoring --remote: no point spinning up a builder for a deploy-only run)"
  fi
  if [[ ! -f build/rc.tar.gz ]]; then
    echo "[release] fatal: build/rc.tar.gz missing — run a build first" >&2
    exit 1
  fi
  if [[ "$BACK_ONLY" != "1" && ! -f build/vue.tar.gz ]]; then
    echo "[release] fatal: build/vue.tar.gz missing (pass --back-only to skip Vue)" >&2
    exit 1
  fi
elif [[ "$BUILD_REMOTE" == "1" ]]; then
  # Remote build path: launches a transient Graviton spot, builds natively,
  # ships tarballs builder→prod, runs deploy.sh on the builder.
  # NOTE: deploy.sh runs on the builder via remote-build.sh, so we SKIP the
  # local deploy.sh invocation later.
  echo "[release] --remote — building on transient AWS Graviton"

  # Internal env-var contract with remote-build.sh — not user-visible.
  export REVISION
  export BACK_ONLY_BOOL
  export VUE_BASE
  export VUE_APP_APPSIGNAL_FRONT="$VUE_APPSIGNAL_KEY"
  [[ "$BUILD_ONLY"   == "1" ]] && export RC_BUILD_ONLY=1
  [[ "$ON_DEMAND"    == "1" ]] && export RC_BUILDER_ON_DEMAND=1
  [[ "$KEEP_BUILDER" == "1" ]] && export RC_BUILDER_KEEP=1
  [[ "$BUILDER_TYPE" != "c7g.4xlarge" ]] && export RC_BUILDER_TYPE="$BUILDER_TYPE"

  ./deploy/bin/remote-build.sh
  REMOTE_USED=1
else
  CACHE_FLAG=()
  [[ "$ALLOW_CACHE" == "0" ]] && CACHE_FLAG+=(--no-cache)

  echo "[release] building arm64 release locally via QEMU (BackOnly=$BACK_ONLY_BOOL, AllowCache=$ALLOW_CACHE)"
  echo "[release]   tip: pass --remote to build on a native-arm Graviton in ~5-10min"
  docker buildx build "${CACHE_FLAG[@]}" --platform linux/arm64 --load -t rc_build_image \
    --build-arg APP_REVISION="$REVISION" \
    --build-arg BACK_ONLY="$BACK_ONLY_BOOL" \
    --build-arg VUE_APP_BASE_URL="$VUE_BASE" \
    --build-arg VUE_APP_APPSIGNAL_FRONT="$VUE_APPSIGNAL_KEY" \
    .

  echo "[release] extracting tarballs"
  docker rm -f rc_extract >/dev/null 2>&1 || true
  docker create --platform linux/arm64 --name rc_extract rc_build_image >/dev/null
  docker cp rc_extract:/home/rc/build/rc.tar.gz ./build/
  if [[ "$BACK_ONLY_BOOL" == "false" ]]; then
    docker cp rc_extract:/home/rc/build/vue.tar.gz ./build/
  fi
  docker rm rc_extract >/dev/null
fi

if [[ "$BUILD_ONLY" == "1" ]]; then
  echo "[release] --build-only — tarballs in build/, skipping deploy"
  ls -la build/*.tar.gz
  exit 0
fi

# === 3. ship to prod (delegate to deploy.sh — leave it alone) =================
# In --remote mode this already happened on the builder; skip.
if [[ "$REMOTE_USED" == "0" ]]; then
  echo "[release] running deploy/bin/deploy.sh"
  ./deploy/bin/deploy.sh
else
  echo "[release] skipping local deploy.sh — deploy was run on the builder"
fi

# === 4. verify deployed revision (read priv/VERSION on prod, NOT journal) =====
# Reading from the static file is immune to journalctl rollover, which is
# what masked the wrong-revision incident on 2026-06-07.
# (nodes.sh already sourced by the preflight section.)
echo "[release] verifying deployed revision on $HOST"
# The remote command ends in `|| true` so the ONLY source of a non-zero
# exit is ssh's own transport failure (255 — timeout, no route, refused).
# A missing VERSION file still exits 0 and falls through to the revision
# comparison below. PIPESTATUS[0] gives ssh's exit, not tr's. We disable
# set -e around the call so a connection failure doesn't abort before we
# can report it. A timeout here is a reachability problem (your IP isn't
# allowed on prod:22, instance down, ...), NOT a stale Docker layer, and
# must not be reported as one.
set +e
PROD_REV=$(ssh "${SSH_OPTS[@]}" "$HOST" \
  'cat /home/rc/rc/lib/rc-*/priv/VERSION 2>/dev/null || true' \
  | tr -d '\r\n ')
SSH_EXIT=${PIPESTATUS[0]}
set -e

if [[ "$SSH_EXIT" -ne 0 ]]; then
  cat <<EOF

========================================
  RELEASE: INCONCLUSIVE — could not verify prod
========================================
  expected : $REVISION
  prod     : <unreachable> (ssh exit $SSH_EXIT)
========================================
  The build and deploy steps completed, but the verification step could
  not reach $HOST over SSH (connection failed — not an auth or revision
  error). This is almost always a network/reachability problem — e.g.
  your current IP is not allowed on the prod security group's port 22, or
  the instance is unreachable — NOT a stale Docker layer.

  Your deploy most likely succeeded. Confirm once SSH is reachable:
    ssh ${SSH_OPTS[*]} $HOST 'cat /home/rc/rc/lib/rc-*/priv/VERSION'

  The deploy notice may still be active on prod — once reachability is
  back, clear it with /cleardeploy on Discord (or re-run the verify).
EOF
  clear_deploy_notice
  exit 3
fi

if [[ "$PROD_REV" != "$REVISION" ]]; then
  cat <<EOF

========================================
  RELEASE: FAIL — wrong revision live
========================================
  expected : $REVISION
  prod     : ${PROD_REV:-<unreadable>}
========================================
  The deploy itself ran but prod is on the wrong revision. Likely cause:
  Docker layer cache served a stale COPY layer. Re-run with RC_NO_CACHE=1
  (default) and verify rc_build_image was rebuilt (not cache-hit).
EOF
  clear_deploy_notice
  exit 1
fi

# === 5. per-instance maintenance recovery =====================================
# deploy.sh's post-start restore is one big Enum.each; a single crash inside
# any restore_instance/2 call short-circuits the rest of the loop. This pass
# runs the restore per-instance with try/rescue/catch so one corrupt
# instance can't starve healthy ones. It's also tolerant of the case where
# nothing is in maintenance (no-op).
echo "[release] running per-instance maintenance recovery"
set +e
RECOVERY_OUTPUT=$(ssh "${SSH_OPTS[@]}" "$HOST" bash -s <<'REMOTE' 2>&1
set -e
cd /home/rc
set -a; . /etc/rc/env; set +a
./rc/bin/rc rpc '
  import Ecto.Query
  iids =
    try do
      RC.Repo.all(from i in RC.Instances.Instance, where: i.state == "maintenance", select: i.id)
    rescue
      _ -> []
    end
  results = Enum.map(iids, fn iid ->
    try do
      instance = RC.Instances.get_instance(iid)
      case RC.Instances.restore_instance(instance, 1) do
        {:ok, _} -> {:restored, iid}
        err -> {:failed, iid, inspect(err)}
      end
    rescue
      e -> {:failed, iid, Exception.message(e)}
    catch
      kind, payload -> {:failed, iid, inspect({kind, payload})}
    end
  end)
  Enum.each(results, fn
    {:restored, iid} ->
      IO.puts("restored " <> Integer.to_string(iid))
    {:failed, iid, reason} ->
      IO.puts("failed " <> Integer.to_string(iid) <> ": " <> reason)
  end)
'
REMOTE
)
RECOVERY_EXIT=$?
set -e

RESTORED_IDS=$(echo "$RECOVERY_OUTPUT" | awk '/^restored /{print $2}' | tr '\n' ' ' | sed 's/ *$//')
FAILED_LINES=$(echo "$RECOVERY_OUTPUT" | grep '^failed ' || true)

# If the rpc itself errored (couldn't even start), we'll have neither
# restored nor failed lines but a non-zero exit and some error text. Treat
# that as a partial failure rather than silently claiming success.
RPC_PROBABLY_BROKEN=0
if [[ "$RECOVERY_EXIT" -ne 0 && -z "$RESTORED_IDS" && -z "$FAILED_LINES" ]]; then
  RPC_PROBABLY_BROKEN=1
fi

# === 6. final summary =========================================================
echo
cat <<EOF
========================================
  RELEASE SUMMARY ($REVISION)
========================================
  prod revision : $PROD_REV (match)
  restored      : ${RESTORED_IDS:-none}
EOF

if [[ -n "$FAILED_LINES" ]]; then
  echo "  failed        :"
  echo "$FAILED_LINES" | sed 's/^/    /'
  echo "  (instances still in maintenance — investigate via ssh)"
  echo "========================================"
  echo "  RELEASE: PARTIAL — recovery incomplete"
  # New code is live — send the update-applied notice despite the
  # stuck instances.
  finish_deploy_notice
  exit 2
fi

if [[ "$RPC_PROBABLY_BROKEN" -eq 1 ]]; then
  echo "  failed        : (recovery rpc did not return parseable output)"
  echo "  raw output    :"
  echo "$RECOVERY_OUTPUT" | sed 's/^/    /' | head -20
  echo "========================================"
  echo "  RELEASE: PARTIAL — recovery rpc errored"
  finish_deploy_notice
  exit 2
fi

# === 7. CloudFront invalidation (remote-build mode only) ======================
# deploy.sh's tail does this when it runs locally. In --remote mode deploy.sh
# ran on the builder, which has no aws credentials, so its invalidation was
# warn-and-skipped. Re-run it here from the operator's box. Skipped for
# back-only deploys (no Vue change to invalidate) and for the local-build
# path (already handled by deploy.sh).
if [[ "$REMOTE_USED" == "1" && "$BACK_ONLY" != "1" ]]; then
  echo "[release] running CloudFront invalidation (post-remote-build)"
  if [[ ! -f .secrets/cf_distribution_id.txt ]]; then
    echo "[release] WARNING: .secrets/cf_distribution_id.txt missing — skipping invalidation"
  elif ! command -v aws >/dev/null 2>&1; then
    echo "[release] WARNING: aws CLI not installed locally — skipping invalidation"
  else
    CF_DIST_ID=$(cat .secrets/cf_distribution_id.txt)
    aws --profile rc-prod cloudfront create-invalidation \
      --distribution-id "$CF_DIST_ID" \
      --paths '/portal/*' \
      --query 'Invalidation.[Id,Status]' --output text \
      || echo "[release] WARNING: invalidation failed — edge caches will age out naturally"
  fi
fi

finish_deploy_notice

echo "  failed        : none"
echo "========================================"
echo "  RELEASE: PASS"

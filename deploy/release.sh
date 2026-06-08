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
#   ./deploy/release.sh                  # build and deploy HEAD
#   ./deploy/release.sh <git-ref>        # build and deploy a specific ref
#
# Env vars (all optional):
#   RC_SKIP_BUILD=1     Reuse existing build/*.tar.gz instead of rebuilding.
#                       Use after a manual `make build` / `make build-back`.
#   RC_BUILD_ONLY=1     Build + extract tarballs, then exit. Skips deploy,
#                       verify, and recovery. Useful for testing builds
#                       without touching prod.
#   RC_BACK_ONLY=1      Skip the Vue rebuild (faster — ~15-20 min instead of
#                       ~30-50 min on amd64-emulating-arm64). Skips Vue
#                       extraction too; existing vue.tar.gz is not touched.
#   RC_NO_CACHE=0       Allow Docker layer cache. Default is 1 (--no-cache)
#                       because cache poisoning of the COPY layer has
#                       shipped wrong revisions to prod in the past.
#   VUE_APP_BASE_URL    Public URL baked into the Vue bundle.
#                       Default: https://tetrarchyfalls.com
#   VUE_APP_APPSIGNAL_FRONT  AppSignal frontend key. Unused; defaults to empty.
#
# Exit codes:
#   0  PASS    — prod runs the requested revision, no failures.
#   1  FAIL    — build, deploy, or revision-match verification failed.
#   2  PARTIAL — deploy succeeded and revision matches, but one or more
#                instances failed to come out of maintenance. They are
#                listed in the summary; investigate via ssh.
#
# All steps emit "[release] ..." progress lines so the operator does not
# need to read intermediate output. The closing summary block is the
# canonical pass/fail signal.

set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
cd "$REPO"

# === 1. resolve target revision ===============================================
REV_INPUT="${1:-HEAD}"
if ! REVISION=$(git rev-parse --short "$REV_INPUT" 2>/dev/null); then
  echo "[release] fatal: unknown git revision '$REV_INPUT'" >&2
  exit 1
fi
echo "$REVISION" > priv/VERSION
echo "[release] target revision: $REVISION"

# === 2. build (default: --no-cache to defeat layer-cache poisoning) ==========
BACK_ONLY=${RC_BACK_ONLY:-0}
NO_CACHE=${RC_NO_CACHE:-1}
VUE_BASE=${VUE_APP_BASE_URL:-https://tetrarchyfalls.com}

if [[ "${RC_SKIP_BUILD:-0}" == "1" ]]; then
  echo "[release] RC_SKIP_BUILD=1 — reusing build/*.tar.gz"
  if [[ ! -f build/rc.tar.gz ]]; then
    echo "[release] fatal: build/rc.tar.gz missing — run a build first" >&2
    exit 1
  fi
  if [[ "$BACK_ONLY" != "1" && ! -f build/vue.tar.gz ]]; then
    echo "[release] fatal: build/vue.tar.gz missing (set RC_BACK_ONLY=1 to skip Vue)" >&2
    exit 1
  fi
else
  CACHE_FLAG=()
  [[ "$NO_CACHE" == "1" ]] && CACHE_FLAG+=(--no-cache)
  if [[ "$BACK_ONLY" == "1" ]]; then BACK_ONLY_BOOL=true; else BACK_ONLY_BOOL=false; fi

  echo "[release] building arm64 release (BACK_ONLY=$BACK_ONLY_BOOL, NO_CACHE=$NO_CACHE)"
  docker buildx build "${CACHE_FLAG[@]}" --platform linux/arm64 --load -t rc_build_image \
    --build-arg APP_REVISION="$REVISION" \
    --build-arg BACK_ONLY="$BACK_ONLY_BOOL" \
    --build-arg VUE_APP_BASE_URL="$VUE_BASE" \
    --build-arg VUE_APP_APPSIGNAL_FRONT="${VUE_APP_APPSIGNAL_FRONT:-}" \
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

if [[ "${RC_BUILD_ONLY:-0}" == "1" ]]; then
  echo "[release] RC_BUILD_ONLY=1 — tarballs in build/, skipping deploy"
  ls -la build/*.tar.gz
  exit 0
fi

# === 3. ship to prod (delegate to deploy.sh — leave it alone) =================
echo "[release] running deploy/bin/deploy.sh"
./deploy/bin/deploy.sh

# === 4. verify deployed revision (read priv/VERSION on prod, NOT journal) =====
# Reading from the static file is immune to journalctl rollover, which is
# what masked the wrong-revision incident on 2026-06-07.
source ./nodes.sh
HOST="${NODES[0]}"
echo "[release] verifying deployed revision on $HOST"
PROD_REV=$(ssh "${SSH_OPTS[@]}" "$HOST" \
  'cat /home/rc/rc/lib/rc-*/priv/VERSION 2>/dev/null' \
  | tr -d '\r\n ')

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
  exit 2
fi

if [[ "$RPC_PROBABLY_BROKEN" -eq 1 ]]; then
  echo "  failed        : (recovery rpc did not return parseable output)"
  echo "  raw output    :"
  echo "$RECOVERY_OUTPUT" | sed 's/^/    /' | head -20
  echo "========================================"
  echo "  RELEASE: PARTIAL — recovery rpc errored"
  exit 2
fi

echo "  failed        : none"
echo "========================================"
echo "  RELEASE: PASS"

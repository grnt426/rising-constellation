#!/bin/bash
#
# remote-build.sh — build the prod release on a transient AWS Graviton.
#
# Replaces the local `docker buildx ... --platform linux/arm64` step in
# release.sh, which uses QEMU emulation and takes ~35min on a beefy x86
# desktop. Native arm64 on a c7g.xlarge spot instance does it in ~3min.
#
# What this does:
#   1. Launch a spot c7g.xlarge (falls back to on-demand if no spot capacity)
#   2. Wait for SSH + cloud-init (docker installed)
#   3. Stream source tree to /home/ec2-user/src/ on the builder, and hand
#      it the dependency cache for the current mix.lock when S3 or this
#      machine has one (see "dependency cache" below; a build without one
#      saves one)
#   4. Upload the prod ssh key transiently so the builder can ship to prod
#   5. Run docker buildx natively (no --platform — host IS arm64); the
#      Dockerfile's `artifacts` stage is exported straight into src/build/
#   6. Run deploy/bin/deploy.sh on the builder — scp tarballs to prod (free
#      intra-region transfer) and ssh-bash-s the install script
#   7. Terminate the builder (EXIT trap, runs on success and failure)
#
# Why we run deploy.sh on the builder rather than pulling tarballs back to
# the operator and running deploy.sh locally:
#   - Saves ~100-200MB of EC2→home internet transfer (slow + you pay egress)
#   - Builder→prod is intra-region: free + ~1GB/s
#   - deploy.sh is the same script, just run from a different shell
#
# Caveat: deploy.sh's CloudFront-invalidation tail will warn-and-skip on
# the builder (no AWS credentials there). release.sh runs the invalidation
# from the operator's box after this script returns, so cache busting still
# happens — just from your laptop, not from the builder.
#
# Inputs (caller — release.sh — exports these):
#   REVISION            git short sha to embed in the build
#   BACK_ONLY_BOOL      "true" | "false"
#   VUE_BASE            VUE_APP_BASE_URL baked into the Vue bundle
#   SSH_KEY             path to the prod ssh key (from nodes.sh sourcing)
#
# Env vars (all optional):
#   RC_BUILD_ONLY=1     Build remotely, pull tarballs back to ./build/, do
#                       NOT deploy. Use for benchmarking or sanity-checking
#                       a build without touching prod.
#   RC_BUILDER_TYPE     EC2 instance type. Default: c7g.xlarge — the
#                       cheapest size that builds this comfortably (4 vCPU,
#                       8GB). Sizes and prices: deploy/aws-setup.md.
#   RC_BUILDER_REGION   AWS region. Default: us-east-1
#   RC_BUILDER_PROFILE  AWS CLI profile. Default: rc-prod
#   RC_BUILDER_KEYNAME  EC2 key pair name. Default: rc-prod
#   RC_BUILDER_SG       security group name. Default: rc-builder-sg
#   RC_BUILDER_ON_DEMAND=1   skip spot entirely, launch on-demand
#   RC_BUILDER_KEEP=1   don't terminate on exit (debugging only — costs money)
#   RC_DEPS_CACHE=0     Ignore the dependency cache: compile every dependency
#                       from scratch and leave the cache as it is.
#   RC_BUILD_CACHE_S3   s3://bucket[/prefix] holding the dependency cache
#                       shared by every machine that deploys. Default:
#                       s3://rc-build-cache-553872001542, a bucket for this
#                       and nothing else (deploy/provision-build-cache.ps1
#                       creates it). Set it empty to use this machine's
#                       copy only.
#   RC_BUILD_CACHE_DIR  Where the dependency cache lives on this machine.
#                       Default: %LOCALAPPDATA%\rc\build-cache on Windows,
#                       ${XDG_CACHE_HOME:-~/.cache}/rc/build-cache elsewhere.
#
# Prints a per-phase timings table at the end (boot+wait, source ship,
# docker build, deploy/pullback) and the slowest steps of the docker build
# — where the wall-clock went, on every run.

set -euo pipefail

REPO=$(cd "$(dirname "$0")/../.." && pwd)
cd "$REPO"

# Git-Bash on Windows translates args starting with `/` into Windows paths
# (so `/aws/service/...` becomes `C:/Program Files/Git/aws/service/...`),
# corrupting SSM parameter names, /dev/xvda block-device specs, etc. Disable
# the translation when we're under MSYS2/git-bash; no-op on real POSIX.
if [[ -n "${MSYSTEM:-}" ]]; then
  export MSYS_NO_PATHCONV=1
  export MSYS2_ARG_CONV_EXCL='*'
fi

: "${REVISION:?REVISION required (call from release.sh)}"
: "${BACK_ONLY_BOOL:?BACK_ONLY_BOOL required (true|false)}"
: "${VUE_BASE:?VUE_BASE required}"

# Pull SSH_KEY from nodes.sh if not in env. We need the local path to the
# prod private key so we can upload it transiently to the builder.
if [[ -z "${SSH_KEY:-}" ]]; then
  source ./nodes.sh
fi
[[ -f "$SSH_KEY" ]] || { echo "[remote-build] fatal: prod ssh key $SSH_KEY not found" >&2; exit 1; }

INSTANCE_TYPE="${RC_BUILDER_TYPE:-c7g.xlarge}"
REGION="${RC_BUILDER_REGION:-us-east-1}"
PROFILE="${RC_BUILDER_PROFILE:-rc-prod}"
KEY_NAME="${RC_BUILDER_KEYNAME:-rc-prod}"
SG_NAME="${RC_BUILDER_SG:-rc-builder-sg}"

AWS=(aws --profile "$PROFILE" --region "$REGION")

# --- dependency cache -------------------------------------------------------
# The fetched + compiled Elixir dependencies of an earlier build (see the
# depscache stage in the Dockerfile). Compiling them is most of a build and
# they only change with mix.lock. The key covers everything they are built
# from: the Dockerfile (toolchain), mix.exs and mix.lock. Builders are
# always arm64, hence the fixed arch in the name.
#
# Two copies of the same tarball:
#   * S3 ($RC_BUILD_CACHE_S3), shared by every machine that deploys. The
#     builder has no AWS credentials, so on a hit this script signs a
#     short-lived download link and the builder fetches it in-region.
#   * this machine ($RC_BUILD_CACHE_DIR), used when S3 does not have it or
#     cannot be reached, and uploaded with the source.
# A miss builds the dependencies from scratch, brings the new tarball back
# here and stores it in S3. S3 trouble never fails a build: it only warns.
if [[ -n "${RC_BUILD_CACHE_DIR:-}" ]]; then
  CACHE_DIR="$RC_BUILD_CACHE_DIR"
elif [[ -n "${LOCALAPPDATA:-}" ]] && command -v cygpath >/dev/null 2>&1; then
  CACHE_DIR="$(cygpath -u "$LOCALAPPDATA")/rc/build-cache"
else
  CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/rc/build-cache"
fi
DEPS_CACHE_KEY=$(cat Dockerfile mix.exs mix.lock | openssl dgst -sha256 | awk '{print substr($NF, 1, 16)}')
DEPS_CACHE_NAME="deps-arm64-$DEPS_CACHE_KEY.tar.gz"
DEPS_CACHE_FILE="$CACHE_DIR/$DEPS_CACHE_NAME"
DEPS_CACHE_S3="${RC_BUILD_CACHE_S3-s3://rc-build-cache-553872001542}"
DEPS_CACHE_S3="${DEPS_CACHE_S3%/}"
DEPS_CACHE_SAVE=false   # true on a miss: the build writes a new tarball
DEPS_CACHE_STATE=off    # off | miss | hit (S3) | hit (local), for the timings table

# aws.exe on Windows wants C:\... paths; this script has MSYS path
# conversion switched off (see above), so convert by hand.
native_path() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi
}

deps_cache_in_s3() {
  [[ -n "$DEPS_CACHE_S3" ]] || return 1
  local rest="${DEPS_CACHE_S3#s3://}"
  local bucket="${rest%%/*}"
  local prefix="${rest#"$bucket"}"
  prefix="${prefix#/}"
  "${AWS[@]}" s3api head-object --bucket "$bucket" \
    --key "${prefix:+$prefix/}$DEPS_CACHE_NAME" >/dev/null 2>&1
}

# Copy this machine's tarball to S3. Best-effort.
deps_cache_to_s3() {
  [[ -n "$DEPS_CACHE_S3" ]] || return 0
  if "${AWS[@]}" s3 cp "$(native_path "$DEPS_CACHE_FILE")" \
       "$DEPS_CACHE_S3/$DEPS_CACHE_NAME" --only-show-errors; then
    echo "[remote-build] dependency cache stored in $DEPS_CACHE_S3"
  else
    echo "[remote-build] WARNING: could not store the dependency cache in $DEPS_CACHE_S3" >&2
    echo "[remote-build]   (bucket: deploy/provision-build-cache.ps1; access: deploy/iam/claude-access-build-cache.json);" >&2
    echo "[remote-build]   it stays on this machine only" >&2
  fi
}

# --- timing instrumentation -----------------------------------------------
# All times in seconds since script start. Printed at end as a table.
T_START=$SECONDS
T_LAUNCH_DONE=0   # boot + ssh + docker ready
T_SHIP_DONE=0     # source streamed to builder
T_BUILD_DONE=0    # docker buildx finished, tarballs in src/build/
T_FINAL_DONE=0    # deploy.sh OR pullback finished
T_CACHE_SAVE=0    # seconds spent bringing a new dependency cache back
BUILD_STEPS=""    # slowest docker build steps, read off the builder's log

print_timings() {
  local total=$((SECONDS - T_START))
  local final_label
  final_label=$(printf '%-29s' "${T_FINAL_LABEL:-deploy}")
  cat <<EOF

[remote-build] phase timings
  launch + ssh + docker        : ${T_LAUNCH_DONE}s
  source + cache stream        : $((T_SHIP_DONE - T_LAUNCH_DONE))s
  docker buildx                : $((T_BUILD_DONE - T_SHIP_DONE))s (dependency cache: $DEPS_CACHE_STATE)
  save dependency cache        : ${T_CACHE_SAVE}s
  ${final_label}: $((T_FINAL_DONE - T_BUILD_DONE - T_CACHE_SAVE))s
  -----
  total (excl. terminate)      : ${T_FINAL_DONE}s
  total (incl. terminate)      : ${total}s
EOF
  if [[ -n "$BUILD_STEPS" ]]; then
    echo
    echo "[remote-build] slowest docker build steps (stages run in parallel, so these overlap)"
    echo "$BUILD_STEPS"
  fi
}

# --- pre-flight -----------------------------------------------------------
command -v aws >/dev/null || { echo "[remote-build] fatal: aws CLI not installed" >&2; exit 1; }
command -v tar >/dev/null || { echo "[remote-build] fatal: tar not installed" >&2; exit 1; }

SG_ID=$("${AWS[@]}" ec2 describe-security-groups \
  --filters "Name=group-name,Values=$SG_NAME" \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo "None")
if [[ "$SG_ID" == "None" || -z "$SG_ID" ]]; then
  echo "[remote-build] fatal: security group '$SG_NAME' not found in $REGION" >&2
  echo "  on Windows: run .\\deploy\\bin\\setup-builder.ps1 once to create it" >&2
  echo "  on POSIX:   run ./deploy/bin/setup-builder.sh once to create it" >&2
  exit 1
fi
echo "[remote-build] using SG $SG_NAME ($SG_ID)"

# --- resolve the builder AMI ----------------------------------------------
# First choice: Amazon's ECS-optimized AL2023 image. It is plain AL2023 with
# Docker already installed and running, which is the point: installing
# Docker on first boot is ~50s of every build. (It costs nothing extra; its
# ECS agent finds no cluster to join and idles.) Newest one by name, so
# there is no AMI id to track by hand.
AMI_ID=$("${AWS[@]}" ec2 describe-images --owners amazon \
  --filters 'Name=name,Values=al2023-ami-ecs-hvm-*-arm64' 'Name=state,Values=available' \
  --query 'sort_by(Images,&CreationDate)[-1].ImageId' --output text 2>/dev/null || true)
if [[ -n "$AMI_ID" && "$AMI_ID" != "None" ]]; then
  echo "[remote-build] AMI: $AMI_ID (AL2023 with Docker preinstalled)"
else
  # Fallback: stock AL2023 via the SSM public parameter; user-data below
  # installs Docker.
  AMI_ID=$("${AWS[@]}" ssm get-parameters \
    --names /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64 \
    --query 'Parameters[0].Value' --output text)
  if [[ -z "$AMI_ID" || "$AMI_ID" == "None" ]]; then
    echo "[remote-build] fatal: SSM AMI lookup returned empty" >&2
    exit 1
  fi
  echo "[remote-build] AMI: $AMI_ID (stock AL2023; Docker is installed at boot)"
fi

# --- launch ---------------------------------------------------------------
# user-data makes Docker usable by ec2-user, installing it first on an
# image that lacks it (stock AL2023). Cloud-init runs async; we poll for
# `docker info` success via SSH before kicking off the build. Nothing else
# is installed: the build itself runs in containers, and the source arrives
# as a tar stream (so no git).
USER_DATA_PLAIN='#!/bin/bash
exec > /var/log/builder-init.log 2>&1
set -x
command -v docker >/dev/null || dnf install -y docker
systemctl enable --now docker
usermod -aG docker ec2-user
# ECS-optimized image only: its agent has no cluster to join and would
# restart every 15s for the life of the builder.
systemctl disable ecs && systemctl stop --no-block ecs
'

# AWS expects user-data as base64. Use openssl since base64(1) flags differ
# across platforms (Windows Git-Bash lacks -w, BSD base64 lacks it too).
USER_DATA=$(printf '%s' "$USER_DATA_PLAIN" | openssl base64 -A)

# The root volume is plain gp3 (125MB/s, 3000 IOPS). The first half-minute
# of a build (image pulls, three copies of the build context, two `npm ci`)
# writes at that cap; `Iops=8000,Throughput=600` in the mapping below made a
# cached build 22s faster on a c7g.2xlarge for about half a cent per deploy.
launch() {
  local market_args=("$@")
  "${AWS[@]}" ec2 run-instances \
    --image-id "$AMI_ID" \
    --instance-type "$INSTANCE_TYPE" \
    --key-name "$KEY_NAME" \
    --security-group-ids "$SG_ID" \
    --user-data "$USER_DATA" \
    --block-device-mappings 'DeviceName=/dev/xvda,Ebs={VolumeSize=40,VolumeType=gp3,DeleteOnTermination=true}' \
    --metadata-options 'HttpTokens=required,HttpEndpoint=enabled' \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=rc-builder-$REVISION},{Key=ManagedBy,Value=rc-remote-build.sh}]" \
    "${market_args[@]}" \
    --query 'Instances[0].InstanceId' --output text
}

if [[ "${RC_BUILDER_ON_DEMAND:-0}" == "1" ]]; then
  echo "[remote-build] launching on-demand $INSTANCE_TYPE"
  INSTANCE_ID=$(launch)
else
  echo "[remote-build] launching spot $INSTANCE_TYPE (one-time, max=on-demand)"
  if ! INSTANCE_ID=$(launch \
      --instance-market-options 'MarketType=spot,SpotOptions={SpotInstanceType=one-time}' \
      2>/tmp/rc-spot-err); then
    echo "[remote-build] spot launch failed:"
    sed 's/^/  /' /tmp/rc-spot-err >&2 || true
    echo "[remote-build] retrying on-demand"
    INSTANCE_ID=$(launch)
  fi
fi
echo "[remote-build] instance: $INSTANCE_ID"

cleanup() {
  local exit_code=$?
  if [[ "${RC_BUILDER_KEEP:-0}" == "1" ]]; then
    echo "[remote-build] RC_BUILDER_KEEP=1 — leaving $INSTANCE_ID running"
    echo "[remote-build] terminate with:"
    echo "  ${AWS[*]} ec2 terminate-instances --instance-ids $INSTANCE_ID"
  else
    echo "[remote-build] terminating $INSTANCE_ID"
    "${AWS[@]}" ec2 terminate-instances --instance-ids "$INSTANCE_ID" >/dev/null \
      || echo "[remote-build] WARNING: terminate failed — check console for orphans" >&2
  fi
  # Only show timings if we got far enough for them to be meaningful.
  [[ "$T_FINAL_DONE" -gt 0 ]] && print_timings
  exit "$exit_code"
}
trap cleanup EXIT

# --- wait for the instance ------------------------------------------------
# Only until it has an address. `ec2 wait instance-status-ok` takes ~2min
# (EC2's reachability checks) while sshd answers ~10s after launch, so the
# docker poll below is the real readiness check.
echo "[remote-build] waiting for the builder's address"
PUBLIC_DNS=""
for i in $(seq 1 90); do
  PUBLIC_DNS=$("${AWS[@]}" ec2 describe-instances --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].PublicDnsName' --output text 2>/dev/null || true)
  [[ -n "$PUBLIC_DNS" && "$PUBLIC_DNS" != "None" ]] && break
  PUBLIC_DNS=""
  sleep 2
done
if [[ -z "$PUBLIC_DNS" ]]; then
  echo "[remote-build] fatal: $INSTANCE_ID never got a public address" >&2
  exit 1
fi
echo "[remote-build] builder: $PUBLIC_DNS"

SSH_OPTS=(-i "$SSH_KEY"
  -o StrictHostKeyChecking=accept-new
  -o UserKnownHostsFile=/dev/null
  -o LogLevel=ERROR
  -o ConnectTimeout=10
  -o ServerAliveInterval=30)
B="ec2-user@$PUBLIC_DNS"

# Poll docker readiness so we don't kick off the build while the instance
# is still booting or dnf is still installing docker. Early attempts fail
# on connection refused / no authorized key yet; that is expected.
echo "[remote-build] waiting for docker on builder"
for i in $(seq 1 150); do
  if ssh "${SSH_OPTS[@]}" "$B" 'docker info' >/dev/null 2>&1; then
    echo "[remote-build] docker up $((SECONDS - T_START))s after start"
    break
  fi
  sleep 2
  if [[ $i -eq 150 ]]; then
    echo "[remote-build] fatal: docker never came up — check /var/log/builder-init.log on $PUBLIC_DNS" >&2
    exit 1
  fi
done
T_LAUNCH_DONE=$((SECONDS - T_START))

# --- ship source ----------------------------------------------------------
# tar | ssh stream avoids needing rsync (not in Git-Bash on Windows).
# Excludes mirror .dockerignore plus .git (we pass APP_REVISION as a build
# arg, so the build doesn't need history) and .secrets/.env (host-only).
echo "[remote-build] streaming source to builder"
ssh "${SSH_OPTS[@]}" "$B" 'rm -rf src && mkdir -p src'
tar --exclude='./_build' --exclude='./deps' --exclude='./node_modules' \
    --exclude='./assets/node_modules' --exclude='./front/node_modules' \
    --exclude='./build' --exclude='./pgdata' --exclude='./replays' \
    --exclude='./.git' --exclude='./.elixir_ls' --exclude='./.vscode' \
    --exclude='./.claude' --exclude='./.secrets' --exclude='./.env' \
    --exclude='./priv/static' --exclude='./priv/_storage' \
    --exclude='./cover' --exclude='./doc' \
    -czf - . | ssh "${SSH_OPTS[@]}" "$B" 'tar -xzf - -C src/'

# The build is always given a depscache dir; empty means "from scratch".
ssh "${SSH_OPTS[@]}" "$B" 'rm -rf depscache && mkdir -p depscache'
if [[ "${RC_DEPS_CACHE:-1}" != "1" ]]; then
  echo "[remote-build] dependency cache off (RC_DEPS_CACHE=0) — compiling dependencies from scratch"
else
  DEPS_CACHE_STATE=miss
  DEPS_CACHE_BACKFILL=0

  if deps_cache_in_s3; then
    echo "[remote-build] dependency cache hit ($DEPS_CACHE_KEY) in S3 — the builder downloads it"
    # The link is a 15-minute bearer token for that one object: never echo it.
    S3_URL=$("${AWS[@]}" s3 presign "$DEPS_CACHE_S3/$DEPS_CACHE_NAME" --expires-in 900 2>/dev/null || true)
    if [[ -n "$S3_URL" ]] \
       && ssh "${SSH_OPTS[@]}" "$B" "curl -fsS --max-time 120 -o depscache/deps-cache.tar.gz '$S3_URL'"; then
      DEPS_CACHE_STATE="hit (S3)"
    else
      echo "[remote-build] WARNING: the builder could not download it from S3" >&2
      ssh "${SSH_OPTS[@]}" "$B" 'rm -f depscache/deps-cache.tar.gz'
    fi
  fi

  if [[ "$DEPS_CACHE_STATE" == "miss" && -f "$DEPS_CACHE_FILE" ]]; then
    echo "[remote-build] dependency cache hit ($DEPS_CACHE_KEY) on this machine — uploading"
    scp "${SSH_OPTS[@]}" "$DEPS_CACHE_FILE" "$B:depscache/deps-cache.tar.gz"
    DEPS_CACHE_STATE="hit (local)"
    DEPS_CACHE_BACKFILL=1
  fi

  # A damaged tarball would be skipped by the build but never replaced:
  # treat it as a miss so this build writes a good one over it.
  if [[ "$DEPS_CACHE_STATE" != "miss" ]] \
     && ! ssh "${SSH_OPTS[@]}" "$B" 'gzip -t depscache/deps-cache.tar.gz'; then
    echo "[remote-build] WARNING: that dependency cache is damaged — ignoring it" >&2
    ssh "${SSH_OPTS[@]}" "$B" 'rm -f depscache/deps-cache.tar.gz'
    DEPS_CACHE_STATE=miss
    DEPS_CACHE_BACKFILL=0
  fi

  if [[ "$DEPS_CACHE_STATE" == "miss" ]]; then
    DEPS_CACHE_SAVE=true
    echo "[remote-build] dependency cache miss ($DEPS_CACHE_KEY) — compiling dependencies, saving them for next time"
  elif [[ "$DEPS_CACHE_BACKFILL" == "1" ]]; then
    # S3 did not have what this machine has (first run with S3 access, or
    # it expired there): share it.
    deps_cache_to_s3
  fi
fi
T_SHIP_DONE=$((SECONDS - T_START))

# --- upload prod ssh key transiently --------------------------------------
# The builder needs this to scp tarballs to prod and to ssh-bash-s the
# install script. Lives only for the life of the spot instance.
echo "[remote-build] uploading prod ssh key transiently"
ssh "${SSH_OPTS[@]}" "$B" 'mkdir -p ~/.ssh && chmod 700 ~/.ssh'
scp "${SSH_OPTS[@]}" "$SSH_KEY" "$B:.ssh/rc-prod.pem"
ssh "${SSH_OPTS[@]}" "$B" 'chmod 600 ~/.ssh/rc-prod.pem'

# --- build natively -------------------------------------------------------
NO_CACHE_FLAG=""
[[ "${RC_NO_CACHE:-1}" == "1" ]] && NO_CACHE_FLAG="--no-cache"

echo "[remote-build] running native arm64 docker build (NO_CACHE=${RC_NO_CACHE:-1})"
# BUILDKIT_PROGRESS=plain forces line-oriented output instead of the TTY
# progress bars that use CR-overwrites + ANSI — much easier to read when
# the stream is captured to a log file on the operator's machine.
# The `artifacts` stage holds only the tarballs; exporting it to src/build/
# puts them where deploy.sh reads them (no image to load and copy out of).
ssh "${SSH_OPTS[@]}" "$B" "set -eo pipefail
cd src
BUILDKIT_PROGRESS=plain docker buildx build $NO_CACHE_FLAG \\
  --target artifacts --output type=local,dest=build \\
  --build-context depscache=../depscache \\
  --build-arg DEPS_CACHE_SAVE='$DEPS_CACHE_SAVE' \\
  --build-arg APP_REVISION='$REVISION' \\
  --build-arg BACK_ONLY='$BACK_ONLY_BOOL' \\
  --build-arg VUE_APP_BASE_URL='$VUE_BASE' \\
  . 2>&1 | tee ~/buildkit.log"
T_BUILD_DONE=$((SECONDS - T_START))

# Where the build time went: plain progress prints "#N [stage i/n] <step>"
# when a step starts and "#N DONE 12.3s" when it ends. Best-effort; read
# now because the builder is gone by the time the timings table prints.
BUILD_STEPS=$(ssh "${SSH_OPTS[@]}" "$B" 'bash -s' <<'STEPS' 2>/dev/null || true
awk '
  /^#[0-9]+ \[/ && !($1 in name) { id = $1; $1 = ""; name[id] = substr($0, 2) }
  /^#[0-9]+ DONE [0-9.]+s/ && ($1 in name) && name[$1] !~ /^\[internal\]/ {
    t = $3; sub(/s$/, "", t); printf "%7.1fs  %s\n", t, substr(name[$1], 1, 96)
  }
' ~/buildkit.log | sort -rn | head -12
STEPS
)

# --- save a new dependency cache ------------------------------------------
# Only after a miss. Written under a temporary name so an interrupted copy
# never leaves a truncated cache behind; failing here never fails the build.
if [[ "$DEPS_CACHE_SAVE" == "true" ]]; then
  echo "[remote-build] saving the new dependency cache to $CACHE_DIR"
  mkdir -p "$CACHE_DIR"
  if scp "${SSH_OPTS[@]}" "$B:src/build/deps-cache.tar.gz" "$DEPS_CACHE_FILE.part" \
     && mv -f "$DEPS_CACHE_FILE.part" "$DEPS_CACHE_FILE"; then
    # Keep this one and the one before it (two branches, two lockfiles).
    ls -t "$CACHE_DIR"/deps-arm64-*.tar.gz 2>/dev/null | tail -n +3 \
      | while IFS= read -r old; do rm -f "$old"; done || true
    deps_cache_to_s3
  else
    echo "[remote-build] WARNING: could not save the dependency cache — the next build compiles them again" >&2
    rm -f "$DEPS_CACHE_FILE.part"
  fi
  ssh "${SSH_OPTS[@]}" "$B" 'rm -f src/build/deps-cache.tar.gz' || true
  T_CACHE_SAVE=$((SECONDS - T_START - T_BUILD_DONE))
fi

# --- final step: either pull tarballs back (build-only) or deploy from builder
if [[ "${RC_BUILD_ONLY:-0}" == "1" ]]; then
  # Build-only mode: pull tarballs back to ./build/ for inspection. Used
  # for benchmarking remote-vs-local without touching prod. Egress to your
  # laptop is ~$0.09/GB; tarballs are ~100-200MB so ~$0.018 per build.
  T_FINAL_LABEL='tarball pullback'
  echo "[remote-build] RC_BUILD_ONLY=1 — pulling tarballs back to ./build/"
  mkdir -p build
  scp "${SSH_OPTS[@]}" "$B:src/build/rc.tar.gz" ./build/
  if [[ "$BACK_ONLY_BOOL" == "false" ]]; then
    scp "${SSH_OPTS[@]}" "$B:src/build/vue.tar.gz" ./build/
  fi
  T_FINAL_DONE=$((SECONDS - T_START))
  echo "[remote-build] build complete — tarballs in ./build/ (NOT deployed)"
else
  # Deploy mode: deploy.sh sources nodes.sh which defaults to the prod SSH
  # host and SSH_KEY=~/.ssh/rc-prod.pem. Both are correct on the builder.
  T_FINAL_LABEL='deploy.sh (ship to prod)'
  # A backend-only build has no vue.tar.gz; tell deploy.sh so it ships the
  # release alone instead of refusing to run.
  DEPLOY_FLAGS=""
  [[ "$BACK_ONLY_BOOL" == "true" ]] && DEPLOY_FLAGS="--back-only"
  echo "[remote-build] running deploy/bin/deploy.sh $DEPLOY_FLAGS on builder (ships to prod + remote install)"
  ssh "${SSH_OPTS[@]}" "$B" "cd src && bash deploy/bin/deploy.sh $DEPLOY_FLAGS"
  T_FINAL_DONE=$((SECONDS - T_START))
  echo "[remote-build] build + deploy complete via builder"
fi

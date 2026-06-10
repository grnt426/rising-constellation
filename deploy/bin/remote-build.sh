#!/bin/bash
#
# remote-build.sh — build the prod release on a transient AWS Graviton.
#
# Replaces the local `docker buildx ... --platform linux/arm64` step in
# release.sh, which uses QEMU emulation and takes ~35min on a beefy x86
# desktop. Native arm64 on a c7g.4xlarge spot instance does it in ~5-8min.
#
# What this does:
#   1. Launch a spot c7g.4xlarge (falls back to on-demand if no spot capacity)
#   2. Wait for SSH + cloud-init (docker installed)
#   3. Stream source tree to /home/ec2-user/src/ on the builder
#   4. Upload the prod ssh key transiently so the builder can ship to prod
#   5. Run docker buildx natively (no --platform — host IS arm64)
#   6. Extract tarballs from the build image into src/build/
#   7. Run deploy/bin/deploy.sh on the builder — scp tarballs to prod (free
#      intra-region transfer) and ssh-bash-s the install script
#   8. Terminate the builder (EXIT trap, runs on success and failure)
#
# Why we run deploy.sh on the builder rather than pulling tarballs back to
# the operator and running deploy.sh locally:
#   - Saves ~100-200MB of EC2→home internet transfer (slow + you pay egress)
#   - Builder→prod is intra-region: free + ~1GB/s
#   - deploy.sh is unmodified, just runs in a different shell
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
#   VUE_APP_APPSIGNAL_FRONT  optional AppSignal frontend key
#   SSH_KEY             path to the prod ssh key (from nodes.sh sourcing)
#
# Env vars (all optional):
#   RC_BUILD_ONLY=1     Build remotely, pull tarballs back to ./build/, do
#                       NOT deploy. Use for benchmarking or sanity-checking
#                       a build without touching prod.
#   RC_BUILDER_TYPE     EC2 instance type. Default: c7g.4xlarge
#   RC_BUILDER_REGION   AWS region. Default: us-east-1
#   RC_BUILDER_PROFILE  AWS CLI profile. Default: rc-prod
#   RC_BUILDER_KEYNAME  EC2 key pair name. Default: rc-prod
#   RC_BUILDER_SG       security group name. Default: rc-builder-sg
#   RC_BUILDER_ON_DEMAND=1   skip spot entirely, launch on-demand
#   RC_BUILDER_KEEP=1   don't terminate on exit (debugging only — costs money)
#
# Prints a per-phase timings table at the end (boot+wait, source ship,
# docker build, deploy/pullback) — useful for benchmarking remote vs local.

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

INSTANCE_TYPE="${RC_BUILDER_TYPE:-c7g.4xlarge}"
REGION="${RC_BUILDER_REGION:-us-east-1}"
PROFILE="${RC_BUILDER_PROFILE:-rc-prod}"
KEY_NAME="${RC_BUILDER_KEYNAME:-rc-prod}"
SG_NAME="${RC_BUILDER_SG:-rc-builder-sg}"

AWS=(aws --profile "$PROFILE" --region "$REGION")

# --- timing instrumentation -----------------------------------------------
# All times in seconds since script start. Printed at end as a table.
T_START=$SECONDS
T_LAUNCH_DONE=0   # boot + status-ok + docker ready
T_SHIP_DONE=0     # source streamed to builder
T_BUILD_DONE=0    # docker buildx finished
T_EXTRACT_DONE=0  # tarballs copied out of build image
T_FINAL_DONE=0    # deploy.sh OR pullback finished

print_timings() {
  local total=$((SECONDS - T_START))
  cat <<EOF

[remote-build] phase timings
  launch + status-ok + docker  : ${T_LAUNCH_DONE}s
  source stream                : $((T_SHIP_DONE - T_LAUNCH_DONE))s
  docker buildx                : $((T_BUILD_DONE - T_SHIP_DONE))s
  extract tarballs             : $((T_EXTRACT_DONE - T_BUILD_DONE))s
  ${T_FINAL_LABEL:-deploy}                        : $((T_FINAL_DONE - T_EXTRACT_DONE))s
  -----
  total (excl. terminate)      : ${T_FINAL_DONE}s
  total (incl. terminate)      : ${total}s
EOF
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

# --- resolve latest AL2023 ARM AMI via SSM --------------------------------
# Using the SSM public parameter means we always get the current AMI without
# tracking ids by hand. Same approach AWS recommends in their docs.
AMI_ID=$("${AWS[@]}" ssm get-parameters \
  --names /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64 \
  --query 'Parameters[0].Value' --output text)
if [[ -z "$AMI_ID" || "$AMI_ID" == "None" ]]; then
  echo "[remote-build] fatal: SSM AMI lookup returned empty" >&2
  exit 1
fi
echo "[remote-build] AMI: $AMI_ID"

# --- launch ---------------------------------------------------------------
# user-data installs Docker + git on first boot. AL2023 doesn't include
# docker in the base image. Cloud-init runs async; we poll for `docker info`
# success via SSH before kicking off the build.
USER_DATA_PLAIN='#!/bin/bash
exec > /var/log/builder-init.log 2>&1
set -x
dnf install -y docker git
systemctl enable --now docker
usermod -aG docker ec2-user
'

# AWS expects user-data as base64. Use openssl since base64(1) flags differ
# across platforms (Windows Git-Bash lacks -w, BSD base64 lacks it too).
USER_DATA=$(printf '%s' "$USER_DATA_PLAIN" | openssl base64 -A)

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
echo "[remote-build] waiting for instance status-ok (typically 60-90s)"
"${AWS[@]}" ec2 wait instance-status-ok --instance-ids "$INSTANCE_ID"

PUBLIC_DNS=$("${AWS[@]}" ec2 describe-instances --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].PublicDnsName' --output text)
echo "[remote-build] builder: $PUBLIC_DNS"

SSH_OPTS=(-i "$SSH_KEY"
  -o StrictHostKeyChecking=accept-new
  -o UserKnownHostsFile=/dev/null
  -o LogLevel=ERROR
  -o ConnectTimeout=10
  -o ServerAliveInterval=30)
B="ec2-user@$PUBLIC_DNS"

# cloud-init runs after the status-ok signal. Poll docker readiness so we
# don't kick off the build while dnf is still installing it.
echo "[remote-build] waiting for docker on builder"
for i in $(seq 1 60); do
  if ssh "${SSH_OPTS[@]}" "$B" 'docker info' >/dev/null 2>&1; then
    echo "[remote-build] docker up after ${i}x5s"
    break
  fi
  sleep 5
  if [[ $i -eq 60 ]]; then
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
ssh "${SSH_OPTS[@]}" "$B" "set -e
cd src
BUILDKIT_PROGRESS=plain docker buildx build $NO_CACHE_FLAG --load -t rc_build_image \\
  --build-arg APP_REVISION='$REVISION' \\
  --build-arg BACK_ONLY='$BACK_ONLY_BOOL' \\
  --build-arg VUE_APP_BASE_URL='$VUE_BASE' \\
  --build-arg VUE_APP_APPSIGNAL_FRONT='${VUE_APP_APPSIGNAL_FRONT:-}' \\
  ."
T_BUILD_DONE=$((SECONDS - T_START))

# --- extract tarballs from the build image into src/build/ ----------------
# deploy.sh reads from ./build/, so we put them where it expects.
echo "[remote-build] extracting tarballs from build image"
ssh "${SSH_OPTS[@]}" "$B" 'set -e
cd src
mkdir -p build
docker rm -f rc_extract >/dev/null 2>&1 || true
docker create --name rc_extract rc_build_image >/dev/null
docker cp rc_extract:/home/rc/build/rc.tar.gz build/rc.tar.gz
'
if [[ "$BACK_ONLY_BOOL" == "false" ]]; then
  ssh "${SSH_OPTS[@]}" "$B" 'cd src && docker cp rc_extract:/home/rc/build/vue.tar.gz build/vue.tar.gz'
fi
ssh "${SSH_OPTS[@]}" "$B" 'cd src && docker rm rc_extract >/dev/null'
T_EXTRACT_DONE=$((SECONDS - T_START))

# --- final step: either pull tarballs back (build-only) or deploy from builder
if [[ "${RC_BUILD_ONLY:-0}" == "1" ]]; then
  # Build-only mode: pull tarballs back to ./build/ for inspection. Used
  # for benchmarking remote-vs-local without touching prod. Egress to your
  # laptop is ~$0.09/GB; tarballs are ~100-200MB so ~$0.018 per build.
  T_FINAL_LABEL='tarball pullback              '
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
  T_FINAL_LABEL='deploy.sh (ship to prod)      '
  echo "[remote-build] running deploy/bin/deploy.sh on builder (ships to prod + remote install)"
  ssh "${SSH_OPTS[@]}" "$B" 'cd src && bash deploy/bin/deploy.sh'
  T_FINAL_DONE=$((SECONDS - T_START))
  echo "[remote-build] build + deploy complete via builder"
fi

#!/bin/bash
#
# Spin up a local Ubuntu 22.04 container that stands in for an EC2 instance,
# run the same bootstrap-host.sh + deploy.sh pipeline against it that we'd
# run on AWS, and smoke-test the result.
#
# Requirements:
#   - docker (with systemd-capable kernel — Linux native or WSL2 backend)
#   - both build artifacts in ./build/ (run `make build` or the equivalent
#     docker build first)
#   - .secrets/rc-prod-env.json (the Secrets Manager payload we already
#     generated for AWS; we re-use it locally via RC_SECRET_FILE mode)
#   - ~/.ssh/rc-prod.pem (the EC2 key pair; its public half lands in the
#     test container's authorized_keys)
#
# What this script does:
#   1. Build the test container image
#   2. Run it with --privileged so systemd works
#   3. Generate the public key from rc-prod.pem and bind-mount it into the
#      container's authorized_keys
#   4. Copy the deploy/ tree and the test secret file into the container
#   5. Exec bootstrap-host.sh inside the container with RC_SECRET_FILE set
#   6. Run deploy.sh from the host (treating the container as the SSH target)
#   7. Curl localhost:8080 (the container's :80 forwarded) and report

set -euo pipefail

# git-bash on Windows aggressively translates Unix paths in command-line args
# into Windows paths (e.g. /home → C:/Program Files/Git/home). That breaks
# everything we hand to docker. Disable for the whole script. Harmless on
# Linux/macOS.
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL='*'

cd "$(dirname "$0")/../.."  # repo root

CONTAINER=rc-test-host
IMAGE=rc-test-host:latest
HOST_PORT=8888
TEST_HOSTNAME=rc-test-host.local

# --- preflight -------------------------------------------------------------
[[ -f build/rc.tar.gz && -f build/vue.tar.gz ]] || {
  echo "error: build/rc.tar.gz or build/vue.tar.gz missing — build first" >&2
  exit 1
}
[[ -f .secrets/rc-prod-env.json ]] || {
  echo "error: .secrets/rc-prod-env.json missing — generate it (see deploy/aws-setup.md)" >&2
  exit 1
}
[[ -f $HOME/.ssh/rc-prod.pem ]] || {
  echo "error: ~/.ssh/rc-prod.pem missing — create the EC2 key pair first" >&2
  exit 1
}

# --- 1. build the test image ----------------------------------------------
echo "[test] building $IMAGE"
docker build -t "$IMAGE" -f deploy/test/Dockerfile deploy/test/

# --- 2. (re)create the container ------------------------------------------
docker rm -f "$CONTAINER" 2>/dev/null || true

# Materialize the public key (ssh-keygen -y derives it from the private key).
PUB_KEY=$(ssh-keygen -y -f "$HOME/.ssh/rc-prod.pem")

echo "[test] starting $CONTAINER on host port $HOST_PORT"
# MSYS_NO_PATHCONV=1 stops git-bash from translating /sys, /run, etc. into
# Windows paths. Harmless on Linux. The cgroup bind-mount the older systemd-
# in-docker guides recommend isn't needed on cgroup v2 + recent Docker;
# --privileged + the tmpfs mounts is sufficient.
docker run -d \
  --name "$CONTAINER" \
  --privileged \
  --tmpfs /tmp --tmpfs /run --tmpfs /run/lock \
  --cgroupns=host \
  -p "$HOST_PORT:80" \
  -p "2222:22" \
  "$IMAGE"

# Inject the SSH key and a local copy of the secret file. Done via
# docker exec rather than a bind mount so paths are deterministic.
# MSYS_NO_PATHCONV=1 stops git-bash translating /home, /etc, etc. into
# Windows paths in commands handed to docker.
docker exec -u root "$CONTAINER" \
  bash -c "echo '$PUB_KEY' > /home/rc/.ssh/authorized_keys && chown rc:rc /home/rc/.ssh/authorized_keys && chmod 600 /home/rc/.ssh/authorized_keys"

# Wait for systemd to settle, then make sure sshd is up.
echo "[test] waiting for systemd + sshd"
for i in $(seq 1 20); do
  if docker exec "$CONTAINER" systemctl is-system-running --wait 2>/dev/null | grep -qE 'running|degraded'; then
    break
  fi
  sleep 1
done
docker exec -u root "$CONTAINER" systemctl start ssh.service

# Confirm SSH from the host works.
SSH_OPTS=(-i "$HOME/.ssh/rc-prod.pem" -p 2222 -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)
for i in $(seq 1 10); do
  if ssh "${SSH_OPTS[@]}" rc@127.0.0.1 true 2>/dev/null; then
    break
  fi
  sleep 1
done
ssh "${SSH_OPTS[@]}" rc@127.0.0.1 echo "SSH up"

# --- 3. ship deploy/ + secret file into the container ---------------------
echo "[test] uploading deploy/ tree"
docker exec -u root "$CONTAINER" mkdir -p /home/rc/deploy /etc/rc
docker cp ./deploy "$CONTAINER:/home/rc/"
docker cp ./.secrets/rc-prod-env.json "$CONTAINER:/etc/rc/secret.json"
docker exec -u root "$CONTAINER" chown -R rc:rc /home/rc/deploy

# --- 4. run bootstrap-host.sh inside the container ------------------------
echo "[test] running bootstrap-host.sh"
docker exec -u root \
  -e RC_HOST="$TEST_HOSTNAME" \
  -e RC_SECRET_FILE=/etc/rc/secret.json \
  "$CONTAINER" \
  bash /home/rc/deploy/bin/bootstrap-host.sh

# --- 5. run deploy.sh from the host, targeting the container --------------
echo "[test] running deploy.sh against the container"
RC_SSH_HOST="rc@127.0.0.1" \
SSH_KEY="$HOME/.ssh/rc-prod.pem" \
RC_SSH_PORT=2222 \
RC_SSH_EXTRA_OPTS="-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o LogLevel=ERROR" \
  ./deploy/bin/deploy.sh

# --- 6. smoke test --------------------------------------------------------
echo "[test] smoke testing http://localhost:$HOST_PORT/"
sleep 2
http_code=$(curl -sSo /dev/null -w "%{http_code}" "http://localhost:$HOST_PORT/")
echo "[test] HTTP $http_code"

if [[ "$http_code" == "200" || "$http_code" == "301" || "$http_code" == "302" ]]; then
  echo
  echo "=== local deploy succeeded ==="
  echo "Container: $CONTAINER  (docker logs $CONTAINER, docker exec -it $CONTAINER bash)"
  echo "Tear down: docker rm -f $CONTAINER"
  exit 0
else
  echo
  echo "=== local deploy did NOT serve 2xx/3xx — investigate ==="
  echo "Try: docker exec $CONTAINER journalctl -u rc.service -n 50"
  exit 1
fi

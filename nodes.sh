#!/bin/bash
#
# Deploy target configuration. Sourced by upload/deploy scripts.
#
# Defaults below point at the current prod host (tetrarchyfalls.com).
# Override via env vars if you're deploying elsewhere:
#
#   RC_SSH_HOST=rc@other-host SSH_KEY=~/.ssh/other.pem ./deploy/bin/deploy.sh
#
# - RC_SSH_HOST       [user@]host       SSH destination (default: prod)
# - SSH_KEY           path              EC2 key pair private key
# - RC_SSH_PORT       port              non-22 SSH port (e.g. 2222 for the
#                                       local test container)
# - RC_SSH_EXTRA_OPTS "-o foo=bar ..."  passed through to ssh/scp (e.g.
#                                       UserKnownHostsFile=/dev/null for tests)

RC_SSH_HOST="${RC_SSH_HOST:-rc@ec2-98-91-16-141.compute-1.amazonaws.com}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/rc-prod.pem}"
RC_SSH_PORT="${RC_SSH_PORT:-22}"
RC_SSH_EXTRA_OPTS="${RC_SSH_EXTRA_OPTS:-}"

export NODES=("$RC_SSH_HOST")

# Build the option arrays. ssh uses -p, scp uses -P — keep them separate.
_common_opts=(-i "$SSH_KEY" -o StrictHostKeyChecking=accept-new)
if [[ -n "$RC_SSH_EXTRA_OPTS" ]]; then
  # Split RC_SSH_EXTRA_OPTS on whitespace, append to common opts.
  IFS=' ' read -r -a _extra <<< "$RC_SSH_EXTRA_OPTS"
  _common_opts+=("${_extra[@]}")
fi

export SSH_OPTS=("${_common_opts[@]}" -p "$RC_SSH_PORT")
export SCP_OPTS=("${_common_opts[@]}" -P "$RC_SSH_PORT")

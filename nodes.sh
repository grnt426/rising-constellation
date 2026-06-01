#!/bin/bash
#
# Deploy target configuration. Sourced by the upload/deploy scripts.
#
# Each entry in NODES is an SSH destination string of the form
# [user@]host[:port]. The default user (if none is in the string) is "rc".
#
# Override SSH_KEY to point at the EC2 key pair private key. Defaults to
# ~/.ssh/rc-prod.pem so a fresh checkout doesn't need anything edited as
# long as that path is populated.

export NODES=("${RC_SSH_HOST:-rc@ec2-CHANGEME.compute-1.amazonaws.com}")
export SSH_KEY="${SSH_KEY:-$HOME/.ssh/rc-prod.pem}"
export SSH_OPTS=(-i "$SSH_KEY" -o StrictHostKeyChecking=accept-new)

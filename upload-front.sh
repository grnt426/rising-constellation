#!/bin/bash
set -euo pipefail

source ./nodes.sh

for node in "${NODES[@]}"; do
  echo "[upload-front] $node"
  scp "${SSH_OPTS[@]}" ./build/vue.tar.gz "$node:/home/rc/"
done

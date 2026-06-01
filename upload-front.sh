#!/bin/bash
set -euo pipefail

source ./nodes.sh

for node in "${NODES[@]}"; do
  echo "[upload-front] $node"
  scp "${SCP_OPTS[@]}" ./build/vue.tar.gz "$node:/home/rc/"
done

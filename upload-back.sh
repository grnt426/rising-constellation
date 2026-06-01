#!/bin/bash
set -euo pipefail

source ./nodes.sh

for node in "${NODES[@]}"; do
  echo "[upload-back] $node"
  scp "${SCP_OPTS[@]}" ./build/rc.tar.gz "$node:/home/rc/"
done

#!/bin/bash

if [[ $BACK_ONLY == "true" ]]; then
  echo "BACK_ONLY=true, skipping frontend"
  exit 0
fi

set -euo pipefail

if [[ -z "${VUE_APP_BASE_URL:-}" ]]; then
  echo "error: VUE_APP_BASE_URL is required for a prod Vue build" >&2
  echo "  example: VUE_APP_BASE_URL=https://your-domain.example make build" >&2
  exit 1
fi

export VUE_APP_BASE_URL
export VUE_APP_APPSIGNAL_FRONT="${VUE_APP_APPSIGNAL_FRONT:-}"
export VUE_APP_APPSIGNAL_REVISION="${APP_REVISION:-}"
export NODE_ENV=production

echo "REVISION:  ${VUE_APP_APPSIGNAL_REVISION}"
echo "BASE_URL:  ${VUE_APP_BASE_URL}"

# Output staging dir. The shape (www-root/asylamba/{static,front}) matches
# what nginx on the prod host expects under its docroot — see
# deploy/nginx/rc.conf.example.
OUT_ROOT="${HOME}/www-root/asylamba"
mkdir -p "${OUT_ROOT}"

function phoenix() {
  cd /home/rc/build
  NODE_ENV= npm ci --prefix ./assets
  npm run deploy --prefix ./assets
  mix phx.digest
  mv priv/static "${OUT_ROOT}/static"
}

function vue() {
  cd front
  NODE_ENV= npm ci
  NODE_OPTIONS="--openssl-legacy-provider" npm run build

  cd /home/rc/build
  mv ./front/dist "${OUT_ROOT}/front"
}

phoenix
vue game

tar -czvf /home/rc/build/vue.tar.gz "${OUT_ROOT}"

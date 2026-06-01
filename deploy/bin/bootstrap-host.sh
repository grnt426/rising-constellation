#!/bin/bash
#
# First-time bootstrap for a fresh Ubuntu 22.04 EC2 instance.
#
# Run this ONCE on the instance after launch, as a user with sudo. The
# easiest path: scp this file plus deploy/systemd/*.service and
# deploy/nginx/rc.conf.example to the host, then `sudo bash bootstrap-host.sh`.
#
# Prerequisites on the EC2 instance:
#   - Ubuntu 22.04 LTS
#   - An IAM instance role attached with permission to call
#     secretsmanager:GetSecretValue on the secret named in RC_SECRET_ID
#   - The Secrets Manager secret already exists and is a JSON object
#     matching the env contract in .env.example
#
# Required env vars (set before invoking, or pass on the command line):
#   RC_HOST       — public hostname clients will hit (the EC2 public DNS
#                   for the first deploy, or a real domain later)
#
# Secret source (exactly one):
#   RC_SECRET_FILE  — local JSON file. Skips AWS entirely. Useful for
#                     testing the bootstrap pipeline in a container or VM
#                     without AWS access.
#   RC_SECRET_ID    — name/ARN of the AWS Secrets Manager secret. Default
#                     when RC_SECRET_FILE is unset. (default: rc/prod/env)
#   AWS_REGION      — AWS region for Secrets Manager (default: us-east-1)
#
# What this does:
#   1. apt-get install packages (nginx, postgresql, awscli, jq)
#   2. Create the `rc` system user (uid 1001 — matches the build image)
#   3. Set up Postgres: create the rcprod user + rc_prod database. The
#      password is pulled from the Secrets Manager DATABASE_URL.
#   4. Install systemd units and the rc-fetch-secrets binary
#   5. Drop the nginx vhost (HTTP only — TLS is a follow-up)
#   6. Enable services. Does NOT start rc.service — that requires the
#      release tarball, which deploy.sh handles.
#
# Idempotent — safe to re-run.

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "error: bootstrap-host.sh must be run as root (sudo)" >&2
  exit 1
fi

RC_HOST="${RC_HOST:?RC_HOST is required — set to the public hostname (e.g. ec2-1-2-3-4.compute-1.amazonaws.com)}"
RC_SECRET_FILE="${RC_SECRET_FILE:-}"
RC_SECRET_ID="${RC_SECRET_ID:-rc/prod/env}"
AWS_REGION="${AWS_REGION:-us-east-1}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEPLOY_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "=== bootstrap-host.sh ==="
echo "RC_HOST=$RC_HOST"
if [[ -n "$RC_SECRET_FILE" ]]; then
  echo "RC_SECRET_FILE=$RC_SECRET_FILE (local mode — no AWS)"
else
  echo "RC_SECRET_ID=$RC_SECRET_ID"
  echo "AWS_REGION=$AWS_REGION"
fi
echo

# Helper: pull the secret JSON from whichever source is configured. Mirrors
# the priority order in rc-fetch-secrets exactly.
fetch_secret_json() {
  if [[ -n "$RC_SECRET_FILE" ]]; then
    if [[ ! -r "$RC_SECRET_FILE" ]]; then
      echo "error: $RC_SECRET_FILE missing or unreadable" >&2
      exit 1
    fi
    cat "$RC_SECRET_FILE"
  else
    aws secretsmanager get-secret-value \
      --secret-id "$RC_SECRET_ID" \
      --region "$AWS_REGION" \
      --query SecretString \
      --output text
  fi
}

# --- 1. Packages -----------------------------------------------------------
echo "[1/6] installing packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq \
  nginx \
  postgresql postgresql-contrib \
  awscli jq \
  ca-certificates

# --- 2. rc user ------------------------------------------------------------
echo "[2/6] ensuring rc user exists"
if ! id -u rc >/dev/null 2>&1; then
  # uid 1001 matches the Dockerfile build user — keeps file ownership
  # consistent across build artifacts and runtime.
  useradd -m -u 1001 -s /bin/bash rc
fi
install -d -o rc -g rc -m 0755 /home/rc /home/rc/www-root
install -d -o rc -g rc -m 0700 /home/rc/.ssh

# Seed rc's authorized_keys from whichever sudo user ran the bootstrap.
# On EC2, that's typically `ubuntu` (default cloud-init key) or `ec2-user`.
# This lets deploy.sh SSH in as rc using the EC2 key pair. Idempotent —
# we only copy if rc has no key yet.
if [[ ! -s /home/rc/.ssh/authorized_keys ]]; then
  invoker="${SUDO_USER:-}"
  if [[ -n "$invoker" && -r "/home/$invoker/.ssh/authorized_keys" ]]; then
    install -o rc -g rc -m 0600 "/home/$invoker/.ssh/authorized_keys" /home/rc/.ssh/authorized_keys
    echo "[2/6] seeded /home/rc/.ssh/authorized_keys from /home/$invoker/.ssh/authorized_keys"
  fi
fi

# Allow the rc user to control its own service unit (and only that one)
# without a password, AND without a TTY. The default Ubuntu sudoers sets
# `Defaults use_pty`, which makes even NOPASSWD commands require a TTY —
# breaks deploy.sh (ssh bash -s has no TTY). Opting the rc user out of
# use_pty restores the expected behavior.
cat >/etc/sudoers.d/rc-systemctl <<'SUDO'
Defaults:rc !use_pty
rc ALL=NOPASSWD: /bin/systemctl start rc.service, /bin/systemctl stop rc.service, /bin/systemctl restart rc.service, /bin/systemctl status rc.service, /usr/bin/systemctl start rc.service, /usr/bin/systemctl stop rc.service, /usr/bin/systemctl restart rc.service, /usr/bin/systemctl status rc.service
SUDO
chmod 0440 /etc/sudoers.d/rc-systemctl

# --- 3. PostgreSQL ---------------------------------------------------------
echo "[3/6] configuring PostgreSQL"
systemctl enable --now postgresql

# Pull DATABASE_URL from the configured secret source so we can mirror its
# credentials into Postgres. The runtime side reads the same URL via
# rc-fetch-secrets.
secret_json=$(fetch_secret_json)

database_url=$(echo "$secret_json" | jq -er '.DATABASE_URL')

# Parse ecto://USER:PASS@HOST:PORT/DBNAME. We only need user/pass/db; the
# host is going to be localhost.
db_user=$(echo "$database_url" | sed -E 's|^[a-z]+://([^:]+):.*|\1|')
db_pass=$(echo "$database_url" | sed -E 's|^[a-z]+://[^:]+:([^@]+)@.*|\1|')
db_name=$(echo "$database_url" | sed -E 's|.*/([^?]+)(\?.*)?$|\1|')

if [[ -z "$db_user" || -z "$db_pass" || -z "$db_name" ]]; then
  echo "error: could not parse DATABASE_URL from secret" >&2
  exit 1
fi

# Idempotent: create role + database if absent, otherwise sync the password.
sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$db_user'" | grep -q 1 || \
  sudo -u postgres psql -c "CREATE ROLE $db_user LOGIN PASSWORD '$db_pass';"

# Sync the password every run (in case it rotated in Secrets Manager).
sudo -u postgres psql -c "ALTER ROLE $db_user WITH PASSWORD '$db_pass';"

sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='$db_name'" | grep -q 1 || \
  sudo -u postgres psql -c "CREATE DATABASE $db_name OWNER $db_user;"

# --- 4. Systemd units and the secrets fetcher ------------------------------
echo "[4/6] installing systemd units and rc-fetch-secrets"
install -m 0755 "$DEPLOY_DIR/bin/rc-fetch-secrets" /usr/local/bin/rc-fetch-secrets
install -m 0644 "$DEPLOY_DIR/systemd/rc.service" /etc/systemd/system/rc.service
install -m 0644 "$DEPLOY_DIR/systemd/rc-fetch-secrets.service" /etc/systemd/system/rc-fetch-secrets.service

# Persist the secret source for the fetcher unit. Done via a drop-in so the
# unit file itself stays generic. RC_SECRET_FILE wins over RC_SECRET_ID in
# rc-fetch-secrets — we set whichever the bootstrap was invoked with.
install -d -m 0755 /etc/systemd/system/rc-fetch-secrets.service.d
if [[ -n "$RC_SECRET_FILE" ]]; then
  cat >/etc/systemd/system/rc-fetch-secrets.service.d/override.conf <<EOF
[Service]
Environment=RC_SECRET_FILE=$RC_SECRET_FILE
EOF
else
  cat >/etc/systemd/system/rc-fetch-secrets.service.d/override.conf <<EOF
[Service]
Environment=RC_SECRET_ID=$RC_SECRET_ID
Environment=AWS_REGION=$AWS_REGION
EOF
fi

install -d -o root -g root -m 0755 /etc/rc

systemctl daemon-reload
systemctl enable rc-fetch-secrets.service
systemctl enable rc.service

# Prime the env file now so the first deploy has it ready. Don't fail
# bootstrap if this errors — the secret might not be fully populated yet.
echo "[4/6] priming /etc/rc/env from Secrets Manager"
systemctl start rc-fetch-secrets.service || \
  echo "warning: rc-fetch-secrets.service failed; check with: journalctl -u rc-fetch-secrets" >&2

# --- 5. nginx --------------------------------------------------------------
echo "[5/6] configuring nginx"
# Render the example vhost with the real hostname swapped in. We start
# without TLS — certs are added in a follow-up once a real domain is in
# play. Drops the cert directives and the :80 redirect.
cat >/etc/nginx/sites-available/rc.conf <<NGINX
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name $RC_HOST _;

    root /home/rc/www-root/asylamba/static;

    location ~* "-[a-f0-9]{32}\.(?:css|js|png|jpg|jpeg|gif|svg|woff2?|ttf|eot)\$" {
        expires 1y;
        access_log off;
        add_header Cache-Control "public, immutable";
    }

    # The frontend (Hooks.login in assets/js/app.js) redirects to "/portal"
    # without a trailing slash after login. nginx location matching for
    # "/portal/" doesn't match "/portal", so add an explicit 301.
    location = /portal { return 301 /portal/; }

    location /portal/ {
        alias /home/rc/www-root/asylamba/front/;
        try_files \$uri \$uri/ /portal/index.html;
    }

    location /api/ {
        proxy_pass http://127.0.0.1:4000;
        proxy_http_version 1.1;
        proxy_set_header Host              \$host;
        proxy_set_header X-Real-IP         \$remote_addr;
        proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 300s;
        client_max_body_size 100m;
    }

    location /socket/ {
        proxy_pass http://127.0.0.1:4000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade           \$http_upgrade;
        proxy_set_header Connection        "upgrade";
        proxy_set_header Host              \$host;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
    }

    location /live/ {
        proxy_pass http://127.0.0.1:4000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade           \$http_upgrade;
        proxy_set_header Connection        "upgrade";
        proxy_set_header Host              \$host;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
    }

    location / {
        try_files \$uri @phoenix;
    }

    location @phoenix {
        proxy_pass http://127.0.0.1:4000;
        proxy_http_version 1.1;
        proxy_set_header Host              \$host;
        proxy_set_header X-Real-IP         \$remote_addr;
        proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
NGINX

ln -sf /etc/nginx/sites-available/rc.conf /etc/nginx/sites-enabled/rc.conf
rm -f /etc/nginx/sites-enabled/default

# Validate before (re)starting so a typo doesn't kill nginx.
nginx -t
# reload-or-restart handles both states: starts nginx if it's not running
# (fresh apt install in a container), reloads if it is.
systemctl enable nginx
systemctl reload-or-restart nginx

# --- 6. Done ---------------------------------------------------------------
echo
echo "=== bootstrap complete ==="
echo
echo "Next steps:"
echo "  - On your local machine, run from the repo root:"
echo "      VUE_APP_BASE_URL=http://$RC_HOST make build deploy"
echo
echo "  - Tail the service after deploy:"
echo "      sudo journalctl -fu rc.service"
echo

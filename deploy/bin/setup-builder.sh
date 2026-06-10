#!/bin/bash
#
# setup-builder.sh — one-time AWS setup for remote builds.
#
# Creates the security group used by deploy/bin/remote-build.sh. Run once
# per AWS account/region; idempotent so re-runs are safe.
#
# What it creates:
#   - Security group `rc-builder-sg` in the default VPC
#   - Inbound rule: SSH (tcp/22) from your current public IP (/32)
#
# What it reuses (not created here):
#   - EC2 key pair `rc-prod` — the same one you SSH to prod with. The
#     prod private key is uploaded to the builder transiently per build,
#     so there's no separate builder key to manage.
#
# Env vars (all optional):
#   RC_BUILDER_PROFILE  AWS CLI profile. Default: rc-prod
#   RC_BUILDER_REGION   AWS region. Default: us-east-1
#   RC_BUILDER_SG       SG name. Default: rc-builder-sg

set -euo pipefail

PROFILE="${RC_BUILDER_PROFILE:-rc-prod}"
REGION="${RC_BUILDER_REGION:-us-east-1}"
SG_NAME="${RC_BUILDER_SG:-rc-builder-sg}"

AWS=(aws --profile "$PROFILE" --region "$REGION")

echo "[setup-builder] profile=$PROFILE region=$REGION sg=$SG_NAME"

# --- discover your current public IP --------------------------------------
# We use checkip.amazonaws.com to keep external dependencies inside AWS.
# Falls back to ifconfig.me on failure.
MY_IP=$(curl -fsS https://checkip.amazonaws.com 2>/dev/null \
        || curl -fsS https://ifconfig.me 2>/dev/null \
        || true)
MY_IP=$(echo "$MY_IP" | tr -d '\r\n ')
if [[ ! "$MY_IP" =~ ^[0-9.]+$ ]]; then
  echo "[setup-builder] fatal: could not detect your public IP" >&2
  exit 1
fi
echo "[setup-builder] your IP: $MY_IP"

# --- default VPC ----------------------------------------------------------
VPC_ID=$("${AWS[@]}" ec2 describe-vpcs \
  --filters Name=is-default,Values=true \
  --query 'Vpcs[0].VpcId' --output text)
if [[ "$VPC_ID" == "None" || -z "$VPC_ID" ]]; then
  echo "[setup-builder] fatal: no default VPC in $REGION" >&2
  exit 1
fi
echo "[setup-builder] default VPC: $VPC_ID"

# --- create or reuse security group ---------------------------------------
SG_ID=$("${AWS[@]}" ec2 describe-security-groups \
  --filters "Name=group-name,Values=$SG_NAME" "Name=vpc-id,Values=$VPC_ID" \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo "None")

if [[ "$SG_ID" == "None" || -z "$SG_ID" ]]; then
  echo "[setup-builder] creating security group $SG_NAME"
  SG_ID=$("${AWS[@]}" ec2 create-security-group \
    --group-name "$SG_NAME" \
    --description "Transient builders for rc release pipeline" \
    --vpc-id "$VPC_ID" \
    --query 'GroupId' --output text)
  "${AWS[@]}" ec2 create-tags \
    --resources "$SG_ID" \
    --tags Key=ManagedBy,Value=rc-setup-builder.sh
else
  echo "[setup-builder] security group $SG_NAME already exists ($SG_ID)"
fi

# --- ensure SSH from your IP is allowed -----------------------------------
# Re-running the script after your IP changes will add a new rule for the
# new IP. Old rules stay (idempotent — we only ADD); clean them up manually
# if you want to keep the SG tidy:
#   aws ec2 revoke-security-group-ingress --group-id $SG_ID --ip-permissions ...
EXISTING=$("${AWS[@]}" ec2 describe-security-groups --group-ids "$SG_ID" \
  --query "SecurityGroups[0].IpPermissions[?FromPort==\`22\`].IpRanges[].CidrIp" \
  --output text)
if echo "$EXISTING" | grep -q "$MY_IP/32"; then
  echo "[setup-builder] SSH from $MY_IP/32 already allowed"
else
  echo "[setup-builder] authorizing SSH from $MY_IP/32"
  "${AWS[@]}" ec2 authorize-security-group-ingress \
    --group-id "$SG_ID" \
    --protocol tcp --port 22 \
    --cidr "$MY_IP/32" \
    --query 'SecurityGroupRules[0].SecurityGroupRuleId' --output text
fi

echo
echo "=== setup complete ==="
echo "  security group: $SG_NAME ($SG_ID)"
echo "  inbound SSH    : $MY_IP/32 (and any IPs from prior runs)"
echo
echo "You can now run a remote build with:"
echo "  RC_BUILD_REMOTE=1 ./deploy/release.sh"

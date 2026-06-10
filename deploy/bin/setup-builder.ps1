<#
.SYNOPSIS
  setup-builder.ps1 -- one-time AWS setup for remote builds.

.DESCRIPTION
  Creates the security group used by deploy/bin/remote-build (the SG
  inbound SSH rule from your current public IP).

  Run once per AWS account/region. Idempotent: re-running after your
  home IP changes adds a new rule for the new IP; old rules stay until
  you clean them up manually with `aws ec2 revoke-security-group-ingress`.

  What it creates:
    - Security group `rc-builder-sg` in the default VPC.
    - Inbound rule: SSH (tcp/22) from your current public IP (/32).

  What it reuses (not created here):
    - EC2 key pair `rc-prod` -- the same one you SSH to prod with. The
      prod private key is uploaded to the builder transiently per build,
      so there is no separate builder key to manage.

.PARAMETER AwsProfile
  AWS CLI profile. Default: rc-prod.

.PARAMETER Region
  AWS region. Default: us-east-1.

.PARAMETER SgName
  Security group name. Default: rc-builder-sg.

.EXAMPLE
  .\deploy\bin\setup-builder.ps1
  Default profile/region/SG name.
#>

[CmdletBinding()]
param(
  [string]$AwsProfile = "rc-prod",
  [string]$Region = "us-east-1",
  [string]$SgName = "rc-builder-sg"
)

$ErrorActionPreference = "Stop"

function Step([string]$msg) {
  Write-Host "[setup-builder] $msg"
}

function Fail([string]$msg, [int]$code = 1) {
  Write-Host "[setup-builder] fatal: $msg" -ForegroundColor Red
  exit $code
}

$awsBase = @('--profile', $AwsProfile, '--region', $Region)

Step "profile=$AwsProfile region=$Region sg=$SgName"

# --- discover your current public IP ------------------------------------------
# Prefer checkip.amazonaws.com so the IP check stays inside AWS; fall back
# to ifconfig.me on failure.
$myIp = $null
try {
  $myIp = (Invoke-WebRequest -Uri "https://checkip.amazonaws.com" -UseBasicParsing -TimeoutSec 10).Content.Trim()
} catch {
  try {
    $myIp = (Invoke-WebRequest -Uri "https://ifconfig.me" -UseBasicParsing -TimeoutSec 10).Content.Trim()
  } catch {
    Fail "could not detect your public IP (both checkip.amazonaws.com and ifconfig.me failed)"
  }
}
if ($myIp -notmatch '^\d+\.\d+\.\d+\.\d+$') {
  Fail "detected IP is not a valid IPv4 address: '$myIp'"
}
Step "your IP: $myIp"

# --- default VPC --------------------------------------------------------------
$vpcId = (& aws @awsBase ec2 describe-vpcs `
  --filters "Name=is-default,Values=true" `
  --query 'Vpcs[0].VpcId' --output text).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($vpcId) -or $vpcId -eq 'None') {
  Fail "no default VPC in $Region (or aws CLI failed; profile=$AwsProfile)"
}
Step "default VPC: $vpcId"

# --- create or reuse security group -------------------------------------------
$sgId = (& aws @awsBase ec2 describe-security-groups `
  --filters "Name=group-name,Values=$SgName" "Name=vpc-id,Values=$vpcId" `
  --query 'SecurityGroups[0].GroupId' --output text 2>$null)
if ($sgId) { $sgId = $sgId.Trim() }

if ([string]::IsNullOrWhiteSpace($sgId) -or $sgId -eq 'None') {
  Step "creating security group $SgName"
  $sgId = (& aws @awsBase ec2 create-security-group `
    --group-name $SgName `
    --description "Transient builders for rc release pipeline" `
    --vpc-id $vpcId `
    --query 'GroupId' --output text).Trim()
  if ($LASTEXITCODE -ne 0) { Fail "create-security-group failed" }
  & aws @awsBase ec2 create-tags --resources $sgId `
    --tags 'Key=ManagedBy,Value=rc-setup-builder.ps1' | Out-Null
} else {
  Step "security group $SgName already exists ($sgId)"
}

# --- ensure SSH from your IP is allowed ---------------------------------------
# Re-running after your IP changes ADDS the new rule. Old rules stay; clean
# up with `aws ec2 revoke-security-group-ingress` if you want the SG tidy.
$existing = & aws @awsBase ec2 describe-security-groups --group-ids $sgId `
  --query "SecurityGroups[0].IpPermissions[?FromPort==``22``].IpRanges[].CidrIp" `
  --output text
if ($existing -and ($existing -match [regex]::Escape("$myIp/32"))) {
  Step "SSH from $myIp/32 already allowed"
} else {
  Step "authorizing SSH from $myIp/32"
  $ruleId = (& aws @awsBase ec2 authorize-security-group-ingress `
    --group-id $sgId `
    --protocol tcp --port 22 `
    --cidr "$myIp/32" `
    --query 'SecurityGroupRules[0].SecurityGroupRuleId' --output text).Trim()
  if ($LASTEXITCODE -ne 0) { Fail "authorize-security-group-ingress failed" }
  Write-Host "  rule id: $ruleId"
}

Write-Host ""
Write-Host "=== setup complete ==="
Write-Host "  security group: $SgName ($sgId)"
Write-Host "  inbound SSH    : $myIp/32 (and any IPs from prior runs)"
Write-Host ""
Write-Host "You can now run a remote build with:"
Write-Host "  .\deploy\release.ps1 -BuildRemote"

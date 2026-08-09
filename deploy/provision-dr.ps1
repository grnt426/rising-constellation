# provision-dr.ps1 - one-shot disaster-recovery provisioning for prod.
#
# Run from the repo root on the operator machine with an AWS profile that
# has admin rights in the prod account (553872001542). Idempotent: every
# step checks before it creates, so re-running is safe.
#
# What it does:
#   1. S3 backup bucket (private, encrypted, N-day expiry lifecycle)
#   2. EC2 instance role + profile with write access to that bucket and
#      read access to the rc/prod/env secret; attaches it to the prod
#      instance
#   3. Pushes .secrets/rc-prod-env.json into Secrets Manager as
#      rc/prod/env (the off-host copy of /etc/rc/secret.json)
#   4. Installs the rc-db-backup script + systemd timer on the prod host
#      (ssh; prompts for the sudo password) and triggers a first backup
#
# Usage:
#   .\deploy\provision-dr.ps1 -AwsProfile my-admin-profile
#   .\deploy\provision-dr.ps1 -AwsProfile my-admin-profile -SkipHost
#
# The AWS steps (1-3) and the host step (4) are independent; -SkipAws /
# -SkipSecret / -SkipHost let you re-run just the part you need.

param(
    [Parameter(Mandatory = $true)] [string]$AwsProfile,
    [string]$Region = "us-east-1",
    [string]$Bucket = "rc-prod-backups-553872001542",
    [string]$InstanceId = "i-017d81bd1155ebfb3",
    [string]$RoleName = "rc-prod-instance-role",
    [string]$InstanceProfileName = "rc-prod-instance-profile",
    [string]$SecretId = "rc/prod/env",
    [string]$SecretFile = ".secrets/rc-prod-env.json",
    [int]$RetentionDays = 30,
    [string]$SshHost = "rc@ec2-98-91-16-141.compute-1.amazonaws.com",
    # Root work goes through the ubuntu cloud-init user (passwordless
    # sudo, same keypair). The rc user has NO password and no general
    # sudo — only a scoped NOPASSWD rule for systemctl on rc.service.
    [string]$SudoSshHost = "ubuntu@ec2-98-91-16-141.compute-1.amazonaws.com",
    [string]$SshKey = "$HOME\.ssh\rc-prod.pem",
    [switch]$SkipAws,
    [switch]$SkipSecret,
    [switch]$SkipHost
)

$ErrorActionPreference = "Stop"

function Invoke-Aws {
    param([string[]]$AwsArgs)
    $out = aws --profile $AwsProfile --region $Region @AwsArgs 2>&1
    return @{ ExitCode = $LASTEXITCODE; Output = ($out | Out-String) }
}

function Step { param([string]$Msg) Write-Host "==> $Msg" -ForegroundColor Cyan }
function Note { param([string]$Msg) Write-Host "    $Msg" }

$tmpDir = Join-Path $env:TEMP "rc-provision-dr"
New-Item -ItemType Directory -Force $tmpDir | Out-Null

# ---------------------------------------------------------------- AWS --
if (-not $SkipAws) {
    Step "S3 bucket $Bucket"
    $r = Invoke-Aws @("s3api", "head-bucket", "--bucket", $Bucket)
    if ($r.ExitCode -ne 0) {
        # us-east-1 rejects an explicit LocationConstraint.
        if ($Region -eq "us-east-1") {
            $r = Invoke-Aws @("s3api", "create-bucket", "--bucket", $Bucket)
        } else {
            $r = Invoke-Aws @("s3api", "create-bucket", "--bucket", $Bucket,
                "--create-bucket-configuration", "LocationConstraint=$Region")
        }
        if ($r.ExitCode -ne 0) { throw "create-bucket failed: $($r.Output)" }
        Note "created"
    } else {
        Note "already exists"
    }

    $r = Invoke-Aws @("s3api", "put-public-access-block", "--bucket", $Bucket,
        "--public-access-block-configuration",
        "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true")
    if ($r.ExitCode -ne 0) { throw "put-public-access-block failed: $($r.Output)" }

    $encFile = Join-Path $tmpDir "enc.json"
    @'
{"Rules": [{"ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "AES256"}}]}
'@ | Set-Content -Encoding Ascii $encFile
    $r = Invoke-Aws @("s3api", "put-bucket-encryption", "--bucket", $Bucket,
        "--server-side-encryption-configuration", "file://$encFile")
    if ($r.ExitCode -ne 0) { throw "put-bucket-encryption failed: $($r.Output)" }

    $lifecycleFile = Join-Path $tmpDir "lifecycle.json"
    @"
{
  "Rules": [
    {
      "ID": "expire-old-backups",
      "Status": "Enabled",
      "Filter": {},
      "Expiration": {"Days": $RetentionDays},
      "AbortIncompleteMultipartUpload": {"DaysAfterInitiation": 7}
    }
  ]
}
"@ | Set-Content -Encoding Ascii $lifecycleFile
    $r = Invoke-Aws @("s3api", "put-bucket-lifecycle-configuration", "--bucket", $Bucket,
        "--lifecycle-configuration", "file://$lifecycleFile")
    if ($r.ExitCode -ne 0) { throw "put-bucket-lifecycle-configuration failed: $($r.Output)" }
    Note "public access blocked, SSE enabled, $RetentionDays-day expiry set"

    Step "IAM role $RoleName + instance profile"
    $accountId = (aws --profile $AwsProfile sts get-caller-identity --query Account --output text)
    $secretArn = "arn:aws:secretsmanager:${Region}:${accountId}:secret:${SecretId}*"

    $trustFile = Join-Path $tmpDir "trust.json"
    @'
{
  "Version": "2012-10-17",
  "Statement": [{"Effect": "Allow", "Principal": {"Service": "ec2.amazonaws.com"}, "Action": "sts:AssumeRole"}]
}
'@ | Set-Content -Encoding Ascii $trustFile

    $r = Invoke-Aws @("iam", "get-role", "--role-name", $RoleName)
    if ($r.ExitCode -ne 0) {
        $r = Invoke-Aws @("iam", "create-role", "--role-name", $RoleName,
            "--assume-role-policy-document", "file://$trustFile",
            "--description", "Prod instance role: backup bucket write + env secret read")
        if ($r.ExitCode -ne 0) { throw "create-role failed: $($r.Output)" }
        Note "role created"
    } else {
        Note "role already exists"
    }

    $policyFile = Join-Path $tmpDir "policy.json"
    @"
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "BackupBucketWrite",
      "Effect": "Allow",
      "Action": ["s3:PutObject", "s3:GetObject"],
      "Resource": "arn:aws:s3:::$Bucket/*"
    },
    {
      "Sid": "BackupBucketList",
      "Effect": "Allow",
      "Action": ["s3:ListBucket"],
      "Resource": "arn:aws:s3:::$Bucket"
    },
    {
      "Sid": "EnvSecretRead",
      "Effect": "Allow",
      "Action": ["secretsmanager:GetSecretValue"],
      "Resource": "$secretArn"
    }
  ]
}
"@ | Set-Content -Encoding Ascii $policyFile
    $r = Invoke-Aws @("iam", "put-role-policy", "--role-name", $RoleName,
        "--policy-name", "rc-prod-backup-and-secrets",
        "--policy-document", "file://$policyFile")
    if ($r.ExitCode -ne 0) { throw "put-role-policy failed: $($r.Output)" }
    Note "inline policy set (bucket write, secret read)"

    $r = Invoke-Aws @("iam", "get-instance-profile", "--instance-profile-name", $InstanceProfileName)
    if ($r.ExitCode -ne 0) {
        $r = Invoke-Aws @("iam", "create-instance-profile", "--instance-profile-name", $InstanceProfileName)
        if ($r.ExitCode -ne 0) { throw "create-instance-profile failed: $($r.Output)" }
    }
    $r = Invoke-Aws @("iam", "add-role-to-instance-profile",
        "--instance-profile-name", $InstanceProfileName, "--role-name", $RoleName)
    if ($r.ExitCode -ne 0 -and $r.Output -notmatch "LimitExceeded|EntityAlreadyExists|Cannot exceed quota") {
        throw "add-role-to-instance-profile failed: $($r.Output)"
    }

    Step "Attach instance profile to $InstanceId"
    $r = Invoke-Aws @("ec2", "describe-iam-instance-profile-associations",
        "--filters", "Name=instance-id,Values=$InstanceId",
        "--query", "IamInstanceProfileAssociations[?State=='associated']", "--output", "text")
    if ($r.Output.Trim()) {
        Note "instance already has a profile associated - leaving as-is"
        Note ($r.Output.Trim())
    } else {
        # IAM propagation to EC2 can lag a freshly created profile.
        $attached = $false
        for ($i = 0; $i -lt 6 -and -not $attached; $i++) {
            $r = Invoke-Aws @("ec2", "associate-iam-instance-profile",
                "--instance-id", $InstanceId,
                "--iam-instance-profile", "Name=$InstanceProfileName")
            if ($r.ExitCode -eq 0) { $attached = $true }
            elseif ($r.Output -match "Invalid IAM Instance Profile") { Start-Sleep -Seconds 10 }
            else { throw "associate-iam-instance-profile failed: $($r.Output)" }
        }
        if (-not $attached) { throw "instance profile association did not propagate in time" }
        Note "attached"
    }
}

# ------------------------------------------------------------- Secret --
if (-not $SkipSecret) {
    Step "Secrets Manager $SecretId"
    if (-not (Test-Path $SecretFile)) {
        throw "secret file $SecretFile not found - run from the repo root of the checkout that has .secrets/"
    }
    # Validate it parses as JSON before shipping it anywhere.
    Get-Content -Raw $SecretFile | ConvertFrom-Json | Out-Null

    $r = Invoke-Aws @("secretsmanager", "describe-secret", "--secret-id", $SecretId)
    if ($r.ExitCode -ne 0) {
        $r = Invoke-Aws @("secretsmanager", "create-secret", "--name", $SecretId,
            "--description", "Rising Constellation prod env vars (rc-fetch-secrets contract)",
            "--secret-string", "file://$SecretFile")
        if ($r.ExitCode -ne 0) { throw "create-secret failed: $($r.Output)" }
        Note "created"
    } else {
        $r = Invoke-Aws @("secretsmanager", "put-secret-value", "--secret-id", $SecretId,
            "--secret-string", "file://$SecretFile")
        if ($r.ExitCode -ne 0) { throw "put-secret-value failed: $($r.Output)" }
        Note "updated existing secret with current $SecretFile"
    }
}

# --------------------------------------------------------------- Host --
if (-not $SkipHost) {
    Step "Install backup timer on $SshHost"
    $staging = "/home/rc/rc-backup-staging"
    ssh -i $SshKey $SshHost "mkdir -p $staging"
    if ($LASTEXITCODE -ne 0) { throw "ssh mkdir failed" }
    # Resolve payload files relative to this script (deploy/), not the
    # CWD — the script may be invoked from any checkout or directory.
    scp -i $SshKey `
        "$PSScriptRoot\bin\rc-db-backup" `
        "$PSScriptRoot\bin\rc-db-backup-install" `
        "$PSScriptRoot\systemd\rc-db-backup.service" `
        "$PSScriptRoot\systemd\rc-db-backup.timer" `
        "${SshHost}:$staging/"
    if ($LASTEXITCODE -ne 0) { throw "scp failed" }

    Note "running installer as root via $SudoSshHost..."
    ssh -i $SshKey $SudoSshHost "sudo -n bash $staging/rc-db-backup-install $Bucket $staging"
    if ($LASTEXITCODE -ne 0) { throw "remote install failed" }

    Step "Trigger first backup and show result"
    ssh -i $SshKey $SudoSshHost "sudo -n systemctl start rc-db-backup.service; sudo -n journalctl -u rc-db-backup.service -n 20 --no-pager; sudo -n rm -rf $staging"
    if ($LASTEXITCODE -ne 0) { throw "first backup run failed - check journalctl -u rc-db-backup on the host" }
}

Write-Host ""
Write-Host "provision-dr complete." -ForegroundColor Green
Write-Host "Verify any time with:"
Write-Host "  aws --profile $AwsProfile s3 ls s3://$Bucket/db/ --region $Region"

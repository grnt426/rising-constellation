# Provision the S3 bucket for the release build's dependency cache.
#
# deploy/bin/remote-build.sh keeps the compiled Elixir dependencies of the
# last build as a ~37MB tarball so the next build does not compile them
# again (see "Dependency cache" in deploy/aws-setup.md). This bucket is
# where that tarball lives, shared by every machine that deploys. It is
# its own bucket on purpose: nothing else is stored in it, nothing serves
# from it, and no other bucket's access rules apply to it.
#
# The deploy scripts work without it (they fall back to a copy of the cache
# on the operator's machine) and start using the bucket as soon as it
# exists.
#
# Two ways to run it:
#
#   * As the deploy user, once deploy/iam/claude-access-build-cache.json is
#     attached to it (IAM console > Users > claude-access > Add permissions
#     > Create inline policy > JSON). That policy covers exactly this
#     bucket: creating and configuring it, and reading/writing its objects.
#
#       .\deploy\provision-build-cache.ps1 -AwsProfile rc-prod
#
#   * With an admin profile, which can also attach the deploy user's
#     day-to-day access (list, read, write; no bucket configuration):
#
#       .\deploy\provision-build-cache.ps1 -AwsProfile my-admin -AttachUserPolicy
#
# What it creates:
#   1. The bucket: private (all public access blocked), SSE-S3 encrypted.
#   2. A lifecycle rule expiring objects after -RetentionDays (default 30).
#      A cache is only ever a convenience: an expired one is rebuilt by the
#      next deploy, which then takes about two minutes longer, once.
#   3. With -AttachUserPolicy: an inline policy on the deploy user allowing
#      ListBucket on the bucket and GetObject/PutObject on its objects.
#
# Idempotent: re-running re-applies the same settings.
#
# Cost: about $0.001 per month per tarball; transfers stay in-region.

param(
    [Parameter(Mandatory = $true)] [string]$AwsProfile,
    [string]$Region = "us-east-1",
    [string]$Bucket = "rc-build-cache-553872001542",
    [string]$DeployUser = "claude-access",
    [string]$PolicyName = "rc-build-cache",
    [int]$RetentionDays = 30,
    [switch]$AttachUserPolicy
)

$ErrorActionPreference = "Stop"

function Invoke-Aws {
    param([string[]]$AwsArgs)
    $out = aws --profile $AwsProfile --region $Region @AwsArgs 2>&1
    return @{ ExitCode = $LASTEXITCODE; Output = ($out | Out-String) }
}

function Step { param([string]$Msg) Write-Host "==> $Msg" -ForegroundColor Cyan }
function Note { param([string]$Msg) Write-Host "    $Msg" }

$tmpDir = Join-Path $env:TEMP "rc-provision-build-cache"
New-Item -ItemType Directory -Force $tmpDir | Out-Null

# ------------------------------------------------------------- bucket --
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
Note "all public access blocked"

$encFile = Join-Path $tmpDir "encryption.json"
@'
{"Rules": [{"ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "AES256"}}]}
'@ | Set-Content -Encoding Ascii $encFile
$r = Invoke-Aws @("s3api", "put-bucket-encryption", "--bucket", $Bucket,
    "--server-side-encryption-configuration", "file://$encFile")
if ($r.ExitCode -ne 0) { throw "put-bucket-encryption failed: $($r.Output)" }
Note "default encryption: SSE-S3 (AES256)"

$lifecycleFile = Join-Path $tmpDir "lifecycle.json"
@"
{
  "Rules": [
    {
      "ID": "expire-old-build-caches",
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
Note "objects expire after $RetentionDays days"

# -------------------------------------------------------- deploy user --
if (-not $AttachUserPolicy) {
    Step "deploy user policy: not touched (pass -AttachUserPolicy with an admin profile)"
} else {
    Step "inline policy '$PolicyName' on IAM user $DeployUser"
    $policyFile = Join-Path $tmpDir "user-policy.json"
    @"
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "BuildCacheList",
      "Effect": "Allow",
      "Action": ["s3:ListBucket"],
      "Resource": "arn:aws:s3:::$Bucket"
    },
    {
      "Sid": "BuildCacheReadWrite",
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject"],
      "Resource": "arn:aws:s3:::$Bucket/*"
    }
  ]
}
"@ | Set-Content -Encoding Ascii $policyFile
    $r = Invoke-Aws @("iam", "put-user-policy", "--user-name", $DeployUser,
        "--policy-name", $PolicyName, "--policy-document", "file://$policyFile")
    if ($r.ExitCode -ne 0) { throw "put-user-policy failed: $($r.Output)" }
    Note "ListBucket on the bucket, GetObject + PutObject on its objects"
}

Remove-Item -Recurse -Force $tmpDir

Write-Host ""
Write-Host "Done. The next remote build stores its dependency cache in" -ForegroundColor Green
Write-Host "  s3://$Bucket" -ForegroundColor Green
Write-Host "(remote-build.sh prints 'dependency cache stored in ...')."
if ($Bucket -ne "rc-build-cache-553872001542") {
    Write-Host "Non-default bucket: set RC_BUILD_CACHE_S3=s3://$Bucket for the deploy scripts."
}

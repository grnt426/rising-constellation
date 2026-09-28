<#
.SYNOPSIS
  Ensure the CloudFront distribution caches every static path at the edge.

.DESCRIPTION
  The distribution's default behavior uses Managed-CachingDisabled (the
  landing page, LiveView pages and anything unlisted go to the us-east-1
  origin on every request). Static trees need their own behavior with
  Managed-CachingOptimized or they miss the edge forever -- /fonts/* and
  /fontawesome/* did until 2026-09-23, although nginx marks those files
  immutable for a year.

  For each path in -Paths that has no behavior yet, this clones the settings
  of the existing /js/* behavior (CachingOptimized, AllViewer origin request
  policy, compression, redirect-to-https) under the new PathPattern and
  appends it. Existing behaviors are never modified. Idempotent: a second
  run finds nothing to add and exits without calling update-distribution.

.PARAMETER Paths
  Path patterns that must be edge-cached. Defaults to the Phoenix static
  trees that were missing.

.PARAMETER DryRun
  Print what would be added; change nothing.

.EXAMPLE
  ./deploy/bin/cf-cache-behaviors.ps1 -DryRun
  ./deploy/bin/cf-cache-behaviors.ps1
#>
param(
  [string[]]$Paths = @('/fonts/*', '/fontawesome/*'),
  [string]$AwsProfile = 'rc-prod',
  [string]$DistributionId = '',
  [string]$TemplatePath = '/js/*',
  [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path

if (-not $DistributionId) {
  $idFile = Join-Path $repo '.secrets\cf_distribution_id.txt'
  if (-not (Test-Path $idFile)) {
    # Worktrees don't carry .secrets; fall back to the main checkout's copy.
    $common = (& git -C $repo rev-parse --path-format=absolute --git-common-dir).Trim()
    $idFile = Join-Path (Split-Path $common -Parent) '.secrets\cf_distribution_id.txt'
  }
  if (-not (Test-Path $idFile)) { throw "no -DistributionId and no .secrets\cf_distribution_id.txt" }
  $DistributionId = (Get-Content $idFile -Raw).Trim()
}

$raw = & aws --profile $AwsProfile cloudfront get-distribution-config --id $DistributionId --output json
if ($LASTEXITCODE -ne 0) { throw "get-distribution-config failed" }
$resp = ($raw -join "`n") | ConvertFrom-Json
$etag = $resp.ETag
$config = $resp.DistributionConfig

$behaviors = @($config.CacheBehaviors.Items)
$template = $behaviors | Where-Object { $_.PathPattern -eq $TemplatePath } | Select-Object -First 1
if (-not $template) { throw "template behavior $TemplatePath not found" }

$existing = $behaviors | ForEach-Object { $_.PathPattern }
$missing = @($Paths | Where-Object { $existing -notcontains $_ })

Write-Host "[cf] distribution $DistributionId (ETag $etag): $($behaviors.Count) behaviors"
if ($missing.Count -eq 0) {
  Write-Host "[cf] all of $($Paths -join ', ') already have behaviors -- nothing to do"
  exit 0
}

foreach ($path in $missing) {
  $clone = ($template | ConvertTo-Json -Depth 100) | ConvertFrom-Json
  $clone.PathPattern = $path
  $behaviors += $clone
  Write-Host "[cf] + $path  (cache policy $($clone.CachePolicyId), cloned from $TemplatePath)"
}

if ($DryRun) {
  Write-Host "[cf] dry run -- not updating"
  exit 0
}

$config.CacheBehaviors.Items = $behaviors
$config.CacheBehaviors.Quantity = $behaviors.Count

$tmp = Join-Path ([IO.Path]::GetTempPath()) "cf-config-$DistributionId.json"
# Write without a BOM: the AWS CLI rejects a BOM-prefixed file:// payload.
[IO.File]::WriteAllText($tmp, (ConvertTo-Json -InputObject $config -Depth 100), (New-Object Text.UTF8Encoding $false))
try {
  $out = & aws --profile $AwsProfile cloudfront update-distribution --id $DistributionId `
    --if-match $etag --distribution-config "file://$tmp" `
    --query 'Distribution.[Status,DistributionConfig.CacheBehaviors.Quantity]' --output text
  if ($LASTEXITCODE -ne 0) { throw "update-distribution failed" }
  Write-Host "[cf] updated: $out (propagates to all edges in a few minutes)"
} finally {
  Remove-Item $tmp -ErrorAction SilentlyContinue
}

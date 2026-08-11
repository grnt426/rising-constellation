# Run the browser E2E suite against this worktree's Docker dev stack.
#
#   bin/e2e.ps1              # headless run
#   bin/e2e.ps1 -Headed      # watch the browser
#   bin/e2e.ps1 -Grep construction   # filter by test title
#
# Prereqs (one-time): cd e2e; npm install; node node_modules/@playwright/test/cli.js install chromium
# The stack must be up (docker compose up -d) with the CURRENT server code:
# the dev container has no code reloader, so restart `rc` after Elixir edits.

param(
    [switch]$Headed,
    [string]$Grep
)

$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$e2e = Join-Path $repo "e2e"

if (-not (Test-Path (Join-Path $repo ".dev-ports.json"))) {
    Write-Error "No .dev-ports.json - run bin/rc-worktree-setup.ps1 and docker compose up -d first."
}
if (-not (Test-Path (Join-Path $e2e "node_modules"))) {
    Write-Error "e2e/node_modules missing - run: cd e2e; npm install; node node_modules/@playwright/test/cli.js install chromium"
}

$ports = (Get-Content (Join-Path $repo ".dev-ports.json") | ConvertFrom-Json).ports
try {
    $null = Invoke-WebRequest -Uri "http://localhost:$($ports.phoenix)/" -UseBasicParsing -TimeoutSec 5
} catch {
    Write-Error "Phoenix not answering on port $($ports.phoenix) - is the stack up?"
}

$cliArgs = @("node_modules/@playwright/test/cli.js", "test")
if ($Headed) { $cliArgs += "--headed" }
if ($Grep) { $cliArgs += @("--grep", $Grep) }

Push-Location $e2e
try {
    node @cliArgs
    exit $LASTEXITCODE
} finally {
    Pop-Location
}

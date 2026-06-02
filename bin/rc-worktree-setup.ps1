# rc-worktree-setup.ps1 — allocate isolated host ports for this worktree so
# multiple worktrees can run their Docker dev stacks in parallel without
# colliding. Windows-native sibling of bin/rc-worktree-setup.
#
# Run from anywhere inside a worktree. Writes .env and .dev-ports.json at the
# worktree root (both gitignored). Re-running is idempotent: the registry at
# %LOCALAPPDATA%\rc\worktree-ports.tsv maps absolute worktree path → slot, so
# the same worktree gets the same ports across recreations.

[CmdletBinding()]
param(
    [switch]$Gc,
    [Alias('h')][switch]$Help
)

$ErrorActionPreference = 'Stop'

if ($Help) {
    @"
Usage: rc-worktree-setup.ps1 [-Gc]

  (no args)   Allocate or reuse a port slot for the current worktree.
              Writes .env and .dev-ports.json at the worktree root.
  -Gc         Prune registry entries whose worktree paths no longer exist
              on disk. Prints what was removed.
"@
    exit 0
}

if ($env:LOCALAPPDATA) {
    $regDir = Join-Path $env:LOCALAPPDATA 'rc'
} else {
    $regDir = Join-Path $HOME '.config\rc'
}
$regFile = Join-Path $regDir 'worktree-ports.tsv'
New-Item -ItemType Directory -Force -Path $regDir | Out-Null
if (-not (Test-Path $regFile)) {
    New-Item -ItemType File -Path $regFile | Out-Null
}

if ($Gc) {
    $kept = 0
    $removed = 0
    $surviving = @()
    Get-Content $regFile | ForEach-Object {
        if ($_ -match '^\s*$') { return }
        $parts = $_ -split "`t"
        if ($parts.Count -lt 2) { return }
        $path = $parts[0]
        $slot = $parts[1]
        if (Test-Path -LiteralPath $path -PathType Container) {
            $surviving += $_
            $kept++
        } else {
            Write-Host "  pruned slot ${slot}: $path"
            $removed++
        }
    }
    [System.IO.File]::WriteAllLines($regFile, $surviving, [System.Text.UTF8Encoding]::new($false))
    Write-Host "Garbage-collected $removed stale entries, kept $kept."
    exit 0
}

$worktreeRaw = (& git rev-parse --show-toplevel 2>$null)
if ($LASTEXITCODE -ne 0 -or -not $worktreeRaw) {
    Write-Error "Not inside a git repository."
    exit 1
}
# git prints forward slashes on Windows — normalize for consistency in the
# registry key and in JSON output.
$worktree = ($worktreeRaw.Trim()) -replace '/', '\'

$lockPath = "$regFile.lock"
$lockStream = $null
$tries = 0
while ($true) {
    try {
        $lockStream = [System.IO.File]::Open($lockPath, 'OpenOrCreate', 'Write', 'None')
        break
    } catch {
        $tries++
        if ($tries -gt 50) { throw "Could not acquire lock at $lockPath" }
        Start-Sleep -Milliseconds 100
    }
}

try {
    $sha = [System.Security.Cryptography.SHA1]::Create()
    $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($worktree))
    $hashInt = ([uint32]$bytes[0] -shl 24) -bor ([uint32]$bytes[1] -shl 16) -bor ([uint32]$bytes[2] -shl 8) -bor ([uint32]$bytes[3])
    $slotPref = [int]($hashInt % 100)

    $registry = @{}
    Get-Content $regFile | ForEach-Object {
        if ($_ -match '^\s*$') { return }
        $parts = $_ -split "`t"
        if ($parts.Count -ge 2) {
            $registry[$parts[0]] = [int]$parts[1]
        }
    }

    $slot = $null
    $reused = $false
    if ($registry.ContainsKey($worktree)) {
        $slot = $registry[$worktree]
        $reused = $true
    } else {
        $claimed = @{}
        foreach ($k in $registry.Keys) {
            if ($k -ne $worktree) { $claimed[$registry[$k]] = $true }
        }

        function Test-PortInUse([int]$port) {
            $listener = $null
            try {
                $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $port)
                $listener.Start()
                return $false
            } catch {
                return $true
            } finally {
                if ($listener) { $listener.Stop() }
            }
        }

        for ($offset = 0; $offset -lt 100; $offset++) {
            $cand = ($slotPref + $offset) % 100
            if ($claimed.ContainsKey($cand)) { continue }
            $http = 4000 + $cand * 10
            $front = 8080 + $cand * 10
            if ((Test-PortInUse $http) -or (Test-PortInUse $front)) { continue }
            $slot = $cand
            break
        }

        if ($null -eq $slot) {
            throw "No free slot among 100 candidates (4000-4990 range)."
        }

        $ts = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        Add-Content -Path $regFile -Value ("{0}`t{1}`t{2}" -f $worktree, $slot, $ts)
    }
} finally {
    if ($lockStream) {
        $lockStream.Close()
        $lockStream.Dispose()
    }
    if (Test-Path $lockPath) {
        try { Remove-Item $lockPath -Force -ErrorAction SilentlyContinue } catch {}
    }
}

$httpPort = 4000 + $slot * 10
$frontPort = 8080 + $slot * 10

$base = Split-Path -Leaf $worktree
$slug = ($base.ToLower() -replace '[^a-z0-9-]+', '-').Trim('-')
if (-not $slug) { $slug = 'worktree' }
$projectName = "rc-$slug"

$envContent = @"
# Auto-generated by bin/rc-worktree-setup.ps1. Re-run the script to refresh.
# Gitignored - per-machine port assignments for parallel worktrees.
COMPOSE_PROJECT_NAME=$projectName
RC_HTTP_PORT=$httpPort
RC_FRONT_PORT=$frontPort
"@
$envPath = Join-Path $worktree '.env'
[System.IO.File]::WriteAllText($envPath, $envContent, [System.Text.UTF8Encoding]::new($false))

$worktreeJson = $worktree.Replace('\', '\\')
$portsContent = @"
{
  "_readme": "Auto-generated. AI agents: when this stack is running, hit the ports below - NOT the defaults 4000/8080.",
  "worktree": "$worktreeJson",
  "project": "$projectName",
  "slot": $slot,
  "ports": {
    "phoenix": $httpPort,
    "vue_spa": $frontPort
  }
}
"@
$portsPath = Join-Path $worktree '.dev-ports.json'
[System.IO.File]::WriteAllText($portsPath, $portsContent, [System.Text.UTF8Encoding]::new($false))

Write-Host ""
if ($reused) {
    Write-Host "Reused existing slot $slot for this worktree."
} else {
    Write-Host "Allocated slot $slot for this worktree (preferred: $slotPref)."
}
Write-Host "  Phoenix:    http://localhost:$httpPort"
Write-Host "  Vue SPA:    http://localhost:$frontPort"
Write-Host "  Project:    $projectName"
Write-Host ""
Write-Host "Bring the stack up with: docker compose up"

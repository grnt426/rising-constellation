# End-to-end faction-government demo against the local docker dev stack.
#
# Seeds a fresh 2-faction fast instance with fake players (3x Tetrarchy,
# 1x Myrmezir), starts it, fast-forwards the founding period, runs both
# factions' leader elections, then walks the diplomacy loop: the pair
# starts AT WAR (2-faction rule), the elected leaders negotiate peace,
# and Tetrarchy declares war again. Every step asserts; exits non-zero
# on the first failure. Wall time: under a minute (all game-time windows
# are skipped via the dev harness clock).
#
#   pwsh bin/gov-e2e.ps1
#   pwsh bin/gov-e2e.ps1 -AdminEmail admin@abc -AdminPassword admindev
#
# Requires: the worktree's docker stack running (bin/rc-worktree-setup,
# docker compose up), dev environment (all gov-debug endpoints are
# dev-only and 404 in prod).

param(
  [string]$AdminEmail = "admin@abc",
  [string]$AdminPassword = "admindev",
  [string]$HarnessSecret = "dev-harness-secret",
  [int]$Phoenix = 0,
  # fast = the test fixture; slow = a LEGACY game (real constants, the
  # clock-skips below scale to match)
  [ValidateSet("fast", "slow")]
  [string]$Speed = "fast",
  # late lets more players join AFTER the game starts
  [ValidateSet("pre", "late")]
  [string]$Registration = "pre"
)

$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot

if ($Phoenix -eq 0) {
  $ports = Get-Content (Join-Path $repo ".dev-ports.json") | ConvertFrom-Json
  $Phoenix = $ports.ports.phoenix
}
$base = "http://localhost:$Phoenix"
$hdr = @{ "X-Harness-Secret" = $HarnessSecret }

# Government clock windows per speed (constant-fast.ex / constant-slow.ex),
# plus a small margin: how far the harness advances to skip each phase.
$foundingUt = if ($Speed -eq "slow") { 1450 } else { 45 }
$electionUt = if ($Speed -eq "slow") { 970 } else { 45 }

$script:failures = 0
function Step([string]$name, [bool]$ok, [string]$detail = "") {
  $tag = if ($ok) { "PASS" } else { "FAIL"; $script:failures++ }
  Write-Host ("[{0}] {1}{2}" -f $tag, $name, $(if ($detail) { " -- $detail" } else { "" }))
  if (-not $ok) { Write-Host "aborting."; exit 1 }
}

function Harness([string]$method, [string]$path, $body = $null) {
  $params = @{ Method = $method; Uri = "$base$path"; Headers = $hdr }
  if ($null -ne $body) {
    $params.ContentType = "application/json"
    $params.Body = ($body | ConvertTo-Json -Depth 6)
  }
  Invoke-RestMethod @params
}

# NOTE: the payload parameter must NOT be called $args — that's a
# PowerShell automatic variable and silently binds to leftovers.
function GovOp([int]$iid, [int]$fid, [int]$actor, [string]$op, $opArgs) {
  Harness "Post" "/api/harness/gov-debug/op" @{ iid = $iid; fid = $fid; actor = $actor; op = $op; args = $opArgs }
}

# ---- 1. seed a fresh instance with fake players --------------------------
Write-Host "seeding $Speed/$Registration instance (mix run in container)..."
Push-Location $repo
try {
  $seed = docker compose exec -T -u rc rc mix run bin/gov-demo-seed.exs $Speed $Registration 2>&1 | Out-String
} finally {
  Pop-Location
}
if ($seed -notmatch "instance_id=(\d+)") { Step "seed instance" $false $seed.Substring(0, [Math]::Min(400, $seed.Length)) }
$iid = [int]$Matches[1]

$players = @{}
foreach ($m in [regex]::Matches($seed, "player=(\S+) profile_id=(\d+) faction=(\S+) faction_id=(\d+)")) {
  $players[$m.Groups[1].Value] = @{
    profile = [int]$m.Groups[2].Value
    faction = $m.Groups[3].Value
    faction_id = [int]$m.Groups[4].Value
  }
}
Step "seed instance" ($players.Count -eq 4) "instance=$iid players=$($players.Count)"
$tet = $players["User1"].faction_id
$myr = $players["User4"].faction_id

# ---- 2. start it as admin -------------------------------------------------
$login = Invoke-RestMethod -Method Post -Uri "$base/api/auth/identity/callback" -ContentType "application/json" `
  -Body (@{ account = @{ email = $AdminEmail; password = $AdminPassword } } | ConvertTo-Json)
$auth = @{ Authorization = "Bearer $($login.access_token)" }
Invoke-RestMethod -Method Put -Uri "$base/api/instances/$iid/start" -Headers $auth | Out-Null

# wait for the live tree (government status answers once faction agents run)
$up = $false
foreach ($i in 1..30) {
  try {
    Harness "Get" "/api/harness/gov-debug/status?iid=$iid&fid=$tet" | Out-Null
    $up = $true; break
  } catch { Start-Sleep -Seconds 2 }
}
Step "instance started" $up "iid=$iid tetrarchy=$tet myrmezir=$myr"

# ---- 3. skip founding, open the elections ---------------------------------
foreach ($fid in @($tet, $myr)) { Harness "Post" "/api/harness/gov-debug/advance" @{ iid = $iid; fid = $fid; ut = $foundingUt } | Out-Null }
$tetStatus = Harness "Get" "/api/harness/gov-debug/status?iid=$iid&fid=$tet"
$myrStatus = Harness "Get" "/api/harness/gov-debug/status?iid=$iid&fid=$myr"
Step "founding over, ballots open" (($tetStatus.phase -eq "running") -and ($tetStatus.ballots.Count -ge 1) -and ($myrStatus.ballots.Count -ge 1)) `
  "tetrarchy ballots=$($tetStatus.ballots.Count) myrmezir ballots=$($myrStatus.ballots.Count)"

# ---- 4. elections ----------------------------------------------------------
# Tetrarchy: weighted plurality, candidates pre-seeded from the (active)
# scoreboard - User2 votes User1 onto the throne.
$tetLeaderBallot = ($tetStatus.ballots | Where-Object { $_.seat -eq "leader" })[0].id
GovOp $iid $tet $players["User2"].profile "vote" @{ ballot_id = $tetLeaderBallot; candidate_id = $players["User1"].profile } | Out-Null

# Myrmezir: one member (small-faction relaxation) - User4 self-nominates
# and votes themselves in.
$myrLeaderBallot = ($myrStatus.ballots | Where-Object { $_.seat -eq "leader" })[0].id
GovOp $iid $myr $players["User4"].profile "nominate" @{ ballot_id = $myrLeaderBallot; candidate_id = $players["User4"].profile } | Out-Null
GovOp $iid $myr $players["User4"].profile "vote" @{ ballot_id = $myrLeaderBallot; candidate_id = $players["User4"].profile } | Out-Null

# close the windows
foreach ($fid in @($tet, $myr)) { Harness "Post" "/api/harness/gov-debug/advance" @{ iid = $iid; fid = $fid; ut = $electionUt } | Out-Null }
$tetStatus = Harness "Get" "/api/harness/gov-debug/status?iid=$iid&fid=$tet"
$myrStatus = Harness "Get" "/api/harness/gov-debug/status?iid=$iid&fid=$myr"
Step "tetrarchy elected a Tetrarch" ($tetStatus.seats.leader.player_id -eq $players["User1"].profile) "leader=$($tetStatus.seats.leader.name)"
Step "myrmezir elected a President" ($myrStatus.seats.leader.player_id -eq $players["User4"].profile) "leader=$($myrStatus.seats.leader.name)"

# ---- 5. treasury flows: appoint, donate, cap, withdraw, grant ---------------
# The Tetrarch appoints User2 Head of Economy (direct appointment).
GovOp $iid $tet $players["User1"].profile "appoint" @{ seat = "economy"; appointee_id = $players["User2"].profile } | Out-Null
$tetStatus = Harness "Get" "/api/harness/gov-debug/status?iid=$iid&fid=$tet"
Step "economy head appointed" ($tetStatus.seats.economy.player_id -eq $players["User2"].profile) "economy=$($tetStatus.seats.economy.name)"

# User3 donates from their own pocket (uncapped, escrowed)
GovOp $iid $tet $players["User3"].profile "donate" @{ credit = 500 } | Out-Null
$tetStatus = Harness "Get" "/api/harness/gov-debug/status?iid=$iid&fid=$tet"
Step "member donation banked" ($tetStatus.treasury.credit -ge 500) "treasury credit=$($tetStatus.treasury.credit)"

# withdrawals are off until the Head of Economy opens them
$closed = $null
try { $closed = GovOp $iid $tet $players["User3"].profile "withdraw" @{ credit = 50 } } catch { $closed = $null }
Step "withdrawals disabled by default" ($null -eq $closed)

GovOp $iid $tet $players["User2"].profile "set_withdraw_cap" @{ pct = 10 } | Out-Null
GovOp $iid $tet $players["User3"].profile "withdraw" @{ credit = 50 } | Out-Null
$tetStatus = Harness "Get" "/api/harness/gov-debug/status?iid=$iid&fid=$tet"
Step "capped withdrawal (taxed)" (($tetStatus.withdraw_cap_pct -eq 10) -and ($tetStatus.treasury.credit -eq 450)) `
  "cap=$($tetStatus.withdraw_cap_pct)% treasury credit=$($tetStatus.treasury.credit)"

# the minister issues freely past the cap
GovOp $iid $tet $players["User2"].profile "grant" @{ player_id = $players["User3"].profile; credit = 400 } | Out-Null
$tetStatus = Harness "Get" "/api/harness/gov-debug/status?iid=$iid&fid=$tet"
Step "ministerial grant past the cap" ($tetStatus.treasury.credit -eq 50) "treasury credit=$($tetStatus.treasury.credit)"

# ---- 6. diplomacy: war -> peace -> war -------------------------------------
$pair = "$([Math]::Min($tet,$myr)):$([Math]::Max($tet,$myr))"
$diplo = Harness "Get" "/api/harness/gov-debug/diplo-status?iid=$iid"
Step "two-faction game starts at war" ($diplo.relations.$pair -eq "war") "relations=$($diplo.relations | ConvertTo-Json -Compress)"
$meters = $diplo.wars.$pair.$([string]$tet)
Step "war meters initialized" (($meters.exhaustion -ge 0) -and ($meters.momentum -eq 50) -and ($meters.frenzy -eq 100)) `
  "exhaustion=$($meters.exhaustion) momentum=$($meters.momentum) frenzy=$($meters.frenzy)"

# the Tetrarch sues for peace; the President accepts
GovOp $iid $tet $players["User1"].profile "diplomacy" @{ action = "propose"; faction_id = $myr; kind = "peace" } | Out-Null
$diplo = Harness "Get" "/api/harness/gov-debug/diplo-status?iid=$iid"
$proposal = $diplo.proposals | Where-Object { $_.kind -eq "peace" } | Select-Object -First 1
Step "peace proposed" ($null -ne $proposal) "proposal_id=$($proposal.id)"

GovOp $iid $myr $players["User4"].profile "diplomacy" @{ action = "accept"; proposal_id = $proposal.id } | Out-Null
$diplo = Harness "Get" "/api/harness/gov-debug/diplo-status?iid=$iid"
Step "peace signed - cold war" ($null -eq $diplo.relations.$pair) "relations=$($diplo.relations | ConvertTo-Json -Compress)"

# ...and the Tetrarch's patience runs out: WAR, declared through the
# leader gate (a non-leader attempting this is refused)
$rogue = $null
try { $rogue = GovOp $iid $tet $players["User3"].profile "diplomacy" @{ action = "declare_war"; faction_id = $myr } } catch { $rogue = $null }
Step "non-leader cannot declare war" ($null -eq $rogue)

GovOp $iid $tet $players["User1"].profile "diplomacy" @{ action = "declare_war"; faction_id = $myr } | Out-Null
$diplo = Harness "Get" "/api/harness/gov-debug/diplo-status?iid=$iid"
$meters = $diplo.wars.$pair.$([string]$tet)
Step "tetrarchy declared war" ($diplo.relations.$pair -eq "war") "relations=$($diplo.relations | ConvertTo-Json -Compress)"
# exhaustion accrues per game-day from the moment of declaration, so a
# hair above zero is exactly right; momentum/frenzy start pegged.
Step "fresh war meters" (($meters.exhaustion -lt 1) -and ($meters.momentum -eq 50) -and ($meters.frenzy -eq 100)) `
  "exhaustion=$($meters.exhaustion) momentum=$($meters.momentum) frenzy=$($meters.frenzy)"

Write-Host ""
Write-Host "E2E complete: instance $iid - elections held, peace signed, war declared. ($($script:failures) failures)"
exit $script:failures

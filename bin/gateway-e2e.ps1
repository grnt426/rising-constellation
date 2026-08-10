# End-to-end gateway transit test against the local docker dev stack.
#
# Stages a two-player same-faction instance (dev/gateway-fixture), elects
# a myrmezir government, builds + links two gateways, then walks the full
# portal-transit contract with REAL character agents:
#
#   R1  happy transit: charge -> jump (untargetable) -> fatigue at B;
#       busy-lock on both ends; unlink/demolish refused while in use;
#       jump queue-clear refused; stance change OK during fatigue;
#       recall refused during fatigue; wind-down frees the pair on its
#       own clock.
#   R2  orders cleared mid-charge -> lock released immediately.
#   R3  charging agent assassinated -> agent gone, lock released.
#   R4  unlink (cost + teardown window) -> demolition allowed once free.
#
# Requires: worktree docker stack running, dev environment. Wall time
# ~60-90s (transit phases run on the real fast-dev clock; government
# windows are skipped via gov-debug/advance).
#
#   pwsh bin/gateway-e2e.ps1

param(
  [string]$HarnessSecret = "dev-harness-secret",
  [int]$Phoenix = 0
)

$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot

if ($Phoenix -eq 0) {
  $ports = Get-Content (Join-Path $repo ".dev-ports.json") | ConvertFrom-Json
  $Phoenix = $ports.ports.phoenix
}
$base = "http://localhost:$Phoenix"
$hdr = @{ "X-Harness-Secret" = $HarnessSecret }

$script:passCount = 0
function Pass($msg) { $script:passCount++; Write-Host "[PASS] $msg" }
function Fail($msg) { Write-Host "[FAIL] $msg"; exit 1 }

function PostJson($path, $body) {
  Invoke-RestMethod -Method Post -Uri "$base$path" -Headers $hdr -ContentType "application/json" `
    -Body ($body | ConvertTo-Json -Depth 8)
}

function GetJson($path) {
  Invoke-RestMethod -Uri "$base$path" -Headers $hdr
}

# Returns the response, or the error body string on 4xx/5xx.
function TryPostJson($path, $body) {
  try {
    PostJson $path $body
  } catch {
    if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { throw }
  }
}

function GovOp($actor, $op, $opArgs) {
  $reply = TryPostJson "/api/harness/gov-debug/op" @{ iid = $iid; fid = $fid; actor = $actor; op = $op; args = $opArgs }
  if ($reply -is [string]) { Fail "gov op $op failed: $reply" }
  $reply
}

function GovOpExpectError($actor, $op, $opArgs, $pattern, $label) {
  $reply = TryPostJson "/api/harness/gov-debug/op" @{ iid = $iid; fid = $fid; actor = $actor; op = $op; args = $opArgs }
  if ($reply -is [string] -and $reply -match $pattern) { Pass $label }
  else { Fail "$label -- expected '$pattern', got: $reply" }
}

function CharOp($playerId, $op, $extra) {
  $body = @{ iid = $iid; pid = $playerId; op = $op } + $extra
  $reply = TryPostJson "/api/harness/gov-debug/char-op" $body
  if ($reply -is [string]) { Fail "char op $op failed: $reply" }
  $reply
}

function CharOpExpectError($playerId, $op, $extra, $pattern, $label) {
  $body = @{ iid = $iid; pid = $playerId; op = $op } + $extra
  $reply = TryPostJson "/api/harness/gov-debug/char-op" $body
  if ($reply -is [string] -and $reply -match $pattern) { Pass $label }
  else { Fail "$label -- expected '$pattern', got: $reply" }
}

function CharStatus($cid) {
  try {
    GetJson "/api/harness/gov-debug/char-status?iid=$iid&cid=$cid"
  } catch {
    "GONE"
  }
}

function GovStatus() { GetJson "/api/harness/gov-debug/status?iid=$iid&fid=$fid" }
function GovAdvance($ut) { PostJson "/api/harness/gov-debug/advance" @{ iid = $iid; fid = $fid; ut = $ut } | Out-Null }

function WaitFor($label, $timeoutSec, [scriptblock]$check) {
  $deadline = (Get-Date).AddSeconds($timeoutSec)
  while ((Get-Date) -lt $deadline) {
    if (& $check) { return }
    Start-Sleep -Milliseconds 500
  }
  Fail "timeout waiting for: $label"
}

# ----------------------------------------------------------------------
Write-Host "staging gateway fixture..."
$fixture = PostJson "/api/harness/dev/gateway-fixture" @{}
$iid = $fixture.instance_id
$fid = $fixture.myrmezir_faction_id
$p2 = $fixture.p2.id
$sysA = $fixture.p2.system.id
$sysB = $fixture.p3.system.id
$admiral1 = ($fixture.characters | Where-Object { $_.type -eq "admiral" })[0].id
$admiral2 = ($fixture.characters | Where-Object { $_.type -eq "admiral" })[1].id
$speaker = ($fixture.characters | Where-Object { $_.type -eq "speaker" })[0].id
Pass "fixture staged -- instance=$iid A=$sysA B=$sysB agents=$admiral1,$admiral2,$speaker"

# ---- government: founding + relaxed 2-member election, p2 takes all seats
GovAdvance 100
$status = GovStatus
if ($status.phase -ne "running" -or $status.ballots.Count -lt 3) { Fail "founding did not open ballots ($($status.phase))" }

foreach ($ballot in $status.ballots) {
  GovOp $p2 "nominate" @{ ballot_id = $ballot.id; candidate_id = $p2 } | Out-Null
  GovOp $p2 "vote" @{ ballot_id = $ballot.id; candidate_id = $p2 } | Out-Null
}
GovAdvance 100
$status = GovStatus
if ($status.seats.military.player_id -ne $p2) { Fail "p2 did not take the military seat" }
Pass "government elected -- p2 holds all seats"

# ---- treasury + patents + two gateways
PostJson "/api/harness/gov-debug/deposit" @{ iid = $iid; fid = $fid; credit = 9000000; technology = 500000; ideology = 100000 } | Out-Null
foreach ($patent in @("research_compact", "orbital_engineering", "gateway_theory")) {
  GovOp $p2 "purchase_patent" @{ key = $patent } | Out-Null
}
foreach ($sys in @($sysA, $sysB)) {
  GovOp $p2 "order_station" @{ system_id = $sys; key = "gateway"; anchor = 0 } | Out-Null
  PostJson "/api/harness/gov-debug/station-complete" @{ iid = $iid; system_id = $sys } | Out-Null
}
$status = GovStatus
$built = @($status.station_buildings | Where-Object { $_.key -eq "gateway" -and $_.status -eq "built" })
if ($built.Count -ne 2) { Fail "expected 2 built gateways, got $($built.Count)" }
Pass "two gateways built (A and B)"

# ---- linking
GovOp $p2 "gateway_link" @{ system_a = $sysA; system_b = $sysB } | Out-Null
$status = GovStatus
if ($status.gateway_links[0].status -ne "linking") { Fail "link did not enter :linking" }
GovOpExpectError $p2 "gateway_unlink" @{ system_id = $sysA } "gateway_not_linked" "unlink refused while still forming"
GovAdvance 50
$status = GovStatus
if ($status.gateway_links[0].status -ne "linked") { Fail "link did not complete" }
Pass "gateways linked A<->B"

$gatewayBuildingA = ($status.station_buildings | Where-Object { $_.system_id -eq $sysA })[0].building_id
GovOpExpectError $p2 "demolish_station" @{ system_id = $sysA; building_id = $gatewayBuildingA } "gateway_linked" "demolition refused while linked"

# ---- R1: full happy transit with interaction checks at every phase
CharOp $p2 "add_actions" @{ character_id = $admiral1; actions = @(@{ type = "gateway_charge"; data = @{ source = $sysA; target = $sysB } }) } | Out-Null
WaitFor "admiral1 charging" 20 { (CharStatus $admiral1).action_status -eq "gateway_charging" }
$cs = CharStatus $admiral1
if ($cs.system -ne $sysA) { Fail "charging agent should still sit in system A" }
Pass "R1 charge started -- agent locked in charging, still present in A (targetable)"

$status = GovStatus
if ($status.gateway_links[0].transit.phase -ne "charging") { Fail "government transit not charging" }
GovOpExpectError $p2 "gateway_unlink" @{ system_id = $sysA } "gateway_in_use" "unlink refused during charge"

# a second agent's charge self-aborts against the busy pair
CharOp $p2 "add_actions" @{ character_id = $admiral2; actions = @(@{ type = "gateway_charge"; data = @{ source = $sysA; target = $sysB } }) } | Out-Null
WaitFor "admiral2 bounced" 20 { $s = CharStatus $admiral2; $s.action_status -eq "idle" -and $s.queue.Count -eq 0 }
Pass "R1 second agent refused -- gateway busy on both ends"

WaitFor "admiral1 in portal transit" 30 { (CharStatus $admiral1).action_status -eq "gateway_jumping" }
$cs = CharStatus $admiral1
if ($null -ne $cs.system) { Fail "jumping agent should be in no system (untargetable), got $($cs.system)" }
Pass "R1 portal jump -- agent left A, system=null (untargetable)"

# clearing a mid-jump queue is refused (would strand the traveler)
CharOp $p2 "clear_actions" @{ character_id = $admiral1; index = 0 } | Out-Null
$cs = CharStatus $admiral1
if ($cs.queue -notcontains "gateway_jump") { Fail "mid-jump queue clear was not refused" }
Pass "R1 mid-jump recall refused -- the jump must land"

WaitFor "admiral1 fatigued at B" 30 { $s = CharStatus $admiral1; $s.system -eq $sysB -and $s.action_status -eq "gateway_fatigue" }
Pass "R1 arrival -- agent present in B under portal fatigue (targetable again)"

CharOp $p2 "update_reaction" @{ character_id = $admiral1; reaction = "attack_enemies" } | Out-Null
if ((CharStatus $admiral1).reaction -ne "attack_enemies") { Fail "stance change during fatigue did not apply" }
Pass "R1 fleet stance change allowed during fatigue"

# (the arrival system belongs to the other member, so the not-at-home
# gate may fire before the idle gate — either way recall is refused)
CharOpExpectError $p2 "deactivate" @{ character_id = $admiral1 } "character_must_be_idle|character_not_at_home" "R1 recall refused during fatigue"

$status = GovStatus
if ($status.gateway_links[0].transit.phase -ne "wind_down") { Fail "gateway should be winding down" }
GovAdvance 10
$status = GovStatus
if ($null -ne $status.gateway_links[0].transit) { Fail "wind-down did not free the pair" }
Pass "R1 wind-down expired -- gateway pair free again"

WaitFor "admiral1 recovered" 20 { (CharStatus $admiral1).action_status -eq "idle" }
Pass "R1 fatigue over -- agent free to act"

# ---- R2: orders cleared mid-charge release the lock
CharOp $p2 "add_actions" @{ character_id = $speaker; actions = @(@{ type = "gateway_charge"; data = @{ source = $sysA; target = $sysB } }) } | Out-Null
WaitFor "speaker charging" 20 { (CharStatus $speaker).action_status -eq "gateway_charging" }
# the speaker charges at its OWN system, so this pins the idle gate itself
CharOpExpectError $p2 "deactivate" @{ character_id = $speaker } "character_must_be_idle" "R2 recall refused during charge (not idle)"
CharOp $p2 "clear_actions" @{ character_id = $speaker; index = 0 } | Out-Null
WaitFor "lock released after clear" 10 { $null -eq (GovStatus).gateway_links[0].transit }
Pass "R2 orders cleared mid-charge -- gateway lock released"

# ---- R3: assassinating the charging agent releases the lock
CharOp $p2 "add_actions" @{ character_id = $admiral2; actions = @(@{ type = "gateway_charge"; data = @{ source = $sysA; target = $sysB } }) } | Out-Null
WaitFor "admiral2 charging" 20 { (CharStatus $admiral2).action_status -eq "gateway_charging" }
CharOp $p2 "assassinate" @{ character_id = $admiral2 } | Out-Null
if ((CharStatus $admiral2) -ne "GONE") { Fail "assassinated agent still alive" }
WaitFor "lock released after death" 10 { $null -eq (GovStatus).gateway_links[0].transit }
Pass "R3 charging agent destroyed -- agent gone, gateway lock released"

# ---- R4: unlink cost + teardown, then demolition works
$before = (GovStatus).treasury.credit
GovOp $p2 "gateway_unlink" @{ system_id = $sysA } | Out-Null
$status = GovStatus
if ($status.gateway_links[0].status -ne "unlinking") { Fail "unlink did not enter :unlinking" }
# live upkeep keeps draining between the two reads — assert the one-time
# cost landed, with a small tolerance for the accrual
$delta = [math]::Round($before - $status.treasury.credit)
if ($delta -lt 150000 -or $delta -gt 155000) { Fail "unlink cost mismatch: $delta" }
GovAdvance 20
$status = GovStatus
if ($status.gateway_links.Count -ne 0) { Fail "unlink did not complete" }
Pass "R4 unlinked -- one-time cost billed, teardown finished"

GovOp $p2 "demolish_station" @{ system_id = $sysA; building_id = $gatewayBuildingA } | Out-Null
Pass "R4 unlinked gateway demolished free"

Write-Host ""
Write-Host "Gateway e2e complete: $script:passCount checks green (instance $iid)."

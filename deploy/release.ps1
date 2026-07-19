<#
.SYNOPSIS
  release.ps1 -- single-command production deploy.

.DESCRIPTION
  Wraps build -> ship -> verify -> recover into one reproducible pipeline.
  Exits 0 only when prod is verified running the requested revision AND
  the post-deploy maintenance-recovery pass left no instances stuck.

  This is the PowerShell entry point; deploy/release.sh is the bash
  equivalent. Both accept the same flag set and call the same downstream
  bash helpers (remote-build.sh, deploy.sh).

.PARAMETER Revision
  Git revision to build and deploy. Defaults to HEAD.

.PARAMETER BuildRemote
  Build on a transient AWS Graviton spot instance (native arm64) instead
  of locally via QEMU. ~5-10 min vs ~35 min for local. Requires AWS
  profile rc-prod and a one-time deploy/bin/setup-builder.sh run.

.PARAMETER BuildOnly
  Build + extract tarballs, then exit. Skips deploy, verify, recovery.
  Combined with -BuildRemote, pulls the tarballs back to .\build\.

.PARAMETER BackOnly
  Skip the Vue rebuild. Backend-only release.

.PARAMETER SkipBuild
  Reuse existing build\*.tar.gz instead of rebuilding. Ignores
  -BuildRemote (no point spinning up a builder for a deploy-only run).

.PARAMETER AllowCache
  Allow Docker layer cache. Default is --no-cache because cache
  poisoning of the COPY layer has shipped wrong revisions to prod before.

.PARAMETER OnDemand
  Skip the spot launch attempt; go straight to on-demand. Only meaningful
  with -BuildRemote.

.PARAMETER Keep
  Don't terminate the builder on exit. Debug only -- it will keep costing
  on-demand prices until you terminate it manually.

.PARAMETER BuilderType
  EC2 instance type for remote builds. Default: c7g.4xlarge.

.PARAMETER VueBaseUrl
  Public URL baked into the Vue bundle. Default: https://tetrarchyfalls.com

.PARAMETER VueAppsignalKey
  AppSignal frontend key. Default: empty.

.EXAMPLE
  .\deploy\release.ps1
  Build and deploy HEAD using the local QEMU path.

.EXAMPLE
  .\deploy\release.ps1 -BuildRemote
  Build on a Graviton spot and ship to prod.

.EXAMPLE
  .\deploy\release.ps1 -BuildRemote -BuildOnly
  Benchmark a remote build, pull tarballs back to .\build\, don't deploy.

.EXAMPLE
  .\deploy\release.ps1 f9e221e -BackOnly
  Backend-only deploy of a specific revision via the local path.

.NOTES
  Exit codes:
    0  PASS         -- prod runs the requested revision, no failures.
    1  FAIL         -- build, deploy, or revision-match verification failed.
    2  PARTIAL      -- deploy succeeded but some instances stuck in maintenance.
    3  INCONCLUSIVE -- build+deploy ran but prod was unreachable over SSH, so
                       the revision could not be verified. Usually a network /
                       security-group reachability problem, not a build error.

  Requirements on the Windows host:
    - Docker Desktop running (only for the local-build path).
    - Git for Windows installed (provides bash.exe + ssh.exe).
    - EC2 key at $HOME\.ssh\rc-prod.pem.
#>

[CmdletBinding()]
param(
  [Parameter(Position=0)]
  [string]$Revision = "HEAD",

  [switch]$BuildRemote,
  [switch]$BuildOnly,
  [switch]$BackOnly,
  [switch]$SkipBuild,
  [switch]$AllowCache,
  [switch]$OnDemand,
  [switch]$Keep,
  [string]$BuilderType = "c7g.4xlarge",
  [string]$VueBaseUrl = "https://tetrarchyfalls.com",
  [string]$VueAppsignalKey = "",
  [switch]$Help
)

$ErrorActionPreference = "Stop"
# Force UTF-8 on the pipe to native commands so the recovery heredoc reaches
# the remote bash intact even if it contains non-ASCII bytes.
$OutputEncoding = [System.Text.UTF8Encoding]::new($false)

# `--help` / `-h` aren't native PowerShell forms, so they bind to the
# positional Revision string instead of triggering Get-Help. Catch the
# common variants here and show the comment-based help.
if ($Help -or $Revision -in @('--help', '-h', '-help', '/?', '/help', 'help')) {
  Get-Help $PSCommandPath -Detailed
  exit 0
}

function Step([string]$msg) {
  Write-Host "[release] $msg"
}

# --- deploy-notice helpers ---------------------------------------------------
# The preflight (section 2c) raises a player-facing "deployment ongoing"
# flag on prod via RC.Deploy; these helpers clear/finish it on the way
# out. $script:deployNoticeSet tracks whether WE raised it, so failure
# paths that never reached the preflight stay no-ops. All three RC.Deploy
# entry points are zero-arg so the remote command needs no nested quoting.
$script:deployNoticeSet = $false

function Invoke-DeployNoticeRpc([string]$fn) {
  $remoteCmd = "set -e; cd /home/rc; set -a; . /etc/rc/env; set +a; ./rc/bin/rc rpc 'RC.Deploy.$fn()'"
  $eapSaved = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $null = & ssh @sshArgs -o ConnectTimeout=15 $sshHost $remoteCmd 2>&1
    return $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $eapSaved
  }
}

function Clear-DeployNotice {
  if (-not $script:deployNoticeSet) { return }
  Step "clearing deploy notice on prod"
  $code = Invoke-DeployNoticeRpc 'clear_deploy'
  if ($code -ne 0) {
    Write-Host "[release] WARNING: could not clear the deploy notice -- run /cleardeploy on Discord" -ForegroundColor Yellow
  }
  $script:deployNoticeSet = $false
}

function Complete-DeployNotice {
  if (-not $script:deployNoticeSet) { return }
  Step "finishing deploy notice on prod (update-applied message)"
  $code = Invoke-DeployNoticeRpc 'finish_deploy'
  if ($code -ne 0) {
    Write-Host "[release] WARNING: could not send the deploy-finished notice -- run /cleardeploy on Discord" -ForegroundColor Yellow
  }
  $script:deployNoticeSet = $false
}

function Fail([string]$msg, [int]$code = 1) {
  Write-Host "[release] fatal: $msg" -ForegroundColor Red
  Clear-DeployNotice
  exit $code
}

# Find git-bash explicitly. A bare `bash` on Windows resolves to
# C:\Windows\System32\bash.exe (WSL stub) first, which tries to exec
# /bin/bash inside a WSL distro and fails noisily if WSL isn't set up.
# We want Git for Windows's bash, which understands MSYS paths and runs
# our POSIX scripts without surprises.
function Get-GitBashPath {
  $candidates = @(
    (Join-Path $env:ProgramFiles 'Git\bin\bash.exe'),
    (Join-Path ${env:ProgramFiles(x86)} 'Git\bin\bash.exe'),
    (Join-Path $env:LOCALAPPDATA 'Programs\Git\bin\bash.exe')
  )
  foreach ($p in $candidates) {
    if ($p -and (Test-Path $p)) { return $p }
  }
  $found = & where.exe bash 2>$null |
    Where-Object { $_ -and ($_ -notmatch [regex]::Escape("$env:WINDIR\System32\bash.exe")) } |
    Select-Object -First 1
  if ($found) { return $found }
  return $null
}

# Single-quote a value for inline-env-var assignment to a bash command line.
# We use bash -c "FOO='val' BAR='val' exec ./script.sh" to set env on the
# child without polluting the PS session. Embedded single quotes get
# escaped via the standard '\'' trick.
function BashEnvLit([string]$v) {
  "'" + ($v -replace "'", "'\''") + "'"
}

# === 0. locate repo root and pin cwd =========================================
$repo = (Resolve-Path (Join-Path $PSScriptRoot "..")).ProviderPath
Push-Location $repo
try {

  # === 1. resolve target revision ============================================
  $resolved = (& git rev-parse --short $Revision 2>$null) | Out-String
  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($resolved)) {
    Fail "unknown git revision '$Revision'"
  }
  $resolved = $resolved.Trim()

  # Match bash `echo "$VERSION" > priv/VERSION` exactly: ASCII content +
  # trailing LF, no BOM. config/prod.exs reads this at compile time.
  [System.IO.File]::WriteAllText(
    (Join-Path $repo "priv\VERSION"),
    "$resolved`n",
    [System.Text.UTF8Encoding]::new($false))
  Step "target revision: $resolved"

  # === 2. derived options ====================================================
  $backOnlyBool = if ($BackOnly) { 'true' } else { 'false' }

  # === 2b. resolve SSH connection params (mirror nodes.sh) ===================
  # Resolved BEFORE the build now -- the preflight below contacts prod
  # first. Also used by the verify + recovery sections later.
  $sshHost  = if ($env:RC_SSH_HOST)  { $env:RC_SSH_HOST }  else { 'rc@ec2-98-91-16-141.compute-1.amazonaws.com' }
  $sshKey   = if ($env:SSH_KEY)      { $env:SSH_KEY }       else { Join-Path $HOME '.ssh\rc-prod.pem' }
  $sshPort  = if ($env:RC_SSH_PORT)  { $env:RC_SSH_PORT }  else { '22' }

  $sshArgs = @('-i', $sshKey, '-o', 'StrictHostKeyChecking=accept-new', '-p', $sshPort)
  if ($env:RC_SSH_EXTRA_OPTS) {
    $sshArgs += ($env:RC_SSH_EXTRA_OPTS -split '\s+' | Where-Object { $_ })
  }

  # === 2c. preflight: reach prod + raise the deploy notice ===================
  # Contact prod BEFORE the (long) build. This
  #   * fails fast when prod is unreachable -- no point building,
  #   * triggers the operator's SSH-key approval (1Password) now, while
  #     they are still watching, so the post-build connections reuse it,
  #   * raises the deploy-notice flag (RC.Deploy) so players get the
  #     heads-up in the news ticker and in-game chat for the whole
  #     build+deploy window.
  # ssh exit 255 = transport failure -> abort. Any other failure only
  # warns: the app may be stopped, or prod may still run a release that
  # predates RC.Deploy -- the deploy itself can proceed either way.
  if ($BuildOnly) {
    Step "-BuildOnly -- skipping prod preflight (no deploy will happen)"
  }
  else {
    Step "preflight: connecting to prod ($sshHost)"
    $preflightExit = Invoke-DeployNoticeRpc 'start_deploy'
    if ($preflightExit -eq 255) {
      Fail "cannot reach $sshHost over SSH (exit 255) -- aborting before the build. Fix reachability first (security group / VPN / instance state), then re-run." 3
    }
    elseif ($preflightExit -ne 0) {
      Write-Host "[release] WARNING: prod reachable but deploy notice not raised (exit $preflightExit)" -ForegroundColor Yellow
      Write-Host "[release]   likely: app stopped, or prod release predates RC.Deploy -- continuing without notice" -ForegroundColor Yellow
    }
    else {
      $script:deployNoticeSet = $true
      Step "deploy notice raised -- players see the heads-up now"
    }
  }

  # === 3. build ==============================================================
  if ($SkipBuild) {
    Step "-SkipBuild -- reusing build\*.tar.gz"
    if ($BuildRemote) {
      Step "  (ignoring -BuildRemote: no point spinning up a builder for a deploy-only run)"
    }
    if (-not (Test-Path "build\rc.tar.gz")) {
      Fail "build\rc.tar.gz missing -- run a build first"
    }
    if (-not $BackOnly -and -not (Test-Path "build\vue.tar.gz")) {
      Fail "build\vue.tar.gz missing (pass -BackOnly to skip Vue)"
    }
    $remoteUsed = $false
  }
  elseif ($BuildRemote) {
    # Remote build path: launches a transient Graviton spot, builds natively,
    # ships tarballs builder->prod, runs deploy.sh on the builder.
    # NOTE: in remote mode deploy.sh runs on the builder, so we SKIP the
    # local deploy.sh invocation later.
    Step "-BuildRemote -- building on transient AWS Graviton"
    $gitBash = Get-GitBashPath
    if (-not $gitBash) {
      Fail "git-bash not found -- install Git for Windows (https://git-scm.com/download/win)"
    }

    # Build the env-var prefix for bash. Internal contract with remote-build.sh
    # -- these are NOT user-facing flags, just how the parent passes state to
    # the helper. Inline assignment + exec keeps it scoped to the child.
    $envAssigns = @(
      "REVISION=$(BashEnvLit $resolved)",
      "BACK_ONLY_BOOL=$(BashEnvLit $backOnlyBool)",
      "VUE_BASE=$(BashEnvLit $VueBaseUrl)",
      "VUE_APP_APPSIGNAL_FRONT=$(BashEnvLit $VueAppsignalKey)"
    )
    if ($BuildOnly)    { $envAssigns += "RC_BUILD_ONLY=1" }
    if ($OnDemand)     { $envAssigns += "RC_BUILDER_ON_DEMAND=1" }
    if ($Keep)         { $envAssigns += "RC_BUILDER_KEEP=1" }
    if ($BuilderType -ne "c7g.4xlarge") {
      $envAssigns += "RC_BUILDER_TYPE=$(BashEnvLit $BuilderType)"
    }

    $cmdline = ($envAssigns -join ' ') + ' exec ./deploy/bin/remote-build.sh'

    # Capture all output to a timestamped log file under build/. Terminal
    # stays quiet during the multi-minute build instead of being flooded
    # with docker buildx output. On failure we tail the log automatically
    # so the operator doesn't have to open it. The log survives a spot
    # interruption mid-build because it's written to the operator's disk,
    # not the builder's ephemeral storage.
    New-Item -ItemType Directory -Force "build" | Out-Null
    $logFile = "build\remote-build-$resolved-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
    Step "  output -> $logFile"
    Step "  (terminal stays quiet; ~7-10 min. follow live in another shell:"
    Step "    Get-Content '$logFile' -Wait )"

    # PowerShell 5.1 promotes a native command's stderr writes to terminating
    # errors when $ErrorActionPreference = 'Stop' -- which would kill us on
    # docker buildx's very first (normal) stderr line. Drop to 'Continue' for
    # just this call; we detect real failure via $LASTEXITCODE below.
    $eapSaved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
      & $gitBash -c $cmdline *> $logFile
      $buildExit = $LASTEXITCODE
    } finally {
      $ErrorActionPreference = $eapSaved
    }

    if ($buildExit -ne 0) {
      Step "remote build FAILED (exit $buildExit) -- last 50 lines of log:"
      Get-Content $logFile -Tail 50 | ForEach-Object { Write-Host "  $_" }
      Fail "remote-build.sh failed (exit $buildExit) -- full log: $logFile"
    }

    # Build succeeded. Show the per-phase timings table (last ~12 lines of
    # the log) on the terminal so the operator sees the headline result
    # without opening the file.
    Step "remote build complete -- phase timings from $logFile :"
    Get-Content $logFile -Tail 12 | ForEach-Object { Write-Host "  $_" }
    $remoteUsed = $true
  }
  else {
    # Local QEMU path: docker buildx with --platform linux/arm64 on x86.
    # Slow (~35 min) but doesn't need AWS. Useful as a fallback.
    $cacheFlag = @()
    if (-not $AllowCache) { $cacheFlag += "--no-cache" }

    Step "building arm64 release locally via QEMU (BackOnly=$BackOnly, AllowCache=$AllowCache)"
    Step "  tip: pass -BuildRemote to build on a native-arm Graviton in ~5-10min"

    # Capture all output to a timestamped log file under build/. Same
    # pattern as the -BuildRemote branch above; keeps the terminal quiet
    # during a ~35 min build and auto-tails the log if buildx fails.
    New-Item -ItemType Directory -Force "build" | Out-Null
    $logFile = "build\local-build-$resolved-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
    Step "  output -> $logFile"
    Step "  (terminal stays quiet; ~35 min for full local build. Follow live:"
    Step "    Get-Content '$logFile' -Wait )"

    # BUILDKIT_PROGRESS=plain makes the captured log readable (the default
    # TTY progress bars use CR-overwrites + ANSI that turn into noise in
    # a file). Scoped via try/finally so it doesn't leak into the PS
    # session if buildx throws.
    # See the -BuildRemote branch: PS 5.1 turns a native command's stderr into
    # a terminating error under 'Stop', which would kill us on buildx's first
    # progress line. Drop to 'Continue' for the whole native-docker section;
    # every docker call below checks $LASTEXITCODE explicitly. Restored before
    # the branch ends (the Fail path exits the process, so no leak there).
    $eapSaved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $t0 = Get-Date
    $env:BUILDKIT_PROGRESS = "plain"
    try {
      & docker buildx build @cacheFlag --platform linux/arm64 --load -t rc_build_image `
        --build-arg "APP_REVISION=$resolved" `
        --build-arg "BACK_ONLY=$backOnlyBool" `
        --build-arg "VUE_APP_BASE_URL=$VueBaseUrl" `
        --build-arg "VUE_APP_APPSIGNAL_FRONT=$VueAppsignalKey" `
        . *> $logFile
      $buildExit = $LASTEXITCODE
    } finally {
      Remove-Item Env:BUILDKIT_PROGRESS -ErrorAction SilentlyContinue
    }

    if ($buildExit -ne 0) {
      Step "local build FAILED (exit $buildExit) -- last 50 lines of log:"
      Get-Content $logFile -Tail 50 | ForEach-Object { Write-Host "  $_" }
      Fail "docker buildx build failed (exit $buildExit) -- full log: $logFile"
    }

    # Extract tarballs from the build image. Fast (seconds) but redirected
    # too so a single log captures the whole local-build phase. Append-all
    # (*>>) preserves the buildx output already in the file.
    & docker rm -f rc_extract *>> $logFile
    & docker create --platform linux/arm64 --name rc_extract rc_build_image *>> $logFile
    if ($LASTEXITCODE -ne 0) {
      Step "docker create FAILED -- last 30 lines of log:"
      Get-Content $logFile -Tail 30 | ForEach-Object { Write-Host "  $_" }
      Fail "docker create failed (exit $LASTEXITCODE) -- full log: $logFile"
    }
    & docker cp "rc_extract:/home/rc/build/rc.tar.gz" "./build/" *>> $logFile
    if ($LASTEXITCODE -ne 0) { Fail "docker cp rc.tar.gz failed -- full log: $logFile" }
    if (-not $BackOnly) {
      & docker cp "rc_extract:/home/rc/build/vue.tar.gz" "./build/" *>> $logFile
      if ($LASTEXITCODE -ne 0) { Fail "docker cp vue.tar.gz failed -- full log: $logFile" }
    }
    & docker rm rc_extract *>> $logFile

    $ErrorActionPreference = $eapSaved
    $elapsed = [int]((Get-Date) - $t0).TotalSeconds
    Step "local build complete in ${elapsed}s -- full log: $logFile"
    $remoteUsed = $false
  }

  # === 4. build-only short-circuit ==========================================
  if ($BuildOnly) {
    Step "-BuildOnly -- tarballs in build\, skipping deploy"
    Get-ChildItem build\*.tar.gz | Format-Table Name, Length, LastWriteTime -AutoSize
    exit 0
  }

  # === 5. ship to prod ======================================================
  # In remote mode, deploy.sh already ran on the builder -- skip the local
  # invocation. deploy.sh is bash; resolve git-bash explicitly because a
  # bare `bash` on Windows resolves to the WSL stub first.
  if (-not $remoteUsed) {
    $gitBash = Get-GitBashPath
    if (-not $gitBash) {
      Fail "git-bash not found -- install Git for Windows (https://git-scm.com/download/win)"
    }
    Step "running deploy/bin/deploy.sh (via $gitBash)"
    & $gitBash "deploy/bin/deploy.sh"
    if ($LASTEXITCODE -ne 0) { Fail "deploy.sh failed (exit $LASTEXITCODE)" }
  }
  else {
    Step "skipping local deploy.sh -- deploy was run on the builder"
  }

  # === 6. (SSH connection params now resolved in section 2b, pre-build) =====

  # === 7. verify deployed revision (read priv/VERSION on prod, NOT journal) =
  Step "verifying deployed revision on $sshHost"
  # ssh writes connection errors (e.g. timeouts) to stderr; under
  # $ErrorActionPreference='Stop' PowerShell 5.1 can promote that to a
  # terminating error before we inspect the exit code. Drop to 'Continue'
  # for just this call and key off $LASTEXITCODE instead.
  #
  # The remote command ends in `|| true` so the ONLY source of a non-zero
  # exit is ssh's own transport failure (255 -- timeout, no route, refused).
  # A missing VERSION file still exits 0 and falls through to the revision
  # comparison below, where it surfaces as the wrong-revision banner. This
  # split matters: a connection timeout is a reachability problem (your IP
  # isn't allowed on prod:22, instance down, ...), NOT a stale Docker layer,
  # and must not be reported as one.
  $eapSaved = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $prodRevRaw = & ssh @sshArgs $sshHost 'cat /home/rc/rc/lib/rc-*/priv/VERSION 2>/dev/null || true'
    $sshExit = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $eapSaved
  }

  if ($sshExit -ne 0) {
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Yellow
    Write-Host "  RELEASE: INCONCLUSIVE -- could not verify prod" -ForegroundColor Yellow
    Write-Host "========================================" -ForegroundColor Yellow
    Write-Host "  expected : $resolved"
    Write-Host "  prod     : <unreachable> (ssh exit $sshExit)"
    Write-Host "========================================" -ForegroundColor Yellow
    Write-Host "  The build and deploy steps completed, but the verification step"
    Write-Host "  could not reach $sshHost over SSH"
    Write-Host "  (connection failed -- not an auth or revision error). This is"
    Write-Host "  almost always a network/reachability problem -- e.g. your current"
    Write-Host "  IP is not allowed on the prod security group's port 22, or the"
    Write-Host "  instance is unreachable -- NOT a stale Docker layer."
    Write-Host ""
    Write-Host "  Your deploy most likely succeeded. Confirm once SSH is reachable:"
    Write-Host "    ssh -i `"$sshKey`" -p $sshPort $sshHost 'cat /home/rc/rc/lib/rc-*/priv/VERSION'"
    Write-Host ""
    Write-Host "  The deploy notice may still be active on prod -- once reachability"
    Write-Host "  is back, clear it with /cleardeploy on Discord (or re-run verify)."
    Clear-DeployNotice
    exit 3
  }

  $prodRev = ($prodRevRaw | Out-String) -replace '\s', ''

  if ($prodRev -ne $resolved) {
    $prodDisplay = if ($prodRev) { $prodRev } else { '<unreadable>' }
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Red
    Write-Host "  RELEASE: FAIL -- wrong revision live"   -ForegroundColor Red
    Write-Host "========================================" -ForegroundColor Red
    Write-Host "  expected : $resolved"
    Write-Host "  prod     : $prodDisplay"
    Write-Host "========================================" -ForegroundColor Red
    Write-Host "  The deploy itself ran but prod is on the wrong revision. Likely cause:"
    Write-Host "  Docker layer cache served a stale COPY layer. Re-run without -AllowCache"
    Write-Host "  and verify rc_build_image was rebuilt (not cache-hit)."
    Clear-DeployNotice
    exit 1
  }

  # === 8. per-instance maintenance recovery =================================
  Step "running per-instance maintenance recovery"

  $remoteScript = @'
set -e
cd /home/rc
set -a; . /etc/rc/env; set +a
./rc/bin/rc rpc '
  import Ecto.Query
  iids =
    try do
      RC.Repo.all(from i in RC.Instances.Instance, where: i.state == "maintenance", select: i.id)
    rescue
      _ -> []
    end
  results = Enum.map(iids, fn iid ->
    try do
      instance = RC.Instances.get_instance(iid)
      case RC.Instances.restore_instance(instance, 1) do
        {:ok, _} -> {:restored, iid}
        err -> {:failed, iid, inspect(err)}
      end
    rescue
      e -> {:failed, iid, Exception.message(e)}
    catch
      kind, payload -> {:failed, iid, inspect({kind, payload})}
    end
  end)
  Enum.each(results, fn
    {:restored, iid} ->
      IO.puts("restored " <> Integer.to_string(iid))
    {:failed, iid, reason} ->
      IO.puts("failed " <> Integer.to_string(iid) <> ": " <> reason)
  end)
'
'@

  # Strip ALL CRs. PowerShell here-strings preserve CRLF on Windows, AND
  # the `|` pipeline to a native command re-injects the OS line terminator --
  # so a simple -replace on the heredoc isn't enough. The Elixir parser
  # bails with `unexpected token: carriage return` if any ^M survives.
  $remoteScript = $remoteScript -replace "`r", ""

  # Drive ssh via .NET Process so we can write raw UTF-8 bytes to stdin
  # without PowerShell's pipeline re-encoding or appending CRLFs.
  function _QuoteArg([string]$a) {
    if ($a -match '[\s"]') { '"' + ($a -replace '"', '\"') + '"' } else { $a }
  }
  $argLine = (($sshArgs + @($sshHost, 'bash', '-s')) |
    ForEach-Object { _QuoteArg $_ }) -join ' '

  $psi = [System.Diagnostics.ProcessStartInfo]::new()
  $psi.FileName = 'ssh.exe'
  $psi.Arguments = $argLine
  $psi.RedirectStandardInput  = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError  = $true
  $psi.UseShellExecute        = $false
  $psi.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false)
  $psi.StandardErrorEncoding  = [System.Text.UTF8Encoding]::new($false)

  $proc = [System.Diagnostics.Process]::Start($psi)
  $scriptBytes = [System.Text.UTF8Encoding]::new($false).GetBytes($remoteScript)
  $proc.StandardInput.BaseStream.Write($scriptBytes, 0, $scriptBytes.Length)
  $proc.StandardInput.Close()

  $stdout = $proc.StandardOutput.ReadToEnd()
  $stderr = $proc.StandardError.ReadToEnd()
  $proc.WaitForExit()
  $recoveryExit = $proc.ExitCode
  $recoveryOutput = ($stdout + $stderr) -split "`n"

  $restoredIds = @()
  $failedLines = @()
  foreach ($line in (($recoveryOutput | Out-String) -split "`n")) {
    if ($line -match '^restored\s+(\d+)') {
      $restoredIds += $Matches[1]
    }
    elseif ($line -match '^failed\s+') {
      $failedLines += $line.Trim()
    }
  }

  $rpcProbablyBroken = (
    $recoveryExit -ne 0 -and
    $restoredIds.Count -eq 0 -and
    $failedLines.Count -eq 0
  )

  # === 9. CloudFront invalidation (remote-build mode only) ==================
  # deploy.sh's tail handles this when it runs locally. In remote mode it
  # ran on the builder with no AWS credentials, so the invalidation was
  # warn-and-skipped. Re-run it here from the operator's box. Skipped for
  # backend-only deploys (no Vue change to invalidate).
  if ($remoteUsed -and -not $BackOnly) {
    Step "running CloudFront invalidation (post-remote-build)"
    $cfIdFile = Join-Path $repo ".secrets\cf_distribution_id.txt"
    if (-not (Test-Path $cfIdFile)) {
      Write-Host "[release] WARNING: .secrets\cf_distribution_id.txt missing -- skipping invalidation" -ForegroundColor Yellow
    }
    elseif (-not (Get-Command aws -ErrorAction SilentlyContinue)) {
      Write-Host "[release] WARNING: aws CLI not installed locally -- skipping invalidation" -ForegroundColor Yellow
    }
    else {
      $cfDistId = (Get-Content $cfIdFile -Raw).Trim()
      & aws --profile rc-prod cloudfront create-invalidation `
        --distribution-id $cfDistId `
        --paths '/portal/*' `
        --query 'Invalidation.[Id,Status]' --output text
      if ($LASTEXITCODE -ne 0) {
        Write-Host "[release] WARNING: invalidation failed -- edge caches will age out naturally" -ForegroundColor Yellow
      }
    }
  }

  # === 10. final summary ====================================================
  $restoredStr = if ($restoredIds.Count -gt 0) { $restoredIds -join ' ' } else { 'none' }

  Write-Host ""
  Write-Host "========================================"
  Write-Host "  RELEASE SUMMARY ($resolved)"
  Write-Host "========================================"
  Write-Host "  prod revision : $prodRev (match)"
  Write-Host "  restored      : $restoredStr"

  if ($failedLines.Count -gt 0) {
    Write-Host "  failed        :"
    foreach ($f in $failedLines) { Write-Host "    $f" }
    Write-Host "  (instances still in maintenance -- investigate via ssh)"
    Write-Host "========================================"
    Write-Host "  RELEASE: PARTIAL -- recovery incomplete" -ForegroundColor Yellow
    # New code is live -- send the update-applied notice despite the
    # stuck instances.
    Complete-DeployNotice
    exit 2
  }

  if ($rpcProbablyBroken) {
    Write-Host "  failed        : (recovery rpc did not return parseable output)"
    Write-Host "  raw output    :"
    foreach ($line in (($recoveryOutput | Out-String) -split "`n" | Select-Object -First 20)) {
      if ($line) { Write-Host "    $line" }
    }
    Write-Host "========================================"
    Write-Host "  RELEASE: PARTIAL -- recovery rpc errored" -ForegroundColor Yellow
    Complete-DeployNotice
    exit 2
  }

  Complete-DeployNotice

  Write-Host "  failed        : none"
  Write-Host "========================================"
  Write-Host "  RELEASE: PASS" -ForegroundColor Green
}
finally {
  # Runs on ctrl-C and on unexpected termination too. Normal paths have
  # already cleared/finished the notice (flag false -> no-op); reaching
  # here with it still set means we bailed mid-flight.
  if ($script:deployNoticeSet) {
    Write-Host ""
    Step "exiting with the deploy notice still up -- attempting to clear"
    Clear-DeployNotice
  }
  Pop-Location
}

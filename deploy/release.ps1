<#
.SYNOPSIS
  release.ps1 — single-command production deploy (PowerShell port of release.sh)

.DESCRIPTION
  Wraps build → extract → ship → verify → recover into one reproducible
  pipeline. Exits 0 only when prod is verified running the requested
  revision AND the post-deploy maintenance-recovery pass left no
  instances stuck.

  This is a faithful port of deploy/release.sh — same env-var contract,
  same exit codes, same output format. Use whichever feels native; both
  call the same docker buildx, deploy.sh, and rc rpc paths underneath.

.PARAMETER Revision
  Git revision to build and deploy. Defaults to HEAD.

.EXAMPLE
  .\deploy\release.ps1                  # build and deploy HEAD
  .\deploy\release.ps1 f9e221e          # specific ref

.EXAMPLE
  $env:RC_SKIP_BUILD=1
  .\deploy\release.ps1                  # reuse existing build\*.tar.gz

.NOTES
  Env vars (all optional, behavior matches release.sh):

    RC_SKIP_BUILD=1     Reuse existing build\*.tar.gz instead of rebuilding.
    RC_BUILD_ONLY=1     Build + extract tarballs, then exit. No deploy.
    RC_BACK_ONLY=1      Skip the Vue rebuild (~15-20 min instead of ~30-50).
    RC_NO_CACHE=0       Allow Docker layer cache. Default is on (--no-cache)
                        because cache poisoning has shipped wrong revisions
                        to prod before.
    VUE_APP_BASE_URL    Public URL baked into the Vue bundle.
                        Default: https://tetrarchyfalls.com
    VUE_APP_APPSIGNAL_FRONT  AppSignal frontend key. Unused; defaults to "".

  SSH connection (mirrors nodes.sh defaults):

    RC_SSH_HOST         Default: rc@ec2-98-91-16-141.compute-1.amazonaws.com
    SSH_KEY             Default: $HOME\.ssh\rc-prod.pem
    RC_SSH_PORT         Default: 22
    RC_SSH_EXTRA_OPTS   Extra opts passed verbatim to ssh.

  Exit codes:

    0  PASS    — prod runs the requested revision, no failures.
    1  FAIL    — build, deploy, or revision-match verification failed.
    2  PARTIAL — deploy succeeded and revision matches, but one or more
                 instances failed to come out of maintenance.

  Requirements on the Windows host:
    - Docker Desktop running (provides docker.exe + buildx).
    - Git for Windows installed (provides bash.exe + ssh.exe).
      deploy/bin/deploy.sh is a bash script; this wrapper invokes it via
      bash.exe. If you have multiple bash installs in PATH (e.g. WSL),
      git-bash is the recommended one.
    - EC2 key at $HOME\.ssh\rc-prod.pem.
#>

[CmdletBinding()]
param(
  [Parameter(Position=0)]
  [string]$Revision = "HEAD"
)

$ErrorActionPreference = "Stop"
# Force UTF-8 on the pipe to native commands so the recovery heredoc
# reaches the remote bash intact even if it contains non-ASCII bytes.
$OutputEncoding = [System.Text.UTF8Encoding]::new($false)

function Step([string]$msg) {
  Write-Host "[release] $msg"
}

function Fail([string]$msg, [int]$code = 1) {
  Write-Host "[release] fatal: $msg" -ForegroundColor Red
  exit $code
}

# Find git-bash explicitly. A bare `bash` on Windows resolves to
# C:\Windows\System32\bash.exe (WSL stub) first, which tries to exec
# /bin/bash inside a WSL distro and fails noisily if WSL isn't set up.
# We want Git for Windows's bash, which understands MSYS paths and runs
# deploy.sh's POSIX-isms without surprises.
function Get-GitBashPath {
  $candidates = @(
    (Join-Path $env:ProgramFiles 'Git\bin\bash.exe'),
    (Join-Path ${env:ProgramFiles(x86)} 'Git\bin\bash.exe'),
    (Join-Path $env:LOCALAPPDATA 'Programs\Git\bin\bash.exe')
  )
  foreach ($p in $candidates) {
    if ($p -and (Test-Path $p)) { return $p }
  }
  # Last resort: any bash in PATH that isn't the WSL stub.
  $found = & where.exe bash 2>$null |
    Where-Object { $_ -and ($_ -notmatch [regex]::Escape("$env:WINDIR\System32\bash.exe")) } |
    Select-Object -First 1
  if ($found) { return $found }
  return $null
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

  # === 2. resolve options ====================================================
  $skipBuild = $env:RC_SKIP_BUILD -eq '1'
  $buildOnly = $env:RC_BUILD_ONLY -eq '1'
  $backOnly  = $env:RC_BACK_ONLY  -eq '1'
  $noCache   = $env:RC_NO_CACHE -ne '0'  # default ON

  $vueBase   = if ($env:VUE_APP_BASE_URL) { $env:VUE_APP_BASE_URL } else { 'https://tetrarchyfalls.com' }
  $appsignal = if ($env:VUE_APP_APPSIGNAL_FRONT) { $env:VUE_APP_APPSIGNAL_FRONT } else { '' }

  # === 3. build (default: --no-cache to defeat layer-cache poisoning) =======
  if ($skipBuild) {
    Step "RC_SKIP_BUILD=1 — reusing build\*.tar.gz"
    if (-not (Test-Path "build\rc.tar.gz")) {
      Fail "build\rc.tar.gz missing — run a build first"
    }
    if (-not $backOnly -and -not (Test-Path "build\vue.tar.gz")) {
      Fail "build\vue.tar.gz missing (set RC_BACK_ONLY=1 to skip Vue)"
    }
  }
  else {
    $cacheFlag = @()
    if ($noCache) { $cacheFlag += "--no-cache" }
    $backOnlyBool = if ($backOnly) { 'true' } else { 'false' }

    Step "building arm64 release (BACK_ONLY=$backOnlyBool, NO_CACHE=$([int]$noCache))"
    & docker buildx build @cacheFlag --platform linux/arm64 --load -t rc_build_image `
      --build-arg "APP_REVISION=$resolved" `
      --build-arg "BACK_ONLY=$backOnlyBool" `
      --build-arg "VUE_APP_BASE_URL=$vueBase" `
      --build-arg "VUE_APP_APPSIGNAL_FRONT=$appsignal" `
      .
    if ($LASTEXITCODE -ne 0) { Fail "docker buildx build failed (exit $LASTEXITCODE)" }

    Step "extracting tarballs"
    & docker rm -f rc_extract *> $null
    & docker create --platform linux/arm64 --name rc_extract rc_build_image *> $null
    if ($LASTEXITCODE -ne 0) { Fail "docker create failed (exit $LASTEXITCODE)" }
    & docker cp "rc_extract:/home/rc/build/rc.tar.gz" "./build/"
    if ($LASTEXITCODE -ne 0) { Fail "docker cp rc.tar.gz failed" }
    if (-not $backOnly) {
      & docker cp "rc_extract:/home/rc/build/vue.tar.gz" "./build/"
      if ($LASTEXITCODE -ne 0) { Fail "docker cp vue.tar.gz failed" }
    }
    & docker rm rc_extract *> $null
  }

  if ($buildOnly) {
    Step "RC_BUILD_ONLY=1 — tarballs in build\, skipping deploy"
    Get-ChildItem build\*.tar.gz | Format-Table Name, Length, LastWriteTime -AutoSize
    exit 0
  }

  # === 4. ship to prod (delegate to deploy.sh — leave it alone) =============
  # deploy.sh is bash. Resolve git-bash explicitly because a bare `bash` on
  # Windows resolves to the WSL stub first and fails with
  # `execvpe(/bin/bash) failed: No such file or directory` when WSL isn't
  # set up. See Get-GitBashPath above for the lookup order.
  $gitBash = Get-GitBashPath
  if (-not $gitBash) {
    Fail "git-bash not found — install Git for Windows (https://git-scm.com/download/win)"
  }
  Step "running deploy/bin/deploy.sh (via $gitBash)"
  & $gitBash "deploy/bin/deploy.sh"
  if ($LASTEXITCODE -ne 0) { Fail "deploy.sh failed (exit $LASTEXITCODE)" }

  # === 5. resolve SSH connection params (mirror nodes.sh) ===================
  $sshHost  = if ($env:RC_SSH_HOST)  { $env:RC_SSH_HOST }  else { 'rc@ec2-98-91-16-141.compute-1.amazonaws.com' }
  $sshKey   = if ($env:SSH_KEY)      { $env:SSH_KEY }       else { Join-Path $HOME '.ssh\rc-prod.pem' }
  $sshPort  = if ($env:RC_SSH_PORT)  { $env:RC_SSH_PORT }  else { '22' }

  $sshArgs = @('-i', $sshKey, '-o', 'StrictHostKeyChecking=accept-new', '-p', $sshPort)
  if ($env:RC_SSH_EXTRA_OPTS) {
    $sshArgs += ($env:RC_SSH_EXTRA_OPTS -split '\s+' | Where-Object { $_ })
  }

  # === 6. verify deployed revision (read priv/VERSION on prod, NOT journal) =
  Step "verifying deployed revision on $sshHost"
  $prodRevRaw = & ssh @sshArgs $sshHost 'cat /home/rc/rc/lib/rc-*/priv/VERSION 2>/dev/null'
  $prodRev = ($prodRevRaw | Out-String) -replace '\s', ''

  if ($prodRev -ne $resolved) {
    $prodDisplay = if ($prodRev) { $prodRev } else { '<unreadable>' }
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Red
    Write-Host "  RELEASE: FAIL — wrong revision live"   -ForegroundColor Red
    Write-Host "========================================" -ForegroundColor Red
    Write-Host "  expected : $resolved"
    Write-Host "  prod     : $prodDisplay"
    Write-Host "========================================" -ForegroundColor Red
    Write-Host "  The deploy itself ran but prod is on the wrong revision. Likely cause:"
    Write-Host "  Docker layer cache served a stale COPY layer. Re-run with RC_NO_CACHE=1"
    Write-Host "  (default) and verify rc_build_image was rebuilt (not cache-hit)."
    exit 1
  }

  # === 7. per-instance maintenance recovery =================================
  Step "running per-instance maintenance recovery"

  # Heredoc piped to remote bash. Single-quoted PS here-string means no
  # variable expansion on our side. The remote rpc gets the Elixir code
  # via single-quoted shell, so $ and #{...} pass through literally.
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
  # the `|` pipeline to a native command re-injects the OS line terminator
  # (CRLF on Windows) — so a simple -replace on the heredoc isn't enough.
  # The Elixir parser bails with `unexpected token: carriage return` if any
  # ^M survives. Belt-and-braces: strip them now, then write bytes directly
  # to ssh's stdin (skipping the pipeline) below.
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

  # Read both streams before WaitForExit to avoid the classic pipe-fills
  # deadlock. Output here is small (a few result lines), so sequential
  # ReadToEnd is fine.
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

  # If the rpc itself errored (couldn't even start), we'll have neither
  # restored nor failed lines but a non-zero exit. Treat as partial.
  $rpcProbablyBroken = (
    $recoveryExit -ne 0 -and
    $restoredIds.Count -eq 0 -and
    $failedLines.Count -eq 0
  )

  # === 8. final summary =====================================================
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
    Write-Host "  (instances still in maintenance — investigate via ssh)"
    Write-Host "========================================"
    Write-Host "  RELEASE: PARTIAL — recovery incomplete" -ForegroundColor Yellow
    exit 2
  }

  if ($rpcProbablyBroken) {
    Write-Host "  failed        : (recovery rpc did not return parseable output)"
    Write-Host "  raw output    :"
    foreach ($line in (($recoveryOutput | Out-String) -split "`n" | Select-Object -First 20)) {
      if ($line) { Write-Host "    $line" }
    }
    Write-Host "========================================"
    Write-Host "  RELEASE: PARTIAL — recovery rpc errored" -ForegroundColor Yellow
    exit 2
  }

  Write-Host "  failed        : none"
  Write-Host "========================================"
  Write-Host "  RELEASE: PASS" -ForegroundColor Green
}
finally {
  Pop-Location
}

# Grant credit / technology / ideology to a list of players in a running game
# instance on prod. ASCII-only; runs on Windows PowerShell 5.1 and PowerShell 7.
#
# Usage:
#   bin/rc-grant-resources.ps1 -Instance 10 -Players "Granite,Alrua,Kalid" `
#       -Cred 3000000 -Tech 100000 -Ideo 100000
#
# Validates the instance is running and every named player is present BEFORE
# granting anything. Aborts cleanly with a list of missing/ambiguous names if
# the precondition fails. No partial grants.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [int]$Instance,

    [Parameter(Mandatory = $true)]
    [string]$Players,

    [Parameter(Mandatory = $true)]
    [int]$Cred,

    [Parameter(Mandatory = $true)]
    [int]$Tech,

    [Parameter(Mandatory = $true)]
    [int]$Ideo,

    [string]$SshHost = 'ec2-98-91-16-141.compute-1.amazonaws.com',
    [string]$SshUser = 'rc',
    [string]$SshKey  = (Join-Path $HOME '.ssh/rc-prod.pem')
)

$ErrorActionPreference = 'Stop'

# ---------- Local validation ----------

if ($Instance -le 0) { throw "Instance id must be > 0 (got $Instance)" }
if ($Cred -lt 0 -or $Tech -lt 0 -or $Ideo -lt 0) {
    throw "Resource deltas must be >= 0 (got cred=$Cred tech=$Tech ideo=$Ideo)"
}

$names = $Players.Split(',') |
    ForEach-Object { $_.Trim() } |
    Where-Object { $_ -ne '' }

if ($names.Count -eq 0) { throw "No player names provided in -Players" }

# Reject names with characters that would need Elixir-string escaping. Game
# player names in practice are letters/digits/underscore/period/hyphen.
$badNames = $names | Where-Object { $_ -notmatch '^[A-Za-z0-9_.\-]+$' }
if ($badNames.Count -gt 0) {
    throw "Unsupported characters in player name(s): $($badNames -join ', ')"
}

if (-not (Test-Path $SshKey)) { throw "SSH key not found: $SshKey" }

# ---------- Build the remote Elixir script ----------

$namesElixir = '[' + (($names | ForEach-Object { '"' + $_ + '"' }) -join ', ') + ']'

$exsContent = @"
instance_id  = $Instance
credit_delta = $Cred
tech_delta   = $Tech
ideo_delta   = $Ideo
target_names = $namesElixir

# 1. Probe the instance: Game.call returns :process_not_found when the
#    galaxy agent for this instance isn't registered (instance not running
#    or doesn't exist). Other errors come back as {:error, :callee_crashed}
#    or {:error, :callee_timeout}.
case Game.call(instance_id, :galaxy, :master, :get_state) do
  {:ok, galaxy} ->
    by_name =
      Enum.reduce(galaxy.players, %{}, fn {id, meta}, acc ->
        Map.update(acc, Map.get(meta, :name), [{id, meta}], fn list -> [{id, meta} | list] end)
      end)

    {missing, ambiguous, found} =
      Enum.reduce(target_names, {[], [], []}, fn name, {miss, amb, ok} ->
        case Map.get(by_name, name) do
          nil      -> {[name | miss], amb, ok}
          [single] -> {miss, amb, [{name, single} | ok]}
          many     -> {miss, [{name, many} | amb], ok}
        end
      end)

    cond do
      missing != [] or ambiguous != [] ->
        if missing != [] do
          IO.puts("ABORT: missing player(s) in instance " <> Integer.to_string(instance_id) <> ": " <> Enum.join(Enum.reverse(missing), ", "))
        end

        if ambiguous != [] do
          IO.puts("ABORT: ambiguous player name(s):")
          Enum.each(ambiguous, fn {name, list} ->
            ids = Enum.map(list, fn {id, _} -> id end)
            IO.puts("  " <> name <> " => " <> inspect(ids))
          end)
        end

        :aborted_validation_failed

      true ->
        IO.puts("=== INSTANCE " <> Integer.to_string(instance_id) <> " - granting +" <> Integer.to_string(credit_delta) <> " cr / +" <> Integer.to_string(tech_delta) <> " tech / +" <> Integer.to_string(ideo_delta) <> " ideo to " <> Integer.to_string(length(found)) <> " player(s) ===")

        Enum.each(Enum.reverse(found), fn {name, {pid, meta}} ->
          before =
            case Game.call(instance_id, :player, pid, :get_state) do
              {:ok, p} -> {trunc(p.credit.value), trunc(p.technology.value), trunc(p.ideology.value)}
              err -> {:error, inspect(err)}
            end

          grant_result =
            Game.call(instance_id, :player, pid, {:add_resources, credit_delta, tech_delta, ideo_delta})

          after_ =
            case Game.call(instance_id, :player, pid, :get_state) do
              {:ok, p} -> {trunc(p.credit.value), trunc(p.technology.value), trunc(p.ideology.value)}
              err -> {:error, inspect(err)}
            end

          IO.inspect(%{
            name: name,
            id: pid,
            faction: Map.get(meta, :faction),
            grant: grant_result,
            before: before,
            after: after_
          })
        end)

        :done
    end

  :process_not_found ->
    IO.puts("ABORT: instance " <> Integer.to_string(instance_id) <> " is not running (galaxy agent not registered).")
    :aborted_instance_not_running

  other ->
    IO.puts("ABORT: galaxy agent returned unexpected value: " <> inspect(other))
    :aborted_galaxy_error
end
"@

# ---------- Stage locally, scp, run, cleanup ----------

$guid       = [guid]::NewGuid().ToString('N').Substring(0, 8)
$localPath  = Join-Path $env:TEMP "rc-grant-$guid.exs"
$remotePath = "/tmp/rc-grant-$guid.exs"

Set-Content -LiteralPath $localPath -Value $exsContent -Encoding ASCII

try {
    Write-Host "scp $localPath -> ${SshUser}@${SshHost}:$remotePath" -ForegroundColor DarkGray
    & scp -i $SshKey -o ConnectTimeout=30 $localPath "${SshUser}@${SshHost}:$remotePath"
    if ($LASTEXITCODE -ne 0) { throw "scp failed (exit $LASTEXITCODE)" }

    # Use the ~S{...} sigil so the eval_file argument has no embedded double
    # quotes - keeps the ssh-remote command quoting simple.
    $remoteCmd = "set -a; . /etc/rc/env; set +a; /home/rc/rc/bin/rc rpc 'Code.eval_file(~S{$remotePath})'"

    & ssh -i $SshKey -o ConnectTimeout=30 "${SshUser}@${SshHost}" $remoteCmd
    if ($LASTEXITCODE -ne 0) { throw "rc rpc failed (exit $LASTEXITCODE)" }
}
finally {
    & ssh -i $SshKey -o ConnectTimeout=15 "${SshUser}@${SshHost}" "rm -f $remotePath" 2>$null | Out-Null
    Remove-Item -LiteralPath $localPath -ErrorAction SilentlyContinue
}

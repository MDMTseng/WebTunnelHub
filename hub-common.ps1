# Shared helpers for Hub mode (dot-source from hub-*.ps1).
# Loads `.env` from this repo root if present; set variables in `.env` or in the environment.

$__hubCommon = $PSCommandPath
if (-not $__hubCommon) { $__hubCommon = $MyInvocation.MyCommand.Path }
$HubRoot = Split-Path -Parent $__hubCommon
$EnvFile = Join-Path $HubRoot '.env'
if (Test-Path -LiteralPath $EnvFile) {
  Get-Content -LiteralPath $EnvFile | ForEach-Object {
    $line = $_ -replace "`r`$", ''
    if ($line -match '^\s*#' -or $line -match '^\s*$') { return }
    if ($line -match '^([^=#]+)=(.*)$') {
      $key = $matches[1].Trim()
      $val = $matches[2].Trim()
      if (
        ($val.Length -ge 2) -and (
          ($val.StartsWith('"') -and $val.EndsWith('"')) -or
          ($val.StartsWith("'") -and $val.EndsWith("'"))
        )
      ) {
        $val = $val.Substring(1, $val.Length - 2)
      }
      Set-Item -Path "Env:$key" -Value $val
    }
  }
}

$HubRequired = @(
  'SSH_TARGET', 'SSH_KEY', 'SSH_PORT', 'HUB_DIR', 'MAIN_CFG', 'HUB_PUBLIC_URL'
)
$HubMissing = @()
foreach ($v in $HubRequired) {
  $x = [Environment]::GetEnvironmentVariable($v)
  if ([string]::IsNullOrWhiteSpace($x)) { $HubMissing += $v }
}
if ($HubMissing.Count -gt 0) {
  Write-Host "hub-common: missing or empty: $($HubMissing -join ', ')" -ForegroundColor Red
  Write-Host "  Set them in $EnvFile (see .env.example) or set environment variables before running." -ForegroundColor Red
  throw 'hub-common: configuration incomplete'
}

function ConvertTo-BashSingleQuoted {
  param([string]$Value)
  "'{0}'" -f ($Value -replace "'", "'\''")
}

function Get-HubSshHost {
  $t = $env:SSH_TARGET
  $i = $t.IndexOf('@')
  if ($i -ge 0) { return $t.Substring($i + 1) }
  return $t
}

function Get-ZlibAdler32 {
  param([byte[]]$Bytes)
  $MOD = 65521
  $a = 1
  $b = 0
  foreach ($byte in $Bytes) {
    $a = ($a + $byte) % $MOD
    $b = ($b + $a) % $MOD
  }
  [uint32](($b -shl 16) -bor $a)
}

function Get-HubRemotePort {
  param([string]$AppName)
  $utf8 = [System.Text.Encoding]::UTF8.GetBytes($AppName)
  $h = Get-ZlibAdler32 -Bytes $utf8
  20000 + ([int]($h % 10000))
}

function Test-HubAppName {
  param([string]$Name)
  if ($Name -notmatch '^[a-zA-Z0-9][a-zA-Z0-9_-]{0,47}$') {
    Write-Host "Invalid app name '$Name': use letters, digits, underscore, hyphen; max 48 chars." -ForegroundColor Red
    return $false
  }
  return $true
}

function Test-HubReverseTunnelActive {
  param([int]$RemotePort)
  $hostOnly = Get-HubSshHost
  $needle = "127.0.0.1:${RemotePort}:127.0.0.1"
  $procs = @(Get-CimInstance Win32_Process -Filter "Name = 'ssh.exe'" -ErrorAction SilentlyContinue)
  foreach ($p in $procs) {
    $cmd = $p.CommandLine
    if ([string]::IsNullOrEmpty($cmd)) { continue }
    if ($cmd -notlike "*$hostOnly*") { continue }
    if ($cmd -notlike '*-R*') { continue }
    if ($cmd -like "*$needle*") { return $true }
  }
  return $false
}

function Stop-HubTunnelForRemotePort {
  param([int]$RemotePort)
  $hostOnly = Get-HubSshHost
  $needle = "127.0.0.1:${RemotePort}:127.0.0.1"
  $procs = @(Get-CimInstance Win32_Process -Filter "Name = 'ssh.exe'" -ErrorAction SilentlyContinue)
  $pids = New-Object System.Collections.Generic.List[int]
  foreach ($p in $procs) {
    $cmd = $p.CommandLine
    if ([string]::IsNullOrEmpty($cmd)) { continue }
    if ($cmd -notlike "*$hostOnly*") { continue }
    if ($cmd -notlike '*-R*') { continue }
    if ($cmd -like "*$needle*") { $pids.Add([int]$p.ProcessId) | Out-Null }
  }
  $unique = $pids | Sort-Object -Unique
  if ($unique.Count -eq 0) { return }
  Write-Host "Stopping local SSH tunnel(s) for EC2 127.0.0.1:${RemotePort} (PIDs: $($unique -join ', '))" -ForegroundColor Yellow
  foreach ($pid in $unique) {
    Stop-Process -Id $pid -Force -ErrorAction SilentlyContinue
  }
  Start-Sleep -Seconds 0.7
}

# On EC2: kill TCP listener on :RemotePort (usually sshd for -R). Drops the client SSH session. sudo + fuser/lsof.
function Stop-HubTunnelListenerOnEc2 {
  param(
    [Parameter(Mandatory)]
    [ValidateRange(1, 65535)]
    [int]$RemotePort
  )
  Write-Host "EC2: tearing down tunnel listener on port $RemotePort (drops client SSH if connected)." -ForegroundColor Cyan
  $tpl = @'
if command -v fuser >/dev/null 2>&1; then
  sudo fuser -k __PORT__/tcp 2>/dev/null || true
fi
if command -v lsof >/dev/null 2>&1; then
  for p in $(sudo lsof -t -iTCP:__PORT__ -sTCP:LISTEN 2>/dev/null); do
    sudo kill "$p" 2>/dev/null || true
  done
fi
'@
  $bashBody = $tpl.Replace('__PORT__', [string]$RemotePort)
  $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($bashBody))
  $inner = "printf '%s' '$b64' | base64 -d | bash"
  $wrapped = 'sudo sh -c ' + (ConvertTo-BashSingleQuoted $inner)
  [void](Invoke-HubSshBatch -Arguments @(
      '-p', $env:SSH_PORT,
      '-i', $env:SSH_KEY,
      '-o', 'BatchMode=yes',
      '-o', 'ConnectTimeout=15',
      $env:SSH_TARGET,
      $wrapped
    ))
}

function Test-HubLocalHttp {
  param([int]$Port)
  try {
    $r = Invoke-WebRequest -Uri "http://127.0.0.1:${Port}/" -UseBasicParsing -TimeoutSec 2 -ErrorAction Stop
    return $true
  }
  catch {
    return $false
  }
}

function Wait-HubLocalHttp {
  param([int]$Port, [int]$MaxTries = 10)
  for ($i = 0; $i -lt $MaxTries; $i++) {
    if (Test-HubLocalHttp -Port $Port) { return $true }
    Start-Sleep -Seconds 0.35
  }
  return $false
}

function Start-HubBackgroundLog {
  param([string]$LogPath, [string]$FilePath, [string[]]$ArgumentList)
  $dir = Split-Path -Parent $LogPath
  if ($dir -and $dir -ne '.') { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -WindowStyle Hidden `
    -RedirectStandardOutput $LogPath -RedirectStandardError $LogPath | Out-Null
}

function Get-HubSshExecutable {
  $cmd = Get-Command ssh.exe -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  return (Get-Command ssh -ErrorAction Stop).Source
}

# Non-interactive ssh with a reliable exit code on Windows PowerShell 5.1 (no $LASTEXITCODE).
function Invoke-HubSshBatch {
  param([Parameter(Mandatory)][string[]]$Arguments)
  $exe = Get-HubSshExecutable
  $p = Start-Process -FilePath $exe -ArgumentList $Arguments -Wait -NoNewWindow -PassThru
  return [int]$p.ExitCode
}

function Invoke-HubRemoteBashScript {
  param(
    [Parameter(Mandatory)][string]$BashScript,
    [switch]$IgnoreExitCode
  )
  $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($BashScript))
  $remote = "printf '%s' '$b64' | base64 -d | bash"
  # Use console ssh (not Start-Process) so remote stdout is visible (hub-applist, hub-status).
  & ssh -p $env:SSH_PORT -i $env:SSH_KEY -o BatchMode=yes -o ConnectTimeout=15 $env:SSH_TARGET $remote
  $exit = 0
  if ($PSVersionTable.PSVersion.Major -ge 6) {
    $exit = $LASTEXITCODE
  }
  else {
    $exit = if ($?) { 0 } else { 1 }
  }
  if (-not $IgnoreExitCode -and $exit -ne 0) {
    throw "ssh remote bash failed (exit $exit)"
  }
  return $exit
}

# Run remote bash via base64 pipe; return stdout as a single string (stderr discarded). Throws if ssh/bash exits non-zero.
function Invoke-HubRemoteBashStdout {
  param([Parameter(Mandatory)][string]$BashScript)
  $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($BashScript))
  $remote = "printf '%s' '$b64' | base64 -d | bash"
  $exe = Get-HubSshExecutable
  $prevEa = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $stdout = & $exe @(
      '-p', $env:SSH_PORT,
      '-i', $env:SSH_KEY,
      '-o', 'BatchMode=yes',
      '-o', 'ConnectTimeout=15',
      $env:SSH_TARGET,
      $remote
    ) 2>$null
  }
  finally {
    $ErrorActionPreference = $prevEa
  }
  if (-not $?) {
    $code = if ($null -ne $LASTEXITCODE) { $LASTEXITCODE } else { 'unknown' }
    throw "ssh remote bash failed (exit $code)"
  }
  if ($null -eq $stdout) { return '' }
  if ($stdout -is [array]) { return (($stdout -join "`n").Trim()) }
  return [string]$stdout
}

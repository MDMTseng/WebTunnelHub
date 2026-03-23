# Reverse SSH tunnel to EC2 (Hub or single default site). Requires OpenSSH client (Windows optional feature).
# Usage matches hub-tunnel.sh — see Manual.md
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'hub-common.ps1')

function Show-HubTunnelUsage {
  Write-Host @'
Usage:
  .\hub-tunnel.ps1                          Default site: local PORT/8080 -> EC2 127.0.0.1:10080
  .\hub-tunnel.ps1 -Port 3422 CoolApp       Hub app:      local 3422       -> EC2 127.0.0.1:<auto>
  .\hub-tunnel.ps1 --port 3422 CoolApp      Same (-p / --port / -Port)
  .\hub-tunnel.ps1 CoolApp -Port 3422       Same (flags and name order flexible)

Environment:
  See `.env` / `.env.example` for SSH_TARGET, SSH_KEY, SSH_PORT, HUB_PUBLIC_URL.
  $env:PORT, $env:REMOTE_BIND, $env:REMOTE_PORT (override auto port for Hub)
'@
}

$remoteBind = if ($env:REMOTE_BIND) { $env:REMOTE_BIND } else { '127.0.0.1' }
$localPort = if ($env:PORT) { [int]$env:PORT } else { 8080 }
$appName = ''

$tokens = New-Object System.Collections.ArrayList
foreach ($x in $args) { [void]$tokens.Add([string]$x) }
while ($tokens.Count -gt 0) {
  $a = [string]$tokens[0]
  if ($a -eq '-p' -or $a -eq '--port' -or $a -ieq '-Port') {
    if ($tokens.Count -lt 2) { Write-Host "Missing value for $a" -ForegroundColor Red; exit 1 }
    $localPort = [int]$tokens[1]
    $tokens.RemoveRange(0, 2)
    continue
  }
  if ($a -eq '-h' -or $a -eq '--help') {
    Show-HubTunnelUsage
    exit 0
  }
  if ($a.StartsWith('-')) {
    Write-Host "Unknown option: $a" -ForegroundColor Red
    Show-HubTunnelUsage
    exit 1
  }
  if ($appName) { Write-Host "Extra argument: $a" -ForegroundColor Red; exit 1 }
  $appName = $a
  $tokens.RemoveAt(0)
}

if ($appName) {
  if (-not (Test-HubAppName $appName)) { exit 1 }
  $remotePort = if ($env:REMOTE_PORT) { [int]$env:REMOTE_PORT } else { Get-HubRemotePort -AppName $appName }
  Write-Host "Hub app '${appName}': $($env:HUB_PUBLIC_URL)/${appName}/"
  Write-Host "EC2 loopback ${remotePort} -> local 127.0.0.1:${localPort}"
  Write-Host "If not done yet: .\hub-register.ps1 ${appName}"
}
else {
  $remotePort = if ($env:REMOTE_PORT) { [int]$env:REMOTE_PORT } else { 10080 }
  Write-Host "Default site: local 127.0.0.1:${localPort} -> EC2 ${remoteBind}:${remotePort}"
}

Write-Host "SSH $($env:SSH_TARGET) (leave running). Direct mode: `$env:REMOTE_BIND='0.0.0.0'; `$env:REMOTE_PORT=1080 .\hub-tunnel.ps1"
Write-Host ''

$sshArgs = @(
  '-N',
  '-p', $env:SSH_PORT,
  '-i', $env:SSH_KEY,
  '-o', 'ServerAliveInterval=30',
  '-o', 'ServerAliveCountMax=3',
  '-R', "${remoteBind}:${remotePort}:127.0.0.1:${localPort}",
  $env:SSH_TARGET
)
& ssh @sshArgs
if ($PSVersionTable.PSVersion.Major -ge 6) {
  exit $LASTEXITCODE
}
if (-not $?) { exit 1 }
exit 0

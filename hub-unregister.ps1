# Remove a Hub app from EC2 (case-insensitive *.caddy match) and tear down tunnels (same behavior as hub-unregister.sh).
# Tunnel teardown: (1) EC2 kills TCP listener for the hub port (drops client SSH), (2) local ssh.exe processes killed as fallback.
# Set env HUB_KILL_TUNNEL_ON_EC2=0 to skip step 1. --no-kill skips both.
# Windows: use OpenSSH (optional feature or Git for Windows). Set SSH_KEY in .env to a path like C:/Users/you/.ssh/key.pem
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'hub-common.ps1')

$noKill = $false
$rest = New-Object System.Collections.ArrayList
foreach ($x in $args) { [void]$rest.Add([string]$x) }
while ($rest.Count -gt 0 -and $rest[0] -eq '--no-kill') {
  $noKill = $true
  $rest.RemoveAt(0)
}

$appName = if ($rest.Count -gt 0) { [string]$rest[0] } else { '' }
if (-not $appName) {
  Write-Host "Usage: $($MyInvocation.MyCommand.Name) [--no-kill] <AppName>" -ForegroundColor Red
  exit 1
}
if (-not (Test-HubAppName $appName)) { exit 1 }

$appLower = $appName.ToLowerInvariant()
$hubDir = $env:HUB_DIR.TrimEnd('/')

$listTpl = @'
shopt -s nullglob
__HUB_DIR_ASSIGN__
__APP_LOWER_ASSIGN__
for f in "$HUB_DIR"/*.caddy; do
	b=$(basename "$f" .caddy)
	[[ "$b" == _keep ]] && continue
	bl=$(printf '%s' "$b" | tr '[:upper:]' '[:lower:]')
	[[ "$bl" == "$APP_LOWER" ]] && printf '%s\n' "$b"
done
'@
$assignHub = 'HUB_DIR=' + (ConvertTo-BashSingleQuoted $hubDir)
$assignLower = 'APP_LOWER=' + (ConvertTo-BashSingleQuoted $appLower)
$listScript = $listTpl.Replace('__HUB_DIR_ASSIGN__', $assignHub).Replace('__APP_LOWER_ASSIGN__', $assignLower)

$listOut = Invoke-HubRemoteBashStdout -BashScript $listScript
$matches = @(
  $listOut -split "`r?`n" |
    ForEach-Object { $_.Trim() } |
    Where-Object { $_ }
)

if ($matches.Count -eq 0) {
  Write-Host "hub-unregister: no route matched '$appName' (case-insensitive) under $($env:HUB_DIR) on $($env:SSH_TARGET)." -ForegroundColor Red
  exit 1
}

if (-not $noKill) {
  if ($env:HUB_KILL_TUNNEL_ON_EC2 -ne '0') {
    if ($env:REMOTE_PORT) {
      Stop-HubTunnelListenerOnEc2 -RemotePort ([int]$env:REMOTE_PORT)
    }
    else {
      foreach ($m in $matches) {
        Stop-HubTunnelListenerOnEc2 -RemotePort (Get-HubRemotePort -AppName $m)
      }
    }
  }
  else {
    Write-Host 'Skipping EC2 tunnel listener kill (HUB_KILL_TUNNEL_ON_EC2=0).' -ForegroundColor Yellow
  }
  if ($env:REMOTE_PORT) {
    Stop-HubTunnelForRemotePort -RemotePort ([int]$env:REMOTE_PORT)
  }
  else {
    foreach ($m in $matches) {
      Stop-HubTunnelForRemotePort -RemotePort (Get-HubRemotePort -AppName $m)
    }
  }
}
else {
  Write-Host 'Skipping tunnel teardown (--no-kill).' -ForegroundColor Yellow
}

$snipList = ($matches | ForEach-Object { "${_}.caddy" }) -join ' '
Write-Host "Removing on $($env:SSH_TARGET) (case-insensitive match for '${appName}'): $snipList"

$removeTpl = @'
set -euo pipefail
shopt -s nullglob
__EXPORTS__
for f in "$HUB_DIR"/*.caddy; do
	b=$(basename "$f" .caddy)
	[[ "$b" == _keep ]] && continue
	bl=$(printf '%s' "$b" | tr '[:upper:]' '[:lower:]')
	[[ "$bl" == "$APP_LOWER" ]] || continue
	sudo rm -f "$f"
done
sudo caddy validate --config "$MAIN_CFG" && sudo systemctl reload caddy
'@
$exports = 'export HUB_DIR=' + (ConvertTo-BashSingleQuoted $hubDir) + '; ' +
  'export APP_LOWER=' + (ConvertTo-BashSingleQuoted $appLower) + '; ' +
  'export MAIN_CFG=' + (ConvertTo-BashSingleQuoted $env:MAIN_CFG)
$removeScript = $removeTpl.Replace('__EXPORTS__', $exports)

$b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($removeScript))
$remoteRm = "printf '%s' '$b64' | base64 -d | bash"
$ec = Invoke-HubSshBatch -Arguments @(
  '-p', $env:SSH_PORT,
  '-i', $env:SSH_KEY,
  '-o', 'BatchMode=yes',
  '-o', 'ConnectTimeout=15',
  $env:SSH_TARGET,
  $remoteRm
)
if ($ec -ne 0) { exit $ec }

Write-Host "OK: removed route(s): $($matches -join ' '). If .\hub-tunnel.ps1 was running for one of these names, it should have exited."

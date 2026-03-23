# Remove a Hub app from EC2 and stop local ssh -R for that app's port (same as hub-unregister.sh).
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

$remotePort = if ($env:REMOTE_PORT) { [int]$env:REMOTE_PORT } else { Get-HubRemotePort -AppName $appName }

if (-not $noKill) {
  Stop-HubTunnelForRemotePort -RemotePort $remotePort
}
else {
  Write-Host 'Skipping local ssh kill (--no-kill).' -ForegroundColor Yellow
}

$qFile = ConvertTo-BashSingleQuoted "$($env:HUB_DIR.TrimEnd('/'))/${appName}.caddy"
$qMainCfg = ConvertTo-BashSingleQuoted $env:MAIN_CFG

Write-Host "Removing $($env:HUB_DIR)/${appName}.caddy on $($env:SSH_TARGET) ..."
$ec = Invoke-HubSshBatch -Arguments @(
  '-p', $env:SSH_PORT,
  '-i', $env:SSH_KEY,
  '-o', 'BatchMode=yes',
  '-o', 'ConnectTimeout=15',
  $env:SSH_TARGET,
  "sudo rm -f $qFile"
)
if ($ec -ne 0) { exit $ec }

$ec2 = Invoke-HubSshBatch -Arguments @(
  '-p', $env:SSH_PORT,
  '-i', $env:SSH_KEY,
  '-o', 'BatchMode=yes',
  '-o', 'ConnectTimeout=15',
  $env:SSH_TARGET,
  "sudo caddy validate --config $qMainCfg && sudo systemctl reload caddy"
)
if ($ec2 -ne 0) { exit $ec2 }

Write-Host "OK: removed '${appName}'. If .\hub-tunnel.ps1 was running for this app, it should have exited."

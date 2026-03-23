# Register a new Hub route on EC2 (Caddy snippet + reload). Same behavior as hub-register.sh.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'hub-common.ps1')

$force = $false
$rest = New-Object System.Collections.ArrayList
foreach ($x in $args) { [void]$rest.Add([string]$x) }
while ($rest.Count -gt 0 -and $rest[0] -eq '--force') {
  $force = $true
  $rest.RemoveAt(0)
}

$appName = if ($rest.Count -gt 0) { [string]$rest[0] } else { '' }
if (-not $appName) {
  Write-Host "Usage: $($MyInvocation.MyCommand.Name) [--force] <AppName>" -ForegroundColor Red
  exit 1
}
if (-not (Test-HubAppName $appName)) { exit 1 }

$remotePort = if ($env:REMOTE_PORT) { [int]$env:REMOTE_PORT } else { Get-HubRemotePort -AppName $appName }
$remoteCaddyPath = "$($env:HUB_DIR.TrimEnd('/'))/${appName}.caddy"
$qRemoteFile = ConvertTo-BashSingleQuoted $remoteCaddyPath

if (-not $force) {
  $checkEc = Invoke-HubSshBatch -Arguments @(
    '-p', $env:SSH_PORT,
    '-i', $env:SSH_KEY,
    '-o', 'BatchMode=yes',
    '-o', 'ConnectTimeout=15',
    $env:SSH_TARGET,
    "sudo test -f $qRemoteFile"
  )
  if ($checkEc -eq 0) {
    Write-Host "hub-register: failed: route '${appName}' already exists on server ($remoteCaddyPath)." -ForegroundColor Red
    Write-Host "  Not changing Caddy or any SSH connection. Remove the remote file or run: $($MyInvocation.MyCommand.Name) --force ${appName}" -ForegroundColor Red
    exit 2
  }
  if ($checkEc -ne 1) {
    Write-Host "hub-register: failed: could not check remote route (ssh exit ${checkEc})." -ForegroundColor Red
    exit 1
  }
}

$snippet = @"
# ${appName} -> 127.0.0.1:${remotePort} (run: .\hub-tunnel.ps1 -Port <local> ${appName})
handle /${appName} {
	redir /${appName}/ permanent
}
handle_path /${appName}/* {
	reverse_proxy 127.0.0.1:${remotePort}
}
"@

Write-Host "Registering $($env:HUB_PUBLIC_URL)/${appName}/ -> EC2 127.0.0.1:${remotePort}"
Write-Host '--- snippet ---'
Write-Host $snippet
Write-Host '---'
Write-Host "Ensure $($env:MAIN_CFG) site block includes: import $($env:HUB_DIR)/*.caddy"
Write-Host ''

$qHubDir = ConvertTo-BashSingleQuoted $env:HUB_DIR
$qKeep = ConvertTo-BashSingleQuoted "$($env:HUB_DIR.TrimEnd('/'))/_keep.caddy"

$ecM = Invoke-HubSshBatch -Arguments @(
  '-p', $env:SSH_PORT,
  '-i', $env:SSH_KEY,
  '-o', 'BatchMode=yes',
  $env:SSH_TARGET,
  "sudo mkdir -p $qHubDir && (sudo test -f $qKeep || echo '#' | sudo tee $qKeep >/dev/null)"
)
if ($ecM -ne 0) { exit $ecM }

$b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($snippet))
$teeRemote = "printf '%s' '$b64' | base64 -d | sudo tee $qRemoteFile >/dev/null"
$ec = Invoke-HubSshBatch -Arguments @(
  '-p', $env:SSH_PORT,
  '-i', $env:SSH_KEY,
  '-o', 'BatchMode=yes',
  $env:SSH_TARGET,
  $teeRemote
)
if ($ec -ne 0) { exit $ec }

$qMainCfg = ConvertTo-BashSingleQuoted $env:MAIN_CFG
$ec2 = Invoke-HubSshBatch -Arguments @(
  '-p', $env:SSH_PORT,
  '-i', $env:SSH_KEY,
  '-o', 'BatchMode=yes',
  $env:SSH_TARGET,
  "sudo caddy validate --config $qMainCfg && sudo systemctl reload caddy"
)
if ($ec2 -ne 0) { exit $ec2 }

Write-Host "OK: ${remoteCaddyPath} installed and Caddy reloaded."

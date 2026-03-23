# Interactive SSH to the same host as hub-tunnel (reads `.env` via hub-common.ps1).
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'hub-common.ps1')

$remoteCmd = if ($env:REMOTE_CMD) { $env:REMOTE_CMD } else { 'cd ~/webTunnel && exec bash -l' }
$sshArgs = @(
  '-t',
  '-p', $env:SSH_PORT,
  '-i', $env:SSH_KEY,
  $env:SSH_TARGET,
  $remoteCmd
)
& ssh @sshArgs
if ($PSVersionTable.PSVersion.Major -ge 6) {
  exit $LASTEXITCODE
}
if (-not $?) { exit 1 }
exit 0

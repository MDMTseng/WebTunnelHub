# Hub status: local ssh -R + EC2 listeners + Caddy routes (same as hub-status.sh).
$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'hub-common.ps1')

$hostOnly = Get-HubSshHost

Write-Host "=== 本机：指向 $($env:SSH_TARGET) 且含 -R 的 ssh 进程 ==="
$found = $false
$procs = @(Get-CimInstance Win32_Process -Filter "Name = 'ssh.exe'" -ErrorAction SilentlyContinue)
foreach ($p in $procs) {
  $cmd = $p.CommandLine
  if ([string]::IsNullOrEmpty($cmd)) { continue }
  if ($cmd -notlike "*$hostOnly*") { continue }
  if ($cmd -notlike '*-R*') { continue }
  Write-Host $cmd
  $found = $true
}
if (-not $found) {
  Write-Host '(未发现；若隧道在另一台电脑或未运行，此处为空)'
}

Write-Host ''
Write-Host '=== EC2：根站 10080 + Hub 端口段 20000–29999 上的 LISTEN（需隧道连着才有）==='
$ssRemote = "ss -tlnp 2>/dev/null | grep 127.0.0.1 | grep -E ':(10080|2[0-9]{4})\b' || echo '(无匹配监听 — 可能本机隧道全未开)'"
& ssh -p $env:SSH_PORT -i $env:SSH_KEY -o BatchMode=yes -o ConnectTimeout=15 $env:SSH_TARGET $ssRemote
$ssEc = if ($PSVersionTable.PSVersion.Major -ge 6) { $LASTEXITCODE } else { if ($?) { 0 } else { 1 } }
if ($ssEc -ne 0) {
  Write-Host '(无法 SSH 到服务器)'
}

Write-Host ''
Write-Host '=== EC2：Caddy 已注册路径（磁盘上的配置；与隧道是否开启无关）==='

$assign = 'HUB_DIR=' + (ConvertTo-BashSingleQuoted $env:HUB_DIR)
$bashTpl = @'
shopt -s nullglob
__HUB_DIR_ASSIGN__
files=("$HUB_DIR"/*.caddy)
if ((${#files[@]} == 0)); then
  echo "(目录无 .caddy 文件: $HUB_DIR)"
  exit 0
fi
for f in "${files[@]}"; do
  base=$(basename "$f" .caddy)
  [[ "$base" == _keep ]] && continue
  rp=$(grep -E '^\s*reverse_proxy\s+' "$f" | head -1 | sed 's/^[[:space:]]*//')
  printf '%s -> %s\n' "$base" "${rp:-(无 reverse_proxy 行)}"
done
'@
$bashScript = $bashTpl.Replace('__HUB_DIR_ASSIGN__', $assign)
Invoke-HubRemoteBashScript -BashScript $bashScript -IgnoreExitCode

Write-Host ''
Write-Host '解读：'
Write-Host '  - 「回环监听」里有端口 = 当前至少有一条 SSH 反向转发连到 EC2 并在该端口监听。'
Write-Host '  - 「已注册路径」只表示 Caddy 会反代到该端口；若监听里没有对应端口，浏览器打开会失败或超时。'
Write-Host '  - 应用名与端口的对应关系也可本地算：python3 -c "import zlib; n=b''应用名''; print(20000+zlib.adler32(n)%10000)"'

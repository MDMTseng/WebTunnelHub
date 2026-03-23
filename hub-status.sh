#!/usr/bin/env bash
# Show Hub-related state: local SSH reverse tunnels + EC2 listeners + registered Caddy routes.
# Usage: ./hub-status.sh
# Config: `.env` (loaded via hub-common.sh)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=hub-common.sh
source "${SCRIPT_DIR}/hub-common.sh"

HOST_ONLY="$(hub_ssh_host)"

echo "=== 本机：指向 ${SSH_TARGET} 且含 -R 的 ssh 进程 ==="
if ps aux 2>/dev/null | grep -E "[s]sh .*" | grep -F -- "$HOST_ONLY" | grep -F -- '-R' | grep -v grep; then
	:
else
	echo "(未发现；若隧道在另一台电脑或未运行，此处为空)"
fi

echo ""
echo "=== EC2：根站 10080 + Hub 端口段 20000–29999 上的 LISTEN（需隧道连着才有）==="
if ssh -p "$SSH_PORT" -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=15 "$SSH_TARGET" \
	"ss -tlnp 2>/dev/null | grep 127.0.0.1 | grep -E ':(10080|2[0-9]{4})\b' || echo '(无匹配监听 — 可能本机隧道全未开)'"; then
	:
else
	echo "(无法 SSH 到服务器)"
fi

echo ""
echo "=== EC2：Caddy 已注册子域路由（磁盘上的配置；与隧道是否开启无关）==="
# shellcheck disable=SC2087
ssh -p "$SSH_PORT" -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=15 "$SSH_TARGET" \
	"export HUB_DIR=$(printf '%q' "$HUB_DIR"); bash -s" <<'REMOTE' || true
shopt -s nullglob
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
REMOTE

echo ""
echo "解读："
echo "  - 「回环监听」里有端口 = 当前至少有一条 SSH 反向转发连到 EC2 并在该端口监听。"
echo "  - 「已注册路径」只表示 Caddy 会反代到该端口；若监听里没有对应端口，浏览器打开会失败或超时。"
echo "  - 应用名与端口的对应关系与 hub-tunnel 一致：hub-common.sh 中 hub_remote_port（zlib Adler-32，与旧版 Python 公式相同）。"

#!/usr/bin/env bash
# Show Hub-related state: local SSH reverse tunnels + EC2 listeners + registered Caddy routes.
# Usage: ./hub-status.sh
# Config: `.env` (loaded via hub-common.sh)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=hub-common.sh
source "${SCRIPT_DIR}/hub-common.sh"

HOST_ONLY="$(hub_ssh_host)"

# Print SSH / empty-dir failure for the single EC2 fetch below. Returns 0 if printed, 1 if data is usable.
_hub_status_caddy_fetch_error() {
	case "${_hub_caddy_state:-}" in
		ssh_fail) echo "(无法 SSH 到服务器)" ;;
		no_files) echo "(目录无 .caddy 文件: ${_hub_no_dir})" ;;
		*) return 1 ;;
	esac
}

# One EC2 round-trip: app names (for hub_remote_port) + route lines for display.
set +e
_hub_caddy_out="$(
	ssh -p "$SSH_PORT" -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=15 "$SSH_TARGET" \
		"export HUB_DIR=$(printf '%q' "$HUB_DIR"); bash -s" <<'REMOTE'
shopt -s nullglob
files=("$HUB_DIR"/*.caddy)
if ((${#files[@]} == 0)); then
	printf 'E\t%s\n' "$HUB_DIR"
	exit 0
fi
for f in "${files[@]}"; do
	b=$(basename "$f" .caddy)
	[[ "$b" == _keep ]] && continue
	printf 'N\t%s\n' "$b"
	reg_note=""
	while IFS= read -r _line; do
		if [[ "$_line" =~ ^#\ Registration\ note:\ (.*)$ ]]; then
			reg_note="${BASH_REMATCH[1]}"
		elif [[ "$_line" =~ ^# ]]; then
			continue
		else
			break
		fi
	done < "$f"
	[[ -n "$reg_note" ]] && printf 'M\t%s\t%s\n' "${b,,}" "$reg_note"
	rp=$(grep -E '^\s*reverse_proxy\s+' "$f" | head -1 | sed 's/^[[:space:]]*//')
	rp="${rp//$'\t'/ }"
	printf 'R\t%s\t%s\n' "${b,,}" "${rp:-(无 reverse_proxy 行)}"
done
REMOTE
)"
_caddy_ec=$?
set -uo pipefail

REGISTERED_APPS=""
_ROUTES_DISPLAY=""
_hub_no_dir=""
declare -A _hub_reg_notes=()
while IFS= read -r line || [[ -n "$line" ]]; do
	line="${line%$'\r'}"
	[[ -z "$line" ]] && continue
	kind="${line%%$'\t'*}"
	rest="${line#*$'\t'}"
	case "$kind" in
		E)
			_hub_no_dir="$rest"
			;;
		N)
			REGISTERED_APPS+="${rest}"$'\n'
			;;
		M)
			_mbase="${rest%%$'\t'*}"
			_mnote="${rest#*$'\t'}"
			_hub_reg_notes["${_mbase}"]="$_mnote"
			;;
		R)
			_base="${rest%%$'\t'*}"
			_rp="${rest#*$'\t'}"
			_rsuffix=""
			[[ -n "${_hub_reg_notes[$_base]-}" ]] && _rsuffix="  # ${_hub_reg_notes[$_base]}"
			_ROUTES_DISPLAY+="${_base} -> ${_rp}${_rsuffix}"$'\n'
			;;
	esac
done <<<"$_hub_caddy_out"

_hub_caddy_state=ok
((_caddy_ec != 0)) && _hub_caddy_state=ssh_fail
[[ "$_hub_caddy_state" == ok && -n "$_hub_no_dir" ]] && _hub_caddy_state=no_files

echo "=== 已注册的 tunnel（应用）名（EC2 上 ${HUB_DIR}/*.caddy）==="
if _hub_status_caddy_fetch_error; then
	:
elif [[ -n "$REGISTERED_APPS" ]]; then
	while IFS= read -r _n || [[ -n "$_n" ]]; do
		[[ -z "$_n" ]] && continue
		printf '%s\n' "${_n,,}"
	done <<<"$REGISTERED_APPS" | sort -u
else
	echo "(无已注册应用)"
fi

echo ""
echo "=== 本机：指向 ${SSH_TARGET} 且含 -R 的 ssh 进程 ==="
_tunnel_ps="$(ps aux 2>/dev/null | grep -E "[s]sh .*" | grep -F -- "$HOST_ONLY" | grep -F -- '-R' | grep -v grep || true)"
if [[ -n "$_tunnel_ps" ]]; then
	printf '%s\n' "$_tunnel_ps"
else
	echo "(未发现；若隧道在另一台电脑或未运行，此处为空)"
fi

echo ""
echo "=== 本机活动 tunnel 名（由 -R 端口推断；10080 = 默认站点）==="
if [[ -z "$_tunnel_ps" ]]; then
	echo "(无)"
else
	declare -A _hub_seen_rport=()
	while IFS= read -r pline || [[ -n "$pline" ]]; do
		[[ -z "$pline" ]] && continue
		rport="" lport=""
		if [[ "$pline" =~ -R[[:space:]]+([0-9.]+):([0-9]+):127\.0\.0\.1:([0-9]+) ]]; then
			rport="${BASH_REMATCH[2]}"
			lport="${BASH_REMATCH[3]}"
		elif [[ "$pline" =~ -R[[:space:]]+([0-9]+):127\.0\.0\.1:([0-9]+) ]]; then
			rport="${BASH_REMATCH[1]}"
			lport="${BASH_REMATCH[2]}"
		fi
		[[ -z "$rport" ]] && continue
		[[ -n "${_hub_seen_rport[$rport]:-}" ]] && continue
		_hub_seen_rport[$rport]=1
		if [[ "$rport" == "10080" ]]; then
			printf '%s（本机 %s）\n' "default" "$lport"
			continue
		fi
		_matched=()
		if [[ "$_hub_caddy_state" == ok && -n "$REGISTERED_APPS" ]]; then
			while IFS= read -r app || [[ -n "$app" ]]; do
				[[ -z "$app" ]] && continue
				_rp="$(hub_remote_port "$app")"
				[[ "$_rp" == "$rport" ]] && _matched+=("${app,,}")
			done <<<"$REGISTERED_APPS"
		fi
		if ((${#_matched[@]})); then
			printf '%s（EC2 :%s，本机 %s）\n' "$(IFS=','; echo "${_matched[*]}")" "$rport" "$lport"
		else
			printf '(未匹配已注册名)（EC2 :%s，本机 %s）\n' "$rport" "$lport"
		fi
	done <<<"$_tunnel_ps"
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
if _hub_status_caddy_fetch_error; then
	:
elif [[ -n "$_ROUTES_DISPLAY" ]]; then
	printf '%s' "$_ROUTES_DISPLAY"
else
	echo "(无路由条目)"
fi

echo ""
echo "解读："
echo "  - 「已注册的 tunnel 名」来自 EC2 上路由文件名；显示为小写，实际注册名大小写与磁盘一致（哈希端口按原名计算）。"
echo "  - 「本机活动 tunnel 名」由当前 ssh -R 的远端端口对照 hub_remote_port 推断；用了 REMOTE_PORT 覆盖时可能显示未匹配。"
echo "  - 「回环监听」里有端口 = 当前至少有一条 SSH 反向转发连到 EC2 并在该端口监听。"
echo "  - 「已注册路径」只表示 Caddy 会反代到该端口；若监听里没有对应端口，浏览器打开会失败或超时。"
echo "  - 行末「# …」为 hub-register.sh --note 写入的 Registration note（片段首行注释）。"
echo "  - 应用名与端口的对应关系与 hub-tunnel 一致：hub-common.sh 中 hub_remote_port（zlib Adler-32，与旧版 Python 公式相同）。"

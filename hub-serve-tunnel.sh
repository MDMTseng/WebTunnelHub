#!/usr/bin/env bash
# hub-serve-tunnel.sh — Minimal local HTTP (serve.py) + SSH reverse tunnel in one command.
#
# Foreground: hub-tunnel (Ctrl+C stops tunnel and cleans up serve.py).
# Logs: logs/hub-serve-<app|root>.log
#
# Usage:
#   ./hub-serve-tunnel.sh                    Legacy: PORT/8080 -> EC2 10080 without AppName (discouraged; see hub-tunnel.sh)
#   ./hub-serve-tunnel.sh myapp            serve.py on 8080 + tunnel for Hub app myapp
#   ./hub-serve-tunnel.sh --port 5654 myapp
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=hub-common.sh
source "${SCRIPT_DIR}/hub-common.sh"

usage() {
	cat <<'EOF'
Usage:
  ./hub-serve-tunnel.sh                     Legacy: serve.py :8080 + tunnel -> EC2 :10080 (no AppName; discouraged)
  ./hub-serve-tunnel.sh <AppName>         serve.py :8080 + Hub tunnel for <AppName>
  ./hub-serve-tunnel.sh --port 5654 <App> Custom local port (register the same name first)

Requires: python3 (or python), .env with SSH_* and HUB_PUBLIC_URL (see hub-common.sh).
EOF
}

LOCAL_PORT="${PORT:-8080}"
APP_NAME=""

while [[ $# -gt 0 ]]; do
	case "$1" in
		-h | --help)
			usage
			exit 0
			;;
		-p | --port)
			if [[ -z "${2:-}" ]]; then
				echo "hub-serve-tunnel: $1 requires a port." >&2
				exit 1
			fi
			LOCAL_PORT="$2"
			shift 2
			;;
		-*)
			echo "hub-serve-tunnel: unknown option: $1" >&2
			usage >&2
			exit 1
			;;
		*)
			if [[ -n "$APP_NAME" ]]; then
				echo "hub-serve-tunnel: unexpected argument: $1" >&2
				usage >&2
				exit 1
			fi
			APP_NAME="$1"
			shift
			;;
	esac
done

if [[ -n "$APP_NAME" ]]; then
	hub_validate_app_name "$APP_NAME" || exit 1
fi

if command -v python3 >/dev/null 2>&1; then
	_PY=python3
elif command -v python >/dev/null 2>&1; then
	_PY=python
else
	echo "hub-serve-tunnel: need python3 or python in PATH." >&2
	exit 1
fi

_log_dir="${HUB_TUNNEL_LOG_DIR:-logs}"
mkdir -p "$_log_dir"
_tag="${APP_NAME:-root}"
_serve_log="${_log_dir}/hub-serve-${_tag}.log"
SERVE_PID=""

cleanup() {
	if [[ -n "${SERVE_PID:-}" ]] && kill -0 "$SERVE_PID" 2>/dev/null; then
		kill "$SERVE_PID" 2>/dev/null || true
		wait "$SERVE_PID" 2>/dev/null || true
	fi
}
trap cleanup EXIT INT TERM

export PORT="$LOCAL_PORT"
export HELLO_TITLE="${HELLO_TITLE:-WebTunnelHub (${_tag})}"
echo "hub-serve-tunnel: starting ${_PY} serve.py on 127.0.0.1:${LOCAL_PORT} (log: ${_serve_log})" >&2
"$_PY" "${SCRIPT_DIR}/serve.py" >>"$_serve_log" 2>&1 &
SERVE_PID=$!

if ! hub_wait_local_http "$LOCAL_PORT" 40; then
	echo "hub-serve-tunnel: local HTTP did not become ready on port ${LOCAL_PORT} (see ${_serve_log})." >&2
	exit 1
fi

_tunnel_ec=0
if [[ -n "$APP_NAME" ]]; then
	_rp="${REMOTE_PORT:-$(hub_remote_port "$APP_NAME")}"
	echo "hub-serve-tunnel: local OK; starting tunnel -> EC2 127.0.0.1:${_rp} (public: $(hub_app_public_url "${APP_NAME}")…)" >&2
	echo "hub-serve-tunnel: ensure ./hub-register.sh --note '…' ${APP_NAME} was run once on EC2." >&2
	"${SCRIPT_DIR}/hub-tunnel.sh" --port "$LOCAL_PORT" "$APP_NAME" || _tunnel_ec=$?
else
	echo "hub-serve-tunnel: local OK; starting legacy root tunnel -> EC2 ${REMOTE_BIND:-127.0.0.1}:10080 (prefer passing AppName)" >&2
	"${SCRIPT_DIR}/hub-tunnel.sh" --port "$LOCAL_PORT" || _tunnel_ec=$?
fi
cleanup
trap - EXIT INT TERM
exit "$_tunnel_ec"

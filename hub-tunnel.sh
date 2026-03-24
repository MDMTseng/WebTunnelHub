#!/usr/bin/env bash
# hub-tunnel.sh — SSH reverse tunnel from this machine to EC2 (Hub app or legacy root path).
#
# No app name: local 127.0.0.1:PORT (default 8080) -> EC2 REMOTE_BIND:10080 (legacy; discouraged for new services).
# With app name: local port -> EC2 REMOTE_BIND:hub_remote_port(AppName) (run hub-register first).
#
# Direct HTTP on EC2 :1080 without Caddy: REMOTE_BIND=0.0.0.0 REMOTE_PORT=1080 ./hub-tunnel.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=hub-common.sh
source "${SCRIPT_DIR}/hub-common.sh"

REMOTE_BIND="${REMOTE_BIND:-127.0.0.1}"

usage() {
	cat <<'EOF'
Usage:
  ./hub-tunnel.sh                          Legacy root path: local PORT/8080 -> EC2 127.0.0.1:10080 (discouraged)
  ./hub-tunnel.sh --port 3422 myapp        Hub app: local 3422 -> EC2 127.0.0.1:<derived>
  ./hub-tunnel.sh myapp --port 3422        Same (flags and app name order are flexible)
  ./hub-tunnel.sh -b --port 5654 myapp     Background (nohup + log under logs/)

Environment:
  See `.env` / `.env.example` for SSH_TARGET, SSH_KEY, SSH_PORT, HUB_PUBLIC_URL.
  Optional: PORT, REMOTE_BIND, REMOTE_PORT (override Hub auto port)
  Optional: HUB_TUNNEL_LOG_DIR (default: logs) for --background log path
EOF
}

LOCAL_PORT="${PORT:-8080}"
APP_NAME=""
BACKGROUND=0

while [[ $# -gt 0 ]]; do
	case "$1" in
		-b | --background)
			BACKGROUND=1
			shift
			;;
		-p | --port)
			if [[ -z "${2:-}" ]]; then
				echo "hub-tunnel: $1 requires a port value." >&2
				exit 1
			fi
			LOCAL_PORT="$2"
			shift 2
			;;
		-h | --help)
			usage
			exit 0
			;;
		-*)
			echo "hub-tunnel: unknown option: $1" >&2
			usage >&2
			exit 1
			;;
		*)
			if [[ -n "$APP_NAME" ]]; then
				echo "hub-tunnel: unexpected argument: $1" >&2
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
	REMOTE_PORT="${REMOTE_PORT:-$(hub_remote_port "$APP_NAME")}"
	echo "hub-tunnel: Hub app '${APP_NAME}' public URL $(hub_app_public_url "${APP_NAME}")"
	echo "hub-tunnel: forward EC2 127.0.0.1:${REMOTE_PORT} -> local 127.0.0.1:${LOCAL_PORT}"
	echo "hub-tunnel: if not registered yet, run ./hub-register.sh with an all-lowercase name matching this tunnel."
else
	REMOTE_PORT="${REMOTE_PORT:-10080}"
	echo "hub-tunnel: legacy root path: local 127.0.0.1:${LOCAL_PORT} -> EC2 ${REMOTE_BIND}:${REMOTE_PORT} (prefer Hub: use an AppName)"
fi

echo "hub-tunnel: connecting to ${SSH_TARGET} (keep this process running; public access stops if it exits)."
echo "hub-tunnel: for raw HTTP tests: REMOTE_BIND=0.0.0.0 REMOTE_PORT=1080 $0"
echo ""

SSH_CMD=(ssh -N
	-p "$SSH_PORT"
	-i "$SSH_KEY"
	-o ServerAliveInterval=30
	-o ServerAliveCountMax=3
	-o ExitOnForwardFailure=yes
	-o TCPKeepAlive=yes)
if [[ -n "${SSH_OPTS:-}" ]]; then
	# shellcheck disable=SC2206
	read -r -a _ssh_extra <<<"$SSH_OPTS"
	SSH_CMD+=("${_ssh_extra[@]}")
fi
SSH_CMD+=(-R "${REMOTE_BIND}:${REMOTE_PORT}:127.0.0.1:${LOCAL_PORT}" "$SSH_TARGET")

if [[ "$BACKGROUND" -eq 1 ]]; then
	_log_dir="${HUB_TUNNEL_LOG_DIR:-logs}"
	_tag="${APP_NAME:-default}"
	_log="${_log_dir}/hub-tunnel-${_tag}.log"
	echo "hub-tunnel: background mode; logging to ${_log}" >&2
	hub_background_log "$_log" "${SSH_CMD[@]}"
	echo "hub-tunnel: ssh started in background (see ${_log}). Use hub-status.sh to inspect -R sessions." >&2
	exit 0
fi

exec "${SSH_CMD[@]}"

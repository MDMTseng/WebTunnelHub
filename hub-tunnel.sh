#!/usr/bin/env bash
# Reverse SSH tunnel to EC2 (Hub or single default site).
#
# Default (no app name): EC2 127.0.0.1:10080 -> local :8080 (Caddy root -> 10080).
# Hub: ./hub-tunnel.sh --port 3422 CoolApp  ->  EC2 127.0.0.1:<derived> -> local :3422
#   Register Caddy subdomain once: ./hub-register.sh CoolApp
#
# Direct HTTP on EC2 :1080 (no Caddy): REMOTE_BIND=0.0.0.0 REMOTE_PORT=1080 ./hub-tunnel.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=hub-common.sh
source "${SCRIPT_DIR}/hub-common.sh"

REMOTE_BIND="${REMOTE_BIND:-127.0.0.1}"

usage() {
	cat <<'EOF'
Usage:
  ./hub-tunnel.sh                          Default site: local PORT/8080 -> EC2 127.0.0.1:10080
  ./hub-tunnel.sh --port 3422 CoolApp     Hub app:      local 3422       -> EC2 127.0.0.1:<auto>
  ./hub-tunnel.sh CoolApp --port 3422     Same (flags and name order flexible)

Environment:
  See `.env` / `.env.example` for SSH_TARGET, SSH_KEY, SSH_PORT, HUB_PUBLIC_URL.
  PORT, REMOTE_BIND, REMOTE_PORT (override auto port for Hub)
EOF
}

LOCAL_PORT="${PORT:-8080}"
APP_NAME=""

while [[ $# -gt 0 ]]; do
	case "$1" in
		-p | --port)
			[[ -n "${2:-}" ]] || { echo "Missing value for $1"; exit 1; }
			LOCAL_PORT="$2"
			shift 2
			;;
		-h | --help)
			usage
			exit 0
			;;
		-*)
			echo "Unknown option: $1" >&2
			usage >&2
			exit 1
			;;
		*)
			[[ -z "$APP_NAME" ]] || { echo "Extra argument: $1" >&2; exit 1; }
			APP_NAME="$1"
			shift
			;;
	esac
done

if [[ -n "$APP_NAME" ]]; then
	hub_validate_app_name "$APP_NAME" || exit 1
	REMOTE_PORT="${REMOTE_PORT:-$(hub_remote_port "$APP_NAME")}"
	echo "Hub app '${APP_NAME}': $(hub_app_public_url "${APP_NAME}")"
	echo "EC2 loopback ${REMOTE_PORT} -> local 127.0.0.1:${LOCAL_PORT}"
	echo "If not done yet: ./hub-register.sh ${APP_NAME}"
else
	REMOTE_PORT="${REMOTE_PORT:-10080}"
	echo "Default site: local 127.0.0.1:${LOCAL_PORT} -> EC2 ${REMOTE_BIND}:${REMOTE_PORT}"
fi

echo "SSH ${SSH_TARGET} (leave running). Direct mode: REMOTE_BIND=0.0.0.0 REMOTE_PORT=1080 $0"
echo ""

exec ssh -N \
	-p "$SSH_PORT" \
	-i "$SSH_KEY" \
	-o ServerAliveInterval=30 \
	-o ServerAliveCountMax=3 \
	-R "${REMOTE_BIND}:${REMOTE_PORT}:127.0.0.1:${LOCAL_PORT}" \
	"$SSH_TARGET"

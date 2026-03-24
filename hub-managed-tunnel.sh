#!/usr/bin/env bash
# hub-managed-tunnel.sh — Register a Hub app, then start the SSH reverse tunnel (local port -> hub host).
# "Managed" = route + remote port are owned by hub-register; tunnel targets that assignment.
# Run from repo root after the local HTTP server is listening (see example/start.sh).
set -euo pipefail

SCRIPT_TAG='hub-managed-tunnel'
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=hub-common.sh
source "${SCRIPT_DIR}/hub-common.sh"

usage() {
	cat <<'EOF'
Usage:
  ./hub-managed-tunnel.sh --name <AppName> --note <text> --port <localPort>

Registers the route on the hub (hub-register.sh), then runs hub-tunnel.sh in the
background and waits (like example/start.sh, but it does not start a local server for you).

Environment: same as other hub scripts (.env / SSH_*, HUB_PUBLIC_URL).
EOF
}

APP_NAME=""
REG_NOTE=""
LOCAL_PORT=""

while [[ $# -gt 0 ]]; do
	case "$1" in
		-h | --help)
			usage
			exit 0
			;;
		--name=*)
			APP_NAME="${1#--name=}"
			if [[ -z "$APP_NAME" ]]; then
				echo "${SCRIPT_TAG}: --name= requires a non-empty value." >&2
				exit 1
			fi
			shift
			;;
		--name)
			if [[ -z "${2:-}" ]]; then
				echo "${SCRIPT_TAG}: $1 requires a value." >&2
				exit 1
			fi
			APP_NAME="$2"
			shift 2
			;;
		--note=*)
			REG_NOTE="${1#--note=}"
			if [[ -z "$REG_NOTE" ]]; then
				echo "${SCRIPT_TAG}: --note= requires a non-empty value." >&2
				exit 1
			fi
			shift
			;;
		--note)
			if [[ -z "${2:-}" ]]; then
				echo "${SCRIPT_TAG}: $1 requires a value." >&2
				exit 1
			fi
			REG_NOTE="$2"
			shift 2
			;;
		--port=*)
			LOCAL_PORT="${1#--port=}"
			if [[ -z "$LOCAL_PORT" ]]; then
				echo "${SCRIPT_TAG}: --port= requires a non-empty value." >&2
				exit 1
			fi
			shift
			;;
		--port)
			if [[ -z "${2:-}" ]]; then
				echo "${SCRIPT_TAG}: $1 requires a value." >&2
				exit 1
			fi
			LOCAL_PORT="$2"
			shift 2
			;;
		-*)
			echo "${SCRIPT_TAG}: unknown option: $1" >&2
			usage >&2
			exit 1
			;;
		*)
			echo "${SCRIPT_TAG}: unexpected argument: $1" >&2
			usage >&2
			exit 1
			;;
	esac
done

if [[ -z "$APP_NAME" || -z "$REG_NOTE" || -z "$LOCAL_PORT" ]]; then
	echo "${SCRIPT_TAG}: --name, --note, and --port are required." >&2
	usage >&2
	exit 1
fi

cd "$SCRIPT_DIR"

set +e
./hub-register.sh --note "$REG_NOTE" "$APP_NAME"
_reg=$?
set -e
if [[ "$_reg" -eq 2 ]]; then
	echo "${SCRIPT_TAG}: ${APP_NAME} is already registered on the hub." >&2
	echo "  Remove the existing route, then run again:  ./hub-unregister.sh ${APP_NAME}" >&2
	exit 2
fi
if [[ "$_reg" -ne 0 ]]; then
	echo "${SCRIPT_TAG}: hub-register.sh failed (exit ${_reg}). Check .env, SSH key, and SSH_TARGET." >&2
	exit "$_reg"
fi

_HUB_REGISTERED=1
TUNNEL_PID=""
cleanup_tunnel() {
	if [[ -n "${TUNNEL_PID:-}" ]]; then
		kill "$TUNNEL_PID" 2>/dev/null || true
		wait "$TUNNEL_PID" 2>/dev/null || true
	fi
}

on_interrupt() {
	trap - EXIT INT TERM
	cleanup_tunnel
	if [[ "${UNREGISTER_ON_INTERRUPT:-1}" -eq 1 && "${_HUB_REGISTERED:-0}" -eq 1 ]]; then
		echo "${SCRIPT_TAG}: interrupt — unregistering ${APP_NAME} on the hub." >&2
		set +e
		./hub-unregister.sh "$APP_NAME"
		_u=$?
		set -e
		[[ "$_u" -eq 0 ]] || echo "${SCRIPT_TAG}: hub-unregister.sh failed (exit ${_u}); run ./hub-unregister.sh ${APP_NAME} manually." >&2
	fi
	exit 130
}

trap on_interrupt INT TERM
trap cleanup_tunnel EXIT

_ec=0
./hub-tunnel.sh --port "$LOCAL_PORT" "$APP_NAME" &
TUNNEL_PID=$!
wait "$TUNNEL_PID" || _ec=$?
trap - EXIT INT TERM
cleanup_tunnel
exit "$_ec"

#!/usr/bin/env bash
# Register a new Hub route on EC2 (Caddy snippet + reload). Fails if the app name is already registered.
# App name: see hub_validate_register_app_name in hub-common.sh (lowercase-only).
# Does not stop or alter existing SSH tunnels.
# Exit codes: 0 ok, 1 usage/ssh/caddy error, 2 duplicate route (file already on server).
#
# Usage: ./hub-register.sh [--force] [--note|-n <text>] <AppName>
#   --force       Overwrite existing /etc/caddy/hub-routes/<AppName>.caddy (still reloads Caddy only if write succeeds).
#   --note / -n   Optional note (who/where/when); stored in the snippet and shown by hub-status.sh.
#
# Remote needs: top-level "import HUB_DIR/*.caddy" + root site (see Caddyfile.ec2.example). Configure SSH/HUB_* in `.env`.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=hub-common.sh
source "${SCRIPT_DIR}/hub-common.sh"

FORCE=0
REG_NOTE=""
while (($#)); do
	case "$1" in
		--force)
			FORCE=1
			shift
			;;
		--note|-n)
			_note_flag="$1"
			shift
			if [[ -z "${1:-}" ]]; then
				echo "hub-register: ${_note_flag} requires text (e.g. $0 ${_note_flag} 'from laptop' myapp)." >&2
				exit 1
			fi
			REG_NOTE="$1"
			shift
			;;
		-*)
			echo "hub-register: unknown option: $1" >&2
			echo "Usage: $0 [--force] [--note|-n <text>] <AppName>" >&2
			exit 1
			;;
		*)
			break
			;;
	esac
done

APP_NAME="${1:-}"
[[ -n "$APP_NAME" ]] || { echo "Usage: $0 [--force] [--note|-n <text>] <AppName>"; exit 1; }
shift
[[ $# -eq 0 ]] || {
	echo "hub-register: unexpected arguments: $*" >&2
	echo "Usage: $0 [--force] [--note|-n <text>] <AppName>" >&2
	exit 1
}
hub_validate_register_app_name "$APP_NAME"

[[ -z "$REG_NOTE" && -n "${HUB_REGISTER_NOTE:-}" ]] && REG_NOTE="$HUB_REGISTER_NOTE"
if [[ -n "$REG_NOTE" ]]; then
	REG_NOTE="$(hub_sanitize_register_note "$REG_NOTE")"
fi

REMOTE_PORT="${REMOTE_PORT:-$(hub_remote_port "$APP_NAME")}"

if [[ "$FORCE" -eq 0 ]]; then
	set +e
	ssh -p "$SSH_PORT" -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=15 "$SSH_TARGET" \
		"sudo test -f '${HUB_DIR}/${APP_NAME}.caddy'"
	check_ec=$?
	set -e
	if [[ "$check_ec" -eq 0 ]]; then
		echo "hub-register: failed: route '${APP_NAME}' already exists on server (${HUB_DIR}/${APP_NAME}.caddy)." >&2
		echo "  Not changing Caddy or any SSH connection. Remove the remote file or run: $0 [--note ...] --force ${APP_NAME}" >&2
		exit 2
	fi
	if [[ "$check_ec" -ne 1 ]]; then
		echo "hub-register: failed: could not check remote route (ssh exit ${check_ec})." >&2
		exit 1
	fi
fi

SNIPPET=""
if [[ -n "$REG_NOTE" ]]; then
	SNIPPET="# Registration note: ${REG_NOTE}"$'\n'
fi
SNIPPET+="# ${APP_NAME} -> 127.0.0.1:${REMOTE_PORT} (run: ./hub-tunnel.sh --port <local> ${APP_NAME})"$'\n'
SNIPPET+="${APP_NAME}.${HUB_PUBLIC_HOST}:${HUB_PUBLIC_PORT} {"$'\n'
SNIPPET+=$'\t'"reverse_proxy 127.0.0.1:${REMOTE_PORT}"$'\n'
SNIPPET+="}"

echo "Registering $(hub_app_public_url "${APP_NAME}") (Host: ${APP_NAME}.${HUB_PUBLIC_HOST}:${HUB_PUBLIC_PORT}) -> EC2 127.0.0.1:${REMOTE_PORT}"
echo "--- snippet ---"
echo "$SNIPPET"
echo "---"
echo "Ensure ${MAIN_CFG} matches Caddyfile.ec2.example: root site ${HUB_PUBLIC_HOST}:${HUB_PUBLIC_PORT} { handle { reverse_proxy 127.0.0.1:10080 } }"
echo "  and a top-level line (outside that block): import ${HUB_DIR}/*.caddy"
echo "DNS: ${APP_NAME}.${HUB_PUBLIC_HOST} (or wildcard *.${HUB_PUBLIC_HOST}) must resolve to this server."
echo ""

ssh -p "$SSH_PORT" -i "$SSH_KEY" -o BatchMode=yes "$SSH_TARGET" \
	"sudo mkdir -p '${HUB_DIR}' && (sudo test -f '${HUB_DIR}/_keep.caddy' || echo '#' | sudo tee '${HUB_DIR}/_keep.caddy' >/dev/null)"

printf '%s\n' "$SNIPPET" | ssh -p "$SSH_PORT" -i "$SSH_KEY" -o BatchMode=yes "$SSH_TARGET" \
	"sudo tee ${HUB_DIR}/${APP_NAME}.caddy >/dev/null"

ssh -p "$SSH_PORT" -i "$SSH_KEY" -o BatchMode=yes "$SSH_TARGET" \
	"sudo caddy validate --config ${MAIN_CFG} && sudo systemctl reload caddy"

if [[ -n "$REG_NOTE" ]]; then
	echo "OK: ${HUB_DIR}/${APP_NAME}.caddy installed and Caddy reloaded (note saved)."
else
	echo "OK: ${HUB_DIR}/${APP_NAME}.caddy installed and Caddy reloaded."
fi

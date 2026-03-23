#!/usr/bin/env bash
# Remove a Hub app from EC2 (delete Caddy snippet, reload) and stop local ssh -R for that app's port.
# The foreground ./hub-tunnel.sh process will exit with an error when its ssh child is killed — that is expected.
#
# Usage: ./hub-unregister.sh [--no-kill] <AppName>
#   --no-kill   Only remove Caddy file + reload; do not kill local ssh (you stop tunnel yourself).
#
# If you overrode REMOTE_PORT when registering, set the same REMOTE_PORT here so we kill the right ssh.
# Env: see `.env` / `.env.example`; REMOTE_PORT optional override
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=hub-common.sh
source "${SCRIPT_DIR}/hub-common.sh"

NO_KILL=0
while [[ "${1:-}" == "--no-kill" ]]; do
	NO_KILL=1
	shift
done

APP_NAME="${1:-}"
[[ -n "$APP_NAME" ]] || { echo "Usage: $0 [--no-kill] <AppName>"; exit 1; }
hub_validate_app_name "$APP_NAME"

REMOTE_PORT="${REMOTE_PORT:-$(hub_remote_port "$APP_NAME")}"

if [[ "$NO_KILL" -eq 0 ]]; then
	hub_kill_tunnels_for_remote_port "$REMOTE_PORT"
else
	echo "Skipping local ssh kill (--no-kill)." >&2
fi

echo "Removing ${HUB_DIR}/${APP_NAME}.caddy on ${SSH_TARGET} ..."
ssh -p "$SSH_PORT" -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=15 "$SSH_TARGET" \
	"sudo rm -f '${HUB_DIR}/${APP_NAME}.caddy'"

ssh -p "$SSH_PORT" -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=15 "$SSH_TARGET" \
	"sudo caddy validate --config ${MAIN_CFG} && sudo systemctl reload caddy"

echo "OK: removed '${APP_NAME}'. If ./hub-tunnel.sh was running in a terminal for this app, it should have exited (broken pipe / ssh died)."

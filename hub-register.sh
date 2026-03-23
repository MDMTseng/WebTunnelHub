#!/usr/bin/env bash
# Register a new Hub route on EC2 (Caddy snippet + reload). Fails if the app name is already registered.
# Does not stop or alter existing SSH tunnels.
# Exit codes: 0 ok, 1 usage/ssh/caddy error, 2 duplicate route (file already on server).
#
# Usage: ./hub-register.sh [--force] <AppName>
#   --force  Overwrite existing /etc/caddy/hub-routes/<AppName>.caddy (still reloads Caddy only if write succeeds).
#
# Remote needs: top-level "import HUB_DIR/*.caddy" + root site (see Caddyfile.ec2.example). Configure SSH/HUB_* in `.env`.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=hub-common.sh
source "${SCRIPT_DIR}/hub-common.sh"

FORCE=0
while [[ "${1:-}" == "--force" ]]; do
	FORCE=1
	shift
done

APP_NAME="${1:-}"
[[ -n "$APP_NAME" ]] || { echo "Usage: $0 [--force] <AppName>"; exit 1; }
hub_validate_app_name "$APP_NAME"

REMOTE_PORT="${REMOTE_PORT:-$(hub_remote_port "$APP_NAME")}"

if [[ "$FORCE" -eq 0 ]]; then
	set +e
	ssh -p "$SSH_PORT" -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=15 "$SSH_TARGET" \
		"sudo test -f '${HUB_DIR}/${APP_NAME}.caddy'"
	check_ec=$?
	set -e
	if [[ "$check_ec" -eq 0 ]]; then
		echo "hub-register: failed: route '${APP_NAME}' already exists on server (${HUB_DIR}/${APP_NAME}.caddy)." >&2
		echo "  Not changing Caddy or any SSH connection. Remove the remote file or run: $0 --force ${APP_NAME}" >&2
		exit 2
	fi
	if [[ "$check_ec" -ne 1 ]]; then
		echo "hub-register: failed: could not check remote route (ssh exit ${check_ec})." >&2
		exit 1
	fi
fi

SNIPPET=$(
	cat <<EOF
# ${APP_NAME} -> 127.0.0.1:${REMOTE_PORT} (run: ./hub-tunnel.sh --port <local> ${APP_NAME})
${APP_NAME}.${HUB_PUBLIC_HOST}:${HUB_PUBLIC_PORT} {
	reverse_proxy 127.0.0.1:${REMOTE_PORT}
}
EOF
)

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

echo "OK: ${HUB_DIR}/${APP_NAME}.caddy installed and Caddy reloaded."

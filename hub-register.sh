#!/usr/bin/env bash
# hub-register.sh — Register a Hub subdomain route on the hub host (Caddy snippet + reload).
#
# Does not start or modify local SSH tunnels.
# Exit codes: 0 success; 1 usage/validation/SSH/Caddy failure; 2 route file already exists without --force.
#
# Usage: ./hub-register.sh [--force] --note|-n <text> <AppName>
#   --force     Overwrite existing ${HUB_DIR}/<AppName>.caddy on the server.
#   --note / -n Required. Stored in the snippet; shown by hub-status.sh. After sanitization, must contain at least 5 ASCII letters.
#
# Remote: main Caddyfile must top-level import ${HUB_DIR}/*.caddy; legacy handle->10080 may exist (see Caddyfile.hub.example).
# App name: hub_validate_register_app_name in hub-common.sh (lowercase only).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=hub-common.sh
source "${SCRIPT_DIR}/hub-common.sh"

FORCE=0
REG_NOTE=""
NOTE_FROM_CLI=0
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
				echo "hub-register: ${_note_flag} requires a value. Example: $0 ${_note_flag} 'ops laptop' myapp" >&2
				exit 1
			fi
			REG_NOTE="$1"
			NOTE_FROM_CLI=1
			shift
			;;
		-*)
			echo "hub-register: unknown option: $1" >&2
			echo "hub-register: usage: $0 [--force] --note|-n <text> <AppName>" >&2
			exit 1
			;;
		*)
			break
			;;
	esac
done

APP_NAME="${1:-}"
if [[ -z "$APP_NAME" ]]; then
	echo "hub-register: usage: $0 [--force] --note|-n <text> <AppName>" >&2
	exit 1
fi
shift
if [[ $# -gt 0 ]]; then
	echo "hub-register: unexpected arguments: $*" >&2
	echo "hub-register: usage: $0 [--force] --note|-n <text> <AppName>" >&2
	exit 1
fi
hub_validate_register_app_name "$APP_NAME" || exit 1

if [[ "$NOTE_FROM_CLI" -eq 0 ]]; then
	echo "hub-register: --note or -n is required (registration audit trail)." >&2
	echo "hub-register: usage: $0 [--force] --note|-n <text> <AppName>" >&2
	exit 1
fi

REG_NOTE="$(hub_sanitize_register_note "$REG_NOTE")"
if [[ -z "$REG_NOTE" ]]; then
	echo "hub-register: note must not be empty after sanitization." >&2
	exit 1
fi
hub_validate_register_note_text "$REG_NOTE" || exit 1

REMOTE_PORT="${REMOTE_PORT:-$(hub_remote_port "$APP_NAME")}"

if [[ "$FORCE" -eq 0 ]]; then
	set +e
	ssh -p "$SSH_PORT" -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=15 "$SSH_TARGET" \
		"sudo test -f '${HUB_DIR}/${APP_NAME}.caddy'"
	check_ec=$?
	set -e
	if [[ "$check_ec" -eq 0 ]]; then
		echo "hub-register: route already exists on server: ${HUB_DIR}/${APP_NAME}.caddy (no changes made)." >&2
		exit 2
	fi
	if [[ "$check_ec" -ne 1 ]]; then
		echo "hub-register: could not check remote route (SSH exit ${check_ec}). Verify network, key, and SSH_TARGET." >&2
		exit 1
	fi
fi

SNIPPET="# Registration note: ${REG_NOTE}"$'\n'
SNIPPET+="# ${APP_NAME} -> 127.0.0.1:${REMOTE_PORT} (run: ./hub-tunnel.sh --port <local> ${APP_NAME})"$'\n'
SNIPPET+="${APP_NAME}.${HUB_PUBLIC_HOST}:${HUB_PUBLIC_PORT} {"$'\n'
SNIPPET+=$'\t'"reverse_proxy 127.0.0.1:${REMOTE_PORT}"$'\n'
SNIPPET+="}"

echo "hub-register: registering $(hub_app_public_url "${APP_NAME}")"
echo "hub-register: site ${APP_NAME}.${HUB_PUBLIC_HOST}:${HUB_PUBLIC_PORT} -> hub 127.0.0.1:${REMOTE_PORT}"
echo "hub-register: --- snippet preview ---"
echo "$SNIPPET"
echo "hub-register: --- end preview ---"
echo "hub-register: ensure ${MAIN_CFG} matches Caddyfile.hub.example (legacy handle reverse_proxy 127.0.0.1:10080 optional; top-level import ${HUB_DIR}/*.caddy)."
echo "hub-register: DNS must resolve ${APP_NAME}.${HUB_PUBLIC_HOST} (or *.${HUB_PUBLIC_HOST}) to this server."
echo ""

set +e
ssh -p "$SSH_PORT" -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=15 "$SSH_TARGET" \
	"sudo mkdir -p '${HUB_DIR}' && (sudo test -f '${HUB_DIR}/_keep.caddy' || echo '#' | sudo tee '${HUB_DIR}/_keep.caddy' >/dev/null)"
_ec_mkdir=$?
set -e
if [[ "$_ec_mkdir" -ne 0 ]]; then
	echo "hub-register: failed to create remote directory or placeholder (SSH exit ${_ec_mkdir})." >&2
	exit 1
fi

# Staged file: leading dot so ${HUB_DIR}/*.caddy does not import it until moved into place.
WIP_REMOTE="${HUB_DIR}/.hub-wip-${APP_NAME}.part"
set +e
ssh -p "$SSH_PORT" -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=15 "$SSH_TARGET" \
	"sudo rm -f '${WIP_REMOTE}'"
printf '%s\n' "$SNIPPET" | ssh -p "$SSH_PORT" -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=15 "$SSH_TARGET" \
	"sudo tee '${WIP_REMOTE}' >/dev/null"
_ec_tee=$?
set -e
if [[ "$_ec_tee" -ne 0 ]]; then
	echo "hub-register: failed to write staged snippet on server (SSH exit ${_ec_tee})." >&2
	exit 1
fi

set +e
ssh -p "$SSH_PORT" -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=15 "$SSH_TARGET" bash -s -- "$HUB_DIR" "$APP_NAME" "$MAIN_CFG" <<'REMOTE'
set -euo pipefail
HUB_DIR="$1"
APP="$2"
MAIN_CFG="$3"
WIP="${HUB_DIR}/.hub-wip-${APP}.part"
FIN="${HUB_DIR}/${APP}.caddy"
PREV="${HUB_DIR}/${APP}.caddy.hubprev"
if ! sudo test -f "$WIP"; then
	echo "hub-register: staged file missing on server after upload." >&2
	exit 1
fi
if sudo test -f "$FIN"; then
	sudo cp -a "$FIN" "$PREV"
fi
sudo mv -f "$WIP" "$FIN"
set +e
sudo caddy validate --config "$MAIN_CFG"
_vc=$?
set -e
if [[ "$_vc" -ne 0 ]]; then
	if sudo test -f "$PREV"; then
		sudo mv -f "$PREV" "$FIN"
	else
		sudo rm -f "$FIN"
	fi
	echo "hub-register: remote caddy validate failed (exit ${_vc}); reverted route file." >&2
	exit 1
fi
set +e
sudo systemctl reload caddy
_re=$?
set -e
if [[ "$_re" -ne 0 ]]; then
	sudo rm -f "$PREV"
	echo "hub-register: systemctl reload caddy failed (exit ${_re}). Config passed validate; route file left in place — run: sudo systemctl reload caddy" >&2
	exit 1
fi
sudo rm -f "$PREV"
REMOTE
_ec_deploy=$?
set -e
if [[ "$_ec_deploy" -ne 0 ]]; then
	exit 1
fi

echo "hub-register: done. Installed ${HUB_DIR}/${APP_NAME}.caddy and reloaded Caddy (registration note saved)."

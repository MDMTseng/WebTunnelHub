#!/usr/bin/env bash
# hub-register.sh — Register a Hub subdomain route on EC2 (Caddy snippet + reload).
#
# Does not start or modify local SSH tunnels.
# Exit codes: 0 success; 1 usage/validation/SSH/Caddy failure; 2 route file already exists without --force.
#
# Usage: ./hub-register.sh [--force] [--note|-n <text>] <AppName>
#   --force     Overwrite existing ${HUB_DIR}/<AppName>.caddy on the server.
#   --note / -n Optional note stored in the snippet; shown by hub-status.sh.
#
# Remote: main Caddyfile must top-level import ${HUB_DIR}/*.caddy and include the root site (see Caddyfile.ec2.example).
# App name: hub_validate_register_app_name in hub-common.sh (lowercase only).
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
				echo "hub-register: ${_note_flag} requires a value. Example: $0 ${_note_flag} 'ops laptop' myapp" >&2
				exit 1
			fi
			REG_NOTE="$1"
			shift
			;;
		-*)
			echo "hub-register: unknown option: $1" >&2
			echo "hub-register: usage: $0 [--force] [--note|-n <text>] <AppName>" >&2
			exit 1
			;;
		*)
			break
			;;
	esac
done

APP_NAME="${1:-}"
if [[ -z "$APP_NAME" ]]; then
	echo "hub-register: usage: $0 [--force] [--note|-n <text>] <AppName>" >&2
	exit 1
fi
shift
if [[ $# -gt 0 ]]; then
	echo "hub-register: unexpected arguments: $*" >&2
	echo "hub-register: usage: $0 [--force] [--note|-n <text>] <AppName>" >&2
	exit 1
fi
hub_validate_register_app_name "$APP_NAME" || exit 1

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
		echo "hub-register: route already exists on server: ${HUB_DIR}/${APP_NAME}.caddy (no changes made)." >&2
		echo "hub-register: to overwrite, run: $0 [--note ...] --force ${APP_NAME}" >&2
		exit 2
	fi
	if [[ "$check_ec" -ne 1 ]]; then
		echo "hub-register: could not check remote route (SSH exit ${check_ec}). Verify network, key, and SSH_TARGET." >&2
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

echo "hub-register: registering $(hub_app_public_url "${APP_NAME}")"
echo "hub-register: site ${APP_NAME}.${HUB_PUBLIC_HOST}:${HUB_PUBLIC_PORT} -> EC2 127.0.0.1:${REMOTE_PORT}"
echo "hub-register: --- snippet preview ---"
echo "$SNIPPET"
echo "hub-register: --- end preview ---"
echo "hub-register: ensure ${MAIN_CFG} matches Caddyfile.ec2.example (root site reverse_proxy 127.0.0.1:10080; top-level import ${HUB_DIR}/*.caddy)."
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

set +e
printf '%s\n' "$SNIPPET" | ssh -p "$SSH_PORT" -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=15 "$SSH_TARGET" \
	"sudo tee ${HUB_DIR}/${APP_NAME}.caddy >/dev/null"
_ec_tee=$?
set -e
if [[ "$_ec_tee" -ne 0 ]]; then
	echo "hub-register: failed to write ${HUB_DIR}/${APP_NAME}.caddy on server (SSH exit ${_ec_tee})." >&2
	exit 1
fi

set +e
ssh -p "$SSH_PORT" -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=15 "$SSH_TARGET" \
	"sudo caddy validate --config ${MAIN_CFG} && sudo systemctl reload caddy"
_ec_caddy=$?
set -e
if [[ "$_ec_caddy" -ne 0 ]]; then
	echo "hub-register: remote caddy validate or reload failed (exit ${_ec_caddy}). Snippet was written; fix config on the server and reload manually." >&2
	exit 1
fi

if [[ -n "$REG_NOTE" ]]; then
	echo "hub-register: done. Installed ${HUB_DIR}/${APP_NAME}.caddy and reloaded Caddy (registration note saved)."
else
	echo "hub-register: done. Installed ${HUB_DIR}/${APP_NAME}.caddy and reloaded Caddy."
fi

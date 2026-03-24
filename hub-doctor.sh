#!/usr/bin/env bash
# hub-doctor.sh — Quick checks: .env loaded, SSH to hub host, optional local HTTP, Hub URL hints.
#
# Usage:
#   ./hub-doctor.sh
#   ./hub-doctor.sh myapp
#   ./hub-doctor.sh --port 5654 myapp
#   ./hub-doctor.sh myapp --port 5654
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=hub-common.sh
source "${SCRIPT_DIR}/hub-common.sh"

usage() {
	cat <<'EOF'
Usage:
  ./hub-doctor.sh                    Check config + SSH to SSH_TARGET
  ./hub-doctor.sh <AppName>          Also print public URL and hub loopback port
  ./hub-doctor.sh [--port N] <App>   Also probe http://127.0.0.1:N/

Examples:
  ./hub-doctor.sh coolapp
  ./hub-doctor.sh --port 5654 coolapp
EOF
}

LOCAL_PORT=""
APP_NAME=""

while [[ $# -gt 0 ]]; do
	case "$1" in
		-h | --help)
			usage
			exit 0
			;;
		-p | --port)
			if [[ -z "${2:-}" ]]; then
				echo "hub-doctor: $1 requires a port." >&2
				exit 1
			fi
			LOCAL_PORT="$2"
			shift 2
			;;
		-*)
			echo "hub-doctor: unknown option: $1" >&2
			usage >&2
			exit 1
			;;
		*)
			if [[ -n "$APP_NAME" ]]; then
				echo "hub-doctor: unexpected argument: $1" >&2
				usage >&2
				exit 1
			fi
			APP_NAME="$1"
			shift
			;;
	esac
done

echo "hub-doctor: configuration OK (.env / required variables)."
echo "hub-doctor: HUB_PUBLIC_URL -> ${HUB_PUBLIC_SCHEME}://${HUB_PUBLIC_HOST}:${HUB_PUBLIC_PORT}/"
echo "hub-doctor: SSH_TARGET=${SSH_TARGET}"

set +e
ssh -p "$SSH_PORT" -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=15 "$SSH_TARGET" "echo hub-doctor-ok"
_ssh_ec=$?
set -e
if [[ "$_ssh_ec" -ne 0 ]]; then
	echo "hub-doctor: SSH check failed (exit ${_ssh_ec}). Check key, network, SSH_TARGET, SSH_PORT." >&2
	exit 1
fi
echo "hub-doctor: SSH non-interactive session OK."

if [[ -z "$APP_NAME" ]]; then
	echo "hub-doctor: pass <AppName> for public URL and remote port hints."
	echo "hub-doctor: DNS must resolve <AppName>.${HUB_PUBLIC_HOST} (or *.${HUB_PUBLIC_HOST}) to your server."
	exit 0
fi

hub_validate_app_name "$APP_NAME" || exit 1
_rp="${REMOTE_PORT:-$(hub_remote_port "$APP_NAME")}"
_pub="$(hub_app_public_url "${APP_NAME}")"
_pub="${_pub%/}/"
echo "hub-doctor: app '${APP_NAME}' public URL (after register + tunnel): ${_pub}"
echo "hub-doctor: reverse tunnel on hub should bind 127.0.0.1:${_rp} -> your local service port."
if hub_reverse_tunnel_active "$_rp"; then
	echo "hub-doctor: local ssh -R for hub :${_rp} appears active."
else
	echo "hub-doctor: no matching local ssh -R for hub :${_rp} (start ./hub-tunnel.sh --port <local> ${APP_NAME})."
fi

if [[ -n "$LOCAL_PORT" ]]; then
	if ! [[ "$LOCAL_PORT" =~ ^[0-9]+$ ]] || [[ "$LOCAL_PORT" -lt 1 ]] || [[ "$LOCAL_PORT" -gt 65535 ]]; then
		echo "hub-doctor: invalid port: ${LOCAL_PORT}" >&2
		exit 1
	fi
	echo "hub-doctor: probing http://127.0.0.1:${LOCAL_PORT}/ ..."
	if hub_local_http_ok "$LOCAL_PORT"; then
		echo "hub-doctor: local HTTP OK on port ${LOCAL_PORT}."
	else
		echo "hub-doctor: local HTTP did not respond OK on port ${LOCAL_PORT} (start your app first)." >&2
		exit 1
	fi
fi

echo "hub-doctor: DNS must resolve ${APP_NAME}.${HUB_PUBLIC_HOST} (or *.${HUB_PUBLIC_HOST}) to your server."
echo "hub-doctor: done."

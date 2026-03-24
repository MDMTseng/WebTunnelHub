#!/usr/bin/env bash
# hub-unregister.sh — Remove Hub route(s) on EC2 (Caddy snippet + reload); by default stop local ssh -R for those ports.
#
# App name match is case-insensitive; multiple on-disk names differing only by case may all be removed.
# If ./hub-tunnel.sh is running in the foreground, it may exit with an error after its ssh child is killed; that is expected.
#
# Usage: ./hub-unregister.sh [--no-kill] <AppName>
#   --no-kill   Only remove remote snippet and reload; do not tear down tunnels (stop hub-tunnel yourself).
#
# Tunnel teardown (unless --no-kill):
#   1) EC2: stop listeners on each Hub port (typically sshd -R).
#   2) Local: stop matching ssh clients (fallback).
# Set HUB_KILL_TUNNEL_ON_EC2=0 to skip step 1 only.
#
# If you used REMOTE_PORT when registering, set the same REMOTE_PORT here. Otherwise ports are derived per matched on-disk name.
if [ -z "${BASH_VERSION:-}" ]; then
	exec /usr/bin/env bash "$0" "$@"
fi
if shopt -qo posix 2>/dev/null; then
	exec /usr/bin/env bash "$0" "$@"
fi
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
if [[ -z "$APP_NAME" ]]; then
	echo "hub-unregister: usage: $0 [--no-kill] <AppName>" >&2
	exit 1
fi
shift
if [[ $# -gt 0 ]]; then
	echo "hub-unregister: unexpected arguments: $*" >&2
	echo "hub-unregister: usage: $0 [--no-kill] <AppName>" >&2
	exit 1
fi
hub_validate_app_name "$APP_NAME" || exit 1

APP_NAME_LOWER="$(printf '%s' "$APP_NAME" | tr '[:upper:]' '[:lower:]')"

set +e
_match_out="$(
	ssh -p "$SSH_PORT" -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=15 "$SSH_TARGET" \
		"export HUB_DIR=$(printf '%q' "$HUB_DIR"); export APP_LOWER=$(printf '%q' "$APP_NAME_LOWER"); bash -s" <<'REMOTE'
shopt -s nullglob
for f in "$HUB_DIR"/*.caddy; do
	b=$(basename "$f" .caddy)
	[[ "$b" == _keep ]] && continue
	bl=$(printf '%s' "$b" | tr '[:upper:]' '[:lower:]')
	[[ "$bl" == "$APP_LOWER" ]] && printf '%s\n' "$b"
done
# Without this, the last loop iteration can end on a failed [[ ... ]] && printf (status 1) and SSH reports failure.
exit 0
REMOTE
)"
_ssh_list_ec=$?
set -euo pipefail

if [[ "$_ssh_list_ec" -ne 0 ]]; then
	echo "hub-unregister: could not connect or list routes (SSH exit ${_ssh_list_ec}). Check network, key, and SSH_TARGET." >&2
	exit 1
fi

MATCHES=()
while IFS= read -r line || [[ -n "$line" ]]; do
	line="${line%$'\r'}"
	[[ -z "$line" ]] && continue
	MATCHES+=("$line")
done <<<"$_match_out"

if ((${#MATCHES[@]} == 0)); then
	echo "hub-unregister: no route matched '${APP_NAME}' (case-insensitive) under ${HUB_DIR} on ${SSH_TARGET}." >&2
	exit 1
fi

if [[ "$NO_KILL" -eq 0 ]]; then
	if [[ "${HUB_KILL_TUNNEL_ON_EC2:-1}" != 0 ]]; then
		if [[ -n "${REMOTE_PORT-}" ]]; then
			hub_kill_tunnel_listener_on_ec2 "$REMOTE_PORT"
		else
			for m in "${MATCHES[@]}"; do
				hub_kill_tunnel_listener_on_ec2 "$(hub_remote_port "$m")"
			done
		fi
	else
		echo "hub-unregister: skipping EC2 listener teardown (HUB_KILL_TUNNEL_ON_EC2=0)." >&2
	fi
	if [[ -n "${REMOTE_PORT-}" ]]; then
		hub_kill_tunnels_for_remote_port "$REMOTE_PORT"
	else
		for m in "${MATCHES[@]}"; do
			hub_kill_tunnels_for_remote_port "$(hub_remote_port "$m")"
		done
	fi
else
	echo "hub-unregister: --no-kill set; skipping tunnel teardown in this script." >&2
fi

printf -v _hub_snips '%s.caddy ' "${MATCHES[@]}"
echo "hub-unregister: removing on ${SSH_TARGET} (case-insensitive match for '${APP_NAME}'): ${_hub_snips% }"

set +e
ssh -p "$SSH_PORT" -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=15 "$SSH_TARGET" \
	"export HUB_DIR=$(printf '%q' "$HUB_DIR"); export APP_LOWER=$(printf '%q' "$APP_NAME_LOWER"); export MAIN_CFG=$(printf '%q' "$MAIN_CFG"); bash -s" <<'REMOTE'
set -euo pipefail
shopt -s nullglob
for f in "$HUB_DIR"/*.caddy; do
	b=$(basename "$f" .caddy)
	[[ "$b" == _keep ]] && continue
	bl=$(printf '%s' "$b" | tr '[:upper:]' '[:lower:]')
	[[ "$bl" == "$APP_LOWER" ]] || continue
	sudo rm -f "$f"
done
sudo caddy validate --config "$MAIN_CFG" && sudo systemctl reload caddy
REMOTE
_ssh_rm_ec=$?
set -euo pipefail

if [[ "$_ssh_rm_ec" -ne 0 ]]; then
	echo "hub-unregister: remote delete, caddy validate, or reload failed (SSH exit ${_ssh_rm_ec}). Inspect the server." >&2
	exit 1
fi

printf 'hub-unregister: done. Removed route(s): %s.\n' "${MATCHES[*]}"
printf 'hub-unregister: if ./hub-tunnel.sh was running in the foreground, it may have exited after ssh was stopped; that is normal.\n'

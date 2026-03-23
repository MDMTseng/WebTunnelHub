#!/usr/bin/env bash
# Remove a Hub app from EC2 (delete Caddy snippet(s), reload) and stop local ssh -R for that app's port(s).
# Matching is case-insensitive: COOLAPP, CoolAPP, and coolapp are the same logical app (Linux stores separate files).
# The foreground ./hub-tunnel.sh process will exit with an error when its ssh child is killed — that is expected.
#
# Usage: ./hub-unregister.sh [--no-kill] <AppName>
#   --no-kill   Only remove Caddy file + reload; do not tear down tunnels (you stop tunnel yourself).
#
# Tunnel teardown (unless --no-kill):
#   1) EC2: sudo kills the TCP listener for each hub port (usually sshd for -R) — server-side drop.
#   2) Local: kill matching ssh client processes (fallback if step 1 missed).
# Set HUB_KILL_TUNNEL_ON_EC2=0 to skip step 1 only.
#
# If you overrode REMOTE_PORT when registering, set the same REMOTE_PORT here so we target that port only.
# If REMOTE_PORT is unset, we use one port per on-disk route name (each case variant can differ).
# Env: see `.env` / `.env.example`; REMOTE_PORT optional override
if [ -z "${BASH_VERSION:-}" ]; then
	exec /usr/bin/env bash "$0" "$@"
fi
# `sh hub-unregister.sh` often runs bash in POSIX mode — process substitution is disabled; re-exec without -o posix.
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
[[ -n "$APP_NAME" ]] || { echo "Usage: $0 [--no-kill] <AppName>"; exit 1; }
hub_validate_app_name "$APP_NAME"

APP_NAME_LOWER="$(printf '%s' "$APP_NAME" | tr '[:upper:]' '[:lower:]')"

# shellcheck disable=SC2087
MATCHES=()
while IFS= read -r line || [[ -n "$line" ]]; do
	[[ -z "$line" ]] && continue
	MATCHES+=("$line")
done < <(ssh -p "$SSH_PORT" -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=15 "$SSH_TARGET" \
	"export HUB_DIR=$(printf '%q' "$HUB_DIR"); export APP_LOWER=$(printf '%q' "$APP_NAME_LOWER"); bash -s" <<'REMOTE'
shopt -s nullglob
for f in "$HUB_DIR"/*.caddy; do
	b=$(basename "$f" .caddy)
	[[ "$b" == _keep ]] && continue
	bl=$(printf '%s' "$b" | tr '[:upper:]' '[:lower:]')
	[[ "$bl" == "$APP_LOWER" ]] && printf '%s\n' "$b"
done
REMOTE
)

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
		echo "Skipping EC2 tunnel listener kill (HUB_KILL_TUNNEL_ON_EC2=0)." >&2
	fi
	if [[ -n "${REMOTE_PORT-}" ]]; then
		hub_kill_tunnels_for_remote_port "$REMOTE_PORT"
	else
		for m in "${MATCHES[@]}"; do
			hub_kill_tunnels_for_remote_port "$(hub_remote_port "$m")"
		done
	fi
else
	echo "Skipping tunnel teardown (--no-kill)." >&2
fi

printf -v _hub_snips '%s.caddy ' "${MATCHES[@]}"
echo "Removing on ${SSH_TARGET} (case-insensitive match for '${APP_NAME}'): ${_hub_snips% }"

# shellcheck disable=SC2087
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

echo "OK: removed route(s): ${MATCHES[*]}. If ./hub-tunnel.sh was running for one of these names, it should have exited (broken pipe / ssh died)."

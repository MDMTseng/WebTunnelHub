# Shared helpers for Hub mode (sourced by hub-tunnel.sh, hub-register.sh, hub-unregister.sh, hub-status.sh, hub-applist.sh).
# Loads `.env` from this repo root if present; no built-in defaults — set variables in `.env` or export in the shell.

_hub_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${_hub_root}/.env" ]]; then
	set -a
	# shellcheck disable=SC1091
	source "${_hub_root}/.env"
	set +a
fi

_hub_required_vars=(SSH_TARGET SSH_KEY SSH_PORT HUB_DIR MAIN_CFG HUB_PUBLIC_URL)
_hub_missing=()
for v in "${_hub_required_vars[@]}"; do
	[[ -z "${!v:-}" ]] && _hub_missing+=("$v")
done
if ((${#_hub_missing[@]})); then
	echo "hub-common: missing or empty: ${_hub_missing[*]}" >&2
	echo "  Set them in ${_hub_root}/.env (see .env.example) or export before running." >&2
	return 1 2>/dev/null || exit 1
fi
export SSH_TARGET SSH_KEY SSH_PORT HUB_DIR MAIN_CFG HUB_PUBLIC_URL

# Avoid bash-only process substitution (< <(...)) so `sh hub-*.sh` on macOS POSIX sh still works.
_hub_parse_tmp="$(python3 -c "
import os, urllib.parse, sys
u = urllib.parse.urlparse(os.environ.get('HUB_PUBLIC_URL', ''))
if not u.hostname:
    print('hub-common: HUB_PUBLIC_URL must include a hostname (e.g. https://db.example.com:1080)', file=sys.stderr)
    sys.exit(1)
port = u.port
if port is None:
    port = 443 if u.scheme == 'https' else 80
print(u.scheme)
print(u.hostname)
print(port)
")" || exit 1
HUB_PUBLIC_SCHEME="$(printf '%s\n' "$_hub_parse_tmp" | sed -n '1p')"
HUB_PUBLIC_HOST="$(printf '%s\n' "$_hub_parse_tmp" | sed -n '2p')"
HUB_PUBLIC_PORT="$(printf '%s\n' "$_hub_parse_tmp" | sed -n '3p')"
export HUB_PUBLIC_SCHEME HUB_PUBLIC_HOST HUB_PUBLIC_PORT

# Hub apps use subdomains: https://AppName.${HUB_PUBLIC_HOST}:${HUB_PUBLIC_PORT}/
hub_app_public_url() {
	printf '%s://%s.%s:%s/\n' "${HUB_PUBLIC_SCHEME}" "$1" "${HUB_PUBLIC_HOST}" "${HUB_PUBLIC_PORT}"
}

hub_ssh_host() {
	echo "${SSH_TARGET#*@}"
}

# True if local ps shows ssh with -R 127.0.0.1:remote:127.0.0.1 to this SSH_TARGET host.
hub_reverse_tunnel_active() {
	local remote="$1"
	ps aux 2>/dev/null | grep -E '[s]sh ' | grep -F "$(hub_ssh_host)" | grep -F -- '-R' | grep -q "127.0.0.1:${remote}:127.0.0.1"
}

# Kill local ssh client(s) forwarding EC2 127.0.0.1:remote -> this machine (hub-unregister.sh).
hub_kill_tunnels_for_remote_port() {
	local remote="$1"
	local host pids
	host="$(hub_ssh_host)"
	# Disable pipefail for this subshell: grep exits 1 when no tunnel matches (normal when unregistering).
	pids=$(
		set +o pipefail 2>/dev/null || true
		ps aux 2>/dev/null | grep -E '[s]sh ' | grep -F "$host" | grep -F -- '-R' | grep -F "127.0.0.1:${remote}:127.0.0.1" | awk '{print $2}' | sort -u
	)
	[[ -z "$pids" ]] && return 0
	echo "Stopping local SSH tunnel(s) for EC2 127.0.0.1:${remote} (PIDs: $pids)" >&2
	for pid in $pids; do
		kill "$pid" 2>/dev/null || true
	done
	sleep 0.7
}

# On EC2: kill whatever is listening on TCP :remote (the sshd session for -R 127.0.0.1:remote:...).
# That terminates the tunnel from the server side; the local ssh client exits. Uses sudo (fuser/lsof).
# Port must be digits only. Ignores ssh failures so unregister can still remove Caddy files.
hub_kill_tunnel_listener_on_ec2() {
	local remote="$1"
	[[ "$remote" =~ ^[0-9]+$ ]] || return 0
	echo "EC2: tearing down tunnel listener on port ${remote} (drops client SSH if connected)." >&2
	# shellcheck disable=SC2087
	ssh -p "$SSH_PORT" -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=15 "$SSH_TARGET" \
		"export RPORT=$(printf '%s' "$remote"); bash -s" <<'REMOTE' || true
set +e
if command -v fuser >/dev/null 2>&1; then
	sudo fuser -k "${RPORT}/tcp" 2>/dev/null || true
fi
if command -v lsof >/dev/null 2>&1; then
	for p in $(sudo lsof -t -iTCP:"${RPORT}" -sTCP:LISTEN 2>/dev/null); do
		sudo kill "$p" 2>/dev/null || true
	done
fi
REMOTE
}

hub_local_http_ok() {
	local p="$1"
	curl -sS -o /dev/null -m 2 -w '' "http://127.0.0.1:${p}/" 2>/dev/null
}

hub_wait_local_http() {
	local port="$1"
	local max="${2:-10}"
	local i=0
	while ((i < max)); do
		hub_local_http_ok "$port" && return 0
		sleep 0.35
		((i++)) || true
	done
	return 1
}

# nohup "$@" >>log 2>&1 & disown
hub_background_log() {
	local log="$1"
	shift
	local d
	d="$(dirname "$log")"
	[[ -n "$d" && "$d" != "." ]] && mkdir -p "$d"
	nohup "$@" >>"$log" 2>&1 &
	disown 2>/dev/null || true
}

hub_validate_app_name() {
	local n="$1"
	if [[ ! "$n" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]{0,47}$ ]]; then
		echo "Invalid app name '$n': use letters, digits, underscore, hyphen; max 48 chars." >&2
		return 1
	fi
}

# Deterministic EC2 loopback port per app (20000–29999). Override with REMOTE_PORT when colliding.
hub_remote_port() {
	python3 -c 'import zlib,sys; n=sys.argv[1].encode(); print(20000 + (zlib.adler32(n) % 10000))' "$1"
}

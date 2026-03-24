# hub-common.sh — Shared helpers and environment for Hub scripts.
# Sourced by hub-tunnel, hub-register, hub-unregister, hub-status, hub-applist, hub-doctor, hub-serve-tunnel, etc.
# Loads `.env` from the repo root when present. Required variables have no built-in defaults.
# HUB_PUBLIC_URL parsing: https with no port defaults to 443; other schemes default to 80.

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
	echo "hub-common: incomplete configuration; unset or empty: ${_hub_missing[*]}" >&2
	echo "hub-common: set them in ${_hub_root}/.env (see .env.example) or export before running." >&2
	return 1 2>/dev/null || exit 1
fi
export SSH_TARGET SSH_KEY SSH_PORT HUB_DIR MAIN_CFG HUB_PUBLIC_URL

# Git Bash / MSYS / MinGW: Windows PATH often puts System32 before usr/bin, so `sort -u`
# runs sort.exe (fails / wrong flags) instead of GNU sort — breaks hub-status, hub-applist, etc.
hub_msys_prepend_path() {
	case "${OSTYPE:-}" in
	msys* | cygwin* | mingw*)
		PATH="/usr/bin:/bin:${PATH:-}"
		export PATH
		;;
	esac
}
hub_msys_prepend_path

# Parse scheme, host, and port from HUB_PUBLIC_URL (no Python).
hub_parse_public_url() {
	local url="$HUB_PUBLIC_URL" scheme rest authority auth
	local host port="" colon_count scheme_lc

	if [[ ! "$url" =~ ^([a-zA-Z][a-zA-Z0-9+.-]*)://([^/]+) ]]; then
		echo "hub-common: HUB_PUBLIC_URL must be a full URL with a hostname, e.g. https://db.example.com:1080" >&2
		return 1
	fi
	scheme="${BASH_REMATCH[1]}"
	rest="${BASH_REMATCH[2]}"
	authority="${rest%%/*}"
	if [[ -z "$authority" ]]; then
		echo "hub-common: HUB_PUBLIC_URL must be a full URL with a hostname, e.g. https://db.example.com:1080" >&2
		return 1
	fi
	if [[ "$authority" =~ @ ]]; then
		auth="${authority##*@}"
	else
		auth="$authority"
	fi
	if [[ -z "$auth" ]]; then
		echo "hub-common: HUB_PUBLIC_URL must be a full URL with a hostname, e.g. https://db.example.com:1080" >&2
		return 1
	fi

	if [[ "$auth" =~ ^\[([^]]+)\](:([0-9]+))?$ ]]; then
		host="${BASH_REMATCH[1]}"
		port="${BASH_REMATCH[3]:-}"
	elif [[ "$auth" == *:* ]]; then
		colon_count=$(printf '%s' "$auth" | tr -cd ':' | wc -c | tr -d ' ')
		if [[ "$colon_count" -eq 1 ]] && [[ "$auth" =~ ^(.+):([0-9]+)$ ]]; then
			host="${BASH_REMATCH[1]}"
			port="${BASH_REMATCH[2]}"
		else
			host="$auth"
		fi
	else
		host="$auth"
	fi

	if [[ -z "$host" ]]; then
		echo "hub-common: HUB_PUBLIC_URL must be a full URL with a hostname, e.g. https://db.example.com:1080" >&2
		return 1
	fi

	scheme_lc="${scheme,,}"
	if [[ -z "$port" ]]; then
		if [[ "$scheme_lc" == "https" ]]; then
			port=443
		else
			port=80
		fi
	fi

	HUB_PUBLIC_SCHEME="$scheme_lc"
	HUB_PUBLIC_HOST="$host"
	HUB_PUBLIC_PORT="$port"
	return 0
}

hub_parse_public_url || exit 1
export HUB_PUBLIC_SCHEME HUB_PUBLIC_HOST HUB_PUBLIC_PORT

# Public URL for a Hub app subdomain: https://AppName.host:port/
hub_app_public_url() {
	printf '%s://%s.%s:%s/\n' "${HUB_PUBLIC_SCHEME}" "$1" "${HUB_PUBLIC_HOST}" "${HUB_PUBLIC_PORT}"
}

hub_ssh_host() {
	echo "${SSH_TARGET#*@}"
}

# True if local ps shows ssh with -R forwarding EC2 127.0.0.1:remote -> this host.
hub_reverse_tunnel_active() {
	local remote="$1"
	ps aux 2>/dev/null | grep -E '[s]sh(\.exe)? ' | grep -F "$(hub_ssh_host)" | grep -F -- '-R' | grep -q "127.0.0.1:${remote}:127.0.0.1"
}

# Stop local ssh client(s) for EC2 127.0.0.1:remote -> this machine (hub-unregister).
hub_kill_tunnels_for_remote_port() {
	local remote="$1"
	local host pids
	host="$(hub_ssh_host)"
	# Disable pipefail: grep exit 1 when no tunnel matches is normal.
	pids=$(
		set +o pipefail 2>/dev/null || true
		ps aux 2>/dev/null | grep -E '[s]sh(\.exe)? ' | grep -F "$host" | grep -F -- '-R' | grep -F "127.0.0.1:${remote}:127.0.0.1" | awk '{print $2}' | sort -u
	)
	[[ -z "$pids" ]] && return 0
	echo "hub-common: stopping local SSH tunnel(s) for EC2 127.0.0.1:${remote} -> localhost (PIDs: ${pids})" >&2
	for pid in $pids; do
		kill "$pid" 2>/dev/null || true
	done
	sleep 0.7
}

# On EC2: stop whatever is listening on TCP :remote (typically sshd -R). Requires sudo.
# Port must be digits only. SSH errors are ignored so unregister can still remove route files.
hub_kill_tunnel_listener_on_ec2() {
	local remote="$1"
	[[ "$remote" =~ ^[0-9]+$ ]] || return 0
	echo "hub-common: releasing listener on EC2 port ${remote} (will drop the matching SSH reverse forward)." >&2
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
	if curl -sS -o /dev/null -m 2 -w '' "http://127.0.0.1:${p}/" 2>/dev/null; then
		return 0
	fi
	# Git Bash / MSYS: Windows curl in PATH may fail localhost HTTP even when the server is up.
	if bash -c 'exec 3<>/dev/tcp/127.0.0.1/$1 && exec 3<&- 3>&-' bash "$p" 2>/dev/null; then
		return 0
	fi
	return 1
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

hub_background_log() {
	local log="$1"
	shift
	local d
	d="$(dirname "$log")"
	[[ -n "$d" && "$d" != "." ]] && mkdir -p "$d"
	nohup "$@" >>"$log" 2>&1 &
	disown 2>/dev/null || true
}

# hub-tunnel / hub-unregister: alphanumeric plus _-; first char letter or digit; max length 48.
hub_validate_app_name() {
	local n="$1"
	if [[ ! "$n" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]{0,47}$ ]]; then
		echo "hub-common: invalid app name '${n}': start with a letter or digit; only letters, digits, underscore, hyphen; max 48 chars." >&2
		return 1
	fi
}

# hub-register: same as hub_validate_app_name, and name must be all lowercase ASCII letters (no uppercase).
hub_validate_register_app_name() {
	hub_validate_app_name "$1" || return 1
	if [[ "$1" != "${1,,}" ]]; then
		echo "hub-common: registration requires an all-lowercase app name; got '$1'." >&2
		return 1
	fi
}

# Single-line registration note for Caddy comment: strip newlines/tabs; cap length at 1024.
hub_sanitize_register_note() {
	local t="$1"
	t="${t//$'\r'/ }"
	t="${t//$'\n'/ }"
	t="${t//$'\t'/ }"
	if ((${#t} > 1024)); then
		t="${t:0:1024}"
	fi
	printf '%s' "$t"
}

# hub-register: after sanitization, require at least 5 ASCII letters (A-Z, a-z); digits/symbols alone are invalid.
hub_validate_register_note_text() {
	local t="$1"
	local letters="${t//[^a-zA-Z]/}"
	if ((${#letters} < 5)); then
		echo "hub-common: registration note must include at least 5 letters (A-Z or a-z), not only digits or punctuation." >&2
		return 1
	fi
}

# Zlib-compatible Adler-32 (ASCII app names per hub_validate_app_name).
hub_zlib_adler32() {
	local name="$1" s1=1 s2=0 MOD=65521 i c b
	for ((i = 0; i < ${#name}; i++)); do
		c="${name:i:1}"
		b=$(printf '%d' "'${c}")
		s1=$(( (s1 + b) % MOD ))
		s2=$(( (s2 + s1) % MOD ))
	done
	printf '%u\n' "$(( (s2 * 65536 + s1) & 0xffffffff ))"
}

# Deterministic EC2 loopback port per app (20000–29999). Override with REMOTE_PORT on collision.
hub_remote_port() {
	local sum
	sum=$(hub_zlib_adler32 "$1")
	printf '%u\n' "$((20000 + sum % 10000))"
}

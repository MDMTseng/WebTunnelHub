#!/usr/bin/env bash
# hub-status.sh — Summarize Hub state: registered apps, local ssh -R, inferred tunnel names, hub listeners, Caddy routes.
#
# No arguments. Requires non-interactive SSH to the hub host.
# One remote read of ${HUB_DIR}/*.caddy; failures are reported in the relevant sections.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=hub-common.sh
source "${SCRIPT_DIR}/hub-common.sh"

HOST_ONLY="$(hub_ssh_host)"

# Bash 3.2 / macOS sh: no associative arrays — use parallel arrays (last key wins, same as repeated map assigns).
_hub_reg_note_keys=()
_hub_reg_note_vals=()
_hub_reg_notes_append() {
	_hub_reg_note_keys+=("$1")
	_hub_reg_note_vals+=("$2")
}
_hub_reg_notes_lookup() {
	local _i
	for ((_i = ${#_hub_reg_note_keys[@]} - 1; _i >= 0; _i--)); do
		if [[ "${_hub_reg_note_keys[$_i]}" == "$1" ]]; then
			printf '%s' "${_hub_reg_note_vals[$_i]}"
			return 0
		fi
	done
	return 1
}

# Print fetch error for the Caddy snapshot. Returns 0 if a message was printed, 1 if data is usable.
_hub_status_caddy_fetch_error() {
	case "${_hub_caddy_state:-}" in
		ssh_fail)
			echo "(Could not connect or remote command failed; check network, key, and SSH_TARGET.)"
			;;
		no_files)
			echo "(No .caddy files under ${HUB_DIR}.)"
			;;
		*)
			return 1
			;;
	esac
}

# Single SSH: per .caddy file emit app name, optional Registration note, reverse_proxy summary
set +e
_hub_caddy_out="$(
	ssh -p "$SSH_PORT" -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=15 "$SSH_TARGET" \
		"export HUB_DIR=$(printf '%q' "$HUB_DIR"); bash -s" <<'REMOTE'
shopt -s nullglob
files=("$HUB_DIR"/*.caddy)
if ((${#files[@]} == 0)); then
	printf 'E\t%s\n' "$HUB_DIR"
	exit 0
fi
for f in "${files[@]}"; do
	b=$(basename "$f" .caddy)
	[[ "$b" == _keep ]] && continue
	printf 'N\t%s\n' "$b"
	reg_note=""
	while IFS= read -r _line; do
		if [[ "$_line" =~ ^#\ Registration\ note:\ (.*)$ ]]; then
			reg_note="${BASH_REMATCH[1]}"
		elif [[ "$_line" =~ ^# ]]; then
			continue
		else
			break
		fi
	done < "$f"
	if [[ -n "$reg_note" ]]; then
		printf 'M\t%s\t%s\n' "$(printf '%s' "$b" | tr '[:upper:]' '[:lower:]')" "$reg_note"
	fi
	rp=$(grep -E '^\s*reverse_proxy\s+' "$f" | head -1 | sed 's/^[[:space:]]*//')
	rp="${rp//$'\t'/ }"
	printf 'R\t%s\t%s\n' "$(printf '%s' "$b" | tr '[:upper:]' '[:lower:]')" "${rp:-(no reverse_proxy line found)}"
done
REMOTE
)"
_caddy_ec=$?
set -uo pipefail

REGISTERED_APPS=""
_ROUTES_DISPLAY=""
_hub_no_dir=""
while IFS= read -r line || [[ -n "$line" ]]; do
	line="${line%$'\r'}"
	[[ -z "$line" ]] && continue
	kind="${line%%$'\t'*}"
	rest="${line#*$'\t'}"
	case "$kind" in
		E)
			_hub_no_dir="$rest"
			;;
		N)
			REGISTERED_APPS+="${rest}"$'\n'
			;;
		M)
			_mbase="${rest%%$'\t'*}"
			_mnote="${rest#*$'\t'}"
			_hub_reg_notes_append "$_mbase" "$_mnote"
			;;
		R)
			_base="${rest%%$'\t'*}"
			_rp="${rest#*$'\t'}"
			_rsuffix=""
			_note="$(_hub_reg_notes_lookup "$_base" || true)"
			[[ -n "$_note" ]] && _rsuffix="  # ${_note}"
			_ROUTES_DISPLAY+="${_base} -> ${_rp}${_rsuffix}"$'\n'
			;;
	esac
done <<<"$_hub_caddy_out"

_hub_caddy_state=ok
((_caddy_ec != 0)) && _hub_caddy_state=ssh_fail
[[ "$_hub_caddy_state" == ok && -n "$_hub_no_dir" ]] && _hub_caddy_state=no_files

echo "=== Registered tunnel (app) names (${HUB_DIR}/*.caddy on hub) ==="
if _hub_status_caddy_fetch_error; then
	:
elif [[ -n "$REGISTERED_APPS" ]]; then
	while IFS= read -r _n || [[ -n "$_n" ]]; do
		[[ -z "$_n" ]] && continue
		printf '%s\n' "$(hub_ascii_lower "$_n")"
	done <<<"$REGISTERED_APPS" | sort -u
else
	echo "(No registered apps.)"
fi

echo ""
echo "=== Local ssh processes to ${SSH_TARGET} with -R ==="
# Match `ssh` or `ssh.exe` (Windows); avoid Windows sort.exe via hub_msys_prepend_path in hub-common.sh
_tunnel_ps="$(ps aux 2>/dev/null | grep -E '[s]sh(\.exe)? ' | grep -F -- "$HOST_ONLY" | grep -F -- '-R' || true)"
if [[ -n "$_tunnel_ps" ]]; then
	printf '%s\n' "$_tunnel_ps"
else
	echo "(None found; tunnel may run on another machine or not be up.)"
fi

echo ""
echo "=== Inferred active tunnel names (from -R remote port; 10080 = legacy root path) ==="
if [[ -z "$_tunnel_ps" ]]; then
	echo "(None)"
else
	# String list (not indexed array): bash 3.2 + set -u treats empty "${arr[@]}" as unbound.
	_hub_seen_rports="|"
	while IFS= read -r pline || [[ -n "$pline" ]]; do
		[[ -z "$pline" ]] && continue
		rport="" lport=""
		if [[ "$pline" =~ -R[[:space:]]+([0-9.]+):([0-9]+):127\.0\.0\.1:([0-9]+) ]]; then
			rport="${BASH_REMATCH[2]}"
			lport="${BASH_REMATCH[3]}"
		elif [[ "$pline" =~ -R[[:space:]]+([0-9]+):127\.0\.0\.1:([0-9]+) ]]; then
			rport="${BASH_REMATCH[1]}"
			lport="${BASH_REMATCH[2]}"
		fi
		[[ -z "$rport" ]] && continue
		[[ "$_hub_seen_rports" == *"|${rport}|"* ]] && continue
		_hub_seen_rports+="${rport}|"
		if [[ "$rport" == "10080" ]]; then
			printf '%s (local %s)\n' "legacy-root" "$lport"
			continue
		fi
		_matched=()
		if [[ "$_hub_caddy_state" == ok && -n "$REGISTERED_APPS" ]]; then
			while IFS= read -r app || [[ -n "$app" ]]; do
				[[ -z "$app" ]] && continue
				_rp="$(hub_remote_port "$app")"
				[[ "$_rp" == "$rport" ]] && _matched+=("$(hub_ascii_lower "$app")")
			done <<<"$REGISTERED_APPS"
		fi
		if ((${#_matched[@]})); then
			printf '%s (Hub :%s, local %s)\n' "$(IFS=','; echo "${_matched[*]}")" "$rport" "$lport"
		else
			printf '(no registered name matched) (Hub :%s, local %s)\n' "$rport" "$lport"
		fi
	done <<<"$_tunnel_ps"
fi

echo ""
echo "=== Hub LISTEN on 127.0.0.1:10080 and 20000-29999 (only when a tunnel is up) ==="
set +e
ssh -p "$SSH_PORT" -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=15 "$SSH_TARGET" \
	"ss -tlnp 2>/dev/null | grep 127.0.0.1 | grep -E ':(10080|2[0-9]{4})\b' || echo '(No matching listeners; tunnels may be down.)'"
_ss_ec=$?
set -uo pipefail
if [[ "$_ss_ec" -ne 0 ]]; then
	echo "(Could not query listeners over SSH; check connectivity and configuration.)"
fi

echo ""
echo "=== Hub Caddy registered subdomain routes (on disk; independent of tunnel state) ==="
if _hub_status_caddy_fetch_error; then
	:
elif [[ -n "$_ROUTES_DISPLAY" ]]; then
	printf '%s' "$_ROUTES_DISPLAY"
else
	echo "(No route entries.)"
fi

echo ""
echo "Legend:"
echo "  - Registered names come from .caddy filenames on the hub host; list is lowercased for display; on-disk case affects hub_remote_port."
echo "  - Inferred tunnel names map -R remote ports to hub_remote_port; port 10080 is shown as legacy-root (discouraged for new services); REMOTE_PORT overrides may show as unmatched."
echo "  - A port under LISTEN usually means an SSH reverse forward is bound on the hub host."
echo "  - Registered routes mean Caddy will reverse_proxy to that port; without a listener, browsers may fail or time out."
echo "  - Trailing \"# ...\" is from hub-register.sh --note (Registration note in the snippet)."
echo "  - Port mapping uses hub_remote_port in hub-common.sh (zlib Adler-32, same as Python zlib.adler32)."
echo ""
echo "hub-status: end of report."

exit 0

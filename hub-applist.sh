#!/usr/bin/env bash
# hub-applist.sh — List Hub app names registered on EC2 (${HUB_DIR}/*.caddy, excluding _keep).
#
# Usage: ./hub-applist.sh
# Config: `.env` via hub-common.sh
# Exit: 0; stderr message and 0 if no apps; non-zero if SSH fails.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=hub-common.sh
source "${SCRIPT_DIR}/hub-common.sh"

set +e
_out="$(
	ssh -p "$SSH_PORT" -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=15 "$SSH_TARGET" \
		"export HUB_DIR=$(printf '%q' "$HUB_DIR"); bash -s" <<'REMOTE'
shopt -s nullglob
names=()
for f in "$HUB_DIR"/*.caddy; do
	b=$(basename "$f" .caddy)
	[[ "$b" == _keep ]] && continue
	names+=("$b")
done
if ((${#names[@]} == 0)); then
	exit 3
fi
printf '%s\n' "${names[@]}" | sort -f
REMOTE
)"
_ssh_ec=$?
set -e

if [[ "$_ssh_ec" -eq 3 ]]; then
	echo "hub-applist: no registered apps under ${HUB_DIR} (excluding _keep)." >&2
	exit 0
fi
if [[ "$_ssh_ec" -ne 0 ]]; then
	echo "hub-applist: SSH failed (exit ${_ssh_ec}). Check connectivity, key, and SSH_TARGET." >&2
	exit 1
fi

printf '%s\n' "$_out"

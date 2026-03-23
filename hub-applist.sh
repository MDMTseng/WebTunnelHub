#!/usr/bin/env bash
# List Hub app names registered on EC2 (hub-routes/*.caddy, excluding _keep).
# Usage: ./hub-applist.sh
# Config: `.env` (loaded via hub-common.sh)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=hub-common.sh
source "${SCRIPT_DIR}/hub-common.sh"

# shellcheck disable=SC2087
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
	echo "(no apps in $HUB_DIR)" >&2
	exit 0
fi
printf '%s\n' "${names[@]}" | sort -f
REMOTE

#!/usr/bin/env bash
# Interactive SSH to the same host as hub-tunnel/hub-register (reads `.env` via hub-common).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=hub-common.sh
source "${SCRIPT_DIR}/hub-common.sh"

REMOTE_CMD="${REMOTE_CMD:-cd ~/webTunnel && exec bash -l}"

exec ssh -t \
	-p "$SSH_PORT" \
	-i "$SSH_KEY" \
	"$SSH_TARGET" \
	"$REMOTE_CMD"

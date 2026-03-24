#!/usr/bin/env bash
# hub-ssh.sh — Interactive SSH session to the hub host (same SSH_TARGET and key as hub-tunnel / hub-register).
#
# Usage: ./hub-ssh.sh
# Optional REMOTE_CMD: remote command string; default cd ~/webTunnel && exec bash -l
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=hub-common.sh
source "${SCRIPT_DIR}/hub-common.sh"

REMOTE_CMD="${REMOTE_CMD:-cd ~/webTunnel && exec bash -l}"

echo "hub-ssh: opening interactive session to ${SSH_TARGET}..." >&2
exec ssh -t \
	-p "$SSH_PORT" \
	-i "$SSH_KEY" \
	"$SSH_TARGET" \
	"$REMOTE_CMD"

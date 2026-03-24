#!/usr/bin/env bash
# Local HTTP (example/serve.py), then Hub register + SSH tunnel (hub-managed-tunnel.sh).
set -euo pipefail

SCRIPT_TAG='example/start.sh'
APP_NAME='hub-serve'
REGISTER_NOTE='Demo hub serve dashboard'
PORT="${PORT:-8080}"

R="$(cd "$(dirname "$0")/.." && pwd)" && cd "$R" && source ./hub-common.sh

_PY="$(command -v python3 || command -v python)" || { echo "${SCRIPT_TAG}: need python3 or python in PATH." >&2; exit 1; }

PORT="$PORT" "$_PY" example/serve.py &
SERVE_PID=$!
cleanup_serve() {
	kill "$SERVE_PID" 2>/dev/null || true
	wait "$SERVE_PID" 2>/dev/null || true
}
# When hub-managed-tunnel exits (tunnel closed, killed, or SSH drops), we exit too and this trap stops serve.py.
trap cleanup_serve EXIT

if ! hub_wait_local_http "$PORT" 30; then
	echo "${SCRIPT_TAG}: local HTTP on :${PORT} never became ready (serve.py may have crashed or failed to bind)." >&2
	exit 1
fi

_ec=0
./hub-managed-tunnel.sh --name "$APP_NAME" --note "$REGISTER_NOTE" --port "$PORT" || _ec=$?
exit "$_ec"

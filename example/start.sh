#!/usr/bin/env bash
# Demo only: hub-serve register + example/serve.py :8080 + tunnel (no unregister — run hub-unregister.sh when done).
set -euo pipefail
R="$(cd "$(dirname "$0")/.." && pwd)" && cd "$R" && source ./hub-common.sh

set +e
./hub-register.sh --note 'Demo hub serve dashboard' hub-serve
_reg=$?
set -e
if [[ "$_reg" -eq 2 ]]; then
	echo "example/start.sh: hub-serve is already registered on the hub." >&2
	echo "  Remove the existing route, then run this script again:  ./hub-unregister.sh hub-serve" >&2
	exit 2
fi
if [[ "$_reg" -ne 0 ]]; then
	echo "example/start.sh: hub-register.sh failed (exit ${_reg}). Check .env, SSH key, and SSH_TARGET." >&2
	exit "$_reg"
fi

if command -v python3 >/dev/null 2>&1; then
	_PY=python3
elif command -v python >/dev/null 2>&1; then
	_PY=python
else
	echo "example/start.sh: need python3 or python in PATH." >&2
	exit 1
fi

PORT=8080 "$_PY" example/serve.py &
SERVE_PID=$!
trap 'kill "$SERVE_PID" 2>/dev/null; wait "$SERVE_PID" 2>/dev/null || true' EXIT
hub_wait_local_http 8080 30
_ec=0
./hub-tunnel.sh --port 8080 hub-serve || _ec=$?
trap - EXIT
kill "$SERVE_PID" 2>/dev/null || true
wait "$SERVE_PID" 2>/dev/null || true
exit "$_ec"

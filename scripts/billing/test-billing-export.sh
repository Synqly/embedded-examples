#!/bin/bash
# Test billing-export.sh against a stub HTTP server: the organization in the
# logon URL, the Authorization header, and the month it resolves an input to.
#
# The stub records every request and rejects the logon, so the export stops
# right after authenticate() has built its request. Everything asserted here
# is read out of the real script, not a copy of its functions.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXPORT_SCRIPT="${SCRIPT_DIR}/billing-export.sh"

WORK_DIR=$(mktemp -d)
STUB_PID=""

cleanup() {
    if [[ -n "$STUB_PID" ]]; then
        kill "$STUB_PID" 2>/dev/null || true
    fi
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT INT TERM

PORT_FILE="${WORK_DIR}/port"
REQUESTS_FILE="${WORK_DIR}/requests"
: >"$REQUESTS_FILE"

cat >"${WORK_DIR}/stub.py" <<'PY'
import http.server
import json
import os
import socketserver

REQUESTS = os.environ["STUB_REQUESTS"]


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def _record(self):
        auth = "auth" if self.headers.get("Authorization") else "noauth"
        with open(REQUESTS, "a") as f:
            f.write("%s %s %s\n" % (self.command, self.path, auth))

    def _send(self, body):
        raw = json.dumps(body).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self):
        self._record()
        self._send({"version": "stub"})

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        if length:
            self.rfile.read(length)
        self._record()
        self._send({"message": "stub rejects all logons"})


server = socketserver.TCPServer(("127.0.0.1", 0), Handler)
with open(os.environ["STUB_PORT"], "w") as f:
    f.write(str(server.server_address[1]))
server.serve_forever()
PY

STUB_PORT="$PORT_FILE" STUB_REQUESTS="$REQUESTS_FILE" python3 "${WORK_DIR}/stub.py" &
STUB_PID=$!

for _ in $(seq 1 50); do
    [[ -s "$PORT_FILE" ]] && break
    sleep 0.1
done

if [[ ! -s "$PORT_FILE" ]]; then
    echo "Error: stub server failed to start" >&2
    exit 1
fi
PORT=$(cat "$PORT_FILE")

# Run the export; echo the first POST the stub saw as "<path> <auth|noauth>"
logon_request() {
    : >"$REQUESTS_FILE"
    "$EXPORT_SCRIPT" \
        --url "http://127.0.0.1:${PORT}" \
        --user admin \
        --password stub-password \
        --month 2026-01 \
        --output "$WORK_DIR" \
        "$@" >/dev/null 2>&1 </dev/null || true
    awk '/^POST /{print $2, $3; exit}' "$REQUESTS_FILE"
}

assert_logon() {
    local description="$1"
    local expected="$2"
    shift 2

    local actual
    actual=$(logon_request "$@")
    if [[ "$actual" == "$expected" ]]; then
        echo "  ✓ $description -> $actual"
    else
        echo "  ✗ $description -> Expected '$expected', got '${actual:-<no request>}'"
        exit 1
    fi
}

# Echo the YYYY-MM the script resolved a --month input to, read from its log
resolved_month() {
    "$EXPORT_SCRIPT" \
        --url "http://127.0.0.1:${PORT}" \
        --user admin \
        --password stub-password \
        --output "$WORK_DIR" \
        --month "$1" >/dev/null 2>"${WORK_DIR}/run.log" </dev/null || true
    awk -F 'Z Month: ' '/Z Month: /{print $2; exit}' "${WORK_DIR}/run.log"
}

echo "Testing logon request construction..."
echo

echo "Test 1: default organization"
assert_logon "no --org" "/v1/auth/logon/synqly-backoffice noauth"
echo

echo "Test 2: --org override"
assert_logon "--org embedded" "/v1/auth/logon/embedded noauth" --org embedded
assert_logon "--org acme-corp" "/v1/auth/logon/acme-corp noauth" --org acme-corp
echo

echo "Test 3: root token is optional but sent when provided"
assert_logon "--token stub-token" "/v1/auth/logon/synqly-backoffice auth" --token stub-token
assert_logon "no token" "/v1/auth/logon/synqly-backoffice noauth"
echo

# A month name means the most recent occurrence of that month: at or before the
# current month, and within the last twelve. Asserting the property rather than
# a fixed date keeps this honest whatever month the suite runs in, and catches
# the zero-padded month numbers bash reads as invalid octal.
echo "Test 4: a month name resolves to its most recent occurrence"
CURRENT_MONTH=$(date +%Y-%m)
FLOOR_MONTH="$(($(date +%Y) - 1))-$(date +%m)"

for month_name in january february march april may june july august \
    september october november december; do
    resolved=$(resolved_month "$month_name")

    if [[ ! "$resolved" =~ ^[0-9]{4}-[0-9]{2}$ ]]; then
        echo "  ✗ $month_name -> '${resolved:-<no month logged>}' is not YYYY-MM"
        exit 1
    fi
    if [[ "$resolved" > "$CURRENT_MONTH" ]]; then
        echo "  ✗ $month_name -> $resolved is in the future (current month is $CURRENT_MONTH)"
        exit 1
    fi
    if [[ ! "$resolved" > "$FLOOR_MONTH" ]]; then
        echo "  ✗ $month_name -> $resolved is over twelve months back (floor is $FLOOR_MONTH)"
        exit 1
    fi

    echo "  ✓ $month_name -> $resolved"
done
echo

echo "All tests passed!"

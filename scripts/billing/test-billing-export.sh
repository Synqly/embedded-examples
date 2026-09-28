#!/bin/bash
# Test billing-export.sh against a stub HTTP server: the organization in the
# logon URL, the Authorization header, and the month it resolves an input to.
#
# The stub records every request and rejects every logon but two secrets, so
# most exports stop right after authenticate() has built its request.
# ACCEPTED_SECRET gets an access token the billing route serves, and
# REFUSED_BILLING_SECRET one it refuses. The billing route also serves
# STUB_ORG_TOKEN. The export route answers 404, as a Synqly version without it
# does, to every token but those starting with EXPORT_PREFIX. Everything
# asserted here comes from running the real script against the stub.
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
import io
import json
import os
import socketserver
import tarfile
import urllib.parse

REQUESTS = os.environ["STUB_REQUESTS"]
ACCEPTED_SECRET = os.environ["STUB_ACCEPTED_SECRET"]
REFUSED_BILLING_SECRET = os.environ["STUB_REFUSED_BILLING_SECRET"]
ORG_TOKEN = os.environ["STUB_ORG_TOKEN"]
NOT_JSON_TOKEN = os.environ["STUB_NOT_JSON_TOKEN"]
EMPTY_401_TOKEN = os.environ["STUB_EMPTY_401_TOKEN"]
FETCH_EMPTY_401_TOKEN = os.environ["STUB_FETCH_EMPTY_401_TOKEN"]
EMPTY_200_TOKEN = os.environ["STUB_EMPTY_200_TOKEN"]
BAD_RESULT_TOKEN = os.environ["STUB_BAD_RESULT_TOKEN"]
NO_CSV_TOKEN = os.environ["STUB_NO_CSV_TOKEN"]
CURSOR_TOKEN = os.environ["STUB_CURSOR_TOKEN"]
HOSTILE_SECRET = os.environ["STUB_HOSTILE_SECRET"]
HOSTILE_OUTPUT = os.environ["STUB_HOSTILE_OUTPUT"]
EXPORT_PREFIX = os.environ["STUB_EXPORT_PREFIX"]
EXPORT_NAME = "synqly-billing-export-2026-09-24-120000"
BILLING_RECORD = {
    "name": "stub",
    "organization_id": "stub-org",
    "month": "january",
    "csv_data": "Organization,Requests\nstub,1\nTOTAL\nstub,1",
}


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    # Record "<method> <path> <auth|noauth> <bearer|->"
    def _record(self):
        header = self.headers.get("Authorization", "")
        auth = "auth" if header else "noauth"
        bearer = header[len("Bearer "):] if header.startswith("Bearer ") else "-"
        with open(REQUESTS, "a") as f:
            f.write("%s %s %s %s\n" % (self.command, self.path, auth, bearer))

    def _send(self, body, status=200):
        self._write(json.dumps(body).encode(), "application/json", status)

    def _write(self, raw, content_type, status):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self):
        self._record()
        if not self.path.startswith("/v1/billing"):
            self._send({"version": "stub"})
            return
        if self.path.startswith("/v1/billing/export"):
            self._export()
            return
        auth = self.headers.get("Authorization")
        if auth == "Bearer " + NOT_JSON_TOKEN:
            self._write(b"<html>stub web page</html>", "text/html", 200)
            return
        if auth == "Bearer " + EMPTY_401_TOKEN:
            self._write(b"", "text/plain", 401)
            return
        if auth == "Bearer " + EMPTY_200_TOKEN:
            self._write(b"", "text/plain", 200)
            return
        # Passes the token check, then gets a gateway's empty 401 on the month
        if auth == "Bearer " + FETCH_EMPTY_401_TOKEN:
            if "limit=1" in self.path:
                self._send({"result": [BILLING_RECORD]})
                return
            self._write(b"", "text/plain", 401)
            return
        # Pass the token check, then answer the month with no billing list
        if auth in ("Bearer " + BAD_RESULT_TOKEN, "Bearer " + NO_CSV_TOKEN) and "limit=1" in self.path:
            self._send({"result": [BILLING_RECORD]})
            return
        if auth == "Bearer " + BAD_RESULT_TOKEN:
            self._send({"result": "oops"})
            return
        if auth == "Bearer " + NO_CSV_TOKEN:
            self._send({"result": [{"name": "stub", "month": "january"}]})
            return
        # One page carrying a cursor curl would glob into two requests, then an
        # empty page
        if auth == "Bearer " + CURSOR_TOKEN:
            if "start_after=" in self.path:
                self._send({"result": []})
                return
            self._send({"result": [BILLING_RECORD], "cursor": "{a,b}"})
            return
        if auth not in ("Bearer " + ORG_TOKEN, "Bearer stub-access-token") and \
                not (auth or "").startswith("Bearer " + EXPORT_PREFIX):
            self._send({"status": 401, "message": "stub refuses this token"}, 401)
            return
        self._send({"result": [BILLING_RECORD]})

    # The export route, keyed by the bearer's suffix after EXPORT_PREFIX:
    # "archive" labels each month it serves "served-<name>"
    def _export(self):
        auth = self.headers.get("Authorization") or ""
        if not auth.startswith("Bearer " + EXPORT_PREFIX):
            self._write(b"404 page not found", "text/plain", 404)
            return
        kind = auth[len("Bearer " + EXPORT_PREFIX):]
        query = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
        names = [query["from"][0], query["to"][0]]
        if names[0] == names[1]:
            names = names[:1]
        # An older version whose billing authz reads the path as a get
        if kind == "old-403":
            self._send({"status": 403, "message": "stub denies billing get"}, 403)
            return
        if kind == "500":
            self._send({"status": 500, "message": "stub export failed"}, 500)
            return
        # A gateway's bare 502, which curl writes no file for
        if kind == "empty-502":
            self._write(b"", "text/plain", 502)
            return
        # A proxy that drops the connection without answering
        if kind == "drop":
            self.close_connection = True
            return
        if kind == "page":
            self._write(b"<html>stub web page</html>", "text/html", 200)
            return
        if kind == "escape":
            self._write(self._archive(names, ["../escape.csv"]), "application/gzip", 200)
            return
        if kind == "empty":
            self._write(self._archive([], []), "application/gzip", 200)
            return
        self._write(self._archive(names, []), "application/gzip", 200)

    # A tar.gz laid out as lepton builds one, with <extra> entries added
    def _archive(self, names, extra):
        labels = ["served-" + n for n in names]
        files = {label + ".csv": "Organization,Requests,Deleted\nstub,1,false\n" for label in labels}
        files["metadata.json"] = json.dumps({"months_included": labels}) + "\n"
        files["export.log"] = "2026-09-24T12:00:00Z stub export log\n"
        for name in extra:
            files[name] = "stub"

        buf = io.BytesIO()
        with tarfile.open(fileobj=buf, mode="w:gz") as tar:
            directory = tarfile.TarInfo(EXPORT_NAME + "/")
            directory.type = tarfile.DIRTYPE
            tar.addfile(directory)
            for name, body in files.items():
                raw = body.encode()
                info = tarfile.TarInfo(EXPORT_NAME + "/" + name)
                info.size = len(raw)
                tar.addfile(info, io.BytesIO(raw))
        return buf.getvalue()

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = json.loads(self.rfile.read(length)) if length else {}
        self._record()
        # HOSTILE_SECRET's token would add an "output" line to curl's config.
        # EXPORT_PREFIX + "secret" gets a token the export route serves.
        access_tokens = {
            ACCEPTED_SECRET: "stub-access-token",
            REFUSED_BILLING_SECRET: "stub-refused-access-token",
            HOSTILE_SECRET: 'x"\noutput = "' + HOSTILE_OUTPUT,
            EXPORT_PREFIX + "secret": EXPORT_PREFIX + "archive",
        }
        if body.get("secret") not in access_tokens:
            self._send({"message": "stub rejects all logons"})
            return
        self._send({"result": {
            "auth_code": "success",
            "token": {"access": {"secret": access_tokens[body["secret"]]}},
        }})


server = socketserver.TCPServer(("127.0.0.1", 0), Handler)
with open(os.environ["STUB_PORT"], "w") as f:
    f.write(str(server.server_address[1]))
server.serve_forever()
PY

ACCEPTED_SECRET="stub-accepted-secret"
REFUSED_BILLING_SECRET="stub-refused-billing-secret"
STUB_ORG_TOKEN="stub-org-token-7f3a9c"
STUB_NOT_JSON_TOKEN="stub-not-json-token"
STUB_EMPTY_401_TOKEN="stub-empty-401-token"
STUB_FETCH_EMPTY_401_TOKEN="stub-fetch-empty-401-token"
STUB_EMPTY_200_TOKEN="stub-empty-200-token"
STUB_BAD_RESULT_TOKEN="stub-bad-result-token"
STUB_NO_CSV_TOKEN="stub-no-csv-token"
STUB_CURSOR_TOKEN="stub-cursor-token"
HOSTILE_SECRET="stub-hostile-secret"
HOSTILE_OUTPUT="${WORK_DIR}/hostile-output"
EXPORT_PREFIX="stub-export-"

STUB_PORT="$PORT_FILE" STUB_REQUESTS="$REQUESTS_FILE" \
    STUB_ACCEPTED_SECRET="$ACCEPTED_SECRET" STUB_ORG_TOKEN="$STUB_ORG_TOKEN" \
    STUB_REFUSED_BILLING_SECRET="$REFUSED_BILLING_SECRET" \
    STUB_NOT_JSON_TOKEN="$STUB_NOT_JSON_TOKEN" \
    STUB_EMPTY_401_TOKEN="$STUB_EMPTY_401_TOKEN" \
    STUB_FETCH_EMPTY_401_TOKEN="$STUB_FETCH_EMPTY_401_TOKEN" \
    STUB_EMPTY_200_TOKEN="$STUB_EMPTY_200_TOKEN" \
    STUB_BAD_RESULT_TOKEN="$STUB_BAD_RESULT_TOKEN" STUB_NO_CSV_TOKEN="$STUB_NO_CSV_TOKEN" \
    STUB_CURSOR_TOKEN="$STUB_CURSOR_TOKEN" \
    STUB_HOSTILE_SECRET="$HOSTILE_SECRET" STUB_HOSTILE_OUTPUT="$HOSTILE_OUTPUT" \
    STUB_EXPORT_PREFIX="$EXPORT_PREFIX" \
    python3 "${WORK_DIR}/stub.py" &
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

# A curl that records its arguments, so a test can check that no token reaches
# the process list
REAL_CURL=$(command -v curl)
CURL_ARGS_FILE="${WORK_DIR}/curl-args"
mkdir "${WORK_DIR}/bin"
cat >"${WORK_DIR}/bin/curl" <<SH
#!/bin/bash
printf '%s\n' "\$*" >>"$CURL_ARGS_FILE"
exec "$REAL_CURL" "\$@"
SH
chmod +x "${WORK_DIR}/bin/curl"

# Months follow UTC, as the script and lepton count them
CURRENT_MONTH=$(date -u +%Y-%m)
NOW_YEAR="${CURRENT_MONTH%-*}"
NOW_MONTH="${CURRENT_MONTH#*-}"
FLOOR_MONTH="$((NOW_YEAR - 1))-${NOW_MONTH}"
MONTH_NAMES=(january february march april may june july august september
    october november december)
MONTH_NAME_PATTERN=$(IFS='|'; echo "${MONTH_NAMES[*]}")

# Run the export into a fresh case directory, with stdin from the caller.
# SYNQLY_TOKEN and SYNQLY_ORG_TOKEN are unset so an ambient value in the
# environment can't flip an assertion; leading NAME=VALUE arguments set
# variables back, as env takes them. Sets CASE_DIR (out/, stdout, stderr) and
# RUN_RC.
run_export() {
    local env_args=()
    while [[ $# -gt 0 && "$1" == *=* ]]; do
        env_args+=("$1")
        shift
    done

    CASE_DIR=$(mktemp -d "${WORK_DIR}/case.XXXXXX")
    mkdir "${CASE_DIR}/out"
    : >"$REQUESTS_FILE"
    RUN_RC=0
    env -u SYNQLY_TOKEN -u SYNQLY_ORG_TOKEN ${env_args[@]+"${env_args[@]}"} \
        "$EXPORT_SCRIPT" \
        --url "http://127.0.0.1:${PORT}" \
        --output "${CASE_DIR}/out" \
        "$@" >"${CASE_DIR}/stdout" 2>"${CASE_DIR}/stderr" || RUN_RC=$?
}

fail() {
    echo "  ✗ $1"
    echo "    stderr:"
    sed 's/^/      /' "${CASE_DIR}/stderr"
    exit 1
}

# Run a password logon; echo the first POST the stub saw as "<path> <auth|noauth>"
logon_request() {
    run_export "$@" --user admin --password stub-password </dev/null
    awk '/^POST /{print $2, $3; exit}' "$REQUESTS_FILE"
}

compare_logon() {
    local description="$1"
    local expected="$2"
    local actual="$3"

    if [[ "$actual" != "$expected" ]]; then
        echo "  ✗ $description -> Expected '$expected', got '${actual:-<no request>}'"
        exit 1
    fi
    echo "  ✓ $description -> $actual"
}

# Assert the logon request twice, the second time with SYNQLY_ORG_TOKEN set:
# the password logons read no org-token source (R6)
assert_logon() {
    local description="$1"
    local expected="$2"
    shift 2

    compare_logon "$description" "$expected" "$(logon_request "$@")"
    compare_logon "$description, SYNQLY_ORG_TOKEN set" "$expected" \
        "$(logon_request "SYNQLY_ORG_TOKEN=$STUB_ORG_TOKEN" "$@")"
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

# Assert the last run_export exited non-zero, printed <text> to stderr, and
# wrote no archive
assert_refused() {
    local description="$1"
    local text="$2"

    if [[ $RUN_RC -eq 0 ]]; then
        fail "$description -> exited 0"
    fi
    if ! grep -qF -- "$text" "${CASE_DIR}/stderr"; then
        fail "$description -> stderr lacks '$text'"
    fi
    if compgen -G "${CASE_DIR}/out/*.tar.gz" >/dev/null; then
        fail "$description -> wrote an archive"
    fi
    echo "  ✓ $description -> $text"
}

# Assert the last run_export wrote an archive, fetched a month, and sent
# <token> as the bearer on every billing request
assert_exported() {
    local description="$1"
    local token="$2"

    if [[ $RUN_RC -ne 0 ]]; then
        fail "$description -> exited $RUN_RC"
    fi
    if ! compgen -G "${CASE_DIR}/out/*.tar.gz" >/dev/null; then
        fail "$description -> wrote no archive"
    fi
    if ! grep -q '^GET /v1/billing?filter=' "$REQUESTS_FILE"; then
        fail "$description -> fetched no month"
    fi
    if awk -v names="^(${MONTH_NAME_PATTERN})$" '$2 ~ /^\/v1\/billing\?filter=/ {
        m = $2; sub(/^.*month%5beq%5d/, "", m); sub(/&.*/, "", m)
        if (m !~ names) bad = 1
    } END {exit !bad}' "$REQUESTS_FILE"; then
        fail "$description -> a billing request named no month"
    fi
    if awk -v t="$token" '$2 ~ /^\/v1\/billing/ && $4 != t {bad = 1} END {exit !bad}' "$REQUESTS_FILE"; then
        fail "$description -> a billing request carried another bearer"
    fi
}

# Assert the last run_export exported through the org-token logon: no logon
# request, and <token> as the bearer on every billing request (R1)
assert_org_token_sent() {
    local description="$1"
    local token="$2"

    assert_exported "$description" "$token"
    if grep -q '^POST ' "$REQUESTS_FILE"; then
        fail "$description -> sent a logon request"
    fi
    echo "  ✓ $description -> org token sent, no logon request"
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

# A month name means its most recent completed occurrence: before the current
# month, and no earlier than the same month last year. Asserting the property
# rather than a fixed date keeps this honest whatever month the suite runs in,
# and catches the zero-padded month numbers bash reads as invalid octal.
echo "Test 4: a month name resolves to its most recent completed occurrence"
for month_name in "${MONTH_NAMES[@]}"; do
    resolved=$(resolved_month "$month_name")

    if [[ ! "$resolved" =~ ^[0-9]{4}-[0-9]{2}$ ]]; then
        echo "  ✗ $month_name -> '${resolved:-<no month logged>}' is not YYYY-MM"
        exit 1
    fi
    if [[ ! "$resolved" < "$CURRENT_MONTH" ]]; then
        echo "  ✗ $month_name -> $resolved has not completed (current month is $CURRENT_MONTH)"
        exit 1
    fi
    if [[ "$resolved" < "$FLOOR_MONTH" ]]; then
        echo "  ✗ $month_name -> $resolved is over twelve months back (floor is $FLOOR_MONTH)"
        exit 1
    fi

    echo "  ✓ $month_name -> $resolved"
done
echo

echo "Test 5: a refused billing call fails the run"
run_export --user admin --password "$REFUSED_BILLING_SECRET" </dev/null
assert_refused "password logon, billing refused" "Error fetching billing data:"
run_export --org-token "$STUB_FETCH_EMPTY_401_TOKEN" </dev/null
assert_refused "billing refused with an empty 401" "Error fetching billing data: HTTP 401"
echo

echo "Test 6: the org-token logon"
: >"$CURL_ARGS_FILE"
run_export "PATH=${WORK_DIR}/bin:$PATH" --org-token "$STUB_ORG_TOKEN" </dev/null
assert_org_token_sent "--org-token" "$STUB_ORG_TOKEN"

if ! grep -q '/v1/billing?filter=' "$CURL_ARGS_FILE"; then
    fail "curl wrapper -> recorded no billing request"
fi
if grep -qF -- "$STUB_ORG_TOKEN" "$CURL_ARGS_FILE"; then
    fail "curl arguments -> hold the org token"
fi
echo "  ✓ curl arguments -> no org token"

mkdir "${CASE_DIR}/extract"
tar -xzf "${CASE_DIR}"/out/*.tar.gz -C "${CASE_DIR}/extract"
if grep -rqF -- "$STUB_ORG_TOKEN" "${CASE_DIR}/stdout" "${CASE_DIR}/stderr" "${CASE_DIR}/extract"; then
    fail "--org-token -> org token found in stdout, stderr or archive"
fi
echo "  ✓ stdout, stderr and archive -> no org token"

if ! grep -q 'Z Logon: org token$' "${CASE_DIR}"/extract/*/export.log ||
    ! grep -q 'Z Authenticating with org token$' "${CASE_DIR}"/extract/*/export.log ||
    grep -q 'Z User: ' "${CASE_DIR}"/extract/*/export.log; then
    fail "export.log -> lacks the org-token logon lines, or holds a User: line"
fi
echo "  ✓ export.log -> Logon: org token, Authenticating with org token, no User:"
echo

ORG_TOKEN_FILE="${WORK_DIR}/org-token"
printf '%s\n' "$STUB_ORG_TOKEN" >"$ORG_TOKEN_FILE"

echo "Test 7: every org-token source selects the logon"
run_export "SYNQLY_ORG_TOKEN=$STUB_ORG_TOKEN" </dev/null
assert_org_token_sent "SYNQLY_ORG_TOKEN" "$STUB_ORG_TOKEN"
run_export --org-token-file "$ORG_TOKEN_FILE" </dev/null
assert_org_token_sent "--org-token-file FILE" "$STUB_ORG_TOKEN"
printf '  %s \t\n' "$STUB_ORG_TOKEN" >"${WORK_DIR}/padded-token"
run_export --org-token-file "${WORK_DIR}/padded-token" </dev/null
assert_org_token_sent "--org-token-file FILE (surrounding whitespace)" "$STUB_ORG_TOKEN"
printf '%s\r\n' "$STUB_ORG_TOKEN" >"${WORK_DIR}/crlf-token"
run_export --org-token-file "${WORK_DIR}/crlf-token" </dev/null
assert_org_token_sent "--org-token-file FILE (Windows line ending)" "$STUB_ORG_TOKEN"
run_export "SYNQLY_ORG_TOKEN=${STUB_ORG_TOKEN}"$'\r' </dev/null
assert_org_token_sent "SYNQLY_ORG_TOKEN (trailing carriage return)" "$STUB_ORG_TOKEN"
# A named pipe stands in for <(vault kv get ...): bash closes a process
# substitution's descriptor before run_export reaches the script
mkfifo "${WORK_DIR}/token-fifo"
printf '%s\n' "$STUB_ORG_TOKEN" >"${WORK_DIR}/token-fifo" &
FIFO_WRITER=$!
run_export --org-token-file "${WORK_DIR}/token-fifo" </dev/null
kill "$FIFO_WRITER" 2>/dev/null || true
assert_org_token_sent "--org-token-file FIFO" "$STUB_ORG_TOKEN"
run_export --org-token-file - < <(printf '%s\n' "$STUB_ORG_TOKEN")
assert_org_token_sent "--org-token-file - (a line)" "$STUB_ORG_TOKEN"
run_export --org-token-file - < <(printf '%s' "$STUB_ORG_TOKEN")
assert_org_token_sent "--org-token-file - (no trailing newline)" "$STUB_ORG_TOKEN"
echo

WRONG_TOKEN_FILE="${WORK_DIR}/wrong-token"
printf '%s\n' "file-token" >"$WRONG_TOKEN_FILE"

echo "Test 8: org-token precedence"
run_export "SYNQLY_ORG_TOKEN=env-token" --org-token "$STUB_ORG_TOKEN" </dev/null
assert_org_token_sent "--org-token over SYNQLY_ORG_TOKEN" "$STUB_ORG_TOKEN"
run_export --org-token "$STUB_ORG_TOKEN" --org-token-file "$WRONG_TOKEN_FILE" </dev/null
assert_org_token_sent "--org-token over --org-token-file" "$STUB_ORG_TOKEN"
run_export "SYNQLY_ORG_TOKEN=env-token" --org-token-file "$ORG_TOKEN_FILE" </dev/null
assert_org_token_sent "--org-token-file over SYNQLY_ORG_TOKEN" "$STUB_ORG_TOKEN"
run_export "SYNQLY_ORG_TOKEN=env-token" --org-token-file - < <(printf '%s\n' "$STUB_ORG_TOKEN")
assert_org_token_sent "--org-token-file - over SYNQLY_ORG_TOKEN" "$STUB_ORG_TOKEN"
echo

echo "Test 9: unreadable org-token sources"
run_export --org-token-file "${WORK_DIR}/missing" </dev/null
assert_refused "missing --org-token-file" "Error: Org token file not found:"
run_export --org-token-file - </dev/null
assert_refused "--org-token-file - with empty stdin" "Error: no org token on stdin"
: >"${WORK_DIR}/empty-token"
run_export --org-token-file "${WORK_DIR}/empty-token" </dev/null
assert_refused "empty --org-token-file" "Error: Org token file is empty:"
echo

# Assert the token check refused the org token before any month was fetched
assert_token_check_refused() {
    local description="$1"
    local text="$2"

    if grep -q 'filter=' "$REQUESTS_FILE"; then
        fail "$description -> fetched a month"
    fi
    assert_refused "$description" "$text"
}

echo "Test 10: a refused org token ends the run before any month is fetched"
run_export --org-token not-the-token </dev/null
assert_token_check_refused "refused org token" "Authentication failed: stub refuses this token"
run_export --org-token "$STUB_EMPTY_401_TOKEN" </dev/null
assert_token_check_refused "org token refused with an empty 401" "Authentication failed: HTTP 401"
run_export --org-token "$STUB_NOT_JSON_TOKEN" </dev/null
assert_token_check_refused "org token answered with a web page" "is not a billing list"
run_export --org-token "$STUB_EMPTY_200_TOKEN" </dev/null
assert_token_check_refused "org token answered with an empty 200" "is not a billing list"
echo

# Assert the args are refused before any request, with "Error: <expected>" on
# stderr
assert_refused_early() {
    local expected="$1"
    shift

    run_export "$@" </dev/null
    if [[ -s "$REQUESTS_FILE" ]]; then
        fail "$* -> sent a request"
    fi
    assert_refused "$*" "Error: $expected"
}

echo "Test 11: flags from two logons are refused together"
assert_refused_early "--user cannot be used with --org-token" --user admin --org-token "$STUB_ORG_TOKEN"
assert_refused_early "--user cannot be used with --org-token-file" --user admin --org-token-file "$ORG_TOKEN_FILE"
for flag in --org --password --password-file --token --token-file; do
    assert_refused_early "$flag cannot be used with --org-token" --org-token "$STUB_ORG_TOKEN" "$flag" acme
    assert_refused_early "$flag cannot be used with --org-token-file" --org-token-file "$ORG_TOKEN_FILE" "$flag" acme
    assert_refused_early "$flag cannot be used with SYNQLY_ORG_TOKEN" SYNQLY_ORG_TOKEN=x "$flag" acme
done
echo

echo "Test 12: a password logon exports with the access token it was given"
: >"$CURL_ARGS_FILE"
run_export "PATH=${WORK_DIR}/bin:$PATH" --user admin --password "$ACCEPTED_SECRET" </dev/null
assert_exported "password logon" "stub-access-token"
if ! grep -q '^POST /v1/auth/logon/synqly-backoffice ' "$REQUESTS_FILE"; then
    fail "password logon -> sent no logon request"
fi
echo "  ✓ password logon -> archive written, access token sent on every billing request"
if grep -qF -- "stub-access-token" "$CURL_ARGS_FILE"; then
    fail "curl arguments -> hold the access token"
fi
echo "  ✓ curl arguments -> no access token"
echo

echo "Test 13: months outside the last 12 completed are refused before any request"
TWO_YEARS_BACK="$((NOW_YEAR - 2))-${NOW_MONTH}"
assert_refused_early "$CURRENT_MONTH is outside the months Synqly keeps" \
    --org-token "$STUB_ORG_TOKEN" --month "$CURRENT_MONTH"
assert_refused_early "$TWO_YEARS_BACK is outside the months Synqly keeps" \
    --org-token "$STUB_ORG_TOKEN" --month "$TWO_YEARS_BACK"
assert_refused_early "$TWO_YEARS_BACK is outside the months Synqly keeps" \
    --org-token "$STUB_ORG_TOKEN" --from "$TWO_YEARS_BACK" --to "$FLOOR_MONTH"
run_export --org-token "$STUB_ORG_TOKEN" --month "$FLOOR_MONTH" </dev/null
assert_org_token_sent "--month $FLOOR_MONTH, the oldest month kept" "$STUB_ORG_TOKEN"

# A month number outside 01-12 can sort inside the window
assert_refused_early "Invalid month: $((NOW_YEAR - 1))-13" \
    --org-token "$STUB_ORG_TOKEN" --month "$((NOW_YEAR - 1))-13"
assert_refused_early "Invalid month: ${NOW_YEAR}-00" \
    --org-token "$STUB_ORG_TOKEN" --month "${NOW_YEAR}-00"
assert_refused_early "Invalid month: septmber" \
    --org-token "$STUB_ORG_TOKEN" --month septmber

# Arguments are validated before any credential is read, so a bad month is
# reported ahead of an unreadable token file (or a prompt for a secret)
assert_refused_early "$CURRENT_MONTH is outside the months Synqly keeps" \
    --org-token-file "${WORK_DIR}/missing" --month "$CURRENT_MONTH"

# The previous month's name resolves to last month, and the current month's
# name to the same month last year, so this range runs backwards
CURRENT_NAME=${MONTH_NAMES[$((10#$NOW_MONTH - 1))]}
PREVIOUS_NAME=${MONTH_NAMES[$(((10#$NOW_MONTH + 10) % 12))]}
LAST_MONTH=$(printf '%d-%02d' "$NOW_YEAR" "$((10#$NOW_MONTH - 1))")
if [[ "$NOW_MONTH" == "01" ]]; then
    LAST_MONTH="$((NOW_YEAR - 1))-12"
fi
assert_refused_early "--from ($LAST_MONTH) must not be after --to ($FLOOR_MONTH)" \
    --org-token "$STUB_ORG_TOKEN" --from "$PREVIOUS_NAME" --to "$CURRENT_NAME"
if ! grep -qF "Note: a month name means its most recent completed month, so $CURRENT_NAME is $FLOOR_MONTH" "${CASE_DIR}/stderr"; then
    fail "--from $PREVIOUS_NAME --to $CURRENT_NAME -> stderr lacks the month-name note"
fi
echo "  ✓ --from $PREVIOUS_NAME --to $CURRENT_NAME -> note: $CURRENT_NAME is $FLOOR_MONTH"

# A backwards range of two YYYY-MM names no month, so it carries no note
assert_refused_early "--from ($LAST_MONTH) must not be after --to ($FLOOR_MONTH)" \
    --org-token "$STUB_ORG_TOKEN" --from "$LAST_MONTH" --to "$FLOOR_MONTH"
if grep -qF "Note: a month name" "${CASE_DIR}/stderr"; then
    fail "--from $LAST_MONTH --to $FLOOR_MONTH -> printed the month-name note"
fi
echo "  ✓ --from $LAST_MONTH --to $FLOOR_MONTH -> no month-name note"

# Months are counted in UTC, as lepton counts them. This date reads the last
# hours of September in UTC and October already in local time, where 2026-09
# looks complete but lepton still serves September 2025 under its name.
mkdir "${WORK_DIR}/utc-date"
cat >"${WORK_DIR}/utc-date/date" <<'SH'
#!/bin/bash
if [[ "$1" == "-u" ]]; then
    echo "2026-09"
    exit
fi
echo "2026-10"
SH
chmod +x "${WORK_DIR}/utc-date/date"
run_export "PATH=${WORK_DIR}/utc-date:$PATH" --org-token "$STUB_ORG_TOKEN" --month 2026-09 </dev/null
if [[ -s "$REQUESTS_FILE" ]]; then
    fail "--month 2026-09, UTC still in September -> sent a request"
fi
assert_refused "--month 2026-09, UTC still in September" \
    "Error: 2026-09 is outside the months Synqly keeps"
echo

echo "Test 14: a token holding characters outside Synqly's set is refused"
run_export --user admin --password "$HOSTILE_SECRET" </dev/null
if [[ -e "$HOSTILE_OUTPUT" ]]; then
    fail "access token carrying a config line -> curl wrote $HOSTILE_OUTPUT"
fi
assert_refused "access token carrying a config line" \
    "Error: token holds characters a Synqly token never has"
run_export --org-token 'stub"token' </dev/null
assert_refused "org token holding a quote" \
    "Error: token holds characters a Synqly token never has"
echo

echo "Test 15: a month answered with no billing list fails the run"
run_export --org-token "$STUB_BAD_RESULT_TOKEN" </dev/null
assert_refused "month answered with a string .result" "is not a billing list"
run_export --org-token "$STUB_NO_CSV_TOKEN" </dev/null
assert_refused "month answered with records lacking csv_data" "is not a billing list"
echo

echo "Test 16: a cursor from the server is sent once, URL-encoded"
run_export --org-token "$STUB_CURSOR_TOKEN" </dev/null
assert_org_token_sent "cursor {a,b}" "$STUB_CURSOR_TOKEN"
if [[ $(grep -c 'start_after=' "$REQUESTS_FILE") -ne 1 ]] ||
    ! grep -q 'start_after=%7Ba%2Cb%7D ' "$REQUESTS_FILE"; then
    fail "cursor {a,b} -> expected one request with start_after=%7Ba%2Cb%7D"
fi
echo "  ✓ cursor {a,b} -> one request, start_after=%7Ba%2Cb%7D"
echo

# Assert the last run_export saved the export route's archive under its own
# name, after one export request for <from>..<to> and no month paged from the
# billing API
assert_served() {
    local description="$1"
    local from="$2"
    local to="$3"
    local archive="${CASE_DIR}/out/synqly-billing-export-2026-09-24-120000.tar.gz"

    if [[ $RUN_RC -ne 0 ]]; then
        fail "$description -> exited $RUN_RC"
    fi
    if [[ ! -f "$archive" || "$(cat "${CASE_DIR}/stdout")" != "$archive" ]]; then
        fail "$description -> served archive not saved under its own name"
    fi
    if [[ $(grep -c '^GET /v1/billing/export' "$REQUESTS_FILE") -ne 1 ]] ||
        ! grep -qF "GET /v1/billing/export?from=${from}&to=${to} " "$REQUESTS_FILE"; then
        fail "$description -> expected one export request for from=${from}&to=${to}"
    fi
    if grep -q '^GET /v1/billing?filter=' "$REQUESTS_FILE"; then
        fail "$description -> paged the billing API"
    fi
    echo "  ✓ $description -> served archive saved, from=${from}&to=${to}"
}

echo "Test 17: a Synqly version with the export route serves the archive"
run_export --org-token "${EXPORT_PREFIX}archive" --from "$FLOOR_MONTH" --to "$LAST_MONTH" </dev/null
assert_served "--from $FLOOR_MONTH --to $LAST_MONTH" "$CURRENT_NAME" "$PREVIOUS_NAME"
if ! grep -qxF "Subject: <Your Company>: served-${CURRENT_NAME} to served-${PREVIOUS_NAME}" "${CASE_DIR}/stderr"; then
    fail "subject -> does not name the months metadata.json lists"
fi
echo "  ✓ subject -> the months metadata.json lists"
if ! grep -qxF "server: 2026-09-24T12:00:00Z stub export log" "${CASE_DIR}/stderr"; then
    fail "stderr -> lacks the served export.log, prefixed server:"
fi
echo "  ✓ stderr -> the served export.log, prefixed server:"
run_export --org-token "${EXPORT_PREFIX}archive" --month "$LAST_MONTH" </dev/null
assert_served "--month $LAST_MONTH" "$PREVIOUS_NAME" "$PREVIOUS_NAME"
run_export --user admin --password "${EXPORT_PREFIX}secret" --month "$LAST_MONTH" </dev/null
assert_served "password logon" "$PREVIOUS_NAME" "$PREVIOUS_NAME"
if ! grep -q '^POST /v1/auth/logon/synqly-backoffice ' "$REQUESTS_FILE" ||
    ! grep -qF "GET /v1/billing/export?from=${PREVIOUS_NAME}&to=${PREVIOUS_NAME} auth ${EXPORT_PREFIX}archive" "$REQUESTS_FILE"; then
    fail "password logon -> export not requested with the logon's access token"
fi
echo "  ✓ password logon -> export requested with the logon's access token"
echo

# Assert the last run_export requested the export, logged <text>, then paged
# the billing API with <token> and wrote the archive itself
assert_fell_back() {
    local description="$1"
    local token="$2"
    local text="$3"

    assert_org_token_sent "$description" "$token"
    if ! awk '/^GET \/v1\/billing\/export\?/ && !e {e = NR} /^GET \/v1\/billing\?filter=/ && !f {f = NR}
        END {exit !(e && e < f)}' "$REQUESTS_FILE"; then
        fail "$description -> export not requested before the billing API"
    fi
    if ! grep -qF -- "$text" "${CASE_DIR}/stderr"; then
        fail "$description -> stderr lacks '$text'"
    fi
    echo "  ✓ $description -> export requested first, then the billing API paged"
}

echo "Test 18: a failed export request falls back to the billing API"
run_export --org-token "$STUB_ORG_TOKEN" </dev/null
assert_fell_back "export route answers 404" "$STUB_ORG_TOKEN" "Billing export API answered HTTP 404"
run_export --org-token "${EXPORT_PREFIX}old-403" </dev/null
assert_fell_back "export route answers 403" "${EXPORT_PREFIX}old-403" "Billing export API answered HTTP 403"
run_export --org-token "${EXPORT_PREFIX}500" </dev/null
assert_fell_back "export route answers 500" "${EXPORT_PREFIX}500" "Billing export API answered HTTP 500"
run_export --org-token "${EXPORT_PREFIX}empty-502" </dev/null
assert_fell_back "export route answers an empty 502" "${EXPORT_PREFIX}empty-502" "Billing export API answered HTTP 502"
run_export --org-token "${EXPORT_PREFIX}drop" </dev/null
assert_fell_back "export route drops the connection" "${EXPORT_PREFIX}drop" "Billing export API gave no response"
echo

echo "Test 19: an export answered with no billing export archive fails the run"
run_export --org-token "${EXPORT_PREFIX}page" </dev/null
assert_refused "export route answers with a web page" "is not a billing export archive"
run_export --org-token "${EXPORT_PREFIX}escape" </dev/null
assert_refused "archive entry outside its directory" "is not a billing export archive"
echo

echo "Test 20: an export holding no billed month writes no archive"
run_export --org-token "${EXPORT_PREFIX}empty" </dev/null
if [[ $RUN_RC -ne 0 ]] || compgen -G "${CASE_DIR}/out/*.tar.gz" >/dev/null ||
    ! grep -qF "No billing data was exported." "${CASE_DIR}/stderr"; then
    fail "empty export -> expected exit 0, no archive, and 'No billing data was exported.'"
fi
echo "  ✓ empty export -> exit 0, no archive"
echo

echo "All tests passed!"

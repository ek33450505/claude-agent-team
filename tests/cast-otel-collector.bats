#!/usr/bin/env bats
# cast-otel-collector.bats — BATS tests for cast-otel-collector.py
#
# Tests the OTLP/JSON ingest modes (--ingest-file, --ingest-stdin)
# and verifies DB writes to otel_metrics and otel_events tables.
#
# All tests use an isolated temp HOME and a temp CAST_DB_PATH to avoid
# polluting the real ~/.claude/cast.db.

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
COLLECTOR_PY="$REPO_DIR/scripts/cast-otel-collector.py"
DB_INIT_SH="$REPO_DIR/scripts/cast-db-init.sh"
FIXTURES_DIR="$REPO_DIR/tests/fixtures/otel"

setup() {
  load 'helpers/setup'
  setup_temp_home

  # Isolated DB in temp HOME
  export CAST_DB_PATH="$HOME/.claude/cast-test.db"
  mkdir -p "$(dirname "$CAST_DB_PATH")"

  # Initialize DB schema
  bash "$DB_INIT_SH" --db "$CAST_DB_PATH" >/dev/null 2>&1
}

teardown() {
  teardown_temp_home
  unset CAST_DB_PATH
}

# ---------------------------------------------------------------------------
# Helper: Count rows in a table
# ---------------------------------------------------------------------------
_count_rows() {
  local table="$1"
  python3 << PYEOF
import sqlite3
try:
    conn = sqlite3.connect("$CAST_DB_PATH")
    cur = conn.execute("SELECT COUNT(*) FROM ${table};")
    count = cur.fetchone()[0]
    conn.close()
    print(count)
except Exception as e:
    print("0")
PYEOF
}

# ---------------------------------------------------------------------------
# Helper: Check if a metric with a specific name and value exists
# ---------------------------------------------------------------------------
_metric_exists() {
  local metric_name="$1"
  local value="$2"
  local unit="$3"

  python3 << PYEOF
import sqlite3
try:
    conn = sqlite3.connect("$CAST_DB_PATH")
    cur = conn.execute(
        "SELECT COUNT(*) FROM otel_metrics WHERE metric_name = ? AND value = ? AND unit = ?;",
        ("$metric_name", $value, "$unit")
    )
    count = cur.fetchone()[0]
    conn.close()
    exit(0 if count > 0 else 1)
except Exception as e:
    exit(1)
PYEOF
}

# ---------------------------------------------------------------------------
# Helper: Check if an event with a specific event_name exists
# ---------------------------------------------------------------------------
_event_exists() {
  local event_name="$1"

  python3 << PYEOF
import sqlite3
try:
    conn = sqlite3.connect("$CAST_DB_PATH")
    cur = conn.execute(
        "SELECT COUNT(*) FROM otel_events WHERE event_name = ?;",
        ("$event_name",)
    )
    count = cur.fetchone()[0]
    conn.close()
    exit(0 if count > 0 else 1)
except Exception as e:
    exit(1)
PYEOF
}

# ---------------------------------------------------------------------------
# Test 1: Ingest metrics.json inserts rows with correct metric and value
# ---------------------------------------------------------------------------
@test "ingest-file metrics.json inserts rows into otel_metrics" {
  run python3 "$COLLECTOR_PY" --ingest-file "$FIXTURES_DIR/metrics.json"
  assert_success
  assert_output --regexp "metrics=2 events=0"
}

@test "ingest-file metrics.json contains claude_code.cost.usage with value 0.0234 USD" {
  python3 "$COLLECTOR_PY" --ingest-file "$FIXTURES_DIR/metrics.json" >/dev/null 2>&1

  # Verify the metric exists in the database
  _metric_exists "claude_code.cost.usage" "0.0234" "USD"
}

@test "ingest-file metrics.json contains claude_code.token.usage with unit tokens" {
  python3 "$COLLECTOR_PY" --ingest-file "$FIXTURES_DIR/metrics.json" >/dev/null 2>&1

  # Verify the second metric exists
  _metric_exists "claude_code.token.usage" "1500" "tokens"
}

# ---------------------------------------------------------------------------
# Test 2: Ingest logs.json inserts rows into otel_events
# ---------------------------------------------------------------------------
@test "ingest-file logs.json inserts rows into otel_events" {
  run python3 "$COLLECTOR_PY" --ingest-file "$FIXTURES_DIR/logs.json"
  assert_success
  assert_output --regexp "metrics=0 events=2"
}

@test "ingest-file logs.json contains claude_code.user_prompt event" {
  python3 "$COLLECTOR_PY" --ingest-file "$FIXTURES_DIR/logs.json" >/dev/null 2>&1

  # Verify the event exists
  _event_exists "claude_code.user_prompt"
}

@test "ingest-file logs.json contains claude_code.api_request event" {
  python3 "$COLLECTOR_PY" --ingest-file "$FIXTURES_DIR/logs.json" >/dev/null 2>&1

  # Verify both events exist
  _event_exists "claude_code.api_request"
}

# ---------------------------------------------------------------------------
# Test 3: Gzip-compressed metrics.json.gz yields same rows as uncompressed
# ---------------------------------------------------------------------------
@test "ingest-file metrics.json.gz decompresses and inserts same rows as uncompressed" {
  # Ingest uncompressed
  python3 "$COLLECTOR_PY" --ingest-file "$FIXTURES_DIR/metrics.json" >/dev/null 2>&1
  local uncompressed_count
  uncompressed_count=$(_count_rows "otel_metrics")

  # Clear DB and ingest compressed
  sqlite3 "$CAST_DB_PATH" "DELETE FROM otel_metrics;" 2>/dev/null

  python3 "$COLLECTOR_PY" --ingest-file "$FIXTURES_DIR/metrics.json.gz" >/dev/null 2>&1
  local compressed_count
  compressed_count=$(_count_rows "otel_metrics")

  # Counts must match
  [[ "$uncompressed_count" -eq "$compressed_count" ]]
}

@test "ingest-file metrics.json.gz contains claude_code.cost.usage with value 0.0234 USD" {
  python3 "$COLLECTOR_PY" --ingest-file "$FIXTURES_DIR/metrics.json.gz" >/dev/null 2>&1

  # Verify the metric exists
  _metric_exists "claude_code.cost.usage" "0.0234" "USD"
}

# ---------------------------------------------------------------------------
# Test 4: Malformed JSON fails gracefully (fail-open)
# ---------------------------------------------------------------------------
@test "ingest-file malformed.json exits 0 with zero rows (fail-open)" {
  run python3 "$COLLECTOR_PY" --ingest-file "$FIXTURES_DIR/malformed.json"

  # Must succeed (fail-open policy)
  assert_success

  # Output must show zero metrics and events
  assert_output --regexp "metrics=0 events=0"

  # DB must have zero rows
  local metric_count
  metric_count=$(_count_rows "otel_metrics")
  [[ "$metric_count" -eq 0 ]]
}

# ---------------------------------------------------------------------------
# Test 5: BIND-SAFETY guard — script contains 127.0.0.1, NOT 0.0.0.0
# ---------------------------------------------------------------------------
@test "BIND-SAFETY: cast-otel-collector.py contains 127.0.0.1 bind" {
  grep -q "127.0.0.1" "$COLLECTOR_PY"
}

@test "BIND-SAFETY: cast-otel-collector.py does NOT contain 0.0.0.0 (local-first)" {
  # This should FAIL (grep returns 1 when pattern not found) — which means
  # the script does NOT contain 0.0.0.0
  ! grep -q "0.0.0.0" "$COLLECTOR_PY"
}

# ---------------------------------------------------------------------------
# Test 6: Session ID extraction from resource attrs
# ---------------------------------------------------------------------------
@test "ingest-file metrics.json extracts session.id from resource attributes" {
  python3 "$COLLECTOR_PY" --ingest-file "$FIXTURES_DIR/metrics.json" >/dev/null 2>&1

  # Query the session_id field in otel_metrics
  local session_id
  session_id=$(sqlite3 "$CAST_DB_PATH" \
    "SELECT session_id FROM otel_metrics LIMIT 1;" 2>/dev/null || echo "")

  [[ "$session_id" == "sess-test-abc123" ]]
}

# ---------------------------------------------------------------------------
# Test 7: stdin ingest mode
# ---------------------------------------------------------------------------
@test "ingest-stdin reads from stdin and inserts rows" {
  # Pipe metrics.json to stdin
  run bash -c "cat '$FIXTURES_DIR/metrics.json' | python3 '$COLLECTOR_PY' --ingest-stdin"
  assert_success
  assert_output --regexp "metrics=2 events=0"
}

# ---------------------------------------------------------------------------
# Test 8: Multiple consecutive ingests (idempotency — rows accumulate)
# ---------------------------------------------------------------------------
@test "Multiple ingest-file calls accumulate rows in DB" {
  # First ingest
  python3 "$COLLECTOR_PY" --ingest-file "$FIXTURES_DIR/metrics.json" >/dev/null 2>&1
  local first_count
  first_count=$(_count_rows "otel_metrics")

  # Second ingest (same file)
  python3 "$COLLECTOR_PY" --ingest-file "$FIXTURES_DIR/metrics.json" >/dev/null 2>&1
  local second_count
  second_count=$(_count_rows "otel_metrics")

  # Rows should double
  [[ "$second_count" -eq $((first_count * 2)) ]]
}

# ---------------------------------------------------------------------------
# Test 9: Subtraction Safety Gate — native OTEL feed captures compaction events
# (v9 B3 recorder-subtraction: cast-post-compact-hook.sh DB write retired;
# the native 'compaction' event now covers this via otel_events)
# Audit: plans/b3-hook-feed-coverage-audit.md
# ---------------------------------------------------------------------------
@test "subtraction-safety: compaction event lands in otel_events (covers retired cast-post-compact-hook.sh DB write)" {
  # Build compaction fixture path (tests/fixtures/otel/compaction.json)
  local fixture_path
  fixture_path="$FIXTURES_DIR/compaction.json"

  # Ingest through the collector's offline mode
  run python3 "$COLLECTOR_PY" --ingest-file "$fixture_path"
  assert_success

  # Summary line must report at least 1 event
  assert_output --regexp "events=[1-9]"

  # The compaction event must be findable in otel_events by event_name
  _event_exists "claude_code.compaction"
}

# ---------------------------------------------------------------------------
# Test 10: HTTP-level Transfer-Encoding: chunked regression
#
# Root cause (2026-07-09): do_POST only read the body via Content-Length.
# http.server does not auto-dechunk request bodies, so a client sending
# Transfer-Encoding: chunked (no/zero Content-Length) had its raw chunk
# framing bytes (hex chunk-size + CRLF + data + CRLF ...) handed straight
# to json.loads(), which failed on every single request — silently
# discarding 100% of telemetry for ~7 days (~/.claude/logs/otel-collector.log
# showed continuous "JSON parse error: Expecting value.../Extra data..."
# at small char offsets 0-7, matching hex chunk-size line lengths).
#
# These tests spawn the real HTTP daemon (--serve) on a scratch port against
# the isolated temp-HOME CAST_DB_PATH and drive it with genuine chunked
# framing via Python's http.client (curl's chunked encoder does not exercise
# the same code path reliably).
# ---------------------------------------------------------------------------
_start_collector_http() {
  local port="$1"
  CAST_OTEL_PORT="$port" CAST_DB_PATH="$CAST_DB_PATH" \
    python3 "$COLLECTOR_PY" --serve >"$BATS_TEST_TMPDIR/collector-http.log" 2>&1 &
  COLLECTOR_HTTP_PID=$!
  # Wait for the port to accept connections (bounded poll, avoids fixed sleep flakiness)
  for _ in $(seq 1 50); do
    if python3 -c "import socket; s=socket.create_connection(('127.0.0.1', $port), timeout=0.2); s.close()" 2>/dev/null; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

_stop_collector_http() {
  if [[ -n "${COLLECTOR_HTTP_PID:-}" ]]; then
    kill "$COLLECTOR_HTTP_PID" 2>/dev/null || true
    wait "$COLLECTOR_HTTP_PID" 2>/dev/null || true
    unset COLLECTOR_HTTP_PID
  fi
}

@test "HTTP: chunked POST to /v1/logs is de-chunked, parsed, and lands in otel_events" {
  local port=48391
  _start_collector_http "$port"

  run python3 -c "
import http.client
conn = http.client.HTTPConnection('127.0.0.1', $port, timeout=5)
body = (b'{\"resourceLogs\":[{\"resource\":{\"attributes\":['
        b'{\"key\":\"session.id\",\"value\":{\"stringValue\":\"chunked-bats-sess\"}}]},'
        b'\"scopeLogs\":[{\"logRecords\":[{\"timeUnixNano\":\"1719216100000000000\",'
        b'\"severityText\":\"INFO\",\"attributes\":['
        b'{\"key\":\"event.name\",\"value\":{\"stringValue\":\"test.chunked\"}}],'
        b'\"body\":{\"stringValue\":\"hello chunked\"}}]}]}]}')
conn.putrequest('POST', '/v1/logs')
conn.putheader('Transfer-Encoding', 'chunked')
conn.putheader('Content-Type', 'application/json')
conn.endheaders()
mid = len(body) // 2
conn.send(b'%x\r\n' % mid + body[:mid] + b'\r\n')
conn.send(b'%x\r\n' % (len(body) - mid) + body[mid:] + b'\r\n')
conn.send(b'0\r\n\r\n')
resp = conn.getresponse()
print(resp.status)
"
  _stop_collector_http

  assert_success
  assert_output "200"

  _event_exists "test.chunked"
}

@test "HTTP: malformed chunk-size line is rejected with 400 (no hang, no crash)" {
  local port=48392
  _start_collector_http "$port"

  # Client-side socket timeout (5s) bounds this call — no shell `timeout` wrapper
  # (GNU coreutils `timeout` is absent on stock macOS/BSD userland).
  run python3 -c "
import http.client
conn = http.client.HTTPConnection('127.0.0.1', $port, timeout=5)
conn.putrequest('POST', '/v1/logs')
conn.putheader('Transfer-Encoding', 'chunked')
conn.endheaders()
conn.send(b'ZZZZ-not-hex\r\n')
resp = conn.getresponse()
print(resp.status)
"
  _stop_collector_http

  assert_success
  assert_output "400"
}

@test "HTTP: non-chunked Content-Length POST still works after chunked-decoding fix" {
  local port=48393
  _start_collector_http "$port"

  run curl -s -o /dev/null -w '%{http_code}' -X POST \
    "http://127.0.0.1:${port}/v1/logs" \
    -H 'Content-Type: application/json' \
    -d '{"resourceLogs":[]}'

  _stop_collector_http

  assert_success
  assert_output "200"
}

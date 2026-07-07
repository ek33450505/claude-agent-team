#!/usr/bin/env bats
# Tests for cast ledger — signed per-session audit receipt (A5)

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
CAST_BIN="$REPO_DIR/bin/cast"

setup() {
  load 'helpers/setup'
  setup_temp_home
  mkdir -p "$HOME/.claude"
  export CAST_DB_PATH="$HOME/.claude/cast.db"
  export CAST_SCRIPTS_DIR="$REPO_DIR/scripts"

  # Build real schema via cast-db-init.sh (source of truth)
  bash "$REPO_DIR/scripts/cast-db-init.sh" >/dev/null 2>&1

  # Seed data
  sqlite3 "$CAST_DB_PATH" <<'SQL'
INSERT INTO sessions (id, project, project_root, started_at, ended_at, status)
VALUES ('sess-A', 'cast', '/x', '2026-06-28T10:00:00', '2026-06-28T10:30:00', 'completed');

INSERT INTO agent_runs
  (session_id, agent, model, started_at, ended_at, status,
   input_tokens, output_tokens, cost_usd,
   cache_read_input_tokens, cache_creation_input_tokens,
   duration_ms, tool_uses)
VALUES
  ('sess-A', 'code-writer', 'claude-sonnet-4-6',
   '2026-06-28T10:01:00', '2026-06-28T10:10:00', 'completed',
   1000, 500, 0.0025, 200, 50, 540000, 12),
  ('sess-A', 'code-reviewer', 'claude-haiku-4-5',
   '2026-06-28T10:11:00', '2026-06-28T10:15:00', 'completed',
   300, 100, 0.0005, 50, 10, 240000, 3);

INSERT INTO file_writes (session_id, agent_name, file_path, tool_name, ts)
VALUES
  ('sess-A', 'code-writer', '/x/scripts/foo.py', 'Write', '2026-06-28T10:05:00'),
  ('sess-A', 'code-writer', '/x/scripts/bar.py', 'Edit',  '2026-06-28T10:07:00');

INSERT INTO routing_events (session_id, timestamp, action, matched_route, pattern, event_type, data)
VALUES ('sess-A', '2026-06-28T10:00:30', 'dispatch', 'code-writer', 'feat/*', 'route_matched', '{}');

INSERT INTO quality_gates
  (session_id, agent_name, status_line, contract_passed, retry_count, gate_type, created_at)
VALUES ('sess-A', 'code-reviewer', 'Status: DONE', 1, 0, 'review', '2026-06-28T10:15:30');
SQL
}

teardown() {
  teardown_temp_home
}

# ── Test 1: renders the receipt ───────────────────────────────────────────────

@test "ledger: renders receipt for sess-A" {
  run bash "$CAST_BIN" ledger sess-A
  assert_success
  assert_output --partial "sess-A"
  assert_output --partial "code-writer"
  assert_output --partial "/x/scripts/foo.py"
  assert_output --partial "Digest: sha256:"
}

# ── Test 2: --json valid ──────────────────────────────────────────────────────

@test "ledger: --json emits parseable JSON with digest and receipt" {
  run bash "$CAST_BIN" ledger sess-A --json
  assert_success
  echo "$output" | python3 -c "
import sys, json
data = json.loads(sys.stdin.read())
assert isinstance(data, dict), 'Expected dict'
assert 'digest' in data, 'Missing digest key'
assert 'receipt' in data, 'Missing receipt key'
assert isinstance(data['receipt'], dict), 'receipt should be a dict'
print('OK')
"
  [ "$?" -eq 0 ]
}

# ── Test 3: digest determinism ────────────────────────────────────────────────

@test "ledger: digest is deterministic across two renders" {
  digest1=$(bash "$CAST_BIN" ledger sess-A | grep "^Digest:" | head -1)
  digest2=$(bash "$CAST_BIN" ledger sess-A | grep "^Digest:" | head -1)
  [ -n "$digest1" ]
  [ "$digest1" = "$digest2" ]
}

# ── Test 4: --verify PASS ─────────────────────────────────────────────────────

@test "ledger: --verify returns PASS for an unmodified receipt" {
  local receipt_file="$BATS_TEST_TMPDIR/receipt.md"
  bash "$CAST_BIN" ledger sess-A --out "$receipt_file"
  run bash "$CAST_BIN" ledger --verify "$receipt_file"
  assert_success
  assert_output --partial "VERIFY: PASS"
}

# ── Test 5: --verify TAMPERED ─────────────────────────────────────────────────

@test "ledger: --verify returns TAMPERED after digest mutation" {
  local receipt_file="$BATS_TEST_TMPDIR/receipt_tamper.md"
  bash "$CAST_BIN" ledger sess-A --out "$receipt_file"
  # Mutate the sha256 hex by replacing the last character with 'x'
  python3 -c "
import re, sys
content = open('$receipt_file').read()
content = re.sub(r'(Digest: sha256:[0-9a-f]{63})[0-9a-f]', r'\g<1>x', content)
open('$receipt_file', 'w').write(content)
"
  run bash "$CAST_BIN" ledger --verify "$receipt_file"
  assert_failure
  assert_output --partial "TAMPERED"
}

# ── Test 6: default = most-recent session ─────────────────────────────────────

@test "ledger: no SESSION_ID renders the most-recent session (sess-A not sess-B)" {
  # Seed an older session sess-B
  sqlite3 "$CAST_DB_PATH" <<'SQL'
INSERT INTO sessions (id, project, project_root, started_at, ended_at, status)
VALUES ('sess-B', 'cast', '/y', '2026-06-27T08:00:00', '2026-06-27T08:30:00', 'completed');
SQL
  run bash "$CAST_BIN" ledger
  assert_success
  assert_output --partial "sess-A"
  refute_output --partial "sess-B"
}

# ── Test 7: --since filters ───────────────────────────────────────────────────

@test "ledger: --since filters to include sess-A but exclude older sess-B" {
  # Seed sess-B with earlier date
  sqlite3 "$CAST_DB_PATH" <<'SQL'
INSERT OR IGNORE INTO sessions (id, project, project_root, started_at, ended_at, status)
VALUES ('sess-B', 'cast', '/y', '2026-06-27T08:00:00', '2026-06-27T08:30:00', 'completed');
SQL
  # Cutoff: after sess-B (2026-06-27) but before sess-A (2026-06-28)
  run bash "$CAST_BIN" ledger --since "2026-06-28"
  assert_success
  assert_output --partial "sess-A"
  refute_output --partial "sess-B"
}

# ── Test 8: nonexistent session exits 1 with a clear message ─────────────────

@test "ledger: nonexistent session exits 1 with a clear error (no traceback)" {
  # Merge stderr into stdout so assert_output can inspect the error message
  run bash -c "bash \"$CAST_BIN\" ledger no-such-session-id 2>&1"
  assert_failure
  # Must NOT be a Python traceback
  refute_output --partial "Traceback"
  assert_output --partial "no such session"
}

# ── Test 9: H2 regression — verify rejects tampered multi-session receipt ─────

@test "ledger: --verify rejects multi-session receipt with missing Digest (H2)" {
  bash "$REPO_DIR/scripts/cast-db-init.sh" >/dev/null 2>&1
  sqlite3 "$CAST_DB_PATH" "INSERT OR IGNORE INTO sessions (id,project,project_root,started_at,ended_at,status) VALUES ('sess-A','cast','/x','2026-06-28T10:00:00','2026-06-28T10:30:00','completed'),('sess-B','cast','/x','2026-06-27T09:00:00','2026-06-27T09:30:00','completed');"
  sqlite3 "$CAST_DB_PATH" "INSERT OR IGNORE INTO agent_runs (session_id,agent,model,status,started_at,ended_at,cost_usd,tool_uses) VALUES ('sess-A','code-writer','claude-opus-4-8','DONE','2026-06-28T10:01:00','2026-06-28T10:05:00',0.12,7),('sess-B','docs','claude-sonnet-4-6','DONE','2026-06-27T09:01:00','2026-06-27T09:03:00',0.03,3);"

  # Render both sessions to a file
  run bash "$CAST_BIN" ledger --last 2 --out "$BATS_TEST_TMPDIR/multi.md"
  assert_success

  # Drop ONLY the FIRST "Digest:" line (portable awk — BSD + GNU)
  awk 'BEGIN{done=0} /^Digest:/{ if(done==0){done=1; next} } {print}' \
    "$BATS_TEST_TMPDIR/multi.md" > "$BATS_TEST_TMPDIR/multi.tampered.md"

  # Verify should fail with "malformed receipt"
  run bash -c "bash \"$CAST_BIN\" ledger --verify \"$BATS_TEST_TMPDIR/multi.tampered.md\" 2>&1"
  assert_failure
  assert_output --partial "malformed receipt"
}

# ── Test 10: M1 regression — raw_excerpt freetext must NOT leak into receipt ──

@test "ledger: raw_excerpt from agent_protocol_violations is NOT in rendered receipt (M1)" {
  # Seed a protocol violation row with a sentinel raw_excerpt value
  sqlite3 "$CAST_DB_PATH" "INSERT INTO agent_protocol_violations (session_id,agent_type,violation,pattern,timestamp,raw_excerpt) VALUES ('sess-A','code-writer','no-status-block','status_missing','2026-06-28T10:00:00','SENSITIVE_RAW_EXCERPT_SENTINEL_XYZ');"

  run bash "$CAST_BIN" ledger sess-A
  assert_success
  # Rendered as: - **Protocol violations:** 1  (markdown bold wraps the label)
  assert_output --partial "Protocol violations:** 1"
  refute_output --partial "SENSITIVE_RAW_EXCERPT_SENTINEL_XYZ"
}

# ── Test 11: M1 residual — last_line and partial_work_log of agent_truncations must NOT leak ──

@test "ledger: last_line and partial_work_log from agent_truncations are NOT in rendered receipt (M1 residual)" {
  # Seed an agent_truncations row with sentinel values in both freetext columns
  sqlite3 "$CAST_DB_PATH" "INSERT INTO agent_truncations (session_id,agent_type,last_line,timestamp,partial_work_log) VALUES ('sess-A','code-writer','TRUNC_LASTLINE_SENTINEL_QRS','2026-06-28T10:00:00','PARTIAL_WORKLOG_SENTINEL_TUV');"

  run bash "$CAST_BIN" ledger sess-A
  assert_success
  # Rendered as: - **Truncations:** 1  (markdown bold wraps the label)
  assert_output --partial "Truncations:** 1"
  refute_output --partial "TRUNC_LASTLINE_SENTINEL_QRS"
  refute_output --partial "PARTIAL_WORKLOG_SENTINEL_TUV"
}

# ── Test 12: P5 regression — quality_gates reader excludes truncation-mirror rows ──

@test "ledger: quality_gates reader excludes truncation-mirror rows (P5 fix)" {
  # Seed a distinct session with one real gate + one truncation-mirror row
  sqlite3 "$CAST_DB_PATH" <<'SQL'
INSERT INTO sessions (id, project, project_root, started_at, ended_at, status)
VALUES ('sess-p5', 'cast', '/p5', '2026-07-06T10:00:00', '2026-07-06T10:30:00', 'completed');

INSERT INTO agent_runs (session_id, agent, model, started_at, ended_at, status, input_tokens, output_tokens, cost_usd, cache_read_input_tokens, cache_creation_input_tokens, duration_ms, tool_uses)
VALUES ('sess-p5', 'code-writer', 'claude-sonnet-4-6', '2026-07-06T10:01:00', '2026-07-06T10:10:00', 'completed', 500, 200, 0.001, 0, 0, 120000, 5);

INSERT INTO quality_gates (id, session_id, agent_name, status_line, contract_passed, retry_count, gate_type, created_at)
VALUES
  ('p5-gate-1', 'sess-p5', 'code-reviewer', 'DONE', 1, 0, 'status_contract', '2026-07-06T10:15:00'),
  ('p5-gate-2', 'sess-p5', 'code-writer',   'TRUNCATED', 0, 0, 'truncation_detected', '2026-07-06T10:16:00');
SQL

  run bash "$CAST_BIN" ledger sess-p5
  assert_success
  # Real gate row must appear in the Gates section
  assert_output --partial "code-reviewer"
  assert_output --partial "status_contract"
  # Truncation mirror row must NOT appear
  refute_output --partial "truncation_detected"
}

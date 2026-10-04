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

# ══ Read-failure reporting: ERROR and EMPTY must not look identical ═══════════
#
# Every fetcher used to swallow sqlite3.OperationalError and return [], so a
# dropped/renamed column rendered a confident, EMPTY, correctly-signed receipt.
# Failures are now collected out-of-band (never into the digest), the receipt is
# marked INCOMPLETE, and the exit code is 3.

LEDGER_PY="$REPO_DIR/scripts/cast-ledger.py"

# Digest of the setup() fixture's sess-A, produced by the PRE-CHANGE script
# (git show HEAD:scripts/cast-ledger.py before the read-error work). Pinned as a
# literal because a HEAD-vs-working-tree comparison goes vacuous once this change
# is itself committed. If you deliberately change the setup() seed data or the
# canonical receipt shape, regenerate it; otherwise a mismatch is a digest break.
GOLDEN_DIGEST_SESS_A="sha256:94fc999c1f34cd4113fecc2542a1888233c8e7b61a8c760e01941703dcae68cf"

# Simulate a schema break: rename a column the agent_runs query selects, so the
# SELECT raises "no such column: cost_usd".
_break_agent_runs() {
  sqlite3 "$CAST_DB_PATH" "ALTER TABLE agent_runs RENAME COLUMN cost_usd TO cost_usd_old;"
}

# Run `cast ledger ARGS...` with stdout in $output and stderr in $BATS_TEST_TMPDIR/err.txt.
_run_ledger_split() {
  run bash -c "bash \"$CAST_BIN\" ledger \"\$@\" 2>\"$BATS_TEST_TMPDIR/err.txt\"" _ "$@"
}

# ── Healthy DB: nothing changes ───────────────────────────────────────────────

@test "ledger: healthy DB markdown — exit 0, no WARNING, no INCOMPLETE" {
  _run_ledger_split sess-A
  assert_success
  assert_output --partial "Digest: sha256:"
  refute_output --partial "INCOMPLETE"
  run cat "$BATS_TEST_TMPDIR/err.txt"
  refute_output --partial "WARNING"
  refute_output --partial "INCOMPLETE"
}

@test "ledger: healthy DB --json — exit 0, no read_errors key, no WARNING" {
  _run_ledger_split sess-A --json
  assert_success
  refute_output --partial "read_errors"
  echo "$output" | python3 -c "
import sys, json
d = json.loads(sys.stdin.read())
assert 'read_errors' not in d, d.keys()
assert sorted(d.keys()) == ['digest', 'receipt'], d.keys()
"
  run cat "$BATS_TEST_TMPDIR/err.txt"
  refute_output --partial "WARNING"
}

# ── Golden digest: a healthy read is byte-identical to the pre-change script ──

@test "ledger: golden digest — markdown matches the pinned digest and HEAD's script" {
  python3 "$LEDGER_PY" sess-A --db "$CAST_DB_PATH" > "$BATS_TEST_TMPDIR/new.md"
  run grep "^Digest:" "$BATS_TEST_TMPDIR/new.md"
  assert_output "Digest: $GOLDEN_DIGEST_SESS_A"

  local head_py="$BATS_TEST_TMPDIR/ledger_head.py"
  if git -C "$REPO_DIR" show HEAD:scripts/cast-ledger.py > "$head_py" 2>/dev/null && [ -s "$head_py" ]; then
    python3 "$head_py" sess-A --db "$CAST_DB_PATH" > "$BATS_TEST_TMPDIR/head.md"
    diff "$BATS_TEST_TMPDIR/head.md" "$BATS_TEST_TMPDIR/new.md"
  fi
}

@test "ledger: golden digest — --json matches the pinned digest and HEAD's script" {
  python3 "$LEDGER_PY" sess-A --json --db "$CAST_DB_PATH" > "$BATS_TEST_TMPDIR/new.json"
  run python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['digest'])" "$BATS_TEST_TMPDIR/new.json"
  assert_output "$GOLDEN_DIGEST_SESS_A"

  local head_py="$BATS_TEST_TMPDIR/ledger_head.py"
  if git -C "$REPO_DIR" show HEAD:scripts/cast-ledger.py > "$head_py" 2>/dev/null && [ -s "$head_py" ]; then
    python3 "$head_py" sess-A --json --db "$CAST_DB_PATH" > "$BATS_TEST_TMPDIR/head.json"
    diff "$BATS_TEST_TMPDIR/head.json" "$BATS_TEST_TMPDIR/new.json"
  fi
}

# ── Schema break: the receipt is INCOMPLETE, never confidently empty ──────────

@test "ledger: broken agent_runs schema (markdown) — exit 3, stderr WARNING, INCOMPLETE banner" {
  _break_agent_runs
  _run_ledger_split sess-A
  assert_equal "$status" 3
  # Banner is in the receipt itself and names the failed section + the real error
  assert_output --partial "INCOMPLETE RECEIPT"
  assert_output --partial "agent_runs"
  assert_output --partial "no such column: cost_usd"
  # The receipt is still rendered and signed; the OTHER sections are intact
  assert_output --partial "/x/scripts/foo.py"
  assert_output --partial "Digest: sha256:"
  run cat "$BATS_TEST_TMPDIR/err.txt"
  assert_output --partial "cast ledger: WARNING: agent_runs query failed (OperationalError: no such column: cost_usd)"
  assert_output --partial "receipt is INCOMPLETE, not empty"
}

@test "ledger: broken agent_runs schema (--json) — exit 3, read_errors outside the digested receipt" {
  _break_agent_runs
  _run_ledger_split sess-A --json
  assert_equal "$status" 3
  echo "$output" | python3 -c "
import sys, json, hashlib
d = json.loads(sys.stdin.read())
errs = d['read_errors']
assert [e['section'] for e in errs] == ['agent_runs'], errs
assert 'no such column' in errs[0]['error'], errs
assert errs[0]['error'].startswith('OperationalError:'), errs
# Errors live BESIDE the receipt, never inside it
assert 'read_errors' not in d['receipt'], d['receipt'].keys()
assert d['receipt']['agents'] == []
# ...and the digest covers the receipt only (re-hash it independently)
blob = json.dumps(d['receipt'], sort_keys=True, separators=(',', ':'), ensure_ascii=False, default=str)
assert d['digest'] == 'sha256:' + hashlib.sha256(blob.encode('utf-8')).hexdigest()
"
  run cat "$BATS_TEST_TMPDIR/err.txt"
  assert_output --partial "WARNING: agent_runs query failed"
}

@test "ledger: digest under a broken agent_runs schema equals the digest with agent_runs emptied (errors never enter the digest)" {
  # Same DB content, two ways to get "no agent rows": rows deleted (healthy read of
  # an empty table) vs. the query raising. If a read error leaked into the digested
  # data, the second digest would differ from the first.
  local empty_db="$BATS_TEST_TMPDIR/empty_agent_runs.db"
  sqlite3 "$CAST_DB_PATH" ".backup '$empty_db'"
  sqlite3 "$empty_db" "DELETE FROM agent_runs;"

  run python3 "$LEDGER_PY" sess-A --json --db "$empty_db"
  assert_success
  local digest_empty
  digest_empty=$(echo "$output" | python3 -c "import sys, json; print(json.load(sys.stdin)['digest'])")

  _break_agent_runs
  _run_ledger_split sess-A --json
  assert_equal "$status" 3
  local digest_broken
  digest_broken=$(echo "$output" | python3 -c "import sys, json; print(json.load(sys.stdin)['digest'])")

  [[ "$digest_empty" == sha256:* ]]
  assert_equal "$digest_broken" "$digest_empty"
  # Discriminating: emptying agent_runs really changed the data (this is not the healthy digest)
  [ "$digest_empty" != "$GOLDEN_DIGEST_SESS_A" ]
}

@test "ledger: broken schema still writes the --out receipt, with exit 3" {
  _break_agent_runs
  local out_file="$BATS_TEST_TMPDIR/incomplete.md"
  _run_ledger_split sess-A --out "$out_file"
  assert_equal "$status" 3
  [ -s "$out_file" ]
  run grep -c "INCOMPLETE RECEIPT" "$out_file"
  assert_output "1"
  run grep "^Digest: sha256:" "$out_file"
  assert_success
}

@test "ledger: --last with a broken schema — per-session WARNING and per-item read_errors" {
  sqlite3 "$CAST_DB_PATH" "INSERT INTO sessions (id,project,project_root,started_at,ended_at,status) VALUES ('sess-B','cast','/y','2026-06-27T08:00:00','2026-06-27T08:30:00','completed');"
  _break_agent_runs
  _run_ledger_split --last 2 --json
  assert_equal "$status" 3
  echo "$output" | python3 -c "
import sys, json
items = json.loads(sys.stdin.read())
assert len(items) == 2, len(items)
for it in items:
    assert [e['section'] for e in it['read_errors']] == ['agent_runs'], it
"
  run cat "$BATS_TEST_TMPDIR/err.txt"
  assert_output --partial "(session sess-A)"
  assert_output --partial "(session sess-B)"
}

# ── --verify: UNVERIFIABLE is not TAMPERED ────────────────────────────────────

@test "ledger: --verify PASS on a healthy re-derive, UNVERIFIABLE (not TAMPERED) after the schema breaks" {
  local receipt_file="$BATS_TEST_TMPDIR/receipt_ok.md"
  bash "$CAST_BIN" ledger sess-A --out "$receipt_file"

  run bash "$CAST_BIN" ledger --verify "$receipt_file"
  assert_success
  assert_output --partial "VERIFY: PASS"

  _break_agent_runs
  run bash "$CAST_BIN" ledger --verify "$receipt_file"
  # Pinned to 3 (not just non-zero): UNVERIFIABLE must stay distinguishable from TAMPERED's 1
  assert_equal "$status" 3
  assert_output --partial "VERIFY: UNVERIFIABLE (session sess-A: read error in agent_runs: OperationalError: no such column: cost_usd)"
  refute_output --partial "TAMPERED"
  refute_output --partial "VERIFY: PASS"
}

@test "ledger: --verify UNVERIFIABLE when the sessions table cannot be read" {
  local receipt_file="$BATS_TEST_TMPDIR/receipt_sess.md"
  bash "$CAST_BIN" ledger sess-A --out "$receipt_file"
  sqlite3 "$CAST_DB_PATH" "DROP TABLE sessions;"
  run bash "$CAST_BIN" ledger --verify "$receipt_file"
  assert_equal "$status" 3
  assert_output --partial "VERIFY: UNVERIFIABLE (session sess-A: read error in sessions:"
  refute_output --partial "TAMPERED"
}

@test "ledger: --verify of a mixed receipt prints both verdicts and exits 1 (TAMPERED outranks UNVERIFIABLE)" {
  sqlite3 "$CAST_DB_PATH" "INSERT INTO sessions (id,project,project_root,started_at,ended_at,status) VALUES ('sess-B','cast','/y','2026-06-27T08:00:00','2026-06-27T08:30:00','completed');"
  local receipt_file="$BATS_TEST_TMPDIR/receipt_mixed.md"
  bash "$CAST_BIN" ledger --last 2 --out "$receipt_file"
  run grep -c "^Digest: sha256:" "$receipt_file"
  assert_output "2"

  # sess-A: still in cast.db but its agent_runs query now fails -> UNVERIFIABLE
  _break_agent_runs
  # sess-B: gone from cast.db entirely (clean read, no such session) -> TAMPERED
  sqlite3 "$CAST_DB_PATH" "DELETE FROM sessions WHERE id = 'sess-B';"

  run bash "$CAST_BIN" ledger --verify "$receipt_file"
  assert_equal "$status" 1
  assert_output --partial "VERIFY: UNVERIFIABLE (session sess-A: read error in agent_runs:"
  assert_output --partial "VERIFY: TAMPERED (session sess-B: not found in cast.db"
  refute_output --partial "VERIFY: PASS"
}

# ── Session resolution: a read failure is not "no sessions found" ─────────────

@test "ledger: sessions table missing — every resolution mode reports the error and exits 3" {
  sqlite3 "$CAST_DB_PATH" "DROP TABLE sessions;"
  local mode
  for mode in "sess-A" "" "--last 1" "--since 2026-01-01"; do
    # shellcheck disable=SC2086  # intentional word-splitting of the mode flags
    _run_ledger_split $mode
    if [ "$status" -ne 3 ]; then echo "# mode='$mode' exited $status: $output" >&3; fi
    assert_equal "$status" 3
    run cat "$BATS_TEST_TMPDIR/err.txt"
    assert_output --partial "ERROR: sessions query failed (OperationalError: no such table: sessions)"
    refute_output --partial "no such session"
    refute_output --partial "no sessions found"
  done
}

@test "ledger: genuinely empty sessions table is still 'no sessions found' (exit 1, not a read error)" {
  sqlite3 "$CAST_DB_PATH" "DELETE FROM sessions;"
  run bash -c "bash \"$CAST_BIN\" ledger --last 1 2>&1"
  assert_equal "$status" 1
  assert_output --partial "no sessions found"
  refute_output --partial "query failed"
}

# ── Integrity tables: legit-empty stays silent, exceptions do not ─────────────

@test "ledger: absent integrity table / table without session_id stay silent-empty (exit 0)" {
  sqlite3 "$CAST_DB_PATH" "DROP TABLE agent_hallucinations; DROP TABLE completeness_events; CREATE TABLE completeness_events (id INTEGER, note_kind TEXT);"
  _run_ledger_split sess-A
  assert_success
  refute_output --partial "INCOMPLETE"
  assert_output --partial "Hallucinations:** 0"
  assert_output --partial "Completeness flags:** 0"
  run cat "$BATS_TEST_TMPDIR/err.txt"
  refute_output --partial "WARNING"
}

@test "ledger: an integrity table that raises on read is reported by table name (exit 3)" {
  sqlite3 "$CAST_DB_PATH" "DROP TABLE agent_truncations; CREATE VIEW agent_truncations AS SELECT session_id FROM table_that_does_not_exist;"
  _run_ledger_split sess-A
  assert_equal "$status" 3
  assert_output --partial "INCOMPLETE RECEIPT"
  run cat "$BATS_TEST_TMPDIR/err.txt"
  assert_output --partial "WARNING: agent_truncations query failed"
}

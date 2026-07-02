#!/usr/bin/env bats
# Tests for cast-incident-record.sh
# Covers: incident insert on debugger+Status:DONE, no-op on wrong agent, no-op on missing status.
# Uses isolated temp HOME + temp CAST_DB_PATH — never touches real ~/.claude.

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_DIR/scripts/cast-incident-record.sh"

setup() {
  load 'helpers/setup'
  setup_temp_home
  mkdir -p "$HOME/.claude/logs"
  export TEST_DB="$HOME/cast-test-incident-$$.db"
  export CAST_DB_PATH="$TEST_DB"
  bash "$REPO_DIR/scripts/cast-db-init.sh" --db "$TEST_DB" 2>/dev/null || true
}

teardown() {
  rm -f "$TEST_DB"
  teardown_temp_home
}

# Helper: count incidents rows
_count_incidents() {
  sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM incidents;" 2>/dev/null || echo "0"
}

# Helper: write a JSON fixture to a temp file and return the path via stdout
_write_fixture() {
  local content="$1"
  local tmp
  tmp="$(mktemp)"
  printf '%s' "$content" >"$tmp"
  echo "$tmp"
}

@test "debugger agent with Status: DONE inserts 1 incident row" {
  local payload
  payload='{"agent_type":"debugger","session_id":"s1","agent_id":"a1","stop_reason":"end_turn","agent_response":{"content":[{"type":"text","text":"Summary: fixed the thing\n## Handoff\nfiles_changed: [a.py]\nStatus: DONE"}]}}'
  local fixture
  fixture="$(_write_fixture "$payload")"

  run bash "$SCRIPT" <"$fixture"
  rm -f "$fixture"

  assert_success
  local count
  count="$(_count_incidents)"
  [ "$count" -eq 1 ]
}

@test "debugger incident row has expected surfaced_by and non-empty problem_summary" {
  local payload
  payload='{"agent_type":"debugger","session_id":"s1","agent_id":"a1","stop_reason":"end_turn","agent_response":{"content":[{"type":"text","text":"Summary: fixed the thing\n## Handoff\nfiles_changed: [a.py]\nStatus: DONE"}]}}'
  local fixture
  fixture="$(_write_fixture "$payload")"

  run bash "$SCRIPT" <"$fixture"
  rm -f "$fixture"

  assert_success
  local surfaced_by
  surfaced_by="$(sqlite3 "$TEST_DB" "SELECT surfaced_by FROM incidents LIMIT 1;" 2>/dev/null)"
  [ "$surfaced_by" = "debugger" ]

  local summary
  summary="$(sqlite3 "$TEST_DB" "SELECT problem_summary FROM incidents LIMIT 1;" 2>/dev/null)"
  [ -n "$summary" ]
}

@test "non-debugger agent (code-writer) inserts 0 incident rows" {
  local payload
  payload='{"agent_type":"code-writer","session_id":"s1","agent_id":"a2","stop_reason":"end_turn","agent_response":{"content":[{"type":"text","text":"Summary: added feature\nStatus: DONE"}]}}'
  local fixture
  fixture="$(_write_fixture "$payload")"

  run bash "$SCRIPT" <"$fixture"
  rm -f "$fixture"

  assert_success
  local count
  count="$(_count_incidents)"
  [ "$count" -eq 0 ]
}

@test "debugger agent with Status: BLOCKED inserts 1 row via BLOCKED class" {
  # Per spec: a debugger ending BLOCKED gets a BLOCKED-class row (old code skipped it entirely).
  local payload
  payload='{"agent_type":"debugger","session_id":"s1","agent_id":"a3","stop_reason":"end_turn","agent_response":{"content":[{"type":"text","text":"Summary: still investigating\n## Handoff\nfiles_changed: []\nStatus: BLOCKED"}]}}'
  local fixture
  fixture="$(_write_fixture "$payload")"

  run bash "$SCRIPT" <"$fixture"
  rm -f "$fixture"

  assert_success
  local count
  count="$(_count_incidents)"
  [ "$count" -eq 1 ]

  local surfaced_by
  surfaced_by="$(sqlite3 "$TEST_DB" "SELECT surfaced_by FROM incidents LIMIT 1;" 2>/dev/null)"
  [ "$surfaced_by" = "debugger" ]
}

@test "debugger agent with no terminal status inserts 0 rows" {
  # Response has neither DONE nor BLOCKED — should produce zero incidents.
  local payload
  payload='{"agent_type":"debugger","session_id":"s1","agent_id":"a3b","stop_reason":"end_turn","agent_response":{"content":[{"type":"text","text":"Summary: still investigating — no verdict yet"}]}}'
  local fixture
  fixture="$(_write_fixture "$payload")"

  run bash "$SCRIPT" <"$fixture"
  rm -f "$fixture"

  assert_success
  local count
  count="$(_count_incidents)"
  [ "$count" -eq 0 ]
}

@test "subprocess guard exits 0 immediately when CLAUDE_SUBPROCESS=1" {
  local payload
  payload='{"agent_type":"debugger","agent_response":{"content":[{"type":"text","text":"Status: DONE"}]}}'
  local fixture
  fixture="$(_write_fixture "$payload")"

  run env CLAUDE_SUBPROCESS=1 bash "$SCRIPT" <"$fixture"
  rm -f "$fixture"

  assert_success
  local count
  count="$(_count_incidents)"
  [ "$count" -eq 0 ]
}

@test "empty stdin exits 0 and inserts 0 rows" {
  run bash "$SCRIPT" </dev/null
  assert_success
  local count
  count="$(_count_incidents)"
  [ "$count" -eq 0 ]
}

@test "redaction strips secret token from problem_summary before DB insert" {
  # Point HOOK_DIR at the repo scripts/ so cast-redact.py is reachable in the temp HOME
  export HOOK_DIR="$REPO_DIR/scripts"
  local fake_secret="sk-ant-""api03-FAKE0000000000000000000000000000000000000000000000000000000000000000000000000000000000"
  local fixture
  fixture="$(mktemp)"
  printf '{"agent_type":"debugger","session_id":"s-redact","agent_id":"a-redact","stop_reason":"end_turn","agent_response":{"content":[{"type":"text","text":"Summary: leaked %s and /Users/testuser/secret.txt\\n## Handoff\\nfiles_changed: []\\nStatus: DONE"}]}}' \
    "$fake_secret" >"$fixture"

  run bash "$SCRIPT" <"$fixture"
  rm -f "$fixture"

  assert_success
  local stored_summary
  stored_summary="$(sqlite3 "$TEST_DB" "SELECT problem_summary FROM incidents LIMIT 1;" 2>/dev/null)"
  # Redaction must have run — raw secret token must NOT appear in stored summary
  [[ "$stored_summary" != *"$fake_secret"* ]]
}

@test "debugger with markdown-bold **Status: DONE** inserts 1 debugger-class row" {
  # PATH 1 matches on stripped_text, so bold markup is stripped before matching.
  local payload
  payload='{"agent_type":"debugger","session_id":"s20","agent_id":"a20","stop_reason":"end_turn","agent_response":{"content":[{"type":"text","text":"Summary: fixed the thing\n## Handoff\nfiles_changed: [b.py]\n**Status: DONE**"}]}}'
  local fixture
  fixture="$(_write_fixture "$payload")"

  run bash "$SCRIPT" <"$fixture"
  rm -f "$fixture"

  assert_success
  local count
  count="$(_count_incidents)"
  [ "$count" -eq 1 ]

  local surfaced_by
  surfaced_by="$(sqlite3 "$TEST_DB" "SELECT surfaced_by FROM incidents LIMIT 1;" 2>/dev/null)"
  [ "$surfaced_by" = "debugger" ]
}

# B2 wiring tests (Unit U2)

@test "SubagentStop wiring: cast-incident-record is registered under SubagentStop in 30-hooks-session.json" {
  local config="$REPO_DIR/managed-settings.d/30-hooks-session.json"
  run python3 - "$config" <<'PYEOF'
import sys, json
with open(sys.argv[1]) as f:
    cfg = json.load(f)
hooks = cfg.get("hooks", {}).get("SubagentStop", [])
ids = [h.get("id", "") for h in hooks]
cmds = [h2.get("command", "") for h in hooks for h2 in h.get("hooks", [])]
assert "cast-incident-record" in ids, f"id not found, ids={ids}"
assert any("cast-incident-record.sh" in c for c in cmds), f"command not found in cmds={cmds}"
print("OK")
PYEOF
  assert_success
  assert_output "OK"
}

# ── BLOCKED/BLOCKER capture class (LF-4 audit: widen to any-agent) ──────────

@test "code-reviewer with Status: BLOCKED inserts 1 row with correct surfaced_by and prefix" {
  local payload
  payload='{"agent_type":"code-reviewer","session_id":"s10","agent_id":"a10","stop_reason":"end_turn","agent_response":{"content":[{"type":"text","text":"Status: BLOCKED\nSummary: cannot proceed without type info\n## Handoff\nfiles_changed: []\nblockers: missing context"}]}}'
  local fixture
  fixture="$(_write_fixture "$payload")"

  run bash "$SCRIPT" <"$fixture"
  rm -f "$fixture"

  assert_success
  local count
  count="$(_count_incidents)"
  [ "$count" -eq 1 ]

  local surfaced_by
  surfaced_by="$(sqlite3 "$TEST_DB" "SELECT surfaced_by FROM incidents LIMIT 1;" 2>/dev/null)"
  [ "$surfaced_by" = "code-reviewer" ]

  local summary
  summary="$(sqlite3 "$TEST_DB" "SELECT problem_summary FROM incidents LIMIT 1;" 2>/dev/null)"
  [[ "$summary" == "[code-reviewer BLOCKED]"* ]]
}

@test "BLOCKER line without Status inserts 1 row" {
  local payload
  payload='{"agent_type":"code-writer","session_id":"s11","agent_id":"a11","stop_reason":"end_turn","agent_response":{"content":[{"type":"text","text":"Review complete.\nBLOCKER missing test coverage for auth module\nSome other text."}]}}'
  local fixture
  fixture="$(_write_fixture "$payload")"

  run bash "$SCRIPT" <"$fixture"
  rm -f "$fixture"

  assert_success
  local count
  count="$(_count_incidents)"
  [ "$count" -eq 1 ]
}

@test "markdown-bold Status: BLOCKED (stripped) inserts 1 row" {
  local payload
  payload='{"agent_type":"bash-specialist","session_id":"s12","agent_id":"a12","stop_reason":"end_turn","agent_response":{"content":[{"type":"text","text":"**Status: BLOCKED**\nSummary: hook script broken"}]}}'
  local fixture
  fixture="$(_write_fixture "$payload")"

  run bash "$SCRIPT" <"$fixture"
  rm -f "$fixture"

  assert_success
  local count
  count="$(_count_incidents)"
  [ "$count" -eq 1 ]
}

@test "Status: BLOCKED and BLOCKER line together insert exactly 1 row" {
  local payload
  payload='{"agent_type":"code-reviewer","session_id":"s13","agent_id":"a13","stop_reason":"end_turn","agent_response":{"content":[{"type":"text","text":"Status: BLOCKED\nBLOCKER missing auth check\nSummary: review failed"}]}}'
  local fixture
  fixture="$(_write_fixture "$payload")"

  run bash "$SCRIPT" <"$fixture"
  rm -f "$fixture"

  assert_success
  local count
  count="$(_count_incidents)"
  [ "$count" -eq 1 ]
}

@test "script exits 0 even when DB is unwritable (exit-0 fix: pipeline-safety contract)" {
  # Force sqlite3 insert to fail by pointing to /dev/null (not a valid SQLite file).
  # The Python except block calls sys.exit(0); the || true on the heredoc invocation
  # also guards against any unexpected non-zero exit.
  local payload
  payload='{"agent_type":"debugger","session_id":"s1","agent_id":"a1","stop_reason":"end_turn","agent_response":{"content":[{"type":"text","text":"Summary: test\nStatus: DONE"}]}}'
  local fixture
  fixture="$(_write_fixture "$payload")"

  run env CAST_DB_PATH="/dev/null" bash "$SCRIPT" <"$fixture"
  rm -f "$fixture"

  assert_success
}

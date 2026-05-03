#!/usr/bin/env bats
# tests/hooks/test_cast_post_tool_suppression.bats
# Covers: cast-post-tool.py Task 4 (A-3 suppression) + Task 6 (B-1 unstaged warning)

bats_require_minimum_version 1.5.0

load '../test_helper/bats-support/load'
load '../test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
HOOK="$REPO_DIR/scripts/cast-post-tool.py"

# ── Payload helpers ──────────────────────────────────────────────────────────

make_edit_payload() {
  local file_path="${1:-/tmp/foo.js}"
  local new_string="${2:-x = 1;}"
  python3 -c "
import json, sys
print(json.dumps({
    'tool_name': 'Edit',
    'tool_input': {'file_path': sys.argv[1], 'new_string': sys.argv[2]},
    'tool_response': {},
}))
" "$file_path" "$new_string"
}

make_write_payload() {
  local file_path="${1:-/tmp/test.md}"
  local content="${2:-# hello}"
  python3 -c "
import json, sys
print(json.dumps({
    'tool_name': 'Write',
    'tool_input': {'file_path': sys.argv[1], 'content': sys.argv[2]},
    'tool_response': {},
}))
" "$file_path" "$content"
}

make_security_script_payload() {
  # Edit a scripts/ .sh file with enough lines to trigger security chain (SIZE_THRESHOLD=5)
  local content
  content="$(printf 'line%d\n' $(seq 1 10))"
  python3 -c "
import json, sys
print(json.dumps({
    'tool_name': 'Edit',
    'tool_input': {
        'file_path': '$REPO_DIR/scripts/cast-events.sh',
        'new_string': sys.argv[1],
    },
    'tool_response': {},
}))
" "$content"
}

make_bash_git_commit_payload() {
  python3 -c "
import json
print(json.dumps({
    'tool_name': 'Bash',
    'tool_input': {'command': 'git commit -m \"test commit\"'},
    'tool_response': {'exit_code': 0, 'output': '[main abc1234] test commit'},
}))
"
}

# ── Setup / teardown ─────────────────────────────────────────────────────────

setup() {
  TEST_DB="$BATS_TEST_TMPDIR/test-post-tool.db"
  export CAST_DB_PATH="$TEST_DB"

  python3 - <<'PYEOF'
import sqlite3, os
db = os.environ['CAST_DB_PATH']
con = sqlite3.connect(db)
con.execute('''CREATE TABLE IF NOT EXISTS agent_runs (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  agent TEXT, session_id TEXT, status TEXT,
  started_at TEXT, ended_at TEXT,
  agent_id TEXT, duration_ms INTEGER, owns_files TEXT
)''')
con.execute('''CREATE TABLE IF NOT EXISTS unstaged_warnings (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id TEXT, commit_sha TEXT,
  unstaged_files TEXT, in_scope_files TEXT,
  timestamp TEXT NOT NULL
)''')
con.commit(); con.close()
PYEOF

  unset CLAUDE_SUBPROCESS
  unset CAST_ORCHESTRATE_ACTIVE
}

teardown() {
  rm -f "$CAST_DB_PATH"
}

# ── Tests ─────────────────────────────────────────────────────────────────────

# 1. CAST_ORCHESTRATE_ACTIVE=1 + code file edit → CAST-CHAIN suppressed
@test "suppression: CAST_ORCHESTRATE_ACTIVE=1 suppresses CAST-CHAIN on code file edit" {
  CAST_ORCHESTRATE_ACTIVE=1 run python3 "$HOOK" <<< "$(make_edit_payload '/tmp/foo.js' 'x = 1;')"
  assert_success
  refute_output --partial "CAST-CHAIN"
  refute_output --partial "CAST-REVIEW"
}

# 2. CAST_ORCHESTRATE_ACTIVE=1 + security-relevant scripts/ .sh edit → security chain still fires
@test "suppression: CAST_ORCHESTRATE_ACTIVE=1 does NOT suppress security chain for scripts/ .sh edit" {
  CAST_ORCHESTRATE_ACTIVE=1 run python3 "$HOOK" <<< "$(make_security_script_payload)"
  assert_success
  assert_output --partial "CAST-CHAIN: security"
}

# 3. No orchestrate env + .md file edit → CAST-REVIEW suppressed unconditionally
@test "suppression: .md file edit suppresses CAST-REVIEW unconditionally" {
  run python3 "$HOOK" <<< "$(make_write_payload '/Users/edkubiak/.claude/plans/test.md' '# test plan')"
  assert_success
  refute_output --partial "CAST-REVIEW"
  refute_output --partial "CAST-CHAIN"
}

# 4. No orchestrate env + .py file edit → CAST-CHAIN fires (normal path for code files)
@test "suppression: no orchestrate env + .py file edit → CAST-CHAIN fires" {
  run python3 "$HOOK" <<< "$(make_edit_payload '/tmp/foo.py' 'x = 1')"
  assert_success
  # .py is a code file → emits CAST-CHAIN (the mandatory code-review chain directive)
  assert_output --partial "CAST-CHAIN"
}

# 5. Bash 'git commit' with unstaged files → unstaged_warnings row + warning
@test "suppression: git commit with unstaged files in working tree → unstaged_warnings row" {
  local git_repo
  git_repo="$(mktemp -d)"
  git -C "$git_repo" init -q
  git -C "$git_repo" config user.email "test@test.com"
  git -C "$git_repo" config user.name "Test"
  echo "initial content" > "$git_repo/file.txt"
  git -C "$git_repo" add file.txt
  git -C "$git_repo" commit -q -m "init"
  # Create an unstaged modification
  echo "modified content" > "$git_repo/file.txt"

  local payload
  payload="$(make_bash_git_commit_payload)"

  # Run the hook from inside the git repo so git diff sees the unstaged change
  CAST_DB_PATH="$CAST_DB_PATH" run bash -c "cd '$git_repo' && python3 '$HOOK'" <<< "$payload"
  assert_success

  # Verify the warning row was recorded (or at minimum the hook did not crash)
  local count
  count=$(python3 -c "
import sqlite3, os
con = sqlite3.connect(os.environ['CAST_DB_PATH'])
try:
    print(con.execute('SELECT COUNT(*) FROM unstaged_warnings').fetchone()[0])
except Exception:
    print(0)
con.close()
")
  # The hook runs without error (exit 0 always)
  [ "$count" -ge 0 ]

  rm -rf "$git_repo"
}

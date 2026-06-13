#!/usr/bin/env bats

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
VERIFIER="$REPO_DIR/scripts/cast_claimed_work_verifier.py"
TEMP_DB=""
TEMP_DIR=""

# ---------------------------------------------------------------------------
# Setup and teardown
# ---------------------------------------------------------------------------

setup() {
  # Create a temp directory for test files
  TEMP_DIR="$(mktemp -d)"
  # Create a temp SQLite database for testing
  TEMP_DB="$(mktemp)"
  export CAST_DB_PATH="$TEMP_DB"
  export CAST_REPO_ROOT="$TEMP_DIR"
  export CAST_SESSION_ID="test-session-123"
}

teardown() {
  [ -d "$TEMP_DIR" ] && rm -rf "$TEMP_DIR"
  [ -f "$TEMP_DB" ] && rm -f "$TEMP_DB"
}

# ---------------------------------------------------------------------------
# Helper: run verifier with env vars
# ---------------------------------------------------------------------------

run_verifier() {
  CAST_AGENT_NAME="${CAST_AGENT_NAME:-test-agent}" \
  CAST_SESSION_ID="${CAST_SESSION_ID:-test-session-123}" \
  CAST_AGENT_START_TIME="${CAST_AGENT_START_TIME:-$(date -u +'%Y-%m-%dT%H:%M:%SZ')}" \
  CAST_REPO_ROOT="${CAST_REPO_ROOT:-$(pwd)}" \
  CAST_DB_PATH="${CAST_DB_PATH:-${HOME}/.claude/cast.db}" \
  CAST_STOP_RESPONSE_TEXT="${1:-}" \
  python3 "$VERIFIER" 2>&1
}

# ---------------------------------------------------------------------------
# 1. Empty response text exits 0 silently
# ---------------------------------------------------------------------------

@test "empty response_text causes immediate exit 0" {
  export CAST_STOP_RESPONSE_TEXT=""
  run run_verifier
  assert_success
  assert_output ""
}

@test "response_text under 50 chars exits 0 silently" {
  export CAST_STOP_RESPONSE_TEXT="short"
  run run_verifier
  assert_success
  assert_output ""
}

# ---------------------------------------------------------------------------
# 2. Verifier extracts and logs file paths from Files changed section
# ---------------------------------------------------------------------------

@test "extracts paths from 'Files changed:' section and writes to DB" {
  # Use a non-existent file so it resolves to [NOT FOUND], which passes the
  # write-gate (only [NOT FOUND] inserts a row — Phase 1 Task 1.1 behavior).
  # src/hooks/useAuth.ts is intentionally NOT created in TEMP_DIR.

  RESPONSE='## Work Log
- Created auth hook

Files changed:
- src/hooks/useAuth.ts

Status: DONE'

  export CAST_AGENT_START_TIME="2000-01-01T00:00:00Z"
  export CAST_STOP_RESPONSE_TEXT="$RESPONSE"

  # Run verifier so it writes to DB
  run_verifier "$RESPONSE"

  # Verify DB was written: agent_hallucinations should have 1 row ([NOT FOUND])
  run python3 - << 'PYEOF'
import os, sqlite3
db = os.environ.get('CAST_DB_PATH')
if not os.path.exists(db):
    print("NO DB")
    exit(0)
try:
    conn = sqlite3.connect(db)
    cur = conn.cursor()
    cur.execute("SELECT COUNT(*) FROM agent_hallucinations")
    count = cur.fetchone()[0]
    print(count)
    conn.close()
except Exception as e:
    print("ERROR: " + str(e))
PYEOF

  assert_success
  assert_output "1"
}

# ---------------------------------------------------------------------------
# 3. [VERIFIED] when file exists and was modified after agent start
# ---------------------------------------------------------------------------

@test "reports [VERIFIED] for file that exists and was recently modified" {
  # Create a file in the temp dir with current timestamp
  mkdir -p "$TEMP_DIR/src"
  touch "$TEMP_DIR/src/main.ts"

  RESPONSE='## Work Log
Modified the main source file.

Files changed:
- src/main.ts

Status: DONE'

  # Agent start time far in the past
  export CAST_AGENT_START_TIME="2000-01-01T00:00:00Z"
  export CAST_STOP_RESPONSE_TEXT="$RESPONSE"
  export CAST_AGENT_NAME="code-writer"

  run run_verifier "$RESPONSE"

  assert_success
  # Summary should show: verified=1, not_found=0, pre_existing=0
  assert_line --partial "verified=1"
  assert_line --partial "not_found=0"
}

# ---------------------------------------------------------------------------
# 4. [NOT FOUND] when claimed file doesn't exist
# ---------------------------------------------------------------------------

@test "reports [NOT FOUND] for non-existent claimed file" {
  RESPONSE='## Work Log
- Wrote a new test file

Files changed:
- tests/component.test.tsx

Status: DONE'

  export CAST_AGENT_START_TIME="2000-01-01T00:00:00Z"
  export CAST_STOP_RESPONSE_TEXT="$RESPONSE"
  export CAST_AGENT_NAME="test-writer"

  run run_verifier "$RESPONSE"

  assert_success
  # Summary should show: not_found=1
  assert_line --partial "not_found=1"
  # Should print the NOT FOUND detail
  assert_line --partial "[NOT FOUND]"
}

# ---------------------------------------------------------------------------
# 5. [PRE_EXISTING] when file exists but was not modified by agent
# ---------------------------------------------------------------------------

@test "reports [PRE_EXISTING] for file that exists but predates agent start" {
  # Create a file with a timestamp in the past
  mkdir -p "$TEMP_DIR/src"
  TEST_FILE="$TEMP_DIR/src/old.ts"
  touch -t 199901010000 "$TEST_FILE"

  RESPONSE='## Work Log
- Updated existing file

Files changed:
- src/old.ts

Status: DONE'

  # Agent start time after the file's mtime
  export CAST_AGENT_START_TIME="2000-02-01T00:00:00Z"
  export CAST_STOP_RESPONSE_TEXT="$RESPONSE"
  export CAST_AGENT_NAME="code-writer"

  run run_verifier "$RESPONSE"

  assert_success
  # Summary should show: pre_existing=1
  assert_line --partial "pre_existing=1"
  # Should print the PRE_EXISTING detail
  assert_line --partial "[PRE_EXISTING]"
}

# ---------------------------------------------------------------------------
# 6. Extracts paths from inline prose claims
# ---------------------------------------------------------------------------

@test "prose 'wrote X' and 'created X' patterns are NOT extracted (Patterns 3+4 dropped)" {
  # Phase 1 Task 1.1: Patterns 3+4 (prose verb extraction) were intentionally
  # removed from extract_file_paths() because they extracted paths the agent
  # only read/referenced, flooding [PRE_EXISTING] rows. This test asserts that
  # prose-only claims produce no file extractions and no verifier output.
  mkdir -p "$TEMP_DIR/scripts"
  touch "$TEMP_DIR/scripts/setup.sh"

  RESPONSE='## Work Log
- Wrote a new hook script at scripts/setup.sh
- Created the installation guide

Status: DONE'

  export CAST_AGENT_START_TIME="2000-01-01T00:00:00Z"
  export CAST_STOP_RESPONSE_TEXT="$RESPONSE"
  export CAST_AGENT_NAME="bash-specialist"

  run run_verifier "$RESPONSE"

  assert_success
  # No [CAST-VERIFY] lines should appear — prose paths are no longer extracted
  refute_output --partial "[CAST-VERIFY]"
}

# ---------------------------------------------------------------------------
# 7. Handles JSON files_changed array in status block
# ---------------------------------------------------------------------------

@test "extracts paths from files_changed JSON array in status block" {
  mkdir -p "$TEMP_DIR/src"
  touch "$TEMP_DIR/src/util.ts"
  touch "$TEMP_DIR/src/util.test.ts"

  RESPONSE='## Work Log
- Added utility function and tests

```json status
{
  "schema_version": "1.0",
  "status": "DONE",
  "agent": "code-writer",
  "summary": "Added utility functions",
  "files_changed": ["src/util.ts", "src/util.test.ts"]
}
```'

  export CAST_AGENT_START_TIME="2000-01-01T00:00:00Z"
  export CAST_STOP_RESPONSE_TEXT="$RESPONSE"
  export CAST_AGENT_NAME="code-writer"

  run run_verifier "$RESPONSE"

  assert_success
  # Both files should be found
  assert_line --partial "files_claimed=2"
  assert_line --partial "verified=2"
}

# ---------------------------------------------------------------------------
# 8. Summary output format
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# F12 regression: commit agent output must never produce hallucination rows
# Triage: reports/2026-06-12-honesty-warn-triage.md (Bucket A, 27/73 false positives)
# ---------------------------------------------------------------------------

@test "F12: commit agent output is NOT parsed for file-write claims (no agent_hallucinations row written)" {
  # Simulate a staged-file list from the commit agent that contains a path
  # that does NOT exist on disk — the kind of input that previously caused
  # false-positive [NOT FOUND] rows in agent_hallucinations.
  RESPONSE='## Work Log
- Staged and committed 2 files

Files changed:
- routeCurve.test.js
- src/components/WorkProjectWidget.tsx

Status: DONE
Summary: committed work-project files'

  export CAST_AGENT_NAME="commit"
  export CAST_AGENT_START_TIME="2000-01-01T00:00:00Z"
  export CAST_STOP_RESPONSE_TEXT="$RESPONSE"

  # Run verifier — must exit 0 and produce no output
  run run_verifier "$RESPONSE"
  assert_success
  assert_output ""

  # Verify the DB has zero rows from the commit agent
  run python3 - << 'PYEOF'
import os, sqlite3
db = os.environ.get('CAST_DB_PATH')
if not db or not os.path.exists(db):
    print("0")
    exit(0)
try:
    conn = sqlite3.connect(db)
    cur = conn.cursor()
    cur.execute("SELECT COUNT(*) FROM agent_hallucinations WHERE agent_name = 'commit'")
    print(cur.fetchone()[0])
    conn.close()
except Exception:
    print("0")
PYEOF

  assert_success
  assert_output "0"
}

@test "summary line includes agent name and claim counts" {
  mkdir -p "$TEMP_DIR/docs"
  touch "$TEMP_DIR/docs/README.md"

  RESPONSE='## Work Log
- Updated documentation

Files changed:
- docs/README.md

Status: DONE'

  export CAST_AGENT_START_TIME="2000-01-01T00:00:00Z"
  export CAST_STOP_RESPONSE_TEXT="$RESPONSE"
  export CAST_AGENT_NAME="docs"

  run run_verifier "$RESPONSE"

  assert_success
  # Summary must include agent name, counts, and status
  assert_line "[CAST-VERIFY] agent=docs files_claimed=1 verified=1 not_found=0 pre_existing=0"
}

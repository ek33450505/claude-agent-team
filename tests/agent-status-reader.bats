#!/usr/bin/env bats

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
HOOK="$REPO_DIR/scripts/agent-status-reader.sh"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

write_status_file() {
  local status="$1"
  local agent="${2:-test-agent}"
  local summary="${3:-Test summary}"
  local concerns="${4:-}"

  mkdir -p "$CAST_STATUS_DIR"
  local ts
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  local file="$CAST_STATUS_DIR/${ts}-${agent}.json"

  python3 - "$file" "$status" "$agent" "$summary" "$concerns" <<'PYEOF'
import json, sys
filepath, status, agent, summary, concerns = sys.argv[1:]
d = {
    "status":   status,
    "agent":    agent,
    "summary":  summary,
    "concerns": concerns if concerns else None
}
with open(filepath, "w") as f:
    json.dump(d, f)
PYEOF
}

run_hook() {
  # Feed empty JSON (the hook reads stdin but only uses CAST_STATUS_DIR env var logic)
  run env CLAUDE_SUBPROCESS=1 CAST_STATUS_DIR="$CAST_STATUS_DIR" bash "$HOOK" <<< "{}"
}

# ---------------------------------------------------------------------------
# Setup / Teardown
# ---------------------------------------------------------------------------

setup() {
  export ORIG_HOME="$HOME"
  export HOME="$(mktemp -d)"
  export CAST_STATUS_DIR="$HOME/.claude/agent-status"
}

teardown() {
  rm -rf "$HOME"
  export HOME="$ORIG_HOME"
}

# ---------------------------------------------------------------------------
# 1. Subprocess guard (inverted — this hook only fires inside subagents)
# ---------------------------------------------------------------------------

@test "subprocess guard: exits 0 silently when CLAUDE_SUBPROCESS is not 1" {
  # The hook should exit 0 immediately when NOT in a subagent context
  run env CLAUDE_SUBPROCESS=0 CAST_STATUS_DIR="$CAST_STATUS_DIR" bash "$HOOK" <<< "{}"
  assert_success
  assert_output ""
}

@test "subprocess guard: exits 0 silently when CLAUDE_SUBPROCESS is unset" {
  run bash "$HOOK" <<< "{}"
  assert_success
  assert_output ""
}

# ---------------------------------------------------------------------------
# 2. Missing or empty status dir
# ---------------------------------------------------------------------------

@test "missing status dir: exits 0 silently" {
  export CAST_STATUS_DIR="$HOME/.claude/agent-status-nonexistent"
  run_hook
  assert_success
  assert_output ""
}

@test "empty status dir: exits 0 silently" {
  mkdir -p "$CAST_STATUS_DIR"
  run_hook
  assert_success
  assert_output ""
}

# ---------------------------------------------------------------------------
# 3. BLOCKED status
# ---------------------------------------------------------------------------

@test "BLOCKED: exits with code 2" {
  write_status_file "BLOCKED" "debugger" "Cannot proceed — missing dependency" "npm package missing"
  run_hook
  assert_failure 2
}

@test "BLOCKED: output contains [CAST-HALT]" {
  write_status_file "BLOCKED" "debugger" "Cannot proceed — missing dependency" ""
  run_hook
  assert_output --partial "[CAST-HALT]"
}

@test "BLOCKED: output contains the agent name" {
  write_status_file "BLOCKED" "debugger" "Cannot proceed" ""
  run_hook
  assert_output --partial "debugger"
}

@test "BLOCKED: output contains the summary" {
  write_status_file "BLOCKED" "test-agent" "Missing test fixtures" ""
  run_hook
  assert_output --partial "Missing test fixtures"
}

@test "BLOCKED: output includes concerns when present" {
  write_status_file "BLOCKED" "test-agent" "Blocked on dep" "npm ci failed with exit 1"
  run_hook
  assert_output --partial "npm ci failed with exit 1"
}

# ---------------------------------------------------------------------------
# 4. DONE_WITH_CONCERNS status
# ---------------------------------------------------------------------------

@test "DONE_WITH_CONCERNS: exits 0" {
  write_status_file "DONE_WITH_CONCERNS" "test-writer" "Tests written but coverage low" "Only 62% coverage"
  run_hook
  assert_success
}

@test "DONE_WITH_CONCERNS: output contains [CAST-REVIEW]" {
  write_status_file "DONE_WITH_CONCERNS" "test-writer" "Tests written but coverage low" ""
  run_hook
  assert_output --partial "[CAST-REVIEW]"
}

@test "DONE_WITH_CONCERNS: output is valid JSON hookSpecificOutput" {
  write_status_file "DONE_WITH_CONCERNS" "refactor-cleaner" "Refactored but naming unclear" ""
  run_hook
  # Write output to temp file — pipe+heredoc conflict makes piping unreliable
  local tmp_out
  tmp_out="$(mktemp)"
  printf '%s' "$output" > "$tmp_out"
  python3 - "$tmp_out" <<'PYEOF'
import json, sys
with open(sys.argv[1]) as f:
    raw = f.read().strip()
assert raw, "hook produced no output for DONE_WITH_CONCERNS"
d = json.loads(raw)
assert 'hookSpecificOutput' in d, f"missing hookSpecificOutput key, got: {raw[:200]}"
assert d['hookSpecificOutput']['hookEventName'] == 'PostToolUse'
assert '[CAST-REVIEW]' in d['hookSpecificOutput']['additionalContext']
PYEOF
  rm -f "$tmp_out"
}

@test "DONE_WITH_CONCERNS: output includes concerns when present" {
  write_status_file "DONE_WITH_CONCERNS" "test-writer" "Tests written" "Coverage only 40%"
  run_hook
  assert_output --partial "Coverage only 40%"
}

# ---------------------------------------------------------------------------
# 5. DONE status
# ---------------------------------------------------------------------------

@test "DONE: exits 0" {
  write_status_file "DONE" "commit" "Committed successfully" ""
  run_hook
  assert_success
}

@test "DONE: produces no output" {
  write_status_file "DONE" "commit" "Committed successfully" ""
  run_hook
  assert_output ""
}

# ---------------------------------------------------------------------------
# 6. NEEDS_CONTEXT status
# ---------------------------------------------------------------------------

@test "NEEDS_CONTEXT: exits 0 and emits researcher suggestion" {
  write_status_file "NEEDS_CONTEXT" "planner" "Need more info about scope" ""
  run_hook
  assert_success
  assert_output --partial "[CAST-NEEDS-CONTEXT]"
  assert_output --partial "researcher"
}

# ---------------------------------------------------------------------------
# 7. Security boundary — file outside $HOME must not be processed
# ---------------------------------------------------------------------------

@test "security: file outside HOME is not processed" {
  # Point CAST_STATUS_DIR to a directory outside $HOME using a symlink trick
  local outside_dir
  outside_dir="$(mktemp -d)"
  # Write a BLOCKED file there — it should NOT trigger exit 2
  python3 -c "
import json
d = {'status': 'BLOCKED', 'agent': 'evil', 'summary': 'pwned', 'concerns': None}
with open('$outside_dir/20991231T235959Z-evil.json', 'w') as f:
    json.dump(d, f)
"
  # Symlink from inside HOME to outside dir so ls picks up the file
  ln -sf "$outside_dir/20991231T235959Z-evil.json" "$CAST_STATUS_DIR/20991231T235959Z-evil.json" 2>/dev/null || true
  mkdir -p "$CAST_STATUS_DIR"
  # The realpath of the symlink resolves to outside $HOME, so the hook should skip it
  run env CLAUDE_SUBPROCESS=1 CAST_STATUS_DIR="$CAST_STATUS_DIR" bash "$HOOK" <<< "{}"
  # Should NOT exit 2 (BLOCKED) — must be 0 (skipped due to security check)
  assert_success
  rm -rf "$outside_dir"
}

# ---------------------------------------------------------------------------
# 8. Status logging — routing-log.jsonl persistence
# ---------------------------------------------------------------------------

setup_log_script() {
  # Install a minimal cast-log-append.py that appends stdin to routing-log.jsonl
  mkdir -p "$HOME/.claude/scripts"
  cat > "$HOME/.claude/scripts/cast-log-append.py" <<'PYEOF'
import sys, os
log_path = os.path.expanduser('~/.claude/routing-log.jsonl')
os.makedirs(os.path.dirname(log_path), exist_ok=True)
data = sys.stdin.read().strip()
if data:
    with open(log_path, 'a') as f:
        f.write(data + '\n')
PYEOF
}

@test "status logging: DONE status writes agent_complete entry with status=DONE" {
  setup_log_script
  write_status_file "DONE" "code-reviewer" "Review complete" ""
  run_hook
  assert_success
  local log_file="$HOME/.claude/routing-log.jsonl"
  [ -f "$log_file" ] || fail "routing-log.jsonl was not created"
  python3 - "$log_file" <<'PYEOF'
import json, sys
log_file = sys.argv[1]
entries = []
with open(log_file) as f:
    for line in f:
        line = line.strip()
        if line:
            try:
                entries.append(json.loads(line))
            except Exception:
                pass
agent_complete = [e for e in entries if e.get('action') == 'agent_complete']
assert agent_complete, f"No agent_complete entries found. All entries: {entries}"
last = agent_complete[-1]
assert last.get('status') == 'DONE', f"Expected status=DONE, got: {last}"
assert last.get('matched_route') == 'code-reviewer', f"Expected matched_route=code-reviewer, got: {last}"
PYEOF
}

@test "status logging: BLOCKED status writes agent_complete entry with status=BLOCKED" {
  setup_log_script
  write_status_file "BLOCKED" "debugger" "Cannot proceed" ""
  run env CLAUDE_SUBPROCESS=1 CAST_STATUS_DIR="$CAST_STATUS_DIR" bash "$HOOK" <<< "{}"
  # exit code 2 expected for BLOCKED — don't assert_success
  local log_file="$HOME/.claude/routing-log.jsonl"
  [ -f "$log_file" ] || fail "routing-log.jsonl was not created"
  python3 - "$log_file" <<'PYEOF'
import json, sys
log_file = sys.argv[1]
entries = []
with open(log_file) as f:
    for line in f:
        line = line.strip()
        if line:
            try:
                entries.append(json.loads(line))
            except Exception:
                pass
agent_complete = [e for e in entries if e.get('action') == 'agent_complete']
assert agent_complete, f"No agent_complete entries found. All entries: {entries}"
last = agent_complete[-1]
assert last.get('status') == 'BLOCKED', f"Expected status=BLOCKED, got: {last}"
PYEOF
}

@test "status logging: logging failure does not break status handling" {
  # Do NOT create cast-log-append.py — logging will silently fail
  write_status_file "DONE" "commit" "Committed successfully" ""
  run_hook
  # Must still exit 0 (DONE path) even though logging failed
  assert_success
}

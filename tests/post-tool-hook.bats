#!/usr/bin/env bats

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
HOOK_SH="$REPO_DIR/scripts/post-tool-hook.sh"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Build a Write tool payload
write_payload() {
  local file_path="$1"
  local content="${2:-export const x = 1}"
  python3 -c "import json,sys; print(json.dumps({'tool_name':'Write','tool_input':{'file_path':sys.argv[1],'content':sys.argv[2]},'tool_response':{}}))" "$file_path" "$content"
}

# Build an Agent tool payload
agent_payload() {
  local subagent_type="${1:-code-writer}"
  python3 -c "import json,sys; print(json.dumps({'tool_name':'Agent','tool_input':{'subagent_type':sys.argv[1],'prompt':'test prompt for agent dispatch'},'tool_response':{}}))" "$subagent_type"
}

# Build a Bash tool payload with optional exit code
bash_payload() {
  local command="$1"
  local exit_code="${2:-0}"
  python3 -c "import json,sys; print(json.dumps({'tool_name':'Bash','tool_input':{'command':sys.argv[1]},'tool_response':{'exit_code':int(sys.argv[2]),'stdout':'','stderr':'command failed'}}))" "$command" "$exit_code"
}

# Read the action field from the last routing-log entry
last_log_action() {
  tail -1 "$HOME/.claude/routing-log.jsonl" 2>/dev/null \
    | python3 -c "import json,sys; print(json.load(sys.stdin).get('action',''))" 2>/dev/null || echo ""
}

# Count lines in the routing log
log_line_count() {
  wc -l < "$HOME/.claude/routing-log.jsonl" 2>/dev/null || echo "0"
}

setup() {
  export ORIG_HOME="$HOME"
  # Resolve symlinks so realpath inside the hook matches $HOME (macOS /var -> /private/var quirk)
  export HOME="$(realpath "$(mktemp -d)")"
  mkdir -p "$HOME/.claude/config"
  mkdir -p "$HOME/.claude/scripts"
  # Create cast-log-append.py stub that just appends the JSON to routing-log.jsonl
  cat > "$HOME/.claude/scripts/cast-log-append.py" <<'PYEOF'
import sys, json
data = json.load(sys.stdin)
import os
log_path = os.path.expanduser("~/.claude/routing-log.jsonl")
os.makedirs(os.path.dirname(log_path), exist_ok=True)
with open(log_path, "a") as f:
    f.write(json.dumps(data) + "\n")
PYEOF
  touch "$HOME/.claude/routing-log.jsonl"
  unset CLAUDE_SUBPROCESS
  unset CLAUDE_SESSION_ID
}

teardown() {
  rm -rf "$HOME"
  export HOME="$ORIG_HOME"
}

# ---------------------------------------------------------------------------
# 1. Non-matching tool_name → no output
# ---------------------------------------------------------------------------

@test "non-Write tool_name (Read) → exits 0 with no hookSpecificOutput" {
  run bash "$HOOK_SH" <<< '{"tool_name":"Read","tool_input":{"file_path":"/tmp/foo.ts"},"tool_response":{}}'
  assert_success
  refute_output --partial "hookSpecificOutput"
}

# ---------------------------------------------------------------------------
# 2. Write .ts file + main session → [CAST-CHAIN]
# ---------------------------------------------------------------------------

@test "Write .ts + main session → output contains [CAST-CHAIN]" {
  run bash "$HOOK_SH" <<< "$(write_payload "$HOME/test.ts")"
  assert_success
  assert_output --partial "CAST-CHAIN"
}

# ---------------------------------------------------------------------------
# 3. Write .md file + main session → CAST-REVIEW SUPPRESSED (plan/doc edits, not code)
# ---------------------------------------------------------------------------

@test "Write .md + main session → CAST-REVIEW SUPPRESSED (plan/doc edits, not code)" {
  run bash "$HOOK_SH" <<< "$(write_payload "$HOME/notes.md" "# just a note")"
  assert_success
  refute_output --partial "CAST-REVIEW"
}

# ---------------------------------------------------------------------------
# 4. Write .ts file + CLAUDE_SUBPROCESS=1 → subagent path (not CAST-CHAIN)
# ---------------------------------------------------------------------------

@test "Write .ts + CLAUDE_SUBPROCESS=1 → does NOT output [CAST-CHAIN]" {
  run env CLAUDE_SUBPROCESS=1 bash "$HOOK_SH" <<< "$(write_payload "$HOME/test.ts")"
  assert_success
  refute_output --partial "CAST-CHAIN"
}

@test "Write .ts + CLAUDE_SUBPROCESS=1 → outputs subagent reinforcement (CAST-REVIEW)" {
  run env CLAUDE_SUBPROCESS=1 bash "$HOOK_SH" <<< "$(write_payload "$HOME/test.ts")"
  assert_success
  assert_output --partial "CAST-REVIEW"
}

# ---------------------------------------------------------------------------
# 5. Write non-code file + CLAUDE_SUBPROCESS=1 → no hookSpecificOutput
# ---------------------------------------------------------------------------

@test "Write .txt + CLAUDE_SUBPROCESS=1 → no hookSpecificOutput" {
  run env CLAUDE_SUBPROCESS=1 bash "$HOOK_SH" <<< "$(write_payload "$HOME/readme.txt" "plain text")"
  assert_success
  refute_output --partial "hookSpecificOutput"
}

# ---------------------------------------------------------------------------
# 6. File path outside $HOME → prettier skipped (no error)
# ---------------------------------------------------------------------------

@test "Write file outside HOME → exits 0 (prettier security guard, no crash)" {
  run bash "$HOOK_SH" <<< '{"tool_name":"Write","tool_input":{"file_path":"/etc/hosts","content":"# test"},"tool_response":{}}'
  assert_success
}

# ---------------------------------------------------------------------------
# 7. Write .md in /plans/ with 'json dispatch' block → ADM directive injected
# ---------------------------------------------------------------------------

@test "Write .md plan file with 'json dispatch' block → [CAST-ORCHESTRATE] injected" {
  mkdir -p "$HOME/.claude/plans"
  local plan_file="$HOME/.claude/plans/2026-03-25-test-plan.md"
  cat > "$plan_file" <<'PLAN'
# Test Plan

## Agent Dispatch Manifest

```json dispatch
{"batches":[]}
```
PLAN
  run bash "$HOOK_SH" <<< "$(write_payload "$plan_file" "$(cat "$plan_file")")"
  assert_success
  assert_output --partial "CAST-ORCHESTRATE"
}

# ---------------------------------------------------------------------------
# 8. Write .md in /plans/ without 'json dispatch' → no ADM directive
# ---------------------------------------------------------------------------

@test "Write .md plan file without 'json dispatch' → no [CAST-ORCHESTRATE]" {
  mkdir -p "$HOME/.claude/plans"
  local plan_file="$HOME/.claude/plans/2026-03-25-no-manifest.md"
  cat > "$plan_file" <<'PLAN'
# Test Plan

No dispatch manifest here.
PLAN
  run bash "$HOOK_SH" <<< "$(write_payload "$plan_file" "$(cat "$plan_file")")"
  assert_success
  refute_output --partial "CAST-ORCHESTRATE"
}

# ---------------------------------------------------------------------------
# 9. Agent tool call + main session → routing-log.jsonl written
# ---------------------------------------------------------------------------

@test "Agent tool call + main session → routing-log.jsonl gets new entry with action=agent_dispatched" {
  local before
  before="$(log_line_count)"
  run bash "$HOOK_SH" <<< "$(agent_payload "code-writer")"
  assert_success
  local after
  after="$(log_line_count)"
  assert [ "$after" -gt "$before" ]
  assert_equal "$(last_log_action)" "agent_dispatched"
}

# ---------------------------------------------------------------------------
# 10. Agent tool call + CLAUDE_SUBPROCESS=1 → routing-log IS written (no guard on Agent logging)
# ---------------------------------------------------------------------------

@test "Agent tool call + CLAUDE_SUBPROCESS=1 → routing-log still written (Agent logging has no subagent guard)" {
  local before
  before="$(log_line_count)"
  run env CLAUDE_SUBPROCESS=1 bash "$HOOK_SH" <<< "$(agent_payload "code-writer")"
  assert_success
  local after
  after="$(log_line_count)"
  assert [ "$after" -gt "$before" ]
}

# ---------------------------------------------------------------------------
# 11–14. Bash CAST-DEBUG section
#
# cast-post-tool.py (consolidated handler) receives $INPUT via herestring
# (<<< "$INPUT") rather than the old pipe+heredoc pattern that caused stdin
# to be empty inside the Python process. CAST-DEBUG is now correctly emitted
# for non-zero Bash exits in main sessions, except for grace-listed commands.
# ---------------------------------------------------------------------------

@test "Bash tool exit_code=1 + main session → exits 0 and emits [CAST-DEBUG]" {
  run bash "$HOOK_SH" <<< "$(bash_payload "npm run build" 1)"
  assert_success
  # Non-grace-listed command with exit_code=1 should route to debugger
  assert_output --partial "CAST-DEBUG"
}

@test "Bash tool exit_code=1 + CLAUDE_SUBPROCESS=1 → exits 0 with no [CAST-DEBUG]" {
  run env CLAUDE_SUBPROCESS=1 bash "$HOOK_SH" <<< "$(bash_payload "npm run build" 1)"
  assert_success
  refute_output --partial "CAST-DEBUG"
}

@test "Bash 'grep foo bar' exit_code=1 → exits 0 with no [CAST-DEBUG]" {
  run bash "$HOOK_SH" <<< "$(bash_payload "grep foo bar" 1)"
  assert_success
  refute_output --partial "CAST-DEBUG"
}

@test "Bash tool exit_code=0 → exits 0 with no [CAST-DEBUG]" {
  run bash "$HOOK_SH" <<< "$(bash_payload "npm run build" 0)"
  assert_success
  refute_output --partial "CAST-DEBUG"
}

# ---------------------------------------------------------------------------
# 15. Write .ts file in dir with .prettierrc → prettier invoked (exits 0)
# ---------------------------------------------------------------------------

@test "Write .ts in dir with .prettierrc → script exits 0 (prettier path exercised)" {
  local src_dir="$HOME/myapp/src"
  mkdir -p "$src_dir"
  echo '{}' > "$HOME/myapp/.prettierrc"
  local ts_file="$src_dir/app.ts"
  echo "export const x = 1" > "$ts_file"
  # Even if npx prettier isn't available, the script must not crash
  run bash "$HOOK_SH" <<< "$(write_payload "$ts_file" "export const x = 1")"
  assert_success
}

# ---------------------------------------------------------------------------
# 16–19. Security chain (Batch 2 — CAST follow-ups 2026-04-16)
#
# cast-post-tool.py emits [CAST-CHAIN: security] only when:
#   - main session (CLAUDE_SUBPROCESS not set or = "0")
#   - file path matches .sh or .py extension AND scripts/ or hooks/ path
#   - non-blank line count of content >= 5
# ---------------------------------------------------------------------------

# Helper: build Write payload for a scripts/ .sh file with N non-blank lines
scripts_sh_payload() {
  local file_path="${1:-scripts/foo.sh}"
  local line_count="${2:-6}"
  local content
  content="$(python3 -c "
import sys
n = int(sys.argv[1])
lines = ['#!/bin/bash'] + [f'echo line_{i}' for i in range(n - 1)]
print('\n'.join(lines))
" "$line_count")"
  python3 -c "import json,sys; print(json.dumps({'tool_name':'Write','tool_input':{'file_path':sys.argv[1],'content':sys.argv[2]},'tool_response':{}}))" "$file_path" "$content"
}

@test "security chain fires for scripts/foo.sh with 6 non-blank lines" {
  local file_path="$HOME/projects/repo/scripts/foo.sh"
  run bash "$HOOK_SH" <<< "$(scripts_sh_payload "$file_path" 6)"
  assert_success
  assert_output --partial "[CAST-CHAIN: security]"
}

@test "security chain does NOT fire for scripts/foo.sh with 3 non-blank lines" {
  local file_path="$HOME/projects/repo/scripts/foo.sh"
  run bash "$HOOK_SH" <<< "$(scripts_sh_payload "$file_path" 3)"
  assert_success
  refute_output --partial "[CAST-CHAIN: security]"
}

@test "security chain does NOT fire for src/components/Foo.jsx regardless of size" {
  local file_path="$HOME/projects/repo/src/components/Foo.jsx"
  local content
  content="$(python3 -c "
lines = ['import React from \"react\"'] + [f'const x{i} = {i}' for i in range(22)]
print('\n'.join(lines))
")"
  local payload
  payload="$(python3 -c "import json,sys; print(json.dumps({'tool_name':'Write','tool_input':{'file_path':sys.argv[1],'content':sys.argv[2]},'tool_response':{}}))" "$file_path" "$content")"
  run bash "$HOOK_SH" <<< "$payload"
  assert_success
  refute_output --partial "[CAST-CHAIN: security]"
}

@test "security chain does NOT fire when CLAUDE_SUBPROCESS=1" {
  local file_path="$HOME/projects/repo/scripts/foo.sh"
  run env CLAUDE_SUBPROCESS=1 bash "$HOOK_SH" <<< "$(scripts_sh_payload "$file_path" 10)"
  assert_success
  refute_output --partial "[CAST-CHAIN: security]"
}

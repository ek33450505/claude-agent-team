#!/usr/bin/env bats

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
HOOK_SH="$REPO_DIR/scripts/cast-response-completeness-hook.sh"

setup() {
  export ORIG_HOME="$HOME"
  export TEMP_HOME="$(mktemp -d "${TMPDIR:-/tmp}/cast-comptest-home-XXXX")"
  export HOME="$TEMP_HOME"
  mkdir -p "$TEMP_HOME/.claude/logs"
  export TEMP_DB="$TEMP_HOME/cast.db"
  export CAST_DB_PATH="$TEMP_DB"
  unset CLAUDE_SUBPROCESS
}

teardown() {
  export HOME="$ORIG_HOME"
  [ -n "${TEMP_HOME:-}" ] && rm -rf "$TEMP_HOME"
}

# Helper: build a SubagentStop JSON payload with a given output string
_make_input() {
  local output_text="$1"
  # Use python3 to safely encode the output text as a JSON string
  python3 -c "
import json, sys
payload = {'agent_type': 'test-agent', 'last_assistant_message': sys.argv[1]}
print(json.dumps(payload))
" "$output_text"
}

# Helper: generate N lines of filler text (simulates a large files_changed array)
_filler_lines() {
  local n="$1"
  python3 -c "print('\n'.join(['  \"/path/to/file_{}.ts\"'.format(i) for i in range($n)]))"
}

@test "completeness hook: JSON status block after 50+ filler lines is NOT flagged as truncated" {
  # Simulate agent output: 50 lines of a files_changed array followed by JSON status block
  # The human-readable 'Status: DONE' line is buried before the filler, >40 lines from the end
  local filler
  filler="$(_filler_lines 50)"

  local output_text
  output_text="$(printf '%s\n\nStatus: DONE\nSummary: All done\nFiles changed: see below\n\n%s\n\n\`\`\`json status\n{\n  \"schema_version\": \"1.0\",\n  \"status\": \"DONE\",\n  \"agent\": \"code-writer\",\n  \"summary\": \"Implemented feature X\",\n  \"concerns\": [],\n  \"files_changed\": [],\n  \"next_actions\": []\n}\n\`\`\`' "$filler")"

  local input
  input="$(_make_input "$output_text")"

  # Run the hook — it should exit 0 and NOT write a completeness_events row
  run bash "$HOOK_SH" <<< "$input"
  assert_success

  # No truncation event should be recorded
  local row_count
  row_count="$(sqlite3 "$TEMP_DB" "SELECT COUNT(*) FROM completeness_events;" 2>/dev/null || echo 0)"
  assert_equal "$row_count" "0"
}

@test "completeness hook: truly truncated output (no Status, no JSON status) IS flagged" {
  # Simulate an agent that stopped mid-sentence — no Status block at all
  local output_text
  output_text="I am going to implement the feature now. First let me read the file and then I'll"

  local input
  input="$(_make_input "$output_text")"

  run bash "$HOOK_SH" <<< "$input"
  assert_success

  # A truncation event should be recorded
  local row_count
  row_count="$(sqlite3 "$TEMP_DB" "SELECT COUNT(*) FROM completeness_events;" 2>/dev/null || echo 0)"
  assert_equal "$row_count" "1"

  # Severity should be HIGH (ends with "I'll")
  local severity
  severity="$(sqlite3 "$TEMP_DB" "SELECT severity FROM completeness_events LIMIT 1;" 2>/dev/null || echo "")"
  assert_equal "$severity" "HIGH"
}

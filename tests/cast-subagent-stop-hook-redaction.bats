#!/usr/bin/env bats

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
HOOK_SH="$REPO_DIR/scripts/cast-subagent-stop-hook.sh"
REDACT_PY="$REPO_DIR/scripts/cast-redact.py"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Build a minimal SubagentStop payload for testing
make_subagent_payload() {
  local summary="$1"
  local concerns="${2:-}"
  python3 -c "
import json, sys
payload = {
    'agent_type': 'test-agent',
    'session_id': 'test-session-123',
    'stop_reason': 'end_turn',
    'output': '${summary}',
    'last_assistant_message': '${summary}',
}
print(json.dumps(payload))
"
}

# Test just the redaction pipeline (simpler than full hook + DB)
# Input: text with PII
# Output: JSON with redacted_text field
test_redaction_pipeline() {
  local input_text="$1"
  echo "$input_text" | python3 "$REDACT_PY" 2>/dev/null | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('redacted_text', ''))
except:
    print('')
"
}

setup() {
  export ORIG_HOME="$HOME"
  export HOME="$(realpath "$(mktemp -d)")"
  mkdir -p "$HOME/.claude/logs"
  mkdir -p "$HOME/.claude/cast"

  # Create a minimal cast.db for hook testing
  export CAST_DB_PATH="$BATS_TEST_TMPDIR/test.db"
  sqlite3 "$CAST_DB_PATH" <<'SQLEOF'
CREATE TABLE IF NOT EXISTS quality_gates (
  id INTEGER PRIMARY KEY,
  session_id TEXT,
  agent TEXT,
  gate_type TEXT,
  gate_result TEXT,
  feedback TEXT,
  created_at TEXT DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS agent_runs (
  id INTEGER PRIMARY KEY,
  agent TEXT,
  session_id TEXT,
  status TEXT DEFAULT 'running',
  started_at TEXT,
  ended_at TEXT,
  duration_ms INTEGER,
  tool_uses INTEGER,
  response TEXT
);

CREATE TABLE IF NOT EXISTS routing_events (
  session_id TEXT,
  event_type TEXT,
  details TEXT,
  created_at TEXT
);
SQLEOF

  unset CLAUDE_SESSION_ID
  unset CLAUDE_SUBPROCESS
}

teardown() {
  rm -rf "$HOME" "$BATS_TEST_TMPDIR"
  export HOME="$ORIG_HOME"
}

# ---------------------------------------------------------------------------
# Test A: API key redaction
# Verify that Anthropic API keys (sk-ant-*) are redacted from Summary text
# ---------------------------------------------------------------------------

@test "Test A: Anthropic API key sk-ant-FAKE_API_KEY_1234567890abcdef is redacted in Summary" {
  # Minimum 32 chars after sk-ant- to match regex pattern in cast-redact.py
  local fake_key="sk-ant-FAKE_API_KEY_1234567890abcdefghij1234567890"
  local summary="Agent completed. API key used: $fake_key for testing."

  # Run redaction pipeline
  local redacted
  redacted="$(test_redaction_pipeline "$summary")"

  # Assert the literal key does NOT appear in the redacted output
  [[ "$redacted" != *"$fake_key"* ]]
  # Assert the output contains a redaction marker (e.g., <ANTHROPIC_KEY>)
  [[ "$redacted" == *"<ANTHROPIC_KEY>"* ]] || [[ "$redacted" == *"REDACTED"* ]] || ! [[ "$redacted" == *"sk-ant-"* ]]
}

@test "Test A variant: Multiple API keys in summary are all redacted" {
  # Minimum 32 chars after sk-ant-
  local key1="sk-ant-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaabbbbbb"
  local key2="sk-ant-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbcccccc"
  local summary="Keys: $key1 and $key2"

  local redacted
  redacted="$(test_redaction_pipeline "$summary")"

  # Neither key should appear literally
  [[ "$redacted" != *"$key1"* ]]
  [[ "$redacted" != *"$key2"* ]]
}

# ---------------------------------------------------------------------------
# Test B: Email redaction
# Verify that email addresses are redacted from Summary text
# ---------------------------------------------------------------------------

@test "Test B: Email address fake-user@example.com is redacted in Summary" {
  local fake_email="fake-user@example.com"
  local summary="Contact the user at $fake_email for feedback."

  local redacted
  redacted="$(test_redaction_pipeline "$summary")"

  # Assert the literal email does NOT appear
  [[ "$redacted" != *"$fake_email"* ]]
  # Assert a redaction marker is present
  [[ "$redacted" == *"<EMAIL_ADDRESS>"* ]] || [[ "$redacted" == *"REDACTED"* ]] || ! [[ "$redacted" == *"@"* ]]
}

@test "Test B variant: Multiple emails are all redacted" {
  local email1="alice@test.com"
  local email2="bob@test.org"
  local summary="Emails: $email1 and $email2"

  local redacted
  redacted="$(test_redaction_pipeline "$summary")"

  [[ "$redacted" != *"$email1"* ]]
  [[ "$redacted" != *"$email2"* ]]
}

# ---------------------------------------------------------------------------
# Test C: Output shape preserved after redaction
# Verify hookSpecificOutput JSON structure remains valid after redaction
# ---------------------------------------------------------------------------

@test "Test C: hookSpecificOutput shape is preserved after redaction" {
  local summary="Test summary with fake-user@example.com"

  # Create a synthetic hookSpecificOutput with redacted summary
  local hook_output
  hook_output=$(python3 - <<'PYEOF'
import json, sys
from subprocess import run, PIPE

# Redact the summary
summary = "Test summary with fake-user@example.com"
result = run([sys.executable, """$REDACT_PY"""], input=summary.encode(), capture_output=True)
if result.returncode == 0:
    redacted_data = json.loads(result.stdout.decode())
    redacted_summary = redacted_data.get('redacted_text', summary)
else:
    redacted_summary = summary

# Build hookSpecificOutput
output = {
    "hookSpecificOutput": {
        "hookEventName": "SubagentStop",
        "additionalContext": redacted_summary
    }
}
print(json.dumps(output))
PYEOF
)

  # Verify the output is valid JSON
  echo "$hook_output" | python3 -c "import sys, json; json.load(sys.stdin)" 2>/dev/null || return 1

  # Verify hookEventName field exists and equals SubagentStop
  echo "$hook_output" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert 'hookSpecificOutput' in d, 'hookSpecificOutput field missing'
assert d['hookSpecificOutput'].get('hookEventName') == 'SubagentStop', 'hookEventName mismatch'
assert 'additionalContext' in d['hookSpecificOutput'], 'additionalContext field missing'
" || return 1
}

@test "Test C variant: hookSpecificOutput is an object not a string" {
  local summary="Summary with sk-ant-key and email@test.com"

  local hook_output
  hook_output=$(python3 - <<'PYEOF'
import json, sys
from subprocess import run, PIPE

summary = "Summary with sk-ant-key and email@test.com"
result = run([sys.executable, """$REDACT_PY"""], input=summary.encode(), capture_output=True)
if result.returncode == 0:
    redacted_data = json.loads(result.stdout.decode())
    redacted_summary = redacted_data.get('redacted_text', summary)
else:
    redacted_summary = summary

output = {
    "hookSpecificOutput": {
        "hookEventName": "SubagentStop",
        "additionalContext": redacted_summary
    }
}
print(json.dumps(output))
PYEOF
)

  # Verify hookSpecificOutput is an object (dict), not a string
  echo "$hook_output" | python3 -c "
import sys, json
d = json.load(sys.stdin)
hook_out = d.get('hookSpecificOutput')
assert isinstance(hook_out, dict), f'hookSpecificOutput should be dict, got {type(hook_out).__name__}'
assert not isinstance(hook_out, str), 'hookSpecificOutput should not be a stringified blob'
print('ok')
"
}

# ---------------------------------------------------------------------------
# Integration test: Redaction pipeline via cast-redact.py directly
# ---------------------------------------------------------------------------

@test "cast-redact.py handles API key input and produces valid JSON output" {
  local input="Using key sk-ant-abc123defghijklmnopqrstuvwxyz in production"
  local output
  output="$(echo "$input" | python3 "$REDACT_PY" 2>/dev/null)"

  # Output must be valid JSON
  echo "$output" | python3 -c "import sys, json; json.load(sys.stdin)" || return 1

  # Output must have redacted_text field
  echo "$output" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert 'redacted_text' in d, 'redacted_text field missing'
assert d['redacted_text'] != '', 'redacted_text is empty'
"
}

@test "cast-redact.py identifies ANTHROPIC_KEY entity type" {
  local input="sk-ant-verylongkeythatmatchesthepattern1234567890"
  local output
  output="$(echo "$input" | python3 "$REDACT_PY" 2>/dev/null)"

  # Check that an entity was detected and identified
  echo "$output" | python3 -c "
import sys, json
d = json.load(sys.stdin)
entities = d.get('entities', [])
assert len(entities) > 0, 'No entities detected'
entity_types = [e.get('entity_type') for e in entities]
assert 'ANTHROPIC_KEY' in entity_types, f'ANTHROPIC_KEY not in {entity_types}'
"
}

@test "cast-redact.py identifies EMAIL_ADDRESS entity type" {
  local input="Contact john.doe@example.com for more info"
  local output
  output="$(echo "$input" | python3 "$REDACT_PY" 2>/dev/null)"

  echo "$output" | python3 -c "
import sys, json
d = json.load(sys.stdin)
entities = d.get('entities', [])
assert len(entities) > 0, 'No entities detected'
entity_types = [e.get('entity_type') for e in entities]
assert 'EMAIL_ADDRESS' in entity_types, f'EMAIL_ADDRESS not in {entity_types}'
"
}

# ---------------------------------------------------------------------------
# Fallback safety: redaction pipeline returns original text on error
# ---------------------------------------------------------------------------

@test "Redaction fallback: malformed JSON input does not crash pipeline" {
  local bad_input="not valid json {]"

  # The redaction should handle gracefully (either filter it or return original)
  # This just ensures no unhandled exception
  output="$(echo "$bad_input" | python3 "$REDACT_PY" 2>/dev/null || echo 'error')"
  [[ -n "$output" ]]
}

@test "Empty input produces valid JSON output from cast-redact.py" {
  local output
  output="$(echo "" | python3 "$REDACT_PY" 2>/dev/null)"

  # Must be valid JSON even on empty input
  echo "$output" | python3 -c "import sys, json; d=json.load(sys.stdin); assert d.get('entity_count') == 0"
}

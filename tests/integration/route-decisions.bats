#!/usr/bin/env bats
# Integration tests for CAST routing decisions using CAST_DRY_RUN=1.
# No real agent dispatches are triggered; route.sh runs the full pipeline
# and prints a JSON summary of what would have been dispatched.

load '../test_helper/bats-support/load'
load '../test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
ROUTE_SH="$REPO_DIR/scripts/route.sh"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

prompt_json() {
  python3 -c "import json,sys; print(json.dumps({'prompt': sys.argv[1]}))" "$1"
}

run_dry() {
  run bash "$ROUTE_SH" <<< "$(prompt_json "$1")"
}

# Parse a field from the dry-run JSON printed to stdout.
# Usage: dry_field 'matched_agent'  (reads $output set by run_dry)
dry_field() {
  local field="$1"
  echo "$output" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    v = d.get('$field')
    print('' if v is None else v)
except Exception:
    print('')
" 2>/dev/null || echo ""
}

# Return true (0) if the post_chain array in the JSON output contains the given value.
post_chain_contains() {
  local want="$1"
  echo "$output" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    chain = d.get('post_chain') or []
    sys.exit(0 if '$want' in chain else 1)
except Exception:
    sys.exit(1)
" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Setup / teardown
# ---------------------------------------------------------------------------

setup() {
  export ORIG_HOME="$HOME"
  # Resolve symlinks — macOS mktemp gives /var/... which is a symlink to /private/var/...
  export HOME="$(realpath "$(mktemp -d)")"
  export CAST_DRY_RUN=1

  # Silence session-briefing block by marking the session as already seen
  export CLAUDE_SESSION_ID="test-dry-$$-${BATS_TEST_NUMBER:-0}"
  echo "$CLAUDE_SESSION_ID" >> /tmp/cast-sessions-seen.log

  mkdir -p "$HOME/.claude/config"
  mkdir -p "$HOME/.claude/scripts"

  # cast-log-append.py stub — dry-run skips logging, but route.sh may call it
  # in non-dry paths; keep it present so the script never errors.
  cat > "$HOME/.claude/scripts/cast-log-append.py" <<'PYEOF'
import sys, json, os
data = sys.stdin.read().strip()
if data:
    log_path = os.path.expanduser('~/.claude/routing-log.jsonl')
    os.makedirs(os.path.dirname(log_path), exist_ok=True)
    with open(log_path, 'a') as f:
        f.write(data + '\n')
PYEOF

  # Minimal routing-table.json with the routes needed by these tests.
  # Patterns are chosen to be unambiguous for the target prompts.
  cat > "$HOME/.claude/config/routing-table.json" <<'EOF'
{
  "routes": [
    {
      "patterns": ["\\bdebug\\b"],
      "agent": "debugger",
      "command": "/debug",
      "confidence": "hard",
      "post_chain": null
    },
    {
      "patterns": ["\\bcommit\\b"],
      "agent": "commit",
      "command": "/commit",
      "confidence": "hard",
      "post_chain": null
    },
    {
      "patterns": ["\\bjwt\\b", "\\bauthentication\\b"],
      "agent": "code-writer",
      "command": "",
      "confidence": "hard",
      "post_chain": ["security"]
    },
    {
      "patterns": ["write.*test|test.*for"],
      "agent": "test-writer",
      "command": "/test",
      "confidence": "hard",
      "post_chain": null
    }
  ],
  "opus_signals": {
    "prefix": "opus:",
    "complexity_patterns": []
  }
}
EOF

  # Minimal agent-groups.json — no groups that would fire for these prompts.
  cat > "$HOME/.claude/config/agent-groups.json" <<'EOF'
{
  "version": "1.0",
  "groups": []
}
EOF
}

teardown() {
  rm -rf "$HOME"
  export HOME="$ORIG_HOME"
  unset CAST_DRY_RUN
}

# ---------------------------------------------------------------------------
# 1. Debug prompt routes to debugger
# ---------------------------------------------------------------------------

@test "dry-run: debug prompt routes to debugger" {
  run_dry "debug this error in my script"
  assert_success

  # Output must be valid JSON
  echo "$output" | python3 -c "import json,sys; json.load(sys.stdin)" 2>/dev/null
  assert_success

  assert_equal "$(dry_field matched_agent)" "debugger"
  assert_equal "$(dry_field match_type)" "regex"
}

# ---------------------------------------------------------------------------
# 2. Commit prompt routes to commit
# ---------------------------------------------------------------------------

@test "dry-run: commit prompt routes to commit" {
  run_dry "commit my changes"
  assert_success
  assert_equal "$(dry_field matched_agent)" "commit"
}

# ---------------------------------------------------------------------------
# 3. Auth prompt routes to code-writer with security in post_chain
# ---------------------------------------------------------------------------

@test "dry-run: auth prompt routes to code-writer (security route)" {
  run_dry "add jwt authentication to the login form"
  assert_success
  assert_equal "$(dry_field matched_agent)" "code-writer"
  post_chain_contains "security"
}

# ---------------------------------------------------------------------------
# 4. Test-writing prompt routes to test-writer
# ---------------------------------------------------------------------------

@test "dry-run: test-writing prompt routes to test-writer" {
  run_dry "write tests for the UserCard component"
  assert_success
  assert_equal "$(dry_field matched_agent)" "test-writer"
}

# ---------------------------------------------------------------------------
# 5. Unmatched prompt sets match_type to no_match or catchall
# ---------------------------------------------------------------------------

@test "dry-run: unmatched prompt sets match_type to no_match or catchall" {
  run_dry "xyzzy frobnicate the quux"
  assert_success

  # Output must be valid JSON regardless
  echo "$output" | python3 -c "import json,sys; json.load(sys.stdin)" 2>/dev/null
  assert_success

  # match_type must be 'no_match' or 'catchall'
  local mt
  mt="$(dry_field match_type)"
  if [[ "$mt" != "no_match" && "$mt" != "catchall" ]]; then
    fail "expected match_type 'no_match' or 'catchall', got '$mt'"
  fi
}

# ---------------------------------------------------------------------------
# 6. Output is always valid JSON
# ---------------------------------------------------------------------------

@test "dry-run: output is always valid JSON" {
  run_dry "refactor the auth module"
  assert_success
  echo "$output" | python3 -c "import json,sys; json.load(sys.stdin)"
  assert_success
}

# ---------------------------------------------------------------------------
# 7. No hookSpecificOutput emitted in dry-run mode
# ---------------------------------------------------------------------------

@test "dry-run: no hookSpecificOutput emitted" {
  run_dry "commit my changes"
  assert_success
  # dry-run must never emit the live hook envelope — only the summary JSON
  refute_output --partial "hookSpecificOutput"
  # directive_would_be may contain '[CAST-DISPATCH]' as a value; the envelope
  # key 'hookEventName' is the definitive signal that a live dispatch was emitted
  refute_output --partial "hookEventName"
}

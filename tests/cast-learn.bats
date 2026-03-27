#!/usr/bin/env bats
# Tests for `cast learn` subcommand
#
# Coverage:
#   - cast learn with valid agent installs route into routing-table.json
#   - cast learn with unknown agent exits 1 and prints "Agent not found"
#   - cast learn without args prints usage and exits non-zero
#   - cast learn logs to routing_events with action='learned'

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
CAST_CLI="$REPO_DIR/bin/cast"
DB_INIT_SH="$REPO_DIR/scripts/cast-db-init.sh"
DB_LOG_PY="$REPO_DIR/scripts/cast-db-log.py"

# ---------------------------------------------------------------------------
# Setup / Teardown — isolated temp home per test
# ---------------------------------------------------------------------------

setup() {
  export ORIG_HOME="$HOME"
  export TEST_HOME
  TEST_HOME="$(mktemp -d)"
  export HOME="$TEST_HOME"
  export TEST_DB="$TEST_HOME/.claude/cast-test.db"
  export CAST_DB_PATH="$TEST_DB"
  export CAST_AGENTS_DIR="$TEST_HOME/.claude/agents"
  # Point DB log script at repo copy so learned events are actually written
  export CAST_DB_LOG_PY="$DB_LOG_PY"
  # Disable Ollama for tests
  export OLLAMA_URL="http://localhost:19999"

  mkdir -p "$TEST_HOME/.claude/agents" \
           "$TEST_HOME/.claude/config" \
           "$TEST_HOME/.claude/logs" \
           "$TEST_HOME/.claude/scripts"

  # Install a minimal CLI config
  cat > "$TEST_HOME/.claude/config/cast-cli.json" <<'JSON'
{
  "db_path": "~/.claude/cast-test.db",
  "ollama_url": "http://localhost:19999",
  "redact_pii": false,
  "default_model": "auto",
  "log_dir": "~/.claude/logs"
}
JSON

  # Initialize DB schema
  bash "$DB_INIT_SH" --db "$TEST_DB" >/dev/null 2>&1 || true

  # Create a test agent file
  cat > "$TEST_HOME/.claude/agents/test-agent.md" <<'AGENT'
---
name: test-agent
description: A test agent for BATS tests
---
Test agent content.
AGENT

  # Initialize an empty routing-table.json
  echo '{"routes":[]}' > "$TEST_HOME/.claude/config/routing-table.json"
}

teardown() {
  rm -rf "$TEST_HOME"
  export HOME="$ORIG_HOME"
  unset CAST_DB_PATH TEST_DB TEST_HOME CAST_AGENTS_DIR CAST_DB_LOG_PY OLLAMA_URL
}

# ---------------------------------------------------------------------------
# cast learn — no args
# ---------------------------------------------------------------------------

@test "cast learn: no args prints usage and exits non-zero" {
  run bash "$CAST_CLI" learn
  assert_failure
  assert_output --partial "Usage: cast learn"
}

# ---------------------------------------------------------------------------
# cast learn — unknown agent
# ---------------------------------------------------------------------------

@test "cast learn: unknown agent exits 1 and prints Agent not found" {
  run bash "$CAST_CLI" learn "\\bfix\\b" nonexistent-agent
  assert_failure
  assert_output --partial "Agent not found"
}

# ---------------------------------------------------------------------------
# cast learn — valid agent installs route
# ---------------------------------------------------------------------------

@test "cast learn: valid agent installs route into routing-table.json" {
  run bash "$CAST_CLI" learn "\\brefactor\\b" test-agent --confidence soft --description "Refactor requests"
  assert_success
  assert_output --partial "Route installed"

  # Assert the routing-table.json now contains the pattern
  result="$(python3 -c "
import json
with open('$TEST_HOME/.claude/config/routing-table.json') as f:
    t = json.load(f)
patterns = [p for r in t['routes'] for p in r.get('patterns', [])]
print('found' if any('refactor' in p for p in patterns) else 'missing')
")"
  [ "$result" = "found" ]
}

@test "cast learn: installed route has correct agent field" {
  run bash "$CAST_CLI" learn "\\brefactor\\b" test-agent
  assert_success

  result="$(python3 -c "
import json
with open('$TEST_HOME/.claude/config/routing-table.json') as f:
    t = json.load(f)
agents = [r.get('agent') for r in t['routes']]
print('found' if 'test-agent' in agents else 'missing')
")"
  [ "$result" = "found" ]
}

@test "cast learn: installed route has source=cast-learn" {
  run bash "$CAST_CLI" learn "\\btest\\b" test-agent
  assert_success

  result="$(python3 -c "
import json
with open('$TEST_HOME/.claude/config/routing-table.json') as f:
    t = json.load(f)
sources = [r.get('source') for r in t['routes']]
print('found' if 'cast-learn' in sources else 'missing')
")"
  [ "$result" = "found" ]
}

# ---------------------------------------------------------------------------
# cast learn — logs to routing_events
# ---------------------------------------------------------------------------

@test "cast learn: logs to routing_events with action=learned" {
  run bash "$CAST_CLI" learn "\\bdebug\\b" test-agent --description "Debug pattern"
  assert_success

  # Query the routing_events table for an 'learned' action
  row_count="$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM routing_events WHERE action='learned' AND matched_route='test-agent';" 2>/dev/null || echo 0)"
  [ "$row_count" -ge 1 ]
}

@test "cast learn: logged event has match_type=manual" {
  run bash "$CAST_CLI" learn "\\bsecurity\\b" test-agent
  assert_success

  match_type="$(sqlite3 "$TEST_DB" "SELECT match_type FROM routing_events WHERE action='learned' AND matched_route='test-agent' LIMIT 1;" 2>/dev/null || echo '')"
  [ "$match_type" = "manual" ]
}

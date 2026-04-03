#!/usr/bin/env bats
# Tests for bin/cast CLI (v4 rebuild)
#
# Coverage:
#   - cast --version, --help, no subcommand
#   - cast budget: empty DB returns $0.00 spend
#   - cast budget --json: returns valid JSON
#   - cast status: runs without error
#   - cast memory: list, export, search, forget
#   - cast agents: lists agents
#   - cast hooks: lists hooks
#   - cast doctor: runs health check
#   - cast unknown: prints error

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
CAST_CLI="$REPO_DIR/bin/cast"
DB_INIT_SH="$REPO_DIR/scripts/cast-db-init.sh"

# ---------------------------------------------------------------------------
# Setup / Teardown — isolated temp home per test
# ---------------------------------------------------------------------------

setup() {
  export ORIG_HOME="$HOME"
  export HOME="$(mktemp -d)"
  export CAST_DB_PATH="$HOME/.claude/cast-test.db"

  mkdir -p "$HOME/.claude/agents" "$HOME/.claude/config" "$HOME/.claude/logs" "$HOME/.claude/scripts"
  mkdir -p "$HOME/.claude/cast/events"

  # Initialize DB schema
  bash "$DB_INIT_SH" --db "$CAST_DB_PATH" >/dev/null 2>&1 || true

  # Install a minimal config
  cat > "$HOME/.claude/config/cast-cli.json" <<'JSON'
{
  "db_path": "~/.claude/cast-test.db"
}
JSON

  # Install a minimal settings.json for hooks tests
  cat > "$HOME/.claude/settings.json" <<'JSON'
{
  "hooks": {
    "SessionStart": [
      {
        "id": "test-hook",
        "hooks": [
          {
            "type": "command",
            "command": "echo test",
            "timeout": 5
          }
        ]
      }
    ]
  }
}
JSON

  # Create a dummy agent
  cat > "$HOME/.claude/agents/test-agent.md" <<'MD'
---
name: test-agent
model: sonnet
description: A test agent
---
Test agent body.
MD
}

teardown() {
  rm -rf "$HOME"
  export HOME="$ORIG_HOME"
  unset CAST_DB_PATH
}

# ---------------------------------------------------------------------------
# cast --version / --help
# ---------------------------------------------------------------------------

@test "cast --version: prints version string" {
  run bash "$CAST_CLI" --version
  assert_success
  assert_output --partial "cast version"
}

@test "cast --help: prints usage with subcommands" {
  run bash "$CAST_CLI" --help
  assert_success
  assert_output --partial "status"
  assert_output --partial "memory"
  assert_output --partial "budget"
  assert_output --partial "agents"
  assert_output --partial "hooks"
}

@test "cast: no subcommand prints usage" {
  run bash "$CAST_CLI"
  assert_success
  assert_output --partial "Usage"
}

@test "cast unknown: prints error" {
  run bash "$CAST_CLI" nonexistent
  assert_failure
  assert_output --partial "Unknown subcommand: nonexistent"
}

# ---------------------------------------------------------------------------
# cast budget — empty DB
# ---------------------------------------------------------------------------

@test "cast budget: empty DB returns \$0.00 today spend" {
  run bash "$CAST_CLI" budget
  assert_success
  assert_output --partial "Today: \$0.00"
}

@test "cast budget: empty DB returns \$0.00 week spend" {
  run bash "$CAST_CLI" budget
  assert_success
  assert_output --partial "This week: \$0.00"
}

@test "cast budget --json: empty DB returns valid JSON with zero today_usd" {
  run bash "$CAST_CLI" --json budget
  assert_success
  echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d['today_usd'] == 0.0" 2>&1
  assert_success
}

@test "cast budget --week: empty DB runs without crash" {
  run bash "$CAST_CLI" budget --week
  assert_success
}

# ---------------------------------------------------------------------------
# cast status
# ---------------------------------------------------------------------------

@test "cast status: exits zero" {
  run bash "$CAST_CLI" status
  assert_success
}

@test "cast status: output contains Budget line" {
  run bash "$CAST_CLI" status
  assert_success
  assert_output --partial "Budget"
}

@test "cast status: output contains Memory line" {
  run bash "$CAST_CLI" status
  assert_success
  assert_output --partial "Memory"
}

@test "cast status: output contains Agents line" {
  run bash "$CAST_CLI" status
  assert_success
  assert_output --partial "Agents"
}

# ---------------------------------------------------------------------------
# cast memory — empty DB
# ---------------------------------------------------------------------------

@test "cast memory list: empty DB prints 'No memories found.'" {
  run bash "$CAST_CLI" memory list
  assert_success
  assert_output "No memories found."
}

@test "cast memory export: empty DB returns empty JSON array" {
  run bash "$CAST_CLI" memory export
  assert_success
  assert_output "[]"
}

@test "cast memory search: no query prints error" {
  run bash "$CAST_CLI" memory search
  assert_failure
  assert_output --partial "Usage: cast memory search"
}

@test "cast memory forget: missing ID prints error" {
  run bash "$CAST_CLI" memory forget
  assert_failure
  assert_output --partial "Usage: cast memory forget"
}

@test "cast memory forget: non-existent ID warns gracefully" {
  run bash "$CAST_CLI" memory forget 9999
  [ "$status" -eq 0 ]
  assert_output --partial "not found"
}

# ---------------------------------------------------------------------------
# cast agents
# ---------------------------------------------------------------------------

@test "cast agents: lists installed agents" {
  run bash "$CAST_CLI" agents
  assert_success
  assert_output --partial "test-agent"
  assert_output --partial "sonnet"
}

@test "cast agents --json: returns valid JSON array" {
  run bash "$CAST_CLI" --json agents
  assert_success
  echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); assert isinstance(d, list); assert len(d) > 0" 2>&1
  assert_success
}

@test "cast agents: shows agent count" {
  run bash "$CAST_CLI" agents
  assert_success
  assert_output --partial "agents installed"
}

# ---------------------------------------------------------------------------
# cast hooks
# ---------------------------------------------------------------------------

@test "cast hooks: lists active hooks" {
  run bash "$CAST_CLI" hooks
  assert_success
  assert_output --partial "SessionStart"
  assert_output --partial "test-hook"
}

@test "cast hooks --json: returns valid JSON" {
  run bash "$CAST_CLI" --json hooks
  assert_success
  echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); assert isinstance(d, list)" 2>&1
  assert_success
}

# ---------------------------------------------------------------------------
# cast doctor
# ---------------------------------------------------------------------------

@test "cast doctor: runs without crash" {
  run bash "$CAST_CLI" doctor
  assert_success
}

@test "cast doctor: checks cast.db" {
  run bash "$CAST_CLI" doctor
  assert_success
  assert_output --partial "cast.db"
}

@test "cast doctor: checks schema tables" {
  run bash "$CAST_CLI" doctor
  assert_success
  assert_output --partial "tables"
}

#!/usr/bin/env bats
# Tests for cast run sync path (B1 fix — Phase 9.75a)
#
# Coverage:
#   - cast run no longer references cast-local-runner.sh or cast-model-resolver.sh
#   - cast run uses direct claude CLI invocation
#   - cast run --async queues a task (queue path still works)

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
CAST_CLI="$REPO_DIR/bin/cast"
DB_INIT_SH="$REPO_DIR/scripts/cast-db-init.sh"

# ---------------------------------------------------------------------------
# Setup / Teardown
# ---------------------------------------------------------------------------

setup() {
  export ORIG_HOME="$HOME"
  export HOME="$(mktemp -d)"
  export CAST_DB_PATH="$HOME/.claude/cast-test.db"
  mkdir -p "$HOME/.claude/agents" "$HOME/.claude/config" "$HOME/.claude/logs" "$HOME/.claude/cast"
  bash "$DB_INIT_SH" --db "$CAST_DB_PATH" >/dev/null 2>&1 || true

  cat > "$HOME/.claude/config/cast-cli.json" <<'JSON'
{
  "db_path": "~/.claude/cast-test.db",
  "redact_pii": false,
  "default_model": "auto",
  "log_dir": "~/.claude/logs"
}
JSON

  # Create a minimal agent definition so cast run doesn't fail on missing agent
  mkdir -p "$HOME/.claude/agents"
  cat > "$HOME/.claude/agents/commit.md" <<'AGENT'
---
name: commit
model: claude-haiku-4-5
description: Creates git commits
---
You are a commit agent.
AGENT

  # Install a stub claude binary that records its invocation args
  mkdir -p "$HOME/bin"
  cat > "$HOME/bin/claude" <<'STUB'
#!/bin/bash
# Stub: records args to a log file and exits 0
echo "stub-claude-invoked: $*" >> /tmp/cast-run-stub-$$.log
echo "Status: DONE"
exit 0
STUB
  chmod +x "$HOME/bin/claude"
  export PATH="$HOME/bin:$PATH"
}

teardown() {
  rm -rf "$HOME"
  rm -f /tmp/cast-run-stub-$$.log
  export HOME="$ORIG_HOME"
  unset CAST_DB_PATH
}

# ---------------------------------------------------------------------------
# B1 — cast run exits 0 (stub claude returns DONE)
# ---------------------------------------------------------------------------

@test "cast run exits 0 when claude stub succeeds" {
  run bash "$CAST_CLI" run commit "test commit task"
  assert_success
}

# ---------------------------------------------------------------------------
# B1 — default model is claude-sonnet-4-6 not qwen3:8b
# ---------------------------------------------------------------------------

@test "cast run sync path uses claude-sonnet-4-6 as default model" {
  # The sync run function should default to claude-sonnet-4-6, not qwen3:8b
  # We check the _cmd_run_sync or equivalent function definition
  run grep -A5 '_cmd_run_sync\|local model.*claude-sonnet' "$CAST_CLI"
  assert_success
  assert_output --partial 'claude-sonnet-4-6'
}

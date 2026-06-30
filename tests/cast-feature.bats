#!/usr/bin/env bats
# Tests for `cast feature` — v9 F3 invocation layer over the app-build Workflow engine

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
CAST_BIN="$REPO_DIR/bin/cast"

setup() {
  load 'helpers/setup'
  setup_temp_home
  mkdir -p "$HOME/.claude"
  export CAST_DB_PATH="$HOME/.claude/cast.db"
  export CAST_SCRIPTS_DIR="$REPO_DIR/scripts"
  export CAST_AGENTS_DIR="$REPO_DIR/agents/core"
  export CAST_JOURNAL_DIR="$BATS_TEST_TMPDIR/journal"
  export CLAUDE_PROJECTS_DIR="$BATS_TEST_TMPDIR/projects"
  export CLAUDE_SUBPROCESS=0
  mkdir -p "$CAST_JOURNAL_DIR" "$CLAUDE_PROJECTS_DIR"
  # Bootstrap full schema so predict's _require_db passes
  bash "$REPO_DIR/scripts/cast-db-init.sh" >/dev/null 2>&1
}

teardown() {
  teardown_temp_home
}

@test "cast feature with no args exits nonzero and prints usage" {
  run bash "$CAST_BIN" feature
  assert_failure
  assert_output --partial 'usage: cast feature'
}

@test "cast feature with a description emits [CAST-FEATURE] directive" {
  run bash "$CAST_BIN" feature "add dark mode toggle"
  assert_output --partial '[CAST-FEATURE]'
}

@test "cast feature directive includes cast-feature.workflow.js scriptPath" {
  run bash "$CAST_BIN" feature "add dark mode toggle"
  assert_output --partial 'workflows/cast-feature.workflow.js'
}

@test "cast feature directive includes the provided description" {
  run bash "$CAST_BIN" feature "add dark mode toggle"
  assert_output --partial 'add dark mode toggle'
}

@test "cast feature emits pre-flight cost estimate header" {
  run bash "$CAST_BIN" feature "add dark mode toggle"
  assert_output --partial 'pre-flight cost estimate'
}

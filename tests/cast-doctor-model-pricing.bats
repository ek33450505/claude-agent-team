#!/usr/bin/env bats
# cast doctor "model-pricing" check: models seen in agent_runs (7d) that are
# absent from config/model-pricing.json are silently priced at _default.

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
CAST_BIN="$REPO_DIR/bin/cast"

setup() {
  load 'helpers/setup'
  setup_temp_home
  mkdir -p "$HOME/.claude/config" "$HOME/.claude/agents" "$HOME/fake-repo" "$HOME/.claude/cast/events"
  export CAST_DB_PATH="$HOME/.claude/cast.db"
  export CLAUDE_SUBPROCESS=0
  export CAST_AGENTS_DIR="$HOME/.claude/agents"
  export CAST_REPO_DIR="$HOME/fake-repo"
  sqlite3 "$CAST_DB_PATH" "CREATE TABLE agent_runs (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT, agent TEXT, started_at TEXT, status TEXT, model TEXT);
    CREATE TABLE sessions (id TEXT PRIMARY KEY, project TEXT, project_root TEXT, started_at TEXT, ended_at TEXT, status TEXT, deleted_at TEXT);"
  printf '%s\n' '{"models":{"_default":{"input":1},"claude-priced":{"input":1}}}' \
    > "$HOME/.claude/config/model-pricing.json"
}

teardown() {
  teardown_temp_home
}

_seed() { # model-sql-literal  days-ago
  sqlite3 "$CAST_DB_PATH" "INSERT INTO agent_runs (agent, started_at, model) VALUES ('x', strftime('%Y-%m-%dT%H:%M:%SZ','now','-$2 days'), $1);"
}

_line() {
  run bash -c "bash '$CAST_BIN' doctor 2>&1 | grep 'model-pricing:'"
}

@test "model-pricing: unpriced model in last 7d warns and names the id" {
  _seed "'claude-priced'" 1
  _seed "'claude-newmodel-9'" 1
  _line
  assert_output --partial "model-pricing: 1 model(s) seen in 7d priced at _default"
  assert_output --partial "claude-newmodel-9"
  refute_output --partial "claude-priced,"
}

@test "model-pricing: all models priced prints OK" {
  _seed "'claude-priced'" 1
  _line
  assert_output --partial "model-pricing: all 1 model(s) seen in 7d are priced"
}

@test "model-pricing: synthetic, NULL and empty models are ignored" {
  _seed "'<synthetic>'" 1
  _seed "NULL" 1
  _seed "''" 1
  _seed "'claude-priced'" 1
  _line
  assert_output --partial "all 1 model(s) seen in 7d are priced"
}

@test "model-pricing: unpriced model older than 7d is ignored" {
  _seed "'claude-ancient'" 10
  _seed "'claude-priced'" 1
  _line
  assert_output --partial "all 1 model(s) seen in 7d are priced"
  refute_output --partial "claude-ancient"
}

@test "model-pricing: absent pricing file gives INFO, not WARN" {
  rm -f "$HOME/.claude/config/model-pricing.json"
  _seed "'claude-newmodel-9'" 1
  _line
  assert_output --partial "model-pricing: config not found"
  refute_output --partial "priced at _default"
}

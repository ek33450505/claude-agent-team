#!/usr/bin/env bats

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_DIR/scripts/cast-cache-metrics.sh"

setup() {
  load 'helpers/setup'
  setup_temp_home
  mkdir -p "$HOME/.claude"

  export TEST_DB="$BATS_TEST_TMPDIR/test-cache-metrics-$$.db"
  export CAST_DB_PATH="$TEST_DB"
}

teardown() {
  rm -f "$TEST_DB"
  teardown_temp_home
}

report_file() {
  printf "%s/.claude/reports/cache-metrics-%s.json" "$HOME" "$(date +%Y-%m-%d)"
}

json_field() {
  python3 - "$1" "$(report_file)" <<'PY'
import json
import sys

field, path = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as fh:
    value = json.load(fh)[field]
print(value)
PY
}

@test "cast-cache-metrics: missing agent_runs table writes skipped report and exits 0" {
  sqlite3 "$TEST_DB" "CREATE TABLE unrelated (id INTEGER PRIMARY KEY);"

  run bash "$SCRIPT"

  assert_success
  assert_output --partial "Skipping cache metrics"
  [ "$(json_field status)" = "skipped" ]
  [ "$(json_field reason)" = "schema missing" ]
}

@test "cast-cache-metrics: agent_runs without cache columns writes skipped report" {
  sqlite3 "$TEST_DB" "CREATE TABLE agent_runs (id INTEGER PRIMARY KEY, started_at TEXT);"

  run bash "$SCRIPT"

  assert_success
  assert_output --partial "Skipping cache metrics"
  [ "$(json_field status)" = "skipped" ]
}

@test "cast-cache-metrics: seeded rows compute expected cache hit rate" {
  sqlite3 "$TEST_DB" <<'SQL'
CREATE TABLE agent_runs (
  id INTEGER PRIMARY KEY,
  started_at TEXT,
  cache_read_input_tokens INTEGER,
  cache_creation_input_tokens INTEGER,
  input_tokens INTEGER
);
INSERT INTO agent_runs (started_at, cache_read_input_tokens, cache_creation_input_tokens, input_tokens)
VALUES (datetime('now'), 90, 0, 10);
SQL

  run bash "$SCRIPT"

  assert_success
  assert_output --partial "Cache hit rate (30d): 90.0%"
  [ "$(json_field cache_read_tokens)" = "90" ]
  [ "$(json_field cache_write_tokens)" = "0" ]
  [ "$(json_field input_tokens)" = "10" ]
  [ "$(json_field cache_hit_rate_percent)" = "90.0" ]
}

@test "cast-cache-metrics: zero rows produce zero hit rate" {
  sqlite3 "$TEST_DB" <<'SQL'
CREATE TABLE agent_runs (
  id INTEGER PRIMARY KEY,
  started_at TEXT,
  cache_read_input_tokens INTEGER,
  cache_creation_input_tokens INTEGER,
  input_tokens INTEGER
);
SQL

  run bash "$SCRIPT"

  assert_success
  assert_output --partial "Cache hit rate (30d): 0.0%"
  [ "$(json_field cache_hit_rate_percent)" = "0.0" ]
}

@test "cast-cache-metrics: CLAUDE_SUBPROCESS=1 exits before writing a report" {
  CLAUDE_SUBPROCESS=1 run bash "$SCRIPT"

  assert_success
  [ ! -e "$(report_file)" ]
}

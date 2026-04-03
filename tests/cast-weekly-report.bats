#!/usr/bin/env bats

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
REPORT_SH="$REPO_DIR/scripts/cast-weekly-report.sh"
TUNER_SH="$REPO_DIR/scripts/cast-weekly-tuner.sh"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Create minimal cast.db schema (sessions, agent_runs) in a temp file
init_test_db() {
  local db_path="$1"
  sqlite3 "$db_path" <<'SQL'
CREATE TABLE IF NOT EXISTS sessions (
  id                    TEXT PRIMARY KEY,
  project               TEXT,
  project_root          TEXT,
  started_at            TEXT,
  ended_at              TEXT,
  model                 TEXT
);
CREATE TABLE IF NOT EXISTS agent_runs (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id      TEXT,
  agent           TEXT NOT NULL,
  model           TEXT,
  started_at      TEXT,
  ended_at        TEXT,
  status          TEXT,
  input_tokens    INTEGER,
  output_tokens   INTEGER,
  cost_usd        REAL,
  task_summary    TEXT,
  project         TEXT,
  agent_id        TEXT,
  batch_id        INTEGER
);
SQL
}

# ---------------------------------------------------------------------------
# Setup / Teardown
# ---------------------------------------------------------------------------

setup() {
  export ORIG_HOME="$HOME"
  export HOME="$(realpath "$(mktemp -d)")"
  mkdir -p "$HOME/.claude/cast"
  mkdir -p "$HOME/.claude/reports"
  mkdir -p "$HOME/.claude/agents"
}

teardown() {
  rm -rf "$HOME"
  export HOME="$ORIG_HOME"
}

# ---------------------------------------------------------------------------
# D5-2: Handles missing cast.db gracefully
# ---------------------------------------------------------------------------

@test "handles missing cast.db — exits 0 and creates placeholder report" {
  run bash "$REPORT_SH"
  [ "$status" -eq 0 ]
  # Output should contain the path of the generated file
  [[ "$output" == *"weekly-"* ]]
  # Extract the last line (the file path) — earlier lines are stderr messages
  local report_file
  report_file=$(echo "$output" | tail -1)
  [ -f "$report_file" ]
}

# ---------------------------------------------------------------------------
# D5-3: Report has YAML frontmatter (empty db — tables present, no rows)
# ---------------------------------------------------------------------------

@test "report has YAML frontmatter when db is empty" {
  local db_path="$HOME/.claude/cast.db"
  export CAST_DB_PATH="$db_path"
  init_test_db "$db_path"

  run bash "$REPORT_SH"
  [ "$status" -eq 0 ]
  local report_file="$output"
  [ -f "$report_file" ]

  run grep -c "^---" "$report_file"
  [ "$status" -eq 0 ]
  # At least 2 occurrences of --- (opening and closing frontmatter)
  [ "$output" -ge 2 ]

  run grep "type: weekly" "$report_file"
  [ "$status" -eq 0 ]

  run grep "week_of:" "$report_file"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# D5-4: Report file lands in correct location
# ---------------------------------------------------------------------------

@test "report file is created under ~/.claude/reports/" {
  local db_path="$HOME/.claude/cast.db"
  export CAST_DB_PATH="$db_path"
  init_test_db "$db_path"

  run bash "$REPORT_SH"
  [ "$status" -eq 0 ]

  # Check that at least one weekly report file exists in reports dir
  local count
  count=$(ls "$HOME/.claude/reports/weekly-"*.md 2>/dev/null | wc -l | tr -d ' ')
  [ "$count" -ge 1 ]
}

# ---------------------------------------------------------------------------
# D5-5: Report contains expected sections
# ---------------------------------------------------------------------------

@test "report contains expected section headers" {
  local db_path="$HOME/.claude/cast.db"
  export CAST_DB_PATH="$db_path"
  init_test_db "$db_path"

  run bash "$REPORT_SH"
  [ "$status" -eq 0 ]
  local report_file="$output"

  run grep "## Summary" "$report_file"
  [ "$status" -eq 0 ]

  run grep "## Agent Performance" "$report_file"
  [ "$status" -eq 0 ]

  run grep "## Top Failure Reasons" "$report_file"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# D5-6: Tuner handles missing cast.db gracefully
# ---------------------------------------------------------------------------

@test "cast-weekly-tuner.sh handles missing cast.db — exits 0" {
  export CAST_DB_PATH="/nonexistent/path/cast.db"
  run bash "$TUNER_SH"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# D5-7: Tuner logs budget_warn to tuning-log.jsonl on budget exceeded
# ---------------------------------------------------------------------------

@test "tuner writes budget_warn to tuning-log.jsonl when spend exceeds budget" {
  local db_path="$HOME/.claude/cast.db"
  export CAST_DB_PATH="$db_path"
  export CAST_WEEKLY_BUDGET="0.01"
  init_test_db "$db_path"

  # Insert a session and agent run with cost that exceeds the budget
  sqlite3 "$db_path" "INSERT INTO sessions (id, project, started_at)
    VALUES ('test-session-1', 'test-project', date('now', '-1 day'));"
  sqlite3 "$db_path" "INSERT INTO agent_runs (session_id, agent, started_at, cost_usd, status)
    VALUES ('test-session-1', 'test-agent', date('now', '-1 day'), 5.0, 'DONE');"

  run bash "$TUNER_SH"
  [ "$status" -eq 0 ]

  local tuning_log="$HOME/.claude/cast/tuning-log.jsonl"
  [ -f "$tuning_log" ]

  run grep "budget_warn" "$tuning_log"
  [ "$status" -eq 0 ]
}

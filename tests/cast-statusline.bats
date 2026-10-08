#!/usr/bin/env bats
# Tests for cast-statusline.sh — StatusLine formatter for Claude Code
# Verifies output rendering, JSON parsing, git integration, and DB queries

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_DIR/scripts/cast-statusline.sh"

setup() {
  load 'helpers/setup'
  setup_temp_home
  mkdir -p "$HOME/.claude"
  export CAST_DB_PATH="$HOME/.claude/cast.db"
  export TMPDIR="${BATS_TEST_TMPDIR}"
  # PATH-shim notify-send, terminal-notifier, osascript (not used by statusline but for safety)
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  echo '#!/bin/bash; exit 0' > "$BATS_TEST_TMPDIR/bin/notify-send"
  chmod +x "$BATS_TEST_TMPDIR/bin/notify-send"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  # Ensure we're NOT in a git repo initially (most tests need this baseline)
  unset GIT_WORK_TREE GIT_DIR GIT_CEILING_DIRECTORIES
  cd "$BATS_TEST_TMPDIR" || exit 1
}

teardown() {
  teardown_temp_home
}

# ───────────────────────────────────────────────────────────────────────────
# HAPPY PATH: Realistic input with all segments
# ───────────────────────────────────────────────────────────────────────────

@test "happy path: exit 0 and renders model, branch, cost, context" {
  local json='{
    "agent": {"name": "test-agent"},
    "cost": {"total_cost_usd": 0.42},
    "context_window": {"used_percentage": 62},
    "rate_limits": {"five_hour": {"used_percentage": "15"}},
    "model": {"display_name": "Sonnet 4"},
    "session_name": "my-session",
    "session_id": "sess123"
  }'

  run bash "$SCRIPT" <<< "$json"
  assert_success

  # Line 1: should have model, cost, context
  assert_output --partial "test-agent"
  assert_output --partial '$0.42'
  assert_output --partial "| ctx: "
  assert_output --partial "62%"
}

@test "happy path: fields split correctly under system /bin/bash (3.2 IFS regression)" {
  [ -x /bin/bash ] || skip "/bin/bash not present"
  local json='{
    "agent": {"name": "test-agent"},
    "cost": {"total_cost_usd": 0.42},
    "context_window": {"used_percentage": 62},
    "model": {"display_name": "Sonnet 4"},
    "session_name": "my-session",
    "session_id": "sess123"
  }'

  run /bin/bash "$SCRIPT" <<< "$json"
  assert_success
  assert_output --partial '$0.42'
  assert_output --partial "Sonnet 4"
  assert_output --partial "test-agent"
}

@test "happy path: non-empty output without fallback" {
  local json='{
    "agent": {"name": "main"},
    "cost": {"total_cost_usd": 0.10},
    "context_window": {"used_percentage": 45},
    "model": {"display_name": "Haiku"}
  }'

  run bash "$SCRIPT" <<< "$json"
  assert_success
  # Fallback is "CAST | n/a"
  refute_output --partial "CAST | n/a"
  # Should have some actual content
  assert [ ${#output} -gt 20 ]
}

# ───────────────────────────────────────────────────────────────────────────
# GIT INTEGRATION: Branch segment
# ───────────────────────────────────────────────────────────────────────────

@test "git: when in a git repo, branch appears in output" {
  git init . >/dev/null 2>&1
  git config user.email "test""@""test.com" 2>/dev/null || true
  git config user.name "Test" 2>/dev/null || true
  git checkout -b feature/test-branch >/dev/null 2>&1

  local json='{"agent": {"name": "main"}, "model": {"display_name": "Haiku"}}'
  run bash "$SCRIPT" <<< "$json"
  assert_success
  assert_output --partial "feature/test-branch"
}

@test "git: not in a git repo yields no git segment and no error" {
  # Already in $BATS_TEST_TMPDIR (not a git repo)
  local json='{"agent": {"name": "main"}, "model": {"display_name": "Haiku"}}'
  run bash "$SCRIPT" <<< "$json"
  assert_success
  # Should still output something valid
  assert [ ${#output} -gt 0 ]
  # Stderr should be clean
  [[ ! "$stderr" =~ "fatal" ]] || false
}

# ───────────────────────────────────────────────────────────────────────────
# ERROR HANDLING: Empty/malformed input
# ───────────────────────────────────────────────────────────────────────────

@test "empty stdin: exit 0 and output fallback message" {
  run bash "$SCRIPT" <<< ""
  assert_success
  assert_output "CAST | n/a"
}

@test "malformed JSON: fall back to safe defaults gracefully" {
  local json='{ bad json ]}'
  run bash "$SCRIPT" <<< "$json"
  assert_success
  # Should not crash, should output something
  assert [ ${#output} -gt 0 ]
}

@test "missing agent field: defaults to 'main'" {
  local json='{"model": {"display_name": "Test"}}'
  run bash "$SCRIPT" <<< "$json"
  assert_success
  assert_output --partial "main"
}

# ───────────────────────────────────────────────────────────────────────────
# COST FORMATTING
# ───────────────────────────────────────────────────────────────────────────

@test "cost formatting: displays as dollar amount with 2 decimals" {
  local json='{
    "agent": {"name": "test"},
    "cost": {"total_cost_usd": 1.5},
    "model": {"display_name": "Sonnet"}
  }'

  run bash "$SCRIPT" <<< "$json"
  assert_success
  assert_output --partial '$1.50'
}

@test "cost zero: displays as $0.00" {
  local json='{
    "agent": {"name": "test"},
    "cost": {"total_cost_usd": 0},
    "model": {"display_name": "Sonnet"}
  }'

  run bash "$SCRIPT" <<< "$json"
  assert_success
  assert_output --partial '$0.00'
}

# ───────────────────────────────────────────────────────────────────────────
# CONTEXT PERCENTAGE COLORING
# ───────────────────────────────────────────────────────────────────────────

@test "context < 50%: uses green color code" {
  local json='{
    "agent": {"name": "test"},
    "context_window": {"used_percentage": 25},
    "model": {"display_name": "Haiku"}
  }'

  run bash "$SCRIPT" <<< "$json"
  assert_success
  assert_output --partial "25%"
  # ANSI green is \033[32m
  [[ "$output" =~ "32m" ]] || false
}

@test "context 50-75%: uses yellow color code" {
  local json='{
    "agent": {"name": "test"},
    "context_window": {"used_percentage": 60},
    "model": {"display_name": "Haiku"}
  }'

  run bash "$SCRIPT" <<< "$json"
  assert_success
  assert_output --partial "60%"
  # ANSI yellow is \033[33m
  [[ "$output" =~ "33m" ]] || false
}

@test "context >= 75%: uses red color code" {
  local json='{
    "agent": {"name": "test"},
    "context_window": {"used_percentage": 85},
    "model": {"display_name": "Haiku"}
  }'

  run bash "$SCRIPT" <<< "$json"
  assert_success
  assert_output --partial "85%"
  # ANSI red is \033[31m
  [[ "$output" =~ "31m" ]] || false
}

# ───────────────────────────────────────────────────────────────────────────
# LINE 2: Session, rate limit, agents
# ───────────────────────────────────────────────────────────────────────────

@test "line2: session_name appears when present" {
  local json='{
    "agent": {"name": "test"},
    "session_name": "demo-session",
    "model": {"display_name": "Haiku"}
  }'

  run bash "$SCRIPT" <<< "$json"
  assert_success
  assert_output --partial "demo-session"
}

@test "line2: rate limit appears when present" {
  local json='{
    "agent": {"name": "test"},
    "rate_limits": {"five_hour": {"used_percentage": "45"}},
    "model": {"display_name": "Haiku"}
  }'

  run bash "$SCRIPT" <<< "$json"
  assert_success
  assert_output --partial "rate: 45%"
}

@test "line2: model always appears" {
  local json='{"agent": {"name": "test"}, "model": {"display_name": "Opus 4"}}'

  run bash "$SCRIPT" <<< "$json"
  assert_success
  assert_output --partial "Opus 4"
}

# ───────────────────────────────────────────────────────────────────────────
# DATABASE: Cast.db queries for active agents and counts
# ───────────────────────────────────────────────────────────────────────────

@test "database: missing cast.db does not crash" {
  # CAST_DB_PATH points to non-existent file
  export CAST_DB_PATH="$HOME/.claude/nonexistent.db"

  local json='{
    "agent": {"name": "test"},
    "session_id": "sess-123",
    "model": {"display_name": "Haiku"}
  }'

  run bash "$SCRIPT" <<< "$json"
  assert_success
  assert [ ${#output} -gt 0 ]
}

@test "database: empty cast.db (no schema) does not crash" {
  touch "$CAST_DB_PATH"

  local json='{
    "agent": {"name": "test"},
    "session_id": "sess-456",
    "model": {"display_name": "Haiku"}
  }'

  run bash "$SCRIPT" <<< "$json"
  assert_success
}

@test "database: active agents from DB appear when session_id present" {
  # Create minimal schema and seed an agent_runs row
  sqlite3 "$CAST_DB_PATH" <<'SQL'
CREATE TABLE agent_runs (
  id INTEGER PRIMARY KEY,
  agent TEXT,
  session_id TEXT,
  status TEXT
);
INSERT INTO agent_runs (agent, session_id, status)
VALUES ('test-writer', 'sess-789', 'running');
INSERT INTO agent_runs (agent, session_id, status)
VALUES ('code-reviewer', 'sess-789', 'running');
INSERT INTO agent_runs (agent, session_id, status)
VALUES ('code-reviewer', 'sess-789', 'done');
SQL

  local json='{
    "agent": {"name": "main"},
    "session_id": "sess-789",
    "model": {"display_name": "Haiku"}
  }'

  run bash "$SCRIPT" <<< "$json"
  assert_success
  # Should show the two running agents
  assert_output --partial "agents:"
  assert_output --partial "test-writer"
  assert_output --partial "code-reviewer"
}

@test "database: dispatch count appears in agents section" {
  sqlite3 "$CAST_DB_PATH" <<'SQL'
CREATE TABLE agent_runs (
  id INTEGER PRIMARY KEY,
  agent TEXT,
  session_id TEXT,
  status TEXT
);
INSERT INTO agent_runs (agent, session_id, status)
VALUES ('test-writer', 'sess-999', 'running');
INSERT INTO agent_runs (agent, session_id, status)
VALUES ('test-writer', 'sess-999', 'done');
INSERT INTO agent_runs (agent, session_id, status)
VALUES ('code-reviewer', 'sess-999', 'done');
SQL

  local json='{
    "agent": {"name": "main"},
    "session_id": "sess-999",
    "model": {"display_name": "Haiku"}
  }'

  run bash "$SCRIPT" <<< "$json"
  assert_success
  # Should show dispatch count: 3 total
  assert_output --partial "3 dispatched"
}

# ───────────────────────────────────────────────────────────────────────────
# UPTIME: Session epoch file calculation
# ───────────────────────────────────────────────────────────────────────────

@test "uptime: creates epoch file on first run" {
  local json='{
    "agent": {"name": "test"},
    "session_id": "sess-uptime-1",
    "model": {"display_name": "Haiku"}
  }'

  run bash "$SCRIPT" <<< "$json"
  assert_success

  local epoch_file="$HOME/.claude/cast-state/cast-session-start-sess-uptime-1.epoch"
  assert [ -f "$epoch_file" ]
  # S3b: state lives in a 0700 dir under ~/.claude, never in TMPDIR
  assert [ ! -e "${TMPDIR}/cast-session-start-sess-uptime-1.epoch" ]
  [ "$(file_mode "$HOME/.claude/cast-state")" = "700" ]
}

@test "uptime: on first run, shows 0m" {
  local json='{
    "agent": {"name": "test"},
    "session_id": "sess-uptime-new",
    "model": {"display_name": "Haiku"}
  }'

  run bash "$SCRIPT" <<< "$json"
  assert_success
  assert_output --partial "0m"
}

@test "uptime: on second run, shows elapsed time" {
  local session_id="sess-uptime-elapsed"
  local epoch_file="$HOME/.claude/cast-state/cast-session-start-${session_id}.epoch"
  mkdir -m 700 -p "$HOME/.claude/cast-state"

  # Pre-seed the epoch file with a time ~5 minutes ago
  local now; now="$(date +%s)"
  local five_min_ago=$(( now - 300 ))
  echo "$five_min_ago" > "$epoch_file"

  local json='{
    "agent": {"name": "test"},
    "session_id": "'"$session_id"'",
    "model": {"display_name": "Haiku"}
  }'

  run bash "$SCRIPT" <<< "$json"
  assert_success
  # Should show approximately 5m
  [[ "$output" =~ "5m" ]] || [[ "$output" =~ "🕐" ]]
}


# S3b: the epoch path is derived exactly as agent-status-reader.sh derives it (same state dir, same
# session-id validation/fallback). Run both for the same id and compare what lands in the state dir.
_sl_state_files() { ls -1 "$HOME/.claude/cast-state" 2>/dev/null | sort | tr '\n' ' '; }

@test "uptime S3b: statusline and agent-status-reader resolve the SAME epoch path (valid id and invalid id -> default)" {
  local sid json statusline_files reader_files
  for sid in "sess-same-1" "bad/../id with spaces"; do
    rm -rf "$HOME/.claude/cast-state"
    json="$(python3 -c 'import json,sys; print(json.dumps({"agent":{"name":"t"},"session_id":sys.argv[1],"model":{"display_name":"H"}}))' "$sid")"
    run bash "$SCRIPT" <<< "$json"
    assert_success
    statusline_files="$(_sl_state_files)"
    rm -rf "$HOME/.claude/cast-state"
    run env CLAUDE_SUBPROCESS=1 CLAUDE_SESSION_ID="$sid" CAST_STATUS_DIR="$HOME/.claude/agent-status" bash "$REPO_DIR/scripts/agent-status-reader.sh" <<< "{}"
    reader_files="$(_sl_state_files)"
    [ -n "$statusline_files" ]
    assert_equal "$statusline_files" "$reader_files"
  done
  # CONTROL: the invalid id really fell back to "default" (a raw id would have produced another name)
  assert_equal "$reader_files" "cast-session-start-default.epoch "
}

@test "uptime S3b: a symlinked epoch file / state dir is refused (no write through it, no uptime)" {
  local victim="$BATS_TEST_TMPDIR/victim.txt" json='{"agent":{"name":"t"},"session_id":"sess-sym","model":{"display_name":"H"}}'
  echo SAFE > "$victim"
  mkdir -m 700 -p "$HOME/.claude/cast-state"
  ln -s "$victim" "$HOME/.claude/cast-state/cast-session-start-sess-sym.epoch"
  run bash "$SCRIPT" <<< "$json"
  assert_success
  assert_equal "$(cat "$victim")" "SAFE"
  rm -rf "$HOME/.claude/cast-state"
  mkdir -p "$BATS_TEST_TMPDIR/attacker"
  ln -s "$BATS_TEST_TMPDIR/attacker" "$HOME/.claude/cast-state"
  run bash "$SCRIPT" <<< "$json"
  assert_success
  [ -z "$(ls -A "$BATS_TEST_TMPDIR/attacker")" ]
}

@test "uptime S3b: a non-numeric epoch file never reaches arithmetic (no code execution, no uptime)" {
  local marker="$BATS_TEST_TMPDIR/pwned"
  mkdir -m 700 -p "$HOME/.claude/cast-state"
  echo "a[\$(touch $marker)]" > "$HOME/.claude/cast-state/cast-session-start-sess-num.epoch"
  run bash "$SCRIPT" <<< '{"agent":{"name":"t"},"session_id":"sess-num","model":{"display_name":"H"}}'
  assert_success
  [ ! -e "$marker" ]
}

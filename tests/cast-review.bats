#!/usr/bin/env bats
# Tests for `cast review` subcommand (v10 W0.1 record readback)
# Covers:
#   1. Full response printed untruncated
#   2. Prefix match returns all agent__* rows, excludes unrelated agents
#   3. Newest-first ordering
#   4. --last N limits results
#   5. NULL response -> "(no response recorded)"
#   6. Empty-string response -> "(no response recorded)"
#   7. No match -> honest message, exit 0
#   8. Missing positional arg -> exit failure
#   9. DB absent -> exit failure, 'cast.db not found'
#   10. --json structure + full response passthrough

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
CAST_BIN="$REPO_DIR/bin/cast"

# ───────────────────────────────────────────────────────────────────────────
# Setup / Teardown — isolated temp HOME per test (HARD RULE — never real $HOME)
# ───────────────────────────────────────────────────────────────────────────

setup() {
  load 'helpers/setup'
  setup_temp_home
  export CAST_DB_PATH="$HOME/.claude/cast.db"
  export CAST_SCRIPTS_DIR="$REPO_DIR/scripts"
  export CLAUDE_SUBPROCESS=0
}

teardown() {
  teardown_temp_home
}

# ───────────────────────────────────────────────────────────────────────────
# Helper: initialize schema + seed deterministic agent_runs data
#
# code-reviewer__alpha   DONE,    started 10:00, multi-line real response
# code-reviewer__beta    DONE,    started 11:00 (newer than alpha), short response
# code-reviewer__gamma   running, started 12:00 (newest), response NULL
# backend-writer__delta  DONE,    started 09:00 (oldest), response '' (empty)
# ───────────────────────────────────────────────────────────────────────────

_seed() {
  bash "$REPO_DIR/scripts/cast-db-init.sh" >/dev/null 2>&1
  sqlite3 "$CAST_DB_PATH" <<'SQL'
INSERT INTO agent_runs (session_id, agent, started_at, ended_at, status, tool_uses, duration_ms, branch, model, response)
VALUES
  ('sess-1', 'code-reviewer__alpha', '2026-08-14T10:00:00Z', '2026-08-14T10:03:12Z', 'DONE', 25, 192000, 'feature/x', 'sonnet',
   'ALPHA-REVIEW-BODY-START
Line one of the alpha review.
Line two of the alpha review.
Line three of the alpha review.
ALPHA-REVIEW-BODY-END'),
  ('sess-1', 'code-reviewer__beta', '2026-08-14T11:00:00Z', '2026-08-14T11:01:00Z', 'DONE', 3, 15000, 'feature/x', 'sonnet',
   'BETA-SHORT-BODY'),
  ('sess-1', 'code-reviewer__gamma', '2026-08-14T12:00:00Z', NULL, 'running', 1, NULL, 'feature/x', 'sonnet', NULL),
  ('sess-1', 'backend-writer__delta', '2026-08-14T09:00:00Z', '2026-08-14T09:02:00Z', 'DONE', 10, 30000, 'feature/y', 'sonnet', '');
SQL
}

# ───────────────────────────────────────────────────────────────────────────
# 1. Full response printed untruncated
# ───────────────────────────────────────────────────────────────────────────

@test "cast review: prints full response body untruncated" {
  _seed
  run bash "$CAST_BIN" review code-reviewer__alpha
  assert_success
  assert_output --partial 'ALPHA-REVIEW-BODY-START'
  assert_output --partial 'ALPHA-REVIEW-BODY-END'
}

# ───────────────────────────────────────────────────────────────────────────
# 2. Prefix match
# ───────────────────────────────────────────────────────────────────────────

@test "cast review code-reviewer: matches alpha, beta, gamma but not backend-writer__delta" {
  _seed
  run bash "$CAST_BIN" review code-reviewer --last 10
  assert_success
  assert_output --partial 'code-reviewer__alpha'
  assert_output --partial 'code-reviewer__beta'
  assert_output --partial 'code-reviewer__gamma'
  refute_output --partial 'backend-writer__delta'
}

# ───────────────────────────────────────────────────────────────────────────
# 3. Newest-first ordering
# ───────────────────────────────────────────────────────────────────────────

@test "cast review: newest-first ordering (gamma before beta before alpha)" {
  _seed
  run bash "$CAST_BIN" review code-reviewer --last 10
  assert_success
  local pos_gamma pos_beta pos_alpha
  pos_gamma=$(printf '%s\n' "$output" | grep -n 'code-reviewer__gamma' | head -1 | cut -d: -f1)
  pos_beta=$(printf '%s\n' "$output" | grep -n 'code-reviewer__beta' | head -1 | cut -d: -f1)
  pos_alpha=$(printf '%s\n' "$output" | grep -n 'code-reviewer__alpha' | head -1 | cut -d: -f1)
  [ -n "$pos_gamma" ]
  [ -n "$pos_beta" ]
  [ -n "$pos_alpha" ]
  [ "$pos_gamma" -lt "$pos_beta" ]
  [ "$pos_beta" -lt "$pos_alpha" ]
}

# ───────────────────────────────────────────────────────────────────────────
# 4. --last N limits results
# ───────────────────────────────────────────────────────────────────────────

@test "cast review --last 1: returns only the newest row (gamma), excludes alpha body" {
  _seed
  run bash "$CAST_BIN" review code-reviewer --last 1
  assert_success
  assert_output --partial 'code-reviewer__gamma'
  refute_output --partial 'ALPHA-REVIEW-BODY-START'
}

# ───────────────────────────────────────────────────────────────────────────
# 5. NULL response bites
# ───────────────────────────────────────────────────────────────────────────

@test "cast review: NULL response prints metadata header + '(no response recorded)'" {
  _seed
  run bash "$CAST_BIN" review code-reviewer__gamma
  assert_success
  assert_output --partial 'running'
  assert_output --partial '(no response recorded)'
}

# ───────────────────────────────────────────────────────────────────────────
# 6. Empty-string response bites
# ───────────────────────────────────────────────────────────────────────────

@test "cast review: empty-string response prints '(no response recorded)'" {
  _seed
  run bash "$CAST_BIN" review backend-writer__delta
  assert_success
  assert_output --partial '(no response recorded)'
}

# ───────────────────────────────────────────────────────────────────────────
# 7. No match
# ───────────────────────────────────────────────────────────────────────────

@test "cast review nonexistent-agent: honest no-match message, exit 0" {
  _seed
  run bash "$CAST_BIN" review nonexistent-agent
  assert_success
  assert_output --partial "No agent runs match"
}

# ───────────────────────────────────────────────────────────────────────────
# 8. Missing positional arg
# ───────────────────────────────────────────────────────────────────────────

@test "cast review with no agent argument: fails" {
  _seed
  run bash "$CAST_BIN" review
  assert_failure
}

# ───────────────────────────────────────────────────────────────────────────
# 9. DB absent
# ───────────────────────────────────────────────────────────────────────────

@test "cast review: DB absent exits non-zero with 'cast.db not found'" {
  rm -f "$CAST_DB_PATH"
  run bash "$CAST_BIN" review code-reviewer
  assert_failure
  assert_output --partial 'cast.db not found'
}

# ───────────────────────────────────────────────────────────────────────────
# 10. --json structure
# ───────────────────────────────────────────────────────────────────────────

@test "cast review --json: valid JSON, view=agent_review, full response passthrough" {
  _seed
  run bash "$CAST_BIN" review code-reviewer__alpha --json
  assert_success
  run python3 -c "
import sys, json
data = json.loads(sys.argv[1])
assert data['view'] == 'agent_review', 'wrong view: ' + str(data.get('view'))
rows = data['rows']
assert len(rows) == 1, 'expected 1 row, got: ' + str(len(rows))
assert rows[0]['agent'] == 'code-reviewer__alpha', 'wrong agent: ' + rows[0]['agent']
assert 'ALPHA-REVIEW-BODY-START' in rows[0]['response'], 'missing start marker'
assert 'ALPHA-REVIEW-BODY-END' in rows[0]['response'], 'missing end marker'
print('OK')
" "$output"
  assert_success
}

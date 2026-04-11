#!/usr/bin/env bats

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
TEARDOWN_SH="$REPO_DIR/scripts/cast-swarm-teardown.sh"
BOOTSTRAP_SH="$REPO_DIR/scripts/cast-swarm-bootstrap.sh"
DB_INIT="$REPO_DIR/scripts/cast-db-init.sh"
VALID_CONFIG="$REPO_DIR/swarm-configs/fullstack-team.yml"

setup() {
  command -v python3 >/dev/null && python3 -c "import yaml" 2>/dev/null || skip "pyyaml not available"
  export ORIG_HOME="$HOME"
  export HOME="$(realpath "$(mktemp -d)")"
  mkdir -p "$HOME/.claude/cast/swarms" "$HOME/.claude/logs"

  export TEST_DB="/tmp/test-cast-$$.db"
  export CAST_DB_PATH="$TEST_DB"
  bash "$DB_INIT" --db "$TEST_DB"
}

teardown() {
  rm -f "$TEST_DB"
  rm -rf "$HOME"
  export HOME="$ORIG_HOME"
  # Clean up any swarm worktrees created during tests (F10)
  git -C "$REPO_DIR" worktree list --porcelain 2>/dev/null | grep "^worktree /tmp/cast-swarm-" | sed 's/^worktree //' | xargs -I{} git -C "$REPO_DIR" worktree remove --force {} 2>/dev/null || true
  rm -rf /tmp/cast-swarm-* 2>/dev/null || true
}

# Helper: bootstrap a swarm and return the swarm_id
bootstrap_swarm() {
  bash "$BOOTSTRAP_SH" "$VALID_CONFIG" "Test task for teardown" 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin)['swarm_id'])"
}

# ---------------------------------------------------------------------------
# teardown: exits 1 for nonexistent swarm_id
# ---------------------------------------------------------------------------

@test "cast-swarm-teardown: nonexistent swarm_id → exit 1" {
  run bash "$TEARDOWN_SH" --force "no-such-swarm-id-$$"
  assert_failure 1
}

# ---------------------------------------------------------------------------
# teardown: --force flag skips confirmation
# ---------------------------------------------------------------------------

@test "cast-swarm-teardown: --force skips interactive confirmation" {
  local swarm_id
  swarm_id="$(bootstrap_swarm)"

  # Without --force, it would wait for stdin. With --force it must not hang.
  run bash "$TEARDOWN_SH" --force "$swarm_id"
  # Exit 0 or 1 is acceptable — main check is that it does not hang
  [ "$status" -le 1 ]
}

# ---------------------------------------------------------------------------
# teardown: updates swarm status to failed in cast.db
# ---------------------------------------------------------------------------

@test "cast-swarm-teardown: updates swarm status to failed in cast.db" {
  local swarm_id
  swarm_id="$(bootstrap_swarm)"

  bash "$TEARDOWN_SH" --force "$swarm_id" > /dev/null 2>&1 || true

  local db_status
  db_status=$(sqlite3 "$TEST_DB" "SELECT status FROM swarm_sessions WHERE id='$swarm_id' LIMIT 1;")
  [ "$db_status" = "failed" ]
}

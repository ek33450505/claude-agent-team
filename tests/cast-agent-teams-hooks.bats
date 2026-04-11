#!/usr/bin/env bats

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
IDLE_HOOK="$REPO_DIR/scripts/cast-teammate-idle-hook.sh"
COMPLETED_HOOK="$REPO_DIR/scripts/cast-task-completed-hook.sh"
WORKTREE_HOOK="$REPO_DIR/scripts/cast-worktree-create-hook.sh"
DB_INIT="$REPO_DIR/scripts/cast-db-init.sh"

setup() {
  export ORIG_HOME="$HOME"
  export HOME="$(realpath "$(mktemp -d)")"
  mkdir -p "$HOME/.claude/scripts" "$HOME/.claude/cast/events" "$HOME/.claude/logs"

  # Stub cast-events.sh so DB logging is a no-op in tests
  cat > "$HOME/.claude/scripts/cast-events.sh" <<'STUB'
cast_emit_event() { return 0; }
STUB

  export TEST_DB="/tmp/test-cast-$$.db"
  export CAST_DB_PATH="$TEST_DB"
  bash "$DB_INIT" --db "$TEST_DB"
}

teardown() {
  rm -f "$TEST_DB"
  rm -rf "$HOME"
  export HOME="$ORIG_HOME"
}

make_idle_payload() {
  local result="${1:-}"
  python3 -c "
import json, sys
print(json.dumps({'result': sys.argv[1]}))
" "$result"
}

make_completed_payload() {
  local task_id="${1:-task-test-123}"
  local result="${2:-Status: DONE}"
  python3 -c "
import json, sys
print(json.dumps({
    'hook_event_name': 'TaskCompleted',
    'task_id': sys.argv[1],
    'task_subject': 'Test task',
    'session_id': 'sess-test-456',
    'agent_name': 'code-writer',
    'result': sys.argv[2],
    'cwd': '/tmp/test-project',
}))
" "$task_id" "$result"
}

make_worktree_payload() {
  local worktree_path="${1:-}"
  python3 -c "
import json, sys
payload = {
    'hook_event_name': 'WorktreeCreate',
    'branch': 'cast-test-branch',
    'session_id': 'sess-wt-789',
}
if sys.argv[1]:
    payload['worktree_path'] = sys.argv[1]
print(json.dumps(payload))
" "$worktree_path"
}

# ---------------------------------------------------------------------------
# cast-teammate-idle-hook: valid non-empty result → exit 0
# ---------------------------------------------------------------------------

@test "cast-teammate-idle-hook: valid non-empty result → exit 0" {
  run bash "$IDLE_HOOK" <<< "$(make_idle_payload "The task is complete. All files written successfully.")"
  assert_success
}

# ---------------------------------------------------------------------------
# cast-teammate-idle-hook: empty result → exit 2
# ---------------------------------------------------------------------------

@test "cast-teammate-idle-hook: empty result → exit 2" {
  run bash "$IDLE_HOOK" <<< "$(make_idle_payload "")"
  assert_failure 2
}

# ---------------------------------------------------------------------------
# cast-teammate-idle-hook: TODO placeholder → exit 2
# ---------------------------------------------------------------------------

@test "cast-teammate-idle-hook: TODO placeholder in result → exit 2" {
  run bash "$IDLE_HOOK" <<< "$(make_idle_payload "Here is my result but TODO finish this part")"
  assert_failure 2
}

# ---------------------------------------------------------------------------
# cast-task-completed-hook: valid input → exit 0 (never blocks)
# ---------------------------------------------------------------------------

@test "cast-task-completed-hook: valid input → exit 0" {
  run bash "$COMPLETED_HOOK" <<< "$(make_completed_payload "task-abc-001" "Status: DONE\nAll changes implemented.")"
  assert_success
}

# ---------------------------------------------------------------------------
# cast-task-completed-hook: missing fields → exit 0 (must never block)
# ---------------------------------------------------------------------------

@test "cast-task-completed-hook: missing fields → exit 0 (must never block)" {
  run bash "$COMPLETED_HOOK" <<< "{}"
  assert_success
}

# ---------------------------------------------------------------------------
# cast-task-completed-hook: empty input → exit 0 (graceful no-op)
# ---------------------------------------------------------------------------

@test "cast-task-completed-hook: empty input → exit 0" {
  run bash "$COMPLETED_HOOK" <<< ""
  assert_success
}

# ---------------------------------------------------------------------------
# cast-worktree-create-hook: valid worktree path → exit 0
# ---------------------------------------------------------------------------

@test "cast-worktree-create-hook: valid worktree path → exit 0" {
  local worktree_dir
  worktree_dir="$(mktemp -d)"

  run bash "$WORKTREE_HOOK" <<< "$(make_worktree_payload "$worktree_dir")"
  assert_success

  rm -rf "$worktree_dir"
}

# ---------------------------------------------------------------------------
# cast-worktree-create-hook: missing worktree_path → exit 0 (must not block)
# ---------------------------------------------------------------------------

@test "cast-worktree-create-hook: missing worktree_path → exit 0" {
  run bash "$WORKTREE_HOOK" <<< "$(make_worktree_payload "")"
  assert_success
}

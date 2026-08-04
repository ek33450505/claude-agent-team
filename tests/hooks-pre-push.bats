#!/usr/bin/env bats
# Tests for scripts/hooks/pre-push.sh
# Covers: CLAUDE_SUBPROCESS=1 guard, QUEUE_ADD executable check, queue-add.sh invocation,
# priority 2 flag, always-exit-0 guarantee.
# Uses isolated temp HOME + temp CAST_DB_PATH — never touches real ~/.claude.

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
PRE_PUSH="$REPO_DIR/scripts/hooks/pre-push.sh"

setup() {
  load 'helpers/setup'
  setup_temp_home  # sets HOME to a temp dir; exports ORIG_HOME

  # Create temp scripts layout: HOME/s/hooks/pre-push.sh and HOME/s/cast-queue-add.sh
  mkdir -p "$HOME/s/hooks"
  cp "$PRE_PUSH" "$HOME/s/hooks/pre-push.sh"

  # Stub queue-add that logs invocations
  cat > "$HOME/s/cast-queue-add.sh" <<'EOF'
#!/bin/bash
# Stub queue-add: log args, exit 0
printf '%s\n' "$@" >> "$HOME/queue-add.log"
exit 0
EOF
  chmod +x "$HOME/s/cast-queue-add.sh"

  # Subshell will run the hook from a temp repo context
  export TEST_HOOK_PATH="$HOME/s/hooks/pre-push.sh"
  export QUEUE_LOG="$HOME/queue-add.log"
}

teardown() {
  rm -f "$HOME/queue-add.log" "$HOME/s/hooks/pre-push.sh" "$HOME/s/cast-queue-add.sh"
  rmdir "$HOME/s/hooks" "$HOME/s" 2>/dev/null || true
  teardown_temp_home
}

# --- CLAUDE_SUBPROCESS=1 guard ---

@test "pre-push exits 0 when CLAUDE_SUBPROCESS=1" {
  run bash -c "
    export CLAUDE_SUBPROCESS=1
    bash '$TEST_HOOK_PATH' origin '' </dev/null
  "
  assert_success
  # Verify stub was NOT invoked (no log file created)
  [[ ! -f "$QUEUE_LOG" ]] && return 0 || (cat "$QUEUE_LOG" && return 1)
}

# --- QUEUE_ADD not executable ---

@test "pre-push exits 0 when QUEUE_ADD is not executable" {
  # Temporarily make the stub non-executable
  chmod -x "$HOME/s/cast-queue-add.sh"

  run bash -c "
    bash '$TEST_HOOK_PATH' origin '' </dev/null
  "
  assert_success

  # Restore permissions for cleanup
  chmod +x "$HOME/s/cast-queue-add.sh"
}

# --- Happy path: QUEUE_ADD invoked with priority 2 ---

@test "pre-push invokes QUEUE_ADD with 'security' and '--priority 2'" {
  run bash -c "
    bash '$TEST_HOOK_PATH' origin '' </dev/null
  "
  assert_success

  # Check log contains 'security' and '--priority 2'
  [[ -f "$QUEUE_LOG" ]] || { echo 'Log not created'; return 1; }
  grep -q 'security' "$QUEUE_LOG" || { echo 'security not found'; cat "$QUEUE_LOG"; return 1; }
  grep -q '\-\-priority' "$QUEUE_LOG" || { echo '--priority not found'; cat "$QUEUE_LOG"; return 1; }
  grep -q '2' "$QUEUE_LOG" || { echo '2 not found'; cat "$QUEUE_LOG"; return 1; }
}

# --- Always exit 0 ---

@test "pre-push exits 0 even when QUEUE_ADD fails" {
  # Create a stub that exits 1
  cat > "$HOME/s/cast-queue-add.sh" <<'EOF'
#!/bin/bash
exit 1
EOF
  chmod +x "$HOME/s/cast-queue-add.sh"

  run bash -c "
    bash '$TEST_HOOK_PATH' origin '' </dev/null
  "
  assert_success  # Must still be 0 due to || true
}

# --- Graceful handling of missing QUEUE_ADD ---

@test "pre-push exits 0 when QUEUE_ADD does not exist" {
  rm -f "$HOME/s/cast-queue-add.sh"

  run bash -c "
    bash '$TEST_HOOK_PATH' origin '' </dev/null
  "
  assert_success
}

#!/usr/bin/env bats

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
HOOK_SH="$REPO_DIR/scripts/cast-precompact-guard.sh"

setup() {
  export ORIG_HOME="$HOME"
  export ORIG_CAST_DB_PATH="${CAST_DB_PATH:-}"
  # Isolated temp HOME so the hardcoded KNOWN_PROJECTS in $HOME/Projects/... miss real repos
  export HOME="$(mktemp -d)"
  mkdir -p "$HOME/.claude/logs"
  unset CLAUDE_SUBPROCESS
  unset CAST_EXTRA_PROJECT
}

teardown() {
  [ -n "${TEMP_GIT_REPO:-}" ] && rm -rf "$TEMP_GIT_REPO"
  rm -rf "$HOME"
  export HOME="$ORIG_HOME"
  if [ -n "$ORIG_CAST_DB_PATH" ]; then
    export CAST_DB_PATH="$ORIG_CAST_DB_PATH"
  else
    unset CAST_DB_PATH
  fi
}

# ---------------------------------------------------------------------------
# 1. allow path: only project visible is a clean git repo
# ---------------------------------------------------------------------------
@test "PreCompact guard: returns allow decision when no dirty repos" {
  local clean_repo
  clean_repo=$(mktemp -d)
  TEMP_GIT_REPO="$clean_repo"
  (
    cd "$clean_repo"
    git init -q
    git config user.email "test@test.com"
    git config user.name "Test"
    echo "init" > README.md
    git add README.md
    git commit -q -m "init" 2>/dev/null
  ) || true

  run bash -c "echo '{}' | CAST_EXTRA_PROJECT='$clean_repo' CAST_DB_PATH=/dev/null bash '$HOOK_SH'"
  assert_success
  assert_output --partial '"decision":"allow"'
}

# ---------------------------------------------------------------------------
# 2. block path: dirty repo via CAST_EXTRA_PROJECT
# ---------------------------------------------------------------------------
@test "PreCompact guard: returns block decision when CAST_EXTRA_PROJECT is dirty" {
  local dirty_repo
  dirty_repo=$(mktemp -d)
  TEMP_GIT_REPO="$dirty_repo"
  (
    cd "$dirty_repo"
    git init -q
    git config user.email "test@test.com"
    git config user.name "Test"
    echo "init" > README.md
    git add README.md
    git commit -q -m "init" 2>/dev/null
    echo "untracked" > untracked.txt
  ) || true

  run bash -c "echo '{}' | CAST_EXTRA_PROJECT='$dirty_repo' CAST_DB_PATH=/dev/null bash '$HOOK_SH'"
  assert_success
  # Tolerate either compact ('"decision":"block"') or pretty ('"decision": "block"') JSON
  assert_output --regexp '"decision":[[:space:]]*"block"'
  assert_output --partial "$dirty_repo"
}

# ---------------------------------------------------------------------------
# 3. non-git directory is silently skipped
# ---------------------------------------------------------------------------
@test "PreCompact guard: skips non-git directories without error" {
  local non_git_dir
  non_git_dir=$(mktemp -d)
  TEMP_GIT_REPO="$non_git_dir"

  run bash -c "echo '{}' | CAST_EXTRA_PROJECT='$non_git_dir' CAST_DB_PATH=/dev/null bash '$HOOK_SH'"
  assert_success
  assert_output --partial '"decision":"allow"'
}

# ---------------------------------------------------------------------------
# 4. invalid stdin: exit 0 cleanly
# ---------------------------------------------------------------------------
@test "PreCompact guard: exits 0 even with invalid stdin" {
  run bash -c "echo 'not-json' | CAST_DB_PATH=/dev/null bash '$HOOK_SH'"
  assert_success
}

# ---------------------------------------------------------------------------
# 5. empty CAST_EXTRA_PROJECT env var: still works
# ---------------------------------------------------------------------------
@test "PreCompact guard: exits 0 with empty CAST_EXTRA_PROJECT env" {
  run bash -c "CAST_EXTRA_PROJECT='' CAST_DB_PATH=/dev/null echo '{}' | bash '$HOOK_SH'"
  assert_success
}

# ---------------------------------------------------------------------------
# 6. missing/unreadable CAST_DB_PATH does not crash
# ---------------------------------------------------------------------------
@test "PreCompact guard: handles missing CAST_DB_PATH without error" {
  run bash -c "echo '{}' | CAST_DB_PATH=/nonexistent/path/cast.db bash '$HOOK_SH'"
  assert_success
}

# ---------------------------------------------------------------------------
# 7. bash 3.2 compat: empty DIRTY_REPOS array does not trigger unbound variable
#    Regression for: `DIRTY_REPOS[@]: unbound variable` under set -u + bash 3.2
#    Fixed at: scripts/cast-precompact-guard.sh (dedup guard)
# ---------------------------------------------------------------------------
@test "PreCompact guard: bash 3.2 compat — exits 0 with no git repos in scope" {
  # Force /bin/bash which is bash 3.2 on macOS CI runners.
  # KNOWN_PROJECTS all miss (HOME is isolated temp dir), CAST_EXTRA_PROJECT unset,
  # so DIRTY_REPOS remains empty — this is the exact path that triggered the unbound
  # variable error before the fix.
  if [ ! -x /bin/bash ]; then
    skip "/bin/bash not available"
  fi
  run /bin/bash -c "echo '{}' | CAST_DB_PATH=/dev/null /bin/bash '$HOOK_SH'"
  assert_success
}

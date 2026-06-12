#!/usr/bin/env bats

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
BOOTSTRAP_SH="$REPO_DIR/scripts/cast-swarm-bootstrap.sh"
DB_INIT="$REPO_DIR/scripts/cast-db-init.sh"
VALID_CONFIG="$REPO_DIR/swarm-configs/fullstack-team.yml"

setup() {
  command -v python3 >/dev/null && python3 -c "import yaml" 2>/dev/null || skip "pyyaml not available"
  load 'helpers/setup'
  setup_temp_home
  # Resolve symlinks: on macOS /var/folders -> /private/var/folders
  HOME="$(realpath "$HOME")"; export HOME
  mkdir -p "$HOME/.claude/cast/swarms" "$HOME/.claude/logs"

  export TEST_DB="/tmp/test-cast-$$.db"
  export CAST_DB_PATH="$TEST_DB"
  bash "$DB_INIT" --db "$TEST_DB"

  # Isolated git repo so bootstrap's `git rev-parse --show-toplevel` resolves
  # here instead of the flagship checkout — prevents cast-swarm-* branch leak.
  export TEST_GIT_REPO="$(realpath "$(mktemp -d)")"
  git init "$TEST_GIT_REPO" --initial-branch=main >/dev/null 2>&1
  git -C "$TEST_GIT_REPO" config user.email "test@example.com"
  git -C "$TEST_GIT_REPO" config user.name "Test"
  git -C "$TEST_GIT_REPO" commit --allow-empty -m "init" >/dev/null 2>&1
  cd "$TEST_GIT_REPO"
}

teardown() {
  cd / 2>/dev/null || true
  rm -f "$TEST_DB"
  # Only remove the temp HOME if setup() actually created it (i.e., ORIG_HOME was set).
  # If setup() called skip before setting ORIG_HOME, HOME still points at the real user
  # home and rm -rf "$HOME" would destroy the live runtime (§3.8.A root cause).
  # Skip-before-setup leaves HOME at the real user home (§3.8.A root cause) —
  # only tear down a temp home setup() actually created; helper guards the deletion.
  if [ -n "${ORIG_HOME:-}" ] && [ "$HOME" != "$ORIG_HOME" ]; then
    teardown_temp_home
  fi
  # Clean up worktrees and temp git repo (TEST_GIT_REPO, not flagship).
  if [ -n "${TEST_GIT_REPO:-}" ]; then
    git -C "$TEST_GIT_REPO" worktree list --porcelain 2>/dev/null | grep "^worktree /tmp/cast-swarm-" | sed 's/^worktree //' | xargs -I{} git -C "$TEST_GIT_REPO" worktree remove --force {} 2>/dev/null || true
    rm -rf "$TEST_GIT_REPO"
  fi
  rm -rf /tmp/cast-swarm-* 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# bootstrap: exits 0 with valid config file
# ---------------------------------------------------------------------------

@test "cast-swarm-bootstrap: valid config → exit 0" {
  run bash "$BOOTSTRAP_SH" "$VALID_CONFIG" "Build a test feature"
  assert_success
}

# ---------------------------------------------------------------------------
# bootstrap: creates swarm_sessions row in cast.db
# ---------------------------------------------------------------------------

@test "cast-swarm-bootstrap: creates swarm_sessions row in cast.db" {
  bash "$BOOTSTRAP_SH" "$VALID_CONFIG" "Build a test feature" > /dev/null

  local count
  count=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM swarm_sessions;")
  [ "$count" -ge 1 ]
}

# ---------------------------------------------------------------------------
# bootstrap: prints JSON manifest to stdout
# ---------------------------------------------------------------------------

@test "cast-swarm-bootstrap: prints JSON manifest to stdout" {
  run bash "$BOOTSTRAP_SH" "$VALID_CONFIG" "Build a test feature"
  assert_success

  # Output must be valid JSON with required fields
  echo "$output" | python3 -c "
import json, sys
data = json.load(sys.stdin)
assert 'swarm_id' in data, 'missing swarm_id'
assert 'team_name' in data, 'missing team_name'
assert 'teammates' in data, 'missing teammates'
assert isinstance(data['teammates'], list), 'teammates must be a list'
print('ok')
"
}

# ---------------------------------------------------------------------------
# bootstrap: exits 1 for nonexistent config file
# ---------------------------------------------------------------------------

@test "cast-swarm-bootstrap: nonexistent config → exit 1" {
  run bash "$BOOTSTRAP_SH" "/tmp/no-such-config-$$.yml" "Some task"
  assert_failure 1
}

# ---------------------------------------------------------------------------
# bootstrap: exits 1 for invalid YAML
# ---------------------------------------------------------------------------

@test "cast-swarm-bootstrap: invalid YAML → exit 1" {
  local bad_config
  bad_config="$(mktemp /tmp/bad-config-XXXXXX.yml)"
  printf 'name: [unclosed bracket\nteammates: {\n' > "$bad_config"

  run bash "$BOOTSTRAP_SH" "$bad_config" "Some task"
  assert_failure 1

  rm -f "$bad_config"
}

# ---------------------------------------------------------------------------
# regression: no cast-swarm-* branches must leak into the flagship repo
# ---------------------------------------------------------------------------

@test "bootstrap tests leak no cast-swarm-* branches into the flagship repo" {
  # Snapshot existing flagship cast-swarm-* branches before running bootstrap.
  # Pre-existing branches (from prior leak runs) must not grow — the fix ensures
  # bootstrap uses TEST_GIT_REPO as its git root, not the flagship checkout.
  local before_branches
  before_branches="$(git -C "$REPO_DIR" branch --list 'cast-swarm-*')"

  run bash "$BOOTSTRAP_SH" "$VALID_CONFIG" "Isolation canary test"
  assert_success

  local after_branches
  after_branches="$(git -C "$REPO_DIR" branch --list 'cast-swarm-*')"
  assert_equal "$before_branches" "$after_branches"
}

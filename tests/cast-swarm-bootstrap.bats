#!/usr/bin/env bats

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
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

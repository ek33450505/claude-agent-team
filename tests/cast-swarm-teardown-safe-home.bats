#!/usr/bin/env bats
# Regression test for §3.8.A: swarm test teardown() must not rm -rf the real HOME
# when setup() calls skip before setting ORIG_HOME (e.g., pyyaml missing).
#
# Root cause: teardown() ran `rm -rf "$HOME"` without checking whether setup()
# had actually redirected HOME to a temp dir. When setup() called `skip` on the
# first line (pyyaml check), HOME still pointed at the real runtime (/root or
# the maintainer's $HOME) and teardown nuked it.
#
# This test verifies the guard: teardown must NOT delete the sentinel when
# ORIG_HOME is unset (i.e., setup never ran past the skip call).

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() {
  load 'helpers/setup'
  setup_temp_home
}

teardown() {
  teardown_temp_home
}

@test "teardown guard: ORIG_HOME unset → HOME is not deleted" {
  # Simulate the failure mode: create a sentinel in a fake "runtime" directory.
  FAKE_RUNTIME="$(mktemp -d)"
  mkdir -p "$FAKE_RUNTIME/.claude/scripts"
  touch "$FAKE_RUNTIME/.claude/scripts/__SENTINEL__"

  # Simulate: setup() skipped before setting ORIG_HOME, so ORIG_HOME is unset
  # and HOME still points at the runtime directory.
  (
    export HOME="$FAKE_RUNTIME"
    unset ORIG_HOME

    # Run the teardown logic extracted from cast-swarm-bootstrap.bats (the fixed version).
    # The guard condition: only rm -rf "$HOME" if ORIG_HOME is set AND HOME != ORIG_HOME.
    if [ -n "${ORIG_HOME:-}" ] && [ "$HOME" != "$ORIG_HOME" ]; then
      rm -rf "$HOME"
    fi
    # HOME must still be intact
    [ -f "$HOME/.claude/scripts/__SENTINEL__" ] || exit 1
  )
  status=$?

  rm -rf "$FAKE_RUNTIME"
  [ "$status" -eq 0 ]
}

@test "teardown guard: ORIG_HOME set and HOME differs → temp dir IS deleted" {
  # When setup() completed successfully: ORIG_HOME holds the real home, HOME
  # holds the temp dir. The temp dir should be cleaned up.
  REAL_HOME="$(mktemp -d)"
  TEMP_HOME="$(mktemp -d)"
  touch "$TEMP_HOME/temp_marker"

  (
    export ORIG_HOME="$REAL_HOME"
    export HOME="$TEMP_HOME"

    if [ -n "${ORIG_HOME:-}" ] && [ "$HOME" != "$ORIG_HOME" ]; then
      rm -rf "$HOME"
      export HOME="$ORIG_HOME"
    fi
    # temp dir must be gone; real home must survive
    [ ! -d "$TEMP_HOME" ] || exit 1
    [ -d "$REAL_HOME" ] || exit 1
  )
  status=$?

  rm -rf "$REAL_HOME" "$TEMP_HOME" 2>/dev/null || true
  [ "$status" -eq 0 ]
}

@test "teardown guard: HOME == ORIG_HOME → nothing deleted" {
  # Edge case: if HOME and ORIG_HOME are somehow equal, the guard prevents
  # deleting the real home directory.
  REAL_HOME="$(mktemp -d)"
  touch "$REAL_HOME/real_marker"

  (
    export ORIG_HOME="$REAL_HOME"
    export HOME="$REAL_HOME"

    if [ -n "${ORIG_HOME:-}" ] && [ "$HOME" != "$ORIG_HOME" ]; then
      rm -rf "$HOME"
    fi
    [ -f "$HOME/real_marker" ] || exit 1
  )
  status=$?

  rm -rf "$REAL_HOME"
  [ "$status" -eq 0 ]
}

@test "teardown guard: worktree safety — path outside /tmp/cast-swarm-* is REFUSED" {
  # Regression for the shutil.rmtree guard in cast-swarm-teardown.sh.
  # Creates a fake manifest with a dangerous worktree path and verifies
  # the script refuses to delete it.
  local dangerous_dir
  dangerous_dir="$(mktemp -d)"
  touch "$dangerous_dir/__MUST_SURVIVE__"

  # Craft a manifest with a worktree pointing at a dangerous path
  local swarm_id="test-guard-$$"
  local fake_home
  fake_home="$(mktemp -d)"
  mkdir -p "$fake_home/.claude/cast/swarms"
  local manifest_path="$fake_home/.claude/cast/swarms/${swarm_id}.json"

  python3 - <<PYEOF
import json
manifest = {
    "swarm_id": "${swarm_id}",
    "team_name": "test",
    "teammates": [
        {"role": "evil", "worktree": "${dangerous_dir}"}
    ]
}
with open("${manifest_path}", "w") as f:
    json.dump(manifest, f)
PYEOF

  # Run teardown with the dangerous manifest
  HOME="$fake_home" CAST_DB_PATH="/tmp/no-db-$$" \
    bash "$REPO_DIR/scripts/cast-swarm-teardown.sh" --force "$swarm_id" 2>/dev/null || true

  # The dangerous directory must NOT have been deleted
  local result=0
  [ -f "$dangerous_dir/__MUST_SURVIVE__" ] || result=1

  rm -rf "$fake_home" "$dangerous_dir"
  [ "$result" -eq 0 ]
}

@test "teardown guard: directory traversal via '..' in worktree path is REFUSED" {
  # Regression for §3.8.A directory-traversal flaw.
  # A path like /tmp/cast-swarm-x/../../<sentinel> satisfies the old regex
  # (starts with /tmp/cast-swarm-) but resolves outside the allowed root.
  # The new realpath-based guard must refuse it.
  local sentinel_dir
  sentinel_dir="$(mktemp -d)"
  touch "$sentinel_dir/__MUST_SURVIVE__"

  # Build traversal path: /tmp/cast-swarm-evil/../../../<sentinel_dir>
  # The number of ".." needed depends on /tmp depth; resolve dynamically.
  # Strip leading slash from sentinel_dir to build the traversal.
  # Instead: use a reliable construction — start from /tmp/cast-swarm-evil
  # and navigate up to / then back down into sentinel_dir.
  # Count components of sentinel_dir to build the right number of "..":
  local depth
  depth=$(echo "$sentinel_dir" | tr -cd '/' | wc -c | tr -d ' ')
  local dotdots=""
  for _ in $(seq 1 "$depth"); do
    dotdots="${dotdots}/.."
  done
  local traversal_path="/tmp/cast-swarm-evil${dotdots}${sentinel_dir}"

  local swarm_id="test-traversal-$$"
  local fake_home
  fake_home="$(mktemp -d)"
  mkdir -p "$fake_home/.claude/cast/swarms"
  local manifest_path="$fake_home/.claude/cast/swarms/${swarm_id}.json"

  python3 - <<PYEOF
import json
manifest = {
    "swarm_id": "${swarm_id}",
    "team_name": "test",
    "teammates": [
        {"role": "traversal-evil", "worktree": "${traversal_path}"}
    ]
}
with open("${manifest_path}", "w") as f:
    json.dump(manifest, f)
PYEOF

  # Run teardown — should refuse the traversal path
  HOME="$fake_home" CAST_DB_PATH="/tmp/no-db-traversal-$$" \
    bash "$REPO_DIR/scripts/cast-swarm-teardown.sh" --force "$swarm_id" 2>/dev/null || true

  # Sentinel must survive — traversal path must have been refused
  local result=0
  [ -f "$sentinel_dir/__MUST_SURVIVE__" ] || result=1

  rm -rf "$fake_home" "$sentinel_dir"
  [ "$result" -eq 0 ]
}

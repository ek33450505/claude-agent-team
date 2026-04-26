#!/usr/bin/env bats

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_DIR/scripts/cast-sync-check.sh"

setup() {
  # Create a fake repo tree with agents/core, agents/personal, scripts
  FAKE_REPO="$(mktemp -d)"
  mkdir -p "$FAKE_REPO/agents/core" "$FAKE_REPO/agents/personal" "$FAKE_REPO/scripts"

  # Create isolated runtime dirs (override via env vars)
  FAKE_RUNTIME_AGENTS="$(mktemp -d)"
  FAKE_RUNTIME_SCRIPTS="$(mktemp -d)"

  export CAST_RUNTIME_AGENTS="$FAKE_RUNTIME_AGENTS"
  export CAST_RUNTIME_SCRIPTS="$FAKE_RUNTIME_SCRIPTS"
  unset CLAUDE_SUBPROCESS
}

teardown() {
  rm -rf "$FAKE_REPO" "$FAKE_RUNTIME_AGENTS" "$FAKE_RUNTIME_SCRIPTS"
}

# Helper: run the script with FAKE_REPO as the repo root.
# We do this by creating a scripts/ subdir in FAKE_REPO and symlinking the real script there,
# so SCRIPT_DIR and REPO_ROOT resolve correctly.
_run_sync_check() {
  local args="${1:-}"
  # Place real script into fake repo so REPO_ROOT resolves correctly
  mkdir -p "$FAKE_REPO/scripts"
  ln -sf "$SCRIPT" "$FAKE_REPO/scripts/cast-sync-check.sh"
  run bash -c "CAST_RUNTIME_AGENTS='$CAST_RUNTIME_AGENTS' CAST_RUNTIME_SCRIPTS='$CAST_RUNTIME_SCRIPTS' bash '$FAKE_REPO/scripts/cast-sync-check.sh' $args"
}

@test "clean state: exit 0, no output" {
  # Source and runtime have identical content — no files in either
  _run_sync_check
  assert_success
  assert_output ""
}

@test "drift in agents/: exit 2, MISSING_IN_RUNTIME reported" {
  # Add a file to agents/core that is absent from the runtime agents dir
  echo "name: test-agent" > "$FAKE_REPO/agents/core/test-agent.md"
  _run_sync_check
  assert_failure 2
  assert_output --partial "MISSING_IN_RUNTIME: agents/core/test-agent.md"
}

@test "drift in scripts/: exit 2, CONTENT_DIFFERS reported" {
  # Add the same filename with different content to repo and runtime
  echo "version: repo" > "$FAKE_REPO/scripts/some-hook.sh"
  echo "version: runtime" > "$FAKE_RUNTIME_SCRIPTS/some-hook.sh"
  _run_sync_check
  assert_failure 2
  assert_output --partial "CONTENT_DIFFERS: scripts/some-hook.sh"
}

@test "effort:xhigh on non-opus model: WARNING printed, exit 0" {
  # Write an agent .md with effort: xhigh but model: sonnet
  cat > "$FAKE_REPO/agents/core/planner.md" <<'EOF'
---
name: planner
model: sonnet
effort: xhigh
---
EOF
  # Copy the same file to runtime so content doesn't drift (no CONTENT_DIFFERS)
  cp "$FAKE_REPO/agents/core/planner.md" "$FAKE_RUNTIME_AGENTS/planner.md"
  _run_sync_check
  assert_success
  assert_output --partial "WARNING: "
  assert_output --partial "effort:xhigh but model is 'sonnet'"
}

@test "--strict flag promotes warning to exit 2" {
  # Same setup as the WARNING test above
  cat > "$FAKE_REPO/agents/core/planner.md" <<'EOF'
---
name: planner
model: sonnet
effort: xhigh
---
EOF
  cp "$FAKE_REPO/agents/core/planner.md" "$FAKE_RUNTIME_AGENTS/planner.md"
  # Symlink then run with --strict
  mkdir -p "$FAKE_REPO/scripts"
  ln -sf "$SCRIPT" "$FAKE_REPO/scripts/cast-sync-check.sh"
  run bash -c "CAST_RUNTIME_AGENTS='$CAST_RUNTIME_AGENTS' CAST_RUNTIME_SCRIPTS='$CAST_RUNTIME_SCRIPTS' bash '$FAKE_REPO/scripts/cast-sync-check.sh' --strict"
  assert_failure 2
  assert_output --partial "WARNING: "
}

@test "CLAUDE_SUBPROCESS=1 short-circuits cleanly" {
  # Even with drift, subprocess guard should exit 0 immediately
  echo "version: repo" > "$FAKE_REPO/scripts/some-hook.sh"
  CLAUDE_SUBPROCESS=1 run bash "$SCRIPT"
  assert_success
  assert_output ""
}

@test "CAST_REPO_ROOT override: script uses env-var repo root, not script dir" {
  # Point CAST_REPO_ROOT at a temp dir with no agents/core — expect exit 0 (no drift, nothing to compare)
  local fake_repo
  fake_repo="$(mktemp -d)"
  mkdir -p "$fake_repo/agents/core" "$fake_repo/agents/personal" "$fake_repo/scripts"
  run env CAST_REPO_ROOT="$fake_repo" \
          CAST_RUNTIME_AGENTS="$(mktemp -d)" \
          CAST_RUNTIME_SCRIPTS="$(mktemp -d)" \
          bash "$REPO_DIR/scripts/cast-sync-check.sh"
  # No files in source dirs → no drift → exit 0
  assert_success
  rm -rf "$fake_repo"
}

@test "allow-list: runtime-only script is NOT flagged as MISSING_IN_REPO" {
  local fake_repo runtime_scripts
  fake_repo="$(mktemp -d)"
  runtime_scripts="$(mktemp -d)"
  mkdir -p "$fake_repo/agents/core" "$fake_repo/agents/personal" "$fake_repo/scripts"
  # Put an allow-listed filename in runtime scripts but NOT in repo scripts
  touch "$runtime_scripts/cast-session-start-journal.sh"
  run env CAST_REPO_ROOT="$fake_repo" \
          CAST_RUNTIME_AGENTS="$(mktemp -d)" \
          CAST_RUNTIME_SCRIPTS="$runtime_scripts" \
          bash "$REPO_DIR/scripts/cast-sync-check.sh"
  assert_success
  refute_output --partial "MISSING_IN_REPO"
  rm -rf "$fake_repo" "$runtime_scripts"
}

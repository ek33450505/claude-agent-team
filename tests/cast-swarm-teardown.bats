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
  if [ -n "${ORIG_HOME:-}" ] && [ "$HOME" != "$ORIG_HOME" ]; then
    rm -rf "$HOME"
    export HOME="$ORIG_HOME"
  fi
  # Clean up worktrees and temp git repo (TEST_GIT_REPO, not flagship).
  if [ -n "${TEST_GIT_REPO:-}" ]; then
    git -C "$TEST_GIT_REPO" worktree list --porcelain 2>/dev/null | grep "^worktree /tmp/cast-swarm-" | sed 's/^worktree //' | xargs -I{} git -C "$TEST_GIT_REPO" worktree remove --force {} 2>/dev/null || true
    rm -rf "$TEST_GIT_REPO"
  fi
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

# ---------------------------------------------------------------------------
# teardown: deletes associated cast-swarm-* branch after worktree removal
# ---------------------------------------------------------------------------

@test "cast-swarm-teardown: deletes cast-swarm-* branch after worktree removal" {
  # Use a temp isolated git repo so we never touch the live repo's branches
  local tmp_repo
  tmp_repo="$(mktemp -d /tmp/cast-swarm-teardown-brtest.XXXXXXXX)"

  git init "$tmp_repo" --initial-branch=main >/dev/null 2>&1
  git -C "$tmp_repo" config user.email "test@example.com"
  git -C "$tmp_repo" config user.name "Test"
  git -C "$tmp_repo" commit --allow-empty -m "init" >/dev/null 2>&1

  local swarm_id="test-br-$$"
  local role="backend"
  local branch_name="cast-swarm-${swarm_id}-${role}"

  # Create the branch that teardown should delete
  git -C "$tmp_repo" branch "$branch_name" >/dev/null 2>&1

  # Verify branch exists before teardown
  git -C "$tmp_repo" branch --list "$branch_name" | grep -q "$branch_name"

  # Build a minimal manifest pointing at tmp_repo as git_root
  local manifest_dir="$HOME/.claude/cast/swarms"
  mkdir -p "$manifest_dir"
  local manifest_file="$manifest_dir/${swarm_id}.json"
  cat > "$manifest_file" <<EOF
{
  "swarm_id": "${swarm_id}",
  "team_name": "test-team",
  "merge_strategy": "squash",
  "teammates": [
    {"role": "${role}", "branch": "${branch_name}", "worktree": null}
  ]
}
EOF

  # Run teardown with synthetic git_root pointing at our tmp repo.
  # We override GIT_ROOT by injecting it via a wrapper: teardown.sh derives
  # GIT_ROOT via `git rev-parse --show-toplevel`, so we run from inside tmp_repo.
  (cd "$tmp_repo" && CAST_DB_PATH="$TEST_DB" bash "$TEARDOWN_SH" --force "$swarm_id") > /dev/null 2>&1 || true

  # Branch must be gone after teardown — git branch --list returns nothing when branch is absent
  run git -C "$tmp_repo" branch --list "$branch_name"
  [ -z "$output" ]

  rm -rf "$tmp_repo"
}

# ---------------------------------------------------------------------------
# teardown: prefix guard — never deletes a non-cast-swarm-* branch
# ---------------------------------------------------------------------------

@test "cast-swarm-teardown: prefix guard prevents deletion of non-swarm branch" {
  local tmp_repo
  tmp_repo="$(mktemp -d /tmp/cast-swarm-teardown-guard.XXXXXXXX)"

  git init "$tmp_repo" --initial-branch=main >/dev/null 2>&1
  git -C "$tmp_repo" config user.email "test@example.com"
  git -C "$tmp_repo" config user.name "Test"
  git -C "$tmp_repo" commit --allow-empty -m "init" >/dev/null 2>&1

  local swarm_id="test-guard-$$"
  # Craft a manifest where role produces a branch name that does NOT start with cast-swarm-
  # (This is a defense-in-depth test — in practice bootstrap always produces cast-swarm-* names,
  # but the guard must hold regardless of manifest content.)
  local role="../../../../main"  # adversarial role value
  local branch_name="safe-branch-that-should-survive"
  git -C "$tmp_repo" branch "$branch_name" >/dev/null 2>&1

  local manifest_dir="$HOME/.claude/cast/swarms"
  mkdir -p "$manifest_dir"
  cat > "$manifest_dir/${swarm_id}.json" <<EOF
{
  "swarm_id": "${swarm_id}",
  "team_name": "test-guard",
  "merge_strategy": "squash",
  "teammates": [
    {"role": "${role}", "branch": "${branch_name}", "worktree": null}
  ]
}
EOF

  (cd "$tmp_repo" && CAST_DB_PATH="$TEST_DB" bash "$TEARDOWN_SH" --force "$swarm_id") > /dev/null 2>&1 || true

  # safe-branch-that-should-survive must still exist — the guard should have blocked its deletion
  run git -C "$tmp_repo" branch --list "$branch_name"
  assert_output --partial "$branch_name"

  rm -rf "$tmp_repo"
}

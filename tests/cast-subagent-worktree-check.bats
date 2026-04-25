#!/usr/bin/env bats
# Tests for scripts/cast-subagent-worktree-check.sh — SubagentStop worktree hook.
# Verifies detection, auto-cleanup of clean worktrees, escalation of dirty ones.

setup() {
  # Per-test isolated repo + cast.db
  TMPROOT="$(mktemp -d)"
  REPO="$TMPROOT/repo"
  mkdir -p "$REPO"
  git -C "$REPO" init -q
  git -C "$REPO" config user.email "test@cast"
  git -C "$REPO" config user.name "cast-test"
  echo "seed" > "$REPO/README.md"
  git -C "$REPO" add -A
  git -C "$REPO" commit -q -m "seed"
  git -C "$REPO" branch -M main

  export CAST_DB_PATH="$TMPROOT/test-cast.db"
  HOOK="$BATS_TEST_DIRNAME/../scripts/cast-subagent-worktree-check.sh"
  STDIN_JSON='{"agent_id":"test-agent-001"}'
}

teardown() {
  # Best-effort — worktrees may be locked
  rm -rf "$TMPROOT" 2>/dev/null || true
}

count_anomalies() {
  sqlite3 "$CAST_DB_PATH" "SELECT count(*) FROM worktree_anomalies;" 2>/dev/null || echo 0
}

@test "no agent worktree present → exits 0, no DB row" {
  cd "$REPO"
  run bash -c "echo '$STDIN_JSON' | bash '$HOOK'"
  [ "$status" -eq 0 ]
  [ "$(count_anomalies)" -eq 0 ]
}

@test "clean agent worktree → auto-removed, banner printed, DB row 'clean-removed'" {
  cd "$REPO"
  mkdir -p ".claude/worktrees"
  git worktree add -q ".claude/worktrees/agent-clean01" HEAD
  run bash -c "echo '$STDIN_JSON' | bash '$HOOK'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"AGENT-WORKTREE CLEANUP"* ]]
  [ ! -d ".claude/worktrees/agent-clean01" ]
  state="$(sqlite3 "$CAST_DB_PATH" "SELECT state FROM worktree_anomalies ORDER BY id DESC LIMIT 1;")"
  [ "$state" = "clean-removed" ]
}

@test "untracked-only worktree (build artifacts) → treated as clean and removed" {
  cd "$REPO"
  mkdir -p ".claude/worktrees"
  git worktree add -q ".claude/worktrees/agent-untracked01" HEAD
  mkdir -p ".claude/worktrees/agent-untracked01/node_modules" \
            ".claude/worktrees/agent-untracked01/dist"
  echo "junk" > ".claude/worktrees/agent-untracked01/dist/build.js"
  run bash -c "echo '$STDIN_JSON' | bash '$HOOK'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"AGENT-WORKTREE CLEANUP"* ]]
  state="$(sqlite3 "$CAST_DB_PATH" "SELECT state FROM worktree_anomalies ORDER BY id DESC LIMIT 1;")"
  [ "$state" = "clean-removed" ]
}

@test "dirty worktree (real modification) → escalated, preserved" {
  cd "$REPO"
  mkdir -p ".claude/worktrees"
  git worktree add -q ".claude/worktrees/agent-dirty01" HEAD
  echo "real change" >> ".claude/worktrees/agent-dirty01/README.md"
  run bash -c "echo '$STDIN_JSON' | bash '$HOOK'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"DIRTY"* ]]
  [ -d ".claude/worktrees/agent-dirty01" ]
  state="$(sqlite3 "$CAST_DB_PATH" "SELECT state FROM worktree_anomalies ORDER BY id DESC LIMIT 1;")"
  [ "$state" = "dirty-escalated" ]
}

@test "malformed stdin → exits 0 without crash" {
  cd "$REPO"
  run bash -c "echo 'not-json{' | bash '$HOOK'"
  [ "$status" -eq 0 ]
}

@test "CLAUDE_SUBPROCESS guard → exits 0 immediately, no DB write" {
  cd "$REPO"
  run bash -c "CLAUDE_SUBPROCESS=1 echo '$STDIN_JSON' | CLAUDE_SUBPROCESS=1 bash '$HOOK'"
  [ "$status" -eq 0 ]
  [ "$(count_anomalies)" -eq 0 ]
}

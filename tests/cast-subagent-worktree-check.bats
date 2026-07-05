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

@test "worktree-check: no longer invokes the 3 deleted sub-hooks" {
  # Pre-consolidation (Phase 5b block, lines 167-182), cast-subagent-worktree-check.sh
  # dispatched cast-agent-protocol-check.sh, cast-truncation-check.sh, and
  # cast-duration-check.sh. Their logic moved into cast_subagent_stop.py (stages 7, 4,
  # 13 respectively). Assert that none of those script names appear in the current
  # worktree-check script — a regression guard against fragment resurrection.
  local script="$BATS_TEST_DIRNAME/../scripts/cast-subagent-worktree-check.sh"
  # grep exits 1 when no match — proves none of the deleted hooks are referenced
  run grep -E "cast-agent-protocol-check|cast-truncation-check|cast-duration-check" "$script"
  [ "$status" -ne 0 ]
}

@test "non-anchored worktree path outside repo root is ignored" {
  # Create a separate fixture repo to simulate a worktree at a sibling path
  SIBLING="$TMPROOT/sibling"
  mkdir -p "$SIBLING"
  git -C "$SIBLING" init -q
  git -C "$SIBLING" config user.email "test@cast"
  git -C "$SIBLING" config user.name "cast-test"
  echo "seed" > "$SIBLING/README.md"
  git -C "$SIBLING" add -A
  git -C "$SIBLING" commit -q -m "seed"
  git -C "$SIBLING" branch -M main

  # Create a worktree that looks like it could match the substring
  # but is under the sibling repo, not our test repo
  mkdir -p "$SIBLING/.claude/worktrees"
  git -C "$SIBLING" worktree add -q "$SIBLING/.claude/worktrees/agent-fake" HEAD

  # Now run the hook on REPO — the regex should be anchored to REPO's root
  # and should NOT match or process the worktree in SIBLING
  cd "$REPO"
  run bash -c "echo '$STDIN_JSON' | bash '$HOOK'"
  [ "$status" -eq 0 ]
  # No anomalies should be recorded for our REPO (sibling's worktree should be ignored)
  [ "$(count_anomalies)" -eq 0 ]
}

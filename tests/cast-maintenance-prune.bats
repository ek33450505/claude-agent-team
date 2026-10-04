#!/usr/bin/env bats
# tests/cast-maintenance-prune.bats — Prune-scope assertions for cast-maintenance.sh
#
# Verifies the prune operations (and the absence of worktree prune):
#   §2  cast/events/  — files older than 30 days deleted; fresh files survive
#   §3  agent-status/ — files older than 24 h deleted; fresh files survive
#   §4  NO git worktree prune — symlink-victim regression + static guards on all callers
#
# File age is backdated via python3 os.utime (portable; avoids BSD-only date -v).
# Uses isolated temp HOME; never touches real ~/.claude or the live cast.db.

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_DIR/scripts/cast-maintenance.sh"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Backdate a file's atime+mtime by N seconds relative to now.
_backdate() {
  local path="$1"
  local age_secs="$2"
  python3 - "$path" "$age_secs" <<'PY'
import sys, os, time
path, age = sys.argv[1], int(sys.argv[2])
t = time.time() - age
os.utime(path, (t, t))
PY
}

_31_days=$((31 * 86400))
_25_hours=$((25 * 3600))
_1_hour=3600

# ---------------------------------------------------------------------------
# Setup / teardown
# ---------------------------------------------------------------------------

setup() {
  load 'helpers/setup'
  setup_temp_home

  # Required directory layout mirroring the live ~/.claude structure
  mkdir -p "$HOME/.claude/logs"
  mkdir -p "$HOME/.claude/cast/events"
  mkdir -p "$HOME/.claude/agent-status"

  export CAST_DB_PATH="$HOME/.claude/cast.db"

  # Provision schema so maintenance does not error on the agent_runs UPDATE
  bash "$REPO_DIR/scripts/cast-db-init.sh" --db "$CAST_DB_PATH" 2>/dev/null || true

  # Shim GUI/notification surfaces to avoid real side effects
  export PATH="$HOME/bin:$PATH"
  mkdir -p "$HOME/bin"
  for cmd in osascript terminal-notifier notify-send open; do
    printf '#!/bin/bash\nexit 0\n' > "$HOME/bin/$cmd"
    chmod +x "$HOME/bin/$cmd"
  done

  # Create a throwaway git repo at the path the maintenance script scans for
  # worktree prune (~/Projects/personal/claude-agent-team).  Under temp HOME,
  # ~ expands to HOME, so this is fully isolated from the real project repo.
  mkdir -p "$HOME/Projects/personal/claude-agent-team"
  git -C "$HOME/Projects/personal/claude-agent-team" init -q 2>/dev/null || true
}

teardown() {
  teardown_temp_home
}

# ---------------------------------------------------------------------------
# §2 — cast/events/ prune (>30 days)
# ---------------------------------------------------------------------------

@test "maintenance: events file older than 30 days is pruned" {
  local aged_file="$HOME/.claude/cast/events/old-event.json"
  echo '{"event":"test"}' > "$aged_file"
  _backdate "$aged_file" $_31_days

  run env CAST_SCRIPTS_DIR="$REPO_DIR/scripts" bash "$SCRIPT" 2>/dev/null
  assert_success

  [ ! -f "$aged_file" ] || {
    echo "FAIL: aged event file was not deleted by maintenance"
    return 1
  }
}

@test "maintenance: events file younger than 30 days survives" {
  local fresh_file="$HOME/.claude/cast/events/fresh-event.json"
  echo '{"event":"fresh"}' > "$fresh_file"
  # mtime is 'now' — do not backdate

  run env CAST_SCRIPTS_DIR="$REPO_DIR/scripts" bash "$SCRIPT" 2>/dev/null
  assert_success

  [ -f "$fresh_file" ] || {
    echo "FAIL: fresh event file was incorrectly deleted by maintenance"
    return 1
  }
}

@test "maintenance: jsonl.gz events file older than 30 days is pruned" {
  local aged_gz="$HOME/.claude/cast/events/old-archive.jsonl.gz"
  printf '\x1f\x8b' > "$aged_gz"   # minimal gz magic bytes; content irrelevant
  _backdate "$aged_gz" $_31_days

  run env CAST_SCRIPTS_DIR="$REPO_DIR/scripts" bash "$SCRIPT" 2>/dev/null
  assert_success

  [ ! -f "$aged_gz" ] || {
    echo "FAIL: aged .jsonl.gz event file was not deleted by maintenance"
    return 1
  }
}

# ---------------------------------------------------------------------------
# §3 — agent-status/ prune (>24 h, -mtime +0)
# ---------------------------------------------------------------------------

@test "maintenance: agent-status file older than 24 h is pruned" {
  local aged_status="$HOME/.claude/agent-status/old-agent.json"
  echo '{"status":"done"}' > "$aged_status"
  _backdate "$aged_status" $_25_hours

  run env CAST_SCRIPTS_DIR="$REPO_DIR/scripts" bash "$SCRIPT" 2>/dev/null
  assert_success

  [ ! -f "$aged_status" ] || {
    echo "FAIL: aged agent-status file was not deleted by maintenance"
    return 1
  }
}

@test "maintenance: agent-status file 1 h old (well within 24 h -mtime +0 threshold) survives" {
  local fresh_status="$HOME/.claude/agent-status/active-agent.json"
  echo '{"status":"running"}' > "$fresh_status"
  _backdate "$fresh_status" $_1_hour

  run env CAST_SCRIPTS_DIR="$REPO_DIR/scripts" bash "$SCRIPT" 2>/dev/null
  assert_success

  [ -f "$fresh_status" ] || {
    echo "FAIL: recent agent-status file was incorrectly deleted by maintenance"
    return 1
  }
}

# ---------------------------------------------------------------------------
# §4 — NO git worktree prune anywhere (symlinked .git/worktrees/<id> is followed
#      by prune and empties its target; CAST code must never run it)
# ---------------------------------------------------------------------------

@test "maintenance: a planted symlinked .git/worktrees/<id> is never followed (victim intact)" {
  # The throwaway repo at $HOME/Projects/personal/claude-agent-team was created in
  # setup(); `~` in the script expands to the temp HOME, so this is fully isolated.
  local repo="$HOME/Projects/personal/claude-agent-team"
  local victim="$BATS_TEST_TMPDIR/victim"
  mkdir -p "$victim" "$repo/.git/worktrees"
  printf 'precious\n' > "$victim/keep.txt"
  ln -s "$victim" "$repo/.git/worktrees/zz"
  run env CAST_SCRIPTS_DIR="$REPO_DIR/scripts" bash "$SCRIPT" 2>/dev/null
  assert_success
  [ -f "$victim/keep.txt" ]
  [ "$(cat "$victim/keep.txt")" = "precious" ]
  [ -L "$repo/.git/worktrees/zz" ]
}

# Static guard: no executable `git worktree prune` in CAST callers. It judges CODE only, with no
# phrase exclusions (a phrase like "never run" on a line must not hide a real prune). HEURISTIC, per line:
#   1. skip full-line comments;
#   2. strip "..." then '...' string contents (so message text naming the command is ignored);
#   3. strip a trailing ` # comment` (done AFTER quote-stripping so a `#` inside a string cannot
#      swallow real code after it, e.g. `echo "x #"; git worktree prune`);
#   4. flag if `worktree<ws>prune` remains.
# Limits: does not track multi-line strings or heredocs. Prints flagged lines; returns 0 if any.
_exec_prune_lines() {
  local f="$1" dq='"[^"]*"' sq="'[^']*'"
  grep -vE '^[[:space:]]*#' "$f" \
    | sed -E "s/${dq}//g; s/${sq}//g; s/[[:space:]]#.*\$//" \
    | grep -E 'worktree[[:space:]]+prune'
}

_no_exec_prune() {
  local f="$REPO_DIR/$1"
  [ -f "$f" ] || { echo "missing: $f" >&2; return 1; }
  if _exec_prune_lines "$f"; then
    return 1
  fi
  return 0
}

@test "static helper self-test: flags code, ignores comments and quoted text" {
  local fx="$BATS_TEST_TMPDIR/helper-fixture.sh"
  # Four fixture lines, one per case; `git worktree prune # never run` and the
  # extra-space form must flag; the quoted message and the comment must not.
  {
    printf '%s\n' 'git worktree prune # never run'
    printf '%s\n' '  git -C "$r" worktree   prune'
    printf '%s\n' 'echo "never run git worktree prune"'
    printf '%s\n' '# git worktree prune'
    printf '%s\n' 'echo "x #"; git worktree prune'
  } > "$fx"
  run _exec_prune_lines "$fx"
  assert_success
  [ "${#lines[@]}" -eq 3 ]
  [ "${lines[0]}" = "git worktree prune" ]
  [[ "${lines[1]}" == *'worktree   prune'* ]]
  [[ "${lines[2]}" == *'; git worktree prune' ]]
  # The two non-code lines must not appear.
  ! printf '%s\n' "$output" | grep -qF 'never run git worktree prune'
  ! printf '%s\n' "$output" | grep -qE '^# git'
}

@test "static: scripts/cast-maintenance.sh has no executable worktree prune" {
  _no_exec_prune scripts/cast-maintenance.sh
}

@test "static: .githooks/pre-push has no executable worktree prune" {
  _no_exec_prune .githooks/pre-push
}

@test "static: scripts/cast-parallel.sh has no executable worktree prune" {
  _no_exec_prune scripts/cast-parallel.sh
}

@test "static: bin/cast has no executable worktree prune" {
  _no_exec_prune bin/cast
}

# ---------------------------------------------------------------------------
# §5 — `cast tidy` step 8 is report-only; its rm advice must be inert when pasted
# ---------------------------------------------------------------------------

@test "cast tidy: SUSPICIOUS rm advice is shell-quoted (hostile entry name cannot inject)" {
  local repo="$BATS_TEST_TMPDIR/repo" victim="$BATS_TEST_TMPDIR/victim" work="$BATS_TEST_TMPDIR/work"
  mkdir -p "$repo/.git/worktrees" "$victim" "$work"
  printf 'precious\n' > "$victim/keep.txt"
  local name="x;touch PWNED"   # no "/" allowed in an entry name; cwd = $work
  ln -s "$victim" "$repo/.git/worktrees/$name"

  run env CAST_REPO_DIR="$repo" bash "$REPO_DIR/bin/cast" tidy
  assert_success
  assert_output --partial "SUSPICIOUS symlinked worktree registry entry"
  [ -f "$victim/keep.txt" ]
  [ -L "$repo/.git/worktrees/$name" ]

  # Extract the advised command (text between "with: " and " (no -r)").
  local advice="${output#*remove the symlink with: }"
  advice="${advice%% (no -r)*}"
  [[ "$advice" == "rm -- "* ]]
  [[ "$advice" == *'\;'* || "$advice" == *"'"* ]]

  # Control: the OLD unquoted form injects `touch PWNED` (proves the fixture bites).
  rm -f "$work/PWNED"
  (cd "$work" && eval "rm $repo/.git/worktrees/$name" 2>/dev/null) || true
  [ -e "$work/PWNED" ]
  rm -f "$work/PWNED"
  ln -s "$victim" "$repo/.git/worktrees/$name" 2>/dev/null || true

  # The advised (quoted) command removes only the symlink and injects nothing.
  (cd "$work" && eval "$advice")
  [ ! -e "$work/PWNED" ]
  [ ! -L "$repo/.git/worktrees/$name" ]
  [ -f "$victim/keep.txt" ]
}

@test "cast tidy: stale line does not claim safe-to-remove or suggest prune as a fix" {
  local repo="$BATS_TEST_TMPDIR/repo2"
  mkdir -p "$repo/.git/worktrees/gone"
  printf '%s\n' "$BATS_TEST_TMPDIR/nonexistent" > "$repo/.git/worktrees/gone/gitdir"
  run env CAST_REPO_DIR="$repo" bash "$REPO_DIR/bin/cast" tidy
  assert_success
  assert_output --partial "stale: gone — gitdir points to a missing path; inspect before removing (never run git worktree prune)"
  refute_output --partial "safe to remove"
}

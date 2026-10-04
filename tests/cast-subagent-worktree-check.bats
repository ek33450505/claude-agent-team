#!/usr/bin/env bats
# Tests for scripts/cast-subagent-worktree-check.sh — SubagentStop worktree hook.
# The hook is DETECT-ONLY: it reports clean/dirty agent worktrees and must never delete, prune or
# move anything, and every git call must go through the hardened cast_git_safe wrapper.

make_repo() {
  local dir="$1"
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" config user.email "test@example.com"
  git -C "$dir" config user.name "cast-test"
  echo "seed" > "$dir/README.md"
  git -C "$dir" add -A
  git -C "$dir" commit -q -m "seed"
  git -C "$dir" branch -M main
}

# Repo-local core.fsmonitor that drops a marker file when git runs it: proves whether git ran
# unhardened in $1 (marker path in $2).
plant_fsmonitor() {
  local repo="$1" marker="$2"
  printf '#!/bin/sh\ntouch "%s"\nexit 0\n' "$marker" > "$BATS_TEST_TMPDIR/fsm.sh"
  chmod +x "$BATS_TEST_TMPDIR/fsm.sh"
  git -C "$repo" config core.fsmonitor "$BATS_TEST_TMPDIR/fsm.sh"
}

setup() {
  # Isolated HOME (the hook logs under $HOME/.claude/logs) + everything under BATS_TEST_TMPDIR
  # (bats removes it; the sandbox's macOS mktemp ignores TMPDIR).
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  TMPROOT="$BATS_TEST_TMPDIR"
  REPO="$TMPROOT/repo"
  make_repo "$REPO"

  export CAST_DB_PATH="$TMPROOT/test-cast.db"
  HOOK="$BATS_TEST_DIRNAME/../scripts/cast-subagent-worktree-check.sh"
  STDIN_JSON='{"agent_id":"test-agent-001"}'
}

count_anomalies() {
  sqlite3 "$CAST_DB_PATH" "SELECT count(*) FROM worktree_anomalies;" 2>/dev/null || echo 0
}

last_state() {
  sqlite3 "$CAST_DB_PATH" "SELECT state FROM worktree_anomalies ORDER BY id DESC LIMIT 1;"
}

@test "no agent worktree present → exits 0, no DB row" {
  cd "$REPO"
  run bash -c "echo '$STDIN_JSON' | bash '$HOOK'"
  [ "$status" -eq 0 ]
  [ "$(count_anomalies)" -eq 0 ]
}

@test "clean agent worktree → detected only, preserved, banner names 'cast clean', DB row 'clean-detected'" {
  cd "$REPO"
  mkdir -p ".claude/worktrees"
  git worktree add -q ".claude/worktrees/agent-clean01" HEAD
  run bash -c "echo '$STDIN_JSON' | bash '$HOOK'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"AGENT-WORKTREE LEFT BEHIND (clean)"* ]]
  [[ "$output" == *"cast clean --apply --worktrees"* ]]
  [ -d ".claude/worktrees/agent-clean01" ]
  [ "$(last_state)" = "clean-detected" ]
  # still a registered worktree: nothing pruned or removed
  run git worktree list --porcelain
  [[ "$output" == *"agent-clean01"* ]]
}

@test "untracked-only worktree → untracked files count as dirty: escalated and preserved" {
  cd "$REPO"
  mkdir -p ".claude/worktrees"
  git worktree add -q ".claude/worktrees/agent-untracked01" HEAD
  mkdir -p ".claude/worktrees/agent-untracked01/node_modules" \
            ".claude/worktrees/agent-untracked01/dist"
  echo "junk" > ".claude/worktrees/agent-untracked01/dist/build.js"
  run bash -c "echo '$STDIN_JSON' | bash '$HOOK'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"DIRTY"* ]]
  [ -f ".claude/worktrees/agent-untracked01/dist/build.js" ]
  [ "$(last_state)" = "dirty-escalated" ]
  reason="$(sqlite3 "$CAST_DB_PATH" "SELECT reason FROM worktree_anomalies ORDER BY id DESC LIMIT 1;")"
  [[ "$reason" == *"changed/untracked"* ]]
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
  [ "$(last_state)" = "dirty-escalated" ]
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
  make_repo "$SIBLING"

  # Create a worktree that looks like it could match the substring
  # but is under the sibling repo, not our test repo
  mkdir -p "$SIBLING/.claude/worktrees"
  git -C "$SIBLING" worktree add -q "$SIBLING/.claude/worktrees/agent-fake" HEAD

  # Now run the hook on REPO — the prefix match is anchored to REPO's root
  # and should NOT match or process the worktree in SIBLING
  cd "$REPO"
  run bash -c "echo '$STDIN_JSON' | bash '$HOOK'"
  [ "$status" -eq 0 ]
  # No anomalies should be recorded for our REPO (sibling's worktree should be ignored)
  [ "$(count_anomalies)" -eq 0 ]
}

@test "C1: planted .git/worktrees/<id> symlink → victim dir is NOT emptied (hook never prunes)" {
  mkdir -p "$TMPROOT/victim/nested/deeper"
  echo "precious" > "$TMPROOT/victim/keep.txt"
  echo "precious" > "$TMPROOT/victim/nested/deeper/keep2.txt"
  mkdir -p "$REPO/.git/worktrees"
  ln -s "$TMPROOT/victim" "$REPO/.git/worktrees/zz"
  cd "$REPO"
  mkdir -p ".claude/worktrees"
  git worktree add -q ".claude/worktrees/agent-clean01" HEAD
  # the planted symlink survived `worktree add`
  [ -L "$REPO/.git/worktrees/zz" ]
  run bash -c "echo '$STDIN_JSON' | bash '$HOOK'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"LEFT BEHIND (clean)"* ]]   # the scan really ran
  [ -f "$TMPROOT/victim/keep.txt" ]
  [ -f "$TMPROOT/victim/nested/deeper/keep2.txt" ]
}

@test "C1 control: plain 'git worktree prune' DOES empty the symlink victim (fixture is real)" {
  local repo2="$TMPROOT/repo2"
  make_repo "$repo2"
  mkdir -p "$TMPROOT/victim2/nested"
  echo "precious" > "$TMPROOT/victim2/keep.txt"
  echo "precious" > "$TMPROOT/victim2/nested/keep2.txt"
  mkdir -p "$repo2/.git/worktrees"
  ln -s "$TMPROOT/victim2" "$repo2/.git/worktrees/zz"
  git -C "$repo2" worktree prune
  [ ! -e "$TMPROOT/victim2/keep.txt" ]
  [ ! -e "$TMPROOT/victim2/nested/keep2.txt" ]
}

@test "exec canary: repo-local core.fsmonitor is NOT executed by the hook (hardened git)" {
  cd "$REPO"
  mkdir -p ".claude/worktrees"
  git worktree add -q ".claude/worktrees/agent-clean01" HEAD
  plant_fsmonitor "$REPO" "$TMPROOT/fsm-marker"
  # control: plain git in the worktree runs the planted fsmonitor
  rm -f "$TMPROOT/fsm-marker"
  git -C "$REPO/.claude/worktrees/agent-clean01" status >/dev/null 2>&1 || true
  [ -f "$TMPROOT/fsm-marker" ]
  # hook run: marker must stay absent, yet the scan must have happened
  rm -f "$TMPROOT/fsm-marker"
  run bash -c "echo '$STDIN_JSON' | bash '$HOOK'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"LEFT BEHIND (clean)"* ]]
  [ ! -e "$TMPROOT/fsm-marker" ]
}

@test "locked agent worktree → not reported as clean, preserved" {
  cd "$REPO"
  mkdir -p ".claude/worktrees"
  git worktree add -q ".claude/worktrees/agent-locked01" HEAD
  git worktree lock ".claude/worktrees/agent-locked01"
  run bash -c "echo '$STDIN_JSON' | bash '$HOOK'"
  [ "$status" -eq 0 ]
  [[ "$output" != *"LEFT BEHIND (clean)"* ]]
  [ -d ".claude/worktrees/agent-locked01" ]
  [ "$(sqlite3 "$CAST_DB_PATH" "SELECT count(*) FROM worktree_anomalies WHERE state='clean-detected';")" -eq 0 ]
  run git worktree list --porcelain
  [[ "$output" == *"agent-locked01"* ]]
}

@test "control chars (newline, ESC) in the worktree path never reach the banner raw" {
  cd "$REPO"
  mkdir -p ".claude/worktrees"
  local name
  name=$'agent-nl\nINJECTED-LINE\e[31mred'
  git worktree add -q ".claude/worktrees/$name" HEAD
  run bash -c "echo '$STDIN_JSON' | bash '$HOOK'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"LEFT BEHIND (clean)"* ]]
  [[ "$output" != *$'\e'* ]]
  # exactly one banner line: the embedded newline was neutralised
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -eq 1 ]
  [[ "$output" == *"agent-nl?INJECTED-LINE?[31mred"* ]]
}

@test "lib missing → exits 0, no git is run (fsmonitor canary absent), scan failure logged" {
  cd "$REPO"
  mkdir -p ".claude/worktrees"
  git worktree add -q ".claude/worktrees/agent-clean01" HEAD
  plant_fsmonitor "$REPO" "$TMPROOT/fsm-marker"
  rm -f "$TMPROOT/fsm-marker"
  mkdir -p "$TMPROOT/s"
  cp "$HOOK" "$TMPROOT/s/hook.sh"
  cp "$BATS_TEST_DIRNAME/../scripts/cast_git_safe.py" "$TMPROOT/s/"
  run bash -c "echo '$STDIN_JSON' | bash '$TMPROOT/s/hook.sh'"
  [ "$status" -eq 0 ]
  [ ! -e "$TMPROOT/fsm-marker" ]
  [ "$(count_anomalies)" -eq 0 ]
  grep -q "worktree scan failed" "$HOME/.claude/logs/hook-errors.log"
}

@test "python wrapper missing → exits 0, scan skipped, nothing recorded" {
  cd "$REPO"
  mkdir -p ".claude/worktrees"
  git worktree add -q ".claude/worktrees/agent-clean01" HEAD
  mkdir -p "$TMPROOT/s"
  cp "$HOOK" "$TMPROOT/s/hook.sh"
  cp "$BATS_TEST_DIRNAME/../scripts/cast-hook-lib.sh" "$TMPROOT/s/"
  run bash -c "echo '$STDIN_JSON' | bash '$TMPROOT/s/hook.sh'"
  [ "$status" -eq 0 ]
  [ "$(count_anomalies)" -eq 0 ]
  [ -d ".claude/worktrees/agent-clean01" ]
  grep -q "worktree scan failed" "$HOME/.claude/logs/hook-errors.log"
}

@test "DB row: ESC/newline/U+202E in the worktree path are escaped, not stored raw, and capped" {
  cd "$REPO"
  mkdir -p ".claude/worktrees"
  local name
  name=$'agent-db\nL2\e[31m\xe2\x80\xaeend'
  git worktree add -q ".claude/worktrees/$name" HEAD
  run bash -c "echo '$STDIN_JSON' | bash '$HOOK'"
  [ "$status" -eq 0 ]
  [ "$(count_anomalies)" -eq 1 ]
  # every stored char is printable ASCII (the U+202E and the controls were escaped)
  [ "$(sqlite3 "$CAST_DB_PATH" "SELECT count(*) FROM worktree_anomalies WHERE worktree_path GLOB '*[^ -~]*';")" -eq 0 ]
  p="$(sqlite3 "$CAST_DB_PATH" "SELECT worktree_path FROM worktree_anomalies;")"
  [[ "$p" == *'agent-db\nL2\x1b[31m\u202eend'* ]]
  [ "$(sqlite3 "$CAST_DB_PATH" "SELECT max(length(worktree_path)) FROM worktree_anomalies;")" -le 1024 ]
}

@test "DB row: a 200k-char agent_id is stored capped with a truncation marker" {
  cd "$REPO"
  mkdir -p ".claude/worktrees"
  git worktree add -q ".claude/worktrees/agent-clean01" HEAD
  { printf '{"agent_id":"'; head -c 200000 /dev/zero | tr '\0' 'A'; printf '"}'; } > "$TMPROOT/big.json"
  run bash "$HOOK" < "$TMPROOT/big.json"
  [ "$status" -eq 0 ]
  [ "$(count_anomalies)" -eq 1 ]
  [ "$(sqlite3 "$CAST_DB_PATH" "SELECT length(agent_id) FROM worktree_anomalies;")" -le 1024 ]
  [[ "$(sqlite3 "$CAST_DB_PATH" "SELECT agent_id FROM worktree_anomalies;")" == *'…[+'*']' ]]
  # banner agent id is capped at 100
  [ "${#output}" -lt 600 ]
}

@test "non-string agent_id → recorded as 'unknown'" {
  cd "$REPO"
  mkdir -p ".claude/worktrees"
  git worktree add -q ".claude/worktrees/agent-clean01" HEAD
  run bash -c "echo '{\"agent_id\":{\"x\":1}}' | bash '$HOOK'"
  [ "$status" -eq 0 ]
  [ "$(sqlite3 "$CAST_DB_PATH" "SELECT agent_id FROM worktree_anomalies;")" = "unknown" ]
}

@test "banner: bidi override (U+202E) and line separator (U+2028) become '?'" {
  cd "$REPO"
  mkdir -p ".claude/worktrees"
  local name
  name=$'agent-a\xe2\x80\xaeb\xe2\x80\xa8c'
  git worktree add -q ".claude/worktrees/$name" HEAD
  run bash -c "echo '$STDIN_JSON' | bash '$HOOK'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"LEFT BEHIND (clean)"* ]]
  [[ "$output" == *"agent-a?b?c"* ]]
  [[ "$output" != *$'\xe2\x80\xae'* ]]
  [[ "$output" != *$'\xe2\x80\xa8'* ]]
}

@test "registry path escaping via agent-/../../x is skipped (no row, no scan of x)" {
  cd "$REPO"
  mkdir -p ".claude/worktrees" "$REPO/x"
  git worktree add -q ".claude/worktrees/agent-real" HEAD
  printf '%s\n' "$REPO/.claude/worktrees/agent-/../../x/.git" > "$REPO/.git/worktrees/agent-real/gitdir"
  # control: git really reports the traversal path (so the filter, not git, is what skips it)
  run git worktree list --porcelain
  [[ "$output" == *"agent-/../../x"* ]]
  run bash -c "echo '$STDIN_JSON' | bash '$HOOK'"
  [ "$status" -eq 0 ]
  [ "$(count_anomalies)" -eq 0 ]
  [[ "$output" != *"AGENT-WORKTREE"* ]]
}

@test "FIFO planted at .git/config → hook still exits 0 within its deadline" {
  cd "$REPO"
  mkdir -p ".claude/worktrees"
  git worktree add -q ".claude/worktrees/agent-clean01" HEAD
  rm -f "$REPO/.git/config"
  mkfifo "$REPO/.git/config"
  start=$SECONDS
  # perl alarm = portable `timeout 15` (SIGALRM -> status 142; 124 for coreutils timeout)
  # Output goes to a file, not `run`'s pipe: on a regression an orphaned git blocked on the FIFO
  # would otherwise hold that pipe open and hang bats instead of failing the test.
  rc=0
  perl -e 'alarm 15; exec @ARGV' bash -c "echo '$STDIN_JSON' | bash '$HOOK'" \
    > "$TMPROOT/fifo.out" 2>&1 3>&- 4>&- || rc=$?
  elapsed=$((SECONDS - start))
  [ "$rc" -ne 124 ]
  [ "$rc" -ne 142 ]
  [ "$rc" -eq 0 ]
  [ "$elapsed" -lt 14 ]
}

#!/usr/bin/env bats

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
HOOK_SH="$REPO_DIR/scripts/cast-precompact-guard.sh"

setup() {
  load 'helpers/setup'
  export ORIG_CAST_DB_PATH="${CAST_DB_PATH:-}"
  # Isolated temp HOME so the hardcoded KNOWN_PROJECTS in $HOME/Projects/... miss real repos
  setup_temp_home
  mkdir -p "$HOME/.claude/logs"
  unset CLAUDE_SUBPROCESS
  unset CAST_EXTRA_PROJECT
}

teardown() {
  [ -n "${TEMP_GIT_REPO:-}" ] && rm -rf "$TEMP_GIT_REPO"
  teardown_temp_home
  if [ -n "$ORIG_CAST_DB_PATH" ]; then
    export CAST_DB_PATH="$ORIG_CAST_DB_PATH"
  else
    unset CAST_DB_PATH
  fi
}

# ---------------------------------------------------------------------------
# 0. SECURITY (2026-10-03): hostile repo-local config must not execute during the dirty
#    check. The hook runs OUTSIDE the Bash sandbox over agent-writable project roots.
#    Marker-file tests: planted fsmonitor / clean filter / process filter (dotted+mixed-case
#    driver name included) must NOT run, and dirty detection must still be correct.
# ---------------------------------------------------------------------------
_pc_marker_script() { # name [body]
  printf '#!/bin/sh\ntouch "%s/fired-%s"\n%s\n' "$PC_MARK" "$1" "${2:-exit 0}" > "$PC_MARK/$1.sh"
  chmod +x "$PC_MARK/$1.sh"
}
_pc_fired() { find "$PC_MARK" -name 'fired-*' | wc -l | tr -d ' '; }
_pc_hostile_repo() {
  PC_MARK="$BATS_TEST_TMPDIR/markers"
  PC_REPO="$BATS_TEST_TMPDIR/hostile"
  mkdir -p "$PC_MARK" "$PC_REPO"
  _pc_marker_script filter cat
  _pc_marker_script process
  _pc_marker_script fsmonitor
  _pc_marker_script eqfilter cat
  git init -q --initial-branch=main "$PC_REPO"
  git -C "$PC_REPO" config user.email "test@example.com"
  git -C "$PC_REPO" config user.name "Test"
  printf 'a.txt filter=x\nb.txt filter=Y.z\nc.txt filter=a=b\n' > "$PC_REPO/.gitattributes"
  echo eq > "$PC_REPO/c.txt"
  echo hello > "$PC_REPO/a.txt"
  echo world > "$PC_REPO/b.txt"
  touch -t 202001010000 "$PC_REPO/.gitattributes" "$PC_REPO/a.txt" "$PC_REPO/b.txt" "$PC_REPO/c.txt"
  git -C "$PC_REPO" add -A
  git -C "$PC_REPO" commit -q -m init
  # hostile config planted AFTER the base commit
  git -C "$PC_REPO" config filter.x.clean "$PC_MARK/filter.sh"
  git -C "$PC_REPO" config filter.Y.z.process "$PC_MARK/process.sh"
  git -C "$PC_REPO" config filter.Y.z.required true
  git -C "$PC_REPO" config core.fsmonitor "$PC_MARK/fsmonitor.sh"
  git -C "$PC_REPO" config "filter.a=b.clean" "$PC_MARK/eqfilter.sh"
}
_pc_run_hook() {
  run bash -c "echo '{}' | CAST_EXTRA_PROJECT='$PC_REPO' CAST_DB_PATH=/dev/null bash '$HOOK_SH'"
}

@test "PreCompact guard hostile repo: filter driver name containing '=' is blanked (no planted program runs)" {
  _pc_hostile_repo
  touch "$PC_REPO/c.txt"
  git -C "$PC_REPO" status --porcelain >/dev/null 2>&1 || true
  [ -e "$PC_MARK/fired-eqfilter" ] # control
  rm -f "$PC_MARK"/fired-*
  touch -t 202201010000 "$PC_REPO/c.txt" # control refreshed the index; re-dirty
  _pc_run_hook
  assert_success
  assert_output --partial '"decision":"allow"'
  [ "$(_pc_fired)" = "0" ]
}

@test "PreCompact guard hostile repo: submodule-local clean filter on a stat-dirty file does not run" {
  PC_MARK="$BATS_TEST_TMPDIR/markers"
  PC_REPO="$BATS_TEST_TMPDIR/par"
  mkdir -p "$PC_MARK" "$BATS_TEST_TMPDIR/subsrc"
  _pc_marker_script subfilter cat
  git init -q --initial-branch=main "$BATS_TEST_TMPDIR/subsrc"
  git -C "$BATS_TEST_TMPDIR/subsrc" config user.email t@t
  git -C "$BATS_TEST_TMPDIR/subsrc" config user.name t
  printf '* filter=sf\n' > "$BATS_TEST_TMPDIR/subsrc/.gitattributes"
  echo f > "$BATS_TEST_TMPDIR/subsrc/f.txt"
  git -C "$BATS_TEST_TMPDIR/subsrc" add -A
  git -C "$BATS_TEST_TMPDIR/subsrc" commit -q -m i
  git init -q --initial-branch=main "$PC_REPO"
  git -C "$PC_REPO" config user.email t@t
  git -C "$PC_REPO" config user.name t
  git -C "$PC_REPO" -c protocol.file.allow=always submodule add -q "$BATS_TEST_TMPDIR/subsrc" sub >/dev/null 2>&1
  git -C "$PC_REPO" commit -q -m i
  git -C "$PC_REPO/sub" config filter.sf.clean "$PC_MARK/subfilter.sh"
  touch -t 202101010000 "$PC_REPO/sub/f.txt" # stat-dirty inside the submodule
  git -C "$PC_REPO" status --porcelain >/dev/null 2>&1 || true
  [ -e "$PC_MARK/fired-subfilter" ] # control
  rm -f "$PC_MARK"/fired-*
  touch -t 202201010000 "$PC_REPO/sub/f.txt"
  _pc_run_hook
  assert_success
  [ "$(_pc_fired)" = "0" ]
}

@test "PreCompact guard hostile repo: inherited GIT_CONFIG_PARAMETERS fsmonitor does not run" {
  PC_MARK="$BATS_TEST_TMPDIR/markers"
  PC_REPO="$BATS_TEST_TMPDIR/plain"
  mkdir -p "$PC_MARK" "$PC_REPO"
  _pc_marker_script fsmonitor
  git init -q --initial-branch=main "$PC_REPO"
  git -C "$PC_REPO" config user.email t@t
  git -C "$PC_REPO" config user.name t
  echo x > "$PC_REPO/a.txt"
  git -C "$PC_REPO" add -A
  git -C "$PC_REPO" commit -q -m i
  export GIT_CONFIG_PARAMETERS="'core.fsmonitor=$PC_MARK/fsmonitor.sh'"
  git -C "$PC_REPO" status --porcelain >/dev/null 2>&1 || true
  [ -e "$PC_MARK/fired-fsmonitor" ] # control: env-injected fsmonitor fires on raw git
  rm -f "$PC_MARK"/fired-*
  _pc_run_hook
  assert_success
  assert_output --partial '"decision":"allow"'
  [ "$(_pc_fired)" = "0" ]
}

@test "PreCompact guard hostile repo: stat-dirty-only repo is allowed and no planted program runs" {
  _pc_hostile_repo
  touch "$PC_REPO/a.txt" "$PC_REPO/b.txt" # stat-dirty, content identical
  # Control: raw porcelain status DOES execute the planted programs (fixture is hostile)
  git -C "$PC_REPO" status --porcelain >/dev/null 2>&1 || true
  [ -e "$PC_MARK/fired-fsmonitor" ]
  [ -e "$PC_MARK/fired-filter" ]
  [ -e "$PC_MARK/fired-process" ]
  rm -f "$PC_MARK"/fired-*
  touch -t 202201010000 "$PC_REPO/a.txt" "$PC_REPO/b.txt"
  _pc_run_hook
  assert_success
  assert_output --partial '"decision":"allow"'
  [ "$(_pc_fired)" = "0" ]
}

@test "PreCompact guard hostile repo: modified tracked file is still detected and no planted program runs" {
  _pc_hostile_repo
  echo changed >> "$PC_REPO/a.txt"
  touch "$PC_REPO/b.txt"
  _pc_run_hook
  assert_success
  assert_output --regexp '"decision":[[:space:]]*"block"'
  assert_output --partial "$PC_REPO"
  [ "$(_pc_fired)" = "0" ]
}

@test "PreCompact guard hostile repo: untracked file is still detected and no planted program runs" {
  _pc_hostile_repo
  echo new > "$PC_REPO/new.txt"
  _pc_run_hook
  assert_success
  assert_output --regexp '"decision":[[:space:]]*"block"'
  assert_output --partial "$PC_REPO"
  [ "$(_pc_fired)" = "0" ]
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
    git config user.email "test@example.com"
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
    git config user.email "test@example.com"
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
  # S3a-U1b: a dirty-only reason is byte-for-byte the original (json.dumps shape + message, nothing appended)
  assert_output "{\"decision\": \"block\", \"reason\": \"Uncommitted changes in: $dirty_repo. Commit before compacting (use commit agent).\"}"
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

# ---------------------------------------------------------------------------
# 8. ISO-T/Z vs space-form regression: sessions.started_at raw compare bug
#    (raw `started_at > datetime('now','-1 day')` string-compared a stored
#    ISO-T/Z timestamp against sqlite's space-separated datetime('now',...)
#    form; 'T' (0x54) > ' ' (0x20) lexically, so a session at/before the
#    cutoff instant was falsely treated as "within the last day" and its
#    repo got swept into the dirty-check. Fixed by wrapping the column in
#    datetime().)
# ---------------------------------------------------------------------------
@test "PreCompact guard: sessions row at the ISO-T/space cutoff instant is NOT falsely swept in" {
  local dirty_repo test_db threshold fixture_started_at
  dirty_repo=$(mktemp -d)
  TEMP_GIT_REPO="$dirty_repo"
  (
    cd "$dirty_repo"
    git init -q
    git config user.email "test@example.com"
    git config user.name "Test"
    echo "init" > README.md
    git add README.md
    git commit -q -m "init" 2>/dev/null
    echo "untracked" > untracked.txt
  ) || true

  test_db="$(mktemp -d)/cast.db"
  threshold="$(sqlite3 :memory: "SELECT datetime('now','-1 day');")"
  # Same instant as the cutoff, stored in the ISO-T/Z form the real column uses.
  fixture_started_at="${threshold%% *}T${threshold#* }Z"

  sqlite3 "$test_db" "CREATE TABLE sessions (project_root TEXT, started_at TEXT);"
  sqlite3 "$test_db" "INSERT INTO sessions (project_root, started_at) VALUES ('$dirty_repo', '$fixture_started_at');"

  run bash -c "echo '{}' | CAST_DB_PATH='$test_db' bash '$HOOK_SH'"
  assert_success
  # Correct: the cutoff instant is not strictly "within the last day" -> the
  # session-sourced project is never added to KNOWN_PROJECTS -> allow.
  assert_output --partial '"decision":"allow"'
}

# ---------------------------------------------------------------------------
# 9. S3a-U1b (2026-10-04): the dirty check runs through cast_git_safe (cast-hook-lib.sh).
#    (a) a git status that FAILS must fail CLOSED (block, naming the repo) — the old
#        `... 2>/dev/null || true` wrapper read an erroring repo as clean;
#    (b) hostile repo-local config (fsmonitor, git 2.54+ config hook, clean filter) planted
#        TOGETHER must not execute;
#    (c) a missing cast-hook-lib.sh must not degrade to bare git: it blocks as status-unknown.
# ---------------------------------------------------------------------------
_pg_repo() { # dir — committed clean repo; tracked files carry an old mtime (never racily clean)
  mkdir -p "$1"
  git init -q --initial-branch=main "$1"
  git -C "$1" config user.email "test@example.com"
  git -C "$1" config user.name "Test"
  printf 'evil.txt filter=evil\n' > "$1/.gitattributes"
  echo base > "$1/a.txt"
  echo evil > "$1/evil.txt"
  touch -t 202001010000 "$1/.gitattributes" "$1/a.txt" "$1/evil.txt"
  git -C "$1" add -A
  git -C "$1" commit -q -m init
}
_pg_canary() { # script-path marker-path [body] — a program that records that it ran
  printf '#!/bin/sh\ntouch "%s"\n%s\n' "$2" "${3:-exit 0}" > "$1"
  chmod +x "$1"
}
_pg_auto() { # repo [hook-script] — auto-compaction payload through the hook
  run bash -c "echo '{\"trigger\":\"auto\"}' | CAST_EXTRA_PROJECT='$1' CAST_DB_PATH=/dev/null bash '${2:-$HOOK_SH}'"
}
# Reason for a repo whose status could not be read (S3a-U1b security L1): a distinct sentence naming
# the repo and saying committing will not help — "Commit before compacting" must NOT be the guidance.
_pg_assert_unreadable_reason() { # repo
  assert_output --partial "Could not read git status for: $1 (rc="
  assert_output --partial "needs an operator fix"
  assert_output --partial "committing will not help"
  assert_output --partial "Manual /compact still works"
  refute_output --partial "Commit before compacting"
  refute_output --partial "Uncommitted changes"
}

@test "PreCompact guard: a git status that FAILS fails CLOSED (blocks, names the repo) - never reads as clean" {
  local repo="$BATS_TEST_TMPDIR/broken-index"
  _pg_repo "$repo"
  printf garbage > "$repo/.git/index"
  # CONTROL: plain git status really fails in this fixture (so a clean/allow verdict is the bug)
  run git -C "$repo" status --porcelain
  assert_failure
  _pg_auto "$repo"
  assert_success
  assert_output --regexp '"decision":[[:space:]]*"block"'
  _pg_assert_unreadable_reason "$repo"
}

@test "PreCompact guard: hardening config read failing (malformed .git/config, rc=3) fails CLOSED" {
  local repo="$BATS_TEST_TMPDIR/broken-config"
  _pg_repo "$repo"
  printf '[core\n' >> "$repo/.git/config"
  # CONTROL: plain git rejects the malformed config too
  run git -C "$repo" status --porcelain
  assert_failure
  _pg_auto "$repo"
  assert_success
  assert_output --regexp '"decision":[[:space:]]*"block"'
  _pg_assert_unreadable_reason "$repo"
  assert_output --partial "$repo (rc=3)"
}

@test "PreCompact guard: a dirty repo AND an unreadable repo get BOTH sentences (commit guidance only for the dirty one)" {
  # KNOWN_PROJECTS hardcodes $HOME/Projects/personal/<name>; HOME is the isolated temp HOME here.
  local dirty="$HOME/Projects/personal/cast-hooks" broken="$HOME/Projects/personal/cast-dash"
  _pg_repo "$dirty"
  echo new > "$dirty/untracked.txt"
  _pg_repo "$broken"
  printf garbage > "$broken/.git/index"
  run bash -c "echo '{\"trigger\":\"auto\"}' | CAST_DB_PATH=/dev/null bash '$HOOK_SH'"
  assert_success
  assert_output --regexp '"decision":[[:space:]]*"block"'
  assert_output --partial "Uncommitted changes in: $dirty. Commit before compacting (use commit agent)."
  assert_output --partial "Could not read git status for: $broken (rc="
  # the dirty-guidance sentence must not name the unreadable repo
  refute_output --partial "Uncommitted changes in: $dirty, $broken"
  refute_output --partial "Uncommitted changes in: $broken"
}

@test "PreCompact guard hostile repo: fsmonitor + config hook + stat-dirty clean filter planted together, none fire (control fires)" {
  local repo="$BATS_TEST_TMPDIR/trio" mk="$BATS_TEST_TMPDIR/trio-marks"
  mkdir -p "$mk"
  _pg_repo "$repo"
  _pg_canary "$mk/fsm.sh" "$mk/fsm.fired"
  _pg_canary "$mk/hook.sh" "$mk/hook.fired"
  _pg_canary "$mk/clean.sh" "$mk/clean.fired" cat
  git -C "$repo" config core.fsmonitor "$mk/fsm.sh"
  git -C "$repo" config hook.x.event post-index-change # inert before git 2.54; see the next test
  git -C "$repo" config hook.x.command "$mk/hook.sh"
  git -C "$repo" config filter.evil.clean "$mk/clean.sh"
  touch "$repo/evil.txt" # stat-dirty, content identical
  # CONTROL: plain git status fires the fsmonitor and the clean filter (the fixture is hostile)
  git -C "$repo" status --porcelain > /dev/null 2>&1 || true
  [ -e "$mk/fsm.fired" ]
  [ -e "$mk/clean.fired" ]
  rm -f "$mk"/*.fired
  touch -t 202201010000 "$repo/evil.txt" # the control refreshed the index; re-dirty
  _pg_auto "$repo"
  assert_success
  assert_output --partial '"decision":"allow"'
  [ -z "$(find "$mk" -name '*.fired')" ]
}

@test "PreCompact guard hostile repo: git 2.54+ config-based hook (post-index-change) does not run (control fires)" {
  local repo="$BATS_TEST_TMPDIR/cfghook" mk="$BATS_TEST_TMPDIR/cfghook-marks"
  mkdir -p "$mk"
  _pg_repo "$repo"
  _pg_canary "$mk/hook.sh" "$mk/hook.fired"
  git -C "$repo" config hook.x.event post-index-change
  git -C "$repo" config hook.x.command "$mk/hook.sh"
  touch "$repo/a.txt" # stat-dirty: a plain status refreshes and rewrites the index
  # CONTROL (attempt-first): skip ONLY if plain git cannot fire a config hook here (git < 2.54)
  git -C "$repo" status --porcelain > /dev/null 2>&1 || true
  if [ ! -e "$mk/hook.fired" ]; then
    skip "config-based hooks need git >= 2.54"
  fi
  rm -f "$mk/hook.fired"
  touch -t 202201010000 "$repo/a.txt"
  _pg_auto "$repo"
  assert_success
  assert_output --partial '"decision":"allow"'
  [ ! -e "$mk/hook.fired" ]
}

@test "PreCompact guard: missing cast-hook-lib.sh fails CLOSED (blocks as status-unknown) and never runs bare git" {
  local dir="$BATS_TEST_TMPDIR/nolib" repo="$BATS_TEST_TMPDIR/cleanrepo"
  local shim="$BATS_TEST_TMPDIR/gitshim" fired="$BATS_TEST_TMPDIR/git-shim.fired"
  mkdir -p "$dir" "$shim"
  cp "$HOOK_SH" "$dir/cast-precompact-guard.sh"
  [ ! -e "$dir/cast-hook-lib.sh" ]
  _pg_repo "$repo"
  # A clean repo: a bare-git fallback would say "allow", so only fail-closed can produce "block".
  [ -z "$(git -C "$repo" status --porcelain)" ]
  # CONTROL 1: with the lib beside the script, this same repo is allowed.
  _pg_auto "$repo"
  assert_success
  assert_output --partial '"decision":"allow"'
  # CONTROL 2: the PATH shim records any git invocation.
  printf '#!/bin/sh\ntouch "%s"\nexit 99\n' "$fired" > "$shim/git"
  chmod +x "$shim/git"
  PATH="$shim:$PATH" git --version > /dev/null 2>&1 || true
  [ -e "$fired" ]
  rm -f "$fired"
  # The lib-less copy, with the shim first on PATH: block, no git invocation at all.
  run env PATH="$shim:$PATH" CAST_EXTRA_PROJECT="$repo" CAST_DB_PATH=/dev/null \
    bash "$dir/cast-precompact-guard.sh" <<< '{"trigger":"auto"}'
  assert_success
  assert_output --regexp '"decision":[[:space:]]*"block"'
  assert_output --partial "$repo"
  assert_output --partial "rc=3"
  [ ! -e "$fired" ]
  grep -q 'cast-hook-lib.sh not loadable' "$HOME/.claude/logs/hook-errors.log"
}

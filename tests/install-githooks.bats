#!/usr/bin/env bats
# install-githooks.bats — install.sh deploys the git hooks to ~/.claude/githooks/ (agent-unwritable)
# and points core.hooksPath at that ABSOLUTE installed dir; the repo's git config is never written
# under a test/CI/temp HOME. Always runs under a temp HOME (setup_temp_home); never touches the real
# ~/.claude or this repo's .git/config.

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'
load 'helpers/setup'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
HOOK_FILES="pre-commit post-commit post-merge pre-push cold-start-baseline.txt"

setup() {
  setup_temp_home
}

teardown() {
  cd /
  teardown_temp_home
}

# A clean throwaway git repo copy of the source tree (so install.sh's dirty-tree guard passes and
# its git config writes could only ever land in THIS scratch repo). Echoes its path.
make_clean_tmp_repo() {
  local tmp_repo
  tmp_repo="$(mktemp -d "$BATS_TEST_TMPDIR/repo.XXXXXX")"
  cp -R "$REPO_DIR/." "$tmp_repo/"
  rm -rf "$tmp_repo/.git"
  git -C "$tmp_repo" -c core.hooksPath=/dev/null init -q
  git -C "$tmp_repo" config gc.auto 0
  git -C "$tmp_repo" config maintenance.auto false
  git -C "$tmp_repo" config maintenance.autoDetach false
  git -C "$tmp_repo" add -A
  git -C "$tmp_repo" -c user.email="test@example.com" -c user.name="Test" \
    -c core.hooksPath=/dev/null commit -q -m "init"
  echo "$tmp_repo"
}

@test "install.sh deploys the 5 hook files byte-identical with correct modes" {
  local repo name
  repo="$(make_clean_tmp_repo)"
  run bash "$repo/install.sh"
  assert_success

  for name in $HOOK_FILES; do
    [ -f "$HOME/.claude/githooks/$name" ]
    [ ! -L "$HOME/.claude/githooks/$name" ]
    cmp -s "$repo/.githooks/$name" "$HOME/.claude/githooks/$name"
  done
  for name in pre-commit post-commit post-merge pre-push; do
    [ "$(file_mode "$HOME/.claude/githooks/$name")" = "755" ]
  done
  [ "$(file_mode "$HOME/.claude/githooks/cold-start-baseline.txt")" = "644" ]
  # No staging temp files left behind
  [ -z "$(find "$HOME/.claude/githooks" -name '.install-*' | head -1)" ]
}

@test "install.sh under the test-HOME sentinel does NOT write the repo's git config" {
  local repo before after
  repo="$(make_clean_tmp_repo)"
  before="$(shasum -a 256 "$repo/.git/config")"
  run bash "$repo/install.sh"
  assert_success
  assert_output --partial "core.hooksPath NOT written"
  after="$(shasum -a 256 "$repo/.git/config")"
  [ "$before" = "$after" ]
  run git -C "$repo" config --get core.hooksPath
  assert_failure
}

# The positive path cannot run under a real install (every test HOME is guarded), so extract the
# wiring block from the real install.sh and run it directly with a controlled HOME.
run_wire_block() {  # <repo> <home> [env assignments...]
  local repo="$1" home="$2"
  shift 2
  local block
  block="$(sed -n '/^# --- Wire git hooks: core.hooksPath/,/^# --- Prune old install-snapshot/p' "$REPO_DIR/install.sh" | sed '$d')"
  [ -n "$block" ]
  run env -u CI -u CLAUDE_SUBPROCESS "$@" HOME="$home" SCRIPT_DIR="$repo" GITHOOKS_DIR="$home/.claude/githooks" \
    bash -c 'warn(){ echo "$1"; }; success(){ echo "$1"; }; '"$block"
}

@test "wiring block: outside a test HOME core.hooksPath = the ABSOLUTE installed dir" {
  local repo fake_home
  repo="$BATS_TEST_TMPDIR/wire-repo"
  git init -q "$repo"
  # "//" prefix defeats the /tmp|/var/folders prefix guard while still naming the same dir; no sentinel.
  fake_home="/$BATS_TEST_TMPDIR/wire-home"
  mkdir -p "$fake_home"
  run_wire_block "$repo" "$fake_home"
  assert_success
  run git -C "$repo" config --get core.hooksPath
  assert_success
  assert_output "$fake_home/.claude/githooks"
  [[ "$output" == /* ]]
}

@test "wiring block: sentinel HOME, CI, CLAUDE_SUBPROCESS and /tmp-style HOMEs all leave the repo config untouched" {
  local repo home
  repo="$BATS_TEST_TMPDIR/wire-repo2"
  git init -q "$repo"

  home="/$BATS_TEST_TMPDIR/sentinel-home"
  mkdir -p "$home"
  touch "$home/.cast-test-home"
  run_wire_block "$repo" "$home"
  assert_success
  run git -C "$repo" config --get core.hooksPath
  assert_failure

  home="/$BATS_TEST_TMPDIR/plain-home"
  mkdir -p "$home"
  run_wire_block "$repo" "$home" CI=1
  run git -C "$repo" config --get core.hooksPath
  assert_failure
  run_wire_block "$repo" "$home" CLAUDE_SUBPROCESS=1
  run git -C "$repo" config --get core.hooksPath
  assert_failure

  # HOME under a temp prefix (no sentinel): guarded by the path prefix alone.
  run_wire_block "$repo" "$BATS_TEST_TMPDIR/prefix-home"
  run git -C "$repo" config --get core.hooksPath
  assert_failure
}

@test "install.sh refuses a symlinked ~/.claude/githooks dir (nothing written through it)" {
  local repo victim
  repo="$(make_clean_tmp_repo)"
  victim="$BATS_TEST_TMPDIR/victim-dir"
  mkdir -p "$victim" "$HOME/.claude"
  ln -s "$victim" "$HOME/.claude/githooks"
  run bash "$repo/install.sh"
  assert_failure
  assert_output --partial "githooks is a symlink or not a directory"
  [ -z "$(ls -A "$victim")" ]
}

@test "install.sh refuses a symlinked installed hook file (victim is not overwritten)" {
  local repo victim
  repo="$(make_clean_tmp_repo)"
  victim="$BATS_TEST_TMPDIR/victim-file"
  echo "victim" > "$victim"
  mkdir -p "$HOME/.claude/githooks"
  ln -s "$victim" "$HOME/.claude/githooks/pre-commit"
  run bash "$repo/install.sh"
  assert_failure
  assert_output --partial "pre-commit is a symlink or not a regular file"
  [ "$(cat "$victim")" = "victim" ]
}

@test "install.sh refuses a symlinked hook SOURCE in the repo" {
  local repo
  repo="$(make_clean_tmp_repo)"
  rm "$repo/.githooks/post-merge"
  ln -s "$repo/.githooks/post-commit" "$repo/.githooks/post-merge"
  # CAST_INSTALL_FORCE: the dirty-tree guard would otherwise abort first (this isolates the source check).
  run env CAST_INSTALL_FORCE=1 bash "$repo/install.sh"
  assert_failure
  assert_output --partial ".githooks/post-merge is missing or not a regular file"
}

@test "dirty-tree guard covers .githooks/: an uncommitted hook edit aborts install before any deploy" {
  local repo
  repo="$(make_clean_tmp_repo)"
  echo "# loosened" >> "$repo/.githooks/pre-commit"
  run bash "$repo/install.sh"
  [ "$status" -eq 1 ]
  [[ "$output" =~ "uncommitted changes" ]]
  [ ! -e "$HOME/.claude/githooks" ]
}

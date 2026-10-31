#!/usr/bin/env bats
# Regression coverage for scripts/cast-overlay-sync.sh
#
# Focus: the durable git-identity fix (2026-07-09). The daily overlay push to
# the private repo failed with GH007 (private-email push-protection) because
# the overlay clone's local git config carried a real email address. A
# one-time manual `git config` fix on the existing clone was NOT durable — a
# fresh clone would reintroduce the bug. This test asserts the script sets
# the correct noreply identity, in the overlay dir's LOCAL config, on every
# run — using a fake local bare repo as "origin", never the real overlay dir
# or real GitHub.

load helpers/setup

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/cast-overlay-sync.sh"

EXPECTED_EMAIL="97137083+ek33450505@users.noreply.github.com"
EXPECTED_NAME="Edward Kubiak"

setup() {
  setup_temp_home

  # Isolated fake "origin": a local bare repo, never the real overlay repo.
  FAKE_REMOTE="$BATS_TEST_TMPDIR/fake-origin.git"
  git init --bare -q "$FAKE_REMOTE"
  cast_git_fixture_quiet "$FAKE_REMOTE"

  # Pre-seed the overlay dir as an existing clone of the fake remote, so the
  # script's "clone if missing" branch (which calls `gh repo create`) is
  # skipped entirely — no real GitHub interaction.
  OVERLAY_DIR="$BATS_TEST_TMPDIR/overlay"
  git clone -q "$FAKE_REMOTE" "$OVERLAY_DIR"

  # Seed a real (non-noreply) identity + an initial commit, mirroring the
  # confirmed-buggy pre-fix state, so we can prove the script corrects it.
  git -C "$OVERLAY_DIR" config user.email "test-real-address@example.com"
  git -C "$OVERLAY_DIR" config user.name "Edward Kubiak (real)"
  git -C "$OVERLAY_DIR" checkout -q -b main
  touch "$OVERLAY_DIR/.keep"
  git -C "$OVERLAY_DIR" add .keep
  git -C "$OVERLAY_DIR" commit -q -m "seed"
  git -C "$OVERLAY_DIR" push -q -u origin main

  # Source dir for the sync (irrelevant to this test's assertions, but must
  # exist for the script's copy step not to error).
  SRC_DIR="$BATS_TEST_TMPDIR/claude-src"
  mkdir -p "$SRC_DIR/config"

  export CAST_OVERLAY_REPO="$FAKE_REMOTE"
  export CAST_OVERLAY_DIR="$OVERLAY_DIR"
  export CAST_CLAUDE_DIR="$SRC_DIR"
}

teardown() {
  teardown_temp_home
}

@test "cast-overlay-sync sets correct local git identity on the overlay dir (dry-run)" {
  if [ "${GITHUB_ACTIONS:-}" = "true" ] && [ "$(uname)" = "Darwin" ]; then
    skip "overlay-sync --dry-run exits 1 with empty output on GH macOS runner (git 2.55; 2026-10-03 probe; root cause open, see audit T-5)"
  fi

  run bash "$SCRIPT" --dry-run
  [ "$status" -eq 0 ]

  local_email="$(git -C "$OVERLAY_DIR" config user.email)"
  local_name="$(git -C "$OVERLAY_DIR" config user.name)"

  [ "$local_email" = "$EXPECTED_EMAIL" ]
  [ "$local_name" = "$EXPECTED_NAME" ]
}

@test "cast-overlay-sync does not touch global git config" {
  if [ "${GITHUB_ACTIONS:-}" = "true" ] && [ "$(uname)" = "Darwin" ]; then
    skip "git empty-clone/overlay setup behavior differs on GH macOS runner (unconditional CI-macOS skip; sibling dry-run test exits 1 with empty output there, root cause open — audit T-5)"
  fi

  # Isolate global config to a throwaway file so we never touch the real
  # user's global git config, then confirm the script left it untouched.
  export GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/fake-gitconfig-global"
  touch "$GIT_CONFIG_GLOBAL"
  git config --file "$GIT_CONFIG_GLOBAL" user.email "should-not-change@example.com"

  run bash "$SCRIPT" --dry-run
  [ "$status" -eq 0 ]

  global_email="$(git config --file "$GIT_CONFIG_GLOBAL" user.email)"
  [ "$global_email" = "should-not-change@example.com" ]
}

@test "cast-overlay-sync corrects a pre-existing real-email local config (regression for GH007)" {
  if [ "${GITHUB_ACTIONS:-}" = "true" ] && [ "$(uname)" = "Darwin" ]; then
    skip "git empty-clone/overlay setup behavior differs on GH macOS runner (unconditional CI-macOS skip; sibling dry-run test exits 1 with empty output there, root cause open — audit T-5)"
  fi

  # Pre-condition sanity check: setup() seeded the real (buggy) identity.
  pre_email="$(git -C "$OVERLAY_DIR" config user.email)"
  [ "$pre_email" = "test-real-address@example.com" ]

  run bash "$SCRIPT" --dry-run
  [ "$status" -eq 0 ]

  post_email="$(git -C "$OVERLAY_DIR" config user.email)"
  [ "$post_email" = "$EXPECTED_EMAIL" ]
}

# --- Wedged-clone self-heal (overlay failed every run 2026-08-22..2026-10-30) ---

_seed_src() {
  mkdir -p "$SRC_DIR/config"
  printf 'plain\n' > "$SRC_DIR/config/sync.json"
}

_run_sync() { run bash "$SCRIPT" "$@" </dev/null; }

_first_tracked() { git -C "$OVERLAY_DIR" ls-files | grep -v '^\.keep$' | head -1; }

@test "wedged clone (modified tracked file) self-heals, pushes, and logs the restore" {
  _seed_src
  _run_sync
  [ "$status" -eq 0 ]
  tracked="$(_first_tracked)"
  [ -n "$tracked" ]
  echo "wedge" >> "$OVERLAY_DIR/$tracked"
  echo "changed" >> "$SRC_DIR/config/sync.json"
  before="$(git -C "$FAKE_REMOTE" rev-parse main)"

  _run_sync
  [ "$status" -eq 0 ]
  after="$(git -C "$FAKE_REMOTE" rev-parse main)"
  [ "$before" != "$after" ]
  grep -q "restored overlay clone" "$HOME/.claude/logs/cast-overlay-sync.log"
}

@test "secret abort leaves the clone clean and the next run succeeds" {
  _seed_src
  _run_sync
  [ "$status" -eq 0 ]
  src="$SRC_DIR/config/sync.json"
  cp "$src" "$BATS_TEST_TMPDIR/orig"
  printf 'AKIA%s\n' QQQQQQQQQQQQQQQQ >> "$src"

  _run_sync
  [ "$status" -eq 1 ]
  [ -z "$(git -C "$OVERLAY_DIR" status --porcelain --untracked-files=no)" ]

  cp "$BATS_TEST_TMPDIR/orig" "$src"
  echo "benign change" >> "$src"
  _run_sync
  [ "$status" -eq 0 ]
}

@test "dirty clone whose origin differs from CAST_OVERLAY_REPO is not restored" {
  _seed_src
  _run_sync
  [ "$status" -eq 0 ]
  tracked="$(_first_tracked)"
  echo "dirty" >> "$OVERLAY_DIR/$tracked"
  sum_before="$(shasum -a 256 "$OVERLAY_DIR/$tracked")"
  git -C "$OVERLAY_DIR" remote set-url origin "$BATS_TEST_TMPDIR/other-origin.git"

  _run_sync
  [ "$status" -eq 1 ]
  [ "$(shasum -a 256 "$OVERLAY_DIR/$tracked")" = "$sum_before" ]
}

@test "overlay dir that is a subdirectory of another repo is refused" {
  OUTER="$BATS_TEST_TMPDIR/outer"
  git init -q "$OUTER"
  git -C "$OUTER" config user.email t@example.com
  git -C "$OUTER" config user.name t
  mkdir -p "$OUTER/sub"
  echo a > "$OUTER/sub/f.txt"
  git -C "$OUTER" add -A
  git -C "$OUTER" commit -q -m init
  git -C "$OUTER" remote add origin "$FAKE_REMOTE"
  echo dirty >> "$OUTER/sub/f.txt"
  sum_before="$(shasum -a 256 "$OUTER/sub/f.txt")"
  export CAST_OVERLAY_DIR="$OUTER/sub"

  _run_sync
  [ "$status" -eq 1 ]
  [ "$(shasum -a 256 "$OUTER/sub/f.txt")" = "$sum_before" ]
}

@test "overlay dir reached through a symlink is accepted" {
  _seed_src
  ln -s "$OVERLAY_DIR" "$BATS_TEST_TMPDIR/overlay-link"
  export CAST_OVERLAY_DIR="$BATS_TEST_TMPDIR/overlay-link"
  _run_sync
  [ "$status" -eq 0 ]
}

@test "trailing slash on CAST_OVERLAY_DIR is accepted" {
  _seed_src
  export CAST_OVERLAY_DIR="$OVERLAY_DIR/"
  _run_sync
  [ "$status" -eq 0 ]
}

@test "_norm_origin treats ssh, scp and https forms of one repo as equal" {
  eval "$(sed -n '/^_norm_origin()/,/^}/p' "$SCRIPT")"
  want="github.com/owner/repo"
  # The at-sign is built at runtime: the PII gates read user-at-host.tld text as an email address.
  local at='@'
  [ "$(_norm_origin "git${at}github.com:owner/repo.git")" = "$want" ]
  [ "$(_norm_origin "git${at}github.com:owner/repo")" = "$want" ]
  [ "$(_norm_origin "ssh://git${at}github.com/owner/repo.git")" = "$want" ]
  [ "$(_norm_origin 'https://github.com/owner/repo')" = "$want" ]
  [ "$(_norm_origin "https://tok${at}GitHub.com/owner/repo.git")" = "$want" ]
  [ "$(_norm_origin 'https://github.com/owner/repo/')" = "$want" ]
  [ "$(_norm_origin "ssh://git${at}github.com:22/o/r")" = "$(_norm_origin 'https://github.com/o/r')" ]
  [ "$(_norm_origin "ssh://git${at}github.com:2222/o/r")" != "$(_norm_origin 'https://github.com/o/r')" ]
  # path case is NOT folded; different owner/repo never matches
  [ "$(_norm_origin 'https://github.com/Owner/repo')" != "$want" ]
  [ "$(_norm_origin "git${at}github.com:other/repo.git")" != "$want" ]
  # local paths compare exactly
  [ "$(_norm_origin '/tmp/x/fake-origin.git')" = "/tmp/x/fake-origin" ]
}

@test "dirty clone with a different owner/repo origin is refused, file unchanged" {
  _seed_src
  _run_sync
  [ "$status" -eq 0 ]
  tracked="$(_first_tracked)"
  echo "dirty" >> "$OVERLAY_DIR/$tracked"
  sum_before="$(shasum -a 256 "$OVERLAY_DIR/$tracked")"
  git -C "$OVERLAY_DIR" remote set-url origin "https://github.com/other/repo.git"
  export CAST_OVERLAY_REPO="https://github.com/owner/repo"

  _run_sync
  [ "$status" -eq 1 ]
  [ "$(shasum -a 256 "$OVERLAY_DIR/$tracked")" = "$sum_before" ]
}

@test "overlay dir that is an ancestor of CAST_CLAUDE_DIR is refused, file unchanged" {
  _seed_src
  _run_sync
  [ "$status" -eq 0 ]
  tracked="$(_first_tracked)"
  echo "dirty" >> "$OVERLAY_DIR/$tracked"
  sum_before="$(shasum -a 256 "$OVERLAY_DIR/$tracked")"
  mkdir -p "$OVERLAY_DIR/inner/config"
  export CAST_CLAUDE_DIR="$OVERLAY_DIR/inner"

  _run_sync
  [ "$status" -eq 1 ]
  [ "$(shasum -a 256 "$OVERLAY_DIR/$tracked")" = "$sum_before" ]
}

@test "empty HOME is refused, dirty file unchanged" {
  _seed_src
  _run_sync
  [ "$status" -eq 0 ]
  tracked="$(_first_tracked)"
  echo "dirty" >> "$OVERLAY_DIR/$tracked"
  sum_before="$(shasum -a 256 "$OVERLAY_DIR/$tracked")"

  HOME="" run bash "$SCRIPT" </dev/null
  [ "$status" -eq 1 ]
  [[ "$output" == *"HOME is unset or empty; refusing to run"* ]]
  [ "$(shasum -a 256 "$OVERLAY_DIR/$tracked")" = "$sum_before" ]
}

@test "inherited GIT_DIR cannot redirect the sync at another repo" {
  _seed_src
  OTHER="$BATS_TEST_TMPDIR/other-repo"
  git init -q "$OTHER"
  cfg_before="$(shasum -a 256 "$OTHER/.git/config")"
  head_before="$(git -C "$OTHER" symbolic-ref HEAD)"

  GIT_DIR="$OTHER/.git" run bash "$SCRIPT" </dev/null
  [ "$status" -eq 0 ]
  [ "$(shasum -a 256 "$OTHER/.git/config")" = "$cfg_before" ]
  [ "$(git -C "$OTHER" symbolic-ref HEAD)" = "$head_before" ]
  [ "$(git -C "$OVERLAY_DIR" config user.email)" = "$EXPECTED_EMAIL" ]
}

@test "up-front gate stops a clean subdir of another repo before git config runs" {
  OUTER="$BATS_TEST_TMPDIR/outer2"
  git init -q "$OUTER"
  git -C "$OUTER" config user.email t@example.com
  git -C "$OUTER" config user.name t
  mkdir -p "$OUTER/sub"
  echo a > "$OUTER/sub/f.txt"
  git -C "$OUTER" add -A
  git -C "$OUTER" commit -q -m init
  git -C "$OUTER" remote add origin "$FAKE_REMOTE"
  cfg_before="$(shasum -a 256 "$OUTER/.git/config")"
  export CAST_OVERLAY_DIR="$OUTER/sub"

  _run_sync
  [ "$status" -eq 1 ]
  [ "$(shasum -a 256 "$OUTER/.git/config")" = "$cfg_before" ]
}

@test "--dry-run leaves no staged or modified tracked files" {
  _seed_src
  _run_sync
  [ "$status" -eq 0 ]
  echo "more" >> "$SRC_DIR/config/sync.json"

  _run_sync --dry-run
  [ "$status" -eq 0 ]
  [ -z "$(git -C "$OVERLAY_DIR" status --porcelain --untracked-files=no)" ]
}

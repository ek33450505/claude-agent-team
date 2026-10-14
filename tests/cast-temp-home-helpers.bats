#!/usr/bin/env bats
# tests/cast-temp-home-helpers.bats — guards for tests/helpers/setup.bash
# (setup_temp_home DB-env isolation; teardown_temp_home canonicalised guards).
#
# Every scenario runs in a `bash -c` subshell with HOME/ORIG_HOME pointing at
# fixtures under $BATS_TEST_TMPDIR. The real home is never an operand.

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

@test "setup_temp_home unsets ambient CAST_DB_PATH and CAST_DB_URL" {
  run env HOME="$BATS_TEST_TMPDIR" REPO_DIR="$REPO_DIR" bash -c '
    source "$REPO_DIR/tests/helpers/setup.bash"
    export CAST_DB_PATH=/x CAST_DB_URL=sqlite:////x
    setup_temp_home
    made="$HOME"
    echo "[${CAST_DB_PATH-unset}][${CAST_DB_URL-unset}]"
    rm -rf "$made"
  '
  assert_success
  assert_output "[unset][unset]"
}

@test "teardown_temp_home refuses when HOME is a symlink to ORIG_HOME" {
  local fake="$BATS_TEST_TMPDIR/fakehome"
  mkdir -p "$fake"
  touch "$fake/.cast-test-home"
  ln -s "$fake" "$BATS_TEST_TMPDIR/linkhome"
  run env REPO_DIR="$REPO_DIR" FAKE="$fake" LINK="$BATS_TEST_TMPDIR/linkhome" bash -c '
    source "$REPO_DIR/tests/helpers/setup.bash"
    export ORIG_HOME="$FAKE"
    export HOME="$LINK"
    teardown_temp_home
  '
  assert_failure
  assert_output --partial "matches ORIG_HOME"
  [ -d "$fake" ]
  [ -f "$fake/.cast-test-home" ]
}

@test "teardown_temp_home still deletes a genuine temp HOME" {
  local fake="$BATS_TEST_TMPDIR/realhome"
  local tgt="$BATS_TEST_TMPDIR/targethome"
  mkdir -p "$fake" "$tgt"
  touch "$tgt/.cast-test-home"
  run env REPO_DIR="$REPO_DIR" FAKE="$fake" TGT="$tgt" bash -c '
    source "$REPO_DIR/tests/helpers/setup.bash"
    export ORIG_HOME="$FAKE"
    export HOME="$TGT"
    teardown_temp_home
  '
  assert_success
  [ ! -d "$tgt" ]
  [ -d "$fake" ]
}

@test "_cast_temp_prefix_ok accepts temp roots and refuses everything else" {
  run env REPO_DIR="$REPO_DIR" bash -c '
    source "$REPO_DIR/tests/helpers/setup.bash"
    for p in /tmp/x /private/tmp/x /var/folders/a /private/var/folders/a/b; do
      _cast_temp_prefix_ok "$p" || echo "REFUSED-OK-CASE:$p"
    done
    for p in /opt/cast-x/y /tmp /private/tmp "" /home/u/tmp/x; do
      _cast_temp_prefix_ok "$p" && echo "ACCEPTED-BAD-CASE:[$p]"
    done
    echo done
  '
  assert_success
  assert_output "done"
}

@test "teardown_temp_home refuses a raw non-temp HOME that resolves into a temp dir" {
  local tgt="$BATS_TEST_TMPDIR/dotdothome"
  local fake="$BATS_TEST_TMPDIR/otherhome"
  mkdir -p "$tgt" "$fake"
  touch "$tgt/.cast-test-home"
  run env REPO_DIR="$REPO_DIR" FAKE="$fake" RAW="/usr/..$tgt" bash -c '
    source "$REPO_DIR/tests/helpers/setup.bash"
    export ORIG_HOME="$FAKE"
    export HOME="$RAW"
    teardown_temp_home
  '
  assert_failure
  assert_output --partial "not under /tmp"
  [ -d "$tgt" ]
}

@test "teardown_temp_home refuses a symlinked HOME (even with trailing slash) and keeps the target" {
  local tgt="$BATS_TEST_TMPDIR/symtarget"
  local fake="$BATS_TEST_TMPDIR/otherhome2"
  mkdir -p "$tgt" "$fake"
  touch "$tgt/.cast-test-home" "$tgt/keep"
  ln -s "$tgt" "$BATS_TEST_TMPDIR/symlink"
  run env REPO_DIR="$REPO_DIR" FAKE="$fake" LINK="$BATS_TEST_TMPDIR/symlink/" bash -c '
    source "$REPO_DIR/tests/helpers/setup.bash"
    export ORIG_HOME="$FAKE"
    export HOME="$LINK"
    teardown_temp_home
  '
  assert_failure
  assert_output --partial "HOME is a symlink"
  [ -f "$tgt/keep" ]
  [ -f "$tgt/.cast-test-home" ]
}

@test "teardown_temp_home refuses a symlinked HOME with multiple trailing slashes" {
  local tgt="$BATS_TEST_TMPDIR/symtarget2"
  local fake="$BATS_TEST_TMPDIR/otherhome3"
  mkdir -p "$tgt" "$fake"
  touch "$tgt/.cast-test-home" "$tgt/keep"
  ln -s "$tgt" "$BATS_TEST_TMPDIR/symlink2"
  local suffix
  for suffix in "//" "///"; do
    run env REPO_DIR="$REPO_DIR" FAKE="$fake" LINK="$BATS_TEST_TMPDIR/symlink2$suffix" bash -c '
      source "$REPO_DIR/tests/helpers/setup.bash"
      export ORIG_HOME="$FAKE"
      export HOME="$LINK"
      teardown_temp_home
    '
    assert_failure
    assert_output --partial "HOME is a symlink"
    [ -f "$tgt/keep" ]
    [ -f "$tgt/.cast-test-home" ]
  done
}

@test "teardown_temp_home deletes a real temp HOME given with trailing slashes" {
  local tgt="$BATS_TEST_TMPDIR/realtrail"
  local fake="$BATS_TEST_TMPDIR/otherhome4"
  mkdir -p "$tgt" "$fake"
  touch "$tgt/.cast-test-home"
  run env REPO_DIR="$REPO_DIR" FAKE="$fake" TGT="$tgt//" bash -c '
    source "$REPO_DIR/tests/helpers/setup.bash"
    export ORIG_HOME="$FAKE"
    export HOME="$TGT"
    teardown_temp_home
  '
  assert_success
  [ ! -d "$tgt" ]
  [ -d "$fake" ]
}

@test "teardown_temp_home refuses an all-slash HOME" {
  local fake="$BATS_TEST_TMPDIR/otherhome5"
  mkdir -p "$fake"
  run env REPO_DIR="$REPO_DIR" FAKE="$fake" bash -c '
    source "$REPO_DIR/tests/helpers/setup.bash"
    export ORIG_HOME="$FAKE"
    export HOME="//"
    teardown_temp_home
  '
  assert_failure
  assert_output --partial "empty path"
}

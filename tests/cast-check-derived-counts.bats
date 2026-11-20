#!/usr/bin/env bats
# Tests for scripts/cast-check-derived-counts.sh (self-lints CI gate).
#
# The script recomputes every derived count and exits 1 when one is stale.
# Plants are made ONLY in a private copy of the working tree under
# $BATS_TEST_TMPDIR; the real repo is read, never written.

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'
load 'helpers/setup'

REPO_ROOT_REAL="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

setup() {
  setup_temp_home
  # PATH-shim the GUI surfaces; this script must never reach them, but the
  # shim guarantees zero side effects if a regression ever does.
  SHIM_DIR="$BATS_TEST_TMPDIR/shims"
  mkdir -p "$SHIM_DIR"
  local _gui
  for _gui in osascript open terminal-notifier screencapture; do
    printf '#!/bin/bash\nexit 0\n' > "$SHIM_DIR/$_gui"
    chmod +x "$SHIM_DIR/$_gui"
  done
  export PATH="$SHIM_DIR:$PATH"

  COPY="$BATS_TEST_TMPDIR/repo"
  make_repo_copy
}

teardown() {
  teardown_temp_home
}

# Copy the working tree WITHOUT .git, then git-init the copy: the gate's
# generators shell out to git (ls-files; the skip-ledger repo check), so the
# copy must be a repo with an index, but the ~30 MB object store is not needed.
make_repo_copy() {
  mkdir -p "$COPY"
  tar -C "$REPO_ROOT_REAL" --exclude=.git -cf - . | tar -C "$COPY" -xf -
  env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE git -C "$COPY" init -q
  cast_git_fixture_quiet "$COPY"
  env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE git -C "$COPY" add -A
}

@test "reports the agent roster and completions surfaces as [ok] on an untouched copy" {
  # Per-surface predicate, not overall exit 0: the live tree can be stale on
  # other surfaces (in-flight docs work), which must not mask this surface.
  run bash "$COPY/scripts/cast-check-derived-counts.sh"
  local expected
  expected="$(find "$COPY/agents/core" -maxdepth 1 -name '*.md' | wc -l | tr -d ' ')"
  assert_output --regexp "\\[ok\\] +CLAUDE\\.md agent roster count +${expected}"
  assert_output --regexp '\[ok\] +completions dispatch-table count +[0-9]+ \(name and assertion agree\)'
  refute_output --partial "[STALE] CLAUDE.md agent roster count"
  refute_output --partial "[STALE] completions dispatch-table count"
}

@test "names the agent roster STALE when CLAUDE.md claims a wrong count" {
  local expected wrong
  expected="$(find "$COPY/agents/core" -maxdepth 1 -name '*.md' | wc -l | tr -d ' ')"
  wrong=$((expected + 1))
  sed "s/holds the ${expected} canonical/holds the ${wrong} canonical/" \
    "$COPY/CLAUDE.md" > "$COPY/CLAUDE.md.new" && mv "$COPY/CLAUDE.md.new" "$COPY/CLAUDE.md"
  run grep -c "holds the ${wrong} canonical" "$COPY/CLAUDE.md"
  assert_output "1"

  run bash "$COPY/scripts/cast-check-derived-counts.sh"
  assert_failure
  assert_output --partial "[STALE] CLAUDE.md agent roster count"
  assert_output --partial "claims ${wrong}, tree has ${expected}"
  assert_output --partial "STALE: at least one derived count is out of date"
}

@test "names the completions surface STALE when test name and assertion disagree" {
  local f="$COPY/tests/cast-completions-drift.bats"
  sed '/^@test "zsh: generated subcommands region == dispatch table (count/s/(count [0-9][0-9]*)/(count 999)/' \
    "$f" > "$f.new" && mv "$f.new" "$f"
  run grep -c '(count 999)' "$f"
  assert_output "1"

  run bash "$COPY/scripts/cast-check-derived-counts.sh"
  assert_failure
  assert_output --partial "[STALE] completions dispatch-table count"
  assert_output --partial "test name says 999, assertion says"
  assert_output --partial "update BOTH the assertion and the test name"
}

@test "reports the completions surface STALE with <none> when its test file is missing" {
  rm -f "$COPY/tests/cast-completions-drift.bats"

  run bash "$COPY/scripts/cast-check-derived-counts.sh"
  assert_failure
  assert_output --partial "test name says <none>, assertion says <none>"
}

@test "never modifies any file in the tree it checks" {
  find "$COPY" -path "$COPY/.git" -prune -o -type f -print0 \
    | xargs -0 shasum -a 256 | sort > "$BATS_TEST_TMPDIR/before.sha"

  run bash "$COPY/scripts/cast-check-derived-counts.sh"

  find "$COPY" -path "$COPY/.git" -prune -o -type f -print0 \
    | xargs -0 shasum -a 256 | sort > "$BATS_TEST_TMPDIR/after.sha"
  run diff "$BATS_TEST_TMPDIR/before.sha" "$BATS_TEST_TMPDIR/after.sha"
  assert_success
}

#!/usr/bin/env bats
# Tests for scripts/check-docs-deletion.sh
#
# Design:
#   Each test builds a throwaway git repo in a mktemp -d directory.
#   Base commit adds CHANGELOG.md (or other files); head commit modifies them.
#   The script is called against "base-commit..head-commit" refs within the
#   fixture repo — never against the real repo history or real $HOME.
#
# Safety:
#   All fixture repos live under mktemp -d directories.
#   No real $HOME or ~/.claude paths are touched.

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_DIR/scripts/check-docs-deletion.sh"

# ---------------------------------------------------------------------------
# Helper: create a fixture git repo with a base commit containing CHANGELOG.md
# with N lines of content.
#
# $1 — number of lines in the base CHANGELOG.md
# Prints the fixture repo path.
# ---------------------------------------------------------------------------
_make_fixture_repo() {
  local base_lines="${1:-100}"
  local tmpdir
  tmpdir="$(mktemp -d)"

  git init -q "$tmpdir"
  git -C "$tmpdir" config user.email "test@example.com"
  git -C "$tmpdir" config user.name "CAST Test"

  # Base commit: CHANGELOG.md with base_lines lines
  local content=""
  local i
  for (( i = 1; i <= base_lines; i++ )); do
    content+="Line $i of changelog content here for testing purposes.$'\n'"
  done
  printf '%s\n' "$(seq 1 "$base_lines" | awk '{print "Line " $1 " of changelog content."}')" \
    > "$tmpdir/CHANGELOG.md"

  git -C "$tmpdir" add CHANGELOG.md
  git -C "$tmpdir" commit -q -m "init: add CHANGELOG.md with $base_lines lines"

  echo "$tmpdir"
}

# ---------------------------------------------------------------------------
# Helper: run the script inside a fixture repo with given base and head refs.
#
# $1 — fixture repo path
# $2 — base ref (default: HEAD~1)
# $3 — head ref (default: HEAD)
# Sets $output, $status via BATS run semantics.
# ---------------------------------------------------------------------------
_run_script() {
  local fixture_repo="$1"
  local base_ref="${2:-HEAD~1}"
  local head_ref="${3:-HEAD}"
  # run is called by the caller after sourcing this helper — see tests below
  :
}

setup() {
  TEST_FIXTURES=()
}

teardown() {
  local f
  for f in "${TEST_FIXTURES[@]+"${TEST_FIXTURES[@]}"}"; do
    [[ -d "$f" ]] && rm -rf "$f"
  done
}

# ---------------------------------------------------------------------------
# Test 1: Large deletion (80 of 100 lines) → script exits 1
# ---------------------------------------------------------------------------

@test "1: large net deletion in CHANGELOG.md exits 1" {
  local repo
  repo="$(mktemp -d)"
  TEST_FIXTURES+=("$repo")

  git init -q "$repo"
  git -C "$repo" config user.email "test@example.com"
  git -C "$repo" config user.name "CAST Test"

  # Base commit: 100-line CHANGELOG.md
  seq 1 100 | awk '{print "Line " $1 " of changelog."}' > "$repo/CHANGELOG.md"
  git -C "$repo" add CHANGELOG.md
  git -C "$repo" commit -q -m "base: 100-line CHANGELOG"

  # Head commit: keep only 20 lines (net delete = 80)
  seq 1 20 | awk '{print "Line " $1 " of changelog."}' > "$repo/CHANGELOG.md"
  git -C "$repo" add CHANGELOG.md
  git -C "$repo" commit -q -m "shrink: remove 80 lines"

  BASE="$(git -C "$repo" rev-parse HEAD~1)"
  HEAD_SHA="$(git -C "$repo" rev-parse HEAD)"

  run bash -c "cd '$repo' && bash '$SCRIPT' '$BASE' '$HEAD_SHA'"
  assert_failure
  assert_output --partial "FAIL"
  assert_output --partial "CHANGELOG.md"
}

# ---------------------------------------------------------------------------
# Test 2: Same large deletion, but commit message contains ack token → exits 0
# ---------------------------------------------------------------------------

@test "2: large deletion acknowledged in commit message exits 0" {
  local repo
  repo="$(mktemp -d)"
  TEST_FIXTURES+=("$repo")

  git init -q "$repo"
  git -C "$repo" config user.email "test@example.com"
  git -C "$repo" config user.name "CAST Test"

  seq 1 100 | awk '{print "Line " $1 " of changelog."}' > "$repo/CHANGELOG.md"
  git -C "$repo" add CHANGELOG.md
  git -C "$repo" commit -q -m "base: 100-line CHANGELOG"

  seq 1 20 | awk '{print "Line " $1 " of changelog."}' > "$repo/CHANGELOG.md"
  git -C "$repo" add CHANGELOG.md
  git -C "$repo" commit -q -m "shrink CHANGELOG [docs-destroy-ok]"

  BASE="$(git -C "$repo" rev-parse HEAD~1)"
  HEAD_SHA="$(git -C "$repo" rev-parse HEAD)"

  run bash -c "cd '$repo' && bash '$SCRIPT' '$BASE' '$HEAD_SHA'"
  assert_success
}

# ---------------------------------------------------------------------------
# Test 3: Large deletion, ack token in PR_BODY env → exits 0
# ---------------------------------------------------------------------------

@test "3: large deletion with [docs-destroy-ok] in PR_BODY exits 0" {
  local repo
  repo="$(mktemp -d)"
  TEST_FIXTURES+=("$repo")

  git init -q "$repo"
  git -C "$repo" config user.email "test@example.com"
  git -C "$repo" config user.name "CAST Test"

  seq 1 100 | awk '{print "Line " $1 " of changelog."}' > "$repo/CHANGELOG.md"
  git -C "$repo" add CHANGELOG.md
  git -C "$repo" commit -q -m "base: 100-line CHANGELOG"

  seq 1 20 | awk '{print "Line " $1 " of changelog."}' > "$repo/CHANGELOG.md"
  git -C "$repo" add CHANGELOG.md
  git -C "$repo" commit -q -m "shrink: remove 80 lines (no ack in commit)"

  BASE="$(git -C "$repo" rev-parse HEAD~1)"
  HEAD_SHA="$(git -C "$repo" rev-parse HEAD)"

  run env PR_BODY="This PR removes old history. [docs-destroy-ok]" \
    bash -c "cd '$repo' && bash '$SCRIPT' '$BASE' '$HEAD_SHA'"
  assert_success
}

# ---------------------------------------------------------------------------
# Test 4: Small deletion (5 lines of 100) → exits 0
# ---------------------------------------------------------------------------

@test "4: small deletion (5 lines) is below threshold → exits 0" {
  local repo
  repo="$(mktemp -d)"
  TEST_FIXTURES+=("$repo")

  git init -q "$repo"
  git -C "$repo" config user.email "test@example.com"
  git -C "$repo" config user.name "CAST Test"

  seq 1 100 | awk '{print "Line " $1 " of changelog."}' > "$repo/CHANGELOG.md"
  git -C "$repo" add CHANGELOG.md
  git -C "$repo" commit -q -m "base: 100-line CHANGELOG"

  # Remove 5 lines (keep 95)
  seq 1 95 | awk '{print "Line " $1 " of changelog."}' > "$repo/CHANGELOG.md"
  git -C "$repo" add CHANGELOG.md
  git -C "$repo" commit -q -m "trim: remove 5 lines"

  BASE="$(git -C "$repo" rev-parse HEAD~1)"
  HEAD_SHA="$(git -C "$repo" rev-parse HEAD)"

  run bash -c "cd '$repo' && bash '$SCRIPT' '$BASE' '$HEAD_SHA'"
  assert_success
  assert_output --partial "OK"
}

# ---------------------------------------------------------------------------
# Test 5: Large deletion of a NON-guarded file → exits 0
# ---------------------------------------------------------------------------

@test "5: large deletion in non-guarded file (src/foo.txt) → exits 0" {
  local repo
  repo="$(mktemp -d)"
  TEST_FIXTURES+=("$repo")

  git init -q "$repo"
  git -C "$repo" config user.email "test@example.com"
  git -C "$repo" config user.name "CAST Test"

  mkdir -p "$repo/src"
  seq 1 100 | awk '{print "line " $1}' > "$repo/src/foo.txt"
  git -C "$repo" add src/foo.txt
  git -C "$repo" commit -q -m "base: 100-line src/foo.txt"

  # Delete 80 lines from non-guarded file
  seq 1 20 | awk '{print "line " $1}' > "$repo/src/foo.txt"
  git -C "$repo" add src/foo.txt
  git -C "$repo" commit -q -m "shrink non-guarded file"

  BASE="$(git -C "$repo" rev-parse HEAD~1)"
  HEAD_SHA="$(git -C "$repo" rev-parse HEAD)"

  run bash -c "cd '$repo' && bash '$SCRIPT' '$BASE' '$HEAD_SHA'"
  assert_success
  assert_output --partial "OK"
}

# ---------------------------------------------------------------------------
# Test 6: CAST_SKIP_DOCS_DELETE=1 with real violation → exits 0
# ---------------------------------------------------------------------------

@test "6: CAST_SKIP_DOCS_DELETE=1 bypasses check even with a large deletion" {
  local repo
  repo="$(mktemp -d)"
  TEST_FIXTURES+=("$repo")

  git init -q "$repo"
  git -C "$repo" config user.email "test@example.com"
  git -C "$repo" config user.name "CAST Test"

  seq 1 100 | awk '{print "Line " $1 " of changelog."}' > "$repo/CHANGELOG.md"
  git -C "$repo" add CHANGELOG.md
  git -C "$repo" commit -q -m "base: 100-line CHANGELOG"

  seq 1 5 | awk '{print "Line " $1 " of changelog."}' > "$repo/CHANGELOG.md"
  git -C "$repo" add CHANGELOG.md
  git -C "$repo" commit -q -m "delete almost everything"

  BASE="$(git -C "$repo" rev-parse HEAD~1)"
  HEAD_SHA="$(git -C "$repo" rev-parse HEAD)"

  run env CAST_SKIP_DOCS_DELETE=1 bash -c "cd '$repo' && bash '$SCRIPT' '$BASE' '$HEAD_SHA'"
  assert_success
  assert_output --partial "CAST_SKIP_DOCS_DELETE=1"
}

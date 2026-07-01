#!/usr/bin/env bats
# Tests for the destructive-docs guard in write-guards.py (CAST X.5 Unit A)
# Covers: CHANGELOG.md / docs/*.md paths, threshold tuning, ack token, non-guarded paths.

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
GUARD="$REPO_DIR/scripts/write-guards.py"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Write N lines to a temp file, return the path via stdout
make_temp_file_with_lines() {
  local n="$1"
  local path
  path="$(mktemp)"
  python3 -c "
import sys
n = int('$n')
print('\n'.join('line {}'.format(i) for i in range(1, n + 1)))
" > "$path"
  echo "$path"
}

# Build a Write JSON payload given file_path and content
write_payload() {
  python3 -c "
import json, sys
fp = sys.argv[1]
content_file = sys.argv[2]
with open(content_file) as fh:
    content = fh.read()
print(json.dumps({'tool_name': 'Write', 'tool_input': {'file_path': fp, 'content': content}}))
" "$1" "$2"
}

# Build an Edit JSON payload given file_path, old_string_file, new_string_file
edit_payload() {
  python3 -c "
import json, sys
fp = sys.argv[1]
with open(sys.argv[2]) as fh:
    old = fh.read()
with open(sys.argv[3]) as fh:
    new = fh.read()
print(json.dumps({'tool_name': 'Edit', 'tool_input': {'file_path': fp, 'old_string': old, 'new_string': new}}))
" "$1" "$2" "$3"
}

setup() {
  load 'helpers/setup'
  setup_temp_home
  mkdir -p "$HOME/.claude/logs"
  unset CLAUDE_SUBPROCESS
}

teardown() {
  teardown_temp_home
}

# ---------------------------------------------------------------------------
# Test 1: Write to CHANGELOG.md — 100-line file, 5-line new content → exit 2 (blocked)
# ---------------------------------------------------------------------------

@test "Write to CHANGELOG.md reducing 100 lines to 5 → blocked (exit 2)" {
  local disk_file new_file
  disk_file="$(make_temp_file_with_lines 100)"
  # The file_path we pass to the guard; disk_file IS the file on disk
  local changelog_path="$disk_file"
  # rename so basename is CHANGELOG.md
  local cl_path
  cl_path="${BATS_TMPDIR}/CHANGELOG_t1_$$.md"
  cp "$disk_file" "$cl_path"
  # Make the guard look at cl_path but the basename must be CHANGELOG.md; use a symlink
  local cl_named
  cl_named="${BATS_TMPDIR}/CHANGELOG.md_t1_$$"
  # Simpler: just use a dir so the path basename is CHANGELOG.md
  local dir
  dir="$(mktemp -d)"
  cp "$disk_file" "$dir/CHANGELOG.md"
  new_file="$(make_temp_file_with_lines 5)"

  local json
  json="$(write_payload "$dir/CHANGELOG.md" "$new_file")"

  run env CAST_WG_INPUT="$json" python3 "$GUARD"
  assert_failure
  assert_equal "$status" 2
  assert_output --partial "CAST DESTROY GUARD"

  rm -f "$disk_file" "$new_file"
  rm -rf "$dir"
}

# ---------------------------------------------------------------------------
# Test 2: Same scenario but new content contains [docs-destroy-ok] → exit 0
# ---------------------------------------------------------------------------

@test "Write to CHANGELOG.md with [docs-destroy-ok] token → allowed (exit 0)" {
  local dir new_file
  dir="$(mktemp -d)"
  python3 -c "print('\n'.join('line {}'.format(i) for i in range(1, 101)))" > "$dir/CHANGELOG.md"
  new_file="$(mktemp)"
  python3 -c "print('line 1\n[docs-destroy-ok]')" > "$new_file"

  local json
  json="$(write_payload "$dir/CHANGELOG.md" "$new_file")"

  run env CAST_WG_INPUT="$json" python3 "$GUARD"
  assert_success

  rm -f "$new_file"
  rm -rf "$dir"
}

# ---------------------------------------------------------------------------
# Test 3: Edit on docs/foo.md — old_string 60 lines, new_string 5 lines → exit 2
# ---------------------------------------------------------------------------

@test "Edit on docs/foo.md reducing 60 lines to 5 → blocked (exit 2)" {
  local old_file new_file
  old_file="$(make_temp_file_with_lines 60)"
  new_file="$(make_temp_file_with_lines 5)"

  local json
  json="$(edit_payload "/some/project/docs/foo.md" "$old_file" "$new_file")"

  run env CAST_WG_INPUT="$json" python3 "$GUARD"
  assert_failure
  assert_equal "$status" 2
  assert_output --partial "CAST DESTROY GUARD"

  rm -f "$old_file" "$new_file"
}

# ---------------------------------------------------------------------------
# Test 4: Small deletion (5 lines) on CHANGELOG.md via Edit → exit 0
# ---------------------------------------------------------------------------

@test "Edit on CHANGELOG.md deleting only 5 lines → allowed (exit 0)" {
  local old_file new_file
  old_file="$(make_temp_file_with_lines 10)"
  new_file="$(make_temp_file_with_lines 5)"

  local json
  json="$(edit_payload "/repo/CHANGELOG.md" "$old_file" "$new_file")"

  run env CAST_WG_INPUT="$json" python3 "$GUARD"
  assert_success

  rm -f "$old_file" "$new_file"
}

# ---------------------------------------------------------------------------
# Test 5: Big deletion on non-guarded path (scripts/foo.py) → exit 0
# ---------------------------------------------------------------------------

@test "Write to scripts/foo.py with 95-line deletion → not guarded (exit 0)" {
  local dir new_file
  dir="$(mktemp -d)"
  python3 -c "print('\n'.join('line {}'.format(i) for i in range(1, 101)))" > "$dir/foo.py"
  new_file="$(make_temp_file_with_lines 5)"

  local json
  json="$(write_payload "$dir/foo.py" "$new_file")"

  run env CAST_WG_INPUT="$json" python3 "$GUARD"
  assert_success

  rm -f "$new_file"
  rm -rf "$dir"
}

# ---------------------------------------------------------------------------
# Test 6: CAST_DOCS_DELETE_THRESHOLD=200 — 100-line deletion on CHANGELOG.md → exit 0
# ---------------------------------------------------------------------------

@test "CHANGELOG.md with 95-line deletion but threshold=200 → allowed (exit 0)" {
  local dir new_file
  dir="$(mktemp -d)"
  python3 -c "print('\n'.join('line {}'.format(i) for i in range(1, 101)))" > "$dir/CHANGELOG.md"
  new_file="$(make_temp_file_with_lines 5)"

  local json
  json="$(write_payload "$dir/CHANGELOG.md" "$new_file")"

  run env CAST_WG_INPUT="$json" CAST_DOCS_DELETE_THRESHOLD=200 python3 "$GUARD"
  assert_success

  rm -f "$new_file"
  rm -rf "$dir"
}

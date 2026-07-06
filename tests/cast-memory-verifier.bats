#!/usr/bin/env bats
# cast-memory-verifier.bats — Tests for scripts/cast_memory_verifier.py
#
# Isolation: uses setup_temp_home/teardown_temp_home (HOME redirected to tmp).
# Coverage:
#   (a) empty input          → valid JSON, paths_checked=0, missing=[], delta=0.0
#   (b) CAST_MEMORY_CONTENT  → env var used over stdin; missing paths detected
#   (c) existing paths       → found on disk, not in missing list
#   (d) non-existent paths   → added to missing list with "path:" prefix
#   (e) function names       → counted in paths_checked but never in missing
#   (f) confidence_delta     → -0.2 per missing path; 0.0 when none missing
#   (g) stdin fallback       → content read from stdin when env var absent
#   (h) output is valid JSON with required keys at all times

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_DIR/scripts/cast_memory_verifier.py"

# ---------------------------------------------------------------------------
# Setup / Teardown
# ---------------------------------------------------------------------------

setup() {
  load 'helpers/setup'
  setup_temp_home
  mkdir -p "$HOME/.claude/logs"
  # Create a sentinel file directly in temp HOME for "existing path" tests.
  # Must start with a word character so the regex's \b anchor matches it.
  touch "$HOME/cast-test-existing.py"
}

teardown() {
  teardown_temp_home
}

# ---------------------------------------------------------------------------
# JSON helpers
# ---------------------------------------------------------------------------

# Extract a top-level key from JSON output.  $1=key, reads from "$output".
json_get() {
  local key="$1"
  printf '%s' "$output" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['$key'])"
}

# ---------------------------------------------------------------------------
# (a) Empty input → valid JSON baseline
# ---------------------------------------------------------------------------

@test "(a) empty stdin returns valid JSON with paths_checked=0" {
  run bash -c "printf '' | python3 '$SCRIPT'"
  assert_success
  run bash -c "printf '' | python3 '$SCRIPT' | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d[\"paths_checked\"])'"
  assert_success
  assert_output "0"
}

@test "(a) empty stdin: missing list is empty" {
  run bash -c "printf '' | python3 '$SCRIPT' | python3 -c 'import sys,json; d=json.load(sys.stdin); print(len(d[\"missing\"]))'"
  assert_success
  assert_output "0"
}

@test "(a) empty stdin: confidence_delta is 0.0" {
  run bash -c "printf '' | python3 '$SCRIPT' | python3 -c 'import sys,json; d=json.load(sys.stdin); v=d[\"confidence_delta\"]; sys.exit(0 if float(v)==0.0 else 1)'"
  assert_success
}

@test "(a) empty CAST_MEMORY_CONTENT env var returns valid JSON" {
  run env CAST_MEMORY_CONTENT="" python3 "$SCRIPT"
  assert_success
  run bash -c "CAST_MEMORY_CONTENT='' python3 '$SCRIPT' | python3 -m json.tool > /dev/null"
  assert_success
}

# ---------------------------------------------------------------------------
# (b) CAST_MEMORY_CONTENT env var takes precedence over stdin
# ---------------------------------------------------------------------------

@test "(b) CAST_MEMORY_CONTENT env var is used when set" {
  # stdin has no paths; env var has a non-existent path → missing list should be non-empty
  local content
  content="The file ghost-nonexistent-xyz.py is mentioned here."
  run bash -c "printf 'no paths here' | CAST_MEMORY_CONTENT='$content' python3 '$SCRIPT' | python3 -c 'import sys,json; d=json.load(sys.stdin); print(len(d[\"missing\"]))'"
  assert_success
  # missing should have at least one entry from env content
  [ "$output" -ge 1 ]
}

@test "(b) non-existent path in CAST_MEMORY_CONTENT appears in missing with 'path:' prefix" {
  local path_name="definitely-missing-file.py"
  run bash -c "CAST_MEMORY_CONTENT='See $path_name for details.' python3 '$SCRIPT' | python3 -c \"import sys,json; d=json.load(sys.stdin); print('path:$path_name' in d['missing'])\""
  assert_success
  assert_output "True"
}

# ---------------------------------------------------------------------------
# (c) Existing paths on disk → not in missing list
# ---------------------------------------------------------------------------

@test "(c) relative-style path that exists in HOME is not in missing" {
  # cast-test-existing.py is created in temp HOME by setup().
  # The regex extracts it (starts with 'c', a word char) and the verifier
  # resolves it via os.path.join(expanduser('~'), path_str) → found.
  run bash -c "CAST_MEMORY_CONTENT='See cast-test-existing.py for details.' python3 '$SCRIPT' | python3 -c \"import sys,json; d=json.load(sys.stdin); print(len([m for m in d['missing'] if 'cast-test-existing' in m]))\""
  assert_success
  assert_output "0"
}

@test "(c) existing file not in missing; paths_checked >= 1" {
  run bash -c "CAST_MEMORY_CONTENT='The file cast-test-existing.py is present.' python3 '$SCRIPT' | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d[\"paths_checked\"] >= 1)'"
  assert_success
  assert_output "True"
}

# ---------------------------------------------------------------------------
# (d) Non-existent paths → added to missing list
# ---------------------------------------------------------------------------

@test "(d) non-existent path is in the missing list" {
  run bash -c "CAST_MEMORY_CONTENT='Load scripts/does-not-exist.py now.' python3 '$SCRIPT' | python3 -c \"import sys,json; d=json.load(sys.stdin); print(any('does-not-exist.py' in m for m in d['missing']))\""
  assert_success
  assert_output "True"
}

@test "(d) missing entry uses 'path:' prefix" {
  run bash -c "CAST_MEMORY_CONTENT='See phantom-script.sh somewhere.' python3 '$SCRIPT' | python3 -c \"import sys,json; d=json.load(sys.stdin); print(any(m.startswith('path:') for m in d['missing']))\""
  assert_success
  assert_output "True"
}

@test "(d) two non-existent paths → missing list has 2 entries" {
  local content="Load nope-a.py and also nope-b.sh from somewhere."
  run bash -c "CAST_MEMORY_CONTENT='$content' python3 '$SCRIPT' | python3 -c 'import sys,json; d=json.load(sys.stdin); print(len(d[\"missing\"]))'"
  assert_success
  assert_output "2"
}

# ---------------------------------------------------------------------------
# (e) Function names — counted in paths_checked, never in missing
# ---------------------------------------------------------------------------

@test "(e) function names counted in paths_checked" {
  # Content has one function declaration and no file paths
  local content="def my_helper_function processes the data."
  run bash -c "CAST_MEMORY_CONTENT='$content' python3 '$SCRIPT' | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d[\"paths_checked\"] >= 1)'"
  assert_success
  assert_output "True"
}

@test "(e) function names are never in the missing list" {
  local content="function setup_temp_home and def teardown_func are defined here."
  run bash -c "CAST_MEMORY_CONTENT='$content' python3 '$SCRIPT' | python3 -c 'import sys,json; d=json.load(sys.stdin); print(len(d[\"missing\"]))'"
  assert_success
  assert_output "0"
}

@test "(e) function names do not affect confidence_delta" {
  local content="def compute_score and function check_path do heavy lifting."
  run bash -c "CAST_MEMORY_CONTENT='$content' python3 '$SCRIPT' | python3 -c 'import sys,json; d=json.load(sys.stdin); v=d[\"confidence_delta\"]; sys.exit(0 if float(v)==0.0 else 1)'"
  assert_success
}

# ---------------------------------------------------------------------------
# (f) confidence_delta calculation
# ---------------------------------------------------------------------------

@test "(f) one missing path → confidence_delta is -0.2" {
  local content="Missing file is nope-single.py right here."
  run bash -c "CAST_MEMORY_CONTENT='$content' python3 '$SCRIPT' | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d[\"confidence_delta\"])'"
  assert_success
  assert_output -- "-0.2"
}

@test "(f) two missing paths → confidence_delta is -0.4" {
  local content="Files nope-x.py and nope-y.sh are both missing."
  run bash -c "CAST_MEMORY_CONTENT='$content' python3 '$SCRIPT' | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d[\"confidence_delta\"])'"
  assert_success
  assert_output -- "-0.4"
}

@test "(f) no missing paths → confidence_delta is 0" {
  run bash -c "printf '' | python3 '$SCRIPT' | python3 -c 'import sys,json; d=json.load(sys.stdin); v=d[\"confidence_delta\"]; sys.exit(0 if float(v)==0.0 else 1)'"
  assert_success
}

# ---------------------------------------------------------------------------
# (g) stdin fallback when CAST_MEMORY_CONTENT is unset
# ---------------------------------------------------------------------------

@test "(g) stdin is read when CAST_MEMORY_CONTENT is unset" {
  # Pass a non-existent path via stdin; expect it to show up in missing
  local content="The file only-in-stdin.py matters here."
  run bash -c "printf '%s' '$content' | env -u CAST_MEMORY_CONTENT python3 '$SCRIPT' | python3 -c \"import sys,json; d=json.load(sys.stdin); print(any('only-in-stdin.py' in m for m in d['missing']))\""
  assert_success
  assert_output "True"
}

@test "(g) stdin read succeeds on empty stream without error" {
  run bash -c "printf '' | env -u CAST_MEMORY_CONTENT python3 '$SCRIPT'"
  assert_success
}

# ---------------------------------------------------------------------------
# (h) Output is always valid JSON with required keys
# ---------------------------------------------------------------------------

@test "(h) output is valid JSON" {
  run bash -c "printf '' | python3 '$SCRIPT' | python3 -m json.tool > /dev/null"
  assert_success
}

@test "(h) output contains required key: paths_checked" {
  run bash -c "printf '' | python3 '$SCRIPT' | python3 -c 'import sys,json; d=json.load(sys.stdin); assert \"paths_checked\" in d'"
  assert_success
}

@test "(h) output contains required key: missing" {
  run bash -c "printf '' | python3 '$SCRIPT' | python3 -c 'import sys,json; d=json.load(sys.stdin); assert \"missing\" in d'"
  assert_success
}

@test "(h) output contains required key: confidence_delta" {
  run bash -c "printf '' | python3 '$SCRIPT' | python3 -c 'import sys,json; d=json.load(sys.stdin); assert \"confidence_delta\" in d'"
  assert_success
}

@test "(h) output is valid JSON even when content has malformed paths" {
  local content="A bad/path without extension and another-path.xyz with unknown extension."
  run bash -c "CAST_MEMORY_CONTENT='$content' python3 '$SCRIPT' | python3 -m json.tool > /dev/null"
  assert_success
}

@test "(h) missing list contains only strings" {
  local content="Load missing-file.py and also other-missing.sh here."
  run bash -c "CAST_MEMORY_CONTENT='$content' python3 '$SCRIPT' | python3 -c 'import sys,json; d=json.load(sys.stdin); assert all(isinstance(m,str) for m in d[\"missing\"]), \"non-string in missing\"'"
  assert_success
}

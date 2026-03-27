#!/usr/bin/env bats
# Tests for parallel post_chain serialization (B2 fix — Phase 9.75a)
#
# Coverage:
#   - Nested arrays in post_chain are formatted as [`a`, `b`] not as Python list strings
#   - Mixed chains (parallel then sequential) produce correct directive text
#   - Single-element chains work as before
#
# Strategy: test the serialization logic directly via Python (same logic used in route.sh)
# and verify the route.sh source contains the correct isinstance detection.

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
ROUTE_SH="$REPO_DIR/scripts/route.sh"

# ---------------------------------------------------------------------------
# Helper: run the post_chain serializer with given chain JSON
# Mirrors the logic extracted from route.sh lines 528-535
# ---------------------------------------------------------------------------

serialize_post_chain() {
  local chain_json="$1"
  python3 <<PYEOF
import json
post_chain = json.loads('$chain_json')
parts = []
for step in post_chain:
    if isinstance(step, list):
        parts.append('[' + ', '.join(f'\`{a}\`' for a in step) + ']')
    else:
        parts.append(f'\`{step}\`')
chain_str = ' -> '.join(parts)
print(chain_str)
PYEOF
}

# ---------------------------------------------------------------------------
# B2 — serialization correctness
# ---------------------------------------------------------------------------

@test "nested array step formats as backtick bracket list" {
  run serialize_post_chain '[["code-reviewer", "security"], "commit"]'
  assert_success
  assert_output '[`code-reviewer`, `security`] -> `commit`'
}

@test "nested array does NOT produce Python list string" {
  run serialize_post_chain '[["code-reviewer", "security"], "commit"]'
  assert_success
  refute_output --partial "['code-reviewer', 'security']"
}

@test "single-string chain formats as single backtick agent" {
  run serialize_post_chain '["commit"]'
  assert_success
  assert_output '`commit`'
}

@test "multiple sequential strings format correctly" {
  run serialize_post_chain '["code-reviewer", "commit"]'
  assert_success
  assert_output '`code-reviewer` -> `commit`'
}

@test "fully parallel chain with two parallel batches" {
  run serialize_post_chain '[["code-reviewer", "security"], ["test-writer", "debugger"]]'
  assert_success
  assert_output '[`code-reviewer`, `security`] -> [`test-writer`, `debugger`]'
}

@test "single-agent parallel batch (bracket notation preserved)" {
  run serialize_post_chain '[["code-reviewer"], "commit"]'
  assert_success
  assert_output '[`code-reviewer`] -> `commit`'
}

# ---------------------------------------------------------------------------
# B2 — source-level verification
# ---------------------------------------------------------------------------

@test "route.sh contains isinstance(step, list) detection" {
  run grep -n 'isinstance.*step.*list\|isinstance.*list' "$ROUTE_SH"
  assert_success
}

@test "route.sh builds bracket notation for parallel steps" {
  run grep -n "parts.append.*\[.*\`" "$ROUTE_SH"
  assert_success
  assert_output --partial 'parts.append'
}

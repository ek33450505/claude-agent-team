#!/usr/bin/env bats

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
HOOK_SH="$REPO_DIR/scripts/cast-teammate-idle-hook.sh"

make_payload() {
  local result="${1:-}"
  python3 -c "
import json, sys
print(json.dumps({'result': sys.argv[1]}))
" "$result"
}

setup() {
  export ORIG_HOME="$HOME"
  export HOME="$(realpath "$(mktemp -d)")"
  mkdir -p "$HOME/.claude/scripts"
  # Stub cast-events.sh so DB logging is a no-op in tests
  cat > "$HOME/.claude/scripts/cast-events.sh" <<'STUB'
cast_emit_event() { return 0; }
STUB
}

teardown() {
  rm -rf "$HOME"
  export HOME="$ORIG_HOME"
}

# ---------------------------------------------------------------------------
# 1. Empty result → exit 2 (block)
# ---------------------------------------------------------------------------

@test "empty result → exit 2 with feedback" {
  run bash "$HOOK_SH" <<< "$(make_payload "")"
  assert_failure 2
  assert_output --partial "no output"
}

# ---------------------------------------------------------------------------
# 2. Result with TODO → exit 2 (block)
# ---------------------------------------------------------------------------

@test "result containing TODO → exit 2 with feedback" {
  run bash "$HOOK_SH" <<< "$(make_payload "Here is my result but TODO finish this part")"
  assert_failure 2
  assert_output --partial "placeholder"
}

# ---------------------------------------------------------------------------
# 3. Result with PLACEHOLDER → exit 2 (block)
# ---------------------------------------------------------------------------

@test "result containing PLACEHOLDER → exit 2 with feedback" {
  run bash "$HOOK_SH" <<< "$(make_payload "PLACEHOLDER: implement later")"
  assert_failure 2
  assert_output --partial "placeholder"
}

# ---------------------------------------------------------------------------
# 4. Valid non-empty result → exit 0 (pass)
# ---------------------------------------------------------------------------

@test "valid non-empty result → exit 0" {
  run bash "$HOOK_SH" <<< "$(make_payload "The task is complete. All files written successfully.")"
  assert_success
}

# ---------------------------------------------------------------------------
# 5. Script is executable
# ---------------------------------------------------------------------------

@test "hook script is executable" {
  [ -x "$HOOK_SH" ]
}

# ---------------------------------------------------------------------------
# 6. Missing 'result' field → exit 2 (treated as empty)
# ---------------------------------------------------------------------------

@test "missing result field in JSON → exit 2" {
  run bash "$HOOK_SH" <<< '{"other_field": "value"}'
  assert_failure 2
}

# ---------------------------------------------------------------------------
# 7. Invalid JSON → exits without crash (set -euo pipefail safe)
# ---------------------------------------------------------------------------

@test "invalid JSON input → exits without crash" {
  run bash "$HOOK_SH" <<< "not valid json"
  # May exit 2 (empty result path) or 1 — must not exit > 2 or unhandled
  [ "$status" -le 2 ]
}

#!/usr/bin/env bats
# tests/cast-time-drift-hook.bats — UserPromptSubmit drift-correction hook.
#
# HARD RULE: never touches the real $HOME. Every run is isolated to a temp dir.

SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/scripts/cast-time-drift-hook.sh"

setup() {
  TMPDIR_TEST="$(mktemp -d -p "${TMPDIR:-/tmp}")" || TMPDIR_TEST="$(mktemp -d)"
  export HOME="$TMPDIR_TEST"
  mkdir -p "$HOME/.claude/logs"
  export CAST_TIME_STATE_DIR="$TMPDIR_TEST/state"
  SID="probe-session"
  STATE="$CAST_TIME_STATE_DIR/$SID"
  PAYLOAD="{\"session_id\":\"$SID\"}"
}

teardown() {
  rm -rf "$TMPDIR_TEST"
}

# Extract additionalContext, or print <SILENT> when the hook emitted nothing.
_ctx() {
  python3 -c '
import json, sys
raw = sys.stdin.read().strip()
if not raw:
    print("<SILENT>")
else:
    print(json.loads(raw)["hookSpecificOutput"]["additionalContext"])
'
}

_seed() { # $1=start_epoch $2=last_epoch $3=last_date
  mkdir -p "$CAST_TIME_STATE_DIR"
  printf '%s|%s|%s\n' "$1" "$2" "$3" > "$STATE"
}

@test "subprocess guard: CLAUDE_SUBPROCESS=1 exits 0 silently" {
  run env CLAUDE_SUBPROCESS=1 bash "$SCRIPT" <<< "$PAYLOAD"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "first prompt of a session seeds state and stays silent" {
  run bash -c "printf '%s' '$PAYLOAD' | bash '$SCRIPT'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -f "$STATE" ]
}

@test "a prompt well inside the window stays silent" {
  NOW=$(date +%s)
  _seed "$((NOW - 600))" "$((NOW - 60))" "$(date +%Y-%m-%d)"
  run bash -c "printf '%s' '$PAYLOAD' | bash '$SCRIPT'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "elapsed beyond the threshold re-injects valid UserPromptSubmit JSON" {
  NOW=$(date +%s)
  _seed "$((NOW - 21600))" "$((NOW - 14400))" "$(date +%Y-%m-%d)"
  run bash -c "printf '%s' '$PAYLOAD' | bash '$SCRIPT'"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  EVENT=$(echo "$output" | python3 -c 'import json,sys; print(json.load(sys.stdin)["hookSpecificOutput"]["hookEventName"])')
  [ "$EVENT" = "UserPromptSubmit" ]
  CONTEXT=$(echo "$output" | _ctx)
  [[ "$CONTEXT" == *"gone stale"* ]]
  [[ "$CONTEXT" == *"Elapsed (since first prompt):"* ]]
}

@test "a date rollover re-injects and says the earlier dates were wrong" {
  NOW=$(date +%s)
  _seed "$((NOW - 36000))" "$((NOW - 3600))" "1999-01-01"
  run bash -c "printf '%s' '$PAYLOAD' | bash '$SCRIPT'"
  [ "$status" -eq 0 ]
  CONTEXT=$(echo "$output" | _ctx)
  [[ "$CONTEXT" == *"local date changed"* ]]
  [[ "$CONTEXT" == *"1999-01-01"* ]]
  [[ "$CONTEXT" == *"used the wrong day"* ]]
}

@test "re-injection updates last_epoch so it does not fire twice in a row" {
  NOW=$(date +%s)
  _seed "$((NOW - 21600))" "$((NOW - 14400))" "$(date +%Y-%m-%d)"
  run bash -c "printf '%s' '$PAYLOAD' | bash '$SCRIPT'"
  [ -n "$output" ]
  # Immediately again: the window has been reset, so this one must be silent.
  run bash -c "printf '%s' '$PAYLOAD' | bash '$SCRIPT'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "elapsed is measured from start_epoch, not from the last injection" {
  NOW=$(date +%s)
  # started 10h ago, last injected 4h ago -> elapsed must read ~10h, not ~4h
  _seed "$((NOW - 36000))" "$((NOW - 14400))" "$(date +%Y-%m-%d)"
  run bash -c "printf '%s' '$PAYLOAD' | bash '$SCRIPT'"
  CONTEXT=$(echo "$output" | _ctx)
  [[ "$CONTEXT" == *"Elapsed (since first prompt): 10h"* ]]
}

@test "CAST_TIME_DRIFT_SECONDS is honoured" {
  NOW=$(date +%s)
  _seed "$((NOW - 600))" "$((NOW - 300))" "$(date +%Y-%m-%d)"
  # 300s elapsed is inside the 3h default, but beyond a 60s override.
  run bash -c "printf '%s' '$PAYLOAD' | CAST_TIME_DRIFT_SECONDS=60 bash '$SCRIPT'"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

@test "a corrupt state file is repaired without emitting or failing" {
  mkdir -p "$CAST_TIME_STATE_DIR"
  echo "garbage-not-a-state-file" > "$STATE"
  run bash -c "printf '%s' '$PAYLOAD' | bash '$SCRIPT'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run cat "$STATE"
  [[ "$output" =~ ^[0-9]+\|[0-9]+\|[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]
}

@test "empty stdin does not fail the hook" {
  run bash -c "printf '' | bash '$SCRIPT'"
  [ "$status" -eq 0 ]
}

@test "malformed JSON on stdin does not fail the hook" {
  run bash -c "printf 'not json at all' | bash '$SCRIPT'"
  [ "$status" -eq 0 ]
}

@test "a session_id containing path separators cannot escape the state dir" {
  EVIL='{"session_id":"../../../../etc/passwd"}'
  PARENT="$(dirname "$CAST_TIME_STATE_DIR")"
  mkdir -p "$CAST_TIME_STATE_DIR"
  BEFORE="$(ls -A "$PARENT" | sort)"

  run bash -c "printf '%s' '$EVIL' | bash '$SCRIPT'"
  [ "$status" -eq 0 ]

  # Nothing appeared outside the state dir.
  AFTER="$(ls -A "$PARENT" | sort)"
  [ "$BEFORE" = "$AFTER" ]

  # Nothing nested itself below the state dir.
  run find "$CAST_TIME_STATE_DIR" -mindepth 2
  [ -z "$output" ]

  # The separators were REPLACED, not interpreted: the state file is a single
  # flat entry whose name still carries the sanitised payload.
  # (Do NOT assert on a resolved path like "$STATE_DIR/../../../../etc/passwd" —
  # that clamps at / and tests whether /etc/passwd exists, not what this hook did.)
  # `wc -l` on empty output still reports 1, so count with find, not echo.
  run bash -c "find '$CAST_TIME_STATE_DIR' -maxdepth 1 -type f | wc -l | tr -d ' '"
  [ "$output" = "1" ]
  run bash -c "find '$CAST_TIME_STATE_DIR' -maxdepth 1 -type f -exec basename {} ';'"
  [[ "$output" == *"etc_passwd"* ]]
  [[ "$output" != *"/"* ]]
}

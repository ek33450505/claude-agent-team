#!/usr/bin/env bats
# Tests for cast-precompact-memory-save.sh
# Verifies the script archives the real transcript_path field from the PreCompact payload,
# stores it off-blast-radius (NOT inside ~/.claude/), and always lets compaction proceed
# (proceed contract: NO stdout, exit 0 - the top-level "decision" field accepts only approve|block).

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

# `run --separate-stderr` (Bats >= 1.5.0): $output is STDOUT ONLY, which is the stream Claude Code
# validates for a PreCompact hook.
bats_require_minimum_version 1.5.0

SCRIPT="$BATS_TEST_DIRNAME/../scripts/cast-precompact-memory-save.sh"

setup() {
  load 'helpers/setup'
  setup_temp_home
  mkdir -p "$HOME/.claude/logs"
  # Ensure the macOS Library path exists inside the temp home
  mkdir -p "$HOME/Library/Application Support/cast/precompact-archives"
}

teardown() {
  teardown_temp_home
}

# PreCompact proceed contract (Claude Code): print NOTHING on stdout and exit 0. The top-level
# "decision" field accepts only "approve"|"block", so {"decision":"allow"} is rejected by hook-output
# validation ("Invalid option: expected one of approve|block"). Use after `run --separate-stderr`.
assert_proceeds() {
  assert_success
  [ -z "$output" ] || {
    echo "expected empty stdout, got: $output" >&2
    return 1
  }
}

# The schema Claude Code enforces on hook stdout: empty, OR a JSON object whose top-level
# "decision", if present, is exactly "approve" or "block". Arg: the captured stdout text.
_decision_schema_ok() { # text
  [ -z "$1" ] && return 0
  printf '%s' "$1" | python3 -I -c '
import json, sys
d = json.load(sys.stdin)
if not isinstance(d, dict):
    sys.exit(1)
sys.exit(0 if ("decision" not in d or d["decision"] in ("approve", "block")) else 1)
' 2> /dev/null
}

# ---------------------------------------------------------------------------

@test "empty stdin -> exit 0 and proceeds (no stdout, fail-open)" {
  run --separate-stderr bash "$SCRIPT" <<< ''
  assert_proceeds
}

@test "malformed JSON -> exit 0 and proceeds (no stdout, fail-open)" {
  run --separate-stderr bash "$SCRIPT" <<< '{ not valid json !!'
  assert_proceeds
}

@test "valid payload with transcript_path -> exit 0, proceeds (no stdout) AND archive file created" {
  # Create a real temp transcript file
  local transcript_src
  transcript_src="$(mktemp -t precompact-transcript.XXXXXX).jsonl"
  printf '{"type":"human","text":"hello"}\n{"type":"assistant","text":"world"}\n' > "$transcript_src"

  local payload
  payload="$(printf '{"hook_event_name":"PreCompact","session_id":"test-session-abc","transcript_path":"%s","cwd":"/tmp","permission_mode":"default"}' "$transcript_src")"

  run --separate-stderr bash "$SCRIPT" <<< "$payload"
  assert_proceeds

  # An archive file must exist under $HOME/Library/Application Support/cast/precompact-archives/
  local archive_dir="$HOME/Library/Application Support/cast/precompact-archives"
  local archive_count
  archive_count="$(find "$archive_dir" -name "test-session-abc-*.jsonl" 2>/dev/null | wc -l | tr -d ' ')"
  [ "$archive_count" -ge 1 ]

  # Archive contents must match the source transcript
  local archive_file
  archive_file="$(find "$archive_dir" -name "test-session-abc-*.jsonl" 2>/dev/null | head -1)"
  diff "$transcript_src" "$archive_file"

  rm -f "$transcript_src"
}

@test "payload missing transcript_path -> exit 0, no archive written, no crash" {
  local payload='{"hook_event_name":"PreCompact","session_id":"sess-no-transcript","cwd":"/tmp","permission_mode":"default"}'

  run --separate-stderr bash "$SCRIPT" <<< "$payload"
  assert_proceeds

  # No archive file should have been created
  local archive_dir="$HOME/Library/Application Support/cast/precompact-archives"
  local archive_count
  archive_count="$(find "$archive_dir" -name "sess-no-transcript-*" 2>/dev/null | wc -l | tr -d ' ')"
  [ "$archive_count" -eq 0 ]
}

@test "nothing is written under \$HOME/.claude/agent-memory-local/ (off-blast-radius proof)" {
  # Create a real transcript file
  local transcript_src
  transcript_src="$(mktemp -t precompact-transcript.XXXXXX).jsonl"
  printf '{"type":"human","text":"test"}\n' > "$transcript_src"

  local payload
  payload="$(printf '{"hook_event_name":"PreCompact","session_id":"blast-radius-check","transcript_path":"%s","cwd":"/tmp","permission_mode":"default"}' "$transcript_src")"

  bash "$SCRIPT" <<< "$payload"

  # The old inside-~/.claude snapshot dir MUST NOT exist or be populated
  local legacy_dir="$HOME/.claude/agent-memory-local"
  local snapshot_count=0
  if [[ -d "$legacy_dir" ]]; then
    snapshot_count="$(find "$legacy_dir" -type f 2>/dev/null | wc -l | tr -d ' ')"
  fi
  [ "$snapshot_count" -eq 0 ]

  rm -f "$transcript_src"
}

@test "payload with empty string transcript_path -> exit 0, no crash" {
  local payload='{"hook_event_name":"PreCompact","session_id":"empty-path-sess","transcript_path":"","cwd":"/tmp","permission_mode":"default"}'

  run --separate-stderr bash "$SCRIPT" <<< "$payload"
  assert_proceeds
}

@test "malicious session_id with ../ does NOT escape archive dir — filename is sanitized" {
  # Create a real transcript file
  local transcript_src
  transcript_src="$(mktemp -t precompact-transcript.XXXXXX).jsonl"
  printf '{"type":"human","text":"test"}\n' > "$transcript_src"

  # session_id containing path traversal attempt: "../../tmp/evil"
  # After sanitization all non-[A-Za-z0-9_-] chars become '_', yielding "____tmp_evil"
  local payload
  payload="$(printf '{"hook_event_name":"PreCompact","session_id":"../../tmp/evil","transcript_path":"%s","cwd":"/tmp","permission_mode":"default"}' "$transcript_src")"

  run --separate-stderr bash "$SCRIPT" <<< "$payload"
  assert_proceeds

  local archive_dir="$HOME/Library/Application Support/cast/precompact-archives"

  # An archive file must exist inside the archive dir
  local archive_count
  archive_count="$(find "$archive_dir" -maxdepth 1 -name "*.jsonl" 2>/dev/null | wc -l | tr -d ' ')"
  [ "$archive_count" -ge 1 ]

  # The archive filename must NOT contain '..' or '/' (sanitized)
  local archive_name
  archive_name="$(find "$archive_dir" -maxdepth 1 -name "*.jsonl" 2>/dev/null | head -1 | xargs basename 2>/dev/null || true)"
  [[ "$archive_name" != *".."* ]]
  [[ "$archive_name" != *"/"* ]]

  # Nothing written outside the archive dir (path traversal blocked)
  [ ! -f "/tmp/evil" ]
  [ ! -f "$HOME/tmp/evil" ]

  rm -f "$transcript_src"
}

@test "stdout satisfies the Claude Code decision schema (empty, or decision approve|block) on every proceed path" {
  # CONTROL: the validator can fail - the rejected legacy output and non-JSON stdout do not pass.
  if _decision_schema_ok '{"decision":"allow"}'; then
    echo "validator accepted decision=allow" >&2
    return 1
  fi
  if _decision_schema_ok 'not json'; then
    echo "validator accepted non-JSON stdout" >&2
    return 1
  fi
  local transcript_src
  transcript_src="$(mktemp -t precompact-transcript.XXXXXX).jsonl"
  printf '{"type":"human","text":"hello"}\n' > "$transcript_src"
  local payload
  payload="$(printf '{"hook_event_name":"PreCompact","session_id":"schema-sess","transcript_path":"%s","cwd":"/tmp","permission_mode":"default"}' "$transcript_src")"

  # archive path (reaches the final exit)
  run --separate-stderr bash "$SCRIPT" <<< "$payload"
  assert_proceeds
  _decision_schema_ok "$output"
  # empty stdin path
  run --separate-stderr bash "$SCRIPT" <<< ''
  assert_proceeds
  _decision_schema_ok "$output"
  # missing transcript_path path
  run --separate-stderr bash "$SCRIPT" <<< '{"hook_event_name":"PreCompact","session_id":"schema-nopath"}'
  assert_proceeds
  _decision_schema_ok "$output"

  rm -f "$transcript_src"
}

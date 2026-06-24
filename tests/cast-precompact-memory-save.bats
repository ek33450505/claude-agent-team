#!/usr/bin/env bats
# Tests for cast-precompact-memory-save.sh
# Verifies the script archives the real transcript_path field from the PreCompact payload,
# stores it off-blast-radius (NOT inside ~/.claude/), and always allows compaction.

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

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

# ---------------------------------------------------------------------------

@test "empty stdin -> exit 0 and outputs allow (fail-open)" {
  run bash "$SCRIPT" <<< ''
  assert_success
  assert_output --partial 'allow'
}

@test "malformed JSON -> exit 0 (fail-open)" {
  run bash "$SCRIPT" <<< '{ not valid json !!'
  assert_success
}

@test "valid payload with transcript_path -> exit 0 AND archive file created" {
  # Create a real temp transcript file
  local transcript_src
  transcript_src="$(mktemp -t precompact-transcript.XXXXXX).jsonl"
  printf '{"type":"human","text":"hello"}\n{"type":"assistant","text":"world"}\n' > "$transcript_src"

  local payload
  payload="$(printf '{"hook_event_name":"PreCompact","session_id":"test-session-abc","transcript_path":"%s","cwd":"/tmp","permission_mode":"default"}' "$transcript_src")"

  run bash "$SCRIPT" <<< "$payload"
  assert_success
  assert_output --partial 'allow'

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

  run bash "$SCRIPT" <<< "$payload"
  assert_success
  assert_output --partial 'allow'

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

  run bash "$SCRIPT" <<< "$payload"
  assert_success
  assert_output --partial 'allow'
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

  run bash "$SCRIPT" <<< "$payload"
  assert_success
  assert_output --partial 'allow'

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

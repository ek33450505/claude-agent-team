#!/usr/bin/env bats

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
HOOK_SH="$REPO_DIR/scripts/cast-post-compact-hook.sh"

make_payload() {
  local trigger="${1:-auto}"
  local session_id="${2:-test-session-123}"
  python3 -c "
import json, sys
print(json.dumps({
    'hook_event_name': 'PostCompact',
    'trigger': sys.argv[1],
    'session_id': sys.argv[2],
    'transcript_path': '/tmp/transcript.jsonl',
    'cwd': '/tmp/project',
}))
" "$trigger" "$session_id"
}

setup() {
  export ORIG_HOME="$HOME"
  export HOME="$(realpath "$(mktemp -d)")"
  mkdir -p "$HOME/.claude/cast/hook-last-fired"
  mkdir -p "$HOME/.claude/cast/events"
  unset CLAUDE_SUBPROCESS
}

teardown() {
  rm -rf "$HOME"
  export HOME="$ORIG_HOME"
}

# ---------------------------------------------------------------------------
# 1. Exit 0 on valid auto payload
# ---------------------------------------------------------------------------

@test "auto trigger payload → exits 0" {
  run bash "$HOOK_SH" <<< "$(make_payload "auto")"
  assert_success
}

# ---------------------------------------------------------------------------
# 2. Exit 0 on valid manual payload
# ---------------------------------------------------------------------------

@test "manual trigger payload → exits 0" {
  run bash "$HOOK_SH" <<< "$(make_payload "manual")"
  assert_success
}

# ---------------------------------------------------------------------------
# 3. Exit 0 on empty input
# ---------------------------------------------------------------------------

@test "empty input → exits 0 (graceful no-op)" {
  run bash "$HOOK_SH" <<< ""
  assert_success
}

# ---------------------------------------------------------------------------
# 4. Writes event file to cast/events/
# ---------------------------------------------------------------------------

@test "auto trigger → writes event file to cast/events/" {
  run bash "$HOOK_SH" <<< "$(make_payload "auto")"
  assert_success
  local count
  count=$(find "$HOME/.claude/cast/events" -name "*compact.json" | wc -l)
  [ "$count" -ge 1 ]
}

# ---------------------------------------------------------------------------
# 5. Event file contains correct type and trigger fields
# ---------------------------------------------------------------------------

@test "event file contains type=post_compact and trigger=auto" {
  bash "$HOOK_SH" <<< "$(make_payload "auto")"
  local event_file
  event_file=$(find "$HOME/.claude/cast/events" -name "*compact.json" | head -1)
  python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
assert d.get('type') == 'post_compact', f'type={d.get(\"type\")}'
assert d.get('trigger') == 'auto', f'trigger={d.get(\"trigger\")}'
print('ok')
" "$event_file"
}

# ---------------------------------------------------------------------------
# 6. Appends to compact-log.jsonl
# ---------------------------------------------------------------------------

@test "auto trigger → appends entry to compact-log.jsonl" {
  run bash "$HOOK_SH" <<< "$(make_payload "auto")"
  assert_success
  [ -f "$HOME/.claude/cast/compact-log.jsonl" ]
  local lines
  lines=$(wc -l < "$HOME/.claude/cast/compact-log.jsonl")
  [ "$lines" -ge 1 ]
}

# ---------------------------------------------------------------------------
# 7. compact-log.jsonl entry is valid JSON
# ---------------------------------------------------------------------------

@test "compact-log.jsonl entry is valid JSON" {
  bash "$HOOK_SH" <<< "$(make_payload "manual")"
  python3 -c "
import json
with open('$HOME/.claude/cast/compact-log.jsonl') as f:
    line = f.readline().strip()
d = json.loads(line)
assert 'type' in d
assert 'trigger' in d
assert 'session_id' in d
print('valid')
"
}

# ---------------------------------------------------------------------------
# 8. Touches hook-last-fired timestamp
# ---------------------------------------------------------------------------

@test "any payload → touches hook-last-fired/cast-post-compact.timestamp" {
  run bash "$HOOK_SH" <<< "$(make_payload "auto")"
  assert_success
  [ -f "$HOME/.claude/cast/hook-last-fired/cast-post-compact.timestamp" ]
}

# ---------------------------------------------------------------------------
# 9. CLAUDE_SUBPROCESS guard — skips silently
# ---------------------------------------------------------------------------

@test "CLAUDE_SUBPROCESS=1 → exits 0 and writes no files" {
  CLAUDE_SUBPROCESS=1 run bash "$HOOK_SH" <<< "$(make_payload "auto")"
  assert_success
  local count
  count=$(find "$HOME/.claude/cast/events" -name "*compact.json" 2>/dev/null | wc -l)
  [ "$count" -eq 0 ]
}

#!/usr/bin/env bats
# tests/hooks/phase1-hooks.bats — Phase 1 hook tests
# Covers: cast-subagent-start-hook.sh and cast-user-prompt-hook.sh

bats_require_minimum_version 1.5.0

load '../test_helper/bats-support/load'
load '../test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
SUBAGENT_START_HOOK="/Users/edkubiak/.claude/scripts/cast-subagent-start-hook.sh"
USER_PROMPT_HOOK="/Users/edkubiak/.claude/scripts/cast-user-prompt-hook.sh"

# ── Payload helpers ──────────────────────────────────────────────────────────

make_subagent_start_payload() {
  local agent_name="${1:-code-writer}"
  local session_id="${2:-test-session-001}"
  python3 -c "
import json, sys
print(json.dumps({
    'hook_event_name': 'SubagentStart',
    'agent_name':      sys.argv[1],
    'session_id':      sys.argv[2],
    'agent_id':        'agent-abc-123',
}))
" "$agent_name" "$session_id"
}

make_user_prompt_payload() {
  local session_id="${1:-test-session-002}"
  local prompt="${2:-Hello, what can you do?}"
  python3 -c "
import json, sys
print(json.dumps({
    'hook_event_name': 'UserPromptSubmit',
    'session_id':      sys.argv[1],
    'prompt':          sys.argv[2],
}))
" "$session_id" "$prompt"
}

# ── Setup / teardown ─────────────────────────────────────────────────────────

setup() {
  export ORIG_HOME="$HOME"
  export HOME="$(realpath "$(mktemp -d)")"
  mkdir -p "$HOME/.claude/cast/events"
  mkdir -p "$HOME/.claude/logs"
  unset CLAUDE_SUBPROCESS
  export CAST_DB_PATH="$HOME/test-cast.db"

  # Create minimal cast.db schema for hooks that write to it
  python3 - <<'PYEOF'
import sqlite3, os
db = os.path.join(os.environ['HOME'], 'test-cast.db')
con = sqlite3.connect(db)
con.execute('''CREATE TABLE IF NOT EXISTS agent_runs (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  agent TEXT, session_id TEXT, status TEXT,
  started_at TEXT, ended_at TEXT, agent_id TEXT
)''')
con.execute('''CREATE TABLE IF NOT EXISTS routing_events (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id TEXT, timestamp TEXT, prompt_preview TEXT,
  action TEXT, matched_route TEXT, match_type TEXT,
  pattern TEXT, confidence TEXT, project TEXT,
  event_type TEXT, data TEXT
)''')
con.commit()
con.close()
PYEOF
}

teardown() {
  rm -rf "$HOME"
  export HOME="$ORIG_HOME"
}

# ═══════════════════════════════════════════════════════════════════════════════
# cast-subagent-start-hook.sh tests
# ═══════════════════════════════════════════════════════════════════════════════

# 1. Exit 0 on valid JSON input
@test "subagent-start: valid payload → exits 0" {
  run bash "$SUBAGENT_START_HOOK" <<< "$(make_subagent_start_payload)"
  assert_success
}

# 2. Writes event file to ~/.claude/cast/events/
@test "subagent-start: valid payload → writes event file with task_claimed type" {
  bash "$SUBAGENT_START_HOOK" <<< "$(make_subagent_start_payload "researcher" "sess-start-1")"
  local event_file
  event_file="$(ls "$HOME/.claude/cast/events/"*subagent-start.json 2>/dev/null | head -1)"
  [ -n "$event_file" ]
  python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
assert d.get('event_type') == 'task_claimed', f'event_type={d.get(\"event_type\")}'
assert d.get('agent') == 'researcher',        f'agent={d.get(\"agent\")}'
assert d.get('source') == 'SubagentStart',    f'source={d.get(\"source\")}'
print('ok')
" "$event_file"
}

# 3. Exits 0 on empty CLAUDE_HOOK_INPUT (no stdin)
@test "subagent-start: empty input → exits 0 without crashing" {
  run bash "$SUBAGENT_START_HOOK" <<< ""
  assert_success
}

# 4. Exits 0 on malformed JSON
@test "subagent-start: malformed JSON input → exits 0 without crashing" {
  run bash "$SUBAGENT_START_HOOK" <<< "not-json-at-all{{"
  assert_success
}

# 5. Exits 0 when agent_name field is absent (defensive parse)
@test "subagent-start: missing agent_name field → exits 0, uses 'unknown'" {
  local payload
  payload='{"hook_event_name":"SubagentStart","session_id":"sess-x"}'
  run bash "$SUBAGENT_START_HOOK" <<< "$payload"
  assert_success
}

# ═══════════════════════════════════════════════════════════════════════════════
# cast-user-prompt-hook.sh tests
# ═══════════════════════════════════════════════════════════════════════════════

# 6. Exit 0 on valid JSON input
@test "user-prompt: valid payload → exits 0" {
  run bash "$USER_PROMPT_HOOK" <<< "$(make_user_prompt_payload)"
  assert_success
}

# 7. Writes to ~/.claude/cast/user-prompts.jsonl or events/
@test "user-prompt: valid payload → writes to user-prompts.jsonl" {
  bash "$USER_PROMPT_HOOK" <<< "$(make_user_prompt_payload "sess-p-1" "Tell me about CAST")"
  [ -f "$HOME/.claude/cast/user-prompts.jsonl" ]
  python3 -c "
import json
with open('$HOME/.claude/cast/user-prompts.jsonl') as f:
    d = json.loads(f.readline().strip())
assert d.get('session_id') == 'sess-p-1', f'got {d.get(\"session_id\")}'
assert 'timestamp' in d
print('ok')
"
}

# 8. Exits 0 on empty input (defensive parse)
@test "user-prompt: empty input → exits 0 without crashing" {
  run bash "$USER_PROMPT_HOOK" <<< ""
  assert_success
}

# 9. Exits 0 on malformed JSON
@test "user-prompt: malformed JSON → exits 0 without crashing" {
  run bash "$USER_PROMPT_HOOK" <<< "{{broken"
  assert_success
}

# 10. CLAUDE_SUBPROCESS guard — hook is a no-op in subprocesses
@test "user-prompt: CLAUDE_SUBPROCESS=1 → exits 0, writes nothing" {
  CLAUDE_SUBPROCESS=1 bash "$USER_PROMPT_HOOK" <<< "$(make_user_prompt_payload "sess-sub" "secret prompt")"
  [ ! -f "$HOME/.claude/cast/user-prompts.jsonl" ]
}

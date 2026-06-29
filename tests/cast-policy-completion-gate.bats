#!/usr/bin/env bats
# cast-policy-completion-gate.bats — Subtraction Safety Gate: v9 P-trust policy-gate
# completion-recording fix.
#
# WRITER: cast-subagent-stop-hook.sh step 2.8 records the agent's real terminal verdict
#         to ~/.claude/agent-status/<agent>-<ts>.json via status-writer.sh.
# READER: cast-pretool-dispatch.py (via cast-git-guard.py _agent_completed_this_session)
#         clears a block-severity policy ONLY when the MOST RECENT completion record for
#         the required agent has status DONE or DONE_WITH_CONCERNS.
#
# HARD RULES honored: temp-HOME isolation (setup_temp_home); zero GUI side effects;
#   printf for all JSON fixtures (no heredocs inside @test); touch -t for mtime ordering.

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
DISPATCH="$REPO_DIR/scripts/cast-pretool-dispatch.py"
HOOK_SH="$REPO_DIR/scripts/cast-subagent-stop-hook.sh"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Build a PreToolUse Write payload (mirrors cast-pretool-dispatch.bats)
payload() {
  python3 -c "
import json, sys
tool = sys.argv[1]
ti = {}
for kv in sys.argv[2:]:
    k, _, v = kv.partition('=')
    ti[k] = v
print(json.dumps({'tool_name': tool, 'tool_input': ti, 'session_id': 'test'}))
" "$@"
}

run_dispatch() { run python3 "$DISPATCH" <<< "$1"; }

# Build a SubagentStop payload (mirrors cast-subagent-stop-hook.bats)
make_stop_payload() {
  local agent_type="${1:-test-agent}"
  local output="${2:-}"
  python3 -c "
import json, sys
print(json.dumps({
    'agent_type':             sys.argv[1],
    'session_id':             'sess-gate-test',
    'stop_reason':            'end_turn',
    'last_assistant_message': sys.argv[2],
}))
" "$agent_type" "$output"
}

# Write a completion record for <agent> with <STATUS>.
# Optional age_secs: set mtime that many seconds in the past (for ordering tests).
# Uses printf (no heredoc) and touch -t (portable CCYYMMDDhhmm.SS on macOS+Linux).
write_status_file() {
  local agent="$1"
  local status="$2"
  local age_secs="${3:-0}"

  local ts
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  # Include status in filename to avoid collision when called twice in same second
  local filepath="$HOME/.claude/agent-status/${agent}-${status}-${ts}.json"

  printf '{"agent": "%s", "status": "%s", "summary": "subagent completion record", "timestamp": "%s"}\n' \
    "$agent" "$status" "$ts" > "$filepath"

  if [[ "$age_secs" -gt 0 ]]; then
    local touch_ts
    touch_ts="$(python3 -c "
from datetime import datetime, timezone, timedelta
import sys
t = datetime.now(timezone.utc) - timedelta(seconds=int(sys.argv[1]))
print(t.strftime('%Y%m%d%H%M.%S'))
" "$age_secs")"
    touch -t "$touch_ts" "$filepath"
  fi
}

# ---------------------------------------------------------------------------
# Setup / teardown — mirrors cast-subagent-stop-hook.bats + adds policy fixtures
# ---------------------------------------------------------------------------

setup() {
  load 'helpers/setup'
  setup_temp_home

  mkdir -p "$HOME/.claude/cast/events"
  mkdir -p "$HOME/.claude/cast/truncated-agents"
  mkdir -p "$HOME/.claude/logs"
  mkdir -p "$HOME/.claude/config"
  mkdir -p "$HOME/.claude/agent-status"
  mkdir -p "$HOME/.claude/scripts"

  # Policy + egress config so the gate finds them under temp HOME regardless of cwd
  cp "$REPO_DIR/config/policies.json"      "$HOME/.claude/config/policies.json"
  cp "$REPO_DIR/config/egress-policy.json" "$HOME/.claude/config/egress-policy.json"

  # Runtime helpers that cast-subagent-stop-hook.sh sources
  cp "$REPO_DIR/scripts/status-writer.sh"        "$HOME/.claude/scripts/status-writer.sh"
  cp "$REPO_DIR/scripts/cast-status-contract.sh" "$HOME/.claude/scripts/cast-status-contract.sh"

  # Minimal cast.db so the hook's DB steps don't abort (mirrors cast-subagent-stop-hook.bats)
  export CAST_DB_PATH="$HOME/.claude/cast.db"
  sqlite3 "$CAST_DB_PATH" 'CREATE TABLE IF NOT EXISTS agent_runs (
    id INTEGER PRIMARY KEY,
    agent TEXT,
    session_id TEXT,
    status TEXT,
    started_at TEXT,
    ended_at TEXT,
    agent_id TEXT,
    duration_ms INTEGER,
    tool_uses INTEGER,
    response TEXT,
    cost_usd REAL,
    input_tokens INTEGER,
    output_tokens INTEGER,
    model TEXT,
    cache_read_input_tokens INTEGER,
    cache_creation_input_tokens INTEGER
  );'

  export EGRESS_LOG="$HOME/.claude/logs/egress.jsonl"
  unset CLAUDE_SUBPROCESS CAST_COMMIT_AGENT CAST_PUSH_OK CAST_STASH_OK \
        CAST_RM_OK CAST_KILL_OK CLAUDE_SESSION_ID \
        CAST_POLICY_OVERRIDE
}

teardown() { teardown_temp_home; }

# ---------------------------------------------------------------------------
# READER tests — Write payload hits policy engine via cast-pretool-dispatch.py
# ---------------------------------------------------------------------------

@test "READER-1: .github/workflows/ path with no devops completion → blocked (exit 2)" {
  local fp
  fp='.github/workflows/deploy.yml'
  run_dispatch "$(payload Write "file_path=$fp")"
  assert_failure
  assert_output --partial "workflows-require-devops"
}

@test "READER-2: .github/workflows/ path after devops DONE → allowed" {
  write_status_file devops DONE
  local fp
  fp='.github/workflows/deploy.yml'
  run_dispatch "$(payload Write "file_path=$fp")"
  assert_success
}

@test "READER-3: devops BLOCKED completion only → gate still blocks" {
  write_status_file devops BLOCKED
  local fp
  fp='.github/workflows/deploy.yml'
  run_dispatch "$(payload Write "file_path=$fp")"
  assert_failure
  assert_output --partial "workflows-require-devops"
}

@test "READER-4: re-run safety — newer BLOCKED beats older DONE (most-recent verdict wins)" {
  # DONE written with mtime 3600 s in the past (older)
  write_status_file devops DONE 3600
  # BLOCKED written with mtime 60 s in the past (strictly newer than 3600 s ago)
  write_status_file devops BLOCKED 60
  local fp
  fp='.github/workflows/deploy.yml'
  run_dispatch "$(payload Write "file_path=$fp")"
  assert_failure
  assert_output --partial "workflows-require-devops"
}

@test "READER-5: src/auth/ path with no security completion → blocked" {
  local fp
  fp='src/auth/login.py'
  run_dispatch "$(payload Write "file_path=$fp")"
  assert_failure
  assert_output --partial "auth-requires-security"
}

@test "READER-5b: src/auth/ path after security DONE → allowed" {
  write_status_file security DONE
  local fp
  fp='src/auth/login.py'
  run_dispatch "$(payload Write "file_path=$fp")"
  assert_success
}

@test "READER-6: .env path with no security completion → blocked" {
  local fp
  fp='config/app.env'
  run_dispatch "$(payload Write "file_path=$fp")"
  assert_failure
  assert_output --partial "env-files-require-security"
}

# ---------------------------------------------------------------------------
# WRITER tests — cast-subagent-stop-hook.sh step 2.8 records verdicts
# ---------------------------------------------------------------------------

@test "WRITER-7: devops Status: DONE → agent-status file written with status DONE" {
  local output
  output="$(python3 -c "
lines = ['Reviewed the workflow file.', '']
lines.append('Status: DONE')
lines.append('Summary: devops review complete')
print('\n'.join(lines))
")"
  run bash "$HOOK_SH" <<< "$(make_stop_payload devops "$output")"
  assert_success
  # At least one devops-*.json must exist
  local count
  count="$(find "$HOME/.claude/agent-status" -name "devops-*.json" 2>/dev/null | wc -l | tr -d ' ')"
  [[ "$count" -ge 1 ]]
  # The file must contain the real status field
  local found
  found="$(grep -rl '"status"' "$HOME/.claude/agent-status" 2>/dev/null | grep '/devops-' | head -1 || echo '')"
  [[ -n "$found" ]]
  run grep -c '"status": "DONE"' "$found"
  assert_success
  assert_output "1"
}

@test "WRITER-8: devops Status: BLOCKED → agent-status file written with status BLOCKED" {
  local output
  output="$(python3 -c "
lines = ['Could not complete — missing credentials.', '']
lines.append('Status: BLOCKED')
lines.append('Summary: blocked on missing deploy secret')
print('\n'.join(lines))
")"
  run bash "$HOOK_SH" <<< "$(make_stop_payload devops "$output")"
  assert_success
  # Verify a BLOCKED record was written (reader must NOT clear gate from this)
  local count
  count="$(grep -rl '"status": "BLOCKED"' "$HOME/.claude/agent-status" 2>/dev/null | grep '/devops-' | wc -l | tr -d ' ')"
  [[ "$count" -ge 1 ]]
}

@test "WRITER-9: general-purpose (exempt) with Status: DONE → NO completion record written" {
  local output
  output="$(python3 -c "
lines = ['Task finished.', '']
lines.append('Status: DONE')
lines.append('Summary: completed')
print('\n'.join(lines))
")"
  run bash "$HOOK_SH" <<< "$(make_stop_payload "general-purpose" "$output")"
  assert_success
  # Exempt agents must NOT write any agent-status file
  local count
  count="$(find "$HOME/.claude/agent-status" -name "general-purpose-*.json" 2>/dev/null | wc -l | tr -d ' ')"
  [[ "$count" -eq 0 ]]
}

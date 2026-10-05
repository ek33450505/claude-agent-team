#!/usr/bin/env bats
# cast-policy-completion-gate.bats — Subtraction Safety Gate: v9 P-trust policy-gate
# completion-recording fix.
#
# WRITER: cast-subagent-stop-hook.sh step 2.8 records the agent's real terminal verdict
#         to ~/.claude/agent-status/<agent>-<ts>.json via status-writer.sh.
# READER: cast-pretool-dispatch.py (via cast-git-guard.py _agent_completed_this_session)
#         clears a block-severity policy ONLY when the MOST RECENT completion record that
#         is bound (by CONTENT: session_id + agent_type) to the payload's session and the
#         required agent has status DONE or DONE_WITH_CONCERNS. Filenames are display-only.
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

# payload() with the session_id replaced: payload_for_session <sid> <tool> [k=v ...]
payload_for_session() {
  local sid="$1"
  shift
  payload "$@" | python3 -c "
import json, sys
d = json.load(sys.stdin)
d['session_id'] = sys.argv[1]
print(json.dumps(d))
" "$sid"
}

# payload() with NO session_id key at all.
payload_no_session() {
  payload "$@" | python3 -c "
import json, sys
d = json.load(sys.stdin)
d.pop('session_id', None)
print(json.dumps(d))
"
}

# Build a SubagentStop payload (mirrors cast-subagent-stop-hook.bats)
# Optional 3rd arg: agent_id (the filename stem of Claude Code's subagent sidecar).
make_stop_payload() {
  local agent_type="${1:-test-agent}"
  local output="${2:-}"
  local agent_id="${3:-}"
  python3 -c "
import json, sys
d = {
    'agent_type':             sys.argv[1],
    'session_id':             'sess-gate-test',
    'stop_reason':            'end_turn',
    'last_assistant_message': sys.argv[2],
}
if sys.argv[3]:
    d['agent_id'] = sys.argv[3]
print(json.dumps(d))
" "$agent_type" "$output" "$agent_id"
}

# Write Claude Code's subagent sidecar fixture the writer reads its TRUSTED roster
# type from: ~/.claude/projects/<slug>/<session_id>/subagents/agent-<agent_id>.meta.json
# (layout live-probed 2026-10-05). Args: <agent_id> <meta-json>. printf only.
write_sidecar() {
  local aid="$1"
  local meta="$2"
  local dir="$HOME/.claude/projects/-home-proj/sess-gate-test/subagents"
  mkdir -p "$dir"
  printf '%s\n' "$meta" > "$dir/agent-${aid}.meta.json"
}

# First completion record written for <agent-prefix> (empty string if none).
first_record() {
  find "$HOME/.claude/agent-status" -name "${1}-*.json" 2>/dev/null | head -1
}

# Set <file>'s mtime to <secs> seconds in the past (negative = in the future).
# touch -t (portable CCYYMMDDhhmm.SS on macOS+Linux) takes LOCAL time, so format a naive
# local datetime — a UTC-formatted stamp lands hours in the future on any non-UTC host
# (the old helper did exactly that, which the gate's future-mtime check now exposes).
set_age() {
  local file="$1"
  local age_secs="$2"
  local touch_ts
  touch_ts="$(python3 -c "
from datetime import datetime, timedelta
import sys
t = datetime.now() - timedelta(seconds=int(sys.argv[1]))
print(t.strftime('%Y%m%d%H%M.%S'))
" "$age_secs")"
  touch -t "$touch_ts" "$file"
}

# Write a completion record for <agent> with <STATUS>, bound the way the SubagentStop
# hook binds a trusted one: content fields session_id + agent_type.
# Optional age_secs: set mtime that many seconds in the past (for ordering tests).
# Optional session_id (default "test", the payload() session) and agent_type (default
# = <agent>) override the bound content fields.
# Uses printf (no heredoc).
write_status_file() {
  local agent="$1"
  local status="$2"
  local age_secs="${3:-0}"
  local sess="${4:-test}"
  local atype="${5:-$agent}"

  local ts
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  # Include status + session in filename to avoid collision when called twice in same second
  local filepath="$HOME/.claude/agent-status/${agent}-${status}-${sess}-${ts}.json"

  printf '{"agent": "%s", "status": "%s", "summary": "subagent completion record", "timestamp": "%s", "session_id": "%s", "agent_type": "%s"}\n' \
    "$agent" "$status" "$ts" "$sess" "$atype" > "$filepath"

  if [[ "$age_secs" -gt 0 ]]; then
    set_age "$filepath" "$age_secs"
  fi
}

# Write a record with arbitrary <name> and raw <json> content (legacy/unbound shapes,
# filename-vs-content tests). Optional age_secs (negative = future mtime).
write_raw_record() {
  local name="$1"
  local json="$2"
  local age_secs="${3:-0}"
  printf '%s\n' "$json" > "$HOME/.claude/agent-status/$name"
  if [[ "$age_secs" -ne 0 ]]; then
    set_age "$HOME/.claude/agent-status/$name" "$age_secs"
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

@test "READER-7: devops DONE record from ANOTHER session → blocked (session-bound)" {
  write_status_file devops DONE 0 some-other-session
  run_dispatch "$(payload Write "file_path=.github/workflows/deploy.yml")"
  assert_failure
  assert_output --partial "workflows-require-devops"
}

@test "READER-8: legacy unbound record (no session_id / agent_type) → blocked" {
  write_raw_record "devops-DONE-legacy.json" '{"agent": "devops", "status": "DONE", "summary": "old shape"}'
  run_dispatch "$(payload Write "file_path=.github/workflows/deploy.yml")"
  assert_failure
  assert_output --partial "workflows-require-devops"
}

@test "READER-9a: content beats filename — devops-named file whose agent_type is security does NOT clear workflows" {
  write_raw_record "devops-x.json" '{"agent": "devops", "status": "DONE", "session_id": "test", "agent_type": "security"}'
  run_dispatch "$(payload Write "file_path=.github/workflows/deploy.yml")"
  assert_failure
  assert_output --partial "workflows-require-devops"
}

@test "READER-9b: content beats filename — arbitrary filename with agent_type devops + this session DOES clear workflows" {
  write_raw_record "zzz.json" '{"agent": "whatever", "status": "DONE", "session_id": "test", "agent_type": "devops"}'
  run_dispatch "$(payload Write "file_path=.github/workflows/deploy.yml")"
  assert_success
}

@test "READER-9c: agent_type must match exactly — devops2 / DEVOPS do not satisfy devops" {
  write_raw_record "a.json" '{"status": "DONE", "session_id": "test", "agent_type": "devops2"}'
  write_raw_record "b.json" '{"status": "DONE", "session_id": "test", "agent_type": "DEVOPS"}'
  run_dispatch "$(payload Write "file_path=.github/workflows/deploy.yml")"
  assert_failure
  assert_output --partial "workflows-require-devops"
}

@test "READER-10: a bound record whose name does not end .json is ignored" {
  write_raw_record "devops-DONE-test.txt" '{"status": "DONE", "session_id": "test", "agent_type": "devops"}'
  write_raw_record ".hidden.json" '{"status": "DONE", "session_id": "test", "agent_type": "devops"}'
  run_dispatch "$(payload Write "file_path=.github/workflows/deploy.yml")"
  assert_failure
  assert_output --partial "workflows-require-devops"
}

@test "READER-11: a symlinked record is ignored (lstat + O_NOFOLLOW)" {
  printf '%s\n' '{"status": "DONE", "session_id": "test", "agent_type": "devops"}' > "$HOME/real-record.json"
  ln -s "$HOME/real-record.json" "$HOME/.claude/agent-status/devops-link.json"
  run_dispatch "$(payload Write "file_path=.github/workflows/deploy.yml")"
  assert_failure
  assert_output --partial "workflows-require-devops"
}

@test "READER-11b: a symlinked agent-status directory is refused" {
  mv "$HOME/.claude/agent-status" "$HOME/real-status-dir"
  ln -s "$HOME/real-status-dir" "$HOME/.claude/agent-status"
  write_raw_record "devops-DONE.json" '{"status": "DONE", "session_id": "test", "agent_type": "devops"}'
  run_dispatch "$(payload Write "file_path=.github/workflows/deploy.yml")"
  assert_failure
  assert_output --partial "workflows-require-devops"
}

@test "READER-12: a future-dated record (mtime > now + 60s) is ignored" {
  write_raw_record "devops-future.json" '{"status": "DONE", "session_id": "test", "agent_type": "devops"}' -3600
  run_dispatch "$(payload Write "file_path=.github/workflows/deploy.yml")"
  assert_failure
  assert_output --partial "workflows-require-devops"
}

@test "READER-13: payload with NO session_id blocks even when a record's session_id is empty" {
  write_raw_record "devops-empty-sid.json" '{"status": "DONE", "session_id": "", "agent_type": "devops"}'
  run_dispatch "$(payload_no_session Write "file_path=.github/workflows/deploy.yml")"
  assert_failure
  assert_output --partial "workflows-require-devops"
}

@test "READER-14: DONE_WITH_CONCERNS still unblocks (decision fence: the gate attests completion, not approval)" {
  write_status_file devops DONE_WITH_CONCERNS
  run_dispatch "$(payload Write "file_path=.github/workflows/deploy.yml")"
  assert_success
}

@test "READER-15: a NEWER other-session BLOCKED does not shadow an older same-session DONE" {
  write_status_file devops DONE 3600
  write_status_file devops BLOCKED 60 some-other-session
  run_dispatch "$(payload Write "file_path=.github/workflows/deploy.yml")"
  assert_success
}

@test "READER-15b: a NEWER same-session BLOCKED still supersedes an older same-session DONE" {
  write_status_file devops DONE 3600
  write_status_file devops BLOCKED 60
  run_dispatch "$(payload Write "file_path=.github/workflows/deploy.yml")"
  assert_failure
  assert_output --partial "workflows-require-devops"
}

@test "READER-16: more than 2000 candidate records → fail closed even with a matching DONE present" {
  write_status_file devops DONE
  python3 -c "
import os, sys
d = sys.argv[1]
for i in range(2001):
    open(os.path.join(d, 'junk-%d.json' % i), 'w').close()
" "$HOME/.claude/agent-status"
  run_dispatch "$(payload Write "file_path=.github/workflows/deploy.yml")"
  assert_failure
  assert_output --partial "workflows-require-devops"
}

@test "READER-17: block message names the session-bound trust rule and keeps the escape hatch" {
  run_dispatch "$(payload Write "file_path=.github/workflows/deploy.yml")"
  assert_failure
  assert_output --partial "dispatched in THIS session"
  assert_output --partial "devops__<label>"
  assert_output --partial "CAST_POLICY_OVERRIDE=1"
}

@test "READER-18: a deeply nested junk record (RecursionError on CPython 3.9) next to no matching record → Write still blocked, never fail-open" {
  # ~3 KB, well under the 64 KiB record cap. On /usr/bin/python3 (3.9) json.loads raises
  # RecursionError at ~1000 levels; if that escaped the reader, evaluate()'s blanket
  # fail-open would return 0 and EVERY policy block would be disabled by one junk file.
  python3 -c "
import sys
sys.stdout.write('[' * 1500 + ']' * 1500)
" > "$HOME/.claude/agent-status/junk-deep.json"
  run_dispatch "$(payload Write "file_path=.github/workflows/deploy.yml")"
  assert_failure
  assert_output --partial "workflows-require-devops"
  if [[ -x /usr/bin/python3 ]]; then
    run /usr/bin/python3 "$DISPATCH" <<< "$(payload Write "file_path=.github/workflows/deploy.yml")"
    assert_failure
    assert_output --partial "workflows-require-devops"
  else
    skip "no /usr/bin/python3 — default-interpreter half passed, 3.9 half not run"
  fi
}

@test "READER-18b: a deeply nested junk record does not shadow a valid bound DONE record" {
  python3 -c "
import sys
sys.stdout.write('[' * 1500 + ']' * 1500)
" > "$HOME/.claude/agent-status/junk-deep.json"
  write_status_file devops DONE
  run_dispatch "$(payload Write "file_path=.github/workflows/deploy.yml")"
  assert_success
  if [[ -x /usr/bin/python3 ]]; then
    run /usr/bin/python3 "$DISPATCH" <<< "$(payload Write "file_path=.github/workflows/deploy.yml")"
    assert_success
  fi
}

@test "READER-19: a payload session_id outside [A-Za-z0-9-]{1,64} fails closed even when a record carries the identical id" {
  write_raw_record "devops-us.json" '{"status": "DONE", "session_id": "sess_x", "agent_type": "devops"}'
  run_dispatch "$(payload_for_session sess_x Write "file_path=.github/workflows/deploy.yml")"
  assert_failure
  assert_output --partial "workflows-require-devops"
}

@test "READER-20: equal-mtime DONE and BLOCKED from the same session+type → blocked (conservative tie-break, either filename order)" {
  write_raw_record "a-done.json" '{"status": "DONE", "session_id": "test", "agent_type": "devops"}'
  write_raw_record "z-blocked.json" '{"status": "BLOCKED", "session_id": "test", "agent_type": "devops"}'
  touch -r "$HOME/.claude/agent-status/a-done.json" "$HOME/.claude/agent-status/z-blocked.json"
  run_dispatch "$(payload Write "file_path=.github/workflows/deploy.yml")"
  assert_failure
  assert_output --partial "workflows-require-devops"
  rm -f "$HOME/.claude/agent-status/a-done.json" "$HOME/.claude/agent-status/z-blocked.json"
  write_raw_record "z-done.json" '{"status": "DONE", "session_id": "test", "agent_type": "devops"}'
  write_raw_record "a-blocked.json" '{"status": "BLOCKED", "session_id": "test", "agent_type": "devops"}'
  touch -r "$HOME/.claude/agent-status/z-done.json" "$HOME/.claude/agent-status/a-blocked.json"
  run_dispatch "$(payload Write "file_path=.github/workflows/deploy.yml")"
  assert_failure
  assert_output --partial "workflows-require-devops"
}

# Run the dispatcher with an explicit interpreter; python3 first, then /usr/bin/python3
# (CPython 3.9 on macOS) when it exists and differs. Args: <payload-json>.
dispatch_each_python() {
  local pl="$1" py
  for py in python3 /usr/bin/python3; do
    command -v "$py" > /dev/null 2>&1 || continue
    run "$py" "$DISPATCH" <<< "$pl"
    assert_failure
    assert_output --partial "CAST-POLICY-BLOCK"
  done
}

now_ms() { python3 -c 'import time; print(int(time.time() * 1000))'; }

@test "READER-21: a 4096-char path with an embedded newline fails closed FAST (cubic .env backtracking guard)" {
  # Without the control-char guard the default `.*\.env(\..*)?$` pattern backtracks
  # cubically on the newline: ~24 s on CPython 3.14 vs the 5 s hook timeout.
  local fp t0 t1
  fp="$(python3 -c "
import sys
sys.stdout.write(('.env' * 1023) + '\nz')
")"
  [[ "${#fp}" -le 4096 ]]
  local py
  for py in python3 /usr/bin/python3; do
    command -v "$py" > /dev/null 2>&1 || continue
    t0="$(now_ms)"
    run "$py" "$DISPATCH" <<< "$(payload Write "file_path=$fp")"
    t1="$(now_ms)"
    assert_failure
    assert_output --partial "control characters"
    # generous bound (interpreter start-up included); the unguarded path takes >20 s
    [[ $((t1 - t0)) -lt 4000 ]]
  done
}

@test "READER-21b: a short control-char path no policy matches is still blocked, and CAST_POLICY_OVERRIDE=1 releases it" {
  dispatch_each_python "$(payload Write "file_path=$(printf 'src/ok\tname.txt')")"
  run env CAST_POLICY_OVERRIDE=1 python3 "$DISPATCH" <<< "$(payload Write "file_path=$(printf 'src/ok\tname.txt')")"
  assert_success
}

@test "READER-21c: a control-free symlink that RESOLVES to a newline target fails closed fast on both interpreters" {
  # The raw path has no control characters; only realpath() exposes the newline. The regexes
  # run on the resolved candidate too, so it needs the same guard (cubic backtracking).
  local tgt link
  tgt="$HOME/tgt/$(printf 'a\nb')"
  mkdir -p "$tgt"
  link="$HOME/link"
  ln -s "$tgt" "$link"
  local py t0 t1
  for py in python3 /usr/bin/python3; do
    command -v "$py" > /dev/null 2>&1 || continue
    t0="$(now_ms)"
    run "$py" "$DISPATCH" <<< "$(payload Write "file_path=$link/x.txt")"
    t1="$(now_ms)"
    assert_failure
    assert_output --partial "symlink-resolved"
    [[ $((t1 - t0)) -lt 4000 ]]
  done
  # control: a symlink to a plain directory is not affected
  mkdir -p "$HOME/tgt/plain"
  ln -s "$HOME/tgt/plain" "$HOME/link2"
  run python3 "$DISPATCH" <<< "$(payload Write "file_path=$HOME/link2/x.txt")"
  assert_success
}

@test "READER-22: a non-string file_path (int/list/dict/bool/null) or no path at all fails closed on both interpreters" {
  local body
  for body in '"file_path": 5' '"file_path": ["a"]' '"file_path": {"a": 1}' '"file_path": true' '"file_path": null' '"content": "x"'; do
    dispatch_each_python "{\"tool_name\": \"Write\", \"session_id\": \"test\", \"tool_input\": {$body}}"
    assert_output --partial "not a string"
  done
  dispatch_each_python '{"tool_name": "Edit", "session_id": "test", "tool_input": {"file_path": 5}}'
}

@test "READER-23: an empty-string file_path is still 'no path, no policy' (allowed); non-str + CAST_POLICY_OVERRIDE=1 is released" {
  run python3 "$DISPATCH" <<< '{"tool_name": "Write", "session_id": "test", "tool_input": {"file_path": ""}}'
  assert_success
  run env CAST_POLICY_OVERRIDE=1 python3 "$DISPATCH" <<< '{"tool_name": "Write", "session_id": "test", "tool_input": {"file_path": 5}}'
  assert_success
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
  # Unnamed-subagent sidecar shape: agentType IS the roster type.
  write_sidecar adevops0001 '{"agentType":"devops"}'
  run bash "$HOOK_SH" <<< "$(make_stop_payload devops "$output" adevops0001)"
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
  # Gate-trust content fields: the payload session_id + the sidecar roster type.
  run grep -c '"session_id": "sess-gate-test"' "$found"
  assert_success
  assert_output "1"
  run grep -c '"agent_type": "devops"' "$found"
  assert_success
  assert_output "1"
}

@test "WRITER-7b: roster type comes from the sidecar, not the dispatch name" {
  local output
  output="$(printf 'Reviewed.\n\nStatus: DONE\nSummary: ok\n')"
  # Named regular subagent (probe shape 4): name differs from agentType.
  write_sidecar adevops0002 '{"agentType":"devops","name":"devops__label"}'
  run bash "$HOOK_SH" <<< "$(make_stop_payload devops__label "$output" adevops0002)"
  assert_success
  local f
  f="$(first_record devops__label)"
  [[ -n "$f" ]]
  run grep -c '"agent_type": "devops"' "$f"
  assert_success
  assert_output "1"
}

@test "WRITER-7c: built-in Explore teammate spoof sidecar → record written, NO agent_type key" {
  local output
  output="$(printf 'Reviewed.\n\nStatus: DONE\nSummary: ok\n')"
  # Probe shape 3: a built-in Explore dispatched with name devops. agentType is the
  # dispatch NAME and nothing names Explore, so the roster type must be untrusted.
  write_sidecar aspoof0001 '{"agentType":"devops","name":"devops","taskKind":"in_process_teammate","teamName":"t"}'
  run bash "$HOOK_SH" <<< "$(make_stop_payload devops "$output" aspoof0001)"
  assert_success
  local f
  f="$(first_record devops)"
  [[ -n "$f" ]]
  run grep -c '"status": "DONE"' "$f"
  assert_success
  assert_output "1"
  run grep -q '"agent_type"' "$f"
  assert_failure
}

@test "WRITER-7d: no sidecar at all → record written, NO agent_type key" {
  local output
  output="$(printf 'Reviewed.\n\nStatus: DONE\nSummary: ok\n')"
  run bash "$HOOK_SH" <<< "$(make_stop_payload devops "$output" anosidecar01)"
  assert_success
  local f
  f="$(first_record devops)"
  [[ -n "$f" ]]
  run grep -c '"session_id": "sess-gate-test"' "$f"
  assert_success
  assert_output "1"
  run grep -q '"agent_type"' "$f"
  assert_failure
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

# ---------------------------------------------------------------------------
# END-TO-END — the real SubagentStop hook writes the record, the real dispatcher reads it
# ---------------------------------------------------------------------------

@test "E2E-1: unnamed devops subagent ends Status: DONE in sess-gate-test → Write to workflows in that session allowed" {
  local output
  output="$(printf 'Reviewed.\n\nStatus: DONE\nSummary: ok\n')"
  write_sidecar adevops0010 '{"agentType":"devops"}'
  run bash "$HOOK_SH" <<< "$(make_stop_payload devops "$output" adevops0010)"
  assert_success
  run_dispatch "$(payload_for_session sess-gate-test Write "file_path=.github/workflows/x.yml")"
  assert_success
  # ...but the same record does NOT unblock a different session.
  run_dispatch "$(payload_for_session some-other-session Write "file_path=.github/workflows/x.yml")"
  assert_failure
  assert_output --partial "workflows-require-devops"
}

@test "E2E-2: spoof — built-in teammate named devops (untrusted roster type) → record written but gate still blocks" {
  local output
  output="$(printf 'Reviewed.\n\nStatus: DONE\nSummary: ok\n')"
  write_sidecar aspoof0010 '{"agentType":"devops","name":"devops","taskKind":"in_process_teammate","teamName":"t"}'
  run bash "$HOOK_SH" <<< "$(make_stop_payload devops "$output" aspoof0010)"
  assert_success
  local f
  f="$(first_record devops)"
  [[ -n "$f" ]]
  run_dispatch "$(payload_for_session sess-gate-test Write "file_path=.github/workflows/x.yml")"
  assert_failure
  assert_output --partial "workflows-require-devops"
}

# ---------------------------------------------------------------------------
# S3d-5 — the gate record is written by a FAST gate-only pass BEFORE the telemetry
# stages, so a slow/killed telemetry pass (stage 9 can take 50-100 s; the SubagentStop
# hook timeout is ~15 s) can no longer lose the requires_agent unblock record.
# ---------------------------------------------------------------------------

# Install a python3 PATH shim in $BATS_TEST_TMPDIR/bin. The real python3 is resolved to
# an absolute path BEFORE the shim exists. The shim execs the real python3 for every
# call EXCEPT one pass of cast_subagent_stop.py, which touches a marker and dies 137:
#   mode "die":     the FULL telemetry pass (no --gate-only) exits 137 immediately.
#                   Marker: $BATS_TEST_TMPDIR/full-pass-started
#   mode "hang":    the FULL pass blocks until $BATS_TEST_TMPDIR/release exists (20 s
#                   backstop), then exits 137. Same marker.
#   mode "gatedie": the --gate-only pass exits 137 immediately (full pass runs for real).
#                   Marker: $BATS_TEST_TMPDIR/gate-pass-started
install_full_pass_shim() {
  local mode="$1"
  local real_py
  real_py="$(command -v python3)"
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '%s\n' \
    '#!/bin/bash' \
    "real_py=\"$real_py\"" \
    "started=\"$BATS_TEST_TMPDIR/full-pass-started\"" \
    "gate_started=\"$BATS_TEST_TMPDIR/gate-pass-started\"" \
    "release=\"$BATS_TEST_TMPDIR/release\"" \
    "mode=\"$mode\"" \
    'script=0; gate=0' \
    'for a in "$@"; do' \
    '  case "$a" in' \
    '    *cast_subagent_stop.py) script=1 ;;' \
    '    --gate-only) gate=1 ;;' \
    '  esac' \
    'done' \
    'if [ "$script" = 1 ] && [ "$gate" = 1 ] && [ "$mode" = gatedie ]; then' \
    '  : > "$gate_started"' \
    '  exit 137' \
    'fi' \
    'if [ "$script" = 1 ] && [ "$gate" = 0 ] && [ "$mode" != gatedie ]; then' \
    '  : > "$started"' \
    '  if [ "$mode" = hang ]; then' \
    '    i=0' \
    '    while [ ! -e "$release" ] && [ "$i" -lt 200 ]; do sleep 0.1; i=$((i + 1)); done' \
    '  fi' \
    '  exit 137' \
    'fi' \
    'exec "$real_py" "$@"' \
    > "$BATS_TEST_TMPDIR/bin/python3"
  chmod +x "$BATS_TEST_TMPDIR/bin/python3"
}

@test "S3d-5a: gate record is written even when the FULL telemetry pass dies (exit 137)" {
  local output
  output="$(printf 'Reviewed.\n\nStatus: DONE\nSummary: ok\n')"
  write_sidecar adevops0020 '{"agentType":"devops"}'
  install_full_pass_shim die
  run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" bash "$HOOK_SH" <<< "$(make_stop_payload devops "$output" adevops0020)"
  assert_success
  # Vacuity guard: the full pass really ran under the shim and died.
  [[ -e "$BATS_TEST_TMPDIR/full-pass-started" ]]
  local f
  f="$(first_record devops)"
  [[ -n "$f" ]]
  run grep -c '"status": "DONE"' "$f"
  assert_success
  assert_output "1"
  run grep -c '"session_id": "sess-gate-test"' "$f"
  assert_success
  assert_output "1"
  run grep -c '"agent_type": "devops"' "$f"
  assert_success
  assert_output "1"
}

@test "S3d-5a2: gate record already exists WHILE the full telemetry pass is still running (written before telemetry, not after)" {
  local output payload_json
  output="$(printf 'Reviewed.\n\nStatus: DONE\nSummary: ok\n')"
  payload_json="$(make_stop_payload devops "$output" adevops0021)"
  write_sidecar adevops0021 '{"agentType":"devops"}'
  install_full_pass_shim hang
  # fd 3/4 closed so the background hook can never hold bats' TAP pipe open.
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" bash "$HOOK_SH" <<< "$payload_json" >/dev/null 2>&1 3>&- 4>&- &
  local pid=$!
  # Bounded poll (15 s) for the marker the shim writes when the full pass STARTS.
  local i=0
  while [[ ! -e "$BATS_TEST_TMPDIR/full-pass-started" && "$i" -lt 150 ]]; do
    sleep 0.1
    i=$((i + 1))
  done
  local started=0 f=""
  [[ -e "$BATS_TEST_TMPDIR/full-pass-started" ]] && started=1
  f="$(first_record devops)"
  # Release + reap BEFORE asserting so a failed assertion cannot leak the background hook.
  : > "$BATS_TEST_TMPDIR/release"
  wait "$pid"
  [[ "$started" -eq 1 ]]
  [[ -n "$f" ]]
  run grep -c '"status": "DONE"' "$f"
  assert_success
  assert_output "1"
}

@test "S3d-5b: exactly ONE completion record per stop on the normal path (the full pass writes no second record)" {
  local output
  output="$(printf 'Reviewed.\n\nStatus: DONE\nSummary: ok\n')"
  write_sidecar adevops0030 '{"agentType":"devops"}'
  run bash "$HOOK_SH" <<< "$(make_stop_payload devops "$output" adevops0030)"
  assert_success
  local n
  n="$(find "$HOME/.claude/agent-status" -type f -name '*.json' | wc -l | tr -d ' ')"
  [[ "$n" -eq 1 ]]
  local f
  f="$(first_record devops)"
  [[ -n "$f" ]]
  run grep -c '"status": "DONE"' "$f"
  assert_success
  assert_output "1"
  run grep -c '"agent_type": "devops"' "$f"
  assert_success
  assert_output "1"
}

@test "S3d-5c: a heartbeat tick and a main-session Stop write NO record in either pass" {
  # Tick: empty agent_type + an ephemeral agent_id that resolves to NO agent_runs row; its
  # text is the ENCLOSING session's last message and says Status: DONE, so an admitted tick
  # WOULD record DONE. Main-session Stop: no agent_type and no agent_id at all.
  local tick main
  tick='{"agent_type":"","agent_id":"tick-ephemeral-0001","session_id":"sess-gate-test","stop_reason":"end_turn","last_assistant_message":"Done.\n\nStatus: DONE\nSummary: enclosing session"}'
  main='{"session_id":"sess-gate-test","stop_reason":"end_turn","last_assistant_message":"Done.\n\nStatus: DONE\nSummary: enclosing session"}'

  # Pass 1 and pass 2 invoked directly: each must stay completely silent.
  run env CAST_STOP_INPUT="$tick" CAST_DB_PATH="$CAST_DB_PATH" CAST_HOOK_DIR="$REPO_DIR/scripts" \
    python3 "$REPO_DIR/scripts/cast_subagent_stop.py" --gate-only
  assert_success
  assert_output ""
  run env CAST_STOP_INPUT="$tick" CAST_DB_PATH="$CAST_DB_PATH" CAST_HOOK_DIR="$REPO_DIR/scripts" \
    python3 "$REPO_DIR/scripts/cast_subagent_stop.py"
  assert_success
  assert_output ""

  # End to end through the wrapper.
  run bash "$HOOK_SH" <<< "$tick"
  assert_success
  run bash "$HOOK_SH" <<< "$main"
  assert_success
  local n
  n="$(find "$HOME/.claude/agent-status" -type f | wc -l | tr -d ' ')"
  [[ "$n" -eq 0 ]]
}

@test "S3d-5d: --gate-only emits ONLY the gate tail vars and runs no stage" {
  local output
  output="$(printf 'Reviewed.\n\nStatus: DONE\nSummary: ok\n')"
  write_sidecar adevops0040 '{"agentType":"devops"}'
  run env CAST_STOP_INPUT="$(make_stop_payload devops "$output" adevops0040)" \
    CAST_DB_PATH="$CAST_DB_PATH" CAST_HOOK_DIR="$REPO_DIR/scripts" \
    python3 "$REPO_DIR/scripts/cast_subagent_stop.py" --gate-only
  assert_success
  assert_line --index 0 "__CAST_TAIL_BEGIN__"
  assert_line "CAST_GATE_MATCH=DONE"
  assert_line "SAFE_AGENT=devops"
  assert_line "SAFE_SESSION_ID=sess-gate-test"
  assert_line "SAFE_ROSTER_TYPE=devops"
  assert_line --index 5 "__CAST_TAIL_END__"
  refute_output --partial "CAST_SUCCESSORS"
  refute_output --partial "hookSpecificOutput"
  # No stage ran: stage 1 (event file) writes under cast/events in the full pass.
  local n
  n="$(find "$HOME/.claude/cast/events" -type f | wc -l | tr -d ' ')"
  [[ "$n" -eq 0 ]]
}

@test "S3d-5e: OLD python that ignores --gate-only is detected: pass 1 IS the full pass (one python run, one record, one passthrough, one enqueue)" {
  # Partial-deploy skew: a stub cast_subagent_stop.py that ignores argv and always emits
  # a FULL tail (incl. CAST_SUCCESSORS) plus one hookSpecificOutput line, counting its runs.
  local hookdir="$BATS_TEST_TMPDIR/oldhook"
  mkdir -p "$hookdir"
  cp "$HOOK_SH" "$hookdir/cast-subagent-stop-hook.sh"
  printf '%s\n' \
    'import os, sys' \
    'open(os.environ["STUB_COUNT"], "a").write("run\n")' \
    'sys.stdout.write("{\"hookSpecificOutput\":{\"hookEventName\":\"SubagentStop\",\"additionalContext\":\"stub-passthrough\"}}\n")' \
    'sys.stdout.write("__CAST_TAIL_BEGIN__\nCAST_GATE_MATCH=DONE\nCAST_SUCCESSORS=code-reviewer\nSAFE_AGENT=devops\nSAFE_SESSION_ID=sess-gate-test\nSAFE_ROSTER_TYPE=devops\n__CAST_TAIL_END__\n")' \
    > "$hookdir/cast_subagent_stop.py"
  # Stub queue-add: records each enqueue as "<successor> <session>".
  printf '%s\n' '#!/bin/bash' 'printf "%s %s\n" "$1" "$2" >> "$STUB_QUEUE"' \
    > "$HOME/.claude/scripts/cast-queue-add.sh"
  local text
  text="$(printf 'Reviewed.\n\nStatus: DONE\nSummary: ok\n')"
  run env STUB_COUNT="$BATS_TEST_TMPDIR/py-runs" STUB_QUEUE="$BATS_TEST_TMPDIR/queue" \
    bash "$hookdir/cast-subagent-stop-hook.sh" <<< "$(make_stop_payload devops "$text")"
  assert_success
  # The hook's stdout carries the passthrough line exactly once.
  [[ "$(printf '%s\n' "$output" | grep -c 'stub-passthrough')" -eq 1 ]]
  # Exactly one python run: pass 2 was skipped.
  [[ "$(wc -l < "$BATS_TEST_TMPDIR/py-runs" | tr -d ' ')" -eq 1 ]]
  # Exactly one gate record, from pass 1's tail.
  [[ "$(find "$HOME/.claude/agent-status" -type f -name '*.json' | wc -l | tr -d ' ')" -eq 1 ]]
  local f
  f="$(first_record devops)"
  [[ -n "$f" ]]
  run grep -c '"status": "DONE"' "$f"
  assert_success
  assert_output "1"
  # Step 4 used pass 1's CAST_SUCCESSORS, once.
  [[ "$(cat "$BATS_TEST_TMPDIR/queue")" == "code-reviewer sess-gate-test" ]]
}

@test "S3d-5f: gate pass dies (137) on a BLOCKED stop after an older DONE: record deferred to pass 2, newest is BLOCKED, gate stays blocked" {
  local done_text blocked_text
  done_text="$(printf 'Reviewed.\n\nStatus: DONE\nSummary: ok\n')"
  blocked_text="$(printf 'Found a problem.\n\nStatus: BLOCKED\nSummary: stop\n')"
  write_sidecar adevops0050 '{"agentType":"devops"}'
  # Seed a real DONE record through the normal path, then age it.
  run bash "$HOOK_SH" <<< "$(make_stop_payload devops "$done_text" adevops0050)"
  assert_success
  local seed
  seed="$(first_record devops)"
  [[ -n "$seed" ]]
  set_age "$seed" 60
  # Sanity: the DONE record alone unblocks this session.
  run_dispatch "$(payload_for_session sess-gate-test Write "file_path=.github/workflows/x.yml")"
  assert_success
  # A genuine BLOCKED stop whose gate pass is killed (shim exits 137 on --gate-only).
  install_full_pass_shim gatedie
  run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" bash "$HOOK_SH" <<< "$(make_stop_payload devops "$blocked_text" adevops0050)"
  assert_success
  # Vacuity guard: the gate pass really died under the shim.
  [[ -e "$BATS_TEST_TMPDIR/gate-pass-started" ]]
  # Exactly one NEW record (seed + 1), and the newest is the BLOCKED one.
  [[ "$(find "$HOME/.claude/agent-status" -type f -name '*.json' | wc -l | tr -d ' ')" -eq 2 ]]
  local newest
  newest="$(ls -t "$HOME/.claude/agent-status"/*.json | head -1)"
  run grep -c '"status": "BLOCKED"' "$newest"
  assert_success
  assert_output "1"
  # End to end: the gate is blocked again, not left open by the stale DONE.
  run_dispatch "$(payload_for_session sess-gate-test Write "file_path=.github/workflows/x.yml")"
  assert_failure
  assert_output --partial "workflows-require-devops"
}

@test "S3d-5g: inherited gate vars in the hook env never become a record: a tick with CAST_GATE_MATCH/SAFE_* exported writes NO record" {
  local tick
  tick='{"agent_type":"","agent_id":"tick-ephemeral-0002","session_id":"sess-gate-test","stop_reason":"end_turn","last_assistant_message":"Done.\n\nStatus: DONE\nSummary: enclosing session"}'
  run env CAST_GATE_MATCH=DONE SAFE_AGENT=security SAFE_SESSION_ID=sess-x SAFE_ROSTER_TYPE=security \
    bash "$HOOK_SH" <<< "$tick"
  assert_success
  [[ "$(find "$HOME/.claude/agent-status" -type f | wc -l | tr -d ' ')" -eq 0 ]]
}

@test "S3d-5h: a real stop with WRONG inherited gate vars records the COMPUTED values, not the inherited ones" {
  local text
  text="$(printf 'Found a problem.\n\nStatus: BLOCKED\nSummary: stop\n')"
  write_sidecar adevops0060 '{"agentType":"devops"}'
  run env CAST_GATE_MATCH=DONE SAFE_AGENT=security SAFE_SESSION_ID=sess-x SAFE_ROSTER_TYPE=security \
    bash "$HOOK_SH" <<< "$(make_stop_payload devops "$text" adevops0060)"
  assert_success
  [[ "$(find "$HOME/.claude/agent-status" -type f -name '*.json' | wc -l | tr -d ' ')" -eq 1 ]]
  [[ -z "$(first_record security)" ]]
  local f
  f="$(first_record devops)"
  [[ -n "$f" ]]
  run grep -c '"status": "BLOCKED"' "$f"
  assert_success
  assert_output "1"
  run grep -c '"session_id": "sess-gate-test"' "$f"
  assert_success
  assert_output "1"
  run grep -c '"agent_type": "devops"' "$f"
  assert_success
  assert_output "1"
  run grep -c 'security\|sess-x' "$f"
  assert_failure
}

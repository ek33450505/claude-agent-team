#!/usr/bin/env bats

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
HOOK_SH="$REPO_DIR/scripts/pre-tool-guard.sh"

setup() {
  load 'helpers/setup'
  setup_temp_home
  export CLAUDE_DIR="$HOME/.claude"
  mkdir -p "$CLAUDE_DIR/agent-status"

  # Unset guard bypass env vars
  unset CLAUDE_SUBPROCESS
  unset CAST_POLICY_OVERRIDE
  unset CAST_COMMIT_AGENT
  unset CAST_PUSH_OK
}

teardown() {
  unset CLAUDE_DIR
  teardown_temp_home
}

# Helper: create a JSON status file with a specific mtime
create_status_file() {
  local name="$1"
  local age_minutes="$2"  # age in minutes from now
  local content="$3"

  local fpath="$CLAUDE_DIR/agent-status/$name"
  echo "$content" > "$fpath"

  # Adjust mtime: -mmin +N means older than N minutes
  # We need to set the file to be exactly age_minutes old
  local target_epoch
  target_epoch=$(date -v-${age_minutes}M +%s 2>/dev/null || date -d "-${age_minutes} minutes" +%s 2>/dev/null)
  if touch -d "@${target_epoch}" "$fpath" 2>/dev/null; then
    : # GNU touch succeeded
  else
    touch -t "$(date -r "$target_epoch" +%Y%m%d%H%M.%S)" "$fpath" 2>/dev/null || true
  fi
}

# Helper: create a Bash tool input JSON
make_bash_payload() {
  local cmd="${1:-echo test}"
  python3 -c "
import json
print(json.dumps({
  'tool_name': 'Bash',
  'tool_input': {
    'command': '$cmd',
    'description': 'test command'
  }
}))
" 2>/dev/null || echo '{"tool_name":"Bash","tool_input":{"command":"'"$cmd"'"}}'
}

# Helper: create a Write tool input JSON
make_write_payload() {
  local file_path="${1:-/tmp/test.txt}"
  python3 -c "
import json
print(json.dumps({
  'tool_name': 'Write',
  'tool_input': {
    'file_path': '$file_path',
    'content': 'test content'
  }
}))
" 2>/dev/null || echo '{"tool_name":"Write","tool_input":{"file_path":"'"$file_path"'"}}'
}

# ---------------------------------------------------------------------------
# TTL Sweep Tests
# ---------------------------------------------------------------------------

@test "TTL sweep: file older than 120 minutes is deleted" {
  # Create a file that is 150 minutes old (should be deleted)
  create_status_file "agent-old.json" 150 '{"status":"DONE"}'

  # Verify it exists before the hook
  [[ -f "$CLAUDE_DIR/agent-status/agent-old.json" ]]

  # Run hook with a Write tool call (triggers policy check and TTL sweep)
  run bash "$HOOK_SH" <<< "$(make_write_payload "/tmp/test.txt")"

  # File should be deleted by the sweep
  [[ ! -f "$CLAUDE_DIR/agent-status/agent-old.json" ]]
}

@test "TTL sweep: fresh file (less than 120 min old) is preserved" {
  # Create a file that is 60 minutes old (should be kept)
  create_status_file "agent-fresh.json" 60 '{"status":"DONE_WITH_CONCERNS"}'

  [[ -f "$CLAUDE_DIR/agent-status/agent-fresh.json" ]]

  run bash "$HOOK_SH" <<< "$(make_write_payload "/tmp/test.txt")"

  # File should still exist
  [[ -f "$CLAUDE_DIR/agent-status/agent-fresh.json" ]]
}

@test "TTL sweep: file 119 minutes old is preserved (below deletion threshold)" {
  # Create a file that is 119 minutes old (unambiguously below the 120 min deletion threshold)
  create_status_file "agent-boundary.json" 119 '{"status":"DONE"}'

  [[ -f "$CLAUDE_DIR/agent-status/agent-boundary.json" ]]

  run bash "$HOOK_SH" <<< "$(make_write_payload "/tmp/test.txt")"

  # File should still exist (below the +120 deletion threshold)
  [[ -f "$CLAUDE_DIR/agent-status/agent-boundary.json" ]]
}

@test "TTL sweep: multiple old files are all deleted" {
  create_status_file "agent1.json" 150 '{"status":"DONE"}'
  create_status_file "agent2.json" 200 '{"status":"DONE"}'
  create_status_file "agent3.json" 60 '{"status":"DONE"}'  # Should keep this one

  [[ -f "$CLAUDE_DIR/agent-status/agent1.json" ]]
  [[ -f "$CLAUDE_DIR/agent-status/agent2.json" ]]
  [[ -f "$CLAUDE_DIR/agent-status/agent3.json" ]]

  run bash "$HOOK_SH" <<< "$(make_write_payload "/tmp/test.txt")"

  # Old files deleted, fresh file kept
  [[ ! -f "$CLAUDE_DIR/agent-status/agent1.json" ]]
  [[ ! -f "$CLAUDE_DIR/agent-status/agent2.json" ]]
  [[ -f "$CLAUDE_DIR/agent-status/agent3.json" ]]
}

# ---------------------------------------------------------------------------
# Blocking Logic Tests
# ---------------------------------------------------------------------------

@test "Bash tool with safe echo command → passes guard (exit 0)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "echo hello")"
  assert_success
}

@test "Bash tool with safe ls command → passes guard (exit 0)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "ls -la /tmp")"
  assert_success
}

@test "git commit without escape hatch → blocks (exit 2)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git commit -m 'test'")"
  assert_failure
  assert_output --partial "git commit"
}

@test "git push without escape hatch → blocks (exit 2)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git push origin main")"
  assert_failure
  assert_output --partial "git push"
}

@test "git commit with CAST_COMMIT_AGENT escape hatch → allows (exit 0)" {
  # The escape hatch is in the command itself, which the script checks
  run bash "$HOOK_SH" <<< "$(make_bash_payload "CAST_COMMIT_AGENT=1 git commit -m 'test'")"
  assert_success
}

@test "CAST_COMMIT_AGENT=1 with extra VAR=value before git commit → allows (exit 0)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "CAST_COMMIT_AGENT=1 CAST_SKIP_PLUGIN_DRIFT=1 git commit -m 'test'")"
  assert_success
}

@test "extra VAR=value without CAST_COMMIT_AGENT hatch before git commit → still blocks (exit 2)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "CAST_SKIP_PLUGIN_DRIFT=1 git commit -m 'test'")"
  assert_failure
  assert_output --partial "git commit"
}

@test "plain git commit with no escape hatch → still blocks (exit 2) [regression]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git commit -m 'test'")"
  assert_failure
  assert_output --partial "git commit"
}

@test "git push with CAST_PUSH_OK escape hatch → allows (exit 0)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "CAST_PUSH_OK=1 git push origin main")"
  assert_success
}

# ---------------------------------------------------------------------------
# Subprocess Guard Tests — git commit/push/stash still block in subprocess
# (CLAUDE_SUBPROCESS skip moved inside cast-git-guard.py; only Write/Edit policy
#  + TTL sweep are subprocess-skipped; irreversibility guards are ALWAYS on)
# ---------------------------------------------------------------------------

@test "CLAUDE_SUBPROCESS=1 + git commit → still blocks (bypass removed for irreversibles)" {
  export CLAUDE_SUBPROCESS=1
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git commit -m 'test'")"
  assert_failure
  assert_output --partial "git commit"
}

@test "CLAUDE_SUBPROCESS=1 + git push → still blocks" {
  export CLAUDE_SUBPROCESS=1
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git push origin main")"
  assert_failure
  assert_output --partial "git push"
}

@test "CLAUDE_SUBPROCESS=1 + git stash → still blocks" {
  export CLAUDE_SUBPROCESS=1
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git stash")"
  assert_failure
  assert_output --partial "stash"
}

@test "CLAUDE_SUBPROCESS=1 + CAST_COMMIT_AGENT=1 git commit → escape hatch still allows" {
  export CLAUDE_SUBPROCESS=1
  run bash "$HOOK_SH" <<< "$(make_bash_payload "CAST_COMMIT_AGENT=1 git commit -m 'test'")"
  assert_success
}

@test "CLAUDE_SUBPROCESS=1 + CAST_PUSH_OK=1 git push → escape hatch still allows" {
  export CLAUDE_SUBPROCESS=1
  run bash "$HOOK_SH" <<< "$(make_bash_payload "CAST_PUSH_OK=1 git push origin main")"
  assert_success
}

@test "CLAUDE_SUBPROCESS=1 + Write tool → still allows (subprocess-skip preserved for Write/Edit)" {
  export CLAUDE_SUBPROCESS=1
  run bash "$HOOK_SH" <<< "$(make_write_payload "/tmp/test.txt")"
  assert_success
}

# ---------------------------------------------------------------------------
# Write/Edit Tool Policy Tests
# ---------------------------------------------------------------------------

@test "Write tool with safe path → passes (no policy blocking)" {
  run bash "$HOOK_SH" <<< "$(make_write_payload "/tmp/test.txt")"
  assert_success
}

@test "Write tool with safe path, subprocess=1 → passes" {
  export CLAUDE_SUBPROCESS=1
  run bash "$HOOK_SH" <<< "$(make_write_payload "/tmp/test.txt")"
  assert_success
}

# ---------------------------------------------------------------------------
# Non-Bash Tools Pass Through
# ---------------------------------------------------------------------------

@test "Read tool input → passes through (not intercepted)" {
  local payload
  payload=$(python3 -c "
import json
print(json.dumps({
  'tool_name': 'Read',
  'tool_input': {
    'file_path': '/tmp/test.txt'
  }
}))
" 2>/dev/null)

  run bash "$HOOK_SH" <<< "$payload"
  assert_success
}

@test "Glob tool input → passes through (not intercepted)" {
  local payload
  payload=$(python3 -c "
import json
print(json.dumps({
  'tool_name': 'Glob',
  'tool_input': {
    'pattern': '*.txt'
  }
}))
" 2>/dev/null)

  run bash "$HOOK_SH" <<< "$payload"
  assert_success
}

# ---------------------------------------------------------------------------
# Git Command Variations and Edge Cases
# ---------------------------------------------------------------------------

@test "git commit as part of subcommand (git commit -m with quotes) → blocks without escape hatch" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git commit -m 'testing edge case'")"
  # Should block because no escape hatch
  assert_failure
}

@test "escape hatch leading cd chain → allows (tolerates leading cd)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "cd /tmp && CAST_COMMIT_AGENT=1 git commit -m 'test'")"
  assert_success
}

# ---------------------------------------------------------------------------
# git -C global-option tolerance
# ---------------------------------------------------------------------------

@test "git -C /repo push without escape hatch → blocks (exit 2)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git -C /tmp/repo push origin main")"
  assert_failure
  assert_output --partial "git push"
}

@test "CAST_PUSH_OK=1 git -C /repo push → allows (exit 0)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "CAST_PUSH_OK=1 git -C /tmp/repo push origin main")"
  assert_success
}

@test "CAST_PUSH_OK=1 with additional env var (CAST_SKIP_BATS_PUSH=1) before git push → allows (exit 0)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "CAST_PUSH_OK=1 CAST_SKIP_BATS_PUSH=1 git push -u origin feature/x")"
  assert_success
}

@test "CAST_SKIP_BATS_PUSH=1 without CAST_PUSH_OK → still blocked (exit 2)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "CAST_SKIP_BATS_PUSH=1 git push -u origin feature/x")"
  assert_failure
  assert_output --partial "git push"
}

@test "git -C /repo commit without escape hatch → blocks (exit 2)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git -C /tmp/repo commit -m 'msg'")"
  assert_failure
  assert_output --partial "git commit"
}

@test "CAST_COMMIT_AGENT=1 git -C /repo commit → allows (exit 0)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "CAST_COMMIT_AGENT=1 git -C /tmp/repo commit -m 'msg'")"
  assert_success
}

@test "git commit with escape hatch only inside message → still blocks (exit 2)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git commit -m \"CAST_COMMIT_AGENT=1\"")"
  assert_failure
  assert_output --partial "git commit"
}

@test "CAST_COMMIT_AGENT=1 git commit → exits 0 and appends COMMIT_HATCH_USED to audit.jsonl without leaking commit message" {
  # Run from inside a git-init'd repo so _repo_toplevel() returns a non-empty path (E1).
  # Supply CAST_SESSION_ID so the event carries the expected session_id (E4).
  local test_repo="$HOME/hatch-test-repo"
  git init "$test_repo" >/dev/null 2>&1
  local payload
  payload="$(make_bash_payload "CAST_COMMIT_AGENT=1 git commit -m 'test hatch'")"
  run env CAST_SESSION_ID="hatch-sess-001" bash -c "cd '$test_repo' && bash '$HOOK_SH'" <<< "$payload"
  assert_success
  [[ -f "$HOME/.claude/logs/audit.jsonl" ]]
  grep -q 'COMMIT_HATCH_USED' "$HOME/.claude/logs/audit.jsonl"
  ! grep -q 'test hatch' "$HOME/.claude/logs/audit.jsonl"
  # E1: repo field must be non-empty (populated by _repo_toplevel() inside git repo)
  # E4: session_id must match CAST_SESSION_ID
  python3 -c "
import json, sys
lines = [l.strip() for l in open(sys.argv[1]) if 'COMMIT_HATCH_USED' in l]
assert lines, 'no COMMIT_HATCH_USED event found'
d = json.loads(lines[-1])
assert d.get('repo'), 'repo field missing or empty in hatch event: ' + repr(d)
assert d.get('session_id') == 'hatch-sess-001', 'session_id mismatch: ' + repr(d)
" "$HOME/.claude/logs/audit.jsonl"
}

@test "CAST_PUSH_OK=1 git push → exits 0 and appends PUSH_HATCH_USED to audit.jsonl" {
  # Run from inside a git-init'd repo so _repo_toplevel() returns a non-empty path.
  # Supply CAST_SESSION_ID so the event carries the expected session_id.
  local test_repo="$HOME/push-hatch-test-repo"
  git init "$test_repo" >/dev/null 2>&1
  local payload
  payload="$(make_bash_payload "CAST_PUSH_OK=1 git push origin main")"
  run env CAST_SESSION_ID="push-hatch-sess-001" bash -c "cd '$test_repo' && bash '$HOOK_SH'" <<< "$payload"
  assert_success
  [[ -f "$HOME/.claude/logs/audit.jsonl" ]]
  grep -q 'PUSH_HATCH_USED' "$HOME/.claude/logs/audit.jsonl"
  python3 -c "
import json, sys
lines = [l.strip() for l in open(sys.argv[1]) if 'PUSH_HATCH_USED' in l]
assert lines, 'no PUSH_HATCH_USED event found'
d = json.loads(lines[-1])
assert d.get('repo'), 'repo field missing or empty in hatch event: ' + repr(d)
assert d.get('session_id') == 'push-hatch-sess-001', 'session_id mismatch: ' + repr(d)
assert d.get('git_op') == 'push', 'git_op mismatch: ' + repr(d)
assert d.get('override_env') == 'CAST_PUSH_OK', 'override_env mismatch: ' + repr(d)
" "$HOME/.claude/logs/audit.jsonl"
}

# ---------------------------------------------------------------------------
# Hatch event session_id resolution (E4 — D5 hardening)
# ---------------------------------------------------------------------------

@test "hatch event: CLAUDE_SESSION_ID alone populates session_id when CAST_SESSION_ID absent" {
  local test_repo="$HOME/hatch-claude-repo"
  git init "$test_repo" >/dev/null 2>&1
  local payload
  payload="$(make_bash_payload "CAST_COMMIT_AGENT=1 git commit -m 'test'")"
  run env -u CAST_SESSION_ID CLAUDE_SESSION_ID="claude-only-sess" \
      bash -c "cd '$test_repo' && bash '$HOOK_SH'" <<< "$payload"
  assert_success
  python3 -c "
import json, sys
lines = [l.strip() for l in open(sys.argv[1]) if 'COMMIT_HATCH_USED' in l]
assert lines, 'no COMMIT_HATCH_USED event found'
d = json.loads(lines[-1])
assert d.get('session_id') == 'claude-only-sess', 'session_id mismatch: ' + repr(d)
" "$HOME/.claude/logs/audit.jsonl"
}

@test "hatch event: both session envs unset + 2 active DB sessions → session_id empty (Defect-3 guard)" {
  local test_repo="$HOME/hatch-2sess-repo"
  git init "$test_repo" >/dev/null 2>&1
  local real_repo
  real_repo="$(python3 -c 'import os; print(os.path.realpath("'"$test_repo"'"))')"
  # Provision a DB and insert 2 active sessions for this repo's project_root.
  local test_db="$HOME/.claude/cast.db"
  mkdir -p "$HOME/.claude"
  env CAST_DB_PATH="$test_db" bash "$REPO_DIR/scripts/cast-db-init.sh" >/dev/null 2>&1
  python3 -c "
import sqlite3, sys
conn = sqlite3.connect(sys.argv[1])
conn.execute('INSERT INTO sessions (id, project_root, status, started_at) VALUES (?,?,?,?)',
             ('sess-dead-a', sys.argv[2], 'active', '2026-07-04T22:40:00'))
conn.execute('INSERT INTO sessions (id, project_root, status, started_at) VALUES (?,?,?,?)',
             ('sess-dead-b', sys.argv[2], 'active', '2026-07-04T22:40:30'))
conn.commit()
conn.close()
" "$test_db" "$real_repo"
  local payload
  payload="$(make_bash_payload "CAST_COMMIT_AGENT=1 git commit -m 'test'")"
  run env -u CAST_SESSION_ID -u CLAUDE_SESSION_ID \
      CAST_DB_PATH="$test_db" \
      bash -c "cd '$test_repo' && bash '$HOOK_SH'" <<< "$payload"
  assert_success
  python3 -c "
import json, sys
lines = [l.strip() for l in open(sys.argv[1]) if 'COMMIT_HATCH_USED' in l]
assert lines, 'no COMMIT_HATCH_USED event found'
d = json.loads(lines[-1])
assert d.get('session_id') == '', 'expected empty session_id with 2 active sessions, got: ' + repr(d)
" "$HOME/.claude/logs/audit.jsonl"
}

@test "hatch event: not inside git repo → repo field empty string, event still written (fail-open)" {
  # Run hook from $HOME (temp dir, not a git repo) → _repo_toplevel() returns '' gracefully.
  local payload
  payload="$(make_bash_payload "CAST_COMMIT_AGENT=1 git commit -m 'test'")"
  run bash -c "cd '$HOME' && bash '$HOOK_SH'" <<< "$payload"
  assert_success
  [[ -f "$HOME/.claude/logs/audit.jsonl" ]]
  grep -q 'COMMIT_HATCH_USED' "$HOME/.claude/logs/audit.jsonl"
  python3 -c "
import json, sys
lines = [l.strip() for l in open(sys.argv[1]) if 'COMMIT_HATCH_USED' in l]
assert lines, 'no COMMIT_HATCH_USED event found'
d = json.loads(lines[-1])
assert d.get('repo') == '', 'expected empty repo outside git repo, got: ' + repr(d)
" "$HOME/.claude/logs/audit.jsonl"
}

@test "CAST_STASH_OK=1 git -C /tmp/repo stash → allows (exit 0)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "CAST_STASH_OK=1 git -C /tmp/repo stash")"
  assert_success
}

# ---------------------------------------------------------------------------
# Empty Input Handling
# ---------------------------------------------------------------------------

@test "empty input → exits 0 (graceful no-op)" {
  run bash "$HOOK_SH" <<< ""
  assert_success
}

@test "malformed JSON input → exits 0 (graceful failure)" {
  run bash "$HOOK_SH" <<< "not valid json at all"
  assert_success
}

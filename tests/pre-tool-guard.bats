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
# git stash token-boundary regex fix (2026-08-17 follow-up security review;
# pre-existing flaw, same class as the reset/checkout fixes below) —
# adjacent empty-output command substitution defeated the old literal
# trailing-whitespace requirement.
# ---------------------------------------------------------------------------

@test "git stash\`true\` (adjacent command substitution, backticks) → blocks (exit 2)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload 'git stash`true`')"
  assert_failure
  assert_output --partial "stash"
}

@test "git stash\$(true) (adjacent command substitution) → blocks (exit 2)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload 'git stash$(true)')"
  assert_failure
  assert_output --partial "stash"
}

@test "git stashsomething (look-alike token) → allows (exit 0) [regression: no false positive]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git stashsomething")"
  assert_success
}

# ---------------------------------------------------------------------------
# git reset --hard/--merge/--keep block Tests (2026-08-17 incident)
# ---------------------------------------------------------------------------

@test "git reset --hard without escape hatch → blocks (exit 2)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git reset --hard")"
  assert_failure
  assert_output --partial "reset"
}

@test "git reset --hard HEAD without escape hatch → blocks (exit 2)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git reset --hard HEAD")"
  assert_failure
  assert_output --partial "reset"
}

@test "git reset HEAD --hard (flag after ref) without escape hatch → blocks (exit 2)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git reset HEAD --hard")"
  assert_failure
  assert_output --partial "reset"
}

@test "git reset --merge without escape hatch → blocks (exit 2)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git reset --merge")"
  assert_failure
  assert_output --partial "reset"
}

@test "git reset --keep without escape hatch → blocks (exit 2)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git reset --keep")"
  assert_failure
  assert_output --partial "reset"
}

@test "bare git reset (index-only) → allows (exit 0) [regression: no false positive]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git reset")"
  assert_success
}

@test "git reset --soft HEAD~1 (index-only) → allows (exit 0) [regression: no false positive]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git reset --soft HEAD~1")"
  assert_success
}

@test "git reset --mixed (index-only) → allows (exit 0) [regression: no false positive]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git reset --mixed")"
  assert_success
}

@test "git reset HEAD file.txt (unstage a file) → allows (exit 0) [regression: no false positive]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git reset HEAD file.txt")"
  assert_success
}

@test "CAST_RESET_OK=1 git reset --hard → allows (exit 0)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "CAST_RESET_OK=1 git reset --hard")"
  assert_success
}

@test "CAST_RESET_OK=1 with extra VAR=value before git reset --hard → allows (exit 0)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "CAST_RESET_OK=1 CAST_SKIP_PLUGIN_DRIFT=1 git reset --hard")"
  assert_success
}

@test "CLAUDE_SUBPROCESS=1 + git reset --hard → still blocks (irreversibility guard always on)" {
  export CLAUDE_SUBPROCESS=1
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git reset --hard")"
  assert_failure
  assert_output --partial "reset"
}

@test "multiline: CAST_RESET_OK=1 on line 2 does NOT unblock git reset --hard on line 1" {
  local payload
  payload=$(python3 -c "
import json, sys
print(json.dumps({'tool_name': 'Bash', 'tool_input': {'command': sys.argv[1]}}))
" $'git reset --hard\nCAST_RESET_OK=1')
  run bash "$HOOK_SH" <<< "$payload"
  assert_failure
  assert_output --partial "reset"
}

# ---------------------------------------------------------------------------
# git reset token-boundary regex fix (2026-08-17 follow-up security review) —
# adjacent empty-output command substitution defeated the old literal
# trailing-whitespace requirement.
# ---------------------------------------------------------------------------

@test "git reset --hard\$(true) (adjacent command substitution) → blocks (exit 2)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload 'git reset --hard$(true)')"
  assert_failure
  assert_output --partial "reset"
}

@test "git reset --merge\$(true) (adjacent command substitution) → blocks (exit 2)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload 'git reset --merge$(true)')"
  assert_failure
  assert_output --partial "reset"
}

@test "git reset --keep\`true\` (adjacent command substitution, backticks) → blocks (exit 2)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload 'git reset --keep`true`')"
  assert_failure
  assert_output --partial "reset"
}

@test "git reset --hardcore (look-alike flag) → allows (exit 0) [regression: no false positive]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload 'git reset --hardcore')"
  assert_success
}

# ---------------------------------------------------------------------------
# git clean block Tests (2026-08-17 incident)
# ---------------------------------------------------------------------------

@test "git clean -fd without escape hatch → blocks (exit 2)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git clean -fd")"
  assert_failure
  assert_output --partial "clean"
}

@test "git clean -fdx without escape hatch → blocks (exit 2)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git clean -fdx")"
  assert_failure
  assert_output --partial "clean"
}

@test "git clean -f without escape hatch → blocks (exit 2)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git clean -f")"
  assert_failure
  assert_output --partial "clean"
}

@test "bare git clean without escape hatch → blocks (exit 2)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git clean")"
  assert_failure
  assert_output --partial "clean"
}

@test "git clean -n (dry run) → allows (exit 0) [regression: no false positive]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git clean -n")"
  assert_success
}

@test "git clean --dry-run → allows (exit 0) [regression: no false positive]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git clean --dry-run")"
  assert_success
}

@test "CAST_CLEAN_OK=1 git clean -fd → allows (exit 0)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "CAST_CLEAN_OK=1 git clean -fd")"
  assert_success
}

@test "CAST_CLEAN_OK=1 with extra VAR=value before git clean -fd → allows (exit 0)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "CAST_CLEAN_OK=1 CAST_SKIP_PLUGIN_DRIFT=1 git clean -fd")"
  assert_success
}

@test "CLAUDE_SUBPROCESS=1 + git clean -fd → still blocks (irreversibility guard always on)" {
  export CLAUDE_SUBPROCESS=1
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git clean -fd")"
  assert_failure
  assert_output --partial "clean"
}

@test "multiline: CAST_CLEAN_OK=1 on line 2 does NOT unblock git clean -fd on line 1" {
  local payload
  payload=$(python3 -c "
import json, sys
print(json.dumps({'tool_name': 'Bash', 'tool_input': {'command': sys.argv[1]}}))
" $'git clean -fd\nCAST_CLEAN_OK=1')
  run bash "$HOOK_SH" <<< "$payload"
  assert_failure
  assert_output --partial "clean"
}

# ---------------------------------------------------------------------------
# git checkout (pathspec) block Tests (2026-08-17 incident class — the same
# mechanism a READ-ONLY code-reviewer used to silently revert its own review)
# ---------------------------------------------------------------------------

@test "git checkout -- . without escape hatch → blocks (exit 2)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git checkout -- .")"
  assert_failure
  assert_output --partial "checkout"
}

@test "git checkout -- src/f.py without escape hatch → blocks (exit 2)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git checkout -- src/f.py")"
  assert_failure
  assert_output --partial "checkout"
}

@test "git checkout . without escape hatch → blocks (exit 2)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git checkout .")"
  assert_failure
  assert_output --partial "checkout"
}

@test "git checkout main (branch op) → allows (exit 0) [regression: no false positive]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git checkout main")"
  assert_success
}

@test "git checkout -b feature/x (new branch) → allows (exit 0) [regression: no false positive]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git checkout -b feature/x")"
  assert_success
}

@test "git checkout - (previous branch) → allows (exit 0) [regression: no false positive]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git checkout -")"
  assert_success
}

@test "git checkout --track origin/feature/x → allows (exit 0) [regression: no false positive]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git checkout --track origin/feature/x")"
  assert_success
}

@test "CAST_CHECKOUT_OK=1 git checkout -- . → allows (exit 0)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "CAST_CHECKOUT_OK=1 git checkout -- .")"
  assert_success
}

@test "CAST_CHECKOUT_OK=1 with extra VAR=value before git checkout -- . → allows (exit 0)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "CAST_CHECKOUT_OK=1 CAST_SKIP_PLUGIN_DRIFT=1 git checkout -- .")"
  assert_success
}

@test "CLAUDE_SUBPROCESS=1 + git checkout -- . → still blocks (irreversibility guard always on)" {
  export CLAUDE_SUBPROCESS=1
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git checkout -- .")"
  assert_failure
  assert_output --partial "checkout"
}

@test "multiline: CAST_CHECKOUT_OK=1 on line 2 does NOT unblock git checkout -- . on line 1" {
  local payload
  payload=$(python3 -c "
import json, sys
print(json.dumps({'tool_name': 'Bash', 'tool_input': {'command': sys.argv[1]}}))
" $'git checkout -- .\nCAST_CHECKOUT_OK=1')
  run bash "$HOOK_SH" <<< "$payload"
  assert_failure
  assert_output --partial "checkout"
}

# ---------------------------------------------------------------------------
# git checkout token-boundary regex fix (2026-08-17 follow-up security
# review) — adjacent empty-output command substitution defeated the old
# literal trailing-whitespace requirement on the bare-`.` form.
# ---------------------------------------------------------------------------

@test "git checkout .\$(true) (adjacent command substitution) → blocks (exit 2)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload 'git checkout .$(true)')"
  assert_failure
  assert_output --partial "checkout"
}

@test "git checkout .github (look-alike dotfile-ish arg) → allows (exit 0) [regression: no false positive]" {
  # Run from an isolated cwd with no `.github` on disk: this test targets the
  # _CHECKOUT_BLOCK regex's bare-dot lookahead specifically (does `.github`
  # false-match the literal-`.` alternative?), not the separate bare-token
  # filesystem-existence heuristic added below (2026-08-17 2nd follow-up) —
  # that heuristic WOULD correctly block `git checkout .github` from THIS
  # repo's own root, since `.github/` really exists here (see the dedicated
  # "existing nested/top-level file" tests for that behavior).
  local test_repo="$HOME/checkout-dotfile-repo"
  mkdir -p "$test_repo"
  run bash -c "cd '$test_repo' && bash '$HOOK_SH'" <<< "$(make_bash_payload "git checkout .github")"
  assert_success
}

@test "git checkout ./foo (relative pathspec, not bare dot) → allows (exit 0) [regression: no false positive]" {
  local test_repo="$HOME/checkout-relpath-repo"
  mkdir -p "$test_repo"
  run bash -c "cd '$test_repo' && bash '$HOOK_SH'" <<< "$(make_bash_payload "git checkout ./foo")"
  assert_success
}

# ---------------------------------------------------------------------------
# git checkout <bare pathspec, no --> block Tests (2026-08-17 second
# follow-up security review — the EXACT form of the 2026-08-15 incident:
# a read-only code-reviewer silently reverted `completions/cast.bash` via
# `git checkout completions/cast.bash`, with no `--` and no bare `.`.)
# ---------------------------------------------------------------------------

@test "git checkout <existing nested file, no --> → blocks (exit 2) [2026-08-15 incident's exact command]" {
  local test_repo="$HOME/checkout-bare-repo"
  mkdir -p "$test_repo/completions"
  echo "fixture" > "$test_repo/completions/cast.bash"
  local payload
  payload="$(make_bash_payload "git checkout completions/cast.bash")"
  run bash -c "cd '$test_repo' && bash '$HOOK_SH'" <<< "$payload"
  assert_failure
  assert_output --partial "checkout"
}

@test "git checkout <existing top-level file, no --> → blocks (exit 2)" {
  local test_repo="$HOME/checkout-bare-repo2"
  mkdir -p "$test_repo"
  echo "fixture" > "$test_repo/f.txt"
  local payload
  payload="$(make_bash_payload "git checkout f.txt")"
  run bash -c "cd '$test_repo' && bash '$HOOK_SH'" <<< "$payload"
  assert_failure
  assert_output --partial "checkout"
}

@test "CAST_CHECKOUT_OK=1 git checkout <existing file, no --> → allows (exit 0)" {
  local test_repo="$HOME/checkout-bare-repo3"
  mkdir -p "$test_repo"
  echo "fixture" > "$test_repo/f.txt"
  local payload
  payload="$(make_bash_payload "CAST_CHECKOUT_OK=1 git checkout f.txt")"
  run bash -c "cd '$test_repo' && bash '$HOOK_SH'" <<< "$payload"
  assert_success
}

@test "git checkout <token that does NOT exist on disk> (branch name) → allows (exit 0) [regression: no false positive]" {
  local test_repo="$HOME/checkout-bare-repo4"
  mkdir -p "$test_repo"
  local payload
  payload="$(make_bash_payload "git checkout some-branch-name")"
  run bash -c "cd '$test_repo' && bash '$HOOK_SH'" <<< "$payload"
  assert_success
}

@test "git checkout release/1.0.0 (branch name shaped like a path, no matching dir) → allows (exit 0) [regression: no false positive]" {
  local test_repo="$HOME/checkout-bare-repo5"
  mkdir -p "$test_repo"
  local payload
  payload="$(make_bash_payload "git checkout release/1.0.0")"
  run bash -c "cd '$test_repo' && bash '$HOOK_SH'" <<< "$payload"
  assert_success
}

@test "git checkout HEAD~1 (ref, not a path) → allows (exit 0) [regression: no false positive]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload 'git checkout HEAD~1')"
  assert_success
}

@test "git checkout @{-1} (ref shorthand, not a path) → allows (exit 0) [regression: no false positive]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload 'git checkout @{-1}')"
  assert_success
}

@test "git checkout --detach (flag, no pathspec) → allows (exit 0) [regression: no false positive]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git checkout --detach")"
  assert_success
}

@test "git checkout -B main origin/main (multi-token branch-create form) → allows (exit 0) [regression: no false positive]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git checkout -B main origin/main")"
  assert_success
}

# ---------------------------------------------------------------------------
# git checkout -f/--force block Tests (2026-08-17 third follow-up, final
# round before ship) — forces a branch switch through local changes,
# discarding them, same as bare-pathspec checkout.
# ---------------------------------------------------------------------------

@test "git checkout -f main → blocks (exit 2)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git checkout -f main")"
  assert_failure
  assert_output --partial "checkout"
}

@test "git checkout --force main → blocks (exit 2)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git checkout --force main")"
  assert_failure
  assert_output --partial "checkout"
}

@test "git checkout -f (bare, no branch arg) → blocks (exit 2)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git checkout -f")"
  assert_failure
  assert_output --partial "checkout"
}

@test "git checkout -f -b new (force combined with branch-create) → blocks (exit 2)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git checkout -f -b new")"
  assert_failure
  assert_output --partial "checkout"
}

@test "CAST_CHECKOUT_OK=1 git checkout -f main → allows (exit 0)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "CAST_CHECKOUT_OK=1 git checkout -f main")"
  assert_success
}

@test "git checkout -b new (regression: -b must not misfire as -f) → allows (exit 0)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git checkout -b new")"
  assert_success
}

# ---------------------------------------------------------------------------
# git checkout -f clustered short-flag completion (2026-08-17 fourth
# follow-up) — `git checkout -fb newbranch` is valid git, parsed as
# `-f -b newbranch` (confirmed: `git checkout -fb` alone errors with
# "switch `b' requires a value"), and is fully destructive, but the initial
# standalone-`-f`-only regex missed it. Same fix shape as `_CLEAN_DRY_RUN`
# clustering.
# ---------------------------------------------------------------------------

@test "git checkout -fb newbranch (clustered force+branch-create) → blocks (exit 2)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git checkout -fb newbranch")"
  assert_failure
  assert_output --partial "checkout"
}

@test "git checkout -bf newbranch (clustered, reversed order) → blocks (exit 2)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git checkout -bf newbranch")"
  assert_failure
  assert_output --partial "checkout"
}

@test "CAST_CHECKOUT_OK=1 git checkout -fb newbranch → allows (exit 0)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "CAST_CHECKOUT_OK=1 git checkout -fb newbranch")"
  assert_success
}

@test "git checkout -B main origin/main (no f in cluster) → allows (exit 0) [regression: no false positive]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git checkout -B main origin/main")"
  assert_success
}

@test "git checkout -q main (no f in cluster) → allows (exit 0) [regression: no false positive]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git checkout -q main")"
  assert_success
}

@test "git checkout -t origin/x (no f in cluster) → allows (exit 0) [regression: no false positive]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git checkout -t origin/x")"
  assert_success
}

@test "git checkout -p (no f in cluster) → allows (exit 0) [regression: no false positive]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git checkout -p")"
  assert_success
}

@test "git checkout -m (no f in cluster) → allows (exit 0) [regression: no false positive]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git checkout -m")"
  assert_success
}

# ---------------------------------------------------------------------------
# git restore block Tests (2026-08-17 incident class)
# ---------------------------------------------------------------------------

@test "git restore . without escape hatch → blocks (exit 2)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git restore .")"
  assert_failure
  assert_output --partial "restore"
}

@test "git restore file.txt (bare, worktree-destructive) without escape hatch → blocks (exit 2)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git restore file.txt")"
  assert_failure
  assert_output --partial "restore"
}

@test "git restore --staged --worktree . (worktree present) without escape hatch → blocks (exit 2)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git restore --staged --worktree .")"
  assert_failure
  assert_output --partial "restore"
}

@test "git restore --staged file.txt (index-only) → allows (exit 0) [regression: no false positive]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git restore --staged file.txt")"
  assert_success
}

@test "CAST_RESTORE_OK=1 git restore . → allows (exit 0)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "CAST_RESTORE_OK=1 git restore .")"
  assert_success
}

@test "CAST_RESTORE_OK=1 with extra VAR=value before git restore . → allows (exit 0)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "CAST_RESTORE_OK=1 CAST_SKIP_PLUGIN_DRIFT=1 git restore .")"
  assert_success
}

@test "CLAUDE_SUBPROCESS=1 + git restore . → still blocks (irreversibility guard always on)" {
  export CLAUDE_SUBPROCESS=1
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git restore .")"
  assert_failure
  assert_output --partial "restore"
}

@test "multiline: CAST_RESTORE_OK=1 on line 2 does NOT unblock git restore . on line 1" {
  local payload
  payload=$(python3 -c "
import json, sys
print(json.dumps({'tool_name': 'Bash', 'tool_input': {'command': sys.argv[1]}}))
" $'git restore .\nCAST_RESTORE_OK=1')
  run bash "$HOOK_SH" <<< "$payload"
  assert_failure
  assert_output --partial "restore"
}

# ---------------------------------------------------------------------------
# git switch block Tests (2026-08-17 third follow-up, final round before
# ship) — `git switch` is the modern branch-changing half of `checkout` and
# was previously COMPLETELY unguarded. Unlike checkout, plain `git switch
# <branch>` is NOT destructive (git refuses it on conflicting local
# changes), so only the force/discard forms block. Own hatch: CAST_SWITCH_OK=1.
# ---------------------------------------------------------------------------

@test "git switch --discard-changes main → blocks (exit 2)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git switch --discard-changes main")"
  assert_failure
  assert_output --partial "switch"
}

@test "git switch -f main → blocks (exit 2)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git switch -f main")"
  assert_failure
  assert_output --partial "switch"
}

@test "git switch --force main → blocks (exit 2)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git switch --force main")"
  assert_failure
  assert_output --partial "switch"
}

@test "git switch main (plain, not destructive) → allows (exit 0) [regression: no false positive]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git switch main")"
  assert_success
}

@test "git switch -c new-branch (create) → allows (exit 0) [regression: no false positive]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git switch -c new-branch")"
  assert_success
}

@test "git switch - (previous branch) → allows (exit 0) [regression: no false positive]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git switch -")"
  assert_success
}

@test "git switch --detach → allows (exit 0) [regression: no false positive]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git switch --detach")"
  assert_success
}

@test "CAST_SWITCH_OK=1 git switch -f main → allows (exit 0)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "CAST_SWITCH_OK=1 git switch -f main")"
  assert_success
}

@test "CAST_SWITCH_OK=1 with extra VAR=value before git switch -f main → allows (exit 0)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "CAST_SWITCH_OK=1 CAST_SKIP_PLUGIN_DRIFT=1 git switch -f main")"
  assert_success
}

@test "CLAUDE_SUBPROCESS=1 + git switch -f main → still blocks (irreversibility guard always on)" {
  export CLAUDE_SUBPROCESS=1
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git switch -f main")"
  assert_failure
  assert_output --partial "switch"
}

@test "multiline: CAST_SWITCH_OK=1 on line 2 does NOT unblock git switch -f main on line 1" {
  local payload
  payload=$(python3 -c "
import json, sys
print(json.dumps({'tool_name': 'Bash', 'tool_input': {'command': sys.argv[1]}}))
" $'git switch -f main\nCAST_SWITCH_OK=1')
  run bash "$HOOK_SH" <<< "$payload"
  assert_failure
  assert_output --partial "switch"
}

@test "git switch -fc new (clustered force+create) → blocks (exit 2)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git switch -fc new")"
  assert_failure
  assert_output --partial "switch"
}

@test "CAST_SWITCH_OK=1 git switch -fc new → allows (exit 0)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "CAST_SWITCH_OK=1 git switch -fc new")"
  assert_success
}

# ---------------------------------------------------------------------------
# Same-line chaining / ALLOW short-circuit Tests (2026-08-17 security fix)
# A matched hatch must suppress ONLY its own op's block, not every later
# destructive op chained on the same line via `;` or `&&`.
# ---------------------------------------------------------------------------

@test "CAST_STASH_OK=1 git stash pop; git reset --hard; git clean -fdx → still blocks (chained bypass)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "CAST_STASH_OK=1 git stash pop; git reset --hard; git clean -fdx")"
  assert_failure
}

@test "CAST_RESET_OK=1 git reset --hard && git clean -fdx → still blocks (chained bypass)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "CAST_RESET_OK=1 git reset --hard && git clean -fdx")"
  assert_failure
  assert_output --partial "clean"
}

@test "CAST_PUSH_OK=1 git push; git clean -fdx → still blocks (chained bypass)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "CAST_PUSH_OK=1 git push; git clean -fdx")"
  assert_failure
  assert_output --partial "clean"
}

@test "CAST_COMMIT_AGENT=1 git commit -m x && git push --force → still blocks (chained bypass, original commit/push trio)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "CAST_COMMIT_AGENT=1 git commit -m x && git push --force")"
  assert_failure
  assert_output --partial "push"
}

@test "single-op hatches unaffected by the independent-evaluation fix (commit/push/stash/reset/clean/checkout/restore)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "CAST_COMMIT_AGENT=1 git commit -m x")"
  assert_success
  run bash "$HOOK_SH" <<< "$(make_bash_payload "CAST_PUSH_OK=1 git push")"
  assert_success
  run bash "$HOOK_SH" <<< "$(make_bash_payload "CAST_STASH_OK=1 git stash")"
  assert_success
  run bash "$HOOK_SH" <<< "$(make_bash_payload "CAST_RESET_OK=1 git reset --hard")"
  assert_success
  run bash "$HOOK_SH" <<< "$(make_bash_payload "CAST_CLEAN_OK=1 git clean -fd")"
  assert_success
  run bash "$HOOK_SH" <<< "$(make_bash_payload "CAST_CHECKOUT_OK=1 git checkout -- .")"
  assert_success
  run bash "$HOOK_SH" <<< "$(make_bash_payload "CAST_RESTORE_OK=1 git restore .")"
  assert_success
}

@test "combined-prefix hatch (CAST_RESET_OK=1 CAST_CLEAN_OK=1 git reset --hard && git clean -fdx) → BLOCKS (intentional strictness)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "CAST_RESET_OK=1 CAST_CLEAN_OK=1 git reset --hard && git clean -fdx")"
  assert_failure
  assert_output --partial "clean"
}

@test "per-command hatch (CAST_RESET_OK=1 git reset --hard && CAST_CLEAN_OK=1 git clean -fdx) → ALLOWED" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "CAST_RESET_OK=1 git reset --hard && CAST_CLEAN_OK=1 git clean -fdx")"
  assert_success
}

# ---------------------------------------------------------------------------
# git clean dry-run flag-cluster Tests (2026-08-17 false-positive fix)
# ---------------------------------------------------------------------------

@test "git clean -nd (clustered dry-run+directories) → allows (exit 0) [false-positive fix]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git clean -nd")"
  assert_success
}

@test "git clean -dn (clustered, reversed order) → allows (exit 0) [false-positive fix]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git clean -dn")"
  assert_success
}

@test "git clean -fn (clustered dry-run+force) → allows (exit 0) [false-positive fix]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git clean -fn")"
  assert_success
}

@test "git clean -nfd (clustered, dry-run first) → allows (exit 0) [false-positive fix]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git clean -nfd")"
  assert_success
}

@test "git clean -d (no n, destructive) → still blocks (exit 2) [regression: no false negative]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git clean -d")"
  assert_failure
  assert_output --partial "clean"
}

@test "git clean -xfd (no n, destructive) → still blocks (exit 2) [regression: no false negative]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git clean -xfd")"
  assert_failure
  assert_output --partial "clean"
}

@test "git clean --interactive → still blocks (exit 2) [must not misfire as dry-run on long-flag 'n']" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git clean --interactive")"
  assert_failure
  assert_output --partial "clean"
}

# ---------------------------------------------------------------------------
# Same-op hatch bleed Tests (2026-08-17 follow-up security fix)
# A hatch attached to a HARMLESS invocation of an op must NOT unlock a
# DESTRUCTIVE invocation of the SAME op later on the line — per-segment
# evaluation (split on ; && || |), not per-line.
# ---------------------------------------------------------------------------

@test "CAST_RESET_OK=1 git reset --soft && git reset --hard → still blocks (same-op bleed)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "CAST_RESET_OK=1 git reset --soft && git reset --hard")"
  assert_failure
  assert_output --partial "reset"
}

@test "CAST_CLEAN_OK=1 git clean -n && git clean -fdx → still blocks (same-op bleed)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "CAST_CLEAN_OK=1 git clean -n && git clean -fdx")"
  assert_failure
  assert_output --partial "clean"
}

@test "CAST_CHECKOUT_OK=1 git checkout main && git checkout -- . → still blocks (same-op bleed)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "CAST_CHECKOUT_OK=1 git checkout main && git checkout -- .")"
  assert_failure
  assert_output --partial "checkout"
}

@test "CAST_RESTORE_OK=1 git restore --staged x && git restore . → still blocks (same-op bleed)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "CAST_RESTORE_OK=1 git restore --staged x && git restore .")"
  assert_failure
  assert_output --partial "restore"
}

@test "CAST_STASH_OK=1 git stash list && git stash → still blocks (same-op bleed)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "CAST_STASH_OK=1 git stash list && git stash")"
  assert_failure
  assert_output --partial "stash"
}

@test "CAST_PUSH_OK=1 git push; git push --force → still blocks (same-op bleed)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "CAST_PUSH_OK=1 git push; git push --force")"
  assert_failure
  assert_output --partial "push"
}

@test "CAST_COMMIT_AGENT=1 git commit --dry-run && git commit -m x → still blocks (same-op bleed, pre-existing at HEAD)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "CAST_COMMIT_AGENT=1 git commit --dry-run && git commit -m x")"
  assert_failure
  assert_output --partial "commit"
}

@test "per-command chained hatch (CAST_RESET_OK=1 git reset --hard && CAST_CLEAN_OK=1 git clean -fdx) → still ALLOWED after segmentation" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "CAST_RESET_OK=1 git reset --hard && CAST_CLEAN_OK=1 git clean -fdx")"
  assert_success
}

@test "combined-prefix hatch still BLOCKS after segmentation (CAST_RESET_OK=1 CAST_CLEAN_OK=1 git reset --hard && git clean -fdx)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "CAST_RESET_OK=1 CAST_CLEAN_OK=1 git reset --hard && git clean -fdx")"
  assert_failure
  assert_output --partial "clean"
}

@test "harmless multi-segment lines still allowed after segmentation (git status && git diff)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git status && git diff")"
  assert_success
}

@test "harmless piped line still allowed after segmentation (git log --oneline | head -5)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git log --oneline | head -5")"
  assert_success
}

@test "harmless mixed ; and && line still allowed after segmentation (git diff && git status; git add -A)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git diff && git status; git add -A")"
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

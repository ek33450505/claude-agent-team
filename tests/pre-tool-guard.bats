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
# git reflog expire/delete block (2026-08-17 recovery-path pass)
# ---------------------------------------------------------------------------

@test "git reflog expire --expire=now --all without escape hatch → blocks (exit 2)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git reflog expire --expire=now --all")"
  assert_failure
  assert_output --partial "reflog"
}

@test "git reflog expire --expire-unreachable=now --all without escape hatch → blocks (exit 2)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git reflog expire --expire-unreachable=now --all")"
  assert_failure
  assert_output --partial "reflog"
}

@test "git reflog delete HEAD@{0} without escape hatch → blocks (exit 2)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git reflog delete HEAD@{0}")"
  assert_failure
  assert_output --partial "reflog"
}

@test "git reflog (bare, read-only) → allows (exit 0) [regression: no false positive]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git reflog")"
  assert_success
}

@test "git reflog show HEAD (read-only) → allows (exit 0) [regression: no false positive]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git reflog show HEAD")"
  assert_success
}

@test "git reflog exists refs/heads/main (read-only) → allows (exit 0) [regression: no false positive]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git reflog exists refs/heads/main")"
  assert_success
}

@test "CAST_REFLOG_OK=1 git reflog expire --expire=now --all → allows (exit 0)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "CAST_REFLOG_OK=1 git reflog expire --expire=now --all")"
  assert_success
}

@test "CAST_REFLOG_OK=1 with extra VAR=value before git reflog expire → allows (exit 0)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "CAST_REFLOG_OK=1 CAST_SKIP_PLUGIN_DRIFT=1 git reflog expire --expire=now --all")"
  assert_success
}

@test "CLAUDE_SUBPROCESS=1 + git reflog delete HEAD@{0} → still blocks (irreversibility guard always on)" {
  export CLAUDE_SUBPROCESS=1
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git reflog delete HEAD@{0}")"
  assert_failure
  assert_output --partial "reflog"
}

@test "git reflog expire\`true\` (adjacent command substitution) → blocks (exit 2)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload 'git reflog expire`true`')"
  assert_failure
  assert_output --partial "reflog"
}

# ---------------------------------------------------------------------------
# git gc --prune=<value> block (2026-08-17 recovery-path pass)
# ---------------------------------------------------------------------------

@test "git gc --prune=now without escape hatch → blocks (exit 2)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git gc --prune=now")"
  assert_failure
  assert_output --partial "gc"
}

@test "git gc --prune=all without escape hatch → blocks (exit 2)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git gc --prune=all")"
  assert_failure
  assert_output --partial "gc"
}

@test "git gc --prune=1.hour.ago without escape hatch → blocks (exit 2)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git gc --prune=1.hour.ago")"
  assert_failure
  assert_output --partial "gc"
}

@test "bare git gc → allows (exit 0) [regression: no false positive]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git gc")"
  assert_success
}

@test "git gc --aggressive → allows (exit 0) [regression: no false positive]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git gc --aggressive")"
  assert_success
}

@test "git gc --prune (no value) → allows (exit 0) [regression: no false positive]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git gc --prune")"
  assert_success
}

@test "git gc --no-prune → allows (exit 0) [regression: no false positive]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git gc --no-prune")"
  assert_success
}

@test "git gc --auto → allows (exit 0) [regression: no false positive]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git gc --auto")"
  assert_success
}

@test "git gcfoo (look-alike token) → allows (exit 0) [regression: no false positive]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git gcfoo")"
  assert_success
}

@test "CAST_GC_OK=1 git gc --prune=now → allows (exit 0)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "CAST_GC_OK=1 git gc --prune=now")"
  assert_success
}

@test "CAST_GC_OK=1 with extra VAR=value before git gc --prune=now → allows (exit 0)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "CAST_GC_OK=1 CAST_SKIP_PLUGIN_DRIFT=1 git gc --prune=now")"
  assert_success
}

@test "CLAUDE_SUBPROCESS=1 + git gc --prune=now → still blocks (irreversibility guard always on)" {
  export CLAUDE_SUBPROCESS=1
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git gc --prune=now")"
  assert_failure
  assert_output --partial "gc"
}

# ---------------------------------------------------------------------------
# git prune block (2026-08-17 recovery-path pass)
# ---------------------------------------------------------------------------

@test "bare git prune without escape hatch → blocks (exit 2)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git prune")"
  assert_failure
  assert_output --partial "prune"
}

@test "git prune --expire=now without escape hatch → blocks (exit 2)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git prune --expire=now")"
  assert_failure
  assert_output --partial "prune"
}

@test "git prune -n (dry run) → allows (exit 0) [regression: no false positive]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git prune -n")"
  assert_success
}

@test "git prune --dry-run → allows (exit 0) [regression: no false positive]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git prune --dry-run")"
  assert_success
}

@test "git prune-packed (distinct non-destructive command) → allows (exit 0) [regression: no false positive]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git prune-packed")"
  assert_success
}

@test "git remote prune origin (different subcommand's argument) → allows (exit 0) [regression: no false positive]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git remote prune origin")"
  assert_success
}

@test "git worktree prune (different subcommand's argument) → allows (exit 0) [regression: no false positive]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git worktree prune")"
  assert_success
}

@test "git prunefoo (look-alike token) → allows (exit 0) [regression: no false positive]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git prunefoo")"
  assert_success
}

@test "CAST_PRUNE_OK=1 git prune → allows (exit 0)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "CAST_PRUNE_OK=1 git prune")"
  assert_success
}

@test "CAST_PRUNE_OK=1 with extra VAR=value before git prune → allows (exit 0)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "CAST_PRUNE_OK=1 CAST_SKIP_PLUGIN_DRIFT=1 git prune")"
  assert_success
}

@test "CLAUDE_SUBPROCESS=1 + git prune → still blocks (irreversibility guard always on)" {
  export CLAUDE_SUBPROCESS=1
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git prune")"
  assert_failure
  assert_output --partial "prune"
}

@test "git prune\$(true) (adjacent command substitution) → blocks (exit 2)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload 'git prune$(true)')"
  assert_failure
  assert_output --partial "prune"
}

@test "git -C /repo prune (global option tolerance) → blocks (exit 2)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git -C /repo prune")"
  assert_failure
  assert_output --partial "prune"
}

@test "CAST_PRUNE_OK=1 git -C /repo prune (global option tolerance) → allows (exit 0)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "CAST_PRUNE_OK=1 git -C /repo prune")"
  assert_success
}

# ---------------------------------------------------------------------------
# git gc/reflog config-route bypass block (2026-08-17 recovery-path pass,
# follow-up): -c inline config injection + `git config` writes of an expiry
# key, both under the existing CAST_GC_OK=1 hatch
# ---------------------------------------------------------------------------

@test "git -c gc.pruneExpire=now gc without escape hatch → blocks (exit 2)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git -c gc.pruneExpire=now gc")"
  assert_failure
  assert_output --partial "gc"
}

@test "git -c gc.reflogExpire=now gc without escape hatch → blocks (exit 2)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git -c gc.reflogExpire=now gc")"
  assert_failure
  assert_output --partial "gc"
}

@test "git -c gc.reflogExpireUnreachable=now gc without escape hatch → blocks (exit 2)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git -c gc.reflogExpireUnreachable=now gc")"
  assert_failure
  assert_output --partial "gc"
}

@test "git -c gc.reflogExpire=now -c gc.pruneExpire=now gc (combined, ONE command) without escape hatch → blocks (exit 2)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git -c gc.reflogExpire=now -c gc.pruneExpire=now gc")"
  assert_failure
  assert_output --partial "gc"
}

@test "git --git-dir=.git -c gc.pruneExpire=now gc (global option tolerance) → blocks (exit 2)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git --git-dir=.git -c gc.pruneExpire=now gc")"
  assert_failure
  assert_output --partial "gc"
}

@test "git -c gc.pruneexpire=now gc (lowercase key, git config keys are case-insensitive) → blocks (exit 2)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git -c gc.pruneexpire=now gc")"
  assert_failure
  assert_output --partial "gc"
}

@test "git -c core.pager=less log (unrelated key) → allows (exit 0) [regression: no false positive]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git -c core.pager=less log")"
  assert_success
}

@test "git -c gc.auto=0 gc (unrelated gc.* key) → allows (exit 0) [regression: no false positive]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git -c gc.auto=0 gc")"
  assert_success
}

@test "git -c user.name=x commit → blocks on commit, not on the -c (exit 2)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git -c user.name=x commit")"
  assert_failure
  assert_output --partial "commit"
}

@test "CAST_GC_OK=1 git -c gc.pruneExpire=now gc → allows (exit 0)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "CAST_GC_OK=1 git -c gc.pruneExpire=now gc")"
  assert_success
}

@test "CAST_GC_OK=1 with extra VAR=value before git -c gc.pruneExpire=now gc → allows (exit 0)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "CAST_GC_OK=1 CAST_SKIP_PLUGIN_DRIFT=1 git -c gc.pruneExpire=now gc")"
  assert_success
}

@test "CLAUDE_SUBPROCESS=1 + git -c gc.pruneExpire=now gc → still blocks (irreversibility guard always on)" {
  export CLAUDE_SUBPROCESS=1
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git -c gc.pruneExpire=now gc")"
  assert_failure
  assert_output --partial "gc"
}

@test "git config gc.pruneExpire now without escape hatch → blocks (exit 2)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git config gc.pruneExpire now")"
  assert_failure
  assert_output --partial "gc"
}

@test "git config --local gc.pruneExpire now (any form) → blocks (exit 2)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git config --local gc.pruneExpire now")"
  assert_failure
  assert_output --partial "gc"
}

@test "git config --replace-all gc.pruneExpire now (any form) → blocks (exit 2)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git config --replace-all gc.pruneExpire now")"
  assert_failure
  assert_output --partial "gc"
}

@test "git config gc.pruneexpire now (lowercase key) → blocks (exit 2)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git config gc.pruneexpire now")"
  assert_failure
  assert_output --partial "gc"
}

@test "git config gc.reflogExpire now → blocks (exit 2)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git config gc.reflogExpire now")"
  assert_failure
  assert_output --partial "gc"
}

@test "git config gc.reflogExpireUnreachable now → blocks (exit 2)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git config gc.reflogExpireUnreachable now")"
  assert_failure
  assert_output --partial "gc"
}

@test "git config user.email x (unrelated key) → allows (exit 0) [regression: no false positive]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git config user.email x")"
  assert_success
}

@test "git config --get gc.pruneExpire (a READ) → allows (exit 0) [subtle: read must not be mistaken for write]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git config --get gc.pruneExpire")"
  assert_success
}

@test "git config gc.pruneExpire (bare key, no value — a READ) → allows (exit 0) [regression: no false positive]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git config gc.pruneExpire")"
  assert_success
}

# `git config --get <key> <value-pattern>` is a READ — the value-pattern is a
# FILTER argument, not a set-value — but it has a token after the key, which
# would otherwise satisfy the write-detection lookahead on its own. This test
# is the only thing that discriminates the `(?!.*--get)` condition: with the
# value-token requirement alone (no --get exclusion), this form is still
# wrongly allowed to look like a write and blocks; only the --get exemption
# saves it.
@test "git config --get gc.pruneExpire now (READ with value-pattern filter) → allows (exit 0) [subtle: --get exemption is load-bearing, not redundant with the value-token check]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git config --get gc.pruneExpire now")"
  assert_success
}

@test "git config --get-regexp gc.*Expire now (READ, --get-family) → allows (exit 0) [regression: no false positive]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git config --get-regexp gc.*Expire now")"
  assert_success
}

@test "CAST_GC_OK=1 git config gc.pruneExpire now → allows (exit 0)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "CAST_GC_OK=1 git config gc.pruneExpire now")"
  assert_success
}

@test "CAST_GC_OK=1 with extra VAR=value before git config gc.pruneExpire now → allows (exit 0)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "CAST_GC_OK=1 CAST_SKIP_PLUGIN_DRIFT=1 git config gc.pruneExpire now")"
  assert_success
}

@test "CLAUDE_SUBPROCESS=1 + git config gc.pruneExpire now → still blocks (irreversibility guard always on)" {
  export CLAUDE_SUBPROCESS=1
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git config gc.pruneExpire now")"
  assert_failure
  assert_output --partial "gc"
}

@test "git config gc.pruneExpire now && git gc (config-write-then-bare-gc bypass) → blocks (exit 2) [the exact measured bypass this closes]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git config gc.pruneExpire now && git gc")"
  assert_failure
  assert_output --partial "gc"
}

@test "CAST_GC_OK=1 git -c gc.pruneExpire=now gc && git gc --prune=now → still BLOCKS (segment 2 carries no hatch)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "CAST_GC_OK=1 git -c gc.pruneExpire=now gc && git gc --prune=now")"
  assert_failure
  assert_output --partial "gc"
}

@test "CAST_GC_OK=1 git config gc.pruneExpire now && git gc --prune=now → still BLOCKS (segment 2 carries no hatch)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "CAST_GC_OK=1 git config gc.pruneExpire now && git gc --prune=now")"
  assert_failure
  assert_output --partial "gc"
}

# ---------------------------------------------------------------------------
# reflog/gc/prune: per-segment hatch scoping + cross-op independence
# (2026-08-17 fix — must not regress)
# ---------------------------------------------------------------------------

@test "CAST_GC_OK=1 git gc --prune=now && git prune → still BLOCKS (segment 2 carries no hatch)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "CAST_GC_OK=1 git gc --prune=now && git prune")"
  assert_failure
  assert_output --partial "prune"
}

@test "CAST_GC_OK=1 git gc --prune=now && CAST_PRUNE_OK=1 git prune → ALLOWED (each segment carries its own hatch)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "CAST_GC_OK=1 git gc --prune=now && CAST_PRUNE_OK=1 git prune")"
  assert_success
}

@test "CAST_PRUNE_OK=1 git prune; git reset --hard → still BLOCKS (cross-op independence)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "CAST_PRUNE_OK=1 git prune; git reset --hard")"
  assert_failure
  assert_output --partial "reset"
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

# ---------------------------------------------------------------------------
# shlex tokenization: quoted-subcommand evasion blocks [2026-08-17]
# Normalization via _normalize_git_segment() rewrites tokens that start with
# git; these cases test that quoted subcommands (attempting to evade the block)
# are still caught.
# ---------------------------------------------------------------------------

@test "git \"commit\" -m x (quoted subcommand) → blocks (exit 2) [shlex tokenization]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git \"commit\" -m x")"
  assert_failure
  assert_output --partial "commit"
}

@test "git \"push\" (quoted subcommand) → blocks (exit 2) [shlex tokenization]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git \"push\"")"
  assert_failure
  assert_output --partial "push"
}

@test "git \"stash\" (quoted subcommand) → blocks (exit 2) [shlex tokenization]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git \"stash\"")"
  assert_failure
  assert_output --partial "stash"
}

@test "git reset \"--hard\" (quoted flag) → blocks (exit 2) [shlex tokenization]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git reset \"--hard\"")"
  assert_failure
  assert_output --partial "reset"
}

@test "git \"reset\" --hard (quoted subcommand) → blocks (exit 2) [shlex tokenization]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git \"reset\" --hard")"
  assert_failure
  assert_output --partial "reset"
}

@test "git checkout \"--\" . (quoted path arg) → blocks (exit 2) [shlex tokenization]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git checkout \"--\" .")"
  assert_failure
  assert_output --partial "checkout"
}

@test "git switch \"--discard-changes\" main (quoted flag) → blocks (exit 2) [shlex tokenization]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git switch \"--discard-changes\" main")"
  assert_failure
  assert_output --partial "switch"
}

@test "git gc \"--prune=now\" (quoted flag) → blocks (exit 2) [shlex tokenization]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git gc \"--prune=now\"")"
  assert_failure
  assert_output --partial "gc"
}

@test "git reflog \"expire\" --all (quoted subcommand) → blocks (exit 2) [shlex tokenization]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git reflog \"expire\" --all")"
  assert_failure
  assert_output --partial "reflog"
}

@test "git \"prune\" (quoted subcommand) → blocks (exit 2) [shlex tokenization]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git \"prune\"")"
  assert_failure
  assert_output --partial "prune"
}

@test "git -c \"gc.pruneExpire=now\" gc (quoted -c value) → blocks (exit 2) [shlex tokenization]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git -c \"gc.pruneExpire=now\" gc")"
  assert_failure
  assert_output --partial "gc"
}

@test "git \"config\" gc.pruneExpire now (quoted subcommand) → blocks (exit 2) [shlex tokenization]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git \"config\" gc.pruneExpire now")"
  assert_failure
  assert_output --partial "config"
}

# ---------------------------------------------------------------------------
# shlex tokenization: absolute-path normalization
# Absolute paths to git binary are normalized to basename; the guard pattern
# still matches the bare git command.
# ---------------------------------------------------------------------------

@test "/usr/bin/git reset --hard (absolute path to git) → blocks (exit 2) [path normalization]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "/usr/bin/git reset --hard")"
  assert_failure
  assert_output --partial "reset"
}

@test "/opt/homebrew/bin/git push (absolute path to git, homebrew) → blocks (exit 2) [path normalization]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "/opt/homebrew/bin/git push")"
  assert_failure
  assert_output --partial "push"
}

# ---------------------------------------------------------------------------
# config-edit block: new gate (2026-08-17)
# git config edit/--edit/-e are blocked to prevent interactive editor abuse.
# ---------------------------------------------------------------------------

@test "git config edit → blocks (exit 2) [config-edit block]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git config edit")"
  assert_failure
  assert_output --partial "config"
}

@test "git config --edit → blocks (exit 2) [config-edit block]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git config --edit")"
  assert_failure
  assert_output --partial "config"
}

@test "git config -e → blocks (exit 2) [config-edit block]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git config -e")"
  assert_failure
  assert_output --partial "config"
}

# ---------------------------------------------------------------------------
# Regression fence: normalization must be narrow (git-basename-only)
# These cases verify that the shlex rewrite does NOT over-apply.
# ---------------------------------------------------------------------------

@test "rg \"git push\" docs/ (string search, not command) → allows (exit 0) [regression: must not rewrite non-commands]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "rg \"git push\" docs/")"
  assert_success
}

@test "grep -n \"git commit\" scripts/cast-git-guard.py (string search) → allows (exit 0) [regression: string literal must not trigger guard]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "grep -n \"git commit\" scripts/cast-git-guard.py")"
  assert_success
}

@test "gh pr create --body \"adds git push guard\" (gh tool with git string in arg) → blocks (exit 2) [PRE-EXISTING at HEAD, unchanged by tokenization: the raw pattern sees a literal space before 'git' INSIDE the quoted string; this is the known prose-mention behaviour — ship such text via 'git commit -F <file>' — NOT a regression introduced by this unit, and pinned here only to prove the git-head-only normalization did not widen it]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "gh pr create --body \"adds git push guard\"")"
  assert_failure
  assert_output --partial "push"
}

@test "./mygit reset --hard (basename ≠ git; must not match) → allows (exit 0) [regression: basename check is strict]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "./mygit reset --hard")"
  assert_success
}

@test "CAST_RESET_OK=1 git reset \"--hard\" (hatch + quoted flag) → allows (exit 0) [regression: hatch survives normalization]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "CAST_RESET_OK=1 git reset \"--hard\"")"
  assert_success
}

@test "CAST_PUSH_OK=1 git \"push\" (hatch + quoted subcommand) → allows (exit 0) [regression: hatch survives normalization]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "CAST_PUSH_OK=1 git \"push\"")"
  assert_success
}

@test "git restore \"--staged\" f.txt (quoted flag on safe restore) → allows (exit 0) [regression: non-blocked git subcommand unaffected]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git restore \"--staged\" f.txt")"
  assert_success
}

@test "git config --global user.email x (safe config write) → allows (exit 0) [regression: safe config operations allowed]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git config --global user.email x")"
  assert_success
}

@test "git config --get-regexp gc.*Expire (config read with regex) → allows (exit 0) [regression: config-edit block must not misfire on reads]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git config --get-regexp gc.*Expire")"
  assert_success
}

@test "CAST_GC_OK=1 git config --edit (config-edit hatch works) → allows (exit 0) [regression: the escape hatch is functional]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "CAST_GC_OK=1 git config --edit")"
  assert_success
}

# ---------------------------------------------------------------------------
# 2026-08-17 security-gate follow-up: config-edit subcommand-position
# anchoring (was: bare "edit" matched anywhere on the line) + hatch
# whitespace-value join fix in _normalize_git_segment.
# ---------------------------------------------------------------------------

@test "git config --global edit → blocks (exit 2) [defence-in-depth: MEASURED on git 2.55, this form does NOT open the editor — git parses 'edit' as a key and errors; blocked anyway in case a later git accepts the legacy flags-then-subcommand order]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git config --global edit")"
  assert_failure
  assert_output --partial "config"
}

@test "git config --local edit → blocks (exit 2) [defence-in-depth, same as --global edit: not a live editor route on git 2.55, blocked so a future git cannot reopen it silently]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git config --local edit")"
  assert_failure
  assert_output --partial "config"
}

@test "git config --global -e → blocks (exit 2) [this one IS a live route: MEASURED to open the editor on git 2.55, unlike the bare-edit-after-a-flag forms]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git config --global -e")"
  assert_failure
  assert_output --partial "config"
}

@test "git config user.email \"edit@example.com\" (value merely contains 'edit') → allows (exit 0) [gate-finding regression fence: config-edit block must not overmatch on a value]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git config user.email \"edit@example.com\"")"
  assert_success
}

@test "git config --get-regexp edit (config read, not the edit subcommand) → allows (exit 0) [gate-finding regression fence: config-edit block must not overmatch a --get-regexp read]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git config --get-regexp edit")"
  assert_success
}

@test "git config alias.e \"edit\" (alias VALUE, not the edit subcommand) → allows (exit 0) [gate-finding regression fence: config-edit block must not overmatch on a value]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git config alias.e \"edit\"")"
  assert_success
}

@test "CAST_RESET_OK=1 FOO=\"bar baz\" git reset --hard (hatch prefix with a whitespace-containing value) → allows (exit 0) [gate-finding regression fence: _normalize_git_segment must not break the hatch on a quoted multi-word value]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "CAST_RESET_OK=1 FOO=\"bar baz\" git reset --hard")"
  assert_success
}

@test "CAST_RESET_OK=\"1\" git reset --hard (quoted hatch value, a real bash assignment) → allows (exit 0) [gate-finding regression fence: quoted-value hatch must survive normalization]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "CAST_RESET_OK=\"1\" git reset --hard")"
  assert_success
}

@test "CAST_RESET_OK=\"10\" git reset --hard (wrong hatch value) → blocks (exit 2) [gate-finding regression fence: whitespace-value join fix must not loosen the hatch VALUE check]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "CAST_RESET_OK=\"10\" git reset --hard")"
  assert_failure
  assert_output --partial "reset"
}

# ---------------------------------------------------------------------------
# shlex tokenization: unbalanced-quote fallback
# When shlex.split() raises ValueError (unterminated quote), normalization
# returns None and the RAW pattern still blocks the command.
# ---------------------------------------------------------------------------

@test "git commit -m \"unterminated (unbalanced quote, shlex ValueError) → blocks (exit 2) [fallback to raw evaluation]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git commit -m \"unterminated")"
  assert_failure
  assert_output --partial "commit"
}

# ---------------------------------------------------------------------------
# git rm force block (2026-08-17 remaining-destructive-ops pass)
# hatch: CAST_GIT_RM_OK=1
# ---------------------------------------------------------------------------

@test "git rm -f f.txt → blocks (exit 2)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git rm -f f.txt")"
  assert_failure
  assert_output --partial "force-remove a modified file"
}

@test "git rm --force f.txt → blocks (exit 2)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git rm --force f.txt")"
  assert_failure
  assert_output --partial "force-remove a modified file"
}

@test "git rm -rf other → blocks (exit 2)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git rm -rf other")"
  assert_failure
  assert_output --partial "force-remove a modified file"
}

@test "git rm -fr other → blocks (exit 2)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git rm -fr other")"
  assert_failure
  assert_output --partial "force-remove a modified file"
}

@test "git rm -rfq other → blocks (exit 2)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git rm -rfq other")"
  assert_failure
  assert_output --partial "force-remove a modified file"
}

# --- security-finding regression fence (2026-08-17) -------------------------
# The `--cached` exemption previously used a bare `--cached\b` lookahead.
# `\b` fires on ANY word→non-word transition, so a pathspec that merely
# STARTS WITH `--cached` (e.g. a file named `--cached-evil.txt`) satisfied
# the lookahead and disabled the entire force-block for the whole command —
# a confirmed HIGH-severity bypass. These four cases reproduce the bypass
# and MUST block. (The corresponding ALLOW fences for the legitimate
# `--cached` flag — `git rm -f --cached f.txt`, `git rm -r --cached sub`,
# `git rm --cached f.txt` — already exist above; this section only adds the
# new BLOCK coverage the fix introduces.)
@test "git rm -f -- --cached-evil.txt (bare \\b bypass regression) → blocks (exit 2)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git rm -f -- --cached-evil.txt")"
  assert_failure
  assert_output --partial "force-remove a modified file"
}

@test "git rm -f --cached-evil.txt (bare \\b bypass regression) → blocks (exit 2)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git rm -f --cached-evil.txt")"
  assert_failure
  assert_output --partial "force-remove a modified file"
}

@test "git rm -rf -- --cached-evil.txt (bare \\b bypass regression) → blocks (exit 2)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git rm -rf -- --cached-evil.txt")"
  assert_failure
  assert_output --partial "force-remove a modified file"
}

@test "git rm -f --cached-suffix/file.txt (bare \\b bypass regression) → blocks (exit 2)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git rm -f --cached-suffix/file.txt")"
  assert_failure
  assert_output --partial "force-remove a modified file"
}

@test "git \"rm\" -f f.txt (quoted-token evasion) → blocks (exit 2)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git \"rm\" -f f.txt")"
  assert_failure
  assert_output --partial "force-remove a modified file"
}

@test "/usr/bin/git rm -f f.txt (absolute path) → blocks (exit 2)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "/usr/bin/git rm -f f.txt")"
  assert_failure
  assert_output --partial "force-remove a modified file"
}

@test "git -C /tmp/x rm -f f.txt (leading -C) → blocks (exit 2)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git -C /tmp/x rm -f f.txt")"
  assert_failure
  assert_output --partial "force-remove a modified file"
}

@test "git rm f.txt (no force flag; git itself refuses on local mods) → allows (exit 0)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git rm f.txt")"
  assert_success
}

@test "git rm --cached f.txt (index-only) → allows (exit 0)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git rm --cached f.txt")"
  assert_success
}

@test "git rm -r --cached sub (index-only, recursive) → allows (exit 0)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git rm -r --cached sub")"
  assert_success
}

@test "git rm -f --cached f.txt (force + cached is still index-only; worktree untouched) → allows (exit 0)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git rm -f --cached f.txt")"
  assert_success
}

@test "git rm -nf f.txt (dry-run wins even with force cluster) → allows (exit 0)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git rm -nf f.txt")"
  assert_success
}

@test "git rm -n f.txt (dry-run) → allows (exit 0)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git rm -n f.txt")"
  assert_success
}

@test "CAST_GIT_RM_OK=1 git rm -f f.txt → allows (exit 0) [hatch]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "CAST_GIT_RM_OK=1 git rm -f f.txt")"
  assert_success
}

@test "CAST_GIT_RM_OK=1 git rm -f f.txt && git rm -f g.txt → blocks (exit 2) [hatch does not carry across segments]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "CAST_GIT_RM_OK=1 git rm -f f.txt && git rm -f g.txt")"
  assert_failure
  assert_output --partial "force-remove a modified file"
}

# ---------------------------------------------------------------------------
# git branch force-delete block (2026-08-17 remaining-destructive-ops pass)
# hatch: CAST_BRANCH_OK=1
# ---------------------------------------------------------------------------

@test "git branch -D feature → blocks (exit 2)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git branch -D feature")"
  assert_failure
  assert_output --partial "force-deletes an unmerged branch ref"
}

@test "git branch --delete --force feature → blocks (exit 2)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git branch --delete --force feature")"
  assert_failure
  assert_output --partial "force-deletes an unmerged branch ref"
}

@test "git branch -qD feature (clustered) → blocks (exit 2)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git branch -qD feature")"
  assert_failure
  assert_output --partial "force-deletes an unmerged branch ref"
}

@test "git branch -d x --force (measured destructive) → blocks (exit 2)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git branch -d x --force")"
  assert_failure
  assert_output --partial "force-deletes an unmerged branch ref"
}

@test "git branch --force --delete x (reversed order) → blocks (exit 2)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git branch --force --delete x")"
  assert_failure
  assert_output --partial "force-deletes an unmerged branch ref"
}

@test "git \"branch\" -D feature (quoted-token evasion) → blocks (exit 2)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git \"branch\" -D feature")"
  assert_failure
  assert_output --partial "force-deletes an unmerged branch ref"
}

@test "git branch -d feature (git refuses unmerged) → allows (exit 0)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git branch -d feature")"
  assert_success
}

@test "git branch --delete feature (no force) → allows (exit 0)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git branch --delete feature")"
  assert_success
}

@test "git branch (bare, read-only) → allows (exit 0)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git branch")"
  assert_success
}

@test "git branch -a → allows (exit 0)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git branch -a")"
  assert_success
}

@test "git branch -v → allows (exit 0)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git branch -v")"
  assert_success
}

@test "git branch -vv → allows (exit 0)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git branch -vv")"
  assert_success
}

@test "git branch -r → allows (exit 0)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git branch -r")"
  assert_success
}

@test "git branch --list → allows (exit 0)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git branch --list")"
  assert_success
}

@test "git branch -m renamed (rename) → allows (exit 0)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git branch -m renamed")"
  assert_success
}

@test "git branch --show-current → allows (exit 0)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git branch --show-current")"
  assert_success
}

@test "git branch --merged main → allows (exit 0)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git branch --merged main")"
  assert_success
}

@test "git branch --set-upstream-to=origin/main → allows (exit 0)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git branch --set-upstream-to=origin/main")"
  assert_success
}

@test "CAST_BRANCH_OK=1 git branch -D feature → allows (exit 0) [hatch]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "CAST_BRANCH_OK=1 git branch -D feature")"
  assert_success
}

@test "CAST_BRANCH_OK=1 git branch -D feature && git branch -D other → blocks (exit 2) [hatch does not carry across segments]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "CAST_BRANCH_OK=1 git branch -D feature && git branch -D other")"
  assert_failure
  assert_output --partial "force-deletes an unmerged branch ref"
}

# ---------------------------------------------------------------------------
# git worktree remove force block (2026-08-17 remaining-destructive-ops pass)
# hatch: CAST_WORKTREE_OK=1
# ---------------------------------------------------------------------------

@test "git worktree remove -f /tmp/wt → blocks (exit 2)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git worktree remove -f /tmp/wt")"
  assert_failure
  assert_output --partial "deletes a worktree even when"
}

@test "git worktree remove --force /tmp/wt → blocks (exit 2)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git worktree remove --force /tmp/wt")"
  assert_failure
  assert_output --partial "deletes a worktree even when"
}

@test "git worktree remove -fq /tmp/wt (clustered force flag) → blocks (exit 2)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git worktree remove -fq /tmp/wt")"
  assert_failure
  assert_output --partial "deletes a worktree even when"
}

@test "git worktree remove /tmp/wt (git refuses on dirty AND untracked-only) → allows (exit 0)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git worktree remove /tmp/wt")"
  assert_success
}

@test "git worktree add -f /tmp/wt (force on add is not destructive) → allows (exit 0)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git worktree add -f /tmp/wt")"
  assert_success
}

@test "git worktree list → allows (exit 0)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git worktree list")"
  assert_success
}

@test "git worktree prune → allows (exit 0)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git worktree prune")"
  assert_success
}

@test "git worktree add /tmp/wt -b b → allows (exit 0)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git worktree add /tmp/wt -b b")"
  assert_success
}

@test "CAST_WORKTREE_OK=1 git worktree remove -f /tmp/wt → allows (exit 0) [hatch]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "CAST_WORKTREE_OK=1 git worktree remove -f /tmp/wt")"
  assert_success
}

@test "CAST_WORKTREE_OK=1 git worktree remove -f /tmp/wt && git worktree remove -f /tmp/wt2 → blocks (exit 2) [hatch does not carry across segments]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "CAST_WORKTREE_OK=1 git worktree remove -f /tmp/wt && git worktree remove -f /tmp/wt2")"
  assert_failure
  assert_output --partial "deletes a worktree even when"
}

# ---------------------------------------------------------------------------
# git update-ref delete block (2026-08-17 remaining-destructive-ops pass)
# hatch: CAST_UPDATE_REF_OK=1
# NOTE: `git update-ref --delete` is NOT a valid git flag (measured rc=129
# usage error on git 2.55.0) — only `-d` deletes. Its absence from the block
# pattern is deliberate, not an oversight; there is nothing to add.
# ---------------------------------------------------------------------------

@test "git update-ref -d refs/heads/feature → blocks (exit 2)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git update-ref -d refs/heads/feature")"
  assert_failure
  assert_output --partial "deletes a ref and its reflog"
}

@test "git update-ref --stdin (payload invisible to scanner, denied by default) → blocks (exit 2)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git update-ref --stdin")"
  assert_failure
  assert_output --partial "deletes a ref and its reflog"
}

@test "/usr/bin/git update-ref -d refs/heads/feature (absolute path) → blocks (exit 2)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "/usr/bin/git update-ref -d refs/heads/feature")"
  assert_failure
  assert_output --partial "deletes a ref and its reflog"
}

@test "git update-ref refs/heads/tmp HEAD (create/update via args) → allows (exit 0)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git update-ref refs/heads/tmp HEAD")"
  assert_success
}

@test "git update-ref -m msg refs/heads/tmp HEAD → allows (exit 0)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git update-ref -m msg refs/heads/tmp HEAD")"
  assert_success
}

@test "git update-ref refs/heads/tmp2 HEAD~1 (update via args, no -d/--stdin) → allows (exit 0)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git update-ref refs/heads/tmp2 HEAD~1")"
  assert_success
}

@test "CAST_UPDATE_REF_OK=1 git update-ref -d refs/heads/feature → allows (exit 0) [hatch]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "CAST_UPDATE_REF_OK=1 git update-ref -d refs/heads/feature")"
  assert_success
}

@test "CAST_UPDATE_REF_OK=1 git update-ref -d refs/heads/feature && git update-ref -d refs/heads/other → blocks (exit 2) [hatch does not carry across segments]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "CAST_UPDATE_REF_OK=1 git update-ref -d refs/heads/feature && git update-ref -d refs/heads/other")"
  assert_failure
  assert_output --partial "deletes a ref and its reflog"
}

# ---------------------------------------------------------------------------
# git filter-branch block (2026-08-17 remaining-destructive-ops pass)
# hatch: CAST_FILTER_BRANCH_OK=1
# filter-branch has no non-destructive read-only mode, so every real
# invocation blocks; the ALLOW-side regressions below exercise the
# (?![\w-]) token-boundary guard instead (must not overmatch a longer
# hyphenated/suffixed token or a non-git command containing the substring).
# ---------------------------------------------------------------------------

@test "git filter-branch -f --msg-filter cat HEAD → blocks (exit 2)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git filter-branch -f --msg-filter cat HEAD")"
  assert_failure
  assert_output --partial "rewrites history"
}

@test "git filter-branch (bare) → blocks (exit 2)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git filter-branch")"
  assert_failure
  assert_output --partial "rewrites history"
}

@test "git filter-branch --tag-name-filter cat -- --all → blocks (exit 2)" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git filter-branch --tag-name-filter cat -- --all")"
  assert_failure
  assert_output --partial "rewrites history"
}

@test "git filter-branches (longer token; must not overmatch via bare \\\\b) → allows (exit 0) [token-boundary regression]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git filter-branches")"
  assert_success
}

@test "echo test filter-branch (non-git command containing the substring) → allows (exit 0) [regression: must not overmatch outside a git invocation]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "echo test filter-branch")"
  assert_success
}

@test "CAST_FILTER_BRANCH_OK=1 git filter-branch -f --msg-filter cat HEAD → allows (exit 0) [hatch]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "CAST_FILTER_BRANCH_OK=1 git filter-branch -f --msg-filter cat HEAD")"
  assert_success
}

@test "CAST_FILTER_BRANCH_OK=1 git filter-branch -f --msg-filter cat HEAD && git filter-branch -f --msg-filter cat HEAD → blocks (exit 2) [hatch does not carry across segments]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "CAST_FILTER_BRANCH_OK=1 git filter-branch -f --msg-filter cat HEAD && git filter-branch -f --msg-filter cat HEAD")"
  assert_failure
  assert_output --partial "rewrites history"
}

# ---------------------------------------------------------------------------
# Out-of-scope regression fence (2026-08-17): both measured non-destructive
# on git 2.55.0 — sparse-checkout refuses to remove modified files and
# ignores untracked-only content; `rm -r --cached` is index-only. Neither
# is covered by any of the five new blocks above; these assert they STAY
# allowed (a false positive here is a shipping blocker per Ed's decision).
# ---------------------------------------------------------------------------

@test "git sparse-checkout set keep → allows (exit 0) [out-of-scope regression fence]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git sparse-checkout set keep")"
  assert_success
}

@test "git sparse-checkout init --cone → allows (exit 0) [out-of-scope regression fence]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git sparse-checkout init --cone")"
  assert_success
}

@test "git sparse-checkout disable → allows (exit 0) [out-of-scope regression fence]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git sparse-checkout disable")"
  assert_success
}

@test "git sparse-checkout list → allows (exit 0) [out-of-scope regression fence]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git sparse-checkout list")"
  assert_success
}

@test "git rm -r --cached sub (index-only recursive removal, duplicate regression fence) → allows (exit 0) [out-of-scope regression fence]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git rm -r --cached sub")"
  assert_success
}

# ---------------------------------------------------------------------------
# git global-option bypass fix (2026-08-18, security review)
# `_GIT_OPTS` was a 5-form enumerated allowlist; ANY other legal git global
# option (or one of those 5 forms spelled differently) broke the `git`-to-
# subcommand anchor in every BLOCK/ALLOW pattern, allowing all 16 guarded
# ops. Fixed by dropping global-option tokens in `_normalize_git_segment`
# instead of extending the regex allowlist. Every case below was measured
# ALLOWED (bypassed) at HEAD `ba039b5` before this fix.
# ---------------------------------------------------------------------------

@test "git -C '/tmp/my dir' reset --hard (quoted -C value, space form) → blocks (exit 2) [global-option bypass regression]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git -C '/tmp/my dir' reset --hard")"
  assert_failure 2
}

@test "git -C '/tmp/my dir' push (quoted -C value, space form) → blocks (exit 2) [global-option bypass regression]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git -C '/tmp/my dir' push")"
  assert_failure 2
}

@test "git -C '/tmp/my dir' clean -fdx (quoted -C value, space form) → blocks (exit 2) [global-option bypass regression]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git -C '/tmp/my dir' clean -fdx")"
  assert_failure 2
}

@test "git -C '/tmp/my dir' commit -m x (quoted -C value, space form) → blocks (exit 2) [global-option bypass regression]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git -C '/tmp/my dir' commit -m x")"
  assert_failure 2
}

@test "git --git-dir='/tmp/my dir/.git' reset --hard (quoted --git-dir value) → blocks (exit 2) [global-option bypass regression]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git --git-dir='/tmp/my dir/.git' reset --hard")"
  assert_failure 2
}

@test "git --work-tree='/tmp/my dir' clean -fdx (quoted --work-tree value) → blocks (exit 2) [global-option bypass regression]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git --work-tree='/tmp/my dir' clean -fdx")"
  assert_failure 2
}

@test "git -c 'user.name=A B' reset --hard (quoted -c value with a space) → blocks (exit 2) [global-option bypass regression]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git -c 'user.name=A B' reset --hard")"
  assert_failure 2
}

@test "git -C/tmp/x reset --hard (attached -C, no separator; MEASURED: real git rejects this form, dropped as an opaque flag anyway) → blocks (exit 2) [global-option bypass regression]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git -C/tmp/x reset --hard")"
  assert_failure 2
}

@test "git --git-dir /tmp/x/.git reset --hard (space form; only the = form was allowlisted) → blocks (exit 2) [global-option bypass regression]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git --git-dir /tmp/x/.git reset --hard")"
  assert_failure 2
}

@test "git --work-tree /tmp/x reset --hard (space form; only the = form was allowlisted) → blocks (exit 2) [global-option bypass regression]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git --work-tree /tmp/x reset --hard")"
  assert_failure 2
}

@test "git -p reset --hard (unenumerated global flag; two-character bypass of the entire module) → blocks (exit 2) [global-option bypass regression]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git -p reset --hard")"
  assert_failure 2
}

@test "git --paginate reset --hard → blocks (exit 2) [global-option bypass regression]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git --paginate reset --hard")"
  assert_failure 2
}

@test "git --bare reset --hard → blocks (exit 2) [global-option bypass regression]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git --bare reset --hard")"
  assert_failure 2
}

@test "git --literal-pathspecs reset --hard → blocks (exit 2) [global-option bypass regression]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git --literal-pathspecs reset --hard")"
  assert_failure 2
}

@test "git --no-replace-objects reset --hard → blocks (exit 2) [global-option bypass regression]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git --no-replace-objects reset --hard")"
  assert_failure 2
}

@test "git --no-optional-locks reset --hard → blocks (exit 2) [global-option bypass regression]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git --no-optional-locks reset --hard")"
  assert_failure 2
}

@test "git --exec-path=/usr/lib/git-core reset --hard (attached =, MEASURED: bare form has no value-consumption at all on git 2.55) → blocks (exit 2) [global-option bypass regression]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git --exec-path=/usr/lib/git-core reset --hard")"
  assert_failure 2
}

@test "git --namespace=foo reset --hard → blocks (exit 2) [global-option bypass regression]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git --namespace=foo reset --hard")"
  assert_failure 2
}

@test "git --attr-source=HEAD reset --hard → blocks (exit 2) [global-option bypass regression]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git --attr-source=HEAD reset --hard")"
  assert_failure 2
}

@test "CAST_RESET_OK=1 git -p reset --hard (hatch survives a global option) → allows (exit 0) [global-option bypass regression]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "CAST_RESET_OK=1 git -p reset --hard")"
  assert_success
}

@test "CAST_PUSH_OK=1 git -C '/tmp/my dir' push (hatch survives a quoted-value global option) → allows (exit 0) [global-option bypass regression]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "CAST_PUSH_OK=1 git -C '/tmp/my dir' push")"
  assert_success
}

@test "git -p -c gc.pruneExpire=now gc (config-injection block must still fire off the RAW segment when -c is preceded by another global option) → blocks (exit 2) [global-option bypass regression]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git -p -c gc.pruneExpire=now gc")"
  assert_failure 2
}

# --- non-regression: legitimate global-option use on non-blocked ops stays allowed ---

@test "git -c foo=bar log (non-blocked subcommand, attached -c form) → allows (exit 0) [global-option bypass, non-regression]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git -c foo=bar log")"
  assert_success
}

@test "git -C /tmp/x status (non-blocked subcommand, -C space form) → allows (exit 0) [global-option bypass, non-regression]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git -C /tmp/x status")"
  assert_success
}

@test "git --no-pager diff (non-blocked subcommand) → allows (exit 0) [global-option bypass, non-regression]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git --no-pager diff")"
  assert_success
}

@test "git worktree add -f /tmp/x (no leading global option at all) → allows (exit 0) [global-option bypass, non-regression]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git worktree add -f /tmp/x")"
  assert_success
}

@test "rg \"git reset --hard\" docs/ (string search, not a command) → allows (exit 0) [global-option bypass, non-regression]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "rg \"git reset --hard\" docs/")"
  assert_success
}

@test "git -c \"gc.pruneExpire=now\" gc (quoted -c value, NO whitespace inside; config-injection block must survive quote-stripping) → blocks (exit 2) [global-option bypass regression: -c preservation]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git -c \"gc.pruneExpire=now\" gc")"
  assert_failure 2
}

# ---------------------------------------------------------------------------
# git branch -M / -f force-overwrite (2026-08-18, remaining-destructive-ops
# follow-up). `-M` clobbers an existing destination branch (dangling-blob-
# recoverable, same class as `reset --hard`); `-f`/`--force` force-moves an
# existing branch pointer (reflog-recoverable via `<branch>@{1}`, same
# class as `-D`). Both were still ALLOWED at HEAD before this fix.
# ---------------------------------------------------------------------------

@test "git branch -M old new (force-rename onto an existing destination) → blocks (exit 2) [remaining-destructive-ops: branch -M]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git branch -M old new")"
  assert_failure 2
  assert_output --partial "branch"
}

@test "git branch -f main HEAD~3 (force-move an existing branch pointer) → blocks (exit 2) [remaining-destructive-ops: branch -f]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git branch -f main HEAD~3")"
  assert_failure 2
  assert_output --partial "branch"
}

@test "git branch --force main HEAD~3 (long-flag force-move) → blocks (exit 2) [remaining-destructive-ops: branch -f]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git branch --force main HEAD~3")"
  assert_failure 2
}

@test "git branch -c -f copyname (force-copy onto an existing branch) → blocks (exit 2) [remaining-destructive-ops: branch -f, same clobber class as -M]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git branch -c -f copyname")"
  assert_failure 2
}

@test "CAST_BRANCH_OK=1 git branch -M old new (hatch) → allows (exit 0) [remaining-destructive-ops: branch -M]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "CAST_BRANCH_OK=1 git branch -M old new")"
  assert_success
}

@test "CAST_BRANCH_OK=1 git branch -f main HEAD~3 (hatch) → allows (exit 0) [remaining-destructive-ops: branch -f]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "CAST_BRANCH_OK=1 git branch -f main HEAD~3")"
  assert_success
}

@test "git branch -m renamed (safe lowercase rename, no force, still allowed) → allows (exit 0) [remaining-destructive-ops: branch -M regression fence]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git branch -m renamed")"
  assert_success
}

@test "git branch -d feature (safe delete, no force, still allowed) → allows (exit 0) [remaining-destructive-ops: branch -f regression fence]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git branch -d feature")"
  assert_success
}

@test "git branch --set-upstream-to=origin/main (long option containing no -f/-M, still allowed) → allows (exit 0) [remaining-destructive-ops: branch regression fence]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git branch --set-upstream-to=origin/main")"
  assert_success
}

@test "git branch -D feature (pre-existing -D coverage, unaffected by the -M/-f simplification) → blocks (exit 2) [remaining-destructive-ops: branch regression fence]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git branch -D feature")"
  assert_failure 2
}

# ---------------------------------------------------------------------------
# git update-ref overwrite-existing-ref (2026-08-18, remaining-destructive-
# ops follow-up). `git update-ref <ref> <value>`, when <ref> already
# exists, moves it (reflog-recoverable, same class as `branch -f`) — was
# still ALLOWED at HEAD. Creating a NEW ref stays allowed (unaffected;
# re-measured, still genuinely harmless). Uses THIS repo's real refs
# (main, feature/v10-continuity) since the check shells out to
# `git rev-parse --verify --quiet`, scoped read-only, never executed.
# ---------------------------------------------------------------------------

@test "git update-ref refs/heads/main HEAD~3 (existing ref) → blocks (exit 2) [remaining-destructive-ops: update-ref overwrite]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git update-ref refs/heads/main HEAD~3")"
  assert_failure 2
  assert_output --partial "update-ref"
}

@test "git update-ref refs/heads/definitely-not-a-real-branch-probe-xyz HEAD (nonexistent ref, create) → allows (exit 0) [remaining-destructive-ops: update-ref create regression fence]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git update-ref refs/heads/definitely-not-a-real-branch-probe-xyz HEAD")"
  assert_success
}

@test "CAST_UPDATE_REF_OK=1 git update-ref refs/heads/main HEAD~3 (hatch) → allows (exit 0) [remaining-destructive-ops: update-ref overwrite]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "CAST_UPDATE_REF_OK=1 git update-ref refs/heads/main HEAD~3")"
  assert_success
}

@test "git update-ref -d refs/heads/feature (pre-existing -d coverage, unaffected) → blocks (exit 2) [remaining-destructive-ops: update-ref regression fence]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git update-ref -d refs/heads/feature")"
  assert_failure 2
}

@test "git update-ref --stdin (pre-existing --stdin coverage, unaffected) → blocks (exit 2) [remaining-destructive-ops: update-ref regression fence]" {
  run bash "$HOOK_SH" <<< "$(make_bash_payload "git update-ref --stdin")"
  assert_failure 2
}

# ---------------------------------------------------------------------------
# Status-file completion-gate __ prefix fix (2026-08-18). Roster dispatches
# named `<agent-type>__<label>` (dispatch-naming convention) write
# `<agent-type>__<label>-<ts>.json`, which a bare `<agent>-` prefix match
# never sees, so a policy gate falsely reports the required agent as never
# having completed. Exercised end-to-end through pre-tool-guard.sh's real
# Write-tool path against this repo's actual config/policies.json
# (`src/auth/.*` requires `security`, severity block).
# ---------------------------------------------------------------------------

@test "Write to src/auth/*.php with NO completion record → blocks (exit 2) [policy-gate __ prefix fix: control]" {
  run bash "$HOOK_SH" <<< "$(make_write_payload "src/auth/probe1.php")"
  assert_failure
  assert_output --partial "auth-requires-security"
}

@test "Write to src/auth/*.php with a plain security-<ts>.json record → allows (exit 0) [policy-gate __ prefix fix: pre-existing dash form regression fence]" {
  create_status_file "security-1000.json" 0 '{"status":"DONE"}'
  run bash "$HOOK_SH" <<< "$(make_write_payload "src/auth/probe2.php")"
  assert_success
}

@test "Write to src/auth/*.php with a security__fix-x-<ts>.json record (dunder dispatch naming) → allows (exit 0) [policy-gate __ prefix fix]" {
  create_status_file "security__fix-x-1000.json" 0 '{"status":"DONE"}'
  run bash "$HOOK_SH" <<< "$(make_write_payload "src/auth/probe3.php")"
  assert_success
}

@test "Write to src/auth/*.php with a security2-<ts>.json record (must NOT satisfy 'security': anchoring regression) → blocks (exit 2) [policy-gate __ prefix fix: anchoring must hold]" {
  create_status_file "security2-1000.json" 0 '{"status":"DONE"}'
  run bash "$HOOK_SH" <<< "$(make_write_payload "src/auth/probe4.php")"
  assert_failure
  assert_output --partial "auth-requires-security"
}

@test "Write to src/auth/*.php with a securityX__fix-y-<ts>.json record (must NOT satisfy 'security': dunder anchoring regression) → blocks (exit 2) [policy-gate __ prefix fix: anchoring must hold]" {
  create_status_file "securityX__fix-y-1000.json" 0 '{"status":"DONE"}'
  run bash "$HOOK_SH" <<< "$(make_write_payload "src/auth/probe5.php")"
  assert_failure
  assert_output --partial "auth-requires-security"
}

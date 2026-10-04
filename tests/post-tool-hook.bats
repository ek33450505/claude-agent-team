#!/usr/bin/env bats

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
HOOK_SH="$REPO_DIR/scripts/post-tool-hook.sh"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Build a Write tool payload
write_payload() {
  local file_path="$1"
  local content="${2:-export const x = 1}"
  python3 -c "import json,sys; print(json.dumps({'tool_name':'Write','tool_input':{'file_path':sys.argv[1],'content':sys.argv[2]},'tool_response':{}}))" "$file_path" "$content"
}

# Build an Agent tool payload
agent_payload() {
  local subagent_type="${1:-code-writer}"
  python3 -c "import json,sys; print(json.dumps({'tool_name':'Agent','tool_input':{'subagent_type':sys.argv[1],'prompt':'test prompt for agent dispatch'},'tool_response':{}}))" "$subagent_type"
}

# Build a Bash tool payload with optional exit code
bash_payload() {
  local command="$1"
  local exit_code="${2:-0}"
  python3 -c "import json,sys; print(json.dumps({'tool_name':'Bash','tool_input':{'command':sys.argv[1]},'tool_response':{'exit_code':int(sys.argv[2]),'stdout':'','stderr':'command failed'}}))" "$command" "$exit_code"
}

# Read the action field from the last routing-log entry
last_log_action() {
  tail -1 "$HOME/.claude/routing-log.jsonl" 2>/dev/null \
    | python3 -c "import json,sys; print(json.load(sys.stdin).get('action',''))" 2>/dev/null || echo ""
}

# Count lines in the routing log
log_line_count() {
  wc -l < "$HOME/.claude/routing-log.jsonl" 2>/dev/null || echo "0"
}

setup() {
  load 'helpers/setup'
  setup_temp_home
  # Resolve symlinks: hook canonicalizes paths; on macOS /var/folders -> /private/var/folders
  HOME="$(realpath "$HOME")"; export HOME
  mkdir -p "$HOME/.claude/config"
  mkdir -p "$HOME/.claude/scripts"
  # Create cast-log-append.py stub that just appends the JSON to routing-log.jsonl
  cat > "$HOME/.claude/scripts/cast-log-append.py" <<'PYEOF'
import sys, json
data = json.load(sys.stdin)
import os
log_path = os.path.expanduser("~/.claude/routing-log.jsonl")
os.makedirs(os.path.dirname(log_path), exist_ok=True)
with open(log_path, "a") as f:
    f.write(json.dumps(data) + "\n")
PYEOF
  touch "$HOME/.claude/routing-log.jsonl"
  unset CLAUDE_SUBPROCESS
  unset CLAUDE_SESSION_ID
}

teardown() {
  teardown_temp_home
}

# ---------------------------------------------------------------------------
# 1. Non-matching tool_name → no output
# ---------------------------------------------------------------------------

@test "non-Write tool_name (Read) → exits 0 with no hookSpecificOutput" {
  run bash "$HOOK_SH" <<< '{"tool_name":"Read","tool_input":{"file_path":"/tmp/foo.ts"},"tool_response":{}}'
  assert_success
  refute_output --partial "hookSpecificOutput"
}

# ---------------------------------------------------------------------------
# 2. Write .ts file + main session → [CAST-CHAIN]
# ---------------------------------------------------------------------------

@test "Write .ts + main session → output contains [CAST-CHAIN]" {
  run bash "$HOOK_SH" <<< "$(write_payload "$HOME/test.ts")"
  assert_success
  assert_output --partial "CAST-CHAIN"
}

# ---------------------------------------------------------------------------
# 3. Write .md file + main session → CAST-REVIEW SUPPRESSED (plan/doc edits, not code)
# ---------------------------------------------------------------------------

@test "Write .md + main session → CAST-REVIEW SUPPRESSED (plan/doc edits, not code)" {
  run bash "$HOOK_SH" <<< "$(write_payload "$HOME/notes.md" "# just a note")"
  assert_success
  refute_output --partial "CAST-REVIEW"
}

# ---------------------------------------------------------------------------
# 4. Write .ts file + CLAUDE_SUBPROCESS=1 → subagent path (not CAST-CHAIN)
# ---------------------------------------------------------------------------

@test "Write .ts + CLAUDE_SUBPROCESS=1 → does NOT output [CAST-CHAIN]" {
  run env CLAUDE_SUBPROCESS=1 bash "$HOOK_SH" <<< "$(write_payload "$HOME/test.ts")"
  assert_success
  refute_output --partial "CAST-CHAIN"
}

@test "Write .ts + CLAUDE_SUBPROCESS=1 → outputs subagent reinforcement (CAST-REVIEW)" {
  run env CLAUDE_SUBPROCESS=1 bash "$HOOK_SH" <<< "$(write_payload "$HOME/test.ts")"
  assert_success
  assert_output --partial "CAST-REVIEW"
}

# ---------------------------------------------------------------------------
# 5. Write non-code file + CLAUDE_SUBPROCESS=1 → no hookSpecificOutput
# ---------------------------------------------------------------------------

@test "Write .txt + CLAUDE_SUBPROCESS=1 → no hookSpecificOutput" {
  run env CLAUDE_SUBPROCESS=1 bash "$HOOK_SH" <<< "$(write_payload "$HOME/readme.txt" "plain text")"
  assert_success
  refute_output --partial "hookSpecificOutput"
}

# ---------------------------------------------------------------------------
# 6. File path outside $HOME → prettier skipped (no error)
# ---------------------------------------------------------------------------

@test "Write file outside HOME → exits 0 (prettier security guard, no crash)" {
  run bash "$HOOK_SH" <<< '{"tool_name":"Write","tool_input":{"file_path":"/etc/hosts","content":"# test"},"tool_response":{}}'
  assert_success
}

# ---------------------------------------------------------------------------
# 7. Write .md in /plans/ with 'json dispatch' block → ADM directive injected
# ---------------------------------------------------------------------------

@test "Write .md plan file with 'json dispatch' block → [CAST-ORCHESTRATE] injected" {
  mkdir -p "$HOME/.claude/plans"
  local plan_file="$HOME/.claude/plans/2026-03-25-test-plan.md"
  cat > "$plan_file" <<'PLAN'
# Test Plan

## Agent Dispatch Manifest

```json dispatch
{"batches":[]}
```
PLAN
  run bash "$HOOK_SH" <<< "$(write_payload "$plan_file" "$(cat "$plan_file")")"
  assert_success
  assert_output --partial "CAST-ORCHESTRATE"
}

# ---------------------------------------------------------------------------
# 8. Write .md in /plans/ without 'json dispatch' → no ADM directive
# ---------------------------------------------------------------------------

@test "Write .md plan file without 'json dispatch' → no [CAST-ORCHESTRATE]" {
  mkdir -p "$HOME/.claude/plans"
  local plan_file="$HOME/.claude/plans/2026-03-25-no-manifest.md"
  cat > "$plan_file" <<'PLAN'
# Test Plan

No dispatch manifest here.
PLAN
  run bash "$HOOK_SH" <<< "$(write_payload "$plan_file" "$(cat "$plan_file")")"
  assert_success
  refute_output --partial "CAST-ORCHESTRATE"
}

# ---------------------------------------------------------------------------
# 9. Agent tool call + main session → routing-log.jsonl written
# ---------------------------------------------------------------------------

@test "Agent tool call + main session → routing-log.jsonl gets new entry with action=agent_dispatched" {
  local before
  before="$(log_line_count)"
  run bash "$HOOK_SH" <<< "$(agent_payload "code-writer")"
  assert_success
  local after
  after="$(log_line_count)"
  assert [ "$after" -gt "$before" ]
  assert_equal "$(last_log_action)" "agent_dispatched"
}

# ---------------------------------------------------------------------------
# 10. Agent tool call + CLAUDE_SUBPROCESS=1 → routing-log IS written (no guard on Agent logging)
# ---------------------------------------------------------------------------

@test "Agent tool call + CLAUDE_SUBPROCESS=1 → routing-log still written (Agent logging has no subagent guard)" {
  local before
  before="$(log_line_count)"
  run env CLAUDE_SUBPROCESS=1 bash "$HOOK_SH" <<< "$(agent_payload "code-writer")"
  assert_success
  local after
  after="$(log_line_count)"
  assert [ "$after" -gt "$before" ]
}

# ---------------------------------------------------------------------------
# 11–14. Bash CAST-DEBUG section
#
# cast-post-tool.py (consolidated handler) receives $INPUT via herestring
# (<<< "$INPUT") rather than the old pipe+heredoc pattern that caused stdin
# to be empty inside the Python process. CAST-DEBUG is now correctly emitted
# for non-zero Bash exits in main sessions, except for grace-listed commands.
# ---------------------------------------------------------------------------

@test "Bash tool exit_code=1 + main session → exits 0 and emits [CAST-DEBUG]" {
  run bash "$HOOK_SH" <<< "$(bash_payload "npm run build" 1)"
  assert_success
  # Non-grace-listed command with exit_code=1 should route to debugger
  assert_output --partial "CAST-DEBUG"
}

@test "Bash tool exit_code=1 + CLAUDE_SUBPROCESS=1 → exits 0 with no [CAST-DEBUG]" {
  run env CLAUDE_SUBPROCESS=1 bash "$HOOK_SH" <<< "$(bash_payload "npm run build" 1)"
  assert_success
  refute_output --partial "CAST-DEBUG"
}

@test "Bash 'grep foo bar' exit_code=1 → exits 0 with no [CAST-DEBUG]" {
  run bash "$HOOK_SH" <<< "$(bash_payload "grep foo bar" 1)"
  assert_success
  refute_output --partial "CAST-DEBUG"
}

@test "Bash tool exit_code=0 → exits 0 with no [CAST-DEBUG]" {
  run bash "$HOOK_SH" <<< "$(bash_payload "npm run build" 0)"
  assert_success
  refute_output --partial "CAST-DEBUG"
}

# ---------------------------------------------------------------------------
# 15. Write .ts file in dir with .prettierrc → prettier invoked (exits 0)
# ---------------------------------------------------------------------------

@test "Write .ts in dir with .prettierrc → script exits 0 (prettier path exercised)" {
  local src_dir="$HOME/myapp/src"
  mkdir -p "$src_dir"
  echo '{}' > "$HOME/myapp/.prettierrc"
  local ts_file="$src_dir/app.ts"
  echo "export const x = 1" > "$ts_file"
  # Even if npx prettier isn't available, the script must not crash
  run bash "$HOOK_SH" <<< "$(write_payload "$ts_file" "export const x = 1")"
  assert_success
}

# ---------------------------------------------------------------------------
# 16–19. Security chain (Batch 2 — CAST follow-ups 2026-04-16)
#
# cast-post-tool.py emits [CAST-CHAIN: security] only when:
#   - main session (CLAUDE_SUBPROCESS not set or = "0")
#   - file path matches .sh or .py extension AND scripts/ or hooks/ path
#   - non-blank line count of content >= 5
# ---------------------------------------------------------------------------

# Helper: build Write payload for a scripts/ .sh file with N non-blank lines
scripts_sh_payload() {
  local file_path="${1:-scripts/foo.sh}"
  local line_count="${2:-6}"
  local content
  content="$(python3 -c "
import sys
n = int(sys.argv[1])
lines = ['#!/bin/bash'] + [f'echo line_{i}' for i in range(n - 1)]
print('\n'.join(lines))
" "$line_count")"
  python3 -c "import json,sys; print(json.dumps({'tool_name':'Write','tool_input':{'file_path':sys.argv[1],'content':sys.argv[2]},'tool_response':{}}))" "$file_path" "$content"
}

@test "security chain fires for scripts/foo.sh with 6 non-blank lines" {
  local file_path="$HOME/projects/repo/scripts/foo.sh"
  run bash "$HOOK_SH" <<< "$(scripts_sh_payload "$file_path" 6)"
  assert_success
  assert_output --partial "[CAST-CHAIN: security]"
}

@test "security chain does NOT fire for scripts/foo.sh with 3 non-blank lines" {
  local file_path="$HOME/projects/repo/scripts/foo.sh"
  run bash "$HOOK_SH" <<< "$(scripts_sh_payload "$file_path" 3)"
  assert_success
  refute_output --partial "[CAST-CHAIN: security]"
}

@test "security chain does NOT fire for src/components/Foo.jsx regardless of size" {
  local file_path="$HOME/projects/repo/src/components/Foo.jsx"
  local content
  content="$(python3 -c "
lines = ['import React from \"react\"'] + [f'const x{i} = {i}' for i in range(22)]
print('\n'.join(lines))
")"
  local payload
  payload="$(python3 -c "import json,sys; print(json.dumps({'tool_name':'Write','tool_input':{'file_path':sys.argv[1],'content':sys.argv[2]},'tool_response':{}}))" "$file_path" "$content")"
  run bash "$HOOK_SH" <<< "$payload"
  assert_success
  refute_output --partial "[CAST-CHAIN: security]"
}

@test "security chain does NOT fire when CLAUDE_SUBPROCESS=1" {
  local file_path="$HOME/projects/repo/scripts/foo.sh"
  run env CLAUDE_SUBPROCESS=1 bash "$HOOK_SH" <<< "$(scripts_sh_payload "$file_path" 10)"
  assert_success
  refute_output --partial "[CAST-CHAIN: security]"
}

# ===========================================================================
# D5 commit provenance — part5_commit_provenance in cast-post-tool.py
#
# Inside Claude Code's Bash sandbox ~/.claude/cast.db is read-only, so the
# Bash children that normally write the commit_provenance row (commit agent
# step 8, .githooks/post-commit) fail. The PostToolUse hook runs OUTSIDE the
# sandbox, so it records the row for hatch commits (CAST_COMMIT_AGENT=1).
# ===========================================================================

POST_TOOL_PY="$REPO_DIR/scripts/cast-post-tool.py"

# prov_init: temp DB provisioned by cast-db-init (schema SSOT) + fresh temp repo
# on branch `main`. Everything lives under the isolated temp HOME / BATS tmpdir.
prov_init() {
  export CAST_DB_PATH="$HOME/.claude/prov-test.db"
  bash "$REPO_DIR/scripts/cast-db-init.sh" --db "$CAST_DB_PATH" >/dev/null 2>&1
  PROV_REPO="$BATS_TEST_TMPDIR/prov-repo"
  mkdir -p "$PROV_REPO"
  git -C "$PROV_REPO" init -q
  git -C "$PROV_REPO" symbolic-ref HEAD refs/heads/main
}

# prov_commit [committer-date]: make an empty commit in $PROV_REPO. Default
# committer time is now; pass "<epoch> +0000" for an old HEAD.
prov_commit() {
  local when="${1:-$(date +%s) +0000}"
  GIT_COMMITTER_DATE="$when" GIT_AUTHOR_DATE="$when" \
    git -C "$PROV_REPO" -c user.name=t -c user.email=t@example.invalid \
      -c commit.gpgsign=false -c core.hooksPath=/dev/null \
      commit -q --allow-empty -m "fixture"
}

# prov_payload <command> <cwd> [session_id] [agent_type] [exit_code]
prov_payload() {
  python3 - "$@" <<'PYEOF'
import json, sys
a = sys.argv[1:]
d = {
    'tool_name': 'Bash',
    'tool_input': {'command': a[0]},
    'tool_response': {'stdout': '', 'stderr': ''},
    'cwd': a[1],
}
d['session_id'] = a[2] if len(a) > 2 else 'sess-prov'
if len(a) > 3 and a[3]:
    d['agent_type'] = a[3]
if len(a) > 4 and a[4]:
    d['tool_response']['exit_code'] = int(a[4])
print(json.dumps(d))
PYEOF
}

prov_count() { sqlite3 "$CAST_DB_PATH" "SELECT COUNT(*) FROM commit_provenance;"; }

@test "provenance: hatch commit records exactly one row (sha/session/agent/branch/repo)" {
  prov_init
  prov_commit
  local sha toplevel
  sha="$(git -C "$PROV_REPO" rev-parse HEAD)"
  toplevel="$(git -C "$PROV_REPO" rev-parse --show-toplevel)"

  run python3 "$POST_TOOL_PY" <<< "$(prov_payload 'CAST_COMMIT_AGENT=1 git commit -m "fixture"' "$PROV_REPO" sess-abc)"
  assert_success
  assert_output ""

  [ "$(prov_count)" = "1" ]
  run sqlite3 "$CAST_DB_PATH" "SELECT sha, session_id, agent, branch, repo FROM commit_provenance;"
  assert_output "${sha}|sess-abc|main-session|main|${toplevel}"
  run sqlite3 "$CAST_DB_PATH" "SELECT recorded_at FROM commit_provenance;"
  [[ "$output" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
}

@test "provenance: payload agent_type is recorded as the agent" {
  prov_init
  prov_commit
  run python3 "$POST_TOOL_PY" <<< "$(prov_payload 'CAST_COMMIT_AGENT=1 git commit -m x' "$PROV_REPO" sess-abc commit)"
  assert_success
  run sqlite3 "$CAST_DB_PATH" "SELECT agent FROM commit_provenance;"
  assert_output "commit"
}

@test "provenance: session_id is the payload's, never the CAST_SESSION_ID env fallback" {
  prov_init
  prov_commit
  run env CAST_SESSION_ID=env-sid CLAUDE_SESSION_ID=env-sid2 python3 "$POST_TOOL_PY" \
    <<< "$(prov_payload 'CAST_COMMIT_AGENT=1 git commit -m x' "$PROV_REPO" payload-sid)"
  assert_success
  run sqlite3 "$CAST_DB_PATH" "SELECT session_id FROM commit_provenance;"
  assert_output "payload-sid"
}

@test "provenance: payload without session_id stores empty, not an env guess" {
  prov_init
  prov_commit
  local payload
  payload="$(python3 -c "import json,sys; print(json.dumps({'tool_name':'Bash','tool_input':{'command':'CAST_COMMIT_AGENT=1 git commit -m x'},'tool_response':{},'cwd':sys.argv[1]}))" "$PROV_REPO")"
  run env CAST_SESSION_ID=env-sid python3 "$POST_TOOL_PY" <<< "$payload"
  assert_success
  [ "$(prov_count)" = "1" ]
  run sqlite3 "$CAST_DB_PATH" "SELECT session_id FROM commit_provenance;"
  assert_output ""
}

@test "provenance: row is written via the registered entrypoint post-tool-hook.sh" {
  prov_init
  prov_commit
  run bash "$HOOK_SH" <<< "$(prov_payload 'CAST_COMMIT_AGENT=1 git commit -m x' "$PROV_REPO" sess-e2e)"
  assert_success
  refute_output --partial "hookSpecificOutput"
  [ "$(prov_count)" = "1" ]
}

@test "provenance: hatch inside a later && segment and extra env assignments still record" {
  prov_init
  prov_commit
  run python3 "$POST_TOOL_PY" \
    <<< "$(prov_payload 'git add -A && CAST_COMMIT_AGENT=1 CAST_SKIP_PLUGIN_DRIFT=1 git commit -m "x"' "$PROV_REPO")"
  assert_success
  [ "$(prov_count)" = "1" ]
}

@test "provenance: commit without the hatch records nothing" {
  prov_init
  prov_commit
  run python3 "$POST_TOOL_PY" <<< "$(prov_payload 'git commit -m "x"' "$PROV_REPO")"
  assert_success
  [ "$(prov_count)" = "0" ]
}

@test "provenance: hatch text that is not a commit invocation records nothing" {
  prov_init
  prov_commit
  # Both pass the cheap substring precheck; neither is a hatch commit per the guard.
  run python3 "$POST_TOOL_PY" <<< "$(prov_payload 'CAST_COMMIT_AGENT=1 git status' "$PROV_REPO")"
  assert_success
  run python3 "$POST_TOOL_PY" <<< "$(prov_payload 'echo "CAST_COMMIT_AGENT=1 git commit -m x"' "$PROV_REPO")"
  assert_success
  [ "$(prov_count)" = "0" ]
}

@test "provenance: hatch --dry-run records nothing even when HEAD is fresh" {
  prov_init
  prov_commit
  run python3 "$POST_TOOL_PY" <<< "$(prov_payload 'CAST_COMMIT_AGENT=1 git commit --dry-run' "$PROV_REPO")"
  assert_success
  [ "$(prov_count)" = "0" ]
}

@test "provenance: HEAD committed more than 120s ago records nothing (nothing-to-commit || true)" {
  prov_init
  prov_commit "$(( $(date +%s) - 600 )) +0000"
  run python3 "$POST_TOOL_PY" <<< "$(prov_payload 'CAST_COMMIT_AGENT=1 git commit -m x || true' "$PROV_REPO")"
  assert_success
  [ "$(prov_count)" = "0" ]
}

@test "provenance: cwd that is not a git repo records nothing, exits 0, prints nothing" {
  prov_init
  mkdir -p "$BATS_TEST_TMPDIR/not-a-repo"
  run python3 "$POST_TOOL_PY" <<< "$(prov_payload 'CAST_COMMIT_AGENT=1 git commit -m x' "$BATS_TEST_TMPDIR/not-a-repo")"
  assert_success
  assert_output ""
  [ "$(prov_count)" = "0" ]
}

@test "provenance: unwritable DB exits 0 and prints nothing" {
  [ "$(id -u)" != "0" ] || skip "root bypasses file permissions"
  prov_init
  prov_commit
  chmod 444 "$CAST_DB_PATH"
  run python3 "$POST_TOOL_PY" <<< "$(prov_payload 'CAST_COMMIT_AGENT=1 git commit -m x' "$PROV_REPO")"
  chmod 644 "$CAST_DB_PATH"
  assert_success
  assert_output ""
  [ "$(prov_count)" = "0" ]
}

@test "provenance: second identical PostToolUse still leaves one row" {
  prov_init
  prov_commit
  local payload
  payload="$(prov_payload 'CAST_COMMIT_AGENT=1 git commit -m x' "$PROV_REPO" sess-abc)"
  run python3 "$POST_TOOL_PY" <<< "$payload"
  assert_success
  run python3 "$POST_TOOL_PY" <<< "$payload"
  assert_success
  [ "$(prov_count)" = "1" ]
}

@test "provenance: an existing row (post-commit hook / commit agent) is write-once — agent AND session_id unchanged" {
  prov_init
  prov_commit
  local sha
  sha="$(git -C "$PROV_REPO" rev-parse HEAD)"
  sqlite3 "$CAST_DB_PATH" "INSERT INTO commit_provenance (sha, session_id, agent, branch, repo, recorded_at) VALUES ('$sha', 'orig-sid', 'commit', 'orig-branch', '/orig/repo', '2026-01-01T00:00:00Z');"
  run python3 "$POST_TOOL_PY" <<< "$(prov_payload 'CAST_COMMIT_AGENT=1 git commit -m x' "$PROV_REPO" other-sid backend-writer)"
  assert_success
  [ "$(prov_count)" = "1" ]
  run sqlite3 "$CAST_DB_PATH" "SELECT sha, session_id, agent, branch, repo, recorded_at FROM commit_provenance;"
  assert_output "${sha}|orig-sid|commit|orig-branch|/orig/repo|2026-01-01T00:00:00Z"
}

@test "provenance: hatch --dry (git accepts unique option prefixes) records nothing even when HEAD is fresh" {
  prov_init
  prov_commit
  run python3 "$POST_TOOL_PY" <<< "$(prov_payload 'CAST_COMMIT_AGENT=1 git commit --dry' "$PROV_REPO")"
  assert_success
  [ "$(prov_count)" = "0" ]
}

# --- security: the hook runs OUTSIDE the sandbox against an agent-controlled cwd ---

@test "provenance: a repo with log.showSignature=true + gpg.program + gpgsig HEAD never executes the gpg.program" {
  prov_init
  local marker="$BATS_TEST_TMPDIR/gpg-ran.marker" prog="$BATS_TEST_TMPDIR/gpg-marker.sh" tree ts sha
  printf '#!/bin/sh\ntouch "%s"\nexit 1\n' "$marker" > "$prog"
  chmod +x "$prog"
  git -C "$PROV_REPO" config log.showSignature true
  git -C "$PROV_REPO" config gpg.program "$prog"
  git -C "$PROV_REPO" config gpg.ssh.program "$prog"
  # HEAD = a commit carrying a gpgsig header, built with hash-object (no gpg needed).
  tree="$(git -C "$PROV_REPO" hash-object -t tree -w /dev/null)"
  ts="$(date +%s)"
  sha="$(printf 'tree %s\nauthor t <t@example.invalid> %s +0000\ncommitter t <t@example.invalid> %s +0000\ngpgsig -----BEGIN PGP SIGNATURE-----\n \n fakesig\n -----END PGP SIGNATURE-----\n\nsigned fixture\n' "$tree" "$ts" "$ts" \
    | git -C "$PROV_REPO" hash-object -t commit -w --stdin)"
  git -C "$PROV_REPO" update-ref refs/heads/main "$sha"
  # Precondition (not vacuous): plain `git log -1` really does run the program here.
  git -C "$PROV_REPO" log -1 >/dev/null 2>&1 || true
  [ -e "$marker" ]
  rm -f "$marker"

  run python3 "$POST_TOOL_PY" <<< "$(prov_payload 'CAST_COMMIT_AGENT=1 git commit -m x' "$PROV_REPO" sess-sig)"
  assert_success
  [ ! -e "$marker" ]
  # The gpgsig-headed commit is still parsed correctly by the plumbing path.
  [ "$(prov_count)" = "1" ]
  run sqlite3 "$CAST_DB_PATH" "SELECT sha FROM commit_provenance;"
  assert_output "$sha"
}

@test "provenance: core.worktree pointing elsewhere (toplevel outside cwd) records nothing" {
  prov_init
  mkdir -p "$BATS_TEST_TMPDIR/elsewhere"
  git -C "$PROV_REPO" config core.worktree "$BATS_TEST_TMPDIR/elsewhere"
  prov_commit
  # Precondition (not vacuous): git really reports the decoy path as the toplevel.
  [ "$(git -C "$PROV_REPO" rev-parse --show-toplevel)" = "$(cd "$BATS_TEST_TMPDIR/elsewhere" && pwd -P)" ]
  run python3 "$POST_TOOL_PY" <<< "$(prov_payload 'CAST_COMMIT_AGENT=1 git commit -m x' "$PROV_REPO")"
  assert_success
  [ "$(prov_count)" = "0" ]
}

@test "provenance: git calls share ONE ~4s deadline (slow git → no row, hook returns well under 10s)" {
  prov_init
  prov_commit
  local real_git shim="$BATS_TEST_TMPDIR/slow-git" t0 t1
  real_git="$(command -v git)"
  mkdir -p "$shim"
  printf '#!/bin/sh\nsleep 1.5\nexec "%s" "$@"\n' "$real_git" > "$shim/git"
  chmod +x "$shim/git"
  t0="$(date +%s)"
  run env PATH="$shim:$PATH" python3 "$POST_TOOL_PY" <<< "$(prov_payload 'CAST_COMMIT_AGENT=1 git commit -m x' "$PROV_REPO")"
  t1="$(date +%s)"
  assert_success
  # Sequential 1.5s calls add up to >6s unbounded; a shared 4s budget aborts the third.
  [ "$(prov_count)" = "0" ]
  [ "$(( t1 - t0 ))" -lt 6 ]
}

# prov_hostile_promisor <vector>: turn $PROV_REPO into a partial-clone ("promisor") repo
# whose HEAD names a sha ABSENT locally. Reading that object makes git lazily fetch it
# through a repo-configured transport helper, which here is a marker script.
prov_hostile_promisor() {
  local vector="$1"
  PROV_MARKER="$BATS_TEST_TMPDIR/lazy-fetch-ran.marker"
  PROV_PROG="$BATS_TEST_TMPDIR/lazy-prog.sh"
  PROV_MISSING_SHA="1234567890abcdef1234567890abcdef12345678"
  printf '#!/bin/sh\ntouch "%s"\nexit 1\n' "$PROV_MARKER" > "$PROV_PROG"
  chmod +x "$PROV_PROG"
  git -C "$PROV_REPO" config core.repositoryformatversion 1
  git -C "$PROV_REPO" config extensions.partialClone origin
  git -C "$PROV_REPO" config remote.origin.promisor true
  case "$vector" in
    uploadpack)
      git -C "$PROV_REPO" config remote.origin.url "$BATS_TEST_TMPDIR/no-such-remote"
      git -C "$PROV_REPO" config remote.origin.uploadpack "$PROV_PROG" ;;
    sshCommand)
      git -C "$PROV_REPO" config remote.origin.url "ssh://example.invalid/x"
      git -C "$PROV_REPO" config core.sshCommand "$PROV_PROG" ;;
    gitProxy)
      git -C "$PROV_REPO" config remote.origin.url "git://example.invalid/x"
      git -C "$PROV_REPO" config core.gitProxy "$PROV_PROG" ;;
    ext)
      git -C "$PROV_REPO" config remote.origin.url "ext::$PROV_PROG"
      git -C "$PROV_REPO" config protocol.ext.allow always ;;
  esac
  printf '%s\n' "$PROV_MISSING_SHA" > "$PROV_REPO/.git/refs/heads/main"
}

# The sandbox sets GIT_SSH_COMMAND, which overrides core.sshCommand — unset it (and
# GIT_SSH) so the vector is live and ONLY the hook's own guards can stop it.
prov_assert_lazy_fetch_inert() {
  prov_init
  prov_hostile_promisor "$1"
  # Precondition (not vacuous): a plain `git cat-file` of the missing sha fires the marker.
  env -u GIT_SSH_COMMAND -u GIT_SSH git -C "$PROV_REPO" cat-file commit "$PROV_MISSING_SHA" >/dev/null 2>&1 || true
  [ -e "$PROV_MARKER" ]
  rm -f "$PROV_MARKER"

  run env -u GIT_SSH_COMMAND -u GIT_SSH python3 "$POST_TOOL_PY" \
    <<< "$(prov_payload 'CAST_COMMIT_AGENT=1 git commit -m x' "$PROV_REPO")"
  assert_success
  assert_output ""
  [ ! -e "$PROV_MARKER" ]
  [ "$(prov_count)" = "0" ]
}

@test "provenance: missing object in a promisor repo — remote.origin.uploadpack is never executed (lazy fetch)" {
  prov_assert_lazy_fetch_inert uploadpack
}

@test "provenance: missing object in a promisor repo — core.sshCommand is never executed (lazy fetch)" {
  prov_assert_lazy_fetch_inert sshCommand
}

@test "provenance: missing object in a promisor repo — core.gitProxy is never executed (lazy fetch)" {
  prov_assert_lazy_fetch_inert gitProxy
}

@test "provenance: missing object in a promisor repo — ext:: transport is never executed (lazy fetch)" {
  prov_assert_lazy_fetch_inert ext
}

@test "provenance: an oversized commit object (>1 MiB) records nothing (bounded read)" {
  prov_init
  local tree ts sha body="$BATS_TEST_TMPDIR/big-commit.txt"
  tree="$(git -C "$PROV_REPO" hash-object -t tree -w /dev/null)"
  ts="$(date +%s)"
  {
    printf 'tree %s\nauthor t <t@example.invalid> %s +0000\ncommitter t <t@example.invalid> %s +0000\n\n' "$tree" "$ts" "$ts"
    head -c 1300000 /dev/zero | tr '\0' 'a'
    printf '\n'
  } > "$body"
  sha="$(git -C "$PROV_REPO" hash-object -t commit -w --stdin < "$body")"
  git -C "$PROV_REPO" update-ref refs/heads/main "$sha"
  # Precondition (not vacuous): the object really is over the 1 MiB cap, and otherwise fresh.
  [ "$(git -C "$PROV_REPO" cat-file -s "$sha")" -gt 1048576 ]
  run python3 "$POST_TOOL_PY" <<< "$(prov_payload 'CAST_COMMIT_AGENT=1 git commit -m x' "$PROV_REPO")"
  assert_success
  assert_output ""
  [ "$(prov_count)" = "0" ]
}

@test "provenance: a failed tool call (non-zero exit) records nothing" {
  prov_init
  prov_commit
  run python3 "$POST_TOOL_PY" <<< "$(prov_payload 'CAST_COMMIT_AGENT=1 git commit -m x' "$PROV_REPO" sess-abc '' 1)"
  assert_success
  [ "$(prov_count)" = "0" ]
}

@test "provenance: non-commit Bash behaviour is unchanged (CAST-DEBUG on failure, no row)" {
  prov_init
  prov_commit
  run python3 "$POST_TOOL_PY" <<< "$(prov_payload 'false' "$PROV_REPO" sess-abc '' 1)"
  assert_success
  assert_output --partial "[CAST-DEBUG]"
  run python3 "$POST_TOOL_PY" <<< "$(prov_payload 'ls' "$PROV_REPO" sess-abc)"
  assert_success
  assert_output ""
  [ "$(prov_count)" = "0" ]
}

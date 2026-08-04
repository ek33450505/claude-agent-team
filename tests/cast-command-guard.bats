#!/usr/bin/env bats
#
# cast-command-guard.bats — prove-refusal tests for the PreToolUse Bash command-guard.
# Mirrors tests/pre-tool-guard.bats. Self-isolates via setup_temp_home, so it is safe
# to run directly (it never touches the real $HOME).
#
# cast-command-guard.sh (the thin bash wrapper) was removed 2026-08-04 — dead code,
# never wired in settings.json, superseded by cast-pretool-dispatch.py (which loads
# cast-command-guard.py as a library, not a subprocess). Tests below invoke the .py
# entrypoint directly; the guard GUARANTEES they prove are unchanged.

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
HOOK_PY="$REPO_DIR/scripts/cast-command-guard.py"

setup() {
  load 'helpers/setup'
  setup_temp_home
  export CLAUDE_DIR="$HOME/.claude"
  mkdir -p "$HOME/.claude/logs"

  # Unset bypass / input env vars so each test starts clean
  unset CLAUDE_SUBPROCESS
  unset CAST_KILL_OK
  unset CAST_RM_OK
  unset CAST_CMD_GUARD_INPUT
}

teardown() {
  unset CLAUDE_DIR
  teardown_temp_home
}

# Build a Bash tool payload. Command is passed via env (CMD) to avoid quoting hell.
make_bash_payload() {
  CMD="$1" python3 -c "
import json, os
print(json.dumps({'tool_name': 'Bash', 'tool_input': {'command': os.environ.get('CMD', '')}}))
"
}

# Build a non-Bash (Write) payload — even with a dangerous string inside.
make_write_payload() {
  python3 -c "
import json
print(json.dumps({'tool_name': 'Write', 'tool_input': {'file_path': '/tmp/x', 'content': 'rm -rf / ; pkill -9 bash'}}))
"
}

# ---------------------------------------------------------------------------
# BLOCK — process-kill (pkill / killall)
# ---------------------------------------------------------------------------

@test "pkill -9 bash → blocks (exit 2)" {
  run python3 "$HOOK_PY" <<< "$(make_bash_payload "pkill -9 bash")"
  assert_failure
  [[ "$status" -eq 2 ]]
  assert_output --partial "[CAST]"
}

@test "pkill node → blocks (exit 2)" {
  run python3 "$HOOK_PY" <<< "$(make_bash_payload "pkill node")"
  assert_failure
  [[ "$status" -eq 2 ]]
  assert_output --partial "[CAST]"
}

@test "killall -9 bash → blocks (exit 2)" {
  run python3 "$HOOK_PY" <<< "$(make_bash_payload "killall -9 bash")"
  assert_failure
  [[ "$status" -eq 2 ]]
  assert_output --partial "[CAST]"
}

@test "killall Terminal → blocks (exit 2)" {
  run python3 "$HOOK_PY" <<< "$(make_bash_payload "killall Terminal")"
  assert_failure
  [[ "$status" -eq 2 ]]
  assert_output --partial "[CAST]"
}

@test "echo x && pkill bash → blocks (pkill in command position after &&)" {
  run python3 "$HOOK_PY" <<< "$(make_bash_payload "echo x && pkill bash")"
  assert_failure
  [[ "$status" -eq 2 ]]
  assert_output --partial "[CAST]"
}

# ---------------------------------------------------------------------------
# BLOCK — mass kill (process group / all processes)
# ---------------------------------------------------------------------------

@test "kill -9 -1 → blocks (signal to all processes)" {
  run python3 "$HOOK_PY" <<< "$(make_bash_payload "kill -9 -1")"
  assert_failure
  [[ "$status" -eq 2 ]]
  assert_output --partial "[CAST]"
}

@test "kill 0 → blocks (process group 0)" {
  run python3 "$HOOK_PY" <<< "$(make_bash_payload "kill 0")"
  assert_failure
  [[ "$status" -eq 2 ]]
  assert_output --partial "[CAST]"
}

@test "kill -- -1234 → blocks (explicit negative pgid after --)" {
  run python3 "$HOOK_PY" <<< "$(make_bash_payload "kill -- -1234")"
  assert_failure
  [[ "$status" -eq 2 ]]
  assert_output --partial "[CAST]"
}

# ---------------------------------------------------------------------------
# BLOCK — catastrophic rm
# ---------------------------------------------------------------------------

@test "rm -rf ~/.claude → blocks (literal tilde home)" {
  run python3 "$HOOK_PY" <<< "$(make_bash_payload "rm -rf ~/.claude")"
  assert_failure
  [[ "$status" -eq 2 ]]
  assert_output --partial "[CAST]"
}

@test "rm -rf \$HOME (literal) → blocks" {
  run python3 "$HOOK_PY" <<< "$(make_bash_payload 'rm -rf $HOME')"
  assert_failure
  [[ "$status" -eq 2 ]]
  assert_output --partial "[CAST]"
}

@test "rm -rf \"\$HOME\" (literal quoted) → blocks" {
  run python3 "$HOOK_PY" <<< "$(make_bash_payload 'rm -rf "$HOME"')"
  assert_failure
  [[ "$status" -eq 2 ]]
  assert_output --partial "[CAST]"
}

@test "rm -rf \${HOME}/.claude (literal braces) → blocks" {
  run python3 "$HOOK_PY" <<< "$(make_bash_payload 'rm -rf ${HOME}/.claude')"
  assert_failure
  [[ "$status" -eq 2 ]]
  assert_output --partial "[CAST]"
}

@test "rm -rf / → blocks (root)" {
  run python3 "$HOOK_PY" <<< "$(make_bash_payload "rm -rf /")"
  assert_failure
  [[ "$status" -eq 2 ]]
  assert_output --partial "[CAST]"
}

@test "rm -rf ~ → blocks (bare tilde home)" {
  run python3 "$HOOK_PY" <<< "$(make_bash_payload "rm -rf ~")"
  assert_failure
  [[ "$status" -eq 2 ]]
  assert_output --partial "[CAST]"
}

@test "rm -rf . → blocks (cwd)" {
  run python3 "$HOOK_PY" <<< "$(make_bash_payload "rm -rf .")"
  assert_failure
  [[ "$status" -eq 2 ]]
  assert_output --partial "[CAST]"
}

@test "rm -rf \$HOME (resolved temp-home absolute path) → blocks" {
  # $HOME is expanded here (double-quoted) to the temp-home absolute path; the
  # guard must match it via the resolved-home base.
  run python3 "$HOOK_PY" <<< "$(make_bash_payload "rm -rf $HOME")"
  assert_failure
  [[ "$status" -eq 2 ]]
  assert_output --partial "[CAST]"
}

@test "rm -rf \$HOME/.claude (resolved temp-home subpath) → blocks" {
  run python3 "$HOOK_PY" <<< "$(make_bash_payload "rm -rf $HOME/.claude")"
  assert_failure
  [[ "$status" -eq 2 ]]
  assert_output --partial "[CAST]"
}

# ---------------------------------------------------------------------------
# ALLOW — legitimate kill (test-runner timeout guard depends on these)
# ---------------------------------------------------------------------------

@test "kill \"\$SUITE_PID\" → allows" {
  run python3 "$HOOK_PY" <<< "$(make_bash_payload 'kill "$SUITE_PID"')"
  assert_success
}

@test "kill -0 \"\$SUITE_PID\" → allows (liveness probe)" {
  run python3 "$HOOK_PY" <<< "$(make_bash_payload 'kill -0 "$SUITE_PID"')"
  assert_success
}

@test "kill 12345 → allows (single pid)" {
  run python3 "$HOOK_PY" <<< "$(make_bash_payload "kill 12345")"
  assert_success
}

@test "kill -9 12345 → allows (signal to single pid)" {
  run python3 "$HOOK_PY" <<< "$(make_bash_payload "kill -9 12345")"
  assert_success
}

@test "kill -TERM 999 → allows (named signal to single pid)" {
  run python3 "$HOOK_PY" <<< "$(make_bash_payload "kill -TERM 999")"
  assert_success
}

# ---------------------------------------------------------------------------
# ALLOW — legitimate rm
# ---------------------------------------------------------------------------

@test "rm -rf /tmp/foo → allows" {
  run python3 "$HOOK_PY" <<< "$(make_bash_payload "rm -rf /tmp/foo")"
  assert_success
}

@test "rm -rf \"\$TEST_HOME\" → allows (non-HOME variable not protected)" {
  run python3 "$HOOK_PY" <<< "$(make_bash_payload 'rm -rf "$TEST_HOME"')"
  assert_success
}

@test "rm -rf ./build → allows" {
  run python3 "$HOOK_PY" <<< "$(make_bash_payload "rm -rf ./build")"
  assert_success
}

@test "rm -rf node_modules → allows" {
  run python3 "$HOOK_PY" <<< "$(make_bash_payload "rm -rf node_modules")"
  assert_success
}

# ---------------------------------------------------------------------------
# ALLOW — harmless commands + mentions
# ---------------------------------------------------------------------------

@test "ls -la → allows" {
  run python3 "$HOOK_PY" <<< "$(make_bash_payload "ls -la")"
  assert_success
}

@test "git status → allows" {
  run python3 "$HOOK_PY" <<< "$(make_bash_payload "git status")"
  assert_success
}

@test "echo \"use pkill to kill the process\" → allows (mention, not command position)" {
  run python3 "$HOOK_PY" <<< "$(make_bash_payload 'echo "use pkill to kill the process"')"
  assert_success
}

# ---------------------------------------------------------------------------
# ALLOW — escape hatches
# ---------------------------------------------------------------------------

@test "CAST_KILL_OK=1 pkill bash → allows (kill escape hatch)" {
  run python3 "$HOOK_PY" <<< "$(make_bash_payload "CAST_KILL_OK=1 pkill bash")"
  assert_success
}

@test "CAST_RM_OK=1 rm -rf ~/.claude → allows (rm escape hatch)" {
  run python3 "$HOOK_PY" <<< "$(make_bash_payload "CAST_RM_OK=1 rm -rf ~/.claude")"
  assert_success
}

# ---------------------------------------------------------------------------
# ALLOW — non-Bash tool, empty / malformed input, subprocess bypass
# ---------------------------------------------------------------------------

@test "non-Bash tool payload (Write) → allows even with dangerous content" {
  run python3 "$HOOK_PY" <<< "$(make_write_payload)"
  assert_success
}

@test "empty input → allows (graceful no-op)" {
  run python3 "$HOOK_PY" <<< ""
  assert_success
}

@test "malformed JSON input → allows (fail-open)" {
  run python3 "$HOOK_PY" <<< "not valid json at all"
  assert_success
}

@test "CLAUDE_SUBPROCESS=1 → destructive rm still blocks (command guard not skipped)" {
  # Matches tests/cast-pretool-dispatch.bats "CLAUDE_SUBPROCESS=1 + destructive pkill
  # → blocks" and reference_claude_subprocess_semantics: CLAUDE_SUBPROCESS=1 marks a
  # managed/headless subprocess but does NOT bypass the destructive-command guard —
  # only the (now-removed) .sh wrapper ever implemented that bypass; the .py guard
  # itself never has, and the current dispatcher runs it in every context.
  export CLAUDE_SUBPROCESS=1
  run python3 "$HOOK_PY" <<< "$(make_bash_payload "rm -rf /")"
  assert_failure
  [[ "$status" -eq 2 ]]
  assert_output --partial "[CAST]"
}

# ===========================================================================
# FIX 1 — home-subtree OVER-BLOCK: only the home ROOT + .claude subtree protected
# ===========================================================================

@test "FIX1 BLOCK: rm -rf .. → blocks (parent dir, exact)" {
  run python3 "$HOOK_PY" <<< "$(make_bash_payload "rm -rf ..")"
  assert_failure
  [[ "$status" -eq 2 ]]
  assert_output --partial "[CAST]"
}

@test "FIX1 BLOCK: rm -rf ~/.claude/logs → blocks (.claude subtree child)" {
  run python3 "$HOOK_PY" <<< "$(make_bash_payload "rm -rf ~/.claude/logs")"
  assert_failure
  [[ "$status" -eq 2 ]]
  assert_output --partial "[CAST]"
}

@test "FIX1 BLOCK: rm -rf \$HOME/.claude (resolved subtree base) → blocks" {
  run python3 "$HOOK_PY" <<< "$(make_bash_payload "rm -rf $HOME/.claude")"
  assert_failure
  [[ "$status" -eq 2 ]]
  assert_output --partial "[CAST]"
}

@test "FIX1 ALLOW: rm -rf ~/Projects/x/node_modules → allows (non-.claude home subpath)" {
  run python3 "$HOOK_PY" <<< "$(make_bash_payload "rm -rf ~/Projects/x/node_modules")"
  assert_success
}

@test "FIX1 ALLOW: rm -rf \"\$HOME/Projects/x/dist\" (literal) → allows" {
  run python3 "$HOOK_PY" <<< "$(make_bash_payload 'rm -rf "$HOME/Projects/x/dist"')"
  assert_success
}

@test "FIX1 ALLOW: rm -rf ~/.cache/pip → allows (non-.claude dotdir)" {
  run python3 "$HOOK_PY" <<< "$(make_bash_payload "rm -rf ~/.cache/pip")"
  assert_success
}

@test "FIX1 ALLOW: rm -rf ~/Downloads/tmpbuild → allows" {
  run python3 "$HOOK_PY" <<< "$(make_bash_payload "rm -rf ~/Downloads/tmpbuild")"
  assert_success
}

@test "FIX1 ALLOW: rm -rf \$HOME/Projects/x/node_modules (resolved subpath) → allows" {
  run python3 "$HOOK_PY" <<< "$(make_bash_payload "rm -rf $HOME/Projects/x/node_modules")"
  assert_success
}

@test "FIX1 ALLOW: rm -rf \$HOME/.cast-worktrees/wt-1 (resolved subpath) → allows" {
  run python3 "$HOOK_PY" <<< "$(make_bash_payload "rm -rf $HOME/.cast-worktrees/wt-1")"
  assert_success
}

# ===========================================================================
# FIX 2 — rm -rf /* root glob (and /.*) is catastrophic
# ===========================================================================

@test "FIX2 BLOCK: rm -rf /* → blocks (root glob)" {
  run python3 "$HOOK_PY" <<< "$(make_bash_payload 'rm -rf /*')"
  assert_failure
  [[ "$status" -eq 2 ]]
  assert_output --partial "[CAST]"
}

@test "FIX2 BLOCK: rm -rf /.* → blocks (root dot-glob)" {
  run python3 "$HOOK_PY" <<< "$(make_bash_payload 'rm -rf /.*')"
  assert_failure
  [[ "$status" -eq 2 ]]
  assert_output --partial "[CAST]"
}

@test "FIX2 ALLOW: rm -rf /tmp/foo → allows (non-root absolute)" {
  run python3 "$HOOK_PY" <<< "$(make_bash_payload "rm -rf /tmp/foo")"
  assert_success
}

# ===========================================================================
# FIX 3 — fail-open: non-dict / malformed JSON must exit 0, never traceback
# ===========================================================================

@test "FIX3 ALLOW: payload 123 (non-dict number) → exit 0, no traceback" {
  run python3 "$HOOK_PY" <<< '123'
  [[ "$status" -eq 0 ]]
  refute_output --partial "Traceback"
}

@test "FIX3 ALLOW: payload [1,2,3] (non-dict array) → exit 0, no traceback" {
  run python3 "$HOOK_PY" <<< '[1,2,3]'
  [[ "$status" -eq 0 ]]
  refute_output --partial "Traceback"
}

@test "FIX3 ALLOW: tool_input is a string (not object) → exit 0, no traceback" {
  run python3 "$HOOK_PY" <<< '{"tool_name":"Bash","tool_input":"oops"}'
  [[ "$status" -eq 0 ]]
  refute_output --partial "Traceback"
}

# ===========================================================================
# FIX 4 — backtick command substitution caught (consistent with $())
# ===========================================================================

@test "FIX4 BLOCK: echo \`pkill -9 bash\` → blocks (pkill in backtick subst)" {
  run python3 "$HOOK_PY" <<< "$(make_bash_payload 'echo `pkill -9 bash`')"
  assert_failure
  [[ "$status" -eq 2 ]]
  assert_output --partial "[CAST]"
}

@test "FIX4 BLOCK: x=\`rm -rf ~/.claude\` → blocks (rm in backtick subst)" {
  run python3 "$HOOK_PY" <<< "$(make_bash_payload 'x=`rm -rf ~/.claude`')"
  assert_failure
  [[ "$status" -eq 2 ]]
  assert_output --partial "[CAST]"
}

# ===========================================================================
# FIX 5 — mid-token quote-concat (shell-joined path) caught
# ===========================================================================

@test "FIX5 BLOCK: rm -rf \$HOME\"/.claude\" → blocks (quote-concat)" {
  run python3 "$HOOK_PY" <<< "$(make_bash_payload 'rm -rf $HOME"/.claude"')"
  assert_failure
  [[ "$status" -eq 2 ]]
  assert_output --partial "[CAST]"
}

@test "FIX5 BLOCK: rm -rf \"\$HOME\"/.claude → blocks (leading-quoted concat)" {
  run python3 "$HOOK_PY" <<< "$(make_bash_payload 'rm -rf "$HOME"/.claude')"
  assert_failure
  [[ "$status" -eq 2 ]]
  assert_output --partial "[CAST]"
}

@test "FIX5 BLOCK: rm -rf ~\"/.claude\" → blocks (tilde quote-concat)" {
  run python3 "$HOOK_PY" <<< "$(make_bash_payload 'rm -rf ~"/.claude"')"
  assert_failure
  [[ "$status" -eq 2 ]]
  assert_output --partial "[CAST]"
}

# ===========================================================================
# FIX 6 — heredoc bodies are inert data (not scanned as commands)
# ===========================================================================

@test "FIX6 ALLOW: heredoc body containing 'rm -rf /' → allows (body is data)" {
  CMD=$'cat <<EOF\nrm -rf /\nEOF\n'
  run python3 "$HOOK_PY" <<< "$(make_bash_payload "$CMD")"
  assert_success
}

@test "FIX6 ALLOW: quoted-delim heredoc body containing 'pkill -9 bash' → allows" {
  CMD=$'cat <<\'EOF\'\npkill -9 bash\nEOF\n'
  run python3 "$HOOK_PY" <<< "$(make_bash_payload "$CMD")"
  assert_success
}

@test "FIX6 BLOCK: rm -rf ~/.claude OUTSIDE the heredoc → blocks" {
  CMD=$'cat <<EOF\nsome inert text\nEOF\nrm -rf ~/.claude\n'
  run python3 "$HOOK_PY" <<< "$(make_bash_payload "$CMD")"
  assert_failure
  [[ "$status" -eq 2 ]]
  assert_output --partial "[CAST]"
}

# ===========================================================================
# FIX 7 — comments & redirections not mis-collected as rm targets
# ===========================================================================

@test "FIX7 ALLOW: rm -rf ./build # mentions ~/.claude in comment → allows" {
  run python3 "$HOOK_PY" <<< "$(make_bash_payload 'rm -rf ./build # mentions ~/.claude in comment')"
  assert_success
}

@test "FIX7 ALLOW: rm -rf ./build > ~/.claude/build.log 2>&1 → allows (redirect target)" {
  run python3 "$HOOK_PY" <<< "$(make_bash_payload 'rm -rf ./build > ~/.claude/build.log 2>&1')"
  assert_success
}

@test "FIX7 BLOCK: rm -rf ~/.claude > x.log → blocks (rm target before redirect)" {
  run python3 "$HOOK_PY" <<< "$(make_bash_payload 'rm -rf ~/.claude > x.log')"
  assert_failure
  [[ "$status" -eq 2 ]]
  assert_output --partial "[CAST]"
}

# ===========================================================================
# FIX 8 — per-segment escape hatch + backslash/wrapper bypass
# ===========================================================================

@test "FIX8 BLOCK: CAST_RM_OK=1 echo x; rm -rf ~ → blocks (hatch only exempts first segment)" {
  run python3 "$HOOK_PY" <<< "$(make_bash_payload 'CAST_RM_OK=1 echo x; rm -rf ~')"
  assert_failure
  [[ "$status" -eq 2 ]]
  assert_output --partial "[CAST]"
}

@test "FIX8 BLOCK: \\pkill bash → blocks (leading backslash stripped)" {
  run python3 "$HOOK_PY" <<< "$(make_bash_payload "\\pkill bash")"
  assert_failure
  [[ "$status" -eq 2 ]]
  assert_output --partial "[CAST]"
}

@test "FIX8 BLOCK: command pkill bash → blocks (wrapper unwrapped)" {
  run python3 "$HOOK_PY" <<< "$(make_bash_payload 'command pkill bash')"
  assert_failure
  [[ "$status" -eq 2 ]]
  assert_output --partial "[CAST]"
}

@test "FIX8 BLOCK: exec pkill bash → blocks (wrapper unwrapped)" {
  run python3 "$HOOK_PY" <<< "$(make_bash_payload 'exec pkill bash')"
  assert_failure
  [[ "$status" -eq 2 ]]
  assert_output --partial "[CAST]"
}

@test "FIX8 BLOCK: nohup pkill bash → blocks (wrapper unwrapped)" {
  run python3 "$HOOK_PY" <<< "$(make_bash_payload 'nohup pkill bash')"
  assert_failure
  [[ "$status" -eq 2 ]]
  assert_output --partial "[CAST]"
}

@test "FIX8 ALLOW: nohup bash tests/run.sh --tap → allows (bash is the command)" {
  run python3 "$HOOK_PY" <<< "$(make_bash_payload 'nohup bash tests/run.sh --tap')"
  assert_success
}

@test "FIX8 ALLOW: time bats tests/foo.bats → allows (bats is the command)" {
  run python3 "$HOOK_PY" <<< "$(make_bash_payload 'time bats tests/foo.bats')"
  assert_success
}

# ===========================================================================
# FIX 9 — heredoc detection is quote/comment-aware; here-strings are not heredocs
#   A `<<WORD` that bash treats as INERT (inside quotes, after an unquoted comment,
#   or as a `<<<` here-string) must NOT open a heredoc, so a real rm/pkill on a
#   later line — which bash WOULD run — is still scanned and blocked.
# ===========================================================================

@test "FIX9 BLOCK: quoted '<<EOF' then rm -rf ~/.claude → blocks (quoted, not a heredoc)" {
  CMD=$'echo \'<<EOF\'\nrm -rf ~/.claude'
  run python3 "$HOOK_PY" <<< "$(make_bash_payload "$CMD")"
  assert_failure
  [[ "$status" -eq 2 ]]
  assert_output --partial "[CAST]"
}

@test "FIX9 BLOCK: '# <<EOF' comment then rm -rf ~/.claude → blocks (comment, not a heredoc)" {
  CMD=$'# <<EOF\nrm -rf ~/.claude'
  run python3 "$HOOK_PY" <<< "$(make_bash_payload "$CMD")"
  assert_failure
  [[ "$status" -eq 2 ]]
  assert_output --partial "[CAST]"
}

@test "FIX9 BLOCK: \"see <<EOF here\" then rm -rf ~ → blocks (double-quoted, not a heredoc)" {
  CMD=$'echo "see <<EOF here"\nrm -rf ~'
  run python3 "$HOOK_PY" <<< "$(make_bash_payload "$CMD")"
  assert_failure
  [[ "$status" -eq 2 ]]
  assert_output --partial "[CAST]"
}

@test "FIX9 BLOCK: <<<EOF here-string then rm -rf ~/.claude → blocks (here-string, not a heredoc)" {
  CMD=$'echo "x" <<<EOF\nrm -rf ~/.claude\nEOF'
  run python3 "$HOOK_PY" <<< "$(make_bash_payload "$CMD")"
  assert_failure
  [[ "$status" -eq 2 ]]
  assert_output --partial "[CAST]"
}

@test "FIX9 ALLOW: real heredoc body 'rm -rf /' → allows (legit heredoc preserved)" {
  CMD=$'cat <<EOF\nrm -rf /\nEOF'
  run python3 "$HOOK_PY" <<< "$(make_bash_payload "$CMD")"
  assert_success
}

@test "FIX9 ALLOW: real quoted-delim heredoc body 'pkill -9 bash' → allows" {
  CMD=$'cat <<\'EOF\'\npkill -9 bash\nEOF'
  run python3 "$HOOK_PY" <<< "$(make_bash_payload "$CMD")"
  assert_success
}

@test "FIX9 ALLOW: real <<- tab-strip heredoc body 'rm -rf /' → allows" {
  CMD=$'cat <<-EOF\n\trm -rf /\n\tEOF'
  run python3 "$HOOK_PY" <<< "$(make_bash_payload "$CMD")"
  assert_success
}

@test "FIX9 BLOCK: real heredoc then real rm -rf ~/.claude after terminator → blocks" {
  CMD=$'cat <<EOF\nhello\nEOF\nrm -rf ~/.claude'
  run python3 "$HOOK_PY" <<< "$(make_bash_payload "$CMD")"
  assert_failure
  [[ "$status" -eq 2 ]]
  assert_output --partial "[CAST]"
}

# ===========================================================================
# FIX 10 — attached redirect glued to a target token is split off before the
#   protected-path check (`~/.claude>x` → target `~/.claude`); spaced/standalone
#   redirect handling (FIX7) is preserved.
# ===========================================================================

@test "FIX10 BLOCK: rm -rf ~/.claude>x → blocks (attached redirect split off target)" {
  run python3 "$HOOK_PY" <<< "$(make_bash_payload 'rm -rf ~/.claude>x')"
  assert_failure
  [[ "$status" -eq 2 ]]
  assert_output --partial "[CAST]"
}

@test "FIX10 BLOCK: rm -rf \$HOME>x (resolved temp home) → blocks (attached redirect split off)" {
  run python3 "$HOOK_PY" <<< "$(make_bash_payload "rm -rf $HOME>x")"
  assert_failure
  [[ "$status" -eq 2 ]]
  assert_output --partial "[CAST]"
}

@test "FIX10 BLOCK: rm -rf ~/.claude > x.log → blocks (rm target before spaced redirect)" {
  run python3 "$HOOK_PY" <<< "$(make_bash_payload 'rm -rf ~/.claude > x.log')"
  assert_failure
  [[ "$status" -eq 2 ]]
  assert_output --partial "[CAST]"
}

@test "FIX10 ALLOW: rm -rf ./build > \$HOME/.claude/build.log 2>&1 → allows (protected path is redirect target)" {
  run python3 "$HOOK_PY" <<< "$(make_bash_payload "rm -rf ./build > $HOME/.claude/build.log 2>&1")"
  assert_success
}

@test "FIX10 ALLOW: rm -rf ./build>out.txt → allows (non-protected target, attached redirect)" {
  run python3 "$HOOK_PY" <<< "$(make_bash_payload 'rm -rf ./build>out.txt')"
  assert_success
}

# ===========================================================================
# RULE 4 — workflow-write via Bash redirection (evades workflows-require-devops).
#   Output redirects (>, >>, | tee) targeting .github/workflows/ are BLOCKED;
#   plain reads and redirects to non-workflow paths are ALLOWED. Probed on the
#   real default path (no env overrides) so the block bites where it matters.
# ===========================================================================

@test "RULE4 BLOCK: echo x > .github/workflows/ci.yml → blocks (spaced redirect, repo-relative)" {
  run python3 "$HOOK_PY" <<< "$(make_bash_payload 'echo x > .github/workflows/ci.yml')"
  assert_failure
  [[ "$status" -eq 2 ]]
  assert_output --partial "[CAST]"
  assert_output --partial ".github/workflows/"
}

@test "RULE4 BLOCK: printf ... >> .github/workflows/deploy.yml → blocks (append redirect)" {
  run python3 "$HOOK_PY" <<< "$(make_bash_payload 'printf "on: push" >> .github/workflows/deploy.yml')"
  assert_failure
  [[ "$status" -eq 2 ]]
  assert_output --partial "[CAST]"
}

@test "RULE4 BLOCK: cat src > /repo/.github/workflows/x.yml → blocks (absolute path)" {
  run python3 "$HOOK_PY" <<< "$(make_bash_payload 'cat src > /repo/.github/workflows/x.yml')"
  assert_failure
  [[ "$status" -eq 2 ]]
  assert_output --partial "[CAST]"
}

@test "RULE4 BLOCK: echo x > \$PWD/.github/workflows/ci.yml → blocks (PWD-composed path)" {
  run python3 "$HOOK_PY" <<< "$(make_bash_payload 'echo x > $PWD/.github/workflows/ci.yml')"
  assert_failure
  [[ "$status" -eq 2 ]]
  assert_output --partial "[CAST]"
}

@test "RULE4 BLOCK: echo x >.github/workflows/ci.yml → blocks (attached redirect, no space)" {
  run python3 "$HOOK_PY" <<< "$(make_bash_payload 'echo x >.github/workflows/ci.yml')"
  assert_failure
  [[ "$status" -eq 2 ]]
  assert_output --partial "[CAST]"
}

@test "RULE4 BLOCK: cmd | tee .github/workflows/ci.yml → blocks (tee sink)" {
  run python3 "$HOOK_PY" <<< "$(make_bash_payload 'echo x | tee .github/workflows/ci.yml')"
  assert_failure
  [[ "$status" -eq 2 ]]
  assert_output --partial "[CAST]"
}

@test "RULE4 BLOCK: cmd | tee -a .github/workflows/ci.yml → blocks (tee append, flag skipped)" {
  run python3 "$HOOK_PY" <<< "$(make_bash_payload 'echo x | tee -a .github/workflows/ci.yml')"
  assert_failure
  [[ "$status" -eq 2 ]]
  assert_output --partial "[CAST]"
}

@test "RULE4 BLOCK: heredoc-fed cat > .github/workflows/x.yml → blocks (intro line scanned)" {
  CMD=$'cat > .github/workflows/x.yml <<EOF\non: push\nEOF'
  run python3 "$HOOK_PY" <<< "$(make_bash_payload "$CMD")"
  assert_failure
  [[ "$status" -eq 2 ]]
  assert_output --partial "[CAST]"
}

@test "RULE4 ALLOW: cat .github/workflows/ci.yml → allows (plain read, no redirect)" {
  run python3 "$HOOK_PY" <<< "$(make_bash_payload 'cat .github/workflows/ci.yml')"
  assert_success
}

@test "RULE4 ALLOW: grep -n jobs .github/workflows/ci.yml → allows (plain read)" {
  run python3 "$HOOK_PY" <<< "$(make_bash_payload 'grep -n jobs .github/workflows/ci.yml')"
  assert_success
}

@test "RULE4 ALLOW: cat .github/workflows/ci.yml > /tmp/out.yml → allows (read workflow, write /tmp)" {
  run python3 "$HOOK_PY" <<< "$(make_bash_payload 'cat .github/workflows/ci.yml > /tmp/out.yml')"
  assert_success
}

@test "RULE4 ALLOW: echo x > /tmp/notes.txt → allows (redirect to non-workflow path)" {
  run python3 "$HOOK_PY" <<< "$(make_bash_payload 'echo x > /tmp/notes.txt')"
  assert_success
}

@test "RULE4 ALLOW: echo x > docs/workflows/guide.md → allows (not .github/workflows/)" {
  run python3 "$HOOK_PY" <<< "$(make_bash_payload 'echo x > docs/workflows/guide.md')"
  assert_success
}

@test "RULE4 BLOCK: cd .github/workflows && echo x > ci.yml → blocks (cd-evasion: redirect target lacks marker)" {
  run python3 "$HOOK_PY" <<< "$(make_bash_payload 'cd .github/workflows && echo x > ci.yml')"
  assert_failure
  [[ "$status" -eq 2 ]]
  assert_output --partial "[CAST]"
}

@test "RULE4 ALLOW: cd .github/workflows && cat ci.yml → allows (cd-evasion path, but no output redirect)" {
  run python3 "$HOOK_PY" <<< "$(make_bash_payload 'cd .github/workflows && cat ci.yml')"
  assert_success
}

@test "RULE4 ALLOW: cd docs && echo x > notes.md → allows (cd to non-workflow dir)" {
  run python3 "$HOOK_PY" <<< "$(make_bash_payload 'cd docs && echo x > notes.md')"
  assert_success
}

#!/usr/bin/env bats
# cast-githooks-policy.bats -- the `githooks-require-security` policy in config/policies.json.
#
# `.githooks/` is this repo's core.hooksPath: hooks run UNSANDBOXED on the next commit/push,
# so an agent-written hook is code execution. The native ask rule Edit(**/.githooks/**) did
# not prompt in auto mode (probed 2026-10-05) and Write(path) rules are inert, so the
# mode-independent gate is this CAST policy (git-guard PreToolUse, exit 2) requiring a
# `security` agent completion this session.
#
# End-to-end through pre-tool-guard.sh's real Write/Edit path against the repo's actual
# config/policies.json, installed into an isolated temp HOME (the guard reads ONLY the
# installed copy). Never touches the real $HOME.

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

  # Install the repo's real policies as the INSTALLED copy under the temp HOME.
  mkdir -p "$HOME/.claude/config"
  cp "$REPO_DIR/config/policies.json" "$HOME/.claude/config/policies.json"
}

teardown() {
  unset CLAUDE_DIR
  teardown_temp_home
}

# Helper: write a status file with a fresh mtime (age 0 = "completed this session").
create_status_file() {
  local name="$1"
  local content="$2"
  echo "$content" > "$CLAUDE_DIR/agent-status/$name"
}

# Helper: Write tool payload. The path travels via the environment, never interpolated
# into the python source.
make_write_payload() {
  GH_PATH="$1" python3 -I -c "
import json, os
print(json.dumps({
  'tool_name': 'Write',
  'tool_input': {'file_path': os.environ['GH_PATH'], 'content': 'echo hi'}
}))
"
}

# Helper: Edit tool payload.
make_edit_payload() {
  GH_PATH="$1" python3 -I -c "
import json, os
print(json.dumps({
  'tool_name': 'Edit',
  'tool_input': {'file_path': os.environ['GH_PATH'], 'old_string': 'a', 'new_string': 'b'}
}))
"
}

@test "Write to an absolute .githooks/ path with NO completion record -> blocks (exit 2) naming the policy" {
  run bash "$HOOK_SH" <<< "$(make_write_payload "/home/someone/Projects/x/.githooks/pre-commit")"
  assert_failure 2
  assert_output --partial "githooks-require-security"
}

@test "Edit to an absolute .githooks/ path with NO completion record -> blocks (exit 2) naming the policy" {
  run bash "$HOOK_SH" <<< "$(make_edit_payload "/home/someone/Projects/x/.githooks/pre-commit")"
  assert_failure 2
  assert_output --partial "githooks-require-security"
}

@test "Write to a RELATIVE .githooks/pre-push path -> blocks (exit 2) naming the policy" {
  run bash "$HOOK_SH" <<< "$(make_write_payload ".githooks/pre-push")"
  assert_failure 2
  assert_output --partial "githooks-require-security"
}

@test "Write to a case-variant /r/.GitHooks/pre-commit -> blocks (exit 2): the match is case-insensitive" {
  run bash "$HOOK_SH" <<< "$(make_write_payload "/r/.GitHooks/pre-commit")"
  assert_failure 2
  assert_output --partial "githooks-require-security"
}

@test "Write to .githooks/ with a plain security-<ts>.json DONE record -> allows (exit 0)" {
  create_status_file "security-1000.json" '{"status":"DONE"}'
  run bash "$HOOK_SH" <<< "$(make_write_payload "/home/someone/Projects/x/.githooks/pre-commit")"
  assert_success
}

@test "Write to .githooks/ with a security__githooks-<ts>.json DONE record (dunder dispatch naming) -> allows (exit 0)" {
  create_status_file "security__githooks-1000.json" '{"status":"DONE"}'
  run bash "$HOOK_SH" <<< "$(make_write_payload "/home/someone/Projects/x/.githooks/pre-commit")"
  assert_success
}

@test "Write to .githooks/ with a BLOCKED security record -> still blocks (exit 2): only DONE unblocks" {
  create_status_file "security-1000.json" '{"status":"BLOCKED"}'
  run bash "$HOOK_SH" <<< "$(make_write_payload "/home/someone/Projects/x/.githooks/pre-commit")"
  assert_failure 2
  assert_output --partial "githooks-require-security"
}

@test "no false positive: /r/docs/githooks.md is allowed (exit 0)" {
  run bash "$HOOK_SH" <<< "$(make_write_payload "/r/docs/githooks.md")"
  assert_success
}

@test "no false positive: /r/my.githooks/x is allowed (exit 0): the dir must be exactly .githooks" {
  run bash "$HOOK_SH" <<< "$(make_write_payload "/r/my.githooks/x")"
  assert_success
}

# ---------------------------------------------------------------------------
# git-internals-require-security (security HIGH-3, 2026-10-05). The Write/Edit policy
# engine did not gate `.git/config` or `.git/hooks/`; an Edit that sets core.hooksPath,
# core.fsmonitor or alias.x='!...' runs unsandboxed on the user's next git command.
# Agents never have a legitimate reason to write git internals with the file tools.
# The pattern is `(^|/)\.git/` (matched case-insensitively), i.e. a path COMPONENT named
# exactly `.git` followed by a slash.
# ---------------------------------------------------------------------------

@test "Write to /r/.git/config with NO completion record -> blocks (exit 2) naming git-internals-require-security" {
  run bash "$HOOK_SH" <<< "$(make_write_payload "/r/.git/config")"
  assert_failure 2
  assert_output --partial "git-internals-require-security"
}

@test "Edit to /r/.git/hooks/pre-commit with NO completion record -> blocks (exit 2) naming git-internals-require-security" {
  run bash "$HOOK_SH" <<< "$(make_edit_payload "/r/.git/hooks/pre-commit")"
  assert_failure 2
  assert_output --partial "git-internals-require-security"
}

@test "Write to a RELATIVE .git/info/attributes path -> blocks (exit 2) naming git-internals-require-security" {
  run bash "$HOOK_SH" <<< "$(make_write_payload ".git/info/attributes")"
  assert_failure 2
  assert_output --partial "git-internals-require-security"
}

@test "Write to a case-variant /r/.GIT/config -> blocks (exit 2): the match is case-insensitive" {
  run bash "$HOOK_SH" <<< "$(make_write_payload "/r/.GIT/config")"
  assert_failure 2
  assert_output --partial "git-internals-require-security"
}

@test "Write to /r/.git/config with a security-<ts>.json DONE record -> allows (exit 0)" {
  create_status_file "security-1000.json" '{"status":"DONE"}'
  run bash "$HOOK_SH" <<< "$(make_write_payload "/r/.git/config")"
  assert_success
}

@test "Write to /r/.git/config with a BLOCKED security record -> still blocks (exit 2): only DONE unblocks" {
  create_status_file "security-1000.json" '{"status":"BLOCKED"}'
  run bash "$HOOK_SH" <<< "$(make_write_payload "/r/.git/config")"
  assert_failure 2
  assert_output --partial "git-internals-require-security"
}

@test "no false positive: /r/.gitignore does not match git-internals (allowed, exit 0)" {
  run bash "$HOOK_SH" <<< "$(make_write_payload "/r/.gitignore")"
  assert_success
  refute_output --partial "git-internals"
}

@test "no false positive: /r/.gitattributes does not match git-internals (allowed, exit 0)" {
  run bash "$HOOK_SH" <<< "$(make_write_payload "/r/.gitattributes")"
  assert_success
  refute_output --partial "git-internals"
}

@test "no false positive: /r/my.git/x does not match git-internals (allowed, exit 0): the component must be exactly .git" {
  run bash "$HOOK_SH" <<< "$(make_write_payload "/r/my.git/x")"
  assert_success
  refute_output --partial "git-internals"
}

@test "no false positive: /r/.github/workflows/x.yml is blocked ONLY by workflows-require-devops, not git-internals" {
  run bash "$HOOK_SH" <<< "$(make_write_payload "/r/.github/workflows/x.yml")"
  assert_failure 2
  assert_output --partial "workflows-require-devops"
  refute_output --partial "git-internals"
}

@test "a gitfile .git FILE (/r/wt/.git, no trailing slash) is blocked naming git-internals-require-security" {
  # In a linked worktree or submodule `.git` is a regular FILE holding `gitdir: <path>`.
  # A gitfile pointing at an attacker dir whose config sets core.fsmonitor execs on the
  # next plain `git status`, so the pattern `(^|/)\.git(/|$)` must match it (no slash).
  run bash "$HOOK_SH" <<< "$(make_write_payload "/r/wt/.git")"
  assert_failure 2
  assert_output --partial "git-internals-require-security"
}

@test "a submodule gitfile /r/tests/test_helper/bats-support/.git -> blocks (exit 2) naming git-internals-require-security" {
  run bash "$HOOK_SH" <<< "$(make_write_payload "/r/tests/test_helper/bats-support/.git")"
  assert_failure 2
  assert_output --partial "git-internals-require-security"
}

@test "no false positive: /r/.gitkeep does not match git-internals (allowed, exit 0)" {
  run bash "$HOOK_SH" <<< "$(make_write_payload "/r/.gitkeep")"
  assert_success
  refute_output --partial "git-internals"
}

@test "no false positive: /r/.git-blame-ignore-revs does not match git-internals (allowed, exit 0): (/|$) must not match a real file name" {
  run bash "$HOOK_SH" <<< "$(make_write_payload "/r/.git-blame-ignore-revs")"
  assert_success
  refute_output --partial "git-internals"
}

# ---------------------------------------------------------------------------
# git-global-config-require-security: ~/.gitconfig and ~/.config/git/ can define
# fsmonitor/hooksPath/filters that run unsandboxed for every repo.
# ---------------------------------------------------------------------------

@test "Write to /home/u/.gitconfig -> blocks (exit 2) naming git-global-config-require-security" {
  run bash "$HOOK_SH" <<< "$(make_write_payload "/home/u/.gitconfig")"
  assert_failure 2
  assert_output --partial "git-global-config-require-security"
}

@test "Write to /home/u/.config/git/config -> blocks (exit 2) naming git-global-config-require-security" {
  run bash "$HOOK_SH" <<< "$(make_write_payload "/home/u/.config/git/config")"
  assert_failure 2
  assert_output --partial "git-global-config-require-security"
}

@test "Write to /home/u/.gitconfig with a security DONE record -> allows (exit 0)" {
  create_status_file "security-1000.json" '{"status":"DONE"}'
  run bash "$HOOK_SH" <<< "$(make_write_payload "/home/u/.gitconfig")"
  assert_success
}

@test "no false positive: /r/docs/gitconfig.md does not match git-global-config (allowed, exit 0)" {
  run bash "$HOOK_SH" <<< "$(make_write_payload "/r/docs/gitconfig.md")"
  assert_success
  refute_output --partial "git-global-config"
}

@test "no false positive: /r/.gitconfig.example does not match git-global-config (allowed, exit 0): the pattern is end-anchored" {
  run bash "$HOOK_SH" <<< "$(make_write_payload "/r/.gitconfig.example")"
  assert_success
  refute_output --partial "git-global-config"
}

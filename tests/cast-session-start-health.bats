#!/usr/bin/env bats
# tests/cast-session-start-health.bats
# Tests for cast-session-start-health.sh

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

SCRIPT="${BATS_TEST_DIRNAME}/../scripts/cast-session-start-health.sh"

# ── Helpers ───────────────────────────────────────────────────────────────────

setup() {
  # Isolate every test in its own temp HOME so memory globs and logs never
  # touch the live ~/.claude tree (see HARD RULE in tests.md / setup.bash).
  load 'helpers/setup'
  setup_temp_home
  mkdir -p "${HOME}/.claude/projects/test-project/memory"
  mkdir -p "${HOME}/.claude/logs"

  # Build a stub launchctl that returns "all clear" by default.
  # Individual tests override CAST_HEALTH_LAUNCHCTL_CMD as needed.
  export STUB_DIR
  STUB_DIR="$(mktemp -d)"

  cat > "${STUB_DIR}/launchctl-ok.sh" <<'EOF'
#!/bin/bash
# all com.cast.* jobs with status 0
echo "-	0	com.cast.backup"
echo "-	0	com.cast.cron-health"
EOF
  chmod +x "${STUB_DIR}/launchctl-ok.sh"

  cat > "${STUB_DIR}/launchctl-failing.sh" <<'EOF'
#!/bin/bash
# one failing job
echo "-	0	com.cast.backup"
echo "-	127	com.cast.cron-meeting-postnotes"
echo "1665	0	com.cast.example-daemon"
EOF
  chmod +x "${STUB_DIR}/launchctl-failing.sh"

  export CAST_HEALTH_LAUNCHCTL_CMD="${STUB_DIR}/launchctl-ok.sh"
}

teardown() {
  rm -rf "${STUB_DIR}"
  teardown_temp_home
}

# Write a minimal memory file with YAML frontmatter
_write_memory() {
  local name="$1"
  local verified_at="$2"
  local body="$3"
  local file="${HOME}/.claude/projects/test-project/memory/${name}.md"
  printf -- '---\nname: %s\nverified_at: %s\n---\n%s\n' "$name" "$verified_at" "$body" > "$file"
}

# Return a date N days ago in YYYY-MM-DD format (portable: python3)
_days_ago() {
  python3 -c "from datetime import date, timedelta; print((date.today() - timedelta(days=$1)).isoformat())"
}

# Return today's date in YYYY-MM-DD format
_today() {
  python3 -c "from datetime import date; print(date.today().isoformat())"
}

# ── Core contract tests ───────────────────────────────────────────────────────

@test "all-clear: no stale memories + all-zero launchd jobs → NO output, exit 0" {
  # No memory files seeded → stale_count=0
  # launchctl stub returns 0 for all jobs
  run bash "$SCRIPT" <<< '{}'
  assert_success
  assert_output ""
}

@test "stale memory with concrete path in body → banner fires and mentions it" {
  local stale_date
  stale_date="$(_days_ago 90)"
  _write_memory "test-stale-mem" "$stale_date" "Wired at /scripts/foo.sh for hook dispatch."

  run bash "$SCRIPT" <<< '{}'
  assert_success
  # Must produce output (banner fired)
  [ -n "$output" ]
  # Must be valid JSON
  python3 -c "import json,sys; json.loads(sys.stdin.read())" <<< "$output"
  # systemMessage must mention health
  python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
assert 'systemMessage' in d, 'systemMessage missing'
msg = d['systemMessage']
assert 'stale' in msg, f'Expected stale in: {msg}'
" <<< "$output"
}

@test "stale memory body contains the memory name in additionalContext" {
  local stale_date
  stale_date="$(_days_ago 60)"
  _write_memory "my-test-memory" "$stale_date" "Lives at ~/.claude/scripts/cast-foo.sh"

  run bash "$SCRIPT" <<< '{}'
  assert_success
  python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
ctx = d.get('hookSpecificOutput', {}).get('additionalContext', '')
assert 'my-test-memory' in ctx, f'Memory name missing from context: {ctx}'
" <<< "$output"
}

@test "fresh memory (verified_at today) is NOT counted as stale" {
  local fresh_date
  fresh_date="$(_today)"
  _write_memory "fresh-mem" "$fresh_date" "Wired at /scripts/foo.sh"

  # Also ensure launchctl stub returns all clear
  run bash "$SCRIPT" <<< '{}'
  assert_success
  assert_output ""
}

@test "stale memory with NO path/fn/flag in body is NOT counted" {
  local stale_date
  stale_date="$(_days_ago 90)"
  # Body has no concrete references (no paths, no foo(), no --flag)
  _write_memory "stale-no-concrete" "$stale_date" "This memory just says some general things about the project."

  run bash "$SCRIPT" <<< '{}'
  assert_success
  assert_output ""
}

@test "memory with no verified_at frontmatter is skipped (no error)" {
  # Write a memory without verified_at
  local file="${HOME}/.claude/projects/test-project/memory/no-date.md"
  printf -- '---\nname: no-date\n---\nReferences /scripts/cast-foo.sh\n' > "$file"

  run bash "$SCRIPT" <<< '{}'
  assert_success
  # Should not crash; with no stale memory flagged and all-zero launchd, output is empty
  assert_output ""
}

@test "failing launchd job → banner fires, mentions the job name" {
  export CAST_HEALTH_LAUNCHCTL_CMD="${STUB_DIR}/launchctl-failing.sh"

  run bash "$SCRIPT" <<< '{}'
  assert_success
  [ -n "$output" ]
  python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
msg = d.get('systemMessage', '')
ctx = d.get('hookSpecificOutput', {}).get('additionalContext', '')
assert 'launchd' in msg, f'Expected launchd in systemMessage: {msg}'
assert 'cron-meeting-postnotes' in ctx, f'Job name missing from context: {ctx}'
assert '127' in ctx, f'Exit status missing from context: {ctx}'
" <<< "$output"
}

@test "currently-running job with stale non-zero exit status is NOT flagged" {
  # A job that IS running (real pid) but carries a stale non-zero
  # last-exit-status from a prior restart (e.g. SIGTERM on sleep/wake)
  # must never appear in the failing-jobs output.
  cat > "${STUB_DIR}/launchctl-running-stale-exit.sh" <<'EOF'
#!/bin/bash
echo "-	0	com.cast.backup"
echo "63445	-15	com.cast.otel-collector"
EOF
  chmod +x "${STUB_DIR}/launchctl-running-stale-exit.sh"
  export CAST_HEALTH_LAUNCHCTL_CMD="${STUB_DIR}/launchctl-running-stale-exit.sh"

  run bash "$SCRIPT" <<< '{}'
  assert_success
  assert_output ""
}

@test "all-zero launchd stub + no stale memories → NO output" {
  export CAST_HEALTH_LAUNCHCTL_CMD="${STUB_DIR}/launchctl-ok.sh"

  run bash "$SCRIPT" <<< '{}'
  assert_success
  assert_output ""
}

@test "emitted stdout is valid JSON with a systemMessage key" {
  # Trigger output via failing job
  export CAST_HEALTH_LAUNCHCTL_CMD="${STUB_DIR}/launchctl-failing.sh"

  run bash "$SCRIPT" <<< '{}'
  assert_success
  python3 -c "
import json, sys
text = sys.stdin.read().strip()
assert text, 'Expected non-empty output'
d = json.loads(text)
assert 'systemMessage' in d, 'systemMessage key missing'
assert 'hookSpecificOutput' in d, 'hookSpecificOutput key missing'
assert d['hookSpecificOutput']['hookEventName'] == 'SessionStart', 'Wrong hookEventName'
" <<< "$output"
}

@test "hook always exits 0 (never blocks a session)" {
  # Even with a stub that produces garbage output, hook must exit 0
  cat > "${STUB_DIR}/launchctl-bad.sh" <<'EOF'
#!/bin/bash
echo "not valid launchctl output!!!"
exit 1
EOF
  chmod +x "${STUB_DIR}/launchctl-bad.sh"
  export CAST_HEALTH_LAUNCHCTL_CMD="${STUB_DIR}/launchctl-bad.sh"

  run bash "$SCRIPT" <<< '{}'
  assert_success
}

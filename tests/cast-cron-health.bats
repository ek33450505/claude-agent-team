#!/usr/bin/env bats
# Tests for scripts/cast-cron-health.sh
#
# Coverage:
#   - Healthy run: exit 0, log written, no alert (regression: a healthy run used
#     to abort under `set -e` because the two check functions ended in `[[ ]] && echo`)
#   - Failure-marker scan of cron-*.log (markers, 7-day window, name filter)
#   - Crontab drift (missing tags, untagged entries, missing SHELL/PATH header)
#   - Alert log written only when something triggers
#   - Subprocess guard
#
# Isolation: temp HOME via tests/helpers/setup.bash (sentinel-guarded), and a
# PATH-shimmed `crontab` whose `-l` output each test controls via $CRONTAB_FIXTURE.
# The script calls no notification/GUI surface, so crontab is the only shim.

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'
load 'helpers/setup'

REPO="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="${REPO}/scripts/cast-cron-health.sh"

setup() {
  setup_temp_home
  mkdir -p "$HOME/.claude/logs" "$HOME/.claude/config"

  # An ambient CLAUDE_SUBPROCESS=1 would make the script exit at its guard and
  # turn every test below into a no-op / false failure.
  unset CLAUDE_SUBPROCESS

  # PATH-shim `crontab`: only `-l` is supported, and it prints $CRONTAB_FIXTURE.
  # With no fixture file it mimics a user who has no crontab (stderr + exit 1).
  # Any other invocation (-e, -r, a file arg) is refused so a test can never
  # write to the real crontab.
  mkdir -p "$HOME/.shim-bin"
  cat > "$HOME/.shim-bin/crontab" <<'SHIM'
#!/bin/bash
if [[ "${1:-}" == "-l" ]]; then
  if [[ -f "${CRONTAB_FIXTURE:-}" ]]; then
    cat "$CRONTAB_FIXTURE"
    exit 0
  fi
  echo "no crontab for ${USER:-user}" >&2
  exit 1
fi
echo "crontab shim: refusing unsupported invocation: $*" >&2
exit 64
SHIM
  chmod +x "$HOME/.shim-bin/crontab"
  export CRONTAB_FIXTURE="$HOME/.crontab-fixture"
  export PATH="$HOME/.shim-bin:$PATH"

  HEALTH_LOG="$HOME/.claude/logs/cron-health.log"
  ALERTS_LOG="$HOME/.claude/logs/cron-health-alerts.log"
}

teardown() {
  teardown_temp_home
}

# ── Fixtures / helpers ────────────────────────────────────────────────────────

# Crontab with the SHELL/PATH header and all 8 expected CAST-MANAGED tags.
_write_healthy_crontab() {
  cat > "$CRONTAB_FIXTURE" <<'CRON'
SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin
0 8 * * * bash ~/.claude/scripts/cast-morning.sh # CAST-MANAGED:morning
0 18 * * * bash ~/.claude/scripts/cast-summary.sh # CAST-MANAGED:summary
0 3 * * * bash ~/.claude/scripts/cast-tidy.sh # CAST-MANAGED:tidy
5 3 * * * bash ~/.claude/scripts/cast-db-prune.sh # CAST-MANAGED:db-prune
10 3 * * * bash ~/.claude/scripts/cast-log-compress.sh # CAST-MANAGED:log-compress
15 3 * * * bash ~/.claude/scripts/cast-pa-backup.sh # CAST-MANAGED:pa-backup
20 3 * * * bash ~/.claude/scripts/cast-maintenance.sh # CAST-MANAGED:cast-maintenance
30 * * * * bash ~/.claude/scripts/cast-cron-health.sh # CAST-MANAGED:cron-health
CRON
}

# Assertion helpers (plain functions: a non-zero return fails the test, and the
# message lands in the bats failure output).
_log_has() {
  grep -qF -- "$1" "$HEALTH_LOG" || {
    echo "expected in cron-health.log: $1" >&2
    cat "$HEALTH_LOG" >&2
    return 1
  }
}

_log_lacks() {
  if grep -qF -- "$1" "$HEALTH_LOG"; then
    echo "unexpected in cron-health.log: $1" >&2
    cat "$HEALTH_LOG" >&2
    return 1
  fi
}

# ── Healthy path ──────────────────────────────────────────────────────────────

@test "cron-health: healthy run exits 0 with no output" {
  _write_healthy_crontab

  run bash "$SCRIPT"

  assert_success
  assert_output ""
}

@test "cron-health: healthy run logs all-clear lines" {
  _write_healthy_crontab

  run bash "$SCRIPT"
  assert_success

  [[ -s "$HEALTH_LOG" ]]
  _log_has "CRON HEALTH CHECK"
  _log_has "No recent failure markers in cron logs."
  _log_has "Crontab entries match expected CAST-MANAGED set."
  _log_has "Crontab PATH header: OK"
  _log_lacks "FAILURES DETECTED"
  _log_lacks "DRIFT DETECTED"
  _log_lacks "WARNING"
}

@test "cron-health: healthy run writes no alert log" {
  _write_healthy_crontab

  run bash "$SCRIPT"
  assert_success

  [[ -f "$HEALTH_LOG" ]]
  [[ ! -e "$ALERTS_LOG" ]]
}

@test "cron-health: header line carries a full timestamp" {
  _write_healthy_crontab

  run bash "$SCRIPT"
  assert_success

  grep -qE 'CRON HEALTH CHECK .+ [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$' "$HEALTH_LOG"
}

@test "cron-health: creates logs directory if missing" {
  _write_healthy_crontab
  # Destructive op: only ever against the sentinel-marked temp HOME.
  [[ -f "$HOME/.cast-test-home" ]]
  rm -rf "$HOME/.claude/logs"
  [[ ! -d "$HOME/.claude/logs" ]]

  run bash "$SCRIPT"
  assert_success

  [[ -d "$HOME/.claude/logs" ]]
  _log_has "No recent failure markers in cron logs."
}

@test "cron-health: appends one report per run" {
  _write_healthy_crontab

  run bash "$SCRIPT"
  assert_success
  run bash "$SCRIPT"
  assert_success

  run grep -c "CRON HEALTH CHECK" "$HEALTH_LOG"
  assert_output "2"
  # The script's own cron-health*.log files match `cron-*.log`; a healthy run
  # must not trip over its own previous output.
  run grep -c "No recent failure markers in cron logs." "$HEALTH_LOG"
  assert_output "2"
  [[ ! -e "$ALERTS_LOG" ]]
}

# ── Subprocess guard ──────────────────────────────────────────────────────────

@test "cron-health: subprocess guard exits 0 early, writes nothing" {
  _write_healthy_crontab

  run env CLAUDE_SUBPROCESS=1 bash "$SCRIPT"

  assert_success
  assert_output ""
  [[ ! -e "$HEALTH_LOG" ]]
  [[ ! -e "$ALERTS_LOG" ]]
}

# ── Failure-marker scan ───────────────────────────────────────────────────────

@test "cron-health: detects ERROR marker in a cron log" {
  _write_healthy_crontab
  echo "ERROR: boom" > "$HOME/.claude/logs/cron-foo.log"

  run bash "$SCRIPT"
  assert_success

  _log_has "FAILURES DETECTED (last 7 days): 1"
  _log_has "- cron-foo.log contains error markers"
  _log_lacks "No recent failure markers in cron logs."
}

@test "cron-health: failure writes exactly one alert line" {
  _write_healthy_crontab
  echo "Permission denied: /etc/shadow" > "$HOME/.claude/logs/cron-auth.log"

  run bash "$SCRIPT"
  assert_success

  [[ -f "$ALERTS_LOG" ]]
  [[ "$(wc -l < "$ALERTS_LOG" | tr -d ' ')" == "1" ]]
  grep -qE '^\[ALERT\] [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:]{8} .+ Cron health check failed\. See .*/\.claude/logs/cron-health\.log$' "$ALERTS_LOG"
}

@test "cron-health: alerts accumulate across runs" {
  _write_healthy_crontab
  echo "ERROR: boom" > "$HOME/.claude/logs/cron-foo.log"

  run bash "$SCRIPT"
  assert_success
  run bash "$SCRIPT"
  assert_success

  [[ "$(wc -l < "$ALERTS_LOG" | tr -d ' ')" == "2" ]]
}

@test "cron-health: every known error marker is detected, clean logs are not" {
  _write_healthy_crontab
  echo "x: command not found" > "$HOME/.claude/logs/cron-m1.log"
  echo "No such file or directory" > "$HOME/.claude/logs/cron-m2.log"
  echo "Permission denied" > "$HOME/.claude/logs/cron-m3.log"
  echo "fatal error: oops" > "$HOME/.claude/logs/cron-m4.log"
  echo "Error: database failed" > "$HOME/.claude/logs/cron-m5.log"
  echo "ERROR: connection timeout" > "$HOME/.claude/logs/cron-m6.log"
  echo "all good, nothing to see" > "$HOME/.claude/logs/cron-clean.log"

  run bash "$SCRIPT"
  assert_success

  _log_has "FAILURES DETECTED (last 7 days): 6"
  _log_lacks "cron-clean.log"
}

@test "cron-health: ignores cron logs older than 7 days" {
  _write_healthy_crontab
  echo "ERROR: ancient failure" > "$HOME/.claude/logs/cron-old.log"
  touch -t 202001010000 "$HOME/.claude/logs/cron-old.log"

  run bash "$SCRIPT"
  assert_success

  _log_has "No recent failure markers in cron logs."
  _log_lacks "cron-old.log"
  [[ ! -e "$ALERTS_LOG" ]]
}

@test "cron-health: old log is ignored while a fresh one is still counted" {
  _write_healthy_crontab
  echo "ERROR: ancient failure" > "$HOME/.claude/logs/cron-old.log"
  touch -t 202001010000 "$HOME/.claude/logs/cron-old.log"
  echo "ERROR: fresh failure" > "$HOME/.claude/logs/cron-fresh.log"

  run bash "$SCRIPT"
  assert_success

  _log_has "FAILURES DETECTED (last 7 days): 1"
  _log_has "- cron-fresh.log contains error markers"
  _log_lacks "cron-old.log"
}

@test "cron-health: only cron-*.log files are scanned" {
  _write_healthy_crontab
  echo "ERROR: not a cron log" > "$HOME/.claude/logs/other.log"
  echo "ERROR: wrong name order" > "$HOME/.claude/logs/old-cron.log"
  echo "ERROR: wrong extension" > "$HOME/.claude/logs/cron-notes.txt"

  run bash "$SCRIPT"
  assert_success

  _log_has "No recent failure markers in cron logs."
  [[ ! -e "$ALERTS_LOG" ]]
}

# ── Crontab drift ─────────────────────────────────────────────────────────────

@test "cron-health: no crontab at all reports every entry missing" {
  # No $CRONTAB_FIXTURE file: the shim behaves like `crontab -l` for a user
  # with no crontab (exit 1, message on stderr).
  [[ ! -e "$CRONTAB_FIXTURE" ]]

  run bash "$SCRIPT"
  assert_success

  _log_has "DRIFT DETECTED: 8 issue(s)"
  _log_has "- Missing entry: morning"
  _log_has "- Missing entry: cron-health"
  _log_has "WARNING: Crontab missing SHELL/PATH header"
  _log_lacks "Crontab entries match expected CAST-MANAGED set."
  [[ -f "$ALERTS_LOG" ]]
}

@test "cron-health: one missing CAST-MANAGED tag is reported by name" {
  _write_healthy_crontab
  grep -v "CAST-MANAGED:tidy" "$CRONTAB_FIXTURE" > "$CRONTAB_FIXTURE.new"
  mv "$CRONTAB_FIXTURE.new" "$CRONTAB_FIXTURE"

  run bash "$SCRIPT"
  assert_success

  _log_has "DRIFT DETECTED: 1 issue(s)"
  _log_has "- Missing entry: tidy"
  _log_lacks "- Missing entry: morning"
  _log_has "Crontab PATH header: OK"
  [[ -f "$ALERTS_LOG" ]]
}

@test "cron-health: untagged bash ~/.claude/scripts entry is flagged as drift" {
  _write_healthy_crontab
  echo '45 4 * * * bash ~/.claude/scripts/rogue.sh' >> "$CRONTAB_FIXTURE"

  run bash "$SCRIPT"
  assert_success

  _log_has "DRIFT DETECTED: 1 issue(s)"
  _log_has "- Found untagged cron entries (should have # CAST-MANAGED comment)"
  _log_lacks "- Missing entry:"
  [[ -f "$ALERTS_LOG" ]]
}

@test "cron-health: missing SHELL/PATH header alerts without drift" {
  _write_healthy_crontab
  tail -n +2 "$CRONTAB_FIXTURE" > "$CRONTAB_FIXTURE.new"
  mv "$CRONTAB_FIXTURE.new" "$CRONTAB_FIXTURE"
  # Sanity: the fixture really starts with a PATH line now, not SHELL=.
  [[ "$(head -1 "$CRONTAB_FIXTURE")" == PATH=* ]]

  run bash "$SCRIPT"
  assert_success

  _log_has "Crontab entries match expected CAST-MANAGED set."
  _log_has "WARNING: Crontab missing SHELL/PATH header"
  _log_lacks "DRIFT DETECTED"
  [[ -f "$ALERTS_LOG" ]]
}

@test "cron-health: failures and drift in one run both reported, one alert line" {
  echo "Error: database failed" > "$HOME/.claude/logs/cron-db.log"
  # No crontab fixture -> drift + missing header as well.

  run bash "$SCRIPT"
  assert_success

  _log_has "FAILURES DETECTED (last 7 days): 1"
  _log_has "DRIFT DETECTED: 8 issue(s)"
  [[ "$(wc -l < "$ALERTS_LOG" | tr -d ' ')" == "1" ]]
}

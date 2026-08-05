#!/usr/bin/env bats
# Tests for scripts/cast-journal-session-end.sh (Stop hook — journal-vault reminder)
# Black-box subprocess tests: no source-script modifications. Covers the
# CLAUDE_SUBPROCESS guard, the today's-note short-circuit, the cancel-flag/
# session-marker state machine, and the hour>=18 re-prompt threshold.
# `date` is PATH-shimmed (not the source script) so the hour-dependent branch
# is deterministic instead of depending on wall-clock time.
# cast_journal_cancelled_*/cast_journal_session_* markers live under /tmp
# (not $HOME), so teardown removes them explicitly in addition to
# teardown_temp_home.

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_DIR/scripts/cast-journal-session-end.sh"

setup() {
	load 'helpers/setup'
	setup_temp_home # sets HOME to a temp dir; exports ORIG_HOME

	mkdir -p "$HOME/bin"
	cat >"$HOME/bin/date" <<'DATEEOF'
#!/bin/bash
# Stub date: deterministic values for the flags cast-journal-session-end.sh
# calls; delegates everything else to the real system date.
case "$1" in
  +%Y-%m-%d)
    echo "${TEST_STUB_TODAY:-2026-08-04}"
    ;;
  +%Y-%m)
    echo "${TEST_STUB_MONTH:-2026-08}"
    ;;
  +%H)
    echo "${TEST_STUB_HOUR:-12}"
    ;;
  -v-1d)
    if [ "$2" = "+%Y-%m-%d" ]; then
      echo "${TEST_STUB_YESTERDAY:-2026-07-31}"
    else
      /bin/date "$@"
    fi
    ;;
  -d)
    if [ "$2" = "yesterday" ] && [ "$3" = "+%Y-%m-%d" ]; then
      echo "${TEST_STUB_YESTERDAY:-2026-07-31}"
    else
      /bin/date "$@"
    fi
    ;;
  *)
    /bin/date "$@"
    ;;
esac
DATEEOF
	chmod +x "$HOME/bin/date"
	export PATH="$HOME/bin:$PATH"

	export TEST_STUB_TODAY="2026-08-$(printf '%02d' "${BATS_TEST_NUMBER:-1}")"
	export TEST_STUB_MONTH="2026-08"
	export TEST_STUB_YESTERDAY="2026-07-31"
	export TEST_STUB_HOUR="12"
	export CLAUDE_SESSION_ID="cast-test-journal-${BATS_TEST_NUMBER:-0}-$$"

	rm -f "/tmp/cast_journal_session_${CLAUDE_SESSION_ID}" "/tmp/cast_journal_cancelled_${TEST_STUB_TODAY}"
}

teardown() {
	rm -f "/tmp/cast_journal_session_${CLAUDE_SESSION_ID}" "/tmp/cast_journal_cancelled_${TEST_STUB_TODAY}"
	teardown_temp_home
}

# --- Subprocess guard ---

@test "journal-session-end: CLAUDE_SUBPROCESS=1 exits 0 with no output and no side effects" {
	run env CLAUDE_SUBPROCESS=1 bash "$SCRIPT" </dev/null
	assert_success
	[ -z "$output" ]
	[ ! -f "/tmp/cast_journal_session_${CLAUDE_SESSION_ID}" ]
	[ ! -d "$HOME/Documents/Claude" ]
}

# --- Today's note already has content ---

@test "journal-session-end: exits 0 with no block JSON when today's note already has content" {
	local note_dir="$HOME/Documents/Claude/${TEST_STUB_MONTH}"
	mkdir -p "$note_dir"
	echo "# Existing entry" >"${note_dir}/${TEST_STUB_TODAY}.md"

	run bash "$SCRIPT" </dev/null
	assert_success
	[ -z "$output" ]
}

# --- No note, no cancel flag: first prompt of the day ---

@test "journal-session-end: no note and no cancel flag creates the flag and emits block JSON with the note path" {
	run bash "$SCRIPT" </dev/null
	assert_success
	assert_output --partial '"decision": "block"'
	assert_output --partial "${TEST_STUB_MONTH}/${TEST_STUB_TODAY}.md"
	[ -f "/tmp/cast_journal_cancelled_${TEST_STUB_TODAY}" ]
}

# --- Cancel flag + session marker: already prompted this session ---

@test "journal-session-end: cancel flag + session marker present exits 0 without reprompting" {
	touch "/tmp/cast_journal_cancelled_${TEST_STUB_TODAY}"
	touch "/tmp/cast_journal_session_${CLAUDE_SESSION_ID}"

	run bash "$SCRIPT" </dev/null
	assert_success
	[ -z "$output" ]
}

# --- Cancel flag + note now filled in: honor the cancel ---

@test "journal-session-end: cancel flag present and note has content honors the cancel" {
	touch "/tmp/cast_journal_cancelled_${TEST_STUB_TODAY}"
	local note_dir="$HOME/Documents/Claude/${TEST_STUB_MONTH}"
	mkdir -p "$note_dir"
	echo "# filled in" >"${note_dir}/${TEST_STUB_TODAY}.md"

	run bash "$SCRIPT" </dev/null
	assert_success
	[ -z "$output" ]
}

# --- Hour-dependent re-prompt threshold ---

@test "journal-session-end: cancel flag present, no note, hour < 18 honors the cancel" {
	touch "/tmp/cast_journal_cancelled_${TEST_STUB_TODAY}"
	export TEST_STUB_HOUR="09"

	run bash "$SCRIPT" </dev/null
	assert_success
	[ -z "$output" ]
	[ -f "/tmp/cast_journal_cancelled_${TEST_STUB_TODAY}" ]
}

@test "journal-session-end: cancel flag present, no note, hour >= 18 clears the flag and reprompts" {
	touch "/tmp/cast_journal_cancelled_${TEST_STUB_TODAY}"
	export TEST_STUB_HOUR="19"

	run bash "$SCRIPT" </dev/null
	assert_success
	assert_output --partial '"decision": "block"'
	[ -f "/tmp/cast_journal_cancelled_${TEST_STUB_TODAY}" ]
}

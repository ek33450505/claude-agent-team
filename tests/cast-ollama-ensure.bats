#!/usr/bin/env bats
# tests/cast-ollama-ensure.bats — Unit tests for cast-ollama-ensure.sh.
#
# HARD RULES (rules: tests.md, shell.md):
#   - Isolated temp HOME via setup_temp_home/teardown_temp_home.
#   - ALL GUI/network/notification surface shimmed with no-op stubs (R2 rule).
#   - Zero real network calls; zero real GUI side effects.
#
# Cases:
#   (a) Ollama UP → exit 0, `open` NOT called.
#   (b) Ollama DOWN then UP → exit 0, `open` WAS called.
#   (c) Ollama stays DOWN → exit 0, notify path fired.

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_DIR/scripts/cast-ollama-ensure.sh"

setup() {
	load 'helpers/setup'
	setup_temp_home

	mkdir -p "$HOME/.claude/logs"
	mkdir -p "$HOME/.claude/scripts"

	# Install a stub cast-notify.sh so the script's notify call hits our shim
	printf '#!/bin/bash\necho "notify: $*" >> "%s/notify-calls.log"\nexit 0\n' \
		"$HOME" >"$HOME/.claude/scripts/cast-notify.sh"
	chmod +x "$HOME/.claude/scripts/cast-notify.sh"

	# Fake bin directory on PATH — shim all side-effect commands
	FAKE_BIN="${BATS_TEST_TMPDIR}/fake-bin"
	mkdir -p "$FAKE_BIN"
	export PATH="$FAKE_BIN:$PATH"

	# open — shims macOS `open -ga Ollama`
	printf '#!/bin/bash\necho "open: $*" >> "%s/open-calls.log"\nexit 0\n' \
		"$BATS_TEST_TMPDIR" >"$FAKE_BIN/open"
	chmod +x "$FAKE_BIN/open"

	# osascript — safety net (should not be called by ensure script)
	printf '#!/bin/bash\necho "osascript: $*" >> "%s/osascript-calls.log"\nexit 0\n' \
		"$BATS_TEST_TMPDIR" >"$FAKE_BIN/osascript"
	chmod +x "$FAKE_BIN/osascript"

	# notify-send / terminal-notifier — safety net
	for _cmd in notify-send terminal-notifier; do
		printf '#!/bin/bash\necho "%s: $*" >> "%s/gui-calls.log"\nexit 0\n' \
			"$_cmd" "$BATS_TEST_TMPDIR" >"$FAKE_BIN/$_cmd"
		chmod +x "$FAKE_BIN/$_cmd"
	done

	# ollama — best-effort non-Darwin start path; default is a no-op
	printf '#!/bin/bash\necho "ollama: $*" >> "%s/ollama-calls.log"\nexit 0\n' \
		"$BATS_TEST_TMPDIR" >"$FAKE_BIN/ollama"
	chmod +x "$FAKE_BIN/ollama"
}

teardown() {
	teardown_temp_home
}

# ---------------------------------------------------------------------------
# Helper: write a curl stub that returns success or failure
# ---------------------------------------------------------------------------
_install_curl_success() {
	# A curl stub that always returns 0 (Ollama reachable)
	printf '#!/bin/bash\nexit 0\n' >"$FAKE_BIN/curl"
	chmod +x "$FAKE_BIN/curl"
}

_install_curl_fail() {
	# A curl stub that always returns 1 (Ollama down)
	printf '#!/bin/bash\nexit 1\n' >"$FAKE_BIN/curl"
	chmod +x "$FAKE_BIN/curl"
}

_install_curl_fail_then_success() {
	# A curl stub that fails on first call, succeeds on all subsequent calls.
	# Uses a call-count file in BATS_TEST_TMPDIR to track state.
	local count_file="${BATS_TEST_TMPDIR}/curl_call_count"
	printf '0' >"$count_file"
	cat >"$FAKE_BIN/curl" <<STUB
#!/bin/bash
COUNT_FILE="${count_file}"
count=\$(cat "\$COUNT_FILE" 2>/dev/null || echo 0)
count=\$((count + 1))
printf '%d' "\$count" > "\$COUNT_FILE"
if [ "\$count" -le 1 ]; then
  exit 1
fi
exit 0
STUB
	chmod +x "$FAKE_BIN/curl"
}

# ---------------------------------------------------------------------------
# (a) Ollama already UP — exits 0, open NOT called
# ---------------------------------------------------------------------------
@test "(a) Ollama UP: script exits 0 and does not call open" {
	_install_curl_success

	run bash "$SCRIPT"
	assert_success

	# open stub log must not exist (open was never called)
	[ ! -f "${BATS_TEST_TMPDIR}/open-calls.log" ]
}

# ---------------------------------------------------------------------------
# (b) Ollama DOWN then UP — exits 0, open WAS called (macOS path)
# ---------------------------------------------------------------------------
@test "(b) Ollama DOWN then UP: script exits 0 and called open" {
	_install_curl_fail_then_success

	# Force uname to return Darwin so the macOS branch fires
	printf '#!/bin/bash\necho Darwin\n' >"$FAKE_BIN/uname"
	chmod +x "$FAKE_BIN/uname"

	# Speed up the poll loop: set a very short sleep stub
	printf '#!/bin/bash\nexit 0\n' >"$FAKE_BIN/sleep"
	chmod +x "$FAKE_BIN/sleep"

	run bash "$SCRIPT"
	assert_success

	# open stub must have been called
	[ -f "${BATS_TEST_TMPDIR}/open-calls.log" ]
}

# ---------------------------------------------------------------------------
# (c) Ollama stays DOWN — exits 0, notify path fired
# ---------------------------------------------------------------------------
@test "(c) Ollama stays DOWN: exits 0 and fires cast-notify" {
	_install_curl_fail

	# Force uname Darwin so macOS branch fires (open will be called but Ollama stays down)
	printf '#!/bin/bash\necho Darwin\n' >"$FAKE_BIN/uname"
	chmod +x "$FAKE_BIN/uname"

	# Skip real sleeping
	printf '#!/bin/bash\nexit 0\n' >"$FAKE_BIN/sleep"
	chmod +x "$FAKE_BIN/sleep"

	# Point SCRIPT_DIR resolution to home where we installed the cast-notify.sh stub.
	# The script resolves its own SCRIPT_DIR via BASH_SOURCE[0]; we override by copying
	# a cast-notify.sh shim alongside the real script in a temp dir.
	local tmp_scripts="${BATS_TEST_TMPDIR}/scripts"
	mkdir -p "$tmp_scripts"
	cp "$SCRIPT" "$tmp_scripts/cast-ollama-ensure.sh"

	# Install notify stub alongside the script copy
	printf '#!/bin/bash\necho "notify: $*" >> "%s/notify-calls.log"\nexit 0\n' \
		"$BATS_TEST_TMPDIR" >"$tmp_scripts/cast-notify.sh"
	chmod +x "$tmp_scripts/cast-notify.sh"

	run bash "$tmp_scripts/cast-ollama-ensure.sh"
	assert_success

	# cast-notify stub must have been invoked
	[ -f "${BATS_TEST_TMPDIR}/notify-calls.log" ]
	grep -q "ollama_down" "${BATS_TEST_TMPDIR}/notify-calls.log"
}

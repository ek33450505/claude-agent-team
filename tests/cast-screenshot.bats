#!/usr/bin/env bats
# Tests for scripts/cast-screenshot.sh (frontend-qa visual capture).
#
# The script drives `npx playwright screenshot` (falling back to
# `npx puppeteer screenshot`). It never calls screencapture, so the screencapture
# shim is a tripwire: any invocation is recorded and fails the test.
# npx is replaced by a recording stub whose behaviour is set per test via env.

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'
load 'helpers/setup'

SCREENSHOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/scripts/cast-screenshot.sh"

setup() {
  setup_temp_home
  unset CLAUDE_SUBPROCESS

  SHIM_DIR="$BATS_TEST_TMPDIR/shims"
  mkdir -p "$SHIM_DIR"
  GUI_LOG="$BATS_TEST_TMPDIR/gui-calls.log"
  export GUI_LOG
  local _gui
  for _gui in osascript open terminal-notifier screencapture; do
    cat > "$SHIM_DIR/$_gui" <<EOF
#!/bin/bash
printf '%s %s\n' "$_gui" "\$*" >> "\$GUI_LOG"
exit 0
EOF
    chmod +x "$SHIM_DIR/$_gui"
  done

  # npx stub. Logs every call. Env switches:
  #   PW_MISSING=1     playwright --version fails
  #   PPT_OK=1         puppeteer --version succeeds
  #   SHOT_RC=<n>      exit code for the screenshot subcommand (default 0)
  cat > "$SHIM_DIR/npx" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$NPX_LOG"
tool="$1"; sub="$2"
if [[ "$sub" == "--version" ]]; then
  if [[ "$tool" == "playwright" && -n "${PW_MISSING:-}" ]]; then exit 1; fi
  if [[ "$tool" == "puppeteer" && -z "${PPT_OK:-}" ]]; then exit 1; fi
  exit 0
fi
out=""
prev=""
for a in "$@"; do
  if [[ "$prev" == "--path" ]]; then out="$a"; fi
  prev="$a"
done
if [[ "${SHOT_RC:-0}" -ne 0 ]]; then exit "$SHOT_RC"; fi
[[ -n "$out" ]] && printf 'PNG\n' > "$out"
exit 0
EOF
  chmod +x "$SHIM_DIR/npx"

  export PATH="$SHIM_DIR:$PATH"
  export NPX_LOG="$BATS_TEST_TMPDIR/npx-calls.log"
  OUT_DIR="$BATS_TEST_TMPDIR/captures"
}

teardown() {
  teardown_temp_home
}

@test "captures via playwright with the expected viewport and load-state arguments" {
  run bash "$SCREENSHOT" "http://localhost:5173" "$OUT_DIR/home.png"
  assert_success
  assert_output "$OUT_DIR/home.png"
  run cat "$NPX_LOG"
  assert_output --partial "playwright screenshot --url http://localhost:5173 --path $OUT_DIR/home.png --viewport-size 1280 800 --wait-for-load-state networkidle"
  [[ -s "$OUT_DIR/home.png" ]] || fail "screenshot file was not written"
}

@test "logs a successful capture to the temp HOME screenshot log" {
  run bash "$SCREENSHOT" "http://localhost:5173" "$OUT_DIR/home.png"
  assert_success
  run cat "$HOME/.claude/logs/screenshot.log"
  assert_output --partial "[INFO] Screenshot captured: $OUT_DIR/home.png from http://localhost:5173 (tool: playwright)"
}

@test "creates a missing output directory before capturing" {
  run bash "$SCREENSHOT" "http://localhost:5173" "$OUT_DIR/nested/deep/shot.png"
  assert_success
  [[ -d "$OUT_DIR/nested/deep" ]] || fail "output directory was not created"
}

@test "accepts a trailing --wait pair and still runs the default networkidle capture" {
  # The script reserves --wait for future use and ignores its value; this
  # asserts only that the pair is parsed without breaking the default invocation.
  run bash "$SCREENSHOT" "http://localhost:5173" "$OUT_DIR/w.png" --wait 2000
  assert_success
  run cat "$NPX_LOG"
  assert_output --partial "--wait-for-load-state networkidle"
}

@test "falls back to puppeteer with its viewport flags when playwright is missing" {
  PW_MISSING=1 PPT_OK=1 run bash "$SCREENSHOT" "http://localhost:5173" "$OUT_DIR/p.png"
  assert_success
  run cat "$NPX_LOG"
  assert_output --partial "puppeteer screenshot --url http://localhost:5173 --path $OUT_DIR/p.png --viewport-width 1280 --viewport-height 800"
  run cat "$HOME/.claude/logs/screenshot.log"
  assert_output --partial "(tool: puppeteer)"
}

@test "exits 1 with an install hint when neither playwright nor puppeteer is available" {
  PW_MISSING=1 run bash "$SCREENSHOT" "http://localhost:5173" "$OUT_DIR/x.png"
  assert_failure
  assert_output --partial "Neither Playwright nor Puppeteer is installed"
  run cat "$HOME/.claude/logs/screenshot.log"
  assert_output --partial "[ERROR] Neither playwright nor puppeteer found"
}

@test "exits 1 and names the dev server when the playwright capture fails" {
  SHOT_RC=1 run bash "$SCREENSHOT" "http://localhost:5173" "$OUT_DIR/f.png"
  assert_failure
  assert_output --partial "Playwright screenshot failed. Is the dev server running at http://localhost:5173?"
  run cat "$HOME/.claude/logs/screenshot.log"
  assert_output --partial "[ERROR] Playwright screenshot failed for http://localhost:5173"
}

@test "exits 1 with a usage line when no arguments are given" {
  run bash "$SCREENSHOT"
  assert_failure
  assert_output --partial "Usage: cast-screenshot.sh <url> <output-path.png>"
  [[ ! -e "$NPX_LOG" ]] || fail "npx was invoked despite missing arguments"
}

@test "exits 1 with a usage line when the output path is missing" {
  run bash "$SCREENSHOT" "http://localhost:5173"
  assert_failure
  assert_output --partial "Usage:"
}

@test "exits 0 silently and never calls npx when running as a CAST subprocess" {
  CLAUDE_SUBPROCESS=1 run bash "$SCREENSHOT" "http://localhost:5173" "$OUT_DIR/s.png"
  assert_success
  assert_output ""
  [[ ! -e "$NPX_LOG" ]] || fail "npx was invoked under CLAUDE_SUBPROCESS=1"
}

@test "never invokes screencapture or any other GUI surface" {
  run bash "$SCREENSHOT" "http://localhost:5173" "$OUT_DIR/g.png"
  assert_success
  [[ ! -e "$GUI_LOG" ]] || fail "GUI shim was called: $(cat "$GUI_LOG")"
}

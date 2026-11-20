#!/usr/bin/env bats
# try-plugin-isolated.bats — tests for scripts/try-plugin-isolated.sh
#
# The script execs `claude`, so a stub `claude` is put first on PATH. It records
# its argv and HOME and exits 0. The script is copied into a fake repo layout so
# the "plugin dir not found" path never touches the real plugin/ directory.
# Every test runs with an isolated temp HOME.

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT_SRC="$REPO_DIR/scripts/try-plugin-isolated.sh"

setup() {
  load 'helpers/setup'
  setup_temp_home   # isolates HOME (and the credentials copy) to a temp dir

  FAKE_REPO="$BATS_TEST_TMPDIR/fake-repo"
  mkdir -p "$FAKE_REPO/scripts"
  cp "$SCRIPT_SRC" "$FAKE_REPO/scripts/try-plugin-isolated.sh"

  STUB_BIN="$BATS_TEST_TMPDIR/bin"
  STUB_LOG="$BATS_TEST_TMPDIR/claude-calls.log"
  mkdir -p "$STUB_BIN"
  cat > "$STUB_BIN/claude" <<'STUB'
#!/usr/bin/env bash
{
  printf 'HOME=%s\n' "$HOME"
  for arg in "$@"; do printf 'ARG=%s\n' "$arg"; done
} >> "$STUB_LOG"
exit 0
STUB
  chmod +x "$STUB_BIN/claude"

  export STUB_LOG
  export PATH="$STUB_BIN:$PATH"
}

teardown() {
  teardown_temp_home
}

@test "creates the sandbox .claude dir and hands off to claude with the plugin dir" {
  mkdir -p "$FAKE_REPO/plugin"
  local sandbox="$BATS_TEST_TMPDIR/sandbox"

  CAST_PLUGIN_SANDBOX_HOME="$sandbox" run bash "$FAKE_REPO/scripts/try-plugin-isolated.sh" --resume

  assert_success
  assert_output --partial "Sandbox HOME : $sandbox"
  [ -d "$sandbox/.claude" ]
  [ -f "$STUB_LOG" ]
  run cat "$STUB_LOG"
  assert_output --partial "HOME=$sandbox"
  assert_output --partial "ARG=--plugin-dir"
  assert_output --partial "ARG=$FAKE_REPO/plugin"
  assert_output --partial "ARG=--resume"
}

@test "copies file-based credentials into the sandbox when the real ones exist" {
  mkdir -p "$FAKE_REPO/plugin" "$HOME/.claude"
  printf '{"token":"fixture"}\n' > "$HOME/.claude/.credentials.json"
  local sandbox="$BATS_TEST_TMPDIR/sandbox-creds"

  CAST_PLUGIN_SANDBOX_HOME="$sandbox" run bash "$FAKE_REPO/scripts/try-plugin-isolated.sh"

  assert_success
  assert [ -f "$sandbox/.claude/.credentials.json" ]
}

@test "exits 1 with a 'plugin dir not found' error when plugin/ is missing" {
  local sandbox="$BATS_TEST_TMPDIR/sandbox-missing"

  CAST_PLUGIN_SANDBOX_HOME="$sandbox" run bash "$FAKE_REPO/scripts/try-plugin-isolated.sh"

  assert_failure 1
  assert_output --partial "plugin dir not found"
  [ ! -f "$STUB_LOG" ]
  [ ! -d "$sandbox" ]
}

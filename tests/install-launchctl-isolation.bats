#!/usr/bin/env bats

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'
load 'helpers/setup'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() {
  setup_temp_home
}

teardown() {
  teardown_temp_home
}

# =============================================================================
# Launchd Isolation: verify install.sh skips launchctl load under temp HOME
# =============================================================================

@test "Install under temp HOME: .cast-test-home sentinel triggers launchd registration skip" {
  # macOS-only test (launchd is Darwin-specific)
  [[ "$(uname -s)" == "Darwin" ]] || skip "launchd is macOS-only"

  # Verify the sentinel file exists (from setup_temp_home)
  [[ -f "$HOME/.cast-test-home" ]] || {
    echo "SETUP ERROR: .cast-test-home sentinel not created" >&2
    return 1
  }

  # Run the installer with CAST_INSTALL_FORCE=1 (no launchctl-skip override)
  # This proves the .cast-test-home sentinel alone triggers the guard
  run env CAST_INSTALL_FORCE=1 bash "$REPO_DIR/install.sh"
  [[ $status -eq 0 ]] || {
    echo "Install failed with status $status:" >&2
    echo "$output" >&2
    return 1
  }

  # Assertion 1: Installer must emit the skip sentinel
  echo "$output" | grep -q "launchd registration skipped" || {
    echo "FAIL: installer did not emit 'launchd registration skipped'" >&2
    echo "Output was:" >&2
    echo "$output" >&2
    return 1
  }

  # Assertion 2: Plists must be written to temp HOME (proof that install.sh ran fully)
  [[ -f "$HOME/Library/LaunchAgents/com.cast.backup.plist" ]] || {
    echo "FAIL: com.cast.backup.plist not written to temp HOME" >&2
    return 1
  }
  [[ -f "$HOME/Library/LaunchAgents/com.cast.log-compress.plist" ]] || {
    echo "FAIL: com.cast.log-compress.plist not written to temp HOME" >&2
    return 1
  }

  # Assertion 3: NO launchd jobs from this temp HOME are registered in the real domain
  # For each label that install.sh would normally load, verify it either:
  #   (a) is not loaded at all in the gui/$uid domain, OR
  #   (b) if somehow loaded, does NOT point to the temp HOME
  local uid
  uid="$(id -u)"
  local labels=("com.cast.backup" "com.cast.log-compress" "com.cast.wipe-canary" "com.cast.memory-embed" "com.cast.db-prune")

  for label in "${labels[@]}"; do
    local loaded_path
    loaded_path="$(launchctl print "gui/$uid/$label" 2>/dev/null | awk -F' = ' '/^\tpath = /{print $2; exit}')" || true

    # If the job is loaded, its path must NOT be under the temp HOME
    if [[ -n "$loaded_path" ]]; then
      if [[ "$loaded_path" == "$HOME"/* ]]; then
        echo "LEAK: launchd job $label is registered with path under temp HOME: $loaded_path" >&2
        return 1
      fi
    fi
  done

  # All assertions passed
  true
}

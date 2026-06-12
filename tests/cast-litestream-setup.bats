#!/usr/bin/env bats
# tests/cast-litestream-setup.bats — Unit tests for cast-litestream-setup.sh and cast-litestream-daemon.sh
#
# Isolation: ALL tests use setup_temp_home/teardown_temp_home — never touch real $HOME.

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'
load 'helpers/setup'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SETUP_SCRIPT="${REPO_DIR}/scripts/cast-litestream-setup.sh"
DAEMON_SCRIPT="${REPO_DIR}/scripts/cast-litestream-daemon.sh"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Create a fake litestream binary in a temp bin dir and prepend to PATH.
_install_fake_litestream() {
  local bindir="$1"
  mkdir -p "$bindir"
  cat > "${bindir}/litestream" <<'EOF'
#!/usr/bin/env bash
# Fake litestream for tests
exit 0
EOF
  chmod +x "${bindir}/litestream"
  export PATH="${bindir}:${PATH}"
}

# Remove litestream from PATH by filtering any dir that contains it.
_remove_litestream_from_path() {
  local new_path=""
  local IFS=":"
  for p in $PATH; do
    if [[ -x "${p}/litestream" ]]; then
      continue
    fi
    new_path="${new_path:+${new_path}:}${p}"
  done
  export PATH="$new_path"
}

# ---------------------------------------------------------------------------
# Setup / teardown
# ---------------------------------------------------------------------------

setup() {
  setup_temp_home
  # Override root to a path within the temp HOME so nothing touches
  # ~/Library/Application Support on the real machine.
  export CAST_LITESTREAM_ROOT="${HOME}/Library/Application Support/cast-test"
  export CAST_DB_PATH="${HOME}/.claude/cast.db"
  # Install a fake litestream binary so setup script sees it as installed
  FAKE_BIN="${HOME}/.cast-test-bin"
  _install_fake_litestream "$FAKE_BIN"
}

teardown() {
  teardown_temp_home
}

# ---------------------------------------------------------------------------
# 1. Setup creates the expected directories
# ---------------------------------------------------------------------------
@test "setup: creates config, replica, and logs directories" {
  run bash "$SETUP_SCRIPT"
  assert_success

  local root="${HOME}/Library/Application Support/cast-test"
  [ -d "${root}/litestream/cast-db" ]
  [ -d "${root}/logs" ]
}

# ---------------------------------------------------------------------------
# 2. Config content matches the verified litestream v0.5 format
# ---------------------------------------------------------------------------
@test "setup: litestream.yml contains correct db path and replica path" {
  run bash "$SETUP_SCRIPT"
  assert_success

  local config="${HOME}/Library/Application Support/cast-test/litestream.yml"
  [ -f "$config" ]

  # Must contain the dbs/path entry
  grep -q "path: ${HOME}/.claude/cast.db" "$config"

  # Must contain the replica type and path
  grep -q "type: file" "$config"
  grep -q "path: ${HOME}/Library/Application Support/cast-test/litestream/cast-db" "$config"
}

# ---------------------------------------------------------------------------
# 3. CAST_DB_PATH override is respected
# ---------------------------------------------------------------------------
@test "setup: CAST_DB_PATH override is written to config" {
  local custom_db="${HOME}/custom/mydb.db"
  CAST_DB_PATH="$custom_db" run bash "$SETUP_SCRIPT"
  assert_success

  local config="${HOME}/Library/Application Support/cast-test/litestream.yml"
  grep -q "path: ${custom_db}" "$config"
}

# ---------------------------------------------------------------------------
# 4. CAST_LITESTREAM_ROOT override is respected
# ---------------------------------------------------------------------------
@test "setup: CAST_LITESTREAM_ROOT override places config in correct location" {
  local custom_root="${HOME}/custom-litestream-root"
  CAST_LITESTREAM_ROOT="$custom_root" run bash "$SETUP_SCRIPT"
  assert_success

  [ -f "${custom_root}/litestream.yml" ]
  [ -d "${custom_root}/litestream/cast-db" ]
  [ -d "${custom_root}/logs" ]
}

# ---------------------------------------------------------------------------
# 5. Idempotency — running setup twice is safe and produces the same config
# ---------------------------------------------------------------------------
@test "setup: second run is idempotent (config unchanged)" {
  run bash "$SETUP_SCRIPT"
  assert_success

  local config="${HOME}/Library/Application Support/cast-test/litestream.yml"
  local checksum_before
  checksum_before="$(md5 -q "$config" 2>/dev/null || md5sum "$config" | awk '{print $1}')"

  run bash "$SETUP_SCRIPT"
  assert_success

  local checksum_after
  checksum_after="$(md5 -q "$config" 2>/dev/null || md5sum "$config" | awk '{print $1}')"

  [ "$checksum_before" = "$checksum_after" ]
}

# ---------------------------------------------------------------------------
# 6. Missing litestream → advisory message, exit 0 (honest degradation)
# ---------------------------------------------------------------------------
@test "setup: missing litestream binary prints advisory and exits 0" {
  # Use a completely controlled PATH that contains only known-safe system dirs,
  # ensuring litestream is not findable (neither from the fake bin nor from brew).
  local safe_path="/usr/bin:/bin:/usr/sbin:/sbin"

  run env PATH="$safe_path" bash "$SETUP_SCRIPT"
  assert_success
  assert_output --partial "ADVISORY"
  assert_output --partial "not installed"
}

# ---------------------------------------------------------------------------
# 7. daemon: missing litestream binary → advisory message + exit 0 (clean exit
#    prevents launchd KeepAlive restart loop on machines without litestream)
# ---------------------------------------------------------------------------
@test "daemon: missing litestream binary exits 0 with advisory message" {
  # Override the PATH prefix the daemon prepends so it resolves to an empty
  # test-owned dir that contains no litestream binary. Combined with a safe
  # system PATH, this guarantees litestream cannot be found.
  local empty_prefix="${BATS_TEST_TMPDIR}/empty-bin"
  mkdir -p "$empty_prefix"
  local safe_path="/usr/bin:/bin:/usr/sbin:/sbin"

  run env \
    PATH="$safe_path" \
    CAST_LITESTREAM_PATH_PREFIX="$empty_prefix" \
    bash "$DAEMON_SCRIPT"
  assert_success
  assert_output --partial "ADVISORY"
  assert_output --partial "not found"
}

# ---------------------------------------------------------------------------
# 8. daemon: binary present but config missing → advisory message + exit 0
#    (clean exit prevents launchd restart loop before setup.sh is run)
# ---------------------------------------------------------------------------
@test "daemon: config missing exits 0 with advisory message" {
  # litestream is available (fake binary in PATH) but config does not exist
  run bash "$DAEMON_SCRIPT"
  assert_success
  assert_output --partial "ADVISORY"
  assert_output --partial "config not found"
}

# ---------------------------------------------------------------------------
# 11. plist KeepAlive uses dict form (SuccessfulExit=false, not bare <true/>)
# ---------------------------------------------------------------------------
@test "plist: KeepAlive uses SuccessfulExit dict form" {
  local plist="${REPO_DIR}/macos/cast-litestream.plist"
  [ -f "$plist" ] || skip "plist source not present in this checkout"
  grep -q "SuccessfulExit" "$plist"
  # Ensure the bare <true/> form for KeepAlive is NOT present (replaced by dict)
  ! grep -q "<key>KeepAlive</key>[[:space:]]*<true/>" "$plist"
}

# ---------------------------------------------------------------------------
# 9. daemon: binary present + config present → exec succeeds (fake binary)
# ---------------------------------------------------------------------------
@test "daemon: valid binary and config → exec litestream replicate" {
  # Write a config first
  run bash "$SETUP_SCRIPT"
  assert_success

  # Replace fake litestream with one that validates it was called with replicate -config.
  # It exits 0 immediately (real litestream replicate runs as a daemon — never use it here).
  local bindir="${BATS_TEST_TMPDIR}/fake-ls-bin"
  mkdir -p "$bindir"
  cat > "${bindir}/litestream" <<'EOF'
#!/usr/bin/env bash
# Fake litestream that validates it received replicate -config <path>
if [[ "$1" == "replicate" && "$2" == "-config" && -n "$3" ]]; then
  exit 0
fi
echo "UNEXPECTED ARGS: $*" >&2
exit 1
EOF
  chmod +x "${bindir}/litestream"

  # Point PATH_PREFIX to our fake bin so the daemon resolves our stub, not brew's real litestream.
  run env \
    CAST_LITESTREAM_PATH_PREFIX="$bindir" \
    CAST_LITESTREAM_ROOT="${CAST_LITESTREAM_ROOT}" \
    bash "$DAEMON_SCRIPT"
  assert_success
}

# ---------------------------------------------------------------------------
# 10. Config file line count sanity check
# ---------------------------------------------------------------------------
@test "setup: config has exactly the expected number of non-empty lines" {
  run bash "$SETUP_SCRIPT"
  assert_success

  local config="${HOME}/Library/Application Support/cast-test/litestream.yml"
  # Expected: dbs:, - path: <db>, replicas:, - type: file, path: <replica>  = 5 non-empty lines
  local count
  count=$(grep -c '[^[:space:]]' "$config" | tr -d ' ')
  [ "$count" -eq 5 ]
}

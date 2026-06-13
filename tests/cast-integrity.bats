#!/usr/bin/env bats
# tests/cast-integrity.bats — cast integrity subcommand
#
# Tests the read-only data-integrity surface (_cmd_integrity):
#   1. pristine temp HOME  → guards-missing WARNs, exit 0, NO [ok] for absent backup
#   2. fixture HOME (guard files + fresh snapshots) → ok rungs appear
#   3. colocated-backup fixture (~/.claude/backups/<ts> fresh) → colocation WARN fires
#   4. canary launchctl checks (loaded+outside-radius → ok; loaded+inside-radius → WARN;
#      not loaded → WARN; launchctl absent → INFO skip)
#
# PR #217 "never-green-on-absent-evidence" rule:
#   no [ok] line may claim a backup is fresh unless a snapshot/backup dir with a
#   fresh file was explicitly created in the fixture.
#
# Isolation: ALL tests use setup_temp_home/teardown_temp_home — never real $HOME.

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
CAST_BIN="${REPO_DIR}/bin/cast"

# ---------------------------------------------------------------------------
# Setup / teardown
# ---------------------------------------------------------------------------

setup() {
  load 'helpers/setup'
  setup_temp_home  # sets HOME to a temp dir; exports ORIG_HOME

  mkdir -p "$HOME/.claude"

  # Redirect backup and litestream roots into the temp HOME so no real
  # system dirs are touched.
  export CAST_BACKUP_ROOT="${HOME}/Library/Application Support/cast/backups"
  export CAST_BACKUP_DIR="${HOME}/Library/Application Support/cast/db-backups"
  export CAST_LITESTREAM_ROOT="${HOME}/Library/Application Support/cast-test"
  export CAST_INCIDENT_DIR="${HOME}/Library/Application Support/cast/incidents"

  # Suppress subprocess guard so cast CLI actually runs.
  export CLAUDE_SUBPROCESS=0

  # Per-test scratch space for fake binaries.
  FAKE_BIN="${BATS_TEST_TMPDIR}/fake-bin"
  mkdir -p "$FAKE_BIN"
}

teardown() {
  teardown_temp_home
}

# ---------------------------------------------------------------------------
# Helper: run cast integrity from a neutral CWD (not the CAST repo), so the
# blast-radius lint check gets INFO-skipped (no scripts/blast-radius-lint.sh
# in BATS_TEST_TMPDIR).
# ---------------------------------------------------------------------------
_run_integrity_neutral() {
  local extra_path="${1:-}"
  local base_path="${extra_path:+${extra_path}:}${PATH}"
  pushd "$BATS_TEST_TMPDIR" > /dev/null
  run env PATH="${base_path}" \
    HOME="$HOME" \
    CLAUDE_SUBPROCESS=0 \
    CAST_BACKUP_ROOT="$CAST_BACKUP_ROOT" \
    CAST_BACKUP_DIR="$CAST_BACKUP_DIR" \
    CAST_LITESTREAM_ROOT="$CAST_LITESTREAM_ROOT" \
    CAST_INCIDENT_DIR="$CAST_INCIDENT_DIR" \
    bash "$CAST_BIN" integrity 2>&1
  popd > /dev/null
}

# ---------------------------------------------------------------------------
# Helper: create fake guard scripts in the temp HOME
# ---------------------------------------------------------------------------
_install_guard_files() {
  local scripts_dir="$HOME/.claude/scripts"
  mkdir -p "$scripts_dir"
  touch "$scripts_dir/cast-guard-lib.sh"
  touch "$scripts_dir/cast_guard.py"
  touch "$scripts_dir/write-guards.sh"
}

# ---------------------------------------------------------------------------
# Helper: create a fresh snapshot dir (mtime = now)
# ---------------------------------------------------------------------------
_create_fresh_snapshot() {
  local snap_dir="${CAST_BACKUP_ROOT}/cast-snapshot-$(date +%Y-%m-%d)"
  mkdir -p "$snap_dir"
  touch "$snap_dir/.cast-snap-manifest"
}

# ---------------------------------------------------------------------------
# Helper: create a fresh db-backup file (mtime = now)
# ---------------------------------------------------------------------------
_create_fresh_db_backup() {
  mkdir -p "$CAST_BACKUP_DIR"
  touch "$CAST_BACKUP_DIR/cast.db.$(date +%Y%m%d%H%M%S)"
}

# ---------------------------------------------------------------------------
# Helper: install fake litestream binary
# ---------------------------------------------------------------------------
_install_fake_litestream() {
  cat > "${FAKE_BIN}/litestream" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "${FAKE_BIN}/litestream"
}

# ---------------------------------------------------------------------------
# Canary helpers — PATH-shim launchctl, plant fixture plists
# ---------------------------------------------------------------------------

# Fake launchctl that reports com.cast.wipe-canary as LOADED (exit 0)
_install_fake_launchctl_canary_loaded() {
  cat > "${FAKE_BIN}/launchctl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "${FAKE_BIN}/launchctl"
}

# Fake launchctl that reports com.cast.wipe-canary as NOT LOADED (exit 1)
_install_fake_launchctl_canary_not_loaded() {
  cat > "${FAKE_BIN}/launchctl" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "${FAKE_BIN}/launchctl"
}

# Write a canary plist whose script path is OUTSIDE the blast radius
# (uses a file in BATS_TEST_TMPDIR, which is never inside HOME/.claude).
_write_canary_plist_outside_blast() {
  local script_path="${BATS_TEST_TMPDIR}/cast-wipe-canary-external.sh"
  touch "$script_path"
  mkdir -p "${HOME}/Library/LaunchAgents"
  cat > "${HOME}/Library/LaunchAgents/com.cast.wipe-canary.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.cast.wipe-canary</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${script_path}</string>
  </array>
  <key>WatchPaths</key>
  <array>
    <string>${HOME}/.claude</string>
  </array>
  <key>RunAtLoad</key>
  <false/>
</dict>
</plist>
EOF
}

# Write a canary plist whose script path is INSIDE ~/.claude (blast radius).
_write_canary_plist_inside_blast() {
  local script_path="${HOME}/.claude/scripts/cast-wipe-canary.sh"
  mkdir -p "${HOME}/.claude/scripts"
  touch "$script_path"
  mkdir -p "${HOME}/Library/LaunchAgents"
  cat > "${HOME}/Library/LaunchAgents/com.cast.wipe-canary.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.cast.wipe-canary</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${script_path}</string>
  </array>
  <key>WatchPaths</key>
  <array>
    <string>${HOME}/.claude</string>
  </array>
  <key>RunAtLoad</key>
  <false/>
</dict>
</plist>
EOF
}

# ---------------------------------------------------------------------------
# Test 1: pristine temp HOME → guards-missing WARNs, exit 0,
#         NO [ok] claims a backup is fresh (never-green-on-absent-evidence probe)
# ---------------------------------------------------------------------------

@test "pristine HOME: exits 0" {
  _run_integrity_neutral
  assert_success
}

@test "pristine HOME: guard files missing → WARN present" {
  _run_integrity_neutral
  assert_output --partial "[!!]"
  assert_output --partial "Write guards: missing"
}

@test "pristine HOME: no snapshot found → WARN present" {
  _run_integrity_neutral
  assert_output --partial "Snapshot:"
  # Should warn about missing snapshot (no backup dir exists)
  refute_output --partial "Snapshot: cast-snapshot"
}

@test "pristine HOME: NO [ok] line claims snapshot is fresh (never-green probe)" {
  # The critical PR #217 rule: no green line when no snapshot was created.
  _run_integrity_neutral
  # [ok] Snapshot: cast-snapshot-... must not appear when no fixture was created.
  run bash -c "echo '$output' | grep -E '^\[ok\].*Snapshot.*old' || true"
  refute_output --partial "ok"
}

@test "pristine HOME: NO [ok] line claims db-backup is fresh (never-green probe)" {
  _run_integrity_neutral
  run bash -c "echo '$output' | grep -E 'DB backups: fresh' | grep 'ok' || true"
  refute_output --partial "ok"
}

@test "pristine HOME: verdict line present with ok/warn/info counts" {
  _run_integrity_neutral
  assert_output --partial "integrity:"
  assert_output --partial "ok,"
  assert_output --partial "warn,"
  assert_output --partial "info"
}

# ---------------------------------------------------------------------------
# Test 2: fixture HOME (guard files + fresh snapshot + fresh db-backup) → ok rungs
# ---------------------------------------------------------------------------

@test "fixture HOME: guard files present → [ok] write guards" {
  _install_guard_files
  _run_integrity_neutral
  assert_output --partial "Write guards: all guard scripts present"
  run bash -c "printf '%s\n' '$output' | grep 'Write guards: all guard scripts present'"
  assert_output --partial "ok"
}

@test "fixture HOME: fresh snapshot present → [ok] snapshot rung" {
  _install_guard_files
  _create_fresh_snapshot
  _run_integrity_neutral
  assert_output --partial "Snapshot: cast-snapshot-"
  run bash -c "printf '%s\n' '$output' | grep 'Snapshot: cast-snapshot'"
  assert_output --partial "ok"
}

@test "fixture HOME: fresh db-backup → [ok] db-backups rung" {
  _install_guard_files
  _create_fresh_db_backup
  _run_integrity_neutral
  assert_output --partial "DB backups: fresh"
  run bash -c "printf '%s\n' '$output' | grep 'DB backups: fresh'"
  assert_output --partial "ok"
}

@test "fixture HOME: no colocation → [ok] colocation rung" {
  _install_guard_files
  _run_integrity_neutral
  assert_output --partial "Colocation: no recent backups inside blast radius"
  run bash -c "printf '%s\n' '$output' | grep 'Colocation: no recent'"
  assert_output --partial "ok"
}

# ---------------------------------------------------------------------------
# Test 3: colocated-backup fixture → colocation WARN fires
# ---------------------------------------------------------------------------

@test "colocation fixture: fresh ~/.claude/backups entry → colocation WARN" {
  mkdir -p "$HOME/.claude/backups"
  touch "$HOME/.claude/backups/cast-snapshot-coloc"

  _run_integrity_neutral
  assert_output --partial "Colocation:"
  assert_output --partial "blast radius"
  run bash -c "printf '%s\n' '$output' | grep 'Colocation:' | grep '\[!!\]'"
  assert_success
}

@test "colocation fixture: WARN line contains count ≥ 1" {
  mkdir -p "$HOME/.claude/backups"
  touch "$HOME/.claude/backups/snap1"
  touch "$HOME/.claude/backups/snap2"

  _run_integrity_neutral
  run bash -c "printf '%s\n' '$output' | grep 'Colocation:' | grep -E '[1-9][0-9]* backup'"
  assert_success
}

# ---------------------------------------------------------------------------
# Test 4a: canary daemon loaded + script off blast radius → [ok]
# ---------------------------------------------------------------------------

@test "canary: loaded + script outside blast radius → [ok]" {
  _install_fake_launchctl_canary_loaded
  _write_canary_plist_outside_blast

  _run_integrity_neutral "$FAKE_BIN"
  assert_output --partial "Wipe canary: daemon loaded, script present and off blast radius"
  run bash -c "printf '%s\n' '$output' | grep 'Wipe canary: daemon loaded, script present and off blast radius'"
  assert_output --partial "ok"
}

# ---------------------------------------------------------------------------
# Test 4b: canary daemon loaded + script INSIDE ~/.claude (blast radius) → WARN
# Never-false-green probe: the real machine currently has this condition.
# ---------------------------------------------------------------------------

@test "canary: loaded + script inside blast radius → WARN (never-false-green probe)" {
  _install_fake_launchctl_canary_loaded
  _write_canary_plist_inside_blast

  _run_integrity_neutral "$FAKE_BIN"
  assert_output --partial "Wipe canary:"
  assert_output --partial "inside blast radius"
  # Must be WARN, not [ok]
  run bash -c "printf '%s\n' '$output' | grep 'Wipe canary:' | grep '\[!!\]'"
  assert_success
}

# ---------------------------------------------------------------------------
# Test 4c: canary daemon NOT loaded → WARN
# ---------------------------------------------------------------------------

@test "canary: daemon not loaded → WARN" {
  _install_fake_launchctl_canary_not_loaded

  _run_integrity_neutral "$FAKE_BIN"
  assert_output --partial "Wipe canary: daemon not loaded"
  run bash -c "printf '%s\n' '$output' | grep 'Wipe canary: daemon not loaded' | grep '\[!!\]'"
  assert_success
}

# ---------------------------------------------------------------------------
# Test 4d: launchctl absent → INFO skip (Linux/CI rung)
# Only testable on systems without launchctl. Skip on macOS.
# ---------------------------------------------------------------------------

@test "canary: launchctl absent → INFO skip" {
  if command -v launchctl >/dev/null 2>&1; then
    skip "launchctl present — launchctl-absent rung only testable on Linux/CI"
  fi
  # No fake launchctl in PATH — the check should hit "not available" branch
  _run_integrity_neutral
  assert_output --partial "Wipe canary: launchctl not available"
  run bash -c "printf '%s\n' '$output' | grep 'Wipe canary: launchctl not available' | grep '\[--\]'"
  assert_success
}

# ---------------------------------------------------------------------------
# Litestream: launchctl absent → INFO skipped (Linux/CI rung)
# Only testable on systems without launchctl. Skip on macOS.
# ---------------------------------------------------------------------------

@test "litestream: launchctl absent → INFO daemon check skipped" {
  if command -v launchctl >/dev/null 2>&1; then
    skip "launchctl present — launchctl-absent rung only testable on Linux/CI"
  fi

  _install_fake_litestream
  mkdir -p "$CAST_LITESTREAM_ROOT"
  cat > "${CAST_LITESTREAM_ROOT}/litestream.yml" <<EOF
dbs:
  - path: ${HOME}/.claude/cast.db
    replicas:
      - type: file
        path: ${CAST_LITESTREAM_ROOT}/litestream/cast-db
EOF

  run env PATH="${FAKE_BIN}:${PATH}" \
    HOME="$HOME" \
    CLAUDE_SUBPROCESS=0 \
    CAST_BACKUP_ROOT="$CAST_BACKUP_ROOT" \
    CAST_BACKUP_DIR="$CAST_BACKUP_DIR" \
    CAST_LITESTREAM_ROOT="$CAST_LITESTREAM_ROOT" \
    CAST_INCIDENT_DIR="$CAST_INCIDENT_DIR" \
    bash "$CAST_BIN" integrity 2>&1
  assert_output --partial "daemon check skipped"
  assert_output --partial "--"
}

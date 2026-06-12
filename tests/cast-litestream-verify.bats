#!/usr/bin/env bats
# tests/cast-litestream-verify.bats — Unit tests for scripts/cast-litestream-verify.sh
#
# Isolation: ALL tests use setup_temp_home/teardown_temp_home — never touch real $HOME.
# No BSD-only flags (date -v, stat -f) — must pass Ubuntu.

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'
load 'helpers/setup'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
VERIFY_SCRIPT="${REPO_DIR}/scripts/cast-litestream-verify.sh"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Install a fake litestream binary in $1 with the given behavior.
#   behavior=fail  — exits 1 on "restore" (simulates restore failure)
#   behavior=junk  — writes non-SQLite junk to the -o path, exits 0
#   behavior=noop  — exits 0 for all invocations
_install_fake_litestream() {
  local bindir="$1"
  local behavior="${2:-noop}"
  mkdir -p "$bindir"

  case "$behavior" in
    fail)
      cat > "${bindir}/litestream" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "restore" ]]; then
  echo "ERROR: simulated restore failure" >&2
  exit 1
fi
exit 0
EOF
      ;;
    junk)
      cat > "${bindir}/litestream" <<'EOF'
#!/usr/bin/env bash
# Succeed at restore but write a non-SQLite file to the -o path.
if [[ "$1" == "restore" ]]; then
  while [[ $# -gt 0 ]]; do
    if [[ "$1" == "-o" ]]; then
      printf 'this is not a sqlite database\n' > "$2"
      exit 0
    fi
    shift
  done
fi
exit 0
EOF
      ;;
    noop|*)
      cat > "${bindir}/litestream" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
      ;;
  esac
  chmod +x "${bindir}/litestream"
  export PATH="${bindir}:${PATH}"
}

# Create a valid config + non-empty replica directory in the temp env.
# (The replica dir gets one dummy file so the empty-replica check passes.)
_setup_valid_replica_env() {
  local replica_dir="${CAST_LITESTREAM_ROOT}/litestream/cast-db"
  mkdir -p "${replica_dir}/ltx"
  printf 'fake ltx data\n' > "${replica_dir}/ltx/fake.ltx"

  mkdir -p "${CAST_LITESTREAM_ROOT}"
  cat > "${CAST_LITESTREAM_ROOT}/litestream.yml" <<YAML
dbs:
  - path: ${CAST_DB_PATH}
    replicas:
      - type: file
        path: ${replica_dir}
YAML
}

# ---------------------------------------------------------------------------
# Setup / teardown
# ---------------------------------------------------------------------------

setup() {
  setup_temp_home
  export CAST_LITESTREAM_ROOT="${HOME}/Library/Application Support/cast-test"
  export CAST_DB_PATH="${HOME}/.claude/cast.db"
  FAKE_BIN="${BATS_TEST_TMPDIR}/fake-ls-bin"
}

teardown() {
  teardown_temp_home
}

# ---------------------------------------------------------------------------
# 1. Missing litestream binary → FAIL (non-zero) with clear message
# ---------------------------------------------------------------------------
@test "missing litestream binary exits non-zero with FAIL message" {
  # Use a PATH that contains only safe system dirs (no litestream)
  local safe_path="/usr/bin:/bin:/usr/sbin:/sbin"
  run env PATH="$safe_path" bash "$VERIFY_SCRIPT"
  assert_failure
  assert_output --partial "FAIL"
  assert_output --partial "not found"
}

# ---------------------------------------------------------------------------
# 2. Fake litestream restore fails → FAIL with "restore" in the message
# ---------------------------------------------------------------------------
@test "fake restore failure exits non-zero with FAIL restore message" {
  _install_fake_litestream "$FAKE_BIN" fail
  _setup_valid_replica_env

  run bash "$VERIFY_SCRIPT"
  assert_failure
  assert_output --partial "FAIL"
  assert_output --partial "restore"
}

# ---------------------------------------------------------------------------
# 3. Fake litestream writes junk → integrity_check fails
# ---------------------------------------------------------------------------
@test "fake restore writes junk file fails integrity_check" {
  _install_fake_litestream "$FAKE_BIN" junk
  _setup_valid_replica_env

  run bash "$VERIFY_SCRIPT"
  assert_failure
  assert_output --partial "FAIL"
  assert_output --partial "integrity"
}

# ---------------------------------------------------------------------------
# 4. Config file missing → FAIL with "config not found"
# ---------------------------------------------------------------------------
@test "missing config exits non-zero with config-not-found message" {
  _install_fake_litestream "$FAKE_BIN" noop
  # Deliberately do NOT call _setup_valid_replica_env — no config file

  run bash "$VERIFY_SCRIPT"
  assert_failure
  assert_output --partial "config not found"
}

# ---------------------------------------------------------------------------
# 5. Replica directory missing → FAIL with "replica directory" in message
# ---------------------------------------------------------------------------
@test "missing replica directory exits non-zero with replica-directory message" {
  _install_fake_litestream "$FAKE_BIN" noop

  # Write config but do NOT create the replica directory
  mkdir -p "${CAST_LITESTREAM_ROOT}"
  cat > "${CAST_LITESTREAM_ROOT}/litestream.yml" <<YAML
dbs:
  - path: ${CAST_DB_PATH}
    replicas:
      - type: file
        path: ${CAST_LITESTREAM_ROOT}/litestream/cast-db
YAML

  run bash "$VERIFY_SCRIPT"
  assert_failure
  assert_output --partial "replica directory"
}

# ---------------------------------------------------------------------------
# 6. Happy path — real litestream binary (skip if not installed)
#    Creates a tiny DB, replicates briefly, then verifies.
# ---------------------------------------------------------------------------
@test "happy path: real litestream restore passes all checks" {
  command -v litestream > /dev/null 2>&1 || skip "litestream not installed"
  command -v sqlite3   > /dev/null 2>&1 || skip "sqlite3 not installed"

  # Create a minimal SQLite database in the temp home
  mkdir -p "${HOME}/.claude"
  sqlite3 "${CAST_DB_PATH}" \
    "CREATE TABLE t (id INTEGER PRIMARY KEY); INSERT INTO t VALUES (1);"

  # Write litestream config pointing at the temp DB and a temp replica dir
  local replica_dir="${CAST_LITESTREAM_ROOT}/litestream/cast-db"
  local config_file="${CAST_LITESTREAM_ROOT}/litestream.yml"
  mkdir -p "${CAST_LITESTREAM_ROOT}"
  cat > "${config_file}" <<YAML
dbs:
  - path: ${CAST_DB_PATH}
    replicas:
      - type: file
        path: ${replica_dir}
YAML

  # Start litestream replicate in background; kill after ~3s for initial snapshot
  litestream replicate -config "${config_file}" > /dev/null 2>&1 &
  local LS_PID="$!"
  sleep 3
  kill "${LS_PID}" 2>/dev/null || true
  wait "${LS_PID}" 2>/dev/null || true

  # If no replica files were produced, environment timing is the culprit — skip
  local file_count
  file_count="$(find "${replica_dir}" -type f 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "${file_count}" -eq 0 ]]; then
    skip "litestream did not create replica files within 3s (environment timing)"
  fi

  run bash "$VERIFY_SCRIPT"
  assert_success
  assert_output --partial "PASS"
}

#!/usr/bin/env bats
# tests/scripts/cast-memory-backup.bats — Tests for scripts/cast-memory-backup.sh

bats_require_minimum_version 1.5.0

load '../test_helper/bats-support/load'
load '../test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
BACKUP_SCRIPT="${REPO_DIR}/scripts/cast-memory-backup.sh"

# ── Setup / teardown ─────────────────────────────────────────────────────────

setup() {
  export ORIG_HOME="$HOME"
  export HOME="$(realpath "$(mktemp -d)")"
  mkdir -p "${HOME}/.claude/agent-memory-local/code-writer"
  mkdir -p "${HOME}/.claude/logs"
  echo "test memory content" > "${HOME}/.claude/agent-memory-local/code-writer/MEMORY.md"

  # Use $TMPDIR for tarball output (sandbox-safe path)
  export CAST_BACKUP_DIR="$(mktemp -d)"

  # Mock gh CLI: create a fake gh that exits 0 and records calls
  export MOCK_BIN="$(mktemp -d)"
  cat > "${MOCK_BIN}/gh" <<GHEOF
#!/bin/bash
echo "gh \$*" >> "${MOCK_BIN}/gh_calls.log"
exit 0
GHEOF
  chmod +x "${MOCK_BIN}/gh"
  export PATH="${MOCK_BIN}:${PATH}"
}

teardown() {
  rm -rf "$HOME" "$MOCK_BIN" "$CAST_BACKUP_DIR"
  export HOME="$ORIG_HOME"
}

# ── Tests ────────────────────────────────────────────────────────────────────

# 1. --dry-run exits 0 when agent-memory-local is present
@test "cast-memory-backup: --dry-run exits 0 with agent-memory-local present" {
  run bash "$BACKUP_SCRIPT" --dry-run
  assert_success
}

# 2. --dry-run creates a .tar.gz file in CAST_BACKUP_DIR
@test "cast-memory-backup: --dry-run creates tarball in backup dir" {
  DATE=$(date +%Y%m%d)
  EXPECTED_FILE="${CAST_BACKUP_DIR}/cast-memory-backup-${DATE}.tar.gz"
  rm -f "$EXPECTED_FILE"

  run bash "$BACKUP_SCRIPT" --dry-run
  assert_success
  [ -f "$EXPECTED_FILE" ]
}

# 3. --dry-run tarball contains agent-memory-local/
@test "cast-memory-backup: --dry-run tarball contains agent-memory-local/" {
  DATE=$(date +%Y%m%d)
  TARBALL="${CAST_BACKUP_DIR}/cast-memory-backup-${DATE}.tar.gz"
  rm -f "$TARBALL"

  bash "$BACKUP_SCRIPT" --dry-run

  run tar -tzf "$TARBALL"
  assert_success
  assert_output --partial "agent-memory-local/"
}

# 4. --dry-run does NOT invoke gh CLI
@test "cast-memory-backup: --dry-run does not call gh release" {
  rm -f "${MOCK_BIN}/gh_calls.log"

  run bash "$BACKUP_SCRIPT" --dry-run
  assert_success

  # gh_calls.log should NOT exist (dry-run skips gh)
  if [ -f "${MOCK_BIN}/gh_calls.log" ]; then
    run cat "${MOCK_BIN}/gh_calls.log"
    refute_output --partial "release create"
  fi
}

# 5. Missing agent-memory-local exits 1 with error message
@test "cast-memory-backup: missing agent-memory-local exits 1 with error" {
  rm -rf "${HOME}/.claude/agent-memory-local"

  run bash "$BACKUP_SCRIPT" --dry-run
  assert_failure
  assert_output --partial "ERROR"
}

# 6. Full run (non-dry-run) invokes gh release create
@test "cast-memory-backup: full run calls gh release create" {
  rm -f "${MOCK_BIN}/gh_calls.log"

  run bash "$BACKUP_SCRIPT"
  assert_success

  [ -f "${MOCK_BIN}/gh_calls.log" ]
  run cat "${MOCK_BIN}/gh_calls.log"
  assert_output --partial "release create"
}

# 7. Script is executable
@test "cast-memory-backup: script is executable" {
  [ -x "$BACKUP_SCRIPT" ]
}

# 8. Script header documents the cron line
@test "cast-memory-backup: header contains cron documentation" {
  run grep -q "0 2 \* \* \*" "$BACKUP_SCRIPT"
  assert_success
}

#!/usr/bin/env bats

# Tests for scripts/cast-snapshot.py
# All tests use isolated temp dirs for CAST_BACKUP_ROOT and CAST_CLAUDE_DIR
# to avoid touching the real ~/.claude or backup locations.

setup() {
  load '../helpers/setup'
  setup_temp_home
  export CAST_DB_PATH="$HOME/.claude/cast.db"
  export CAST_BACKUP_DIR="$BATS_TEST_TMPDIR/db-backups"
  # Create isolated temp directories for each test
  BATS_BACKUP_ROOT="$BATS_TEST_TMPDIR/backups"
  BATS_CLAUDE_DIR="$BATS_TEST_TMPDIR/dot-claude"
  mkdir -p "$BATS_BACKUP_ROOT"
  mkdir -p "$BATS_CLAUDE_DIR"

  # Seed BATS_CLAUDE_DIR with some test files
  mkdir -p "$BATS_CLAUDE_DIR/config"
  mkdir -p "$BATS_CLAUDE_DIR/rules"
  mkdir -p "$BATS_CLAUDE_DIR/agent-memory-local"
  mkdir -p "$BATS_CLAUDE_DIR/projects/test-proj/memory"

  echo "pii_patterns:" > "$BATS_CLAUDE_DIR/config/pii-denylist-local.txt"
  echo "# Test rule" > "$BATS_CLAUDE_DIR/rules/a.md"
  echo "# CLAUDE.md" > "$BATS_CLAUDE_DIR/CLAUDE.md"
  echo "memory_entry" > "$BATS_CLAUDE_DIR/agent-memory-local/test.md"
  echo "project memory" > "$BATS_CLAUDE_DIR/projects/test-proj/memory/note.md"

  # Resolve the repo directory (parent of tests/)
  REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
}

teardown() {
  # Cleanup is automatic via BATS_TEST_TMPDIR removal
  teardown_temp_home
}

@test "snapshot creates a cast-snapshot-YYYY-MM-DD directory" {
  export CAST_BACKUP_ROOT="$BATS_BACKUP_ROOT"
  export CAST_CLAUDE_DIR="$BATS_CLAUDE_DIR"

  run python3 "$REPO_DIR/scripts/cast-snapshot.py"
  [ "$status" -eq 0 ]

  # Check that a dated snapshot directory was created
  TODAY=$(date +%Y-%m-%d)
  [ -d "$BATS_BACKUP_ROOT/cast-snapshot-$TODAY" ]
}

@test "snapshot JSON output is valid and files_copied > 0" {
  export CAST_BACKUP_ROOT="$BATS_BACKUP_ROOT"
  export CAST_CLAUDE_DIR="$BATS_CLAUDE_DIR"

  run python3 "$REPO_DIR/scripts/cast-snapshot.py"
  [ "$status" -eq 0 ]

  # Verify stdout is valid JSON
  echo "$output" | python3 -m json.tool >/dev/null
  [ $? -eq 0 ]

  # Verify files_copied is present and > 0
  FILES_COPIED=$(echo "$output" | python3 -c "import sys, json; data = json.load(sys.stdin); print(data.get('files_copied', 0))")
  [ "$FILES_COPIED" -gt 0 ]
}

@test "retention prunes old snapshots to 7 daily + 4 weekly" {
  export CAST_BACKUP_ROOT="$BATS_BACKUP_ROOT"
  export CAST_CLAUDE_DIR="$BATS_CLAUDE_DIR"

  # Create 10 fake snapshot directories with dates spanning multiple weeks.
  # Portable date arithmetic via python3 — GNU `date -d` and BSD `date -v` differ,
  # and CI runs on Linux (the `date -v` form fails there with "invalid option -- v").
  for i in {0..9}; do
    DATE=$(python3 -c "import datetime,sys; print((datetime.date.today()-datetime.timedelta(days=int(sys.argv[1]))).isoformat())" "$i")
    mkdir -p "$BATS_BACKUP_ROOT/cast-snapshot-$DATE"
  done

  # Run snapshot (will trigger retention)
  run python3 "$REPO_DIR/scripts/cast-snapshot.py"
  [ "$status" -eq 0 ]

  # Count remaining snapshot directories
  # Should be ≤ 11 (7 daily + 4 weekly + 1 new from today)
  COUNT=$(find "$BATS_BACKUP_ROOT" -maxdepth 1 -type d -name "cast-snapshot-*" | wc -l | tr -d ' ')
  [ "$COUNT" -le 11 ]
}

@test "restore round-trip restores files to target directory" {
  export CAST_BACKUP_ROOT="$BATS_BACKUP_ROOT"
  export CAST_CLAUDE_DIR="$BATS_CLAUDE_DIR"

  # Create a snapshot
  run python3 "$REPO_DIR/scripts/cast-snapshot.py"
  [ "$status" -eq 0 ]

  TODAY=$(date +%Y-%m-%d)
  RESTORE_TARGET="$BATS_TEST_TMPDIR/restore-out"

  # Restore to target directory
  run python3 "$REPO_DIR/scripts/cast-snapshot.py" restore "$TODAY" --target "$RESTORE_TARGET"
  [ "$status" -eq 0 ]

  # Verify at least one expected file exists in target
  [ -f "$RESTORE_TARGET/rules/a.md" ]
  [ -f "$RESTORE_TARGET/CLAUDE.md" ]
  [ -f "$RESTORE_TARGET/config/pii-denylist-local.txt" ]
}

@test "secrets are excluded from snapshot (no .env, api_key, secret files)" {
  export CAST_BACKUP_ROOT="$BATS_BACKUP_ROOT"
  export CAST_CLAUDE_DIR="$BATS_CLAUDE_DIR"

  # Place secret files in CLAUDE_DIR
  echo "ANTHROPIC_API_KEY=sk-ant-abc123" > "$BATS_CLAUDE_DIR/config/secret.env"
  echo "token=xyz" > "$BATS_CLAUDE_DIR/my_api_key.txt"
  echo "ADMIN_PASSWORD=secret123" > "$BATS_CLAUDE_DIR/rules/db_secret.md"

  # Run snapshot
  run python3 "$REPO_DIR/scripts/cast-snapshot.py"
  [ "$status" -eq 0 ]

  TODAY=$(date +%Y-%m-%d)
  SNAPSHOT_DIR="$BATS_BACKUP_ROOT/cast-snapshot-$TODAY"

  # Verify secret files were NOT copied
  ! find "$SNAPSHOT_DIR" -name "secret.env" -o -name "my_api_key.txt" -o -name "*secret*" | grep -q .
  [ $? -eq 0 ]
}

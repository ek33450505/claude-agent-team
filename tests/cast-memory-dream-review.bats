#!/usr/bin/env bats
# cast-memory-dream-review.bats — BATS tests for scripts/cast-memory-dream-review.py
#
# Tests the memory_consolidation_runs reviewer that lists pending (unpromoted)
# dream output directories.
#
# Coverage:
# - Happy path: seeded temp cast.db with completed runs
# - Empty input (no completed runs)
# - Error state: malformed/missing table (graceful non-crash)

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'
load 'helpers/setup'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_DIR/scripts/cast-memory-dream-review.py"

# Helper to initialize cast.db with schema and populate test data
_init_test_db() {
    local db_path="$1"

    # Run cast-db-init.sh to create schema
    bash "$REPO_DIR/scripts/cast-db-init.sh" --db "$db_path" >/dev/null 2>&1

    # Schema is now ready; insert test rows
}

setup() {
    setup_temp_home
    export CAST_DB_PATH="$BATS_TEST_TMPDIR/cast.db"
    _init_test_db "$CAST_DB_PATH"
}

teardown() {
    teardown_temp_home
}

# ──────────────────────────────────────────────────────────────────────────────
# Test 1: Happy path — pending runs are listed in human-readable table format
# ──────────────────────────────────────────────────────────────────────────────
@test "lists pending runs in human-readable table with correct columns" {
    # Create output directories and database rows
    local output_dir1="$BATS_TEST_TMPDIR/projects/test-1/memory/_dream-output-001"
    mkdir -p "$output_dir1"

    # Create a manifest in the output directory
    cat > "$output_dir1/_dream-manifest.json" <<'EOF'
{
  "run_id": "run-001",
  "created_at": "2026-07-08T10:00:00Z",
  "memory_dir_sha_at_dream_start": "abc123",
  "files_written": [
    {"name": "feedback-1.md", "canonical_path": "/home/test/memory/feedback-1.md"},
    {"name": "project-2.md", "canonical_path": "/home/test/memory/project-2.md"}
  ],
  "files_unchanged": []
}
EOF

    # Insert a completed run into the database
    sqlite3 "$CAST_DB_PATH" <<EOF
INSERT INTO memory_consolidation_runs
  (run_id, project_id, status, output_path, completed_at, candidates_written)
VALUES
  ('run-001', 'test-project-1', 'completed', '$output_dir1', '2026-07-08T10:00:00Z', 2);
EOF

    # Run the script
    run python3 "$SCRIPT"
    assert_success

    # Output should contain table header and data row
    assert_line --partial "run_id"
    assert_line --partial "project_id"
    assert_line --partial "output_path"
    assert_line --partial "pending"

    # Should list the pending run
    assert_line --partial "run-001"
    assert_line --partial "test-project-1"
}

# ──────────────────────────────────────────────────────────────────────────────
# Test 2: Promoted runs are hidden (have .promoted sentinel)
# ──────────────────────────────────────────────────────────────────────────────
@test "hides fully-promoted runs (with .promoted sentinel)" {
    local output_dir_promoted="$BATS_TEST_TMPDIR/projects/test-2/memory/_dream-output-002"
    mkdir -p "$output_dir_promoted"

    # Create .promoted sentinel to mark as promoted
    touch "$output_dir_promoted/.promoted"

    # Create manifest
    cat > "$output_dir_promoted/_dream-manifest.json" <<'EOF'
{
  "run_id": "run-002-promoted",
  "created_at": "2026-07-08T11:00:00Z",
  "memory_dir_sha_at_dream_start": "def456",
  "files_written": [],
  "files_unchanged": []
}
EOF

    # Insert row
    sqlite3 "$CAST_DB_PATH" <<EOF
INSERT INTO memory_consolidation_runs
  (run_id, project_id, status, output_path, completed_at, candidates_written)
VALUES
  ('run-002-promoted', 'test-project-2', 'completed', '$output_dir_promoted', '2026-07-08T11:00:00Z', 0);
EOF

    run python3 "$SCRIPT"
    assert_success

    # Promoted run should NOT appear in the output
    ! assert_line --partial "run-002-promoted"
}

# ──────────────────────────────────────────────────────────────────────────────
# Test 3: Partial runs (with .partial sentinel) are shown
# ──────────────────────────────────────────────────────────────────────────────
@test "shows partial runs (with .partial sentinel) as retryable" {
    local output_dir_partial="$BATS_TEST_TMPDIR/projects/test-3/memory/_dream-output-003"
    mkdir -p "$output_dir_partial"

    # Create .partial sentinel
    touch "$output_dir_partial/.partial"

    cat > "$output_dir_partial/_dream-manifest.json" <<'EOF'
{
  "run_id": "run-003-partial",
  "created_at": "2026-07-08T12:00:00Z",
  "memory_dir_sha_at_dream_start": "ghi789",
  "files_written": [
    {"name": "entry.md"}
  ],
  "files_unchanged": []
}
EOF

    sqlite3 "$CAST_DB_PATH" <<EOF
INSERT INTO memory_consolidation_runs
  (run_id, project_id, status, output_path, completed_at, candidates_written)
VALUES
  ('run-003-partial', 'test-project-3', 'completed', '$output_dir_partial', '2026-07-08T12:00:00Z', 1);
EOF

    run python3 "$SCRIPT"
    assert_success

    # Partial run should appear with status "partial"
    assert_line --partial "run-003-partial"
    assert_line --partial "partial"
}

# ──────────────────────────────────────────────────────────────────────────────
# Test 4: Empty input — no completed runs → friendly message
# ──────────────────────────────────────────────────────────────────────────────
@test "no completed runs → prints friendly message and exits 0" {
    # Do NOT insert any rows; DB is empty
    run python3 "$SCRIPT"
    assert_success

    # Should print friendly "no pending" message
    assert_line --partial "No pending dream runs found"
}

# ──────────────────────────────────────────────────────────────────────────────
# Test 5: JSON output mode with pending runs
# ──────────────────────────────────────────────────────────────────────────────
@test "JSON output mode lists pending runs as structured array" {
    local output_dir1="$BATS_TEST_TMPDIR/projects/test-5/memory/_dream-output-005"
    mkdir -p "$output_dir1"

    cat > "$output_dir1/_dream-manifest.json" <<'EOF'
{
  "run_id": "run-005",
  "created_at": "2026-07-08T14:00:00Z",
  "memory_dir_sha_at_dream_start": "jkl012",
  "files_written": [
    {"name": "test.md"}
  ],
  "files_unchanged": []
}
EOF

    sqlite3 "$CAST_DB_PATH" <<EOF
INSERT INTO memory_consolidation_runs
  (run_id, project_id, status, output_path, completed_at, candidates_written)
VALUES
  ('run-005', 'test-project-5', 'completed', '$output_dir1', '2026-07-08T14:00:00Z', 1);
EOF

    run python3 "$SCRIPT" --json
    assert_success

    # Output should be valid JSON array
    echo "$output" | python3 -c "
import json, sys
data = json.load(sys.stdin)
if not isinstance(data, list):
    print('ERROR: not a list', file=sys.stderr)
    sys.exit(1)
if len(data) != 1:
    print(f'ERROR: expected 1 item, got {len(data)}', file=sys.stderr)
    sys.exit(1)
item = data[0]
if item['run_id'] != 'run-005':
    print(f'ERROR: wrong run_id', file=sys.stderr)
    sys.exit(1)
"
}

# ──────────────────────────────────────────────────────────────────────────────
# Test 6: Project ID filter (--project-id)
# ──────────────────────────────────────────────────────────────────────────────
@test "filters results by --project-id flag" {
    # Insert two runs for different projects
    for proj_id in proj-a proj-b; do
        local output_dir="$BATS_TEST_TMPDIR/projects/$proj_id/memory/_dream-output-$proj_id"
        mkdir -p "$output_dir"

        cat > "$output_dir/_dream-manifest.json" <<EOF
{
  "run_id": "run-$proj_id",
  "created_at": "2026-07-08T15:00:00Z",
  "memory_dir_sha_at_dream_start": "xxx",
  "files_written": [],
  "files_unchanged": []
}
EOF

        sqlite3 "$CAST_DB_PATH" <<DBEOF
INSERT INTO memory_consolidation_runs
  (run_id, project_id, status, output_path, completed_at, candidates_written)
VALUES
  ('run-$proj_id', '$proj_id', 'completed', '$output_dir', '2026-07-08T15:00:00Z', 0);
DBEOF
    done

    # Query only proj-a
    run python3 "$SCRIPT" --project-id proj-a
    assert_success

    # Should show only proj-a's run
    assert_line --partial "run-proj-a"
    assert_line --partial "proj-a"

    # Should NOT show proj-b
    ! assert_line --partial "proj-b"
}

# ──────────────────────────────────────────────────────────────────────────────
# Test 7: Graceful error on missing output directory
# ──────────────────────────────────────────────────────────────────────────────
@test "skips completed runs with missing/deleted output_path" {
    # Insert a run whose output_path does not exist
    local nonexistent_path="/nonexistent/dream-output-999"

    sqlite3 "$CAST_DB_PATH" <<EOF
INSERT INTO memory_consolidation_runs
  (run_id, project_id, status, output_path, completed_at, candidates_written)
VALUES
  ('run-999', 'test-project-999', 'completed', '$nonexistent_path', '2026-07-08T16:00:00Z', 0);
EOF

    run python3 "$SCRIPT"
    assert_success

    # Script should not crash; missing path is silently skipped
    # Output should indicate no pending runs (or just the header)
    assert_line --partial "No pending dream runs found"
}

# ──────────────────────────────────────────────────────────────────────────────
# Test 8: Happy path with manifest file to extract files_changed_count
# ──────────────────────────────────────────────────────────────────────────────
@test "reads files_changed_count from _dream-manifest.json files_written array" {
    local output_dir="$BATS_TEST_TMPDIR/projects/test-8/memory/_dream-output-008"
    mkdir -p "$output_dir"

    # Create manifest with 3 files
    cat > "$output_dir/_dream-manifest.json" <<'EOF'
{
  "run_id": "run-008",
  "created_at": "2026-07-08T17:00:00Z",
  "memory_dir_sha_at_dream_start": "abc",
  "files_written": [
    {"name": "file1.md", "canonical_path": "/path/file1.md"},
    {"name": "file2.md", "canonical_path": "/path/file2.md"},
    {"name": "file3.md", "canonical_path": "/path/file3.md"}
  ],
  "files_unchanged": ["file4.md", "file5.md"]
}
EOF

    sqlite3 "$CAST_DB_PATH" <<EOF
INSERT INTO memory_consolidation_runs
  (run_id, project_id, status, output_path, completed_at, candidates_written)
VALUES
  ('run-008', 'test-project-8', 'completed', '$output_dir', '2026-07-08T17:00:00Z', 0);
EOF

    run python3 "$SCRIPT"
    assert_success

    # Should show files_changed_count as 3 (from files_written length)
    # Look for "3" in the files_changed column (may be right-aligned)
    assert_line --partial "3"
}

# ──────────────────────────────────────────────────────────────────────────────
# Test 9: Non-existent or wrong db path → error message, exit 1
# ──────────────────────────────────────────────────────────────────────────────
@test "exits with error when cast.db does not exist at specified path" {
    run python3 "$SCRIPT" --db /nonexistent/cast.db
    # Should error (status is non-zero in bats)
    [ "$status" -ne 0 ]

    # Should emit JSON error
    echo "$output" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    if 'error' not in data:
        sys.exit(1)
except:
    sys.exit(1)
"
}

# ──────────────────────────────────────────────────────────────────────────────
# Test 10: Malformed _dream-manifest.json is handled gracefully
# ──────────────────────────────────────────────────────────────────────────────
@test "malformed or missing _dream-manifest.json does not crash" {
    local output_dir="$BATS_TEST_TMPDIR/projects/test-10/memory/_dream-output-010"
    mkdir -p "$output_dir"

    # Create an invalid JSON file
    echo "{ invalid json ]" > "$output_dir/_dream-manifest.json"

    sqlite3 "$CAST_DB_PATH" <<EOF
INSERT INTO memory_consolidation_runs
  (run_id, project_id, status, output_path, completed_at, candidates_written)
VALUES
  ('run-010', 'test-project-10', 'completed', '$output_dir', '2026-07-08T18:00:00Z', 5);
EOF

    run python3 "$SCRIPT"
    # Should not crash; should treat malformed manifest gracefully
    # (may still list the run with candidates_written count as fallback)
    assert_success
}

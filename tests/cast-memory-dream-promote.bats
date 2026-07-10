#!/usr/bin/env bats
# cast-memory-dream-promote.bats — BATS tests for scripts/cast-memory-dream-promote.py
#
# Tests the memory_consolidation_runs promoter that atomically copies dream output
# files from candidate directories to their canonical locations.
#
# Coverage:
# - Happy path: a promotable run is promoted, .promoted sentinel written, exit 0
# - Edge cases: already-promoted runs, SHA mismatches, no eligible files
# - Error states: missing run, non-completed status, missing manifest, parse errors
# - Options: --force (bypass SHA check), --dry-run (no writes), --db override

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'
load 'helpers/setup'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_DIR/scripts/cast-memory-dream-promote.py"

# Helper to initialize cast.db with schema
_init_test_db() {
    local db_path="$1"
    bash "$REPO_DIR/scripts/cast-db-init.sh" --db "$db_path" >/dev/null 2>&1
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
# Test 1: Happy path — promotable run is promoted, files copied, sentinel written
# ──────────────────────────────────────────────────────────────────────────────
@test "happy path: promotable run copies all files to canonical paths and writes .promoted sentinel" {
    # Setup: create output dir with manifest and candidate files
    local output_dir="$BATS_TEST_TMPDIR/projects/test-1/memory/_dream-output-001"
    mkdir -p "$output_dir"

    local canonical_dir="$BATS_TEST_TMPDIR/projects/test-1/memory"
    mkdir -p "$canonical_dir"

    # Create candidate files
    local candidate_file1="$output_dir/feedback-1.md"
    local canonical_file1="$canonical_dir/feedback-1.md"
    echo "# Feedback 1" > "$candidate_file1"

    local candidate_file2="$output_dir/project-test.md"
    local canonical_file2="$canonical_dir/project-test.md"
    echo "# Project Test" > "$candidate_file2"

    # Compute pre_sha256 of canonical files (they don't exist yet, so empty SHA)
    local pre_sha1=""
    local pre_sha2=""

    # Create manifest with per-file pre_sha256
    cat > "$output_dir/_dream-manifest.json" <<EOF
{
  "run_id": "run-001",
  "created_at": "2026-07-08T10:00:00Z",
  "memory_dir_sha_at_dream_start": "abc123",
  "files_written": [
    {
      "name": "feedback-1.md",
      "candidate_path": "$candidate_file1",
      "canonical_path": "$canonical_file1",
      "pre_sha256": "$pre_sha1"
    },
    {
      "name": "project-test.md",
      "candidate_path": "$candidate_file2",
      "canonical_path": "$canonical_file2",
      "pre_sha256": "$pre_sha2"
    }
  ],
  "files_unchanged": []
}
EOF

    # Insert completed run into DB
    sqlite3 "$CAST_DB_PATH" <<EOF
INSERT INTO memory_consolidation_runs
  (run_id, project_id, status, output_path, completed_at, candidates_written)
VALUES
  ('run-001', 'test-project-1', 'completed', '$output_dir', '2026-07-08T10:00:00Z', 2);
EOF

    # Run the promote script
    run python3 "$SCRIPT" --run-id run-001 --db "$CAST_DB_PATH"
    assert_success

    # Verify output is valid JSON with promotion report
    echo "$output" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert d['run_id'] == 'run-001', f'run_id mismatch: {d.get(\"run_id\")}'
assert d['promoted_count'] == 2, f'promoted_count should be 2, got {d.get(\"promoted_count\")}'
assert d['skipped_count'] == 0, f'skipped_count should be 0, got {d.get(\"skipped_count\")}'
assert d['conflict_count'] == 0, f'conflict_count should be 0, got {d.get(\"conflict_count\")}'
" || return 1

    # Verify canonical files were written
    [ -f "$canonical_file1" ]
    [ -f "$canonical_file2" ]

    # Verify .promoted sentinel exists
    [ -f "$output_dir/.promoted" ]
}

# ──────────────────────────────────────────────────────────────────────────────
# Test 2: Error — run not found in DB
# ──────────────────────────────────────────────────────────────────────────────
@test "error: run_id not found → JSON error message, exit 1" {
    run python3 "$SCRIPT" --run-id nonexistent-run-123 --db "$CAST_DB_PATH"
    [ "$status" -eq 1 ]

    # Output should be JSON error
    echo "$output" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert 'error' in d, 'output missing error field'
assert 'nonexistent-run-123' in d['error'], 'error should mention the run_id'
" || return 1
}

# ──────────────────────────────────────────────────────────────────────────────
# Test 3: Error — run has non-completed status
# ──────────────────────────────────────────────────────────────────────────────
@test "error: run status is not 'completed' → JSON error, exit 1" {
    local output_dir="$BATS_TEST_TMPDIR/projects/test-3/memory/_dream-output-003"
    mkdir -p "$output_dir"

    # Create dummy manifest
    cat > "$output_dir/_dream-manifest.json" <<'EOF'
{"run_id": "run-003", "created_at": "2026-07-08T10:00:00Z", "files_written": [], "files_unchanged": []}
EOF

    # Insert run with status 'pending' (not 'completed')
    sqlite3 "$CAST_DB_PATH" <<EOF
INSERT INTO memory_consolidation_runs
  (run_id, project_id, status, output_path, completed_at, candidates_written)
VALUES
  ('run-003', 'test-project-3', 'pending', '$output_dir', NULL, 0);
EOF

    run python3 "$SCRIPT" --run-id run-003 --db "$CAST_DB_PATH"
    [ "$status" -eq 1 ]

    echo "$output" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert 'error' in d, 'output missing error field'
assert 'completed' in d['error'].lower(), 'error should mention status requirement'
" || return 1
}

# ──────────────────────────────────────────────────────────────────────────────
# Test 4: Error — manifest file is missing
# ──────────────────────────────────────────────────────────────────────────────
@test "error: _dream-manifest.json not found → JSON error, exit 1" {
    local output_dir="$BATS_TEST_TMPDIR/projects/test-4/memory/_dream-output-004"
    mkdir -p "$output_dir"

    # Do NOT create manifest

    sqlite3 "$CAST_DB_PATH" <<EOF
INSERT INTO memory_consolidation_runs
  (run_id, project_id, status, output_path, completed_at, candidates_written)
VALUES
  ('run-004', 'test-project-4', 'completed', '$output_dir', '2026-07-08T10:00:00Z', 0);
EOF

    run python3 "$SCRIPT" --run-id run-004 --db "$CAST_DB_PATH"
    [ "$status" -eq 1 ]

    echo "$output" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert 'error' in d, 'output missing error field'
assert '_dream-manifest.json' in d['error'], 'error should mention manifest file'
" || return 1
}

# ──────────────────────────────────────────────────────────────────────────────
# Test 5: Error — manifest is malformed JSON
# ──────────────────────────────────────────────────────────────────────────────
@test "error: malformed _dream-manifest.json → JSON parse error, exit 1" {
    local output_dir="$BATS_TEST_TMPDIR/projects/test-5/memory/_dream-output-005"
    mkdir -p "$output_dir"

    # Create invalid JSON
    echo "{ invalid json ]" > "$output_dir/_dream-manifest.json"

    sqlite3 "$CAST_DB_PATH" <<EOF
INSERT INTO memory_consolidation_runs
  (run_id, project_id, status, output_path, completed_at, candidates_written)
VALUES
  ('run-005', 'test-project-5', 'completed', '$output_dir', '2026-07-08T10:00:00Z', 0);
EOF

    run python3 "$SCRIPT" --run-id run-005 --db "$CAST_DB_PATH"
    [ "$status" -eq 1 ]

    echo "$output" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert 'error' in d, 'output missing error field'
" || return 1
}

# ──────────────────────────────────────────────────────────────────────────────
# Test 6: Error — files_written uses legacy string format (no per_sha256)
# ──────────────────────────────────────────────────────────────────────────────
@test "error: legacy files_written format (strings, not dicts) → error requiring upgrade" {
    local output_dir="$BATS_TEST_TMPDIR/projects/test-6/memory/_dream-output-006"
    mkdir -p "$output_dir"

    # Legacy format: files_written is array of strings
    cat > "$output_dir/_dream-manifest.json" <<'EOF'
{
  "run_id": "run-006",
  "created_at": "2026-07-08T10:00:00Z",
  "files_written": [
    "feedback-1.md",
    "project-test.md"
  ],
  "files_unchanged": []
}
EOF

    sqlite3 "$CAST_DB_PATH" <<EOF
INSERT INTO memory_consolidation_runs
  (run_id, project_id, status, output_path, completed_at, candidates_written)
VALUES
  ('run-006', 'test-project-6', 'completed', '$output_dir', '2026-07-08T10:00:00Z', 2);
EOF

    run python3 "$SCRIPT" --run-id run-006 --db "$CAST_DB_PATH"
    [ "$status" -eq 1 ]

    echo "$output" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert 'error' in d, 'output missing error field'
assert 'legacy' in d['error'].lower() or 'pre_sha256' in d['error'], 'error should mention legacy format or pre_sha256'
" || return 1
}

# ──────────────────────────────────────────────────────────────────────────────
# Test 7: Error — run already promoted (has .promoted sentinel)
# ──────────────────────────────────────────────────────────────────────────────
@test "error: already promoted (has .promoted sentinel) → error, exit 1" {
    local output_dir="$BATS_TEST_TMPDIR/projects/test-7/memory/_dream-output-007"
    mkdir -p "$output_dir"

    # Create sentinel to mark as already promoted
    touch "$output_dir/.promoted"

    cat > "$output_dir/_dream-manifest.json" <<'EOF'
{"run_id": "run-007", "created_at": "2026-07-08T10:00:00Z", "files_written": [], "files_unchanged": []}
EOF

    sqlite3 "$CAST_DB_PATH" <<EOF
INSERT INTO memory_consolidation_runs
  (run_id, project_id, status, output_path, completed_at, candidates_written)
VALUES
  ('run-007', 'test-project-7', 'completed', '$output_dir', '2026-07-08T10:00:00Z', 0);
EOF

    run python3 "$SCRIPT" --run-id run-007 --db "$CAST_DB_PATH"
    [ "$status" -eq 1 ]

    echo "$output" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert 'error' in d, 'output missing error field'
assert 'Already promoted' in d['error'], 'error should mention already promoted'
" || return 1
}

# ──────────────────────────────────────────────────────────────────────────────
# Test 8: SHA precondition mismatch (without --force)
# ──────────────────────────────────────────────────────────────────────────────
@test "SHA mismatch without --force: conflict reported, canonical file not overwritten, exit 2" {
    local output_dir="$BATS_TEST_TMPDIR/projects/test-8/memory/_dream-output-008"
    local canonical_dir="$BATS_TEST_TMPDIR/projects/test-8/memory"
    mkdir -p "$output_dir" "$canonical_dir"

    # Create candidate file
    local candidate_file="$output_dir/feedback.md"
    echo "# Candidate version" > "$candidate_file"

    # Create pre-existing canonical file with different content
    local canonical_file="$canonical_dir/feedback.md"
    echo "# Original version" > "$canonical_file"

    # Compute SHA256 of canonical file
    local current_sha=$(python3 -c "import hashlib; print(hashlib.sha256(open('$canonical_file','rb').read()).hexdigest())")

    # Manifest says pre_sha256 was empty (different from current)
    cat > "$output_dir/_dream-manifest.json" <<EOF
{
  "run_id": "run-008",
  "created_at": "2026-07-08T10:00:00Z",
  "files_written": [
    {
      "name": "feedback.md",
      "candidate_path": "$candidate_file",
      "canonical_path": "$canonical_file",
      "pre_sha256": "different-sha-value"
    }
  ],
  "files_unchanged": []
}
EOF

    sqlite3 "$CAST_DB_PATH" <<EOF
INSERT INTO memory_consolidation_runs
  (run_id, project_id, status, output_path, completed_at, candidates_written)
VALUES
  ('run-008', 'test-project-8', 'completed', '$output_dir', '2026-07-08T10:00:00Z', 1);
EOF

    # Run promote (without --force)
    run python3 "$SCRIPT" --run-id run-008 --db "$CAST_DB_PATH"
    # Exit code 2 indicates promotion_conflicts exist
    [ "$status" -eq 2 ]

    # Verify output reports conflicts
    echo "$output" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert d['conflict_count'] > 0, 'should have promotion_conflicts'
assert len(d.get('promotion_conflicts', [])) > 0, 'promotion_conflicts array should not be empty'
" || return 1

    # Verify canonical file was NOT overwritten
    local current_content=$(cat "$canonical_file")
    [[ "$current_content" == *"Original version"* ]]
}

# ──────────────────────────────────────────────────────────────────────────────
# Test 9: --force flag bypasses SHA check
# ──────────────────────────────────────────────────────────────────────────────
@test "--force flag: bypasses SHA precondition check and promotes anyway" {
    local output_dir="$BATS_TEST_TMPDIR/projects/test-9/memory/_dream-output-009"
    local canonical_dir="$BATS_TEST_TMPDIR/projects/test-9/memory"
    mkdir -p "$output_dir" "$canonical_dir"

    local candidate_file="$output_dir/feedback.md"
    echo "# New candidate version" > "$candidate_file"

    local canonical_file="$canonical_dir/feedback.md"
    echo "# Old version" > "$canonical_file"

    # Manifest with mismatched pre_sha256
    cat > "$output_dir/_dream-manifest.json" <<EOF
{
  "run_id": "run-009",
  "created_at": "2026-07-08T10:00:00Z",
  "files_written": [
    {
      "name": "feedback.md",
      "candidate_path": "$candidate_file",
      "canonical_path": "$canonical_file",
      "pre_sha256": "intentionally-wrong-sha"
    }
  ],
  "files_unchanged": []
}
EOF

    sqlite3 "$CAST_DB_PATH" <<EOF
INSERT INTO memory_consolidation_runs
  (run_id, project_id, status, output_path, completed_at, candidates_written)
VALUES
  ('run-009', 'test-project-9', 'completed', '$output_dir', '2026-07-08T10:00:00Z', 1);
EOF

    # Run with --force
    run python3 "$SCRIPT" --run-id run-009 --db "$CAST_DB_PATH" --force
    assert_success

    # Verify canonical file WAS overwritten
    local content=$(cat "$canonical_file")
    [[ "$content" == *"New candidate version"* ]]

    # Verify .promoted sentinel exists
    [ -f "$output_dir/.promoted" ]
}

# ──────────────────────────────────────────────────────────────────────────────
# Test 10: --dry-run flag performs no writes
# ──────────────────────────────────────────────────────────────────────────────
@test "--dry-run flag: no files written, no sentinel created, but report output is generated" {
    local output_dir="$BATS_TEST_TMPDIR/projects/test-10/memory/_dream-output-010"
    local canonical_dir="$BATS_TEST_TMPDIR/projects/test-10/memory"
    mkdir -p "$output_dir" "$canonical_dir"

    local candidate_file="$output_dir/entry.md"
    echo "# Entry content" > "$candidate_file"

    local canonical_file="$canonical_dir/entry.md"
    # Canonical doesn't exist yet

    cat > "$output_dir/_dream-manifest.json" <<EOF
{
  "run_id": "run-010",
  "created_at": "2026-07-08T10:00:00Z",
  "files_written": [
    {
      "name": "entry.md",
      "candidate_path": "$candidate_file",
      "canonical_path": "$canonical_file",
      "pre_sha256": ""
    }
  ],
  "files_unchanged": []
}
EOF

    sqlite3 "$CAST_DB_PATH" <<EOF
INSERT INTO memory_consolidation_runs
  (run_id, project_id, status, output_path, completed_at, candidates_written)
VALUES
  ('run-010', 'test-project-10', 'completed', '$output_dir', '2026-07-08T10:00:00Z', 1);
EOF

    run python3 "$SCRIPT" --run-id run-010 --db "$CAST_DB_PATH" --dry-run
    assert_success

    # Verify output reports what would be promoted
    echo "$output" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert d['dry_run'] == True, 'dry_run flag should be True'
assert d['promoted_count'] == 1, 'report should show 1 promoted (hypothetical)'
" || return 1

    # Verify canonical file was NOT actually written
    [ ! -f "$canonical_file" ]

    # Verify .promoted sentinel was NOT created
    [ ! -f "$output_dir/.promoted" ]
}

# ──────────────────────────────────────────────────────────────────────────────
# Test 11: No eligible files (empty files_written)
# ──────────────────────────────────────────────────────────────────────────────
@test "no eligible files: empty files_written array → .promoted sentinel written, exit 0" {
    local output_dir="$BATS_TEST_TMPDIR/projects/test-11/memory/_dream-output-011"
    mkdir -p "$output_dir"

    cat > "$output_dir/_dream-manifest.json" <<'EOF'
{
  "run_id": "run-011",
  "created_at": "2026-07-08T10:00:00Z",
  "files_written": [],
  "files_unchanged": []
}
EOF

    sqlite3 "$CAST_DB_PATH" <<EOF
INSERT INTO memory_consolidation_runs
  (run_id, project_id, status, output_path, completed_at, candidates_written)
VALUES
  ('run-011', 'test-project-11', 'completed', '$output_dir', '2026-07-08T10:00:00Z', 0);
EOF

    run python3 "$SCRIPT" --run-id run-011 --db "$CAST_DB_PATH"
    assert_success

    # Verify .promoted sentinel is written (fully promoted with 0 files)
    [ -f "$output_dir/.promoted" ]

    echo "$output" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert d['promoted_count'] == 0, 'promoted_count should be 0'
assert d['conflict_count'] == 0, 'conflict_count should be 0'
" || return 1
}

# ──────────────────────────────────────────────────────────────────────────────
# Test 12: Partial promotion (.partial sentinel for skipped files)
# ──────────────────────────────────────────────────────────────────────────────
@test "partial promotion: some files promoted, some skipped → .partial sentinel written, exit 0" {
    local output_dir="$BATS_TEST_TMPDIR/projects/test-12/memory/_dream-output-012"
    local canonical_dir="$BATS_TEST_TMPDIR/projects/test-12/memory"
    mkdir -p "$output_dir" "$canonical_dir"

    # Create one valid candidate that will be promoted
    local candidate_file1="$output_dir/valid.md"
    echo "# Valid content" > "$candidate_file1"
    local canonical_file1="$canonical_dir/valid.md"

    # Create one candidate that doesn't exist (will be skipped)
    local candidate_file2="$output_dir/missing.md"  # Don't create it
    local canonical_file2="$canonical_dir/missing.md"

    cat > "$output_dir/_dream-manifest.json" <<EOF
{
  "run_id": "run-012",
  "created_at": "2026-07-08T10:00:00Z",
  "files_written": [
    {
      "name": "valid.md",
      "candidate_path": "$candidate_file1",
      "canonical_path": "$canonical_file1",
      "pre_sha256": ""
    },
    {
      "name": "missing.md",
      "candidate_path": "$candidate_file2",
      "canonical_path": "$canonical_file2",
      "pre_sha256": ""
    }
  ],
  "files_unchanged": []
}
EOF

    sqlite3 "$CAST_DB_PATH" <<EOF
INSERT INTO memory_consolidation_runs
  (run_id, project_id, status, output_path, completed_at, candidates_written)
VALUES
  ('run-012', 'test-project-12', 'completed', '$output_dir', '2026-07-08T10:00:00Z', 2);
EOF

    run python3 "$SCRIPT" --run-id run-012 --db "$CAST_DB_PATH"
    assert_success

    # Verify .partial sentinel (not .promoted) was written
    [ -f "$output_dir/.partial" ]
    [ ! -f "$output_dir/.promoted" ]

    echo "$output" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert d['promoted_count'] == 1, f'should have 1 promoted, got {d[\"promoted_count\"]}'
assert d['skipped_count'] == 1, f'should have 1 skipped, got {d[\"skipped_count\"]}'
" || return 1

    # Verify the valid file was promoted
    [ -f "$canonical_file1" ]
    # Verify the missing file was not created
    [ ! -f "$canonical_file2" ]
}

# ──────────────────────────────────────────────────────────────────────────────
# Test 13: cast.db does not exist
# ──────────────────────────────────────────────────────────────────────────────
@test "cast.db not found at specified path → JSON error, exit 1" {
    local nonexistent_db="/nonexistent/path/cast.db"

    run python3 "$SCRIPT" --run-id run-test --db "$nonexistent_db"
    [ "$status" -eq 1 ]

    echo "$output" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert 'error' in d, 'output missing error field'
assert 'cast.db' in d['error'] or 'not found' in d['error'].lower(), 'error should mention cast.db'
" || return 1
}

# ──────────────────────────────────────────────────────────────────────────────
# Test 14: Missing candidate file (candidate_path does not exist)
# ──────────────────────────────────────────────────────────────────────────────
@test "candidate file missing: skipped with reason in output" {
    local output_dir="$BATS_TEST_TMPDIR/projects/test-14/memory/_dream-output-014"
    local canonical_dir="$BATS_TEST_TMPDIR/projects/test-14/memory"
    mkdir -p "$output_dir" "$canonical_dir"

    # Don't create the candidate file
    local candidate_file="$output_dir/nonexistent.md"
    local canonical_file="$canonical_dir/nonexistent.md"

    cat > "$output_dir/_dream-manifest.json" <<EOF
{
  "run_id": "run-014",
  "created_at": "2026-07-08T10:00:00Z",
  "files_written": [
    {
      "name": "nonexistent.md",
      "candidate_path": "$candidate_file",
      "canonical_path": "$canonical_file",
      "pre_sha256": ""
    }
  ],
  "files_unchanged": []
}
EOF

    sqlite3 "$CAST_DB_PATH" <<EOF
INSERT INTO memory_consolidation_runs
  (run_id, project_id, status, output_path, completed_at, candidates_written)
VALUES
  ('run-014', 'test-project-14', 'completed', '$output_dir', '2026-07-08T10:00:00Z', 1);
EOF

    run python3 "$SCRIPT" --run-id run-014 --db "$CAST_DB_PATH"
    # Exit 0 with partial promotion (some skipped, none promoted)
    [ "$status" -eq 0 ]

    echo "$output" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert d['skipped_count'] == 1, 'should have 1 skipped entry'
assert d['promoted_count'] == 0, 'should have 0 promoted'
assert len(d.get('skipped', [])) > 0, 'skipped array should have entries'
" || return 1
}

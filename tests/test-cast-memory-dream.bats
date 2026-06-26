#!/usr/bin/env bats
# test-cast-memory-dream.bats — BATS tests for cast-memory-dream.py and friends
#
# Tests (11 total):
#   1. Migration idempotency
#   2. Orient phase (dry-run) — memory_files_read >= 3
#   3. No canonical mutation — fixture .md files unchanged after full run
#   4. Output isolation — _dream-output-*/ dir + _dream-manifest.json keys
#   5. DB row lifecycle — completed row with matching run_id
#   6. Cancel semantics — status='canceled', output dir preserved
#   7. SHA precondition on promote — conflict reported, canonical file not overwritten
#   8-10. _build_memory_index byte-budget enforcement (MEMORY_INDEX_MAX_BYTES = 23000)
#   11. _build_memory_index robustness — no crash on malformed candidates (missing keys)

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
DREAM_SCRIPT="$REPO_DIR/scripts/cast-memory-dream.py"
MIGRATION_SCRIPT="$REPO_DIR/scripts/cast-memory-dream-migration.py"
PROMOTE_SCRIPT="$REPO_DIR/scripts/cast-memory-dream-promote.py"

FIXTURE_MEMORY_DIR="$REPO_DIR/tests/fixtures/dream-memory"
FIXTURE_TRANSCRIPTS_DIR="$REPO_DIR/tests/fixtures/dream-transcripts"

# Shared state populated by setup(); used by all tests
TEST_PROJECT_ID="test-dream-project"

setup() {
    # DB isolation — never touch real ~/.claude/cast.db
    export CAST_DB_PATH="$BATS_TEST_TMPDIR/cast.db"

    # Project dir isolation — never touch real ~/.claude/projects/
    export CLAUDE_PROJECTS_DIR="$BATS_TEST_TMPDIR/projects"

    # Create isolated memory dir mirroring the fixtures
    TEST_MEMORY_DIR="$BATS_TEST_TMPDIR/projects/$TEST_PROJECT_ID/memory"
    mkdir -p "$TEST_MEMORY_DIR"
    cp "$FIXTURE_MEMORY_DIR/"*.md "$TEST_MEMORY_DIR/"

    # Copy JSONL transcripts into the project dir (not inside memory/)
    cp "$FIXTURE_TRANSCRIPTS_DIR/"*.jsonl "$BATS_TEST_TMPDIR/projects/$TEST_PROJECT_ID/"

    # Run migration so the DB schema is ready
    python3 "$MIGRATION_SCRIPT" --db "$CAST_DB_PATH" >/dev/null
}

teardown() {
    unset CAST_DB_PATH
    unset CLAUDE_PROJECTS_DIR
}

# ──────────────────────────────────────────────────────────────────────────────
# Test 1: Migration idempotency
# ──────────────────────────────────────────────────────────────────────────────
@test "migration idempotency: table exists after two runs; column count is 14" {
    local fresh_db="$BATS_TEST_TMPDIR/idem_test.db"

    # First run
    run python3 "$MIGRATION_SCRIPT" --db "$fresh_db"
    assert_success

    # Second run — must succeed without error
    run python3 "$MIGRATION_SCRIPT" --db "$fresh_db"
    assert_success

    # Verify table exists
    table_check=$(sqlite3 "$fresh_db" "SELECT name FROM sqlite_master WHERE type='table' AND name='memory_consolidation_runs';" 2>/dev/null)
    [ "$table_check" = "memory_consolidation_runs" ]

    # Verify column count is 14
    col_count=$(sqlite3 "$fresh_db" "SELECT COUNT(*) FROM pragma_table_info('memory_consolidation_runs');" 2>/dev/null | tr -d ' ')
    [ "$col_count" -eq 14 ]
}

# ──────────────────────────────────────────────────────────────────────────────
# Test 2: Orient phase (dry-run) — memory_files_read >= 3
# ──────────────────────────────────────────────────────────────────────────────
@test "orient phase dry-run: JSON output has memory_files_read >= 3" {
    run python3 "$DREAM_SCRIPT" \
        --project-id "$TEST_PROJECT_ID" \
        --transcripts-since "2026-05-01" \
        --dry-run

    assert_success

    # Parse JSON and check memory_files_read (last line is JSON; earlier lines may be stderr warnings)
    files_read=$(echo "$output" | grep '^{' | tail -1 | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(d['memory_files_read'])
")
    [ "$files_read" -ge 3 ]
}

# ──────────────────────────────────────────────────────────────────────────────
# Test 3: No canonical mutation — fixture .md files unchanged after full run
# ──────────────────────────────────────────────────────────────────────────────
@test "no canonical mutation: fixture memory .md files are byte-identical before and after full run" {
    local mem_dir="$BATS_TEST_TMPDIR/projects/$TEST_PROJECT_ID/memory"
    local before_file="$BATS_TEST_TMPDIR/sha-before.txt"
    local after_file="$BATS_TEST_TMPDIR/sha-after.txt"

    # Capture sorted SHA-256 of every .md file in the canonical memory dir.
    # Excludes _dream-output-* subdirs because the glob doesn't recurse.
    ( cd "$mem_dir" && shasum -a 256 *.md 2>/dev/null | sort ) > "$before_file"

    run python3 "$DREAM_SCRIPT" \
        --project-id "$TEST_PROJECT_ID" \
        --transcripts-since "2026-05-01"

    assert_success

    ( cd "$mem_dir" && shasum -a 256 *.md 2>/dev/null | sort ) > "$after_file"

    # Test passes iff before and after are byte-identical.
    diff "$before_file" "$after_file"
}

# ──────────────────────────────────────────────────────────────────────────────
# Test 4: Output isolation — _dream-output-*/ dir exists + manifest has required keys
# ──────────────────────────────────────────────────────────────────────────────
@test "output isolation: exactly one _dream-output-* subdir exists with valid _dream-manifest.json" {
    local mem_dir="$BATS_TEST_TMPDIR/projects/$TEST_PROJECT_ID/memory"

    run python3 "$DREAM_SCRIPT" \
        --project-id "$TEST_PROJECT_ID" \
        --transcripts-since "2026-05-01"

    assert_success

    # Count _dream-output-* subdirs
    output_dir_count=$(find "$mem_dir" -maxdepth 1 -type d -name '_dream-output-*' | wc -l | tr -d ' ')
    [ "$output_dir_count" -eq 1 ]

    # Find the single output dir
    output_dir=$(find "$mem_dir" -maxdepth 1 -type d -name '_dream-output-*' | head -1)
    manifest="$output_dir/_dream-manifest.json"
    [ -f "$manifest" ]

    # Parse manifest and assert required keys exist
    python3 - "$manifest" <<'PYEOF'
import json, sys
path = sys.argv[1]
with open(path) as f:
    d = json.load(f)
required = ['run_id', 'created_at', 'memory_dir_sha_at_dream_start', 'files_written', 'files_unchanged']
missing = [k for k in required if k not in d]
if missing:
    print(f"Missing keys: {missing}", file=sys.stderr)
    sys.exit(1)
print("manifest ok")
PYEOF
}

# ──────────────────────────────────────────────────────────────────────────────
# Test 5: DB row lifecycle — completed row with matching run_id
# ──────────────────────────────────────────────────────────────────────────────
@test "DB row lifecycle: completed row in memory_consolidation_runs with matching run_id" {
    run python3 "$DREAM_SCRIPT" \
        --project-id "$TEST_PROJECT_ID" \
        --transcripts-since "2026-05-01"

    assert_success

    # Extract run_id from stdout JSON (last JSON line; earlier lines may be stderr warnings)
    run_id=$(echo "$output" | grep '^{' | tail -1 | python3 -c "import json,sys; print(json.load(sys.stdin)['run_id'])")
    [ -n "$run_id" ]

    # Query DB for completed row with matching run_id
    db_status=$(sqlite3 "$CAST_DB_PATH" \
        "SELECT status FROM memory_consolidation_runs WHERE run_id='$run_id';" 2>/dev/null)
    [ "$db_status" = "completed" ]
}

# ──────────────────────────────────────────────────────────────────────────────
# Test 6: Cancel semantics
# ──────────────────────────────────────────────────────────────────────────────
@test "cancel semantics: status=canceled in DB; output dir preserved if present" {
    # Do a full run first to get a run_id and output dir
    run python3 "$DREAM_SCRIPT" \
        --project-id "$TEST_PROJECT_ID" \
        --transcripts-since "2026-05-01"

    assert_success

    run_id=$(echo "$output" | grep '^{' | tail -1 | python3 -c "import json,sys; print(json.load(sys.stdin)['run_id'])")
    [ -n "$run_id" ]

    output_dir_json=$(echo "$output" | grep '^{' | tail -1 | python3 -c "import json,sys; print(json.load(sys.stdin).get('output_dir',''))")

    # Cancel the run
    run python3 "$DREAM_SCRIPT" --cancel "$run_id"
    assert_success

    # Verify status is 'canceled' in DB
    db_status=$(sqlite3 "$CAST_DB_PATH" \
        "SELECT status FROM memory_consolidation_runs WHERE run_id='$run_id';" 2>/dev/null)
    [ "$db_status" = "canceled" ]

    # Verify output dir is preserved (if it was created)
    if [ -n "$output_dir_json" ] && [ "$output_dir_json" != "None" ]; then
        [ -d "$output_dir_json" ]
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# Test 7: SHA precondition on promote
# ──────────────────────────────────────────────────────────────────────────────
@test "SHA precondition on promote: conflict reported and canonical file not overwritten when SHA mismatches" {
    local mem_dir="$BATS_TEST_TMPDIR/projects/$TEST_PROJECT_ID/memory"

    # Step A: Full dream run
    run python3 "$DREAM_SCRIPT" \
        --project-id "$TEST_PROJECT_ID" \
        --transcripts-since "2026-05-01"

    assert_success

    run_id=$(echo "$output" | grep '^{' | tail -1 | python3 -c "import json,sys; print(json.load(sys.stdin)['run_id'])")
    [ -n "$run_id" ]

    # Step B: Find the output dir and manifest
    output_dir=$(find "$mem_dir" -maxdepth 1 -type d -name '_dream-output-*' | head -1)
    manifest="$output_dir/_dream-manifest.json"
    [ -f "$manifest" ]

    # Step C: Find a file in files_written from the manifest, modify the canonical version
    target_canonical=$(python3 - "$manifest" <<'PYEOF'
import json, sys
path = sys.argv[1]
with open(path) as f:
    d = json.load(f)
fw = d.get('files_written', [])
# Pick first entry that has a canonical_path (skip MEMORY.md for simplicity)
for entry in fw:
    name = entry.get('name', '')
    canonical = entry.get('canonical_path', '')
    if name != 'MEMORY.md' and canonical:
        print(canonical)
        sys.exit(0)
# Fallback: try MEMORY.md
for entry in fw:
    canonical = entry.get('canonical_path', '')
    if canonical:
        print(canonical)
        sys.exit(0)
sys.exit(1)
PYEOF
)

    # If no files_written, force-modify user_test_c.md which is always in the fixture
    if [ -z "$target_canonical" ]; then
        target_canonical="$mem_dir/user_test_c.md"
    fi

    [ -n "$target_canonical" ]

    # Record original content for assertion
    original_content=$(cat "$target_canonical")

    # Modify the canonical file so its SHA differs from what the manifest recorded
    echo "# Modified after dream — SHA precondition test" >> "$target_canonical"

    # Step D: Run promote — should detect conflict
    run python3 "$PROMOTE_SCRIPT" --run-id "$run_id" --db "$CAST_DB_PATH"
    # Exit code 2 means promotion_conflicts exist; that's correct
    [ "$status" -eq 2 ] || [ "$status" -eq 0 ]

    # Assert promotion_conflicts is non-empty in output
    conflicts=$(echo "$output" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(len(d.get('promotion_conflicts', [])))
")
    [ "$conflicts" -ge 1 ]

    # Assert canonical file was NOT overwritten (still has our appended line)
    current_content=$(cat "$target_canonical")
    [[ "$current_content" == *"SHA precondition test"* ]]
}

# ──────────────────────────────────────────────────────────────────────────────
# Tests 8-10: _build_memory_index byte-budget enforcement
# Claude Code's native auto-load limit for MEMORY.md is ~24.4 KB (24576 bytes).
# The function must enforce a hard MEMORY_INDEX_MAX_BYTES = 23000 byte budget.
# ──────────────────────────────────────────────────────────────────────────────

# Helper: build a synthetic candidates list via Python and call _build_memory_index.
# Usage: call from inside a @test block; result is in $output.
_make_candidates_script() {
    local n_entries="$1"
    local types="$2"          # e.g. "user,feedback,other"
    local desc_len="$3"       # length of description string per entry
    cat <<PYEOF
import sys, importlib.util, pathlib

repo = pathlib.Path("$REPO_DIR")
spec = importlib.util.spec_from_file_location(
    "cast_memory_dream",
    str(repo / "scripts" / "cast-memory-dream.py"),
)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

types_cycle = "$types".split(',')
n = $n_entries
desc = "x" * $desc_len
candidates = []
for i in range(n):
    t = types_cycle[i % len(types_cycle)]
    candidates.append({
        'filename': f'entry_{i:04d}.md',
        'frontmatter': {
            'name': f'entry-{i:04d}',
            'description': desc,
            'type': t,
        },
        'raw': '',
        'changed': False,
        'pre_sha256': '',
        'source_path': '',
    })

result = mod._build_memory_index(candidates)
sys.stdout.write(result)
PYEOF
}

@test "byte budget: _build_memory_index output is always <= MEMORY_INDEX_MAX_BYTES bytes with many long-description candidates" {
    # 150 entries with 200-char descriptions: well over 23000 bytes if uncapped by lines
    local script
    script=$(_make_candidates_script 150 "user,feedback,reference,other" 200)

    run python3 -c "$script"
    assert_success

    byte_len=$(printf '%s' "$output" | wc -c | tr -d ' ')
    [ "$byte_len" -le 23000 ]
}

@test "byte budget: footer with correct omitted-count appears when entries are spilled" {
    # 200 entries with 200-char descriptions — forces spillage
    local script
    script=$(_make_candidates_script 200 "user,feedback" 200)

    run python3 -c "$script"
    assert_success

    # Footer must mention the byte budget constant
    [[ "$output" == *"23000-byte auto-load budget"* ]]

    # The omitted-count must be a positive integer in the footer line
    omitted=$(echo "$output" | grep -o '^> [0-9]* lower-priority' | grep -o '[0-9]*' | head -1)
    [ -n "$omitted" ]
    [ "$omitted" -gt 0 ]

    # Total byte length is still within budget
    byte_len=$(printf '%s' "$output" | wc -c | tr -d ' ')
    [ "$byte_len" -le 23000 ]
}

@test "byte budget: highest-priority sections (user/goals/project) survive when low-priority entries are spilled" {
    # Mix: 5 user + 5 goals + 5 project (high pri) + 100 feedback (low pri, long desc)
    # Only feedback entries should be dropped
    local script
    script=$(cat <<PYEOF
import sys, importlib.util, pathlib

repo = pathlib.Path("$REPO_DIR")
spec = importlib.util.spec_from_file_location(
    "cast_memory_dream",
    str(repo / "scripts" / "cast-memory-dream.py"),
)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

candidates = []
# 5 user entries (highest priority)
for i in range(5):
    candidates.append({
        'filename': f'user_{i}.md',
        'frontmatter': {'name': f'user-entry-{i}', 'description': 'short', 'type': 'user'},
        'raw': '', 'changed': False, 'pre_sha256': '', 'source_path': '',
    })
# 5 goals entries
for i in range(5):
    candidates.append({
        'filename': f'goals_{i}.md',
        'frontmatter': {'name': f'goals-entry-{i}', 'description': 'short', 'type': 'goals'},
        'raw': '', 'changed': False, 'pre_sha256': '', 'source_path': '',
    })
# 5 project entries
for i in range(5):
    candidates.append({
        'filename': f'project_{i}.md',
        'frontmatter': {'name': f'project-entry-{i}', 'description': 'short', 'type': 'project'},
        'raw': '', 'changed': False, 'pre_sha256': '', 'source_path': '',
    })
# 200 feedback entries with long descriptions (low priority, will be spilled)
for i in range(200):
    candidates.append({
        'filename': f'feedback_{i}.md',
        'frontmatter': {'name': f'feedback-entry-{i}', 'description': 'z' * 200, 'type': 'feedback'},
        'raw': '', 'changed': False, 'pre_sha256': '', 'source_path': '',
    })

result = mod._build_memory_index(candidates)
sys.stdout.write(result)
PYEOF
)

    run python3 -c "$script"
    assert_success

    # All 5 user entries must appear in the output
    for i in 0 1 2 3 4; do
        [[ "$output" == *"user-entry-${i}"* ]]
    done

    # All 5 goals entries must appear
    for i in 0 1 2 3 4; do
        [[ "$output" == *"goals-entry-${i}"* ]]
    done

    # All 5 project entries must appear
    for i in 0 1 2 3 4; do
        [[ "$output" == *"project-entry-${i}"* ]]
    done

    # Footer must appear (feedback entries were spilled)
    [[ "$output" == *"lower-priority entries omitted"* ]]

    # Total byte length is still within budget
    byte_len=$(printf '%s' "$output" | wc -c | tr -d ' ')
    [ "$byte_len" -le 23000 ]
}

# ──────────────────────────────────────────────────────────────────────────────
# Test 11: _build_memory_index is robust to malformed candidates (missing keys)
# ──────────────────────────────────────────────────────────────────────────────
@test "robustness: _build_memory_index does not crash on candidates missing frontmatter or filename" {
    run python3 -c "
import importlib.util, pathlib, sys

repo = pathlib.Path('$REPO_DIR')
spec = importlib.util.spec_from_file_location(
    'cast_memory_dream',
    str(repo / 'scripts' / 'cast-memory-dream.py'),
)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

candidates = [
    # Missing both 'frontmatter' and 'filename'
    {},
    # Has 'filename' but no 'frontmatter'
    {'filename': 'orphan.md', 'raw': '', 'changed': False, 'pre_sha256': '', 'source_path': ''},
    # Has 'frontmatter' but no 'filename'
    {'frontmatter': {'name': 'no-file', 'description': 'desc', 'type': 'project'}, 'raw': '', 'changed': False, 'pre_sha256': '', 'source_path': ''},
    # Fully valid entry to confirm non-malformed ones still appear
    {'filename': 'good.md', 'frontmatter': {'name': 'good-entry', 'description': 'ok', 'type': 'user'}, 'raw': '', 'changed': False, 'pre_sha256': '', 'source_path': ''},
]
result = mod._build_memory_index(candidates)
sys.stdout.write(result)
"
    assert_success
    # Valid entry must appear; malformed ones are silently defaulted, not crashing
    [[ "$output" == *"good-entry"* ]]
    # Result must be a non-empty string starting with the MEMORY.md header
    [[ "$output" == *"# CAST Project Memory"* ]]
}

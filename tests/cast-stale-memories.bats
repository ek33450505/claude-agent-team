#!/usr/bin/env bats
# cast-stale-memories.bats — BATS tests for scripts/cast-stale-memories.py
#
# Tests the canonical stale-memory scanner:
# - Counts files with old verified_at and concrete references
# - Parser handles indented verified_at (YAML frontmatter under metadata:)
# - Skips MEMORY.md index files
# - Handles missing/empty directories gracefully
# - Reports age_days correctly

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'
load 'helpers/setup'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_DIR/scripts/cast-stale-memories.py"

setup() {
    setup_temp_home
    export CAST_MEMORIES_BASE_DIR="$HOME/.cast-test-memories"
    mkdir -p "$CAST_MEMORIES_BASE_DIR"
}

teardown() {
    teardown_temp_home
}

# ──────────────────────────────────────────────────────────────────────────────
# Test 1: Counts a file with old verified_at as stale
# ──────────────────────────────────────────────────────────────────────────────
@test "counts a file with verified_at > STALE_DAYS as stale when it has concrete references" {
    # Create a project directory with memory subdirectory
    local proj_dir="$CAST_MEMORIES_BASE_DIR/test-project-1/memory"
    mkdir -p "$proj_dir"

    # Create a memory file with verified_at 31 days ago and concrete references
    cat > "$proj_dir/old-feedback.md" <<'EOF'
---
name: old-feedback-test
metadata:
  verified_at: 2026-06-08
---

This feedback discusses the `/scripts/cast-events.sh` hook.
EOF

    run env CAST_STALE_DAYS=30 python3 "$SCRIPT"
    assert_success

    # First line is the count
    stale_count=$(echo "$output" | head -1)
    [ "$stale_count" = "1" ]

    # Second line should be the file entry
    assert_line --index 1 --partial "old-feedback.md"
}

# ──────────────────────────────────────────────────────────────────────────────
# Test 2: CRITICAL REGRESSION — parser handles indented verified_at under metadata:
# ──────────────────────────────────────────────────────────────────────────────
@test "parser strips whitespace and finds verified_at indented under metadata: (regression test)" {
    local proj_dir="$CAST_MEMORIES_BASE_DIR/test-project-2/memory"
    mkdir -p "$proj_dir"

    # Fixture with verified_at INDENTED under metadata: (real format)
    cat > "$proj_dir/indented-metadata.md" <<'EOF'
---
name: indented-test
metadata:
  verified_at: 2026-06-07
---

This memory discusses ~/.claude/cast.db location.
EOF

    run env CAST_STALE_DAYS=30 python3 "$SCRIPT"
    assert_success

    stale_count=$(echo "$output" | head -1)
    # Should find 1 stale file (31+ days old with indentation)
    [ "$stale_count" = "1" ]
    assert_line --index 1 --partial "indented-metadata.md"
}

# ──────────────────────────────────────────────────────────────────────────────
# Test 3: Skips MEMORY.md index files
# ──────────────────────────────────────────────────────────────────────────────
@test "skips MEMORY.md index files even if they have old verified_at" {
    local proj_dir="$CAST_MEMORIES_BASE_DIR/test-project-3/memory"
    mkdir -p "$proj_dir"

    # Create MEMORY.md index file with old verified_at and concrete references
    cat > "$proj_dir/MEMORY.md" <<'EOF'
---
name: memory-index
metadata:
  verified_at: 2026-06-07
---

- [Feedback entry](/scripts/something)
- [Reference](/~/.claude/config)
EOF

    # Also create a regular stale file to confirm we count others
    cat > "$proj_dir/regular-stale.md" <<'EOF'
---
name: regular-entry
metadata:
  verified_at: 2026-06-07
---

Talks about --some-flag in the codebase.
EOF

    run env CAST_STALE_DAYS=30 python3 "$SCRIPT"
    assert_success

    stale_count=$(echo "$output" | head -1)
    # Should count 1 (regular-stale.md), NOT MEMORY.md
    [ "$stale_count" = "1" ]
    assert_line --index 1 --partial "regular-stale.md"

    # Verify MEMORY.md is NOT in any output line
    ! echo "$output" | grep -q "MEMORY.md"
}

# ──────────────────────────────────────────────────────────────────────────────
# Test 4: Empty/missing directory returns 0, exit 0
# ──────────────────────────────────────────────────────────────────────────────
@test "empty/missing CAST_MEMORIES_BASE_DIR returns count=0, exit 0" {
    # Use a non-existent directory
    run env CAST_MEMORIES_BASE_DIR="$HOME/.cast-nonexistent" python3 "$SCRIPT"
    assert_success

    # Should output 0 on first line
    assert_line --index 0 "0"

    # No additional lines
    line_count=$(echo "$output" | wc -l | tr -d ' ')
    [ "$line_count" = "1" ]
}

# ──────────────────────────────────────────────────────────────────────────────
# Test 5: File with no verified_at is skipped (not counted as stale)
# ──────────────────────────────────────────────────────────────────────────────
@test "file with no verified_at in frontmatter is skipped" {
    local proj_dir="$CAST_MEMORIES_BASE_DIR/test-project-5/memory"
    mkdir -p "$proj_dir"

    # Create file with NO verified_at but WITH concrete references
    cat > "$proj_dir/no-verified-at.md" <<'EOF'
---
name: unverified-entry
type: feedback
---

This discusses ~/\.claude/logs/hook-errors.log but has no verified_at.
EOF

    run python3 "$SCRIPT"
    assert_success

    stale_count=$(echo "$output" | head -1)
    # Should be 0 — no verified_at means not counted
    [ "$stale_count" = "0" ]
}

# ──────────────────────────────────────────────────────────────────────────────
# Test 6: File with concrete references but recent verified_at is not stale
# ──────────────────────────────────────────────────────────────────────────────
@test "file with recent verified_at is not counted as stale" {
    local proj_dir="$CAST_MEMORIES_BASE_DIR/test-project-6/memory"
    mkdir -p "$proj_dir"

    # Create file with TODAY's verified_at and concrete references
    local today
    today=$(date +%Y-%m-%d)
    cat > "$proj_dir/recent.md" <<EOF
---
name: recent-entry
metadata:
  verified_at: $today
---

Discusses /scripts/cast-push.sh and other paths.
EOF

    run env CAST_STALE_DAYS=30 python3 "$SCRIPT"
    assert_success

    stale_count=$(echo "$output" | head -1)
    [ "$stale_count" = "0" ]
}

# ──────────────────────────────────────────────────────────────────────────────
# Test 7: File without concrete references is skipped even if old
# ──────────────────────────────────────────────────────────────────────────────
@test "file with old verified_at but NO concrete references is skipped" {
    local proj_dir="$CAST_MEMORIES_BASE_DIR/test-project-7/memory"
    mkdir -p "$proj_dir"

    # Create file with old verified_at but NO concrete references (just prose)
    cat > "$proj_dir/abstract.md" <<'EOF'
---
name: abstract-entry
metadata:
  verified_at: 2026-06-07
---

This is an abstract comment without any concrete paths or function calls.
Just general thoughts on the system.
EOF

    run env CAST_STALE_DAYS=30 python3 "$SCRIPT"
    assert_success

    stale_count=$(echo "$output" | head -1)
    # Should be 0 — no concrete references means not counted
    [ "$stale_count" = "0" ]
}

# ──────────────────────────────────────────────────────────────────────────────
# Test 8: Multiple stale files are reported in output
# ──────────────────────────────────────────────────────────────────────────────
@test "reports multiple stale files, one per line" {
    local proj_dir="$CAST_MEMORIES_BASE_DIR/test-project-8/memory"
    mkdir -p "$proj_dir"

    # Create three stale files with old verified_at
    for i in 1 2 3; do
        cat > "$proj_dir/stale-$i.md" <<EOF
---
name: stale-entry-$i
metadata:
  verified_at: 2026-06-08
---

Entry $i discusses /scripts/some-path.sh location.
EOF
    done

    run env CAST_STALE_DAYS=30 python3 "$SCRIPT"
    assert_success

    stale_count=$(echo "$output" | head -1)
    [ "$stale_count" = "3" ]

    # Verify all three are reported (order may vary)
    assert_line --index 1 --partial "stale-1.md"
    assert_line --index 2 --partial "stale-2.md"
    assert_line --index 3 --partial "stale-3.md"
}

# ──────────────────────────────────────────────────────────────────────────────
# Test 9: Output format is pipe-separated (filepath|verified_at|age_days)
# ──────────────────────────────────────────────────────────────────────────────
@test "output format for each stale file is filepath|verified_at|age_days" {
    local proj_dir="$CAST_MEMORIES_BASE_DIR/test-project-9/memory"
    mkdir -p "$proj_dir"

    cat > "$proj_dir/format-test.md" <<'EOF'
---
name: format-test
metadata:
  verified_at: 2026-06-07
---

Tests the ~/.claude/config structure with --verbose flag.
EOF

    run env CAST_STALE_DAYS=30 python3 "$SCRIPT"
    assert_success

    # Second line should be pipe-delimited
    output_line=$(echo "$output" | head -2 | tail -1)
    # Should contain two pipes: filepath|date|age
    pipe_count=$(printf '%s' "$output_line" | grep -o '|' | wc -l | tr -d ' ')
    [ "$pipe_count" = "2" ]
}

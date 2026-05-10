#!/usr/bin/env bats
# Tests for cast-memory-review.sh
# Phase 4.8.2: pending memory review queue

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_DIR/scripts/cast-memory-review.sh"

setup() {
  TEST_HOME="/tmp/test-cast-memory-review-$$"
  mkdir -p "$TEST_HOME/.claude/projects/proj-a/memory/_pending"
  mkdir -p "$TEST_HOME/.claude/projects/proj-b/memory/_pending"
  mkdir -p "$TEST_HOME/.claude/projects/proj-c/memory"

  # Create pending memories in proj-a
  cat > "$TEST_HOME/.claude/projects/proj-a/memory/_pending/foo.md" << 'EOF'
---
name: foo memory
description: A foo test memory
type: feedback
---

This is a test memory with foo content.
EOF

  cat > "$TEST_HOME/.claude/projects/proj-a/memory/_pending/bar.md" << 'EOF'
---
name: bar memory
description: A bar test memory
type: reference
---

This is a test memory with bar content.
EOF

  # Create pending memory in proj-b
  cat > "$TEST_HOME/.claude/projects/proj-b/memory/_pending/baz.md" << 'EOF'
---
name: baz memory
description: A baz test memory
type: project
---

This is a test memory with baz content.
EOF

  # Create canonical memory in proj-c (should not be listed in pending)
  cat > "$TEST_HOME/.claude/projects/proj-c/memory/canonical_only.md" << 'EOF'
---
name: canonical memory
description: A canonical memory
type: user
---

This is a canonical memory.
EOF

  # Create MEMORY.md index in proj-a
  cat > "$TEST_HOME/.claude/projects/proj-a/memory/MEMORY.md" << 'EOF'
# Memory Index

- [canonical.md](canonical.md) — an existing canonical memory
EOF

  export HOME="$TEST_HOME"
  export CLAUDE_SUBPROCESS=0
}

teardown() {
  rm -rf "$TEST_HOME"
}

# ─────────────────────────────────────────────────────────────────────────────
# Tests: --list mode
# ─────────────────────────────────────────────────────────────────────────────

@test "--list lists all pending entries across projects" {
  run bash "$SCRIPT" --list
  assert_success
  assert_output --partial "foo.md"
  assert_output --partial "bar.md"
  assert_output --partial "baz.md"
  assert_output --partial "[review] 3 pending entries"
}

@test "--list does not list canonical files" {
  run bash "$SCRIPT" --list
  assert_success
  # canonical_only.md is in proj-c/memory (not _pending), should not appear
  refute_output --partial "canonical_only"
}

@test "--list with no pending prints empty queue message" {
  # Remove all pending files
  rm -rf "$TEST_HOME/.claude/projects/proj-a/memory/_pending"
  rm -rf "$TEST_HOME/.claude/projects/proj-b/memory/_pending"

  run bash "$SCRIPT" --list
  assert_success
  assert_output "[review] no pending memories"
}

@test "--list handles missing _pending directory gracefully" {
  # Already tested above; this is extra coverage
  run bash "$SCRIPT" --list
  assert_success
}

# ─────────────────────────────────────────────────────────────────────────────
# Tests: --auto-promote mode
# ─────────────────────────────────────────────────────────────────────────────

@test "--auto-promote moves files >7 days old to canonical" {
  # Touch foo.md to be 8 days old
  touch -d "8 days ago" "$TEST_HOME/.claude/projects/proj-a/memory/_pending/foo.md" 2>/dev/null || \
    touch -t "$(date -u -d '8 days ago' +%Y%m%d%H%M.%S 2>/dev/null || date -u -v-8d +%Y%m%d%H%M.%S)" \
    "$TEST_HOME/.claude/projects/proj-a/memory/_pending/foo.md"

  run bash "$SCRIPT" --auto-promote
  assert_success
  assert_output --partial "[auto-promote] promoted 1"

  # Verify foo.md moved to canonical
  [ -f "$TEST_HOME/.claude/projects/proj-a/memory/foo.md" ]
  [ ! -f "$TEST_HOME/.claude/projects/proj-a/memory/_pending/foo.md" ]
}

@test "--auto-promote leaves <7 day files in pending" {
  run bash "$SCRIPT" --auto-promote
  assert_success
  # bar.md is fresh (just created), should stay in pending
  [ -f "$TEST_HOME/.claude/projects/proj-a/memory/_pending/bar.md" ]
}

@test "--auto-promote updates MEMORY.md index" {
  # Touch foo.md to be 8 days old
  touch -d "8 days ago" "$TEST_HOME/.claude/projects/proj-a/memory/_pending/foo.md" 2>/dev/null || \
    touch -t "$(date -u -d '8 days ago' +%Y%m%d%H%M.%S 2>/dev/null || date -u -v-8d +%Y%m%d%H%M.%S)" \
    "$TEST_HOME/.claude/projects/proj-a/memory/_pending/foo.md"

  bash "$SCRIPT" --auto-promote >/dev/null

  # Check that MEMORY.md was updated
  grep -q "foo.md" "$TEST_HOME/.claude/projects/proj-a/memory/MEMORY.md"
}

@test "--auto-promote is idempotent" {
  # Touch foo.md to be 8 days old
  touch -d "8 days ago" "$TEST_HOME/.claude/projects/proj-a/memory/_pending/foo.md" 2>/dev/null || \
    touch -t "$(date -u -d '8 days ago' +%Y%m%d%H%M.%S 2>/dev/null || date -u -v-8d +%Y%m%d%H%M.%S)" \
    "$TEST_HOME/.claude/projects/proj-a/memory/_pending/foo.md"

  # Run once
  bash "$SCRIPT" --auto-promote >/dev/null

  # Count lines in MEMORY.md
  local line_count_1
  line_count_1=$(wc -l < "$TEST_HOME/.claude/projects/proj-a/memory/MEMORY.md")

  # Run again
  bash "$SCRIPT" --auto-promote >/dev/null

  # Line count should not increase (no duplicate entries)
  local line_count_2
  line_count_2=$(wc -l < "$TEST_HOME/.claude/projects/proj-a/memory/MEMORY.md")

  [ "$line_count_1" -eq "$line_count_2" ]
}

@test "--auto-promote skips when canonical file already exists" {
  # Create canonical version of foo.md
  cat > "$TEST_HOME/.claude/projects/proj-a/memory/foo.md" << 'EOF'
---
name: foo memory canonical
description: Canonical version
type: feedback
---

This is the canonical version.
EOF

  # Touch pending foo.md to be 8 days old
  touch -d "8 days ago" "$TEST_HOME/.claude/projects/proj-a/memory/_pending/foo.md" 2>/dev/null || \
    touch -t "$(date -u -d '8 days ago' +%Y%m%d%H%M.%S 2>/dev/null || date -u -v-8d +%Y%m%d%H%M.%S)" \
    "$TEST_HOME/.claude/projects/proj-a/memory/_pending/foo.md"

  # Run auto-promote
  bash "$SCRIPT" --auto-promote >/dev/null

  # Verify pending file still exists (was not moved over canonical)
  [ -f "$TEST_HOME/.claude/projects/proj-a/memory/_pending/foo.md" ]
  # Verify canonical still exists and is unchanged
  [ -f "$TEST_HOME/.claude/projects/proj-a/memory/foo.md" ]
  grep -q "canonical version" "$TEST_HOME/.claude/projects/proj-a/memory/foo.md"
}

# ─────────────────────────────────────────────────────────────────────────────
# Tests: interactive mode (TUI simulation)
# ─────────────────────────────────────────────────────────────────────────────

@test "interactive: approve moves file to canonical and updates index" {
  # Remove bar.md so only foo.md is in queue (alphabetically)
  rm -f "$TEST_HOME/.claude/projects/proj-a/memory/_pending/bar.md"

  # Simulate user pressing 'a'
  printf "a\n" | bash "$SCRIPT" >/dev/null || true

  # Verify foo.md moved
  [ -f "$TEST_HOME/.claude/projects/proj-a/memory/foo.md" ]
  [ ! -f "$TEST_HOME/.claude/projects/proj-a/memory/_pending/foo.md" ]

  # Verify MEMORY.md was updated
  grep -q "foo.md" "$TEST_HOME/.claude/projects/proj-a/memory/MEMORY.md"
}

@test "interactive: reject deletes pending file" {
  # Remove bar.md so only foo.md is in queue (alphabetically)
  rm -f "$TEST_HOME/.claude/projects/proj-a/memory/_pending/bar.md"

  # Simulate user pressing 'r'
  printf "r\n" | bash "$SCRIPT" >/dev/null || true

  # Verify foo.md was deleted
  [ ! -f "$TEST_HOME/.claude/projects/proj-a/memory/_pending/foo.md" ]
  [ ! -f "$TEST_HOME/.claude/projects/proj-a/memory/foo.md" ]
}

@test "interactive: skip leaves file in pending" {
  # Remove bar.md so only foo.md is in queue (alphabetically)
  rm -f "$TEST_HOME/.claude/projects/proj-a/memory/_pending/bar.md"

  # Simulate user pressing 's'
  printf "s\n" | bash "$SCRIPT" >/dev/null || true

  # Verify foo.md still in pending
  [ -f "$TEST_HOME/.claude/projects/proj-a/memory/_pending/foo.md" ]
}

@test "interactive: unknown input defaults to skip" {
  # Remove bar.md so only foo.md is in queue (alphabetically)
  rm -f "$TEST_HOME/.claude/projects/proj-a/memory/_pending/bar.md"

  # Simulate user pressing 'x' (unknown)
  printf "x\n" | bash "$SCRIPT" >/dev/null || true

  # Verify foo.md still in pending
  [ -f "$TEST_HOME/.claude/projects/proj-a/memory/_pending/foo.md" ]
}

# ─────────────────────────────────────────────────────────────────────────────
# Tests: edge cases
# ─────────────────────────────────────────────────────────────────────────────

@test "handles non-existent _pending directory" {
  rm -rf "$TEST_HOME/.claude/projects/proj-a/memory/_pending"
  rm -rf "$TEST_HOME/.claude/projects/proj-b/memory/_pending"

  run bash "$SCRIPT" --list
  assert_success
  assert_output "[review] no pending memories"
}

@test "subprocess guard exits early" {
  export CLAUDE_SUBPROCESS=1
  run bash "$SCRIPT" --list
  assert_success
}

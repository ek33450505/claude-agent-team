#!/usr/bin/env bats
# cast-verify-memories.bats — BATS tests for scripts/cast-verify-memories.py
#
# CAST v10 item C6 — automated verified_at re-verification.
# Covers: skip-if-no-verified_at, skip-if-fresh, REFS-OK classify + --apply bump,
# REF-BROKEN classify + never-auto-bumped, report-only-modifies-nothing,
# indentation preservation, --apply idempotency, MEMORY.md exclusion,
# unknown-flag exit-2-no-mutation, multi-root ref resolution (bare basename,
# memory-own-dir, missing project dir), and the NO-REFS class.
#
# HARD RULE: never runs --apply against real memory data — CAST_MEMORIES_BASE_DIR
# is always a tempdir created by setup_temp_home.

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'
load 'helpers/setup'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_DIR/scripts/cast-verify-memories.py"

# Relative repo paths used as concrete refs in fixtures — resolved by
# cast-verify-memories.py's own resolver against $(pwd), which is REPO_DIR
# for the duration of the bats run (tests/run.sh cd's there before invoking bats).
REAL_REF="scripts/cast-events.sh"
FAKE_REF="scripts/cast-definitely-not-real-xyz123.sh"
# Bare basename that exists ONLY under scripts/ — not directly in REPO_DIR
# root, and not directly in $HOME — so resolving it requires the fix's
# "<root>/scripts/<basename>" joining, not the old cwd/$HOME-only check.
BARE_BASENAME="cast_db.py"

setup() {
    setup_temp_home
    export CAST_MEMORIES_BASE_DIR="$HOME/.cast-test-memories"
    mkdir -p "$CAST_MEMORIES_BASE_DIR"
    cd "$REPO_DIR"
}

teardown() {
    teardown_temp_home
}

# ──────────────────────────────────────────────────────────────────────────────
# Test 1: a file with no verified_at is skipped entirely
# ──────────────────────────────────────────────────────────────────────────────
@test "file with no verified_at is skipped entirely" {
    local proj_dir="$CAST_MEMORIES_BASE_DIR/proj-1/memory"
    mkdir -p "$proj_dir"

    cat > "$proj_dir/no-verified-at.md" <<EOF
---
name: unverified-entry
type: feedback
---

Discusses $REAL_REF but has no verified_at.
EOF

    run env CAST_STALE_DAYS=30 python3 "$SCRIPT"
    assert_success
    assert_output --partial "0 stale memories evaluated (0 REF-BROKEN, 0 REFS-OK, 0 NO-REFS)"
}

# ──────────────────────────────────────────────────────────────────────────────
# Test 2: a file verified today is not in the queue
# ──────────────────────────────────────────────────────────────────────────────
@test "file verified today is not in the stale queue" {
    local proj_dir="$CAST_MEMORIES_BASE_DIR/proj-2/memory"
    mkdir -p "$proj_dir"
    local today
    today=$(date +%Y-%m-%d)

    cat > "$proj_dir/recent.md" <<EOF
---
name: recent-entry
metadata:
  verified_at: $today
---

Discusses $REAL_REF and the --verbose flag.
EOF

    run env CAST_STALE_DAYS=30 python3 "$SCRIPT"
    assert_success
    assert_output --partial "0 stale memories evaluated (0 REF-BROKEN, 0 REFS-OK, 0 NO-REFS)"
}

# ──────────────────────────────────────────────────────────────────────────────
# Test 3: stale + all refs resolve -> REFS-OK; --apply bumps verified_at/verified_by
# ──────────────────────────────────────────────────────────────────────────────
@test "stale with resolving refs classifies REFS-OK and --apply bumps it" {
    local proj_dir="$CAST_MEMORIES_BASE_DIR/proj-3/memory"
    mkdir -p "$proj_dir"

    cat > "$proj_dir/ok.md" <<EOF
---
name: ok-entry
metadata:
  verified_at: 2026-06-08
---

Discusses $REAL_REF and the --verbose flag.
EOF

    run env CAST_STALE_DAYS=30 python3 "$SCRIPT"
    assert_success
    assert_output --partial "1 stale memories evaluated (0 REF-BROKEN, 1 REFS-OK, 0 NO-REFS)"
    refute_output --partial "REF-BROKEN:"

    run env CAST_STALE_DAYS=30 python3 "$SCRIPT" --apply
    assert_success

    local today
    today=$(date +%Y-%m-%d)
    run grep "verified_at: $today" "$proj_dir/ok.md"
    assert_success
    run grep "verified_by: cast-verify-memories.py (refs-resolved)" "$proj_dir/ok.md"
    assert_success
}

# ──────────────────────────────────────────────────────────────────────────────
# Test 4: stale + a broken ref -> REF-BROKEN, and --apply leaves it byte-identical
# ──────────────────────────────────────────────────────────────────────────────
@test "stale with a broken ref classifies REF-BROKEN and --apply never touches it" {
    local proj_dir="$CAST_MEMORIES_BASE_DIR/proj-4/memory"
    mkdir -p "$proj_dir"

    cat > "$proj_dir/broken.md" <<EOF
---
name: broken-entry
metadata:
  verified_at: 2026-06-08
---

Discusses $FAKE_REF and the --verbose flag.
EOF

    local before after
    before=$(shasum -a 256 "$proj_dir/broken.md" | awk '{print $1}')

    run env CAST_STALE_DAYS=30 python3 "$SCRIPT"
    assert_success
    assert_output --partial "1 stale memories evaluated (1 REF-BROKEN, 0 REFS-OK, 0 NO-REFS)"
    assert_output --partial "missing ref: $FAKE_REF"

    run env CAST_STALE_DAYS=30 python3 "$SCRIPT" --apply
    assert_success

    after=$(shasum -a 256 "$proj_dir/broken.md" | awk '{print $1}')
    [ "$before" = "$after" ]
}

# ──────────────────────────────────────────────────────────────────────────────
# Test 5: default (report-only) mode modifies nothing, verified by checksum
# ──────────────────────────────────────────────────────────────────────────────
@test "default report-only mode modifies no fixture" {
    local proj_dir="$CAST_MEMORIES_BASE_DIR/proj-5/memory"
    mkdir -p "$proj_dir"

    cat > "$proj_dir/ok.md" <<EOF
---
name: ok-entry
metadata:
  verified_at: 2026-06-08
---

Discusses $REAL_REF and the --verbose flag.
EOF
    cat > "$proj_dir/broken.md" <<EOF
---
name: broken-entry
metadata:
  verified_at: 2026-06-08
---

Discusses $FAKE_REF and the --verbose flag.
EOF

    local ok_before broken_before ok_after broken_after
    ok_before=$(shasum -a 256 "$proj_dir/ok.md" | awk '{print $1}')
    broken_before=$(shasum -a 256 "$proj_dir/broken.md" | awk '{print $1}')

    run env CAST_STALE_DAYS=30 python3 "$SCRIPT"
    assert_success

    ok_after=$(shasum -a 256 "$proj_dir/ok.md" | awk '{print $1}')
    broken_after=$(shasum -a 256 "$proj_dir/broken.md" | awk '{print $1}')
    [ "$ok_before" = "$ok_after" ]
    [ "$broken_before" = "$broken_after" ]
}

# ──────────────────────────────────────────────────────────────────────────────
# Test 6: indentation is preserved after a bump
# ──────────────────────────────────────────────────────────────────────────────
@test "2-space indented verified_at keeps its indentation after --apply" {
    local proj_dir="$CAST_MEMORIES_BASE_DIR/proj-6/memory"
    mkdir -p "$proj_dir"

    cat > "$proj_dir/indented.md" <<EOF
---
name: indented-entry
metadata:
  verified_at: 2026-06-08
---

Discusses $REAL_REF and the --verbose flag.
EOF

    run env CAST_STALE_DAYS=30 python3 "$SCRIPT" --apply
    assert_success

    run grep -n "verified_at:" "$proj_dir/indented.md"
    assert_success
    assert_output --partial "  verified_at:"

    run grep -n "verified_by:" "$proj_dir/indented.md"
    assert_success
    assert_output --partial "  verified_by:"
}

# ──────────────────────────────────────────────────────────────────────────────
# Test 7: --apply twice is idempotent — exactly one verified_by line
# ──────────────────────────────────────────────────────────────────────────────
@test "--apply run twice leaves exactly one verified_by line" {
    local proj_dir="$CAST_MEMORIES_BASE_DIR/proj-7/memory"
    mkdir -p "$proj_dir"

    cat > "$proj_dir/ok.md" <<EOF
---
name: ok-entry
metadata:
  verified_at: 2026-06-08
---

Discusses $REAL_REF and the --verbose flag.
EOF

    run env CAST_STALE_DAYS=30 python3 "$SCRIPT" --apply
    assert_success
    # Second run: verified_at is now today, so it's no longer stale — force it
    # stale again to exercise the idempotency path a second time.
    sed -i.bak 's/verified_at: .*/verified_at: 2026-06-08/' "$proj_dir/ok.md"
    rm -f "$proj_dir/ok.md.bak"

    run env CAST_STALE_DAYS=30 python3 "$SCRIPT" --apply
    assert_success

    local count
    count=$(grep -c "verified_by:" "$proj_dir/ok.md")
    [ "$count" = "1" ]
}

# ──────────────────────────────────────────────────────────────────────────────
# Test 8: MEMORY.md is never modified even when stale-looking
# ──────────────────────────────────────────────────────────────────────────────
@test "MEMORY.md is excluded and never modified" {
    local proj_dir="$CAST_MEMORIES_BASE_DIR/proj-8/memory"
    mkdir -p "$proj_dir"

    cat > "$proj_dir/MEMORY.md" <<EOF
---
name: memory-index
metadata:
  verified_at: 2026-06-08
---

Discusses $REAL_REF and the --verbose flag.
EOF

    local before after
    before=$(shasum -a 256 "$proj_dir/MEMORY.md" | awk '{print $1}')

    run env CAST_STALE_DAYS=30 python3 "$SCRIPT"
    assert_success
    assert_output --partial "0 stale memories evaluated (0 REF-BROKEN, 0 REFS-OK, 0 NO-REFS)"

    run env CAST_STALE_DAYS=30 python3 "$SCRIPT" --apply
    assert_success

    after=$(shasum -a 256 "$proj_dir/MEMORY.md" | awk '{print $1}')
    [ "$before" = "$after" ]
}

# ──────────────────────────────────────────────────────────────────────────────
# Test 9: an unknown flag exits 2 and modifies nothing
# ──────────────────────────────────────────────────────────────────────────────
@test "unknown flag exits 2 and modifies nothing" {
    local proj_dir="$CAST_MEMORIES_BASE_DIR/proj-9/memory"
    mkdir -p "$proj_dir"

    cat > "$proj_dir/ok.md" <<EOF
---
name: ok-entry
metadata:
  verified_at: 2026-06-08
---

Discusses $REAL_REF and the --verbose flag.
EOF

    local before after
    before=$(shasum -a 256 "$proj_dir/ok.md" | awk '{print $1}')

    run env CAST_STALE_DAYS=30 python3 "$SCRIPT" --bogus-flag
    assert_failure 2

    after=$(shasum -a 256 "$proj_dir/ok.md" | awk '{print $1}')
    [ "$before" = "$after" ]
}

# ──────────────────────────────────────────────────────────────────────────────
# Test 10 (⭐): a ref cited by BARE BASENAME that exists under a searched root
# (cwd/scripts) classifies REFS-OK, not REF-BROKEN. This is the regression
# test for the false-positive bug: the old resolver only tried the ref as
# given relative to cwd/$HOME, so "cast_db.py" (which really lives at
# scripts/cast_db.py) was wrongly reported missing.
# ──────────────────────────────────────────────────────────────────────────────
@test "bare basename resolving under a searched scripts/ root classifies REFS-OK" {
    local proj_dir="$CAST_MEMORIES_BASE_DIR/proj-10/memory"
    mkdir -p "$proj_dir"

    cat > "$proj_dir/bare-basename.md" <<EOF
---
name: bare-basename-entry
metadata:
  verified_at: 2026-06-08
---

Uses $BARE_BASENAME for DB access via the --verbose flag.
EOF

    run env CAST_STALE_DAYS=30 python3 "$SCRIPT"
    assert_success
    assert_output --partial "1 stale memories evaluated (0 REF-BROKEN, 1 REFS-OK, 0 NO-REFS)"
    refute_output --partial "missing ref: $BARE_BASENAME"
}

# ──────────────────────────────────────────────────────────────────────────────
# Test 11: a ref that resolves ONLY via the memory file's own directory
# (the MEMORY.md shape — a companion file sitting next to the memory itself)
# ──────────────────────────────────────────────────────────────────────────────
@test "ref resolving only via the memory file's own directory classifies REFS-OK" {
    local proj_dir="$CAST_MEMORIES_BASE_DIR/proj-11/memory"
    mkdir -p "$proj_dir"
    touch "$proj_dir/companion-xyz.sh"

    cat > "$proj_dir/own-dir.md" <<EOF
---
name: own-dir-entry
metadata:
  verified_at: 2026-06-08
---

See companion-xyz.sh in the same directory, and the --verbose flag.
EOF

    run env CAST_STALE_DAYS=30 python3 "$SCRIPT"
    assert_success
    assert_output --partial "1 stale memories evaluated (0 REF-BROKEN, 1 REFS-OK, 0 NO-REFS)"
    refute_output --partial "missing ref: companion-xyz.sh"
}

# ──────────────────────────────────────────────────────────────────────────────
# Test 12: a fixture whose project dir does NOT decode to a real directory
# stays REF-BROKEN — the widening must not become blanket forgiveness, and
# decode_project_dir() must not crash on an undecodable/deleted project.
# ──────────────────────────────────────────────────────────────────────────────
@test "undecodable project dir stays REF-BROKEN (true positive preserved)" {
    local proj_dir="$CAST_MEMORIES_BASE_DIR/-Nonexistent-Test-Root-Zzyzx-Project/memory"
    mkdir -p "$proj_dir"

    cat > "$proj_dir/dead-project.md" <<EOF
---
name: dead-project-entry
metadata:
  verified_at: 2026-06-08
---

References src/would-be-resolved-xyz.py and the --verbose flag.
EOF

    run env CAST_STALE_DAYS=30 python3 "$SCRIPT"
    assert_success
    assert_output --partial "1 stale memories evaluated (1 REF-BROKEN, 0 REFS-OK, 0 NO-REFS)"
    assert_output --partial "missing ref: src/would-be-resolved-xyz.py"
}

# ──────────────────────────────────────────────────────────────────────────────
# Test 13: a stale file with ZERO extractable refs classifies NO-REFS and is
# NEVER bump-eligible (a refs-resolved bump with zero evidence is a false claim)
# ──────────────────────────────────────────────────────────────────────────────
@test "zero extractable refs classifies NO-REFS and --apply never touches it" {
    local proj_dir="$CAST_MEMORIES_BASE_DIR/proj-13/memory"
    mkdir -p "$proj_dir"

    cat > "$proj_dir/no-refs.md" <<EOF
---
name: no-refs-entry
metadata:
  verified_at: 2026-06-08
---

This discusses the --verbose flag only, no file paths of any kind here.
EOF

    local before after
    before=$(shasum -a 256 "$proj_dir/no-refs.md" | awk '{print $1}')

    run env CAST_STALE_DAYS=30 python3 "$SCRIPT"
    assert_success
    assert_output --partial "1 stale memories evaluated (0 REF-BROKEN, 0 REFS-OK, 1 NO-REFS)"
    assert_output --partial "NO-REFS (not bump-eligible"

    run env CAST_STALE_DAYS=30 python3 "$SCRIPT" --apply
    assert_success

    after=$(shasum -a 256 "$proj_dir/no-refs.md" | awk '{print $1}')
    [ "$before" = "$after" ]
}

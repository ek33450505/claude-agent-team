#!/usr/bin/env bats
# cast-verify-memories.bats — BATS tests for scripts/cast-verify-memories.py
#
# CAST v10 item C6 — automated verified_at re-verification.
# Covers: skip-if-no-verified_at, skip-if-fresh, REFS-OK classify + --apply bump,
# REF-BROKEN classify + never-auto-bumped, report-only-modifies-nothing,
# indentation preservation, --apply idempotency, MEMORY.md exclusion,
# unknown-flag exit-2-no-mutation, multi-root ref resolution (bare basename,
# memory-own-dir, missing project dir), the NO-REFS class, decode_project_dir's
# underscore/dot trailing-component recovery (Change 1), the EPHEMERAL-ONLY
# class for dead session artifacts under claude/{plans, reports,
# resume-prompts,research} (Change 2), deleted-file refs staying REF-BROKEN (the git-log RETIRED
# lookup was removed), line-ending/UTF-8/mode/lost-update write safety, and
# the bare-extension extraction guard ("init/.sh/.py") (CAST v10 J-4).
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

# Creates a throwaway git repo at "$1" containing a file (basename "$2",
# default retired-fixture.sh) that is added then deleted, so the deleted-ref
# tests use REAL git history rather than a stub. Sets DELETED_SHA to the short hash of the deleting commit.
_make_retired_repo() {
    local repo_dir="$1"
    local basename="${2:-retired-fixture.sh}"
    mkdir -p "$repo_dir/scripts"
    (
        cd "$repo_dir" || exit 1
        git init -q
        cast_git_fixture_quiet
        git config user.email "bats@example.com"
        git config user.name "bats-test"
        touch "scripts/$basename"
        git add -A
        git commit -q -m "add $basename"
        git rm -q "scripts/$basename"
        git commit -q -m "remove $basename"
    )
    DELETED_SHA=$(git -C "$repo_dir" log --diff-filter=D --format='%h' -1 -- "scripts/$basename")
}

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
    assert_output --partial "0 stale memories evaluated (0 REF-BROKEN, 0 REFS-OK, 0 NO-REFS, 0 EPHEMERAL-ONLY)"
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
    assert_output --partial "0 stale memories evaluated (0 REF-BROKEN, 0 REFS-OK, 0 NO-REFS, 0 EPHEMERAL-ONLY)"
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
    assert_output --partial "1 stale memories evaluated (0 REF-BROKEN, 1 REFS-OK, 0 NO-REFS, 0 EPHEMERAL-ONLY)"
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
    assert_output --partial "1 stale memories evaluated (1 REF-BROKEN, 0 REFS-OK, 0 NO-REFS, 0 EPHEMERAL-ONLY)"
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
    assert_output --partial "0 stale memories evaluated (0 REF-BROKEN, 0 REFS-OK, 0 NO-REFS, 0 EPHEMERAL-ONLY)"

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
    assert_output --partial "1 stale memories evaluated (0 REF-BROKEN, 1 REFS-OK, 0 NO-REFS, 0 EPHEMERAL-ONLY)"
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
    assert_output --partial "1 stale memories evaluated (0 REF-BROKEN, 1 REFS-OK, 0 NO-REFS, 0 EPHEMERAL-ONLY)"
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
    assert_output --partial "1 stale memories evaluated (1 REF-BROKEN, 0 REFS-OK, 0 NO-REFS, 0 EPHEMERAL-ONLY)"
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
    assert_output --partial "1 stale memories evaluated (0 REF-BROKEN, 0 REFS-OK, 1 NO-REFS, 0 EPHEMERAL-ONLY)"
    assert_output --partial "NO-REFS (not bump-eligible"

    run env CAST_STALE_DAYS=30 python3 "$SCRIPT" --apply
    assert_success

    after=$(shasum -a 256 "$proj_dir/no-refs.md" | awk '{print $1}')
    [ "$before" = "$after" ]
}

# ──────────────────────────────────────────────────────────────────────────────
# Test 14: a `claude/`-prefixed ref (memories write these meaning ~/.claude/...)
# resolves via the dedicated claude-prefix root, not a doubled
# ~/.claude/claude/... join.
# ──────────────────────────────────────────────────────────────────────────────
@test "claude/-prefix ref resolves against \$HOME/.claude" {
    local proj_dir="$CAST_MEMORIES_BASE_DIR/proj-14/memory"
    mkdir -p "$proj_dir"
    mkdir -p "$HOME/.claude/resume-prompts"
    touch "$HOME/.claude/resume-prompts/2026-06-24-fixture.md"

    cat > "$proj_dir/claude-prefix.md" <<EOF
---
name: claude-prefix-entry
metadata:
  verified_at: 2026-06-08
---

See claude/resume-prompts/2026-06-24-fixture.md for details, plus the --verbose flag.
EOF

    run env CAST_STALE_DAYS=30 python3 "$SCRIPT"
    assert_success
    assert_output --partial "1 stale memories evaluated (0 REF-BROKEN, 1 REFS-OK, 0 NO-REFS, 0 EPHEMERAL-ONLY)"
    refute_output --partial "missing ref: claude/resume-prompts/2026-06-24-fixture.md"
}

# ──────────────────────────────────────────────────────────────────────────────
# Test 15: a bare ref with no direct root hit resolves via the LAST-RESORT
# project-git-suffix fallback (git -C <project_root> ls-files, path-suffix
# match) — "run.sh" isn't at repo root or repo/scripts/, only at
# tests/run.sh, so this can ONLY pass via the new fallback.
# ──────────────────────────────────────────────────────────────────────────────
@test "bare ref resolves via the project-git-suffix fallback (unique match)" {
    # The memory dir must DECODE to the repo (the cwd fallback no longer exists):
    # encode REPO_DIR the way Claude Code does ('/', '_' and '.' all become '-').
    local encoded
    encoded=$(printf '%s' "$REPO_DIR" | tr '/_.' '---')
    local proj_dir="$CAST_MEMORIES_BASE_DIR/$encoded/memory"
    mkdir -p "$proj_dir"

    cat > "$proj_dir/git-suffix.md" <<EOF
---
name: git-suffix-entry
metadata:
  verified_at: 2026-06-08
---

See run.sh for the test entrypoint, plus the --verbose flag.
EOF

    run env CAST_STALE_DAYS=30 python3 "$SCRIPT" --json
    assert_success
    assert_output --partial '"root": "project-git-suffix"'

    run env CAST_STALE_DAYS=30 python3 "$SCRIPT"
    assert_success
    assert_output --partial "1 stale memories evaluated (0 REF-BROKEN, 1 REFS-OK, 0 NO-REFS, 0 EPHEMERAL-ONLY)"
    refute_output --partial "missing ref: run.sh"
}

# ──────────────────────────────────────────────────────────────────────────────
# Test 16: MORE THAN ONE git-tracked file matching the suffix must NOT be
# silently picked — it stays REF-BROKEN with an "ambiguous" detail line,
# never resolved. Exercises resolve_git_suffix_ref()/get_git_tracked_files()
# directly against an isolated throwaway git repo (not the real repo tree)
# so the assertion can't drift if real-repo file layout changes.
# ──────────────────────────────────────────────────────────────────────────────
@test "ambiguous multi-hit on project-git-suffix stays REF-BROKEN, never silently picked" {
    local fake_repo="$BATS_TEST_TMPDIR/fake-repo"
    mkdir -p "$fake_repo/a" "$fake_repo/b"
    touch "$fake_repo/a/dup.md" "$fake_repo/b/dup.md"
    ( cd "$fake_repo" && git init -q && cast_git_fixture_quiet && git add -A )

    run python3 -c "
import sys
sys.path.insert(0, '$REPO_DIR/scripts')
import importlib.util
spec = importlib.util.spec_from_file_location('cvm', '$SCRIPT')
cvm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cvm)
path, candidates = cvm.resolve_git_suffix_ref('dup.md', '$fake_repo')
assert path is None, f'expected no unique resolution, got {path}'
assert candidates is not None and len(candidates) == 2, f'expected 2 ambiguous candidates, got {candidates}'
print('OK', sorted(candidates))
"
    assert_success
    assert_output --partial "OK ['a/dup.md', 'b/dup.md']"
}

# ──────────────────────────────────────────────────────────────────────────────
# Test 17 (Change 1): a project dir whose real directory name contains an
# UNDERSCORE — the Claude Code encoding flattens '_' to '-' just like '/', so
# the trailing-component decode pass must recover it. Without this pass the
# ref would stay REF-BROKEN (see mutation-tested in the dispatch report).
# ──────────────────────────────────────────────────────────────────────────────
@test "project dir with an underscore in its real name decodes and resolves" {
    local real_dir="$HOME/testproj_underscore"
    mkdir -p "$real_dir/src"
    touch "$real_dir/src/marker-us.js"

    # Only flatten the tail component WE added — $HOME itself is a
    # mktemp-generated name that must decode via pass 1 (literal-dot-inside-
    # a-segment) unchanged, so it must not be swept into this substitution.
    local encoded="${HOME//\//-}-testproj-underscore"

    local proj_dir="$CAST_MEMORIES_BASE_DIR/$encoded/memory"
    mkdir -p "$proj_dir"

    cat > "$proj_dir/underscore-project.md" <<EOF
---
name: underscore-project-entry
metadata:
  verified_at: 2026-06-08
---

References src/marker-us.js and the --verbose flag.
EOF

    run env CAST_STALE_DAYS=30 python3 "$SCRIPT"
    assert_success
    assert_output --partial "1 stale memories evaluated (0 REF-BROKEN, 1 REFS-OK, 0 NO-REFS, 0 EPHEMERAL-ONLY)"
    refute_output --partial "missing ref: src/marker-us.js"
}

# ──────────────────────────────────────────────────────────────────────────────
# Test 18 (Change 1): a project dir whose real directory name contains a DOT
# — the encoding flattens '.' to '-' as well, exercising the same trailing-
# component decode pass with a different separator character.
# ──────────────────────────────────────────────────────────────────────────────
@test "project dir with a dot in its real name decodes and resolves" {
    local real_dir="$HOME/testproj.dotted"
    mkdir -p "$real_dir/src"
    touch "$real_dir/src/marker-dot.js"

    # Only flatten the tail component WE added — $HOME's own mktemp-
    # generated name (which itself may contain a literal dot, e.g.
    # "tmp.XXXXXXXX" on macOS) must decode via pass 1 unchanged; sweeping it
    # into this substitution would create a second, non-trailing merge
    # point that the (intentionally bounded, trailing-only) decoder is not
    # meant to chase.
    local encoded="${HOME//\//-}-testproj-dotted"

    local proj_dir="$CAST_MEMORIES_BASE_DIR/$encoded/memory"
    mkdir -p "$proj_dir"

    cat > "$proj_dir/dotted-project.md" <<EOF
---
name: dotted-project-entry
metadata:
  verified_at: 2026-06-08
---

References src/marker-dot.js and the --verbose flag.
EOF

    run env CAST_STALE_DAYS=30 python3 "$SCRIPT"
    assert_success
    assert_output --partial "1 stale memories evaluated (0 REF-BROKEN, 1 REFS-OK, 0 NO-REFS, 0 EPHEMERAL-ONLY)"
    refute_output --partial "missing ref: src/marker-dot.js"
}

# ──────────────────────────────────────────────────────────────────────────────
# Test 19 (Change 1 regression guard): a genuinely absent project — whose
# encoded name LOOKS like it could decode via an underscore/dot variant but
# has no real directory anywhere — must still fail closed to REF-BROKEN. The
# widened decode must not become blanket forgiveness.
# ──────────────────────────────────────────────────────────────────────────────
@test "genuinely absent project with underscore/dot-shaped name still fails closed" {
    local proj_dir="$CAST_MEMORIES_BASE_DIR/-Nonexistent-Test-Root-Foo-Bar-Baz/memory"
    mkdir -p "$proj_dir"

    cat > "$proj_dir/dead-project-2.md" <<EOF
---
name: dead-project-2-entry
metadata:
  verified_at: 2026-06-08
---

References src/would-not-resolve-xyz.py and the --verbose flag.
EOF

    run env CAST_STALE_DAYS=30 python3 "$SCRIPT"
    assert_success
    assert_output --partial "1 stale memories evaluated (1 REF-BROKEN, 0 REFS-OK, 0 NO-REFS, 0 EPHEMERAL-ONLY)"
    assert_output --partial "missing ref: src/would-not-resolve-xyz.py"
}

# ──────────────────────────────────────────────────────────────────────────────
# Test 20 (Change 2): an unresolvable `claude/reports/...` ref (a dead
# session artifact — the file was destroyed and can never come back) is
# bucketed as EPHEMERAL-ONLY, not counted toward REF-BROKEN, and NOT
# --apply-bump-eligible.
# ──────────────────────────────────────────────────────────────────────────────
@test "unresolvable ephemeral session ref classifies EPHEMERAL-ONLY, never bumped" {
    local proj_dir="$CAST_MEMORIES_BASE_DIR/proj-20/memory"
    mkdir -p "$proj_dir"

    cat > "$proj_dir/ephemeral.md" <<EOF
---
name: ephemeral-entry
metadata:
  verified_at: 2026-06-08
---

See claude/reports/2026-06-01-long-gone-report.md and the --verbose flag.
EOF

    local before after
    before=$(shasum -a 256 "$proj_dir/ephemeral.md" | awk '{print $1}')

    run env CAST_STALE_DAYS=30 python3 "$SCRIPT"
    assert_success
    assert_output --partial "1 stale memories evaluated (0 REF-BROKEN, 0 REFS-OK, 0 NO-REFS, 1 EPHEMERAL-ONLY)"
    assert_output --partial "ephemeral ref: claude/reports/2026-06-01-long-gone-report.md"
    refute_output --partial "missing ref: claude/reports/2026-06-01-long-gone-report.md"

    run env CAST_STALE_DAYS=30 python3 "$SCRIPT" --apply
    assert_success

    after=$(shasum -a 256 "$proj_dir/ephemeral.md" | awk '{print $1}')
    [ "$before" = "$after" ]
}

# ──────────────────────────────────────────────────────────────────────────────
# Test 21 (Change 2 regression guard): a `claude/reports/...`-SHAPED ref that
# actually DOES resolve on disk must stay a normal resolved ref (REFS-OK),
# and must NOT be swept into the ephemeral bucket just because its path
# shape matches plans/reports/resume-prompts/research.
# ──────────────────────────────────────────────────────────────────────────────
@test "resolving ephemeral-shaped ref stays a normal resolved ref, not ephemeral" {
    local proj_dir="$CAST_MEMORIES_BASE_DIR/proj-21/memory"
    mkdir -p "$proj_dir"
    mkdir -p "$HOME/.claude/reports"
    touch "$HOME/.claude/reports/2026-06-01-still-here-report.md"

    cat > "$proj_dir/resolving-ephemeral-shaped.md" <<EOF
---
name: resolving-ephemeral-shaped-entry
metadata:
  verified_at: 2026-06-08
---

See claude/reports/2026-06-01-still-here-report.md and the --verbose flag.
EOF

    run env CAST_STALE_DAYS=30 python3 "$SCRIPT"
    assert_success
    assert_output --partial "1 stale memories evaluated (0 REF-BROKEN, 1 REFS-OK, 0 NO-REFS, 0 EPHEMERAL-ONLY)"
    refute_output --partial "ephemeral ref: claude/reports/2026-06-01-still-here-report.md"
}

# ──────────────────────────────────────────────────────────────────────────────
# A ref naming a file that was deleted from the project's git history is
# REF-BROKEN like any other unresolvable ref (the git-log "RETIRED" lookup was
# removed: it cannot be made safe in an agent-writable repo). --apply leaves
# the file byte-identical.
# ──────────────────────────────────────────────────────────────────────────────
@test "ref to a file deleted from project git history is REF-BROKEN and --apply leaves the file alone" {
    local fake_repo="$HOME/deleted-ref-proj"
    _make_retired_repo "$fake_repo" "cast-deleted-ref-fixture.sh"

    local encoded="${HOME//\//-}-deleted-ref-proj"
    local proj_dir="$CAST_MEMORIES_BASE_DIR/$encoded/memory"
    mkdir -p "$proj_dir"

    cat > "$proj_dir/deleted-ref.md" <<EOF
---
name: deleted-ref-entry
metadata:
  verified_at: 2026-06-08
---

References cast-deleted-ref-fixture.sh and the --verbose flag.
EOF

    local before after
    before=$(shasum -a 256 "$proj_dir/deleted-ref.md" | awk '{print $1}')

    run env CAST_STALE_DAYS=30 python3 "$SCRIPT" --apply
    assert_success
    assert_output --partial "1 stale memories evaluated (1 REF-BROKEN, 0 REFS-OK, 0 NO-REFS, 0 EPHEMERAL-ONLY)"
    assert_output --partial "missing ref: cast-deleted-ref-fixture.sh"
    refute_output --partial "RETIRED"

    after=$(shasum -a 256 "$proj_dir/deleted-ref.md" | awk '{print $1}')
    [ "$before" = "$after" ]
}

# ──────────────────────────────────────────────────────────────────────────────
# The verifier must never run `git log` (or any git other than via
# cast_git_safe, which ignores PATH). A PATH-shimmed `git` records every raw
# invocation; none may appear, whatever the memory cites.
# ──────────────────────────────────────────────────────────────────────────────
@test "verifier never invokes a raw git (no git log) even for a deleted-file ref" {
    local fake_repo="$HOME/nolog-proj"
    _make_retired_repo "$fake_repo" "cast-nolog-fixture.sh"

    local encoded="${HOME//\//-}-nolog-proj"
    local proj_dir="$CAST_MEMORIES_BASE_DIR/$encoded/memory"
    mkdir -p "$proj_dir"
    cat > "$proj_dir/nolog.md" <<EOF
---
name: nolog-entry
metadata:
  verified_at: 2026-06-08
---

References cast-nolog-fixture.sh and the --verbose flag.
EOF

    local real_git shim_dir="$HOME/shim" gitlog="$HOME/git-argv.log"
    real_git=$(command -v git)
    mkdir -p "$shim_dir"
    printf '#!/bin/bash\necho "$*" >> "%s"\nexec "%s" "$@"\n' "$gitlog" "$real_git" > "$shim_dir/git"
    chmod +x "$shim_dir/git"

    # Positive control: the shim records a raw git call made via PATH.
    PATH="$shim_dir:$PATH" git --version > /dev/null
    [ -s "$gitlog" ]
    : > "$gitlog"

    run env PATH="$shim_dir:$PATH" CAST_STALE_DAYS=30 python3 "$SCRIPT" --apply
    assert_success
    assert_output --partial "1 REF-BROKEN"

    run grep -c " log \|^log " "$gitlog"
    assert_output "0"
}

# ──────────────────────────────────────────────────────────────────────────────
# Test 26 (fail-closed): when the memory's decoded project root is NOT a
# git work tree, a missing ref stays REF-BROKEN (ls-files fails closed).
# ──────────────────────────────────────────────────────────────────────────────
@test "non-git-repo project root stays REF-BROKEN" {
    local plain_dir="$HOME/plain-non-git-proj"
    mkdir -p "$plain_dir"
    # Deliberately NOT a git repo — no `git init` here.

    local encoded="${HOME//\//-}-plain-non-git-proj"
    local proj_dir="$CAST_MEMORIES_BASE_DIR/$encoded/memory"
    mkdir -p "$proj_dir"

    cat > "$proj_dir/non-git.md" <<EOF
---
name: non-git-entry
metadata:
  verified_at: 2026-06-08
---

References cast-would-be-retired-xyz.sh and the --verbose flag.
EOF

    run env CAST_STALE_DAYS=30 python3 "$SCRIPT"
    assert_success
    assert_output --partial "1 stale memories evaluated (1 REF-BROKEN, 0 REFS-OK, 0 NO-REFS, 0 EPHEMERAL-ONLY)"
    assert_output --partial "missing ref: cast-would-be-retired-xyz.sh"
}

# ──────────────────────────────────────────────────────────────────────────────
# Test 27 (CAST v10 J-4 — bare-extension extraction guard): "init/.sh/.py"
# (a real extraction artifact from prose like "init/.sh/.py", meaning two
# files, not a path) is dropped before classification. When it's the ONLY
# extracted "ref", the file classifies NO-REFS, not REF-BROKEN.
# ──────────────────────────────────────────────────────────────────────────────
@test "bare-extension extraction artifact is dropped, leaving NO-REFS" {
    local proj_dir="$CAST_MEMORIES_BASE_DIR/proj-27/memory"
    mkdir -p "$proj_dir"

    cat > "$proj_dir/bare-ext.md" <<EOF
---
name: bare-ext-entry
metadata:
  verified_at: 2026-06-08
---

schema_migrations shape unified across init/.sh/.py and the --verbose flag.
EOF

    run env CAST_STALE_DAYS=30 python3 "$SCRIPT"
    assert_success
    assert_output --partial "1 stale memories evaluated (0 REF-BROKEN, 0 REFS-OK, 1 NO-REFS, 0 EPHEMERAL-ONLY)"
    refute_output --partial "init/.sh/.py"
}

# ──────────────────────────────────────────────────────────────────────────────
# Test 28 (regression guard): a placeholder-shaped ref like "tests/X.bats"
# is NOT swept up by the bare-extension guard (its final segment "X.bats"
# has a real stem, "X") — it must stay reported as REF-BROKEN, per the
# task's explicit instruction not to guess at placeholder-ness.
# ──────────────────────────────────────────────────────────────────────────────
@test "placeholder-shaped ref (tests/X.bats) is left reported, not swept by the bare-extension guard" {
    local proj_dir="$CAST_MEMORIES_BASE_DIR/proj-28/memory"
    mkdir -p "$proj_dir"

    cat > "$proj_dir/placeholder.md" <<EOF
---
name: placeholder-entry
metadata:
  verified_at: 2026-06-08
---

Run bats tests/X.bats to check, plus the --verbose flag.
EOF

    run env CAST_STALE_DAYS=30 python3 "$SCRIPT"
    assert_success
    assert_output --partial "1 stale memories evaluated (1 REF-BROKEN, 0 REFS-OK, 0 NO-REFS, 0 EPHEMERAL-ONLY)"
    assert_output --partial "missing ref: tests/X.bats"
}

# ──────────────────────────────────────────────────────────────────────────────
# J-4: plugin/ is a GENERATED MIRROR of tracked repo content (scripts/gen-plugin.sh),
# so every bundled file has a plugin/ twin and a ref naming one matches twice by
# construction. That produced ambiguity findings that were artifacts of the mirror,
# not of the memory — measured on the real corpus: "planner.md: ambiguous (2
# candidates: agents/core/planner.md, plugin/agents/planner.md)".
# The mirror is collapsed ONLY when it is the sole cause of the tie. A ref with two
# genuine sources stays ambiguous and stays reported, because picking one is a guess.
# ──────────────────────────────────────────────────────────────────────────────
@test "J-4: a generated plugin/ mirror twin does not make a ref ambiguous" {
    local fake_repo="$BATS_TEST_TMPDIR/mirror-repo"
    mkdir -p "$fake_repo/agents/core" "$fake_repo/plugin/agents"
    touch "$fake_repo/agents/core/planner.md" "$fake_repo/plugin/agents/planner.md"
    ( cd "$fake_repo" && git init -q && cast_git_fixture_quiet && git add -A )

    run python3 -c "
import sys, importlib.util
spec = importlib.util.spec_from_file_location('cvm', '$SCRIPT')
cvm = importlib.util.module_from_spec(spec); spec.loader.exec_module(cvm)
path, candidates = cvm.resolve_git_suffix_ref('planner.md', '$fake_repo')
assert candidates is None, f'expected no ambiguity, got {candidates}'
assert path is not None and path.endswith('agents/core/planner.md'), f'resolved to {path}'
print('OK resolved to the source, not the mirror')
"
    assert_success
    assert_output --partial "OK resolved to the source"
}

@test "J-4: two genuine sources stay ambiguous even when mirrors are present" {
    local fake_repo="$BATS_TEST_TMPDIR/mirror-repo2"
    mkdir -p "$fake_repo/skills/a" "$fake_repo/skills/b" "$fake_repo/plugin/skills/a"
    touch "$fake_repo/skills/a/SKILL.md" "$fake_repo/skills/b/SKILL.md" \
          "$fake_repo/plugin/skills/a/SKILL.md"
    ( cd "$fake_repo" && git init -q && cast_git_fixture_quiet && git add -A )

    run python3 -c "
import sys, importlib.util
spec = importlib.util.spec_from_file_location('cvm', '$SCRIPT')
cvm = importlib.util.module_from_spec(spec); spec.loader.exec_module(cvm)
path, candidates = cvm.resolve_git_suffix_ref('SKILL.md', '$fake_repo')
assert path is None, f'must not silently pick, got {path}'
assert candidates is not None and len(candidates) == 3, f'expected all 3 reported, got {candidates}'
print('OK still ambiguous')
"
    assert_success
    assert_output --partial "OK still ambiguous"
}

# ──────────────────────────────────────────────────────────────────────────────
# H1: a planted repo-config exec path (core.fsmonitor) must NOT run during the
# scheduled form. Positive control first: raw git DOES fire the planted script
# in this fixture. The memory cites a TRACKED file by a path suffix that only
# the `git ls-files` fallback can resolve, so a REFS-OK + bumped result proves
# ls-files actually ran (and via the hardened primitive, since the marker is
# absent).
# ──────────────────────────────────────────────────────────────────────────────
@test "scheduled form (--apply) resolves via ls-files without executing a planted core.fsmonitor" {
    local planted="$HOME/planted-proj"
    mkdir -p "$planted/deep/dir"
    (
        cd "$planted" || exit 1
        git init -q
        git config user.email "bats@example.com"
        git config user.name "bats-test"
        touch deep/dir/planted-tracked.sh
        git add -A
        git commit -q -m "add tracked"
    )
    local marker="$HOME/fsmonitor-fired.marker"
    printf '#!/bin/sh\ntouch "%s"\n' "$marker" > "$HOME/fsmon.sh"
    chmod +x "$HOME/fsmon.sh"
    git -C "$planted" config core.fsmonitor "$HOME/fsmon.sh"

    # Positive control: unhardened git fires it.
    git -C "$planted" ls-files > /dev/null 2>&1 || true
    [ -f "$marker" ]
    rm -f "$marker"

    local encoded="${HOME//\//-}-planted-proj"
    local proj_dir="$CAST_MEMORIES_BASE_DIR/$encoded/memory"
    mkdir -p "$proj_dir"
    cat > "$proj_dir/planted.md" <<EOF
---
name: planted-entry
metadata:
  verified_at: 2026-06-08
---

References dir/planted-tracked.sh and the --verbose flag.
EOF

    run env CAST_STALE_DAYS=30 python3 "$SCRIPT" --apply
    assert_success
    assert_output --partial "1 stale memories evaluated (0 REF-BROKEN, 1 REFS-OK"
    run grep -c "verified_by: cast-verify-memories.py (refs-resolved)" "$proj_dir/planted.md"
    assert_output "1"
    [ ! -e "$marker" ]
}

# ──────────────────────────────────────────────────────────────────────────────
# Bytes safety: CRLF round-trips intact (only the two frontmatter lines
# change); a non-UTF-8 file is skipped byte-identical; file mode is preserved.
# ──────────────────────────────────────────────────────────────────────────────
@test "--apply on a CRLF file keeps CRLF and changes only the two frontmatter lines" {
    local proj_dir="$CAST_MEMORIES_BASE_DIR/proj-crlf/memory"
    mkdir -p "$proj_dir"
    printf -- '---\r\nname: crlf-entry\r\nmetadata:\r\n  verified_at: 2026-06-08\r\n---\r\n\r\nDiscusses %s and the --verbose flag.\r\n' "$REAL_REF" > "$proj_dir/crlf.md"

    local today
    today=$(date -u +%Y-%m-%d)
    printf -- '---\r\nname: crlf-entry\r\nmetadata:\r\n  verified_at: %s\r\n  verified_by: cast-verify-memories.py (refs-resolved)\r\n---\r\n\r\nDiscusses %s and the --verbose flag.\r\n' "$today" "$REAL_REF" > "$BATS_TEST_TMPDIR/expected.md"

    run env CAST_STALE_DAYS=30 python3 "$SCRIPT" --apply
    assert_success
    assert_output --partial "1 REFS-OK"

    run cmp "$proj_dir/crlf.md" "$BATS_TEST_TMPDIR/expected.md"
    assert_success
}

@test "--apply skips a non-UTF-8 memory file byte-identical" {
    local proj_dir="$CAST_MEMORIES_BASE_DIR/proj-latin1/memory"
    mkdir -p "$proj_dir"
    printf -- '---\nname: latin1-entry\nmetadata:\n  verified_at: 2026-06-08\n---\n\nCaf\xe9 discusses %s and the --verbose flag.\n' "$REAL_REF" > "$proj_dir/latin1.md"

    local before after
    before=$(shasum -a 256 "$proj_dir/latin1.md" | awk '{print $1}')

    run env CAST_STALE_DAYS=30 python3 "$SCRIPT" --apply
    assert_success
    assert_output --partial "0 stale memories evaluated"
    assert_output --partial "skipped 1 non-UTF-8 memory file(s)"

    after=$(shasum -a 256 "$proj_dir/latin1.md" | awk '{print $1}')
    [ "$before" = "$after" ]
}

@test "--apply preserves the memory file's mode" {
    local proj_dir="$CAST_MEMORIES_BASE_DIR/proj-mode/memory"
    mkdir -p "$proj_dir"
    cat > "$proj_dir/mode.md" <<EOF
---
name: mode-entry
metadata:
  verified_at: 2026-06-08
---

Discusses $REAL_REF and the --verbose flag.
EOF
    chmod 640 "$proj_dir/mode.md"

    run env CAST_STALE_DAYS=30 python3 "$SCRIPT" --apply
    assert_success

    run python3 -c 'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777))' "$proj_dir/mode.md"
    assert_output "0o640"
    run grep -c "verified_by: cast-verify-memories.py (refs-resolved)" "$proj_dir/mode.md"
    assert_output "1"
}

# ──────────────────────────────────────────────────────────────────────────────
# S6: a verified_by: key anywhere in the frontmatter is replaced in place, never
# duplicated.
# ──────────────────────────────────────────────────────────────────────────────
@test "--apply replaces a verified_by line that sits ABOVE verified_at (no duplicate)" {
    local proj_dir="$CAST_MEMORIES_BASE_DIR/proj-vb-above/memory"
    mkdir -p "$proj_dir"
    cat > "$proj_dir/vb-above.md" <<EOF
---
name: vb-above-entry
metadata:
  verified_by: human
  verified_at: 2026-06-08
---

Discusses $REAL_REF and the --verbose flag.
EOF

    run env CAST_STALE_DAYS=30 python3 "$SCRIPT" --apply
    assert_success

    run grep -c "verified_by:" "$proj_dir/vb-above.md"
    assert_output "1"
    run sed -n 4p "$proj_dir/vb-above.md"
    assert_output "  verified_by: cast-verify-memories.py (refs-resolved)"
    run grep "verified_by: human" "$proj_dir/vb-above.md"
    assert_failure
}

@test "--apply replaces a verified_by line that sits BELOW verified_at but not adjacent (no duplicate)" {
    local proj_dir="$CAST_MEMORIES_BASE_DIR/proj-vb-below/memory"
    mkdir -p "$proj_dir"
    cat > "$proj_dir/vb-below.md" <<EOF
---
name: vb-below-entry
metadata:
  verified_at: 2026-06-08
  note: keep-me
  verified_by: human
---

Discusses $REAL_REF and the --verbose flag.
EOF

    run env CAST_STALE_DAYS=30 python3 "$SCRIPT" --apply
    assert_success

    run grep -c "verified_by:" "$proj_dir/vb-below.md"
    assert_output "1"
    run grep "verified_by: human" "$proj_dir/vb-below.md"
    assert_failure
    run grep -c "note: keep-me" "$proj_dir/vb-below.md"
    assert_output "1"
}

# ──────────────────────────────────────────────────────────────────────────────
# Boundary: the bump only edits files whose lines end in "\n" / "\r\n". A
# CR-only file, or a frontmatter line holding another line-boundary char
# (U+2028 here), is skipped byte-identical — never rewritten with lost
# terminators.
# ──────────────────────────────────────────────────────────────────────────────
@test "--apply leaves a CR-only (classic Mac) memory file byte-identical" {
    local proj_dir="$CAST_MEMORIES_BASE_DIR/proj-cr/memory"
    mkdir -p "$proj_dir"
    printf -- '---\rname: cr-entry\rmetadata:\r  verified_at: 2026-06-08\r---\r\rDiscusses %s and the --verbose flag.\r' "$REAL_REF" > "$proj_dir/cr.md"

    local before after
    before=$(shasum -a 256 "$proj_dir/cr.md" | awk '{print $1}')

    run env CAST_STALE_DAYS=30 python3 "$SCRIPT" --apply
    assert_success

    after=$(shasum -a 256 "$proj_dir/cr.md" | awk '{print $1}')
    [ "$before" = "$after" ]
}

@test "--apply leaves a file with U+2028 inside the frontmatter byte-identical" {
    local proj_dir="$CAST_MEMORIES_BASE_DIR/proj-ls/memory"
    mkdir -p "$proj_dir"
    printf -- '---\nname: ls-entry\nmetadata:\n  verified_at: 2026-06-08\n  note: a\xe2\x80\xa8b\n---\n\nDiscusses %s and the --verbose flag.\n' "$REAL_REF" > "$proj_dir/ls.md"

    local before after
    before=$(shasum -a 256 "$proj_dir/ls.md" | awk '{print $1}')

    run env CAST_STALE_DAYS=30 python3 "$SCRIPT" --apply
    assert_success
    assert_output --partial "1 stale memories evaluated"

    after=$(shasum -a 256 "$proj_dir/ls.md" | awk '{print $1}')
    [ "$before" = "$after" ]
}

# ──────────────────────────────────────────────────────────────────────────────
# Index-only entries: `git ls-files` lists a file deleted from the worktree but
# still in the index. A memory citing it must NOT resolve (REF-BROKEN) and
# --apply must leave the file byte-identical.
# ──────────────────────────────────────────────────────────────────────────────
@test "ref to a file deleted from the worktree but still in the git index stays REF-BROKEN" {
    local repo="$HOME/indexonly-proj"
    mkdir -p "$repo/deep/idx"
    (
        cd "$repo" || exit 1
        git init -q
        git config user.email "bats@example.com"
        git config user.name "bats-test"
        touch deep/idx/gone-file.sh
        git add -A
    )
    rm "$repo/deep/idx/gone-file.sh"
    # Positive control: the index still lists the deleted file.
    run git -C "$repo" ls-files
    assert_output --partial "deep/idx/gone-file.sh"

    local encoded="${HOME//\//-}-indexonly-proj"
    local proj_dir="$CAST_MEMORIES_BASE_DIR/$encoded/memory"
    mkdir -p "$proj_dir"
    cat > "$proj_dir/indexonly.md" <<EOF
---
name: indexonly-entry
metadata:
  verified_at: 2026-06-08
---

References idx/gone-file.sh and the --verbose flag.
EOF

    local before after
    before=$(shasum -a 256 "$proj_dir/indexonly.md" | awk '{print $1}')

    run env CAST_STALE_DAYS=30 python3 "$SCRIPT" --apply
    assert_success
    assert_output --partial "1 stale memories evaluated (1 REF-BROKEN, 0 REFS-OK"

    after=$(shasum -a 256 "$proj_dir/indexonly.md" | awk '{print $1}')
    [ "$before" = "$after" ]
}

# ──────────────────────────────────────────────────────────────────────────────
# Fail closed on an undecodable project dir: the git-suffix root must NOT fall
# back to the process cwd (the unattended run's cwd is arbitrary).
# ──────────────────────────────────────────────────────────────────────────────
@test "undecodable project dir does not resolve refs against the cwd repo via git-suffix" {
    local cwd_repo="$HOME/cwd-repo"
    mkdir -p "$cwd_repo/deep/sub"
    (
        cd "$cwd_repo" || exit 1
        git init -q
        git config user.email "bats@example.com"
        git config user.name "bats-test"
        touch deep/sub/cwd-only.sh
        git add -A
        git commit -q -m "add"
    )
    # Positive control: from this cwd the suffix IS resolvable via ls-files.
    run git -C "$cwd_repo" ls-files
    assert_output --partial "deep/sub/cwd-only.sh"

    local proj_dir="$CAST_MEMORIES_BASE_DIR/-Nonexistent-Zzyzx-Undecodable-Project/memory"
    mkdir -p "$proj_dir"
    cat > "$proj_dir/undecodable.md" <<EOF
---
name: undecodable-entry
metadata:
  verified_at: 2026-06-08
---

References sub/cwd-only.sh and the --verbose flag.
EOF

    local before after
    before=$(shasum -a 256 "$proj_dir/undecodable.md" | awk '{print $1}')

    cd "$cwd_repo"
    run env CAST_STALE_DAYS=30 python3 "$SCRIPT" --apply
    assert_success
    assert_output --partial "1 stale memories evaluated (1 REF-BROKEN, 0 REFS-OK"
    assert_output --partial "missing ref: sub/cwd-only.sh"

    after=$(shasum -a 256 "$proj_dir/undecodable.md" | awk '{print $1}')
    [ "$before" = "$after" ]
}

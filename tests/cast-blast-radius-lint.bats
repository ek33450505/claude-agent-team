#!/usr/bin/env bats
# tests/cast-blast-radius-lint.bats — Gate-must-bite tests for scripts/blast-radius-lint.sh
#
# Verifies the required behaviors:
#   1. Bare rm -rf in a non-exempt file → exit 1 naming the file (gate bites)
#   2. Clean scripts/ (no violations) → exit 0
#   3. Allowlisted file → exit 0 even when it contains rm -rf
#   4. Pure comment lines with rm -rf → exit 0 (skipped)
#   5-11. All rm-rf permutations (F2) → exit 1 each
#   12-14. Negative cases (rm -f alone, rm -r alone, word ending in rm) → exit 0
#   15. Trailing-comment fail-closed (F1): code line + rm-rf in comment → exit 1
#   16. No-override gate-bites: temp git repo + violating script, no env override → exit 1
#   17. Empty scripts dir → exit 1 with scanned-0 error message
#
# All tests operate on mktemp fixture directories via CAST_LINT_SCRIPTS_DIR env var
# (except test 16 which exercises the git-based REPO_ROOT path).
# The real scripts/ directory is never modified.

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
LINT_SCRIPT="$REPO_DIR/scripts/blast-radius-lint.sh"

# ---------------------------------------------------------------------------
# 1. Gate must bite: fake script with bare rm -rf → exit 1, file named in output
# ---------------------------------------------------------------------------
@test "blast-radius-lint exits 1 and names violating file" {
  local fixture_dir
  fixture_dir="$BATS_TEST_TMPDIR/scripts"
  mkdir -p "$fixture_dir"

  # Plant a fake shell script with a bare rm -rf (not in a comment)
  cat > "$fixture_dir/fake-bad-script.sh" << 'EOF'
#!/usr/bin/env bash
rm -rf /tmp/some-dir
EOF

  CAST_LINT_SCRIPTS_DIR="$fixture_dir" run bash "$LINT_SCRIPT"
  assert_failure
  assert_output --partial "fake-bad-script.sh"
  assert_output --partial "FATAL" || assert_output --partial "ERROR"
}

# ---------------------------------------------------------------------------
# 2. Clean fixture → exit 0
# ---------------------------------------------------------------------------
@test "blast-radius-lint exits 0 for clean scripts directory" {
  local fixture_dir
  fixture_dir="$BATS_TEST_TMPDIR/scripts-clean"
  mkdir -p "$fixture_dir"

  # Script that uses cast_safe_rm — no bare rm -rf
  cat > "$fixture_dir/clean-script.sh" << 'EOF'
#!/usr/bin/env bash
source cast-guard-lib.sh
cast_declare_blast_radius "/tmp/safe-root-"
cast_safe_rm "/tmp/safe-root-abc"
EOF

  CAST_LINT_SCRIPTS_DIR="$fixture_dir" run bash "$LINT_SCRIPT"
  assert_success
}

# ---------------------------------------------------------------------------
# 3. Allowlisted file with bare rm -rf → exit 0 (exemption applies)
# ---------------------------------------------------------------------------
@test "blast-radius-lint exits 0 for allowlisted file with rm -rf" {
  local fixture_dir
  fixture_dir="$BATS_TEST_TMPDIR/scripts-allowlist"
  mkdir -p "$fixture_dir"

  # ci-pii-scan.sh is in the ALLOWLIST — a bare rm -rf there must be ignored
  cat > "$fixture_dir/ci-pii-scan.sh" << 'EOF'
#!/usr/bin/env bash
TMPDIR_SELF="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_SELF"' EXIT
EOF

  CAST_LINT_SCRIPTS_DIR="$fixture_dir" run bash "$LINT_SCRIPT"
  assert_success
}

# ---------------------------------------------------------------------------
# 4. Pure comment line with rm -rf → exit 0 (comment lines are skipped)
# ---------------------------------------------------------------------------
@test "blast-radius-lint skips comment lines containing rm -rf" {
  local fixture_dir
  fixture_dir="$BATS_TEST_TMPDIR/scripts-comment"
  mkdir -p "$fixture_dir"

  cat > "$fixture_dir/script-with-comment.sh" << 'EOF'
#!/usr/bin/env bash
# This is a comment: rm -rf /some/path is documented here but not executed
# Another comment mentioning shutil.rmtree for Python callers
cast_safe_rm "$TARGET"
EOF

  CAST_LINT_SCRIPTS_DIR="$fixture_dir" run bash "$LINT_SCRIPT"
  assert_success
}

# ---------------------------------------------------------------------------
# 5-11. F2: rm-rf permutations — all must be flagged (exit 1)
# ---------------------------------------------------------------------------
@test "blast-radius-lint flags rm -fr (force then recursive combined)" {
  local d="$BATS_TEST_TMPDIR/scripts-fr"
  mkdir -p "$d"
  printf '#!/usr/bin/env bash\nrm -fr /tmp/x\n' > "$d/bad.sh"
  CAST_LINT_SCRIPTS_DIR="$d" run bash "$LINT_SCRIPT"
  assert_failure
  assert_output --partial "bad.sh"
}

@test "blast-radius-lint flags rm -Rf (capital R combined)" {
  local d="$BATS_TEST_TMPDIR/scripts-Rf"
  mkdir -p "$d"
  printf '#!/usr/bin/env bash\nrm -Rf /tmp/x\n' > "$d/bad.sh"
  CAST_LINT_SCRIPTS_DIR="$d" run bash "$LINT_SCRIPT"
  assert_failure
  assert_output --partial "bad.sh"
}

@test "blast-radius-lint flags rm -fR (force then capital R combined)" {
  local d="$BATS_TEST_TMPDIR/scripts-fR"
  mkdir -p "$d"
  printf '#!/usr/bin/env bash\nrm -fR /tmp/x\n' > "$d/bad.sh"
  CAST_LINT_SCRIPTS_DIR="$d" run bash "$LINT_SCRIPT"
  assert_failure
  assert_output --partial "bad.sh"
}

@test "blast-radius-lint flags rm -r -f (separate short flags)" {
  local d="$BATS_TEST_TMPDIR/scripts-r-f"
  mkdir -p "$d"
  printf '#!/usr/bin/env bash\nrm -r -f /tmp/x\n' > "$d/bad.sh"
  CAST_LINT_SCRIPTS_DIR="$d" run bash "$LINT_SCRIPT"
  assert_failure
  assert_output --partial "bad.sh"
}

@test "blast-radius-lint flags rm -f -r (separate short flags reversed)" {
  local d="$BATS_TEST_TMPDIR/scripts-f-r"
  mkdir -p "$d"
  printf '#!/usr/bin/env bash\nrm -f -r /tmp/x\n' > "$d/bad.sh"
  CAST_LINT_SCRIPTS_DIR="$d" run bash "$LINT_SCRIPT"
  assert_failure
  assert_output --partial "bad.sh"
}

@test "blast-radius-lint flags rm --recursive --force (long flags)" {
  local d="$BATS_TEST_TMPDIR/scripts-long-rf"
  mkdir -p "$d"
  printf '#!/usr/bin/env bash\nrm --recursive --force /tmp/x\n' > "$d/bad.sh"
  CAST_LINT_SCRIPTS_DIR="$d" run bash "$LINT_SCRIPT"
  assert_failure
  assert_output --partial "bad.sh"
}

@test "blast-radius-lint flags rm --force --recursive (long flags reversed)" {
  local d="$BATS_TEST_TMPDIR/scripts-long-fr"
  mkdir -p "$d"
  printf '#!/usr/bin/env bash\nrm --force --recursive /tmp/x\n' > "$d/bad.sh"
  CAST_LINT_SCRIPTS_DIR="$d" run bash "$LINT_SCRIPT"
  assert_failure
  assert_output --partial "bad.sh"
}

# ---------------------------------------------------------------------------
# 12-14. F2 negative cases — must NOT be flagged (exit 0)
# ---------------------------------------------------------------------------
@test "blast-radius-lint does NOT flag rm -f alone (no recursive)" {
  local d="$BATS_TEST_TMPDIR/scripts-f-only"
  mkdir -p "$d"
  printf '#!/usr/bin/env bash\nrm -f /tmp/x\n' > "$d/clean.sh"
  CAST_LINT_SCRIPTS_DIR="$d" run bash "$LINT_SCRIPT"
  assert_success
}

@test "blast-radius-lint does NOT flag rm -r alone (no force)" {
  local d="$BATS_TEST_TMPDIR/scripts-r-only"
  mkdir -p "$d"
  printf '#!/usr/bin/env bash\nrm -r /tmp/x\n' > "$d/clean.sh"
  CAST_LINT_SCRIPTS_DIR="$d" run bash "$LINT_SCRIPT"
  assert_success
}

@test "blast-radius-lint does NOT flag words ending in rm (e.g. confirm)" {
  local d="$BATS_TEST_TMPDIR/scripts-confirm"
  mkdir -p "$d"
  # 'confirm' contains 'rm' — must not trigger the rm pattern
  printf '#!/usr/bin/env bash\nconfirm -rf /some/path || true\n' > "$d/clean.sh"
  CAST_LINT_SCRIPTS_DIR="$d" run bash "$LINT_SCRIPT"
  assert_success
}

# ---------------------------------------------------------------------------
# 15. F1 fail-closed: code line with rm-rf in trailing comment → exit 1 (flagged)
#
# Rationale: position-of-# heuristics are bypassable without a real shell parser
# (e.g. `true "#"; rm -rf /x`). Only pure comment lines (first non-space char = #)
# are skipped. Any executable line mentioning rm-rf is flagged even if the mention
# is in a trailing comment. Reword the comment or use ALLOWLIST instead.
# ---------------------------------------------------------------------------
@test "blast-radius-lint flags code line with rm-rf in trailing comment (fail-closed)" {
  local d="$BATS_TEST_TMPDIR/scripts-trailing-comment"
  mkdir -p "$d"
  # This line has real code (cast_safe_rm) AND mentions rm -rf in a trailing comment.
  # The lint must flag it because the line is executable code, not a pure comment.
  printf '#!/usr/bin/env bash\ncast_safe_rm "$d"  # rm -rf /danger\n' > "$d/trailing.sh"
  CAST_LINT_SCRIPTS_DIR="$d" run bash "$LINT_SCRIPT"
  assert_failure
  assert_output --partial "trailing.sh"
}

# ---------------------------------------------------------------------------
# 16. F4(c): NO-OVERRIDE gate-bites — temp git repo, no CAST_LINT_SCRIPTS_DIR set
#
# Builds a real git repo fixture so REPO_ROOT resolves via git rev-parse --show-toplevel.
# Runs the lint from inside the repo WITHOUT any env override.
# Asserts exit 1 naming the violating file.
# ---------------------------------------------------------------------------
@test "blast-radius-lint bites via git-based REPO_ROOT with no env override" {
  local fake_repo
  fake_repo="$BATS_TEST_TMPDIR/fake-repo"
  mkdir -p "$fake_repo/scripts"

  # Initialize a minimal git repo (quiet, no user config needed for init)
  git -C "$fake_repo" init -q

  # Plant a violating script in scripts/
  cat > "$fake_repo/scripts/evil.sh" << 'EOF'
#!/usr/bin/env bash
rm -rf /tmp/evil
EOF

  # Run lint from INSIDE the fake repo — no CAST_LINT_SCRIPTS_DIR override
  # so lint must discover scripts/ via git rev-parse --show-toplevel
  run bash -c "cd '$fake_repo' && bash '$LINT_SCRIPT'"
  assert_failure
  assert_output --partial "evil.sh"
}

# ---------------------------------------------------------------------------
# 17. F4(b): empty scripts dir → exit 1 with scanned-0 error (not a silent pass)
# ---------------------------------------------------------------------------
@test "blast-radius-lint exits 1 with scanned-0 error for empty scripts directory" {
  local d="$BATS_TEST_TMPDIR/scripts-empty"
  mkdir -p "$d"
  # No .sh or .py files — lint must refuse to pass

  CAST_LINT_SCRIPTS_DIR="$d" run bash "$LINT_SCRIPT"
  assert_failure
  assert_output --partial "scanned 0 files"
}

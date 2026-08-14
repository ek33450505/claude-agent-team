#!/usr/bin/env bats
# tests/cast-lint-source-guard.bats — Gate-must-bite tests for
# scripts/cast-lint-source-guard.sh (bash 3.2 `source X || ...` idiom ratchet)
#
# Verifies:
#   1. Bare unguarded `source X 2>/dev/null || true` under set -e → exit 1
#   2. Existence-guarded (if [[ -f ]]; then source; fi) → exit 0
#   3. Subshell-wrapped ( source X && cmd ) || true → exit 0
#   4. Pure comment mentioning the pattern → exit 0 (skipped)
#   5. Multi-line backslash-continuation form → exit 1 (logical-line join catches it)
#   6. File with no `set -e` at all → exit 0 (out of scope for the bug)
#   7. Unguarded source in the ELSE branch of a guarded if → exit 1 (state
#      machine must not treat the whole if/fi span as safe)
#   8. Empty scripts dir → exit 1 with scanned-0 error message
#   9. No-override gate-bites: real git repo fixture, no CAST_LINT_SCRIPTS_DIR → exit 1
#
# All tests (except 9) operate on mktemp fixture directories via
# CAST_LINT_SCRIPTS_DIR. The real scripts/ directory is never modified.

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
LINT_SCRIPT="$REPO_DIR/scripts/cast-lint-source-guard.sh"

@test "source-guard-lint flags bare unguarded source || true under set -e" {
  local d="$BATS_TEST_TMPDIR/scripts-bare"
  mkdir -p "$d"
  cat > "$d/bad.sh" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
source /nonexistent/a.sh 2>/dev/null || source /nonexistent/b.sh 2>/dev/null || true
echo "done"
EOF
  CAST_LINT_SCRIPTS_DIR="$d" run bash "$LINT_SCRIPT"
  assert_failure
  assert_output --partial "bad.sh"
}

@test "source-guard-lint allows existence-guarded source" {
  local d="$BATS_TEST_TMPDIR/scripts-guarded"
  mkdir -p "$d"
  cat > "$d/good.sh" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
_lib="/nonexistent/a.sh"
[[ -f "$_lib" ]] || _lib="/nonexistent/b.sh"
if [[ -f "$_lib" ]]; then
  source "$_lib" 2>/dev/null || true
fi
echo "done"
EOF
  CAST_LINT_SCRIPTS_DIR="$d" run bash "$LINT_SCRIPT"
  assert_success
}

@test "source-guard-lint allows subshell-wrapped source" {
  local d="$BATS_TEST_TMPDIR/scripts-subshell"
  mkdir -p "$d"
  cat > "$d/good.sh" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
( source /nonexistent/a.sh 2>/dev/null && do_thing ) || true
echo "done"
EOF
  CAST_LINT_SCRIPTS_DIR="$d" run bash "$LINT_SCRIPT"
  assert_success
}

@test "source-guard-lint skips pure comment lines" {
  local d="$BATS_TEST_TMPDIR/scripts-comment"
  mkdir -p "$d"
  cat > "$d/good.sh" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
# source /nonexistent/a.sh 2>/dev/null || true  -- documented example only
echo "done"
EOF
  CAST_LINT_SCRIPTS_DIR="$d" run bash "$LINT_SCRIPT"
  assert_success
}

@test "source-guard-lint flags multi-line backslash-continuation form" {
  local d="$BATS_TEST_TMPDIR/scripts-multiline"
  mkdir -p "$d"
  cat > "$d/bad.sh" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
source "/nonexistent/a.sh" 2>/dev/null \
  || source "/nonexistent/b.sh" 2>/dev/null \
  || true
echo "done"
EOF
  CAST_LINT_SCRIPTS_DIR="$d" run bash "$LINT_SCRIPT"
  assert_failure
  assert_output --partial "bad.sh"
}

@test "source-guard-lint does not scan files without set -e" {
  local d="$BATS_TEST_TMPDIR/scripts-no-sete"
  mkdir -p "$d"
  cat > "$d/clean.sh" << 'EOF'
#!/usr/bin/env bash
source /nonexistent/a.sh 2>/dev/null || true
echo "done"
EOF
  CAST_LINT_SCRIPTS_DIR="$d" run bash "$LINT_SCRIPT"
  assert_success
}

@test "source-guard-lint flags unguarded source in the else branch of a guarded if" {
  local d="$BATS_TEST_TMPDIR/scripts-else"
  mkdir -p "$d"
  cat > "$d/bad.sh" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ -f "/nonexistent/a.sh" ]]; then
  source "/nonexistent/a.sh"
else
  source "/nonexistent/fallback.sh" 2>/dev/null || true
fi
echo "done"
EOF
  CAST_LINT_SCRIPTS_DIR="$d" run bash "$LINT_SCRIPT"
  assert_failure
  assert_output --partial "bad.sh"
}

@test "source-guard-lint exits 1 with scanned-0 error for empty scripts directory" {
  local d="$BATS_TEST_TMPDIR/scripts-empty"
  mkdir -p "$d"
  CAST_LINT_SCRIPTS_DIR="$d" run bash "$LINT_SCRIPT"
  assert_failure
  assert_output --partial "scanned 0 files"
}

@test "source-guard-lint bites via git-based REPO_ROOT with no env override" {
  local fake_repo="$BATS_TEST_TMPDIR/fake-repo"
  mkdir -p "$fake_repo/scripts"
  git -C "$fake_repo" init -q
  cat > "$fake_repo/scripts/evil.sh" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
source /nonexistent/a.sh 2>/dev/null || true
EOF
  run bash -c "cd '$fake_repo' && bash '$LINT_SCRIPT'"
  assert_failure
  assert_output --partial "evil.sh"
}

#!/usr/bin/env bats
# tests/cast-lint-bash32-parse.bats — Gate-must-bite tests for
# scripts/cast-lint-bash32-parse.sh (bash 3.2 parse-error gate)
#
# NOTE ON THE "BAD" FIXTURE: the motivating incident (2026-08-24) described
# a heredoc inside `$(...)` as the construct that broke bash 3.2 parsing.
# Empirically, on this machine's real /bin/bash 3.2.57 (verified directly,
# several shapes tried), a plain heredoc-inside-$(...) parses CLEAN on both
# 3.2 and newer bash — it is not itself a 3.2-only parse divergence here.
# The "bad" fixture below keeps the heredoc (so it still matches the
# incident's shape and doubles as a false-positive check — see the "clean"
# test, which uses the identical heredoc idiom and must pass) and adds a
# construct independently VERIFIED to be bash-3.2-only: the `;;&` case
# fall-through terminator, added in bash 4.0. Confirmed directly:
#   /bin/bash -n  (3.2.57)  -> exit 2, "syntax error near unexpected token `&'"
#   bash 5.x -n             -> exit 0, clean
# This keeps the test both faithful to the incident's shape AND honest
# about what actually reproduces a parse-time failure on real bash 3.2.
#
# Verifies:
#   1. A script with a genuine bash-3.2-only parse error -> exit 1, names the file
#   2. A clean script (including a benign heredoc inside $(...)) -> exit 0
#   3. --help -> exit 0, prints usage
#   4. Output always states the "weaker on Linux" caveat
#   5. Empty scan dir -> exit 1 with scanned-0 error (fail-closed, mirrors
#      cast-lint-source-guard.bats)
#   6. Non-bash-shebang files (e.g. a *.py script) are not swept in
#
# All tests use CAST_LINT_BASH32_DIR to point at a $BATS_TEST_TMPDIR
# fixture directory. The real scripts/, bin/, .githooks/ are never touched.

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
LINT_SCRIPT="$REPO_DIR/scripts/cast-lint-bash32-parse.sh"

@test "bash32-parse-lint flags a real bash-3.2-only parse error and names the file" {
  # Capability probe, not a platform probe: what discriminates this test is
  # whether the bash binary the lint will actually check with REJECTS the
  # `;;&` case fall-through (bash 4.0+ only) at parse time -- not "which OS
  # is this". CAST_LINT_BASH32_BASH mirrors the lint script's own default
  # (BASH_BIN="${CAST_LINT_BASH32_BASH:-/bin/bash}") so a caller forcing a
  # newer bash (e.g. CAST_LINT_BASH32_BASH=$(command -v bash) to simulate
  # Linux CI, where /bin/bash is 5.x) is honored here too.
  local probe_bash="${CAST_LINT_BASH32_BASH:-/bin/bash}"
  local probe_ver
  probe_ver="$("$probe_bash" --version 2>&1 | head -1)"
  if "$probe_bash" -n <<'PROBE_EOF' 2>/dev/null
case "x" in
  a) echo a ;;&
  b) echo b ;;
esac
PROBE_EOF
  then
    skip "bash-3.2 ';;&' detection NOT exercised on this runner: ${probe_bash} (${probe_ver}) parses ';;&' cleanly (bash 4.0+ semantics), so no bash-3.2-only parse error exists to catch. Real coverage for this bug class is the bats-macos CI job (real /bin/bash 3.2.57)."
  fi

  local d="$BATS_TEST_TMPDIR/scan-bad"
  mkdir -p "$d"
  cat > "$d/bad.sh" << 'EOF'
#!/bin/bash
set -euo pipefail
_PRUNE_ERR="$(cat << PRUNE_SQL
select 1;
PRUNE_SQL
)"
case "${1:-}" in
  a) echo a ;;&
  b) echo b ;;
esac
echo "$_PRUNE_ERR"
EOF
  CAST_LINT_BASH32_BASH="$probe_bash" CAST_LINT_BASH32_DIR="$d" run bash "$LINT_SCRIPT"
  assert_failure
  assert_output --partial "bad.sh"
  assert_output --partial "BLOCKED"
}

@test "bash32-parse-lint passes a clean script, including a benign heredoc inside \$(...)" {
  local d="$BATS_TEST_TMPDIR/scan-clean"
  mkdir -p "$d"
  cat > "$d/good.sh" << 'EOF'
#!/bin/bash
set -euo pipefail
OUT="$(cat << PRUNE_SQL
select 1;
PRUNE_SQL
)"
echo "$OUT"
EOF
  CAST_LINT_BASH32_DIR="$d" run bash "$LINT_SCRIPT"
  assert_success
  assert_output --partial "parse clean"
}

@test "bash32-parse-lint --help exits 0 and prints usage" {
  run bash "$LINT_SCRIPT" --help
  assert_success
  assert_output --partial "Usage"
}

@test "bash32-parse-lint output states the weaker-on-Linux caveat" {
  local d="$BATS_TEST_TMPDIR/scan-caveat"
  mkdir -p "$d"
  cat > "$d/good.sh" << 'EOF'
#!/bin/bash
set -euo pipefail
echo "hi"
EOF
  CAST_LINT_BASH32_DIR="$d" run bash "$LINT_SCRIPT"
  assert_success
  assert_output --partial "WEAKER on Linux"
}

@test "bash32-parse-lint exits 1 with scanned-0 error for an empty directory" {
  local d="$BATS_TEST_TMPDIR/scan-empty"
  mkdir -p "$d"
  CAST_LINT_BASH32_DIR="$d" run bash "$LINT_SCRIPT"
  assert_failure
  assert_output --partial "scanned 0"
}

@test "bash32-parse-lint ignores files without a bash shebang" {
  local d="$BATS_TEST_TMPDIR/scan-nonbash"
  mkdir -p "$d"
  cat > "$d/script.py" << 'EOF'
#!/usr/bin/env python3
print("hi")
EOF
  cat > "$d/good.sh" << 'EOF'
#!/bin/bash
set -euo pipefail
echo "hi"
EOF
  CAST_LINT_BASH32_DIR="$d" run bash "$LINT_SCRIPT"
  assert_success
  assert_output --partial "1 bash-shebang"
}

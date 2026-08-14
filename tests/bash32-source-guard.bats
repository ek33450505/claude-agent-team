#!/usr/bin/env bats
# tests/bash32-source-guard.bats — Regression coverage for the bash 3.2
# `source <missing-file> || ...` fatality bug under `set -e`.
#
# CRITICAL: every test here pins the interpreter to /bin/bash BY ABSOLUTE PATH.
# Apple's frozen /bin/bash (3.2.57) has the bug; a plain `bash`/`run bash` on a
# machine where Homebrew bash (4+/5.x) is first on PATH does NOT reproduce it —
# that mistake makes the "guarded pattern survives" test pass vacuously and only
# fail on the bats-macos CI runner. Never relax `/bin/bash` to `bash` here.
#
# Coverage:
#   1. Negative control: bare `source X || true` DOES abort under /bin/bash + set -e
#      (proves the bug is real on this interpreter — guards against a vacuous suite).
#      SKIPPED when /bin/bash is bash 4+ (e.g. the bats-ubuntu CI runner), where the
#      3.2 fatality bug does not reproduce.
#   2. Positive: the existence-guarded idiom (if [[ -f ]]; then source; fi) SURVIVES
#      a missing candidate under /bin/bash + set -e
#   3. Positive: the two-candidate fallback form (as used in cast-maintenance.sh,
#      cast-cookbook-drift.sh, etc.) SURVIVES when BOTH candidates are missing
#   4. Positive: the subshell-wrapped form ( source X && cmd ) || true SURVIVES
#      a missing file under /bin/bash + set -e
#   5. Sanity (informational, always passes): records the /bin/bash major version on
#      this host. Documents why test 1 gates (bash < 4) or skips (bash 4+) instead of
#      asserting a specific version — this repo's CI legitimately runs /bin/bash 3.2
#      on macOS and 5.x on Ubuntu.

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'
load 'helpers/setup'

BASH32="/bin/bash"

setup() {
  setup_temp_home
}

teardown() {
  teardown_temp_home
}

@test "sanity: record /bin/bash major version on this host (informational)" {
  run "$BASH32" -c 'echo "${BASH_VERSINFO[0]}"'
  assert_success
  echo "# /bin/bash major version on this host: ${output} (informational only — does not gate)" >&3
}

@test "negative control: bare unguarded source || true ABORTS under /bin/bash + set -e" {
  local v
  v="$("$BASH32" -c 'echo ${BASH_VERSINFO[0]}')"
  [[ "$v" -lt 4 ]] || skip "/bin/bash is ${v}.x — the 3.2 source-fatality bug does not apply"

  local fixture="$BATS_TEST_TMPDIR/bare.sh"
  cat > "$fixture" << 'EOF'
set -euo pipefail
source /nonexistent/a.sh 2>/dev/null || source /nonexistent/b.sh 2>/dev/null || true
echo "SURVIVED"
EOF
  run "$BASH32" "$fixture"
  assert_failure
  refute_output --partial "SURVIVED"
}

@test "existence-guarded source (if [[ -f ]]; then source; fi) survives missing file" {
  local fixture="$BATS_TEST_TMPDIR/guarded.sh"
  cat > "$fixture" << 'EOF'
set -euo pipefail
_lib="/nonexistent/a.sh"
if [[ -f "$_lib" ]]; then
  source "$_lib" 2>/dev/null || true
fi
echo "SURVIVED"
EOF
  run "$BASH32" "$fixture"
  assert_success
  assert_output --partial "SURVIVED"
}

@test "two-candidate fallback idiom survives when both candidates are missing" {
  local fixture="$BATS_TEST_TMPDIR/twocand.sh"
  cat > "$fixture" << 'EOF'
set -euo pipefail
_lib="/nonexistent/primary.sh"
[[ -f "$_lib" ]] || _lib="/nonexistent/fallback.sh"
if [[ -f "$_lib" ]]; then
  source "$_lib" 2>/dev/null || true
fi
echo "SURVIVED"
EOF
  run "$BASH32" "$fixture"
  assert_success
  assert_output --partial "SURVIVED"
}

@test "subshell-wrapped source survives missing file" {
  local fixture="$BATS_TEST_TMPDIR/subshell.sh"
  cat > "$fixture" << 'EOF'
set -euo pipefail
( source /nonexistent/a.sh 2>/dev/null && echo "should not print" ) || true
echo "SURVIVED"
EOF
  run "$BASH32" "$fixture"
  assert_success
  assert_output --partial "SURVIVED"
}

@test "cast-guard-lib.sh's own documented header idiom survives a missing lib" {
  local repo_dir
  repo_dir="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  local fixture="$BATS_TEST_TMPDIR/real-lib.sh"
  # Mirrors the exact shape now used in scripts/cast-maintenance.sh, pointed at
  # the REAL cast-guard-lib.sh via CAST_SCRIPTS_DIR-equivalent, but with the
  # primary candidate deliberately missing so only the fallback resolves.
  cat > "$fixture" << EOF
set -euo pipefail
_cast_guard_lib="/nonexistent/cast-guard-lib.sh"
[[ -f "\$_cast_guard_lib" ]] || _cast_guard_lib="${repo_dir}/scripts/cast-guard-lib.sh"
if [[ -f "\$_cast_guard_lib" ]]; then
  source "\$_cast_guard_lib" 2>/dev/null || true
fi
declare -f cast_safe_rm >/dev/null 2>&1 && echo "LOADED"
echo "SURVIVED"
EOF
  run "$BASH32" "$fixture"
  assert_success
  assert_output --partial "LOADED"
  assert_output --partial "SURVIVED"
}

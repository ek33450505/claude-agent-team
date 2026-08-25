#!/usr/bin/env bats
# tests/gen-plugin-tracked-only.bats
#
# Regression coverage for the gen-plugin.sh supply-chain leak: the skills/ and
# commands/ bundling steps must copy ONLY git-tracked files, never the raw
# working tree. Untracked/gitignored content (e.g. skills/neon,
# skills/neon-postgres — third-party skills installed via `npx skills`,
# gitignored per PR #380) must never reach the bundled plugin output.
# See scripts/gen-plugin.sh Step 4 (skills) and Step 5 (commands).

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'
load 'helpers/setup'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
# Overridable so a mutation-test run can point at a deliberately-reverted copy
# of the script without touching the real file or any git state.
GEN_PLUGIN_SRC="${GEN_PLUGIN_SRC_OVERRIDE:-${REPO_DIR}/scripts/gen-plugin.sh}"
GUARD_LIB_SRC="${REPO_DIR}/scripts/cast-guard-lib.sh"

# Minimal PATH so gen-plugin.sh's optional `claude plugin validate` step
# (Step 10) is deterministically skipped, regardless of whether the claude
# CLI happens to be on the host PATH — keeps the test hermetic and fast.
_safe_test_path() {
  local d
  for d in /usr/bin /bin /usr/local/bin /opt/homebrew/bin; do
    [[ -d "$d" ]] && printf '%s:' "$d"
  done
}

# Builds a self-contained fixture git repo under $1 (must be inside
# $BATS_TEST_TMPDIR): one tracked skill, two untracked/gitignored skill dirs
# mirroring skills/neon + skills/neon-postgres, one tracked command, and one
# untracked/gitignored command. Commits everything tracked.
build_fixture_repo() {
  local repo="$1"
  [[ "$repo" == "$BATS_TEST_TMPDIR"/* ]] || {
    echo "refusing to build fixture outside tmpdir: $repo" >&2
    return 1
  }

  mkdir -p \
    "${repo}/skills/tracked-skill" \
    "${repo}/skills/neon" \
    "${repo}/skills/neon-postgres" \
    "${repo}/commands" \
    "${repo}/agents/core" \
    "${repo}/scripts"

  printf 'Tracked skill body.\n' >"${repo}/skills/tracked-skill/SKILL.md"
  printf 'Third-party skill (should never bundle).\n' >"${repo}/skills/neon/SKILL.md"
  printf 'Third-party skill (should never bundle).\n' >"${repo}/skills/neon-postgres/SKILL.md"

  printf 'Tracked command body.\n' >"${repo}/commands/tracked-cmd.md"
  printf 'Untracked command (should never bundle).\n' >"${repo}/commands/untracked-cmd.md"

  cp "$GEN_PLUGIN_SRC" "${repo}/scripts/gen-plugin.sh"
  cp "$GUARD_LIB_SRC" "${repo}/scripts/cast-guard-lib.sh"

  {
    printf 'skills/neon\n'
    printf 'skills/neon-postgres\n'
    printf 'commands/untracked-cmd.md\n'
  } >"${repo}/.gitignore"

  (
    cd "$repo" || exit 1
    git init -q
    git config user.email "test@example.com"
    git config user.name "gen-plugin-tests"
    git add -A
    git commit -q -m "fixture: tracked-only baseline"
  )
}

run_gen_plugin() {
  local repo="$1" out="$2"
  PATH="$(_safe_test_path)" bash "${repo}/scripts/gen-plugin.sh" "$out"
}

setup() {
  setup_temp_home
  FIXTURE_REPO="${BATS_TEST_TMPDIR}/repo"
  FIXTURE_OUT="${BATS_TEST_TMPDIR}/out"
  build_fixture_repo "$FIXTURE_REPO"
}

teardown() {
  teardown_temp_home
}

@test "skills: untracked/gitignored dirs (neon, neon-postgres) excluded from output" {
  run run_gen_plugin "$FIXTURE_REPO" "$FIXTURE_OUT"
  assert_success
  [[ ! -e "${FIXTURE_OUT}/skills/neon" ]] || fail "leak: skills/neon was bundled"
  [[ ! -e "${FIXTURE_OUT}/skills/neon-postgres" ]] || fail "leak: skills/neon-postgres was bundled"
}

@test "skills: tracked skill IS bundled (over-correction fence)" {
  run run_gen_plugin "$FIXTURE_REPO" "$FIXTURE_OUT"
  assert_success
  [[ -f "${FIXTURE_OUT}/skills/tracked-skill/SKILL.md" ]] || fail "tracked-skill/SKILL.md missing from output"
  grep -q "Tracked skill body." "${FIXTURE_OUT}/skills/tracked-skill/SKILL.md"
}

@test "commands: untracked/gitignored .md excluded from output" {
  run run_gen_plugin "$FIXTURE_REPO" "$FIXTURE_OUT"
  assert_success
  [[ ! -e "${FIXTURE_OUT}/commands/untracked-cmd.md" ]] || fail "leak: commands/untracked-cmd.md was bundled"
}

@test "commands: tracked command IS bundled (over-correction fence)" {
  run run_gen_plugin "$FIXTURE_REPO" "$FIXTURE_OUT"
  assert_success
  [[ -f "${FIXTURE_OUT}/commands/tracked-cmd.md" ]] || fail "tracked-cmd.md missing from output"
  grep -q "Tracked command body." "${FIXTURE_OUT}/commands/tracked-cmd.md"
}

@test "not a git repo: script fails non-zero instead of bundling the working tree" {
  local norepo="${BATS_TEST_TMPDIR}/norepo"
  mkdir -p "${norepo}/scripts" "${norepo}/skills/neon"
  printf 'third-party\n' >"${norepo}/skills/neon/SKILL.md"
  cp "$GEN_PLUGIN_SRC" "${norepo}/scripts/gen-plugin.sh"
  cp "$GUARD_LIB_SRC" "${norepo}/scripts/cast-guard-lib.sh"
  # Deliberately no `git init` — norepo is not inside any work tree.

  run env PATH="$(_safe_test_path)" bash "${norepo}/scripts/gen-plugin.sh" "${BATS_TEST_TMPDIR}/norepo-out"
  assert_failure
  [[ ! -e "${BATS_TEST_TMPDIR}/norepo-out/skills/neon" ]] || fail "leak: bundled the working tree despite no git repo"
}

@test "skills: pre-existing missing-SKILL.md assertion still fires for a tracked dir" {
  local repo="${BATS_TEST_TMPDIR}/repo-broken"
  mkdir -p "${repo}/skills/broken-skill" "${repo}/commands" "${repo}/agents/core" "${repo}/scripts"
  printf 'no SKILL.md here\n' >"${repo}/skills/broken-skill/other.md"
  cp "$GEN_PLUGIN_SRC" "${repo}/scripts/gen-plugin.sh"
  cp "$GUARD_LIB_SRC" "${repo}/scripts/cast-guard-lib.sh"
  (
    cd "$repo" || exit 1
    git init -q
    git config user.email "test@example.com"
    git config user.name "gen-plugin-tests"
    git add -A
    git commit -q -m "fixture: tracked skill missing SKILL.md"
  )

  run run_gen_plugin "$repo" "${BATS_TEST_TMPDIR}/broken-out"
  assert_failure
  assert_output --partial "missing SKILL.md"
}

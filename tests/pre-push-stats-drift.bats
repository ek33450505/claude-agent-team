#!/usr/bin/env bats
# Tests for the stats-drift gate in .githooks/pre-push
#
# Covers:
#   (a) Drift in the pushed SHA is caught even when the working tree is clean/regenerated
#   (b) A clean pushed SHA passes the gate
#   (c) Deletion pushes (local_sha = 40 zeros) are skipped without error
#   (d) CAST_SKIP_STATS_PUSH=1 bypasses the gate entirely
#
# Design:
#   The gate creates a throwaway detached worktree from the pushed SHA and runs
#   scripts/gen-cast-stats.sh --check from that committed tree.  Inside BATS the
#   real gen-cast-stats.sh self-skips via its BATS_* env guard, so each fixture repo
#   carries a stub scripts/gen-cast-stats.sh that exits 0 (clean) or 1 (drift).
#   The stub travels with the fixture and is therefore the script the gate actually
#   executes from the worktree.
#
# Safety:
#   All fixture repos live under mktemp -d directories.
#   The hook is called via a subshell that cd's into the fixture; $REPO_ROOT resolves
#   to the fixture, not the real repo.
#   No real $HOME or ~/.claude paths are touched.

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
HOOK="$REPO_DIR/.githooks/pre-push"

# ---------------------------------------------------------------------------
# Helper: build a minimal fixture git repo.
#
# $1 — stub exit code for scripts/gen-cast-stats.sh (0 = clean, 1 = drift)
#
# Prints the path to the fixture repo root.
# ---------------------------------------------------------------------------
_make_fixture_repo() {
  local stub_exit="${1:-0}"
  local tmpdir
  tmpdir="$(mktemp -d)"

  git init -q "$tmpdir"
  git -C "$tmpdir" config user.email "test@example.com"
  git -C "$tmpdir" config user.name "CAST Test"

  mkdir -p "$tmpdir/scripts"

  # Stub gen-cast-stats.sh — the gate runs this from the pushed SHA's worktree.
  # It deliberately has NO BATS guard so the exit code is predictable regardless
  # of whether BATS_* env vars are set in the parent process.
  printf '#!/usr/bin/env bash\n# stats-drift stub: exits %s\nexit %s\n' \
    "$stub_exit" "$stub_exit" > "$tmpdir/scripts/gen-cast-stats.sh"
  chmod +x "$tmpdir/scripts/gen-cast-stats.sh"

  # Placeholder cast-stats.json so the pushed tree looks realistic.
  printf '{"version":"stub"}\n' > "$tmpdir/cast-stats.json"

  git -C "$tmpdir" add scripts/gen-cast-stats.sh cast-stats.json
  git -C "$tmpdir" commit -q -m "init"

  echo "$tmpdir"
}

# ---------------------------------------------------------------------------
# Helper: run the pre-push hook inside a fixture repo.
#
# $1 — absolute path to the fixture repo
# $2 — stdin data to feed to the hook (push ref lines, may be empty)
# $3 — (optional) extra env var assignment, e.g. "CAST_SKIP_STATS_PUSH=1"
#
# All gates except stats-drift are disabled so failures stay scoped.
# Sets $output and $status via bats `run` semantics.
# ---------------------------------------------------------------------------
_run_hook_in_fixture() {
  local fixture_repo="$1"
  local stdin_data="${2:-}"
  local extra_env="${3:-}"

  local out rc=0
  out=$(
    cd "$fixture_repo" || exit 1
    # Disable all gates except the stats-drift gate under test.
    export CAST_SKIP_PII_CHECK=1
    export CAST_SKIP_DB_CONTRACT=1
    export CAST_SKIP_RULES_DRIFT=1
    export CAST_SKIP_README_STRUCTURE=1
    # Apply any extra env var (e.g. CAST_SKIP_STATS_PUSH=1).
    if [ -n "$extra_env" ]; then
      # Safe: extra_env is a single "KEY=VALUE" string constructed by the test.
      export "$extra_env" 2>/dev/null || true
    fi
    printf '%s' "$stdin_data" | bash "$HOOK" 2>&1
  ) || rc=$?

  output="$out"
  status="$rc"
}

# ---------------------------------------------------------------------------
# Setup / teardown
# ---------------------------------------------------------------------------

setup() {
  TEST_FIXTURES=()
}

teardown() {
  # Remove all fixture repos created during the test.
  local f
  for f in "${TEST_FIXTURES[@]+"${TEST_FIXTURES[@]}"}"; do
    [ -d "$f" ] && rm -rf "$f"
  done
}

# ---------------------------------------------------------------------------
# (a) Drift in the pushed SHA is caught even when working tree is clean
# ---------------------------------------------------------------------------

@test "(a) drift in pushed SHA fails the gate even with a clean working tree" {
  local repo
  repo="$(_make_fixture_repo 1)"  # committed stub exits 1 → drift in pushed tree
  TEST_FIXTURES+=("$repo")

  local sha
  sha="$(git -C "$repo" rev-parse HEAD)"

  # Discriminating condition: overwrite the working-tree copy of gen-cast-stats.sh
  # with an exit-0 stub WITHOUT committing.  This creates a divergence between what
  # the working tree says (clean / exit 0) and what the committed pushed tree says
  # (drift / exit 1).
  #
  # Old implementation (runs gen-cast-stats.sh from the working tree):
  #   sees exit 0 → would let the push through → assert_failure FAILS.
  # New implementation (runs gen-cast-stats.sh from a detached worktree of the pushed SHA):
  #   sees exit 1 → blocks the push → assert_failure PASSES.
  #
  # The test is therefore non-discriminating against the old implementation and
  # discriminating (passing only) against the new one.
  printf '#!/usr/bin/env bash\n# working-tree stub: regenerated clean — exit 0\nexit 0\n' \
    > "$repo/scripts/gen-cast-stats.sh"
  # Do NOT commit — the dirty working-tree state is the discriminating condition.

  local ref_line="refs/heads/main ${sha} refs/heads/main 0000000000000000000000000000000000000000"

  _run_hook_in_fixture "$repo" "$ref_line"

  assert_failure
  assert_output --partial "cast-stats.json is out of sync"
}

# ---------------------------------------------------------------------------
# (b) A clean pushed SHA passes the gate
# ---------------------------------------------------------------------------

@test "(b) clean pushed SHA passes the gate" {
  local repo
  repo="$(_make_fixture_repo 0)"  # stub exits 0 → clean
  TEST_FIXTURES+=("$repo")

  local sha
  sha="$(git -C "$repo" rev-parse HEAD)"

  local ref_line="refs/heads/main ${sha} refs/heads/main 0000000000000000000000000000000000000000"

  _run_hook_in_fixture "$repo" "$ref_line"

  assert_success
  assert_output --partial "cast-stats.json in sync"
}

# ---------------------------------------------------------------------------
# (c) Deletion pushes (local_sha = 40 zeros) are skipped
# ---------------------------------------------------------------------------

@test "(c) deletion push (local_sha = zeros) is skipped without error" {
  local repo
  repo="$(_make_fixture_repo 0)"  # stub exits 0 — HEAD fallback validates cleanly
  TEST_FIXTURES+=("$repo")

  local sha
  sha="$(git -C "$repo" rev-parse HEAD)"

  # Deletion push: the local ref is being deleted (local_sha = all zeros).
  # The gate must skip the zeros SHA — never pass it to git worktree add.
  # With no non-zero SHA to validate the gate falls back to HEAD; HEAD's stub
  # exits 0, so the overall gate passes.
  local ref_line="refs/heads/feature 0000000000000000000000000000000000000000 refs/heads/feature ${sha}"

  _run_hook_in_fixture "$repo" "$ref_line"

  # Zeros SHA was never used as a worktree target.
  refute_output --partial "Could not create stats-check worktree for 000000"
  # Gate exits 0 — deletion push is not blocked.
  assert_success
}

# ---------------------------------------------------------------------------
# (c-skip) Deletion-only push with CAST_SKIP_STATS_PUSH=1 exits 0
# ---------------------------------------------------------------------------

@test "(c-skip) deletion push with CAST_SKIP_STATS_PUSH=1 is fully skipped" {
  local repo
  repo="$(_make_fixture_repo 1)"
  TEST_FIXTURES+=("$repo")

  local sha
  sha="$(git -C "$repo" rev-parse HEAD)"

  local ref_line="refs/heads/feature 0000000000000000000000000000000000000000 refs/heads/feature ${sha}"

  _run_hook_in_fixture "$repo" "$ref_line" "CAST_SKIP_STATS_PUSH=1"

  assert_success
  assert_output --partial "Skipping stats-drift check"
}

# ---------------------------------------------------------------------------
# (d) CAST_SKIP_STATS_PUSH=1 bypasses the gate entirely
# ---------------------------------------------------------------------------

@test "(d) CAST_SKIP_STATS_PUSH=1 bypasses the stats-drift gate" {
  local repo
  repo="$(_make_fixture_repo 1)"  # stub exits 1 — would fail without bypass
  TEST_FIXTURES+=("$repo")

  local sha
  sha="$(git -C "$repo" rev-parse HEAD)"

  local ref_line="refs/heads/main ${sha} refs/heads/main 0000000000000000000000000000000000000000"

  _run_hook_in_fixture "$repo" "$ref_line" "CAST_SKIP_STATS_PUSH=1"

  assert_success
  assert_output --partial "Skipping stats-drift check"
  refute_output --partial "cast-stats.json is out of sync"
}

# ---------------------------------------------------------------------------
# Fallback: empty stdin falls back to HEAD
# ---------------------------------------------------------------------------

@test "empty stdin (manual invocation) falls back to validating HEAD" {
  local repo
  repo="$(_make_fixture_repo 0)"  # HEAD is clean
  TEST_FIXTURES+=("$repo")

  # No stdin — simulates manual hook invocation or `git push` with no refs.
  _run_hook_in_fixture "$repo" ""

  assert_success
  assert_output --partial "cast-stats.json in sync"
}

@test "empty stdin with drifted HEAD reports drift" {
  local repo
  repo="$(_make_fixture_repo 1)"  # HEAD has drift
  TEST_FIXTURES+=("$repo")

  _run_hook_in_fixture "$repo" ""

  assert_failure
  assert_output --partial "cast-stats.json is out of sync"
}

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
#   The gate materialises the pushed SHA's committed tree in a throwaway standalone
#   repo and runs the INSTALLED gen-cast-stats.sh / gen-stats.sh --check against it
#   (CAST_REPO_ROOT = that export; no repo file is ever executed).  Inside BATS the
#   real gen-cast-stats.sh self-skips via its BATS_* env guard, so the installed copy
#   here is a stub (temp HOME) that reads the verdict from the EXPORTED tree: it exits
#   1 (drift) when $CAST_REPO_ROOT/cast-stats.json says "drift", else 0 (clean).  The
#   fixture's committed cast-stats.json therefore decides the outcome, exactly as a
#   real committed file would.
#
# Safety:
#   All fixture repos live under mktemp -d directories.
#   The hook is called via a subshell that cd's into the fixture; $REPO_ROOT resolves
#   to the fixture, not the real repo.
#   No real $HOME or ~/.claude paths are touched.

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'
load 'helpers/setup'
load 'helpers/prepush-installed'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
HOOK="$REPO_DIR/.githooks/pre-push"

# ---------------------------------------------------------------------------
# Helper: build a minimal fixture git repo.
#
# $1 — 0 = committed cast-stats.json is clean, 1 = it is drifted
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

  # The verdict file travels with the pushed tree: "drift" makes the installed stub exit 1.
  if [ "$stub_exit" = "0" ]; then
    printf '{"version":"clean"}\n' > "$tmpdir/cast-stats.json"
  else
    printf '{"version":"drift"}\n' > "$tmpdir/cast-stats.json"
  fi
  git -C "$tmpdir" add cast-stats.json
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
  setup_temp_home
  seed_prepush_install
  # Installed stub: the verdict is read from the tree the hook EXPORTED for the pushed SHA.
  cat > "$INSTALLED/gen-cast-stats.sh" <<'STUBEOF'
#!/usr/bin/env bash
if grep -q drift "$CAST_REPO_ROOT/cast-stats.json"; then
  echo "[stub gen-cast-stats] drift in $CAST_REPO_ROOT" >&2
  exit 1
fi
exit 0
STUBEOF
  chmod +x "$INSTALLED/gen-cast-stats.sh"
}

teardown() {
  # Remove all fixture repos created during the test.
  local f
  for f in "${TEST_FIXTURES[@]+"${TEST_FIXTURES[@]}"}"; do
    [ -d "$f" ] && rm -rf "$f"
  done
  teardown_temp_home
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

  # Discriminating condition: overwrite the working-tree cast-stats.json with a clean one
  # WITHOUT committing.  This creates a divergence between what the working tree says
  # (clean) and what the committed pushed tree says (drift).
  #
  # An implementation that checks the working tree sees clean → lets the push through →
  # assert_failure FAILS.  One that checks the pushed SHA's tree sees drift → blocks the
  # push → assert_failure PASSES.
  printf '{"version":"clean"}\n' > "$repo/cast-stats.json"
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
  # The gate must skip the zeros SHA — never export it as a tree.
  # With no non-zero SHA to validate the gate falls back to HEAD; HEAD's stub
  # exits 0, so the overall gate passes.
  local ref_line="refs/heads/feature 0000000000000000000000000000000000000000 refs/heads/feature ${sha}"

  _run_hook_in_fixture "$repo" "$ref_line"

  # Zeros SHA was never used as an export target.
  refute_output --partial "Could not export the pushed tree for 000000"
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

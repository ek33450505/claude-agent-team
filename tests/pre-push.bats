#!/usr/bin/env bats
# Tests for .githooks/pre-push top-level deletion-skip logic
#
# Covers:
#   - Deletion-only pushes (local_sha = 40 zeros) should skip slow checks
#   - All checks (ubuntu, PII, stats, db-contract, rules-drift, README) are skipped
#   - Hook exits 0 and logs "[CAST pre-push] Skipping ubuntu check (deletion-only push)"

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
HOOK="$REPO_DIR/.githooks/pre-push"

setup() {
  # Create a minimal test fixture git repo
  TEST_REPO="$(mktemp -d)"
  git init -q "$TEST_REPO"
  git -C "$TEST_REPO" config user.email "test@example.com"
  git -C "$TEST_REPO" config user.name "CAST Test"
  git -C "$TEST_REPO" commit -q --allow-empty -m "init"

  # Create stub scripts so the hook doesn't fail
  mkdir -p "$TEST_REPO/scripts"

  # Stub pre-push-ci-check.sh
  cat > "$TEST_REPO/scripts/pre-push-ci-check.sh" <<'STUBEOF'
#!/usr/bin/env bash
exit 0
STUBEOF
  chmod +x "$TEST_REPO/scripts/pre-push-ci-check.sh"

  # Stub gen-cast-stats.sh (created in worktree, so stub in original repo too)
  cat > "$TEST_REPO/scripts/gen-cast-stats.sh" <<'STUBEOF'
#!/usr/bin/env bash
exit 0
STUBEOF
  chmod +x "$TEST_REPO/scripts/gen-cast-stats.sh"

  # Create stub gen-rules-manifest.sh
  cat > "$TEST_REPO/scripts/gen-rules-manifest.sh" <<'STUBEOF'
#!/usr/bin/env bash
mkdir -p .github
touch .github/rules-core.manifest
exit 0
STUBEOF
  chmod +x "$TEST_REPO/scripts/gen-rules-manifest.sh"

  # Create stub cast-db-contract.py
  cat > "$TEST_REPO/scripts/cast-db-contract.py" <<'STUBEOF'
#!/usr/bin/env python3
import sys
if '--check' in sys.argv:
    exit(0)
STUBEOF
  chmod +x "$TEST_REPO/scripts/cast-db-contract.py"

  # Create stub .github/db-contract-baseline.json
  mkdir -p "$TEST_REPO/.github"
  echo '{}' > "$TEST_REPO/.github/db-contract-baseline.json"

  # Create README.md with required sections
  cat > "$TEST_REPO/README.md" <<'STUBEOF'
# Test Repo
## Installation
## Agents
## Hooks
## Testing
STUBEOF
}

teardown() {
  rm -rf "$TEST_REPO"
}

# ---------------------------------------------------------------------------
# Helper: run pre-push hook with a deletion ref on stdin
# ---------------------------------------------------------------------------
_run_hook_with_ref() {
  local ref_line="$1"
  local repo="$2"
  (
    cd "$repo" || exit 1
    # Skip optional gates (stats, db-contract, rules-drift checks)
    # to test just the deletion-skip logic without full gate setup
    printf '%s' "$ref_line" | \
      CAST_SKIP_STATS_PUSH=1 \
      CAST_SKIP_DB_CONTRACT=1 \
      CAST_SKIP_RULES_DRIFT=1 \
      CAST_SKIP_PII_CHECK=1 \
      bash "$HOOK" 2>&1
  )
  return $?
}

# ---------------------------------------------------------------------------
# Test: deletion-only push skips all checks and exits 0
# ---------------------------------------------------------------------------

@test "deletion-only push (local_sha = zeros) skips checks and exits 0" {
  # Deletion ref-line: "refs/heads/feature 0000000000000000000000000000000000000000 refs/heads/feature <remote-sha>"
  local remote_sha
  remote_sha="$(git -C "$TEST_REPO" rev-parse HEAD)"

  local ref_line="refs/heads/feature 0000000000000000000000000000000000000000 refs/heads/feature ${remote_sha}"

  run _run_hook_with_ref "$ref_line" "$TEST_REPO"

  # Hook must exit 0 (deletion pushes are not blocked)
  assert_success

  # Hook must log that it's skipping the ubuntu check
  assert_output --partial "Skipping ubuntu check (deletion-only push)"
}

# ---------------------------------------------------------------------------
# Test: mixed push (some deletions, some normal) does NOT skip
# ---------------------------------------------------------------------------

@test "mixed push (deletion + normal commit) does NOT skip" {
  # Create a second branch to push a real commit
  git -C "$TEST_REPO" checkout -q -b feature
  echo "test" > "$TEST_REPO/test.txt"
  git -C "$TEST_REPO" add test.txt
  git -C "$TEST_REPO" commit -q -m "add test file"

  local commit_sha
  commit_sha="$(git -C "$TEST_REPO" rev-parse HEAD)"

  # Ref line 1: deletion (refs/heads/feature)
  # Ref line 2: normal push (refs/heads/feature)
  # This is a mixed push — should NOT skip
  local ref_line1="refs/heads/delete-me 0000000000000000000000000000000000000000 refs/heads/delete-me 1234567890abcdef1234567890abcdef12345678"
  local ref_line2="refs/heads/feature ${commit_sha} refs/heads/feature 0000000000000000000000000000000000000000"

  run _run_hook_with_ref "$(printf '%s\n%s' "$ref_line1" "$ref_line2")" "$TEST_REPO"

  # Hook should NOT skip (since one ref is not a deletion)
  # The ubuntu check output should NOT say "deletion-only"
  # (It may still pass since Docker is likely not running, but the message must differ)
  refute_output --partial "deletion-only push"
}

# ---------------------------------------------------------------------------
# Test: multiple deletions all skipped
# ---------------------------------------------------------------------------

@test "multiple deletion refs all skipped" {
  # Two deletion refs (both local_sha = zeros)
  local ref_line1="refs/heads/feature1 0000000000000000000000000000000000000000 refs/heads/feature1 1234567890abcdef1234567890abcdef12345678"
  local ref_line2="refs/heads/feature2 0000000000000000000000000000000000000000 refs/heads/feature2 abcdef1234567890abcdef1234567890abcdef12"

  run _run_hook_with_ref "$(printf '%s\n%s' "$ref_line1" "$ref_line2")" "$TEST_REPO"

  assert_success

  # Both should be detected as deletions, so the skip message appears
  assert_output --partial "Skipping ubuntu check (deletion-only push)"
}

#!/usr/bin/env bats

setup() {
  cd "$(git rev-parse --show-toplevel)" || exit 1
}

@test "manifest script regenerates without error" {
  run bash scripts/gen-rules-manifest.sh
  [ "$status" -eq 0 ]
  [ -f .github/rules-core.manifest ]
}

@test "manifest matches current rules-core" {
  # Generate twice and verify they match
  bash scripts/gen-rules-manifest.sh
  cp .github/rules-core.manifest "$BATS_TEST_TMPDIR/manifest1.txt"

  bash scripts/gen-rules-manifest.sh
  cp .github/rules-core.manifest "$BATS_TEST_TMPDIR/manifest2.txt"

  # Should be identical
  diff "$BATS_TEST_TMPDIR/manifest1.txt" "$BATS_TEST_TMPDIR/manifest2.txt"
}

@test "manifest flags drift after a file edit" {
  # Isolate in a disposable worktree: gen-rules-manifest.sh internally does
  # `cd "$(git rev-parse --show-toplevel)"`, so only a worktree (a real repo
  # root of its own) keeps the edit+regenerate+checkout off the real tree.
  local worktree
  worktree="$(mktemp -d)"
  git worktree add "$worktree" HEAD >/dev/null

  (
    cd "$worktree"

    # Generate baseline
    bash scripts/gen-rules-manifest.sh
    cp .github/rules-core.manifest "$BATS_TEST_TMPDIR/manifest_before.txt"

    # Modify a rules-core file (in the worktree only)
    echo "# drift test" >>rules-core/working-conventions.md

    # Regenerate manifest
    bash scripts/gen-rules-manifest.sh
    cp .github/rules-core.manifest "$BATS_TEST_TMPDIR/manifest_after.txt"
  )

  git worktree remove "$worktree" --force

  # Should differ (negation test)
  ! diff "$BATS_TEST_TMPDIR/manifest_before.txt" "$BATS_TEST_TMPDIR/manifest_after.txt" >/dev/null
}

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
  cp .github/rules-core.manifest /tmp/manifest1.txt

  bash scripts/gen-rules-manifest.sh
  cp .github/rules-core.manifest /tmp/manifest2.txt

  # Should be identical
  diff /tmp/manifest1.txt /tmp/manifest2.txt
}

@test "manifest flags drift after a file edit" {
  # Generate baseline
  bash scripts/gen-rules-manifest.sh
  cp .github/rules-core.manifest /tmp/manifest_before.txt

  # Modify a rules-core file
  echo "# drift test" >> rules-core/working-conventions.md

  # Regenerate manifest
  bash scripts/gen-rules-manifest.sh
  cp .github/rules-core.manifest /tmp/manifest_after.txt

  # Should differ (negation test)
  ! diff /tmp/manifest_before.txt /tmp/manifest_after.txt > /dev/null

  # Restore the file
  git checkout rules-core/working-conventions.md

  # Regenerate to clean state
  bash scripts/gen-rules-manifest.sh
}

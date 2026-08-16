#!/bin/bash
set -euo pipefail

# Guard: skip in subprocess
if [[ "${CLAUDE_SUBPROCESS:-}" == "1" ]]; then
  exit 0
fi

# Ensure we're at repo root (resolved from this script's own location, not the CWD)
cd "$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"

# Generate manifest of all rules-core files (both .md and .template)
find rules-core -type f \( -name "*.md" -o -name "*.template" \) | sort | xargs sha256sum > .github/rules-core.manifest

echo "[manifest] regenerated .github/rules-core.manifest with $(wc -l < .github/rules-core.manifest) entries"

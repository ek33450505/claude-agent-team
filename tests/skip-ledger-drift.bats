#!/usr/bin/env bats
# tests/skip-ledger-drift.bats — Guard: docs/test-skip-ledger.md recorded total must
# match the actual skip-site count found by the canonical enumeration command.
#
# When a skip is added or removed the ledger MUST be updated; this test fails if they
# drift apart. Re-run the enumeration command (printed in the failure message) to get
# the current count, update the ledger, and this test will pass again.
#
# No temp-HOME isolation required: this test only reads source files, never touches
# ~/.claude or any live runtime state.

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

@test "skip-ledger: recorded total matches actual skip-site count" {
  local ledger="$REPO_DIR/docs/test-skip-ledger.md"
  [ -f "$ledger" ] || fail "skip ledger not found at $ledger"

  # Parse the 'Total call sites: N' line from the ledger.
  # Accepts the exact format written by this document: "**Total call sites: 54**"
  local recorded
  recorded=$(grep -E 'Total call sites: [0-9]+' "$ledger" | grep -oE '[0-9]+' | head -1)
  [ -n "$recorded" ] || fail "could not parse 'Total call sites: N' from $ledger"

  # Canonical enumeration — catches all 4 skip forms:
  #   || skip "..."
  #   && skip "..."
  #   line-leading    skip "..."  (indent + bare call, multi-line if-then body)
  #   if-then inline  skip "..."  (same-line: if [...]; then skip "..."; fi)
  # Excludes comment lines (lines whose content starts with optional whitespace + #).
  # Excludes this file itself — it contains the pattern as a string argument and
  # would otherwise produce a false match that inflates the count by 1.
  local actual
  actual=$(grep -rEn '(\|\| skip "|&& skip "|[[:space:]]skip ")' \
    "$REPO_DIR/tests/" --include="*.bats" \
    | grep -vF 'skip-ledger-drift.bats' \
    | grep -cvE '^[^:]+:[0-9]+:[[:space:]]*#' || true)

  # grep -c returns 1 when count is 0; use the pipeline form above to avoid false
  # failures. Normalise any trailing whitespace.
  actual=$(echo "$actual" | tr -d ' ')

  [ "$actual" -eq "$recorded" ] || {
    echo "FAIL: docs/test-skip-ledger.md records $recorded skip call sites but grep found $actual"
    echo ""
    echo "If you added or removed a skip, update the 'Total call sites' line in the ledger."
    echo ""
    echo "Re-run enumeration to see the full list:"
    echo "  grep -rEn '(|| skip \"|&& skip \"|[[:space:]]skip \")' tests/ --include='*.bats' \\"
    echo "    | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#'"
    return 1
  }
}

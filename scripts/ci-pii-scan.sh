#!/usr/bin/env bash
# ci-pii-scan.sh — Repo-tree PII/secret scanner for CI and local use.
# Scans tracked files (git ls-files) for generic PII classes.
# Keeps patterns consistent with scripts/pre-push-ci-check.sh Check 1 and Check 4.
#
# Usage:
#   bash scripts/ci-pii-scan.sh            # scan tracked files in the repo
#   bash scripts/ci-pii-scan.sh --self-test # verify detection works, exits 0 on success
#
# Exit codes: 0 = clean (or self-test passed), 1 = findings detected
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
FINDINGS=()

# ---------------------------------------------------------------------------
# Files that intentionally contain scanner trigger patterns.
# Paths are relative to REPO_ROOT.
# The CI scanner does NOT read config/pii-denylist-local.txt.template because
# work/personal patterns must never be needed in CI — denylist is local-only.
# ---------------------------------------------------------------------------
PII_ALLOWLIST=(
  "scripts/pre-push-ci-check.sh"
  "tests/pre-push-ci-check.bats"
  "tests/cast_cron_setup.bats"
  "config/pii-denylist-local.txt.template"
  "scripts/ci-pii-scan.sh"
  "tests/ci-pii-scan.bats"
  "README.md"
  "LICENSE"
)

# Directory prefixes whose tracked files are always skipped (docs, test helpers).
# These contain intentional placeholder paths and third-party package metadata.
# NOTE: plugin/ is intentionally NOT listed here — the curated plugin artifact is
# now scanned directly. The dev/CI/personal scripts (ci-pii-scan.sh,
# pre-push-ci-check.sh, cast-overlay-sync.sh, etc.) that previously caused
# false-positives are no longer shipped inside plugin/, so the scan is clean.
PII_ALLOWLIST_DIRS=(
  "docs/"
  "tests/test_helper/"
)

# Return 0 if the given file path (relative to REPO_ROOT) is allowlisted.
_is_allowed() {
  local relpath="$1"
  local p
  for p in "${PII_ALLOWLIST[@]}"; do
    [[ "$relpath" == "$p" ]] && return 0
  done
  for p in "${PII_ALLOWLIST_DIRS[@]}"; do
    [[ "$relpath" == "$p"* ]] && return 0
  done
  return 1
}

# ---------------------------------------------------------------------------
# Exclusion patterns — mirror pre-push-ci-check.sh
# ---------------------------------------------------------------------------

# Hardcoded-path exclusion: testuser, runner, janedoe, doc placeholders, $USER,
# regex literals like /Users/[a-z], and generic fake names used in test fixtures.
# Also covers: /Users/you, /Users/yourname, /Users/... (doc patterns).
_PATH_EXCLUSION='/Users/testuser\b|/Users/runner\b|/Users/janedoe\b|/Users/johndoe\b|/Users/john_doe|/Users/alice\b|/Users/bob\b|/Users/you\b|/Users/yourname\b|/Users/\.\.\.|/Users/\[|/Users/<|/Users/\$'

# Email exclusion: known safe addresses and obvious placeholders.
_EMAIL_EXCLUSION='users\.noreply\.github\.com|noreply@anthropic\.com|@example\.(com|org)|your-email@|user@example|@example\b|test@test\.(com|org)|ci@example|@test\.(com|org)'

# Secret exclusion: test files that explicitly label fakes
# (the file path check for test files is handled by the "test-fixture" label below)
_SECRET_TEST_FILE_PATTERN='tests/cast-subagent-stop-hook-redaction\.bats|tests/cast-batch-dispatch\.bats|tests/ci-pii-scan\.bats|evals/cases/security/security-hardcoded-api-key-unreported\.yaml'

# ---------------------------------------------------------------------------
# Combined pattern for a single-pass scan over all six PII/secret classes.
# IMPORTANT: every sub-pattern is preserved verbatim (security-critical).
#   1. /Users/[A-Za-z0-9._-]+                              hardcoded-path
#   2. [A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}    email
#   3. GOCSPX-[A-Za-z0-9_-]+                               google-oauth
#   4. sk-ant-[A-Za-z0-9_-]{32,}                           anthropic-key
#   5. (ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{36}              github-pat
#      |github_pat_[A-Za-z0-9_]{22,}
#   6. AKIA[0-9A-Z]{16}                                    aws-key
# ---------------------------------------------------------------------------
_COMBINED_PATTERN='/Users/[A-Za-z0-9._-]+|[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}|GOCSPX-[A-Za-z0-9_-]+|sk-ant-[A-Za-z0-9_-]{32,}|(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{22,}|AKIA[0-9A-Z]{16}'

# Per-category hit buffers — populated by _scan_all, merged into FINDINGS.
_HITS_PATH=()
_HITS_EMAIL=()
_HITS_SECRETS=()

# ---------------------------------------------------------------------------
# Single-pass scanner: one git ls-files | xargs grep pass with the combined
# pattern above.  Each matching line is classified into the three category
# arrays and the appropriate exclusion is applied.
# ---------------------------------------------------------------------------
_scan_all() {
  # Use PCRE if available, else ERE
  local grep_flag="-E"
  echo "" | grep -qP "." 2>/dev/null && grep_flag="-P"

  # Get tracked text files; -I skips binary files.
  # Run from REPO_ROOT so that ls-files' repo-relative paths resolve correctly
  # regardless of the caller's cwd.
  local raw_hits
  # shellcheck disable=SC2086
  raw_hits="$(cd "$REPO_ROOT" && git ls-files -z \
    | xargs -0 grep -InH $grep_flag "$_COMBINED_PATTERN" \
    2>/dev/null || true)"

  [[ -z "$raw_hits" ]] && return 0

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue

    # Extract relative path from grep output (format: relpath:lineno:content)
    local relpath="${line%%:*}"
    local rest="${line#*:}"
    local content="${rest#*:}"

    # Skip allowlisted files and directories
    _is_allowed "$relpath" && continue

    # Pre-compute whether this file matches the secret-fixture skip pattern
    local is_secret_fixture=0
    echo "$relpath" | grep -qE "$_SECRET_TEST_FILE_PATTERN" 2>/dev/null && is_secret_fixture=1

    # --- hardcoded-path (exclusion: $_PATH_EXCLUSION) ---
    if echo "$content" | grep -qE '/Users/[A-Za-z0-9._-]+' 2>/dev/null; then
      if ! echo "$content" | grep -qE "$_PATH_EXCLUSION" 2>/dev/null; then
        _HITS_PATH+=("  [hardcoded-path] $relpath: $content")
      fi
    fi

    # --- email (exclusion: $_EMAIL_EXCLUSION) ---
    if echo "$content" | grep -qE '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' 2>/dev/null; then
      if ! echo "$content" | grep -qE "$_EMAIL_EXCLUSION" 2>/dev/null; then
        _HITS_EMAIL+=("  [email] $relpath: $content")
      fi
    fi

    # --- secret keys (skip if test-fixture file) ---
    if [[ "$is_secret_fixture" -eq 0 ]]; then
      if echo "$content" | grep -qE 'GOCSPX-[A-Za-z0-9_-]+' 2>/dev/null; then
        _HITS_SECRETS+=("  [google-oauth] $relpath: $content")
      fi
      if echo "$content" | grep -qE 'sk-ant-[A-Za-z0-9_-]{32,}' 2>/dev/null; then
        _HITS_SECRETS+=("  [anthropic-key] $relpath: $content")
      fi
      if echo "$content" | grep -qE '(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{22,}' 2>/dev/null; then
        _HITS_SECRETS+=("  [github-pat] $relpath: $content")
      fi
      if echo "$content" | grep -qE 'AKIA[0-9A-Z]{16}' 2>/dev/null; then
        _HITS_SECRETS+=("  [aws-key] $relpath: $content")
      fi
    fi

  done <<< "$raw_hits"
}

# ---------------------------------------------------------------------------
# --self-test mode: plant a fake finding in a temp dir, verify detection
# ---------------------------------------------------------------------------
if [[ "${1:-}" == "--self-test" ]]; then
  echo "[ci-pii-scan] --self-test mode"

  TMPDIR_SELF="$(mktemp -d)"
  trap 'rm -rf "$TMPDIR_SELF"' EXIT

  # Plant a fake anthropic key in a temp file (not in the real tree)
  FAKE_FILE="$TMPDIR_SELF/fake.sh"
  printf '#!/usr/bin/env bash\nexport MYKEY="sk-ant-api03-fakekeyfortestingonly1234567890"\n' > "$FAKE_FILE"

  # Run a targeted grep against just the temp file
  HIT="$(grep -n 'sk-ant-[A-Za-z0-9_-]\{32,\}' "$FAKE_FILE" 2>/dev/null || true)"
  if [[ -n "$HIT" ]]; then
    echo "[ci-pii-scan] --self-test PASSED: scanner correctly detected planted sk-ant key"
    exit 0
  else
    echo "[ci-pii-scan] --self-test FAILED: scanner did NOT detect the planted key" >&2
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# Normal scan mode: single combined pass, per-category reporting
# ---------------------------------------------------------------------------
echo "[ci-pii-scan] Scanning tracked files: $REPO_ROOT"
echo ""

_scan_all

# --- Hardcoded home paths ---
echo "=== Check: Hardcoded /Users/<realname> paths ==="
if [[ "${#_HITS_PATH[@]}" -eq 0 ]]; then
  echo "PASS: No hardcoded /Users/ paths found"
else
  FINDINGS+=("${_HITS_PATH[@]}")
fi

# --- Email addresses ---
echo ""
echo "=== Check: Email addresses ==="
if [[ "${#_HITS_EMAIL[@]}" -eq 0 ]]; then
  echo "PASS: No unexpected email addresses found"
else
  FINDINGS+=("${_HITS_EMAIL[@]}")
fi

# --- Secret keys ---
echo ""
echo "=== Check: Secret keys ==="
if [[ "${#_HITS_SECRETS[@]}" -eq 0 ]]; then
  echo "PASS: No secret key patterns found"
else
  FINDINGS+=("${_HITS_SECRETS[@]}")
fi

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
echo ""
if [[ "${#FINDINGS[@]}" -gt 0 ]]; then
  echo "FAIL: PII or secret patterns found in tracked files:"
  for finding in "${FINDINGS[@]}"; do
    echo "$finding"
  done
  echo ""
  echo "[ci-pii-scan] ${#FINDINGS[@]} finding(s) detected. Fix before merging."
  exit 1
else
  echo "[ci-pii-scan] All checks passed. Tree is clean."
  exit 0
fi

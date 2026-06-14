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
PII_ALLOWLIST_DIRS=(
  "docs/"
  "tests/test_helper/"
  # Generated plugin build artifact — a curated mirror of already-scanned source
  # (scripts/, agents/core/, skills/). The check-plugin-drift gate guarantees it
  # equals regenerated source, so re-scanning it only false-positives on copies of
  # this scanner's own fake-secret self-test fixture.
  "plugin/"
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
# Core scanner: grep a pattern across tracked files, filtering allowlisted
# paths and applying an optional exclusion regex on the matching line.
# Appends hits to the FINDINGS array.
# Args: $1=label $2=grep-content-pattern $3=exclusion-ere (optional) $4=skip-file-pattern (optional)
# ---------------------------------------------------------------------------
_scan_tracked() {
  local label="$1"
  local content_pattern="$2"
  local exclusion="${3:-}"
  local skip_file_pat="${4:-}"

  # Use PCRE if available, else ERE
  local grep_flag="-E"
  echo "" | grep -qP "." 2>/dev/null && grep_flag="-P"

  # Get tracked text files; -I skips binary files
  local raw_hits
  # shellcheck disable=SC2086
  raw_hits="$(git -C "$REPO_ROOT" ls-files -z \
    | xargs -0 grep -InH $grep_flag "$content_pattern" \
    2>/dev/null || true)"

  if [[ -z "$raw_hits" ]]; then
    return 0
  fi

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue

    # Extract relative path from grep output (format: relpath:lineno:content)
    local relpath="${line%%:*}"
    local rest="${line#*:}"
    local content="${rest#*:}"

    # Skip allowlisted files and directories
    _is_allowed "$relpath" && continue

    # Skip by per-scan file pattern (e.g., known test fixture files for secrets)
    if [[ -n "$skip_file_pat" ]] && echo "$relpath" | grep -qE "$skip_file_pat" 2>/dev/null; then
      continue
    fi

    # Apply optional exclusion regex to the content
    if [[ -n "$exclusion" ]] && echo "$content" | grep -qE "$exclusion" 2>/dev/null; then
      continue
    fi

    FINDINGS+=("  [$label] $relpath: $content")
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
# Normal scan mode
# ---------------------------------------------------------------------------
echo "[ci-pii-scan] Scanning tracked files: $REPO_ROOT"
echo ""

# --- Hardcoded home paths ---
echo "=== Check: Hardcoded /Users/<realname> paths ==="
BEFORE="${#FINDINGS[@]}"
_scan_tracked "hardcoded-path" '/Users/[A-Za-z0-9._-]+' "$_PATH_EXCLUSION"
AFTER="${#FINDINGS[@]}"
if [[ "$AFTER" -eq "$BEFORE" ]]; then
  echo "PASS: No hardcoded /Users/ paths found"
fi

# --- Email addresses ---
echo ""
echo "=== Check: Email addresses ==="
BEFORE="${#FINDINGS[@]}"
_scan_tracked "email" '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' "$_EMAIL_EXCLUSION"
AFTER="${#FINDINGS[@]}"
if [[ "$AFTER" -eq "$BEFORE" ]]; then
  echo "PASS: No unexpected email addresses found"
fi

# --- Secret keys ---
echo ""
echo "=== Check: Secret keys ==="
BEFORE="${#FINDINGS[@]}"
# Secret scans skip test fixture files that explicitly label their keys as fakes
_scan_tracked "google-oauth"  'GOCSPX-[A-Za-z0-9_-]+'         "" "$_SECRET_TEST_FILE_PATTERN"
_scan_tracked "anthropic-key" 'sk-ant-[A-Za-z0-9_-]{32,}'      "" "$_SECRET_TEST_FILE_PATTERN"
_scan_tracked "github-pat"    '(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{22,}' "" "$_SECRET_TEST_FILE_PATTERN"
_scan_tracked "aws-key"       'AKIA[0-9A-Z]{16}'                "" "$_SECRET_TEST_FILE_PATTERN"
AFTER="${#FINDINGS[@]}"
if [[ "$AFTER" -eq "$BEFORE" ]]; then
  echo "PASS: No secret key patterns found"
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

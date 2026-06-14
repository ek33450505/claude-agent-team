#!/usr/bin/env bash
# pre-push-ci-check.sh — CI safety checks before pushing
# Catches the recurring failure classes documented in the 2026-04-16 insights report.
# Extended (2026-06-01) with PII / secret scanning of the push diff.
# New-branch pushes scan the NET diff vs the upstream default branch's merge-base
# (audit §3.8.E) — NOT the whole repo (which previously hung the gate). KNOWN LIMITATION:
# a secret introduced and then removed across commits within the SAME push lands in history
# without appearing in the net diff; full-history coverage would need `git log --patch`.
set -euo pipefail

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
PASS=true

echo "[pre-push-ci-check] Scanning $REPO_ROOT"

# ---------------------------------------------------------------------------
# Files whose content intentionally contains scanner trigger patterns.
# Used by both Check 1 (path portability gate) and Check 4 (PII/secret scan).
# Paths are relative to REPO_ROOT.
# ---------------------------------------------------------------------------
PII_ALLOWLIST=(
  "scripts/pre-push-ci-check.sh"
  "config/pii-patterns.json"
  "config/pii-denylist-local.txt.template"
  "tests/pre-push-ci-check.bats"
  "tests/ci-pii-scan.bats"
  "tests/cast_cron_setup.bats"
  "tests/scripts/cast-overlay-sync.bats"
  "evals/cases/security/security-hardcoded-api-key-unreported.yaml"
)

# Build an ERE that matches any allowlisted file in grep's "file:line:content" output.
# grep -rn output format: /abs/path/to/file:lineno:content
# We match on the relative-path suffix so REPO_ROOT prefix differences don't matter.
_allowlist_exclusion_ere() {
  local parts=()
  local p
  for p in "${PII_ALLOWLIST[@]}"; do
    # Escape dots for ERE; anchor to path separator so partial names don't match.
    local escaped
    escaped=$(printf '%s' "$p" | sed 's/\./\\./g')
    parts+=("${escaped}:[0-9]")
  done
  local IFS='|'
  echo "${parts[*]}"
}
_ALLOWLIST_ERE="$(_allowlist_exclusion_ere)"

# ---------------------------------------------------------------------------
# Check 1: Hardcoded absolute paths in test files
# ---------------------------------------------------------------------------
echo ""
echo "=== Check 1: Hardcoded /Users/ paths in test files ==="
# Intentional test-fixture paths are excluded from this check:
#   /Users/testuser  — canonical fake user for tilde-guard and path-scan tests
#   /Users/runner    — GitHub macOS CI runner username used in portability assertions
#   /Users/janedoe   — fake user for PII-scan test payloads
#   /Users/[         — grep ERE regex literals in assertions (e.g. /Users/[a-zA-Z])
#   /Users/<...>     — doc-style placeholder strings
#   /Users/*         — case-glob literal in teardown safety guards (a pattern, not a path)
# Files in PII_ALLOWLIST are also excluded (they intentionally embed trigger strings).
_CHECK1_EXCLUSION='/Users/testuser\b|/Users/runner\b|/Users/janedoe\b|/Users/\[|/Users/<|/Users/\*'
HARDCODED=$(grep -rn "/Users/" "$REPO_ROOT/tests" "$REPO_ROOT/test" "$REPO_ROOT/src" \
  --include="*.sh" --include="*.bats" --include="*.test.*" --include="*.spec.*" \
  --exclude-dir=".git" --exclude-dir="worktrees" \
  --exclude-dir="node_modules" --exclude-dir=".cache" \
  --exclude-dir="dist" \
  2>/dev/null \
  | grep -v "\.git" \
  | grep -Ev "$_ALLOWLIST_ERE" \
  | grep -Ev "$_CHECK1_EXCLUSION" \
  || true)
if [[ -n "$HARDCODED" ]]; then
  echo "FAIL: Found hardcoded /Users/ paths (will break on CI runners):"
  echo "$HARDCODED" | head -20
  PASS=false
else
  echo "PASS: No hardcoded /Users/ paths found"
fi

# ---------------------------------------------------------------------------
# Check 2: FTS5 availability — macOS-only SQLite feature
# ---------------------------------------------------------------------------
echo ""
echo "=== Check 2: FTS5 platform-specific imports ==="
FTS5_HITS=$(grep -rn "fts5\|FTS5\|USING fts5" "$REPO_ROOT" \
  --include="*.py" --include="*.sh" --include="*.sql" \
  --exclude-dir=".git" --exclude-dir="worktrees" \
  --exclude-dir="node_modules" --exclude-dir=".cache" \
  --exclude-dir="dist" \
  2>/dev/null | grep -v "#.*fts5\|-- fts5" || true)
if [[ -n "$FTS5_HITS" ]]; then
  echo "WARNING: FTS5 references found — verify these include a sqlite3 version check:"
  echo "$FTS5_HITS" | head -10
  # Warning only, not a hard fail — some repos handle this gracefully
else
  echo "PASS: No bare FTS5 references"
fi

# ---------------------------------------------------------------------------
# Check 3: Stale version() or package name references after renames
# ---------------------------------------------------------------------------
echo ""
echo "=== Check 3: Stale package/version references ==="
if [[ -f "$REPO_ROOT/package.json" ]]; then
  PKG_NAME=$(python3 - "$REPO_ROOT/package.json" <<'EOF' 2>/dev/null || echo ""
import json, sys
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
    print(d.get('name', ''))
except Exception:
    pass
EOF
)
  echo "Package name: $PKG_NAME"
fi
echo "PASS: Manual review recommended after any package rename"

# ---------------------------------------------------------------------------
# Check 4: PII / secret scan of the full push diff
# ---------------------------------------------------------------------------
echo ""
echo "=== Check 4: PII and secret scan ==="
# PII_ALLOWLIST defined above — shared with Check 1.

# Detect PCRE support; fall back to ERE if unavailable.
if echo "" | grep -qP "." 2>/dev/null; then
  GREP_FLAGS="-P"
else
  GREP_FLAGS="-E"
fi

# Build the diff text from stdin (push refs) or fall back to HEAD~1..HEAD.
# git pre-push hook stdin format: "<local-ref> <local-sha> <remote-ref> <remote-sha>"
EMPTY_TREE="4b825dc642cb6eb9a060e54bf8d69288fbee4904"
PUSH_DIFF=""
# Consume stdin; may be empty when the script is run standalone.
while IFS=' ' read -r _local_ref local_sha _remote_ref remote_sha || [[ -n "${local_sha:-}" ]]; do
  [[ -z "${local_sha:-}" ]] && continue
  if [[ "${remote_sha:-}" == "0000000000000000000000000000000000000000" ]] || [[ -z "${remote_sha:-}" ]]; then
    # New branch: the remote ref does not exist yet. Diffing against the empty tree
    # would scan the ENTIRE repo (~540 files) and hang the gate (audit §3.8.D/E).
    # Scan only what this branch adds over the shared upstream history: diff against
    # the merge-base with the default branch.
    base=""
    for _ref in origin/main origin/master main master; do
      git rev-parse --verify --quiet "$_ref" >/dev/null 2>&1 || continue
      base="$(git merge-base "$_ref" "$local_sha" 2>/dev/null || true)"
      [[ -n "$base" ]] && break
    done
    # Genuinely new repo with no upstream default branch → fall back to full history.
    [[ -z "$base" ]] && base="$EMPTY_TREE"
  else
    base="$remote_sha"
  fi
  PUSH_DIFF+=$(git diff "$base" "$local_sha" 2>/dev/null || true)
  PUSH_DIFF+=$'\n'
done

# Standalone fallback (called directly, not from a hook with stdin refs).
if [[ -z "${PUSH_DIFF// }" ]]; then
  PUSH_DIFF=$(git diff HEAD~1 HEAD 2>/dev/null || git diff "$EMPTY_TREE" HEAD 2>/dev/null || true)
fi

# ---- Helpers ----------------------------------------------------------------

# Check whether a file path is in the allowlist.
_is_allowed() {
  local file="$1"
  local p
  for p in "${PII_ALLOWLIST[@]}"; do
    [[ "$file" == "$p" ]] && return 0
  done
  return 1
}

# Scan the diff for a pattern, skipping allowlisted files.
# Prints matching lines prefixed with [label] file:linecontent.
# Returns 0 always (caller decides whether hits are fatal).
# $3 (optional): extra grep flags (e.g., "-i" for case-insensitive)
# $4 (optional): exclusion ERE pattern — candidate hit lines matching this are suppressed
_pii_scan() {
  local label="$1"
  local pattern="$2"
  local extra_flags="${3:-}"
  local exclusion="${4:-}"
  local current_file=""
  local skip=false
  local in_hunk=false

  while IFS= read -r line; do
    # Diff file header
    if [[ "$line" =~ ^diff\ --git\ a/(.+)\ b/(.+)$ ]]; then
      current_file="${BASH_REMATCH[2]}"
      if _is_allowed "$current_file"; then
        skip=true
      else
        skip=false
      fi
      in_hunk=false
      continue
    fi
    # Hunk header — reset in_hunk flag (we are in a hunk now)
    if [[ "$line" =~ ^@@ ]]; then
      in_hunk=true
      continue
    fi
    # Only inspect added lines inside a hunk (skip context and removed lines)
    if [[ "$in_hunk" == "true" && "$skip" == "false" && "$line" =~ ^\+ && ! "$line" =~ ^\+\+\+ ]]; then
      local content="${line:1}"
      # shellcheck disable=SC2086
      if echo "$content" | grep -q $GREP_FLAGS $extra_flags "$pattern" 2>/dev/null; then
        # Apply exclusion filter if provided
        if [[ -n "$exclusion" ]] && echo "$content" | grep -qE "$exclusion" 2>/dev/null; then
          continue
        fi
        echo "  [$label] $current_file: $content"
      fi
    fi
  done <<< "$PUSH_DIFF"
}

# Case-insensitive variant of _pii_scan.
# Uses -i flag directly so it works in both PCRE and ERE modes.
# The pattern must NOT embed (?i) — that only works in PCRE.
_pii_scan_ci() {
  _pii_scan "$1" "$2" "-i" "${3:-}"
}

# ---- Run scans --------------------------------------------------------------

PII_HITS=""

# Generic email scan — flags any email address; safe senders and obvious placeholders
# are excluded via a combined exclusion regex.
_EMAIL_EXCLUSION='users\.noreply\.github\.com|noreply@anthropic\.com|@example\.(com|org)|your-email@|user@example|@example\b'
PII_HITS+=$(_pii_scan "email" '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' "" "$_EMAIL_EXCLUSION" || true)

# Generic hardcoded home-path scan — flags /Users/<name>; well-known CI runner
# usernames and doc placeholders are excluded.
_PATH_EXCLUSION='/Users/testuser\b|/Users/runner\b|/Users/<[^>]+>|/Users/\$'
PII_HITS+=$(_pii_scan "hardcoded-path" '/Users/[A-Za-z0-9._-]+' "" "$_PATH_EXCLUSION" || true)

# Local deny-list scan — reads patterns from a file outside the repo.
# The file path is configurable via CAST_PII_LOCAL_DENYLIST; defaults to
# ~/.claude/config/pii-denylist-local.txt. If absent, prints a NOTE and continues.
_DENYLIST_FILE="${CAST_PII_LOCAL_DENYLIST:-$HOME/.claude/config/pii-denylist-local.txt}"
if [[ -f "$_DENYLIST_FILE" ]]; then
  while IFS= read -r _deny_pattern || [[ -n "$_deny_pattern" ]]; do
    # Skip blank lines and comments
    [[ -z "$_deny_pattern" ]] && continue
    [[ "$_deny_pattern" =~ ^[[:space:]]*# ]] && continue
    PII_HITS+=$(_pii_scan_ci "local-denylist" "$_deny_pattern" || true)
  done < "$_DENYLIST_FILE"
else
  echo "  NOTE: No local deny-list found at $_DENYLIST_FILE — work/personal patterns are not being scanned."
  echo "        Copy config/pii-denylist-local.txt.template to that path and add your identifiers."
fi

PII_HITS+=$(_pii_scan "google-oauth"    'GOCSPX-[A-Za-z0-9_-]+' || true)
PII_HITS+=$(_pii_scan "anthropic-key"   'sk-ant-[A-Za-z0-9_-]{32,}' || true)
PII_HITS+=$(_pii_scan "github-pat"      '(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{22,}' || true)
PII_HITS+=$(_pii_scan "aws-key"         'AKIA[0-9A-Z]{16}' || true)

if [[ -n "$PII_HITS" ]]; then
  echo "FAIL: PII or secret patterns found in push diff:"
  echo "$PII_HITS"
  PASS=false
else
  echo "PASS: No PII or secret patterns found in diff"
fi

# ---------------------------------------------------------------------------
# Final result
# ---------------------------------------------------------------------------
echo ""
if [[ "$PASS" == "true" ]]; then
  echo "[pre-push-ci-check] All checks passed."
  exit 0
else
  echo "[pre-push-ci-check] FAILURES detected. Fix before pushing."
  exit 1
fi

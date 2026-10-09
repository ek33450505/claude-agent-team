#!/usr/bin/env bash
# pre-push-ci-check.sh — CI safety checks before pushing
# Catches the recurring failure classes documented in the 2026-04-16 insights report.
# Extended (2026-06-01) with PII / secret scanning of the push diff.
# Pushes are scanned PER COMMIT (Check 4): every pushed commit's own patch, once per parent
# for a merge (defence in depth: with already-published ancestors excluded, first-parent alone
# is detection-equivalent) and against the empty tree for a root, because GitHub secret
# scanning inspects every commit — a secret added and removed within the SAME push lands in
# history yet never appears in the net diff (alert #2, 2026-10-09).
# Range: <remote>..<local> when the remote sha is a local commit; otherwise (new branch, or an
# unfetched / non-fast-forward remote sha) every pushed commit NOT on the remote-tracking refs
# of THE REMOTE BEING PUSHED TO (`rev-list <local> --not --remotes=<name>`; the hook forwards
# git's remote name as $1). No usable name (empty, URL, glob) excludes nothing: over-scan,
# bounded by CAST_PII_MAX_COMMITS (default 500), which fails closed with the escape-hatch
# hint — the variable only tunes the cap; it cannot skip the scan.
# FAILS CLOSED: a pushed sha that is not a local commit, any git failure while enumerating or
# diffing (no `|| true` on a git call whose output is scanned), a diff with text but no
# `diff --git` header, a grep that errors (a `[scan-error]` hit), an invalid deny-list regex,
# a non-numeric cap, and running outside a git repo. Every diff is pinned (--text --no-color
# --no-ext-diff --no-textconv --no-renames, a/ b/ prefixes) and every Check 4 grep runs under
# LC_ALL=C (Checks 1 and 2 run earlier, under the caller's locale), so repo/user config and
# invalid-UTF-8 bytes cannot blind the scan. The
# standalone HEAD~1..HEAD fallback runs only when NO stdin ref line was read, so a
# deletion-only push scans nothing and passes. The allowlist applies only to an exactly
# parsed `diff --git a/P b/P` header; an unparsed header is scanned, never skipped.
# RESIDUALS (not covered):
#   - commit and annotated-tag MESSAGES are not scanned;
#   - file-NAME lines (`diff --git`, `---`/`+++`) are not scanned, only added content;
#   - SHA-256 repos fail closed on root commits (the empty-tree literal is SHA-1);
#   - a remote-tracking ref AHEAD of the remote's real state (a server-side rewind or
#     delete, or a hand-set ref) makes `--remotes=<name>` exclude commits that are not
#     published: that can UNDER-scan (a stale ref behind the remote only over-scans);
#   - `git remote set-url` to another host without refetching leaves the tracking refs
#     ahead of the new remote (same family as the rewound-ref residual above);
#   - nested remote names: `--remotes=<name>` globs `refs/remotes/<name>/*`, so a push to
#     `foo` also excludes commits published only to a remote named `foo/bar` (under-scans
#     only when remote names nest);
#   - plugin/ is excluded from every Check 4 diff (a generated mirror, drift-gated by CI);
#   - the `diff --git` sanity check is aggregate (any header anywhere satisfies it): a
#     tripwire that is unreachable with the pinned flags, kept as defence in depth;
#   - merging an already-published branch (main) into a feature branch re-scans that
#     published content, so it can false-positive;
#   - the per-line grep loop is slow, quadratic under /bin/bash 3.2 (pre-existing; hence the
#     cap; follow-up G1c).
set -euo pipefail

# Hardened git (cast_git_safe): hook-run git must not honour repo-local exec config
# (diff.external ran for `git diff HEAD~1 HEAD`). FAIL CLOSED if the lib is not loadable beside
# this script — never fall back to bare git. The -r guard matters: on bash 3.2 a bare
# `source <missing-file>` aborts under set -e.
_CAST_LIB="$(dirname "$0")/cast-hook-lib.sh"
# shellcheck source=cast-hook-lib.sh
if [[ -r "$_CAST_LIB" ]] && source "$_CAST_LIB"; then
  :
else
  echo "[pre-push-ci-check] FATAL — cast-hook-lib.sh not loadable beside $0 (fail closed)" >&2
  exit 1
fi

# CAST_REPO_ROOT wins (installed-copy mode: the hook passes the repo as data); else the
# cwd's repo. GIT_DIR/GIT_WORK_TREE/GIT_INDEX_FILE are not inherited — a git hook exports the
# committing worktree's gitdir (S3c-15) — and every git call below goes through cast_git_safe
# against REPO_ROOT. This script reads pushed commits (refs from stdin), never the index.
if [[ -n "${CAST_REPO_ROOT+x}" ]]; then
  if [[ "$CAST_REPO_ROOT" != /* || ! -d "$CAST_REPO_ROOT" ]]; then
    echo "[pre-push-ci-check] FATAL — CAST_REPO_ROOT must be an absolute path to an existing directory: '${CAST_REPO_ROOT}'" >&2
    exit 1
  fi
  REPO_ROOT="$CAST_REPO_ROOT"
  cd "$REPO_ROOT"
else
  REPO_ROOT=$(cast_git_safe "$PWD" rev-parse --show-toplevel 2>/dev/null || pwd)
fi
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
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
  --exclude-dir="dist" --exclude-dir="plugin" \
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
  PKG_NAME=$(python3 -I - "$REPO_ROOT/package.json" <<'EOF' 2>/dev/null || echo ""
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

# Scan BYTE-WISE. BSD grep (macOS) stops matching at an invalid multibyte sequence under a
# UTF-8 locale, so `\xff k=AKIA…` or a binary blob would PASS the scan. Exported before any
# scan grep runs (Check 1 above is a path-portability check, not a secret gate, and keeps the
# caller's locale).
export LC_ALL=C

# This gate reads a git repo. Outside one, "nothing to scan" must not read as "clean".
if ! cast_git_safe "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  echo "ERROR: $REPO_ROOT is not a git repository — PII gate fails closed" >&2
  exit 1
fi

# Detect PCRE support; fall back to ERE if unavailable.
if echo "" | grep -qP "." 2>/dev/null; then
  GREP_FLAGS="-P"
else
  GREP_FLAGS="-E"
fi

# Build the diff text from stdin (push refs); the HEAD~1..HEAD fallback runs only when
# no ref line was read at all.
# git pre-push hook stdin format: "<local-ref> <local-sha> <remote-ref> <remote-sha>"
# SHA-1 empty tree; a SHA-256 repo has no such object, so root-commit diffs fail CLOSED there.
EMPTY_TREE="4b825dc642cb6eb9a060e54bf8d69288fbee4904"
PUSH_DIFF=""
# The remote being pushed to (git passes its name as the hook's $1; the hook forwards it).
_pii_remote="${1:-}"

# EVERY Check 4 diff is pinned so repo/user config cannot change what the parser sees:
#   --text           binary files and `-diff` attributes would otherwise yield no added lines
#   --no-color       color.ui/color.diff=always puts ANSI codes before `diff --git` and `@@`
#   --no-ext-diff --no-textconv   no repo-configured drivers
#   --no-renames     a pure rename shows no hunk; delete+add forces the full content to be scanned
#   --src-prefix=a/ --dst-prefix=b/   diff.noprefix / diff.mnemonicPrefix change header shape
_DIFF_FLAGS=(--text --no-color --no-ext-diff --no-textconv --no-renames --src-prefix=a/ --dst-prefix=b/)

# Append the pinned `git diff <parent> <commit>` for EVERY parent of <commit> ($1; its parents
# follow as $2..). A root commit (no parents) is diffed against the empty tree. Diffing each
# parent of a merge is defence in depth: under the premise that parents outside the pushed
# range are already published, first-parent alone is detection-equivalent. plugin/ is
# excluded: it is a generated build artifact (mirror of scanned source) that is drift-gated by
# CI; including it caused a ~43k-line diff that made the _pii_scan loop hang at 99% CPU for
# 18+ min (same hang class as audit §3.8.D/E). _is_allowed() keeps a plugin/* skip as
# belt-and-suspenders. FAILS CLOSED on any git error.
_append_commit_diffs() {
  local c="$1" p d
  shift
  if [[ $# -eq 0 ]]; then
    set -- "$EMPTY_TREE"
  fi
  for p in "$@"; do
    if ! d=$(cast_git_safe "$REPO_ROOT" diff "${_DIFF_FLAGS[@]}" "$p" "$c" -- . ':(exclude)plugin/' 2>/dev/null); then
      echo "ERROR: cannot diff pushed commit $c against $p — PII gate fails closed" >&2
      exit 1
    fi
    PUSH_DIFF+="$d"$'\n'
  done
}

_pii_cap="${CAST_PII_MAX_COMMITS:-500}"
if ! [[ "$_pii_cap" =~ ^[0-9]{1,9}$ ]]; then
  echo "ERROR: CAST_PII_MAX_COMMITS must be a non-negative integer of at most 9 digits ('$_pii_cap') — PII gate fails closed" >&2
  exit 1
fi
_pii_cap=$((10#$_pii_cap)) # decimal: "08" / "0500" are not octal
_saw_ref=false
while IFS=' ' read -r _local_ref local_sha _remote_ref remote_sha || [[ -n "${local_sha:-}" ]]; do
  [[ -z "${local_sha:-}" ]] && continue
  _saw_ref=true
  # Branch-deletion push (local sha all zeros, any length): nothing is pushed, nothing to scan.
  [[ "$local_sha" =~ ^0+$ ]] && continue
  # FAIL CLOSED on an unusable pushed sha: it must resolve to a commit in this repo.
  if ! cast_git_safe "$REPO_ROOT" rev-parse --verify --quiet "${local_sha}^{commit}" >/dev/null 2>&1; then
    echo "ERROR: pushed sha $local_sha is not a local commit — PII gate fails closed" >&2
    exit 1
  fi
  # Range selection. Remote sha is a local commit: scan <remote>..<local>. Otherwise (new
  # branch: all zeros / empty; or a remote sha we do not have: non-fast-forward, unfetched
  # remote) there is no usable range start: scan every pushed commit that is NOT on the
  # remote-tracking refs of THIS remote (--remotes=<name>; a commit published only to some
  # OTHER remote is not published here). A hook argument that is not a plain remote name
  # (empty, a URL, a glob) excludes nothing: over-scan, bounded by the cap. Never a
  # merge-base guess that can fail open.
  if [[ -n "${remote_sha:-}" ]] && ! [[ "$remote_sha" =~ ^0+$ ]] \
    && cast_git_safe "$REPO_ROOT" rev-parse --verify --quiet "${remote_sha}^{commit}" >/dev/null 2>&1; then
    _revargs=("$remote_sha..$local_sha")
  elif [[ "$_pii_remote" =~ ^[A-Za-z0-9._-]+$ ]]; then
    _revargs=("$local_sha" --not "--remotes=$_pii_remote")
  else
    _revargs=("$local_sha")
  fi
  # One rev-list: every pushed commit (merges included) with its parents, "<sha> <p1> [<p2>…]".
  # Each commit's OWN patch is scanned, not the net diff: GitHub secret scanning inspects every
  # commit, so a literal added in one commit and removed in a later one of the same push is
  # invisible to `diff base local_sha` yet still lands in history (alert #2, 2026-10-09).
  if ! _lines=$(cast_git_safe "$REPO_ROOT" rev-list --parents "${_revargs[@]}" 2>/dev/null); then
    echo "ERROR: cannot enumerate pushed commits for ${_local_ref:-$local_sha} — PII gate fails closed" >&2
    exit 1
  fi
  _n=0
  if [[ -n "$_lines" ]]; then
    _nl="${_lines//[!$'\n']/}"
    _n=$((${#_nl} + 1))
  fi
  if ((_n > _pii_cap)); then
    echo "ERROR: $_n pushed commits exceed the per-commit scan cap — run gitleaks, then push with CAST_SKIP_PII_CHECK=1 if clean" >&2
    exit 1
  fi
  while IFS= read -r _line; do
    [[ -z "$_line" ]] && continue
    read -r -a _fields <<<"$_line"
    _append_commit_diffs "${_fields[@]}"
  done <<<"$_lines"
done

# Standalone fallback: called directly (not from a hook), so NO ref line was read. A
# deletion-only push read a line and correctly scans nothing. FAILS CLOSED on a git error;
# a repo with no commits has nothing to scan.
if [[ "$_saw_ref" != "true" ]] && cast_git_safe "$REPO_ROOT" rev-parse --verify --quiet HEAD >/dev/null 2>&1; then
  if PUSH_DIFF=$(cast_git_safe "$REPO_ROOT" diff "${_DIFF_FLAGS[@]}" HEAD~1 HEAD -- . ':(exclude)plugin/' 2>/dev/null); then
    :
  elif PUSH_DIFF=$(cast_git_safe "$REPO_ROOT" diff "${_DIFF_FLAGS[@]}" "$EMPTY_TREE" HEAD -- . ':(exclude)plugin/' 2>/dev/null); then
    :
  else
    echo "ERROR: cannot diff HEAD for the standalone scan — PII gate fails closed" >&2
    exit 1
  fi
fi

# Sanity: a diff that carries text but no `diff --git` header is not in the shape the parser
# understands (it would silently scan nothing). FAIL CLOSED.
if [[ -n "${PUSH_DIFF//[[:space:]]/}" && $'\n'"$PUSH_DIFF" != *$'\n'"diff --git "* ]]; then
  echo "ERROR: scanned diff text has no 'diff --git' header (unexpected diff format) — PII gate fails closed" >&2
  exit 1
fi

# ---- Helpers ----------------------------------------------------------------

# Check whether a file path is in the allowlist.
_is_allowed() {
  local file="$1"
  local p
  for p in "${PII_ALLOWLIST[@]}"; do
    [[ "$file" == "$p" ]] && return 0
  done
  # Generated plugin build artifact — a curated mirror of already-scanned source
  # (scripts/, agents/core/, skills/); the check-plugin-drift gate guarantees it
  # equals regenerated source, so scanning it only false-positives on copies of
  # the scanner self-test fixtures. (Check 1 already scans only tests/test/src.)
  [[ "$file" == plugin/* ]] && return 0
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
    # Diff file header. EVERY header resets the per-file state, so a header that cannot be
    # parsed never inherits the previous file's allowlist skip. The allowlist applies only
    # when the header is exactly `diff --git a/P b/P` (both halves equal, checked by length
    # and string equality — a path containing " b/" cannot spoof an allowlisted name).
    # Anything else (quoted/non-ASCII path, rename, ambiguous) keeps the raw header text as
    # its name, is never allowlisted, and has its added lines scanned.
    if [[ "$line" == "diff --git "* ]]; then
      local rest="${line#diff --git }" half
      current_file="$rest"
      skip=false
      in_hunk=false
      half=$(((${#rest} - 5) / 2))
      if ((half > 0 && 2 * half + 5 == ${#rest})) \
        && [[ "${rest:0:2}" == "a/" && "${rest:$((half + 2)):3}" == " b/" \
        && "${rest:2:$half}" == "${rest:$((half + 5)):$half}" ]]; then
        current_file="${rest:2:$half}"
        if _is_allowed "$current_file"; then
          skip=true
        fi
      fi
      continue
    fi
    # Hunk header — reset in_hunk flag (we are in a hunk now)
    if [[ "$line" =~ ^@@ ]]; then
      in_hunk=true
      continue
    fi
    # Only inspect added lines inside a hunk (skip context and removed lines). No `+++`
    # exclusion: the `+++ b/file` header only occurs BEFORE the first @@ (in_hunk=false), so
    # inside a hunk a line starting `+++` is real added content (e.g. a `++secret` line).
    if [[ "$in_hunk" == "true" && "$skip" == "false" && "$line" =~ ^\+ ]]; then
      local content="${line:1}" rc=0
      # grep status: 0 = match, 1 = no match, anything else (2 = bad pattern / I/O) is a SCAN
      # ERROR and must not read as "no match". Here-string, not a pipe: with pipefail a
      # SIGPIPE'd `echo` on a long line could mask a match. -e keeps a '-'-leading pattern a
      # pattern. LC_ALL=C is exported for the whole of Check 4.
      # shellcheck disable=SC2086
      grep -q $GREP_FLAGS $extra_flags -e "$pattern" <<<"$content" 2>/dev/null || rc=$?
      if [[ "$rc" -eq 1 ]]; then
        continue
      elif [[ "$rc" -ne 0 ]]; then
        echo "  [scan-error] $label: grep rc=$rc"
        return 0
      fi
      # Apply exclusion filter if provided
      if [[ -n "$exclusion" ]]; then
        rc=0
        grep -qE -e "$exclusion" <<<"$content" 2>/dev/null || rc=$?
        if [[ "$rc" -eq 0 ]]; then
          continue
        elif [[ "$rc" -ne 1 ]]; then
          echo "  [scan-error] $label: exclusion grep rc=$rc"
          return 0
        fi
      fi
      echo "  [$label] $current_file: $content"
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
  # Pass 1: collect AND validate every pattern up front. An invalid regex makes grep exit 2,
  # which would otherwise read as "no match" and silently disable that pattern: fail closed.
  # (The pattern text is not echoed: deny-list entries are the identifiers being protected.)
  _deny_patterns=""
  _deny_lineno=0
  while IFS= read -r _deny_pattern || [[ -n "$_deny_pattern" ]]; do
    _deny_lineno=$((_deny_lineno + 1))
    # Trim leading/trailing whitespace so patterns with extra spaces don't match literally
    _deny_pattern=$(sed 's/^[[:space:]]*//; s/[[:space:]]*$//' <<< "$_deny_pattern")
    # Skip blank/whitespace-only lines and comments
    [[ -z "$_deny_pattern" ]] && continue
    [[ "$_deny_pattern" =~ ^# ]] && continue
    _deny_rc=0
    # shellcheck disable=SC2086
    grep -q $GREP_FLAGS -i -e "$_deny_pattern" </dev/null 2>/dev/null || _deny_rc=$?
    if [[ "$_deny_rc" -ge 2 ]]; then
      echo "ERROR: invalid deny-list pattern at line $_deny_lineno of $_DENYLIST_FILE (grep rc=$_deny_rc) — PII gate fails closed" >&2
      exit 1
    fi
    _deny_patterns+="$_deny_pattern"$'\n'
  done < "$_DENYLIST_FILE"
  # Pass 2: scan.
  while IFS= read -r _deny_pattern; do
    [[ -z "$_deny_pattern" ]] && continue
    PII_HITS+=$(_pii_scan_ci "local-denylist" "$_deny_pattern" || true)
  done <<< "$_deny_patterns"
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

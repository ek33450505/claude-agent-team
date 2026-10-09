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
# diffing (no `|| true` on a git call whose output is scanned), a non-empty diff that does not
# start with a `diff --git` header, a grep that errors or a join that cannot be parsed (a
# `[scan-error]` hit), a scratch dir that cannot be created or written, an invalid deny-list
# regex, a non-numeric cap, and running outside a git repo. Every diff is pinned (--text
# --no-color --no-ext-diff --no-textconv --no-renames, a/ b/ prefixes) and every Check 4 grep
# runs under LC_ALL=C (Checks 1 and 2 run earlier, under the caller's locale), so repo/user
# config and invalid-UTF-8 bytes cannot blind the scan. The standalone HEAD~1..HEAD fallback
# runs only when NO stdin ref line was read, so a deletion-only push scans nothing and passes.
# The allowlist applies only to an exactly parsed `diff --git a/P b/P` header; an unparsed
# header is scanned, never skipped.
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
#   - merging an already-published branch (main) into a feature branch re-scans that
#     published content, so it can false-positive;
#   - a SIGKILLed run leaves its 0700 `$TMPDIR/cast-pii.*` scratch (pushed diff text) behind;
#     the EXIT trap covers exit, INT, TERM and HUP;
#   - hit lines are echoed raw: control bytes (ESC, CR) in pushed content or paths reach the
#     terminal (pre-existing);
#   - a same-user process that changes the 0700 scratch dir between the S1 guard and grep can
#     still make a pattern read as clean (same-user trust; out of scope);
#   - the per-pattern join keeps line numbers (line mode) or match indices (match mode) in
#     memory: O(hit lines) or O(matches) (a 50 MB line of excluded matches ~ 20 s, 346 MB RSS);
#     it fails closed if killed;
#   - exclusions are substring searches within each match (`bob@example.com.corp.io` is
#     excluded by `@example\.(com|org)`), as before;
#   - scripts/ci-pii-scan.sh (the CI scan) still applies its exclusions per whole line
#     (follow-up: align the two scanners, G6/G2).
# COST (G1c): the diff is parsed ONCE (awk) into line-aligned added-line records, then each
# pattern is ONE grep over all of them: O(patterns) processes, not one grep per added line per
# pattern. git still runs one diff per (commit, parent); commits shared by several pushed refs
# are diffed once. No `${var//pat/}` on unbounded text: bash 3.2 runs it in quadratic time
# (20 KB took 30 s). Before G1c, 1,000 added lines took 272 s on /bin/bash 3.2 and 14 s on
# bash 5, and 5,000 took 62 s on bash 5; now 50,000 take ~1 s on /bin/bash 3.2.
# Printed hits are capped at 200 per pattern (the verdict is unchanged).
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

# Private scratch for the single-pass scan: the diff text, the parsed records and grep output.
# It holds pushed content, so it is mktemp's 0700 dir, removed on exit. FAILS CLOSED.
_PII_TMP=""
# shellcheck disable=SC2329 # invoked by the EXIT trap below
_pii_cleanup() {
  if [[ -n "$_PII_TMP" && -d "$_PII_TMP" ]]; then
    rm -f -- "$_PII_TMP/commits" "$_PII_TMP/diff" "$_PII_TMP/names" "$_PII_TMP/added" \
      "$_PII_TMP/files" "$_PII_TMP/hits" "$_PII_TMP/excl" "$_PII_TMP/mtext" 2>/dev/null || true
    rmdir -- "$_PII_TMP" 2>/dev/null || true
  fi
}
_pii_tmproot="${TMPDIR:-/tmp}"
if ! _PII_TMP=$(mktemp -d "${_pii_tmproot%/}/cast-pii.XXXXXX" 2>/dev/null) || [[ ! -d "$_PII_TMP" ]]; then
  echo "ERROR: cannot create a private temp dir for the scan — PII gate fails closed" >&2
  exit 1
fi
trap _pii_cleanup EXIT
if ! : >"$_PII_TMP/commits" || ! : >"$_PII_TMP/diff"; then
  echo "ERROR: cannot write the scan scratch dir — PII gate fails closed" >&2
  exit 1
fi

# Every pattern, built-in and deny-list, is an ERE (config/pii-denylist-local.txt.template
# documents ERE). Pinned: the old `echo "" | grep -qP .` probe could never succeed (`.` cannot
# match an empty line) and BSD grep has no -P, so every scan already ran with -E.
GREP_FLAGS="-E"

# Build the diff text from stdin (push refs); the HEAD~1..HEAD fallback runs only when
# no ref line was read at all.
# git pre-push hook stdin format: "<local-ref> <local-sha> <remote-ref> <remote-sha>"
# SHA-1 empty tree; a SHA-256 repo has no such object, so root-commit diffs fail CLOSED there.
EMPTY_TREE="4b825dc642cb6eb9a060e54bf8d69288fbee4904"
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
# 18+ min (same hang class as audit §3.8.D/E). The single-pass parse keeps a plugin/* skip as
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
    _pii_add_diff "$d" "pushed commit $c against $p"
  done
}

# Append one pinned diff to the scan input. A non-empty diff must START with a `diff --git`
# header (unreachable with the pinned flags; defence in depth: lines before the first header
# would belong to no file). Test the start with a glob, never `${d//...}`. FAILS CLOSED.
_pii_add_diff() {
  if [[ -z "$1" ]]; then
    return 0
  fi
  if [[ "$1" != "diff --git "* ]]; then
    echo "ERROR: diff of $2 does not start with a 'diff --git' header (unexpected diff format) — PII gate fails closed" >&2
    exit 1
  fi
  if ! printf '%s\n' "$1" >>"$_PII_TMP/diff"; then
    echo "ERROR: cannot write the scan input — PII gate fails closed" >&2
    exit 1
  fi
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
    # awk, not `${_lines//[!$'\n']/}`: bash 3.2 pattern substitution is quadratic, which made
    # the cap check itself the slow path on a big push.
    if ! _n=$(printf '%s\n' "$_lines" | awk 'END { print NR }') || ! [[ "$_n" =~ ^[0-9]+$ ]]; then
      echo "ERROR: cannot count pushed commits for ${_local_ref:-$local_sha} — PII gate fails closed" >&2
      exit 1
    fi
  fi
  if ((_n > _pii_cap)); then
    echo "ERROR: $_n pushed commits exceed the per-commit scan cap — run gitleaks, then push with CAST_SKIP_PII_CHECK=1 if clean" >&2
    exit 1
  fi
  if [[ -n "$_lines" ]] && ! printf '%s\n' "$_lines" >>"$_PII_TMP/commits"; then
    echo "ERROR: cannot write the scan scratch dir — PII gate fails closed" >&2
    exit 1
  fi
done

# Commits shared by several pushed refs (--all, --mirror, a branch and its tag) are diffed once:
# dedupe on the sha (field 1; a sha fixes its parents). FAILS CLOSED.
if ! _commits=$(awk 'NF && !seen[$1]++' "$_PII_TMP/commits"); then
  echo "ERROR: cannot dedupe pushed commits — PII gate fails closed" >&2
  exit 1
fi
while IFS= read -r _line; do
  [[ -z "$_line" ]] && continue
  read -r -a _fields <<<"$_line"
  _append_commit_diffs "${_fields[@]}"
done <<<"$_commits"

# Standalone fallback: called directly (not from a hook), so NO ref line was read. A
# deletion-only push read a line and correctly scans nothing. FAILS CLOSED on a git error;
# a repo with no commits has nothing to scan.
if [[ "$_saw_ref" != "true" ]] && cast_git_safe "$REPO_ROOT" rev-parse --verify --quiet HEAD >/dev/null 2>&1; then
  if _sd=$(cast_git_safe "$REPO_ROOT" diff "${_DIFF_FLAGS[@]}" HEAD~1 HEAD -- . ':(exclude)plugin/' 2>/dev/null); then
    :
  elif _sd=$(cast_git_safe "$REPO_ROOT" diff "${_DIFF_FLAGS[@]}" "$EMPTY_TREE" HEAD -- . ':(exclude)plugin/' 2>/dev/null); then
    :
  else
    echo "ERROR: cannot diff HEAD for the standalone scan — PII gate fails closed" >&2
    exit 1
  fi
  _pii_add_diff "$_sd" "HEAD for the standalone scan"
fi

# ---- Helpers ----------------------------------------------------------------

# Single pass (G1c): parse the diff ONCE into line-aligned files, names (the ordinal of the
# header of the file each added line belongs to) and added (the line without its leading '+'),
# so each pattern below is ONE grep over every added line. The header text is written once per
# header to files (line N = the Nth `diff --git` header), so the scratch grows with the diff,
# not with header length x added lines. The rules are those of the per-line loop it replaced: EVERY
# `diff --git` line resets the per-file state; a file's allowlist skip applies only when its
# header is exactly `diff --git a/P b/P` (both halves equal, checked by length and string
# equality, so a path containing " b/" cannot spoof an allowlisted name); anything else (quoted/
# non-ASCII path, rename, ambiguous) keeps the raw header text as its name, is never
# allowlisted, and has its added lines scanned. plugin/ (a generated mirror of already-scanned
# source, drift-gated by CI) is skipped as belt-and-suspenders to the pathspec exclusion. Only
# `+` lines after a hunk header are added lines; no `+++` exclusion: the `+++ b/file` header
# only occurs before the first @@, so inside a hunk a `+++` line is real content. Byte-wise
# under the exported LC_ALL=C; paths and the allowlist reach awk via ENVIRON (no -v escape
# processing). FAILS CLOSED on any awk error.
_PII_ALLOW=$(printf '%s\n' "${PII_ALLOWLIST[@]}")
if ! _PII_D="$_PII_TMP" _PII_ALLOW="$_PII_ALLOW" awk '
  BEGIN {
    names = ENVIRON["_PII_D"] "/names"; added = ENVIRON["_PII_D"] "/added"
    files = ENVIRON["_PII_D"] "/files"; nf = 0
    n = split(ENVIRON["_PII_ALLOW"], a, "\n")
    for (i = 1; i <= n; i++) if (a[i] != "") allow[a[i]] = 1
    printf "" > names; printf "" > added; printf "" > files
  }
  substr($0, 1, 11) == "diff --git " {
    rest = substr($0, 12); file = rest; skip = 0; inhunk = 0
    L = length(rest); half = int((L - 5) / 2)
    if (half > 0 && 2 * half + 5 == L && substr(rest, 1, 2) == "a/" \
        && substr(rest, half + 3, 3) == " b/" && substr(rest, 3, half) == substr(rest, half + 6, half)) {
      file = substr(rest, 3, half)
      if ((file in allow) || substr(file, 1, 7) == "plugin/") skip = 1
    }
    nf++; print file > files
    next
  }
  substr($0, 1, 2) == "@@" { inhunk = 1; next }
  inhunk && !skip && substr($0, 1, 1) == "+" { print nf > names; print substr($0, 2) > added }
' "$_PII_TMP/diff"; then
  echo "ERROR: cannot parse the scan input — PII gate fails closed" >&2
  exit 1
fi

# Scan every added line for a pattern ($2), skipping allowlisted files (parsed above). Prints
# hits as "  [label] file: content" in diff order. Returns 0 always (caller decides whether hits
# are fatal). $3 (optional): extra grep flags (e.g., "-i"). $4 (optional): exclusion ERE, tested
# against each MATCH (grep -o), not the whole line: a line is a hit if ANY of its matches
# survives, so a placeholder on the same line cannot hide a real address or path (the full line
# is printed once). Without $4 the whole line is the unit (no -o). $4 requires a pattern that
# cannot match the empty string: -o prints nothing for an empty match, so a line whose only
# matches are empty would be dropped silently. Anchors and \b in $4 see only the match text.
# grep status: 0 = match, 1 = no match, anything else (2 = bad pattern / I/O) is a SCAN ERROR
# and must not read as "no match". -n numbers lines as the records are numbered; -a because the
# input is text by construction (no NUL survives the $(...) capture) and grep must never switch
# to "Binary file matches"; -e keeps a '-'-leading pattern a pattern. LC_ALL=C is exported for
# Check 4.
_pii_scan() {
  local label="$1" pattern="$2" extra_flags="${3:-}" exclusion="${4:-}" rc=0 mode="line"
  # Create/truncate the output files BEFORE grep: a redirect that cannot open its file never
  # runs grep and returns 1, which would read as "no match" (fail open). This closes the
  # open/create failures (a dangling path, ENOSPC on create); once the files exist, the `>`
  # below only truncates, which needs no space. A same-user process swapping the files between
  # this guard and grep is outside the boundary (see RESIDUALS).
  if ! { : >"$_PII_TMP/hits" && : >"$_PII_TMP/excl" && : >"$_PII_TMP/mtext"; } 2>/dev/null; then
    echo "  [scan-error] $label: cannot write the scan scratch"
    return 0
  fi
  if [[ -n "$exclusion" ]]; then
    # Match mode: one `N:match` hits line per match; the exclusion runs over the match texts.
    mode="match"
    # shellcheck disable=SC2086
    grep -n -o -a $GREP_FLAGS $extra_flags -e "$pattern" -- "$_PII_TMP/added" >"$_PII_TMP/hits" 2>/dev/null || rc=$?
  else
    # shellcheck disable=SC2086
    grep -n -a $GREP_FLAGS $extra_flags -e "$pattern" -- "$_PII_TMP/added" >"$_PII_TMP/hits" 2>/dev/null || rc=$?
  fi
  if [[ "$rc" -eq 1 ]]; then
    return 0
  elif [[ "$rc" -ne 0 ]]; then
    echo "  [scan-error] $label: grep rc=$rc"
    return 0
  fi
  if [[ "$mode" == "match" ]]; then
    # mtext line j = the text of hits line j; the exclusion grep's line numbers index hits lines.
    if ! awk '{ i = index($0, ":"); print substr($0, i + 1) }' "$_PII_TMP/hits" >"$_PII_TMP/mtext" 2>/dev/null; then
      echo "  [scan-error] $label: cannot extract matches"
      return 0
    fi
    rc=0
    grep -n -a -E -e "$exclusion" -- "$_PII_TMP/mtext" >"$_PII_TMP/excl" 2>/dev/null || rc=$?
    if [[ "$rc" -ne 0 && "$rc" -ne 1 ]]; then
      echo "  [scan-error] $label: exclusion grep rc=$rc"
      return 0
    fi
  fi
  # Join: report record N when it is a hit and not excluded, naming the file of its header
  # ordinal. In line mode excl holds record numbers; in match mode (mode=match) it holds
  # indices of hits lines, and record N is reported if ANY of its hits lines survives, once.
  # Unparsable grep output, a record or file stream shorter than a hit's number, or rc 0 with
  # no hits line written (nh == 0, or max == 0 in line mode; e.g. the hits file is /dev/null)
  # is a scan error. At most 200 hits are printed per pattern, then a count of the rest; the
  # verdict is unchanged.
  _PII_D="$_PII_TMP" awk -v label="$label" -v mode="$mode" '
    function num(l,   i, n) {
      i = index(l, ":"); n = substr(l, 1, i - 1)
      return (i > 1 && n ~ /^[0-9]+$/) ? n + 0 : -1
    }
    BEGIN {
      d = ENVIRON["_PII_D"]
      while ((r = (getline l < (d "/excl"))) > 0) {
        n = num(l); if (n < 0) { bad = 1; break }
        if (mode == "match") exm[n] = 1; else ex[n] = 1
      }
      if (r < 0) bad = 1
      while (!bad && (r = (getline l < (d "/hits"))) > 0) {
        n = num(l); if (n < 0) { bad = 1; break }
        nh++
        if (mode == "match" && (nh in exm)) continue
        hit[n] = 1; if (n > max) max = n
      }
      if (r < 0) bad = 1
      if (bad) { print "  [scan-error] " label ": unparsable grep output"; exit 0 }
      if (nh == 0 || (mode == "line" && max == 0)) {
        print "  [scan-error] " label ": grep reported a match but wrote no hits"; exit 0
      }
      fo = 0; ft = ""; shown = 0
      for (k = 1; k <= max; k++) {
        if ((getline o < (d "/names")) <= 0 || (getline ct < (d "/added")) <= 0) {
          print "  [scan-error] " label ": record stream ended early"; exit 0
        }
        if (!(k in hit) || (k in ex)) continue
        o += 0
        while (fo < o) {
          if ((getline ft < (d "/files")) <= 0) {
            print "  [scan-error] " label ": file list ended early"; exit 0
          }
          fo++
        }
        if (shown < 200) printf "  [%s] %s: %s\n", label, ft, ct
        shown++
      }
      if (shown > 200) printf "  [%s] ... and %d more hit lines not shown\n", label, shown - 200
    }' || echo "  [scan-error] $label: join failed"
}

# Case-insensitive variant of _pii_scan. Patterns are EREs; case-insensitivity comes from the
# -i flag, so a pattern must NOT embed (?i) (that is PCRE syntax, not ERE).
_pii_scan_ci() {
  _pii_scan "$1" "$2" "-i" "${3:-}"
}

# ---- Run scans --------------------------------------------------------------

PII_HITS=""

# Generic email scan — flags any email address; safe senders and obvious placeholders
# are excluded via a combined exclusion regex, applied per match.
_EMAIL_EXCLUSION='users\.noreply\.github\.com|noreply@anthropic\.com|@example\.(com|org)|your-email@|user@example|@example\b'
PII_HITS+=$(_pii_scan "email" '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' "" "$_EMAIL_EXCLUSION" || true)

# Generic hardcoded home-path scan — flags /Users/<name>. CI-runner and fixture usernames are
# excluded per match; /Users/<name> and /Users/$VAR never match the path pattern.
_PATH_EXCLUSION='/Users/testuser\b|/Users/runner\b'
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

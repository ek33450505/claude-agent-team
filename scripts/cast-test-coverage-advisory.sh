#!/usr/bin/env bash
# cast-test-coverage-advisory.sh — CAST Pre-Commit Test-Coverage Advisory
#
# Reports which existing BATS tests reference each staged scripts/bin/hook/
# completions file, at commit time. Report-only advisory — never blocks the
# commit, regardless of what (or how little) coverage it finds.
#
# Motivation: a previous session ran the test suites its change ADDED but not
# the six suites that already covered the file it EDITED, and shipped a
# defect to CI. This advisory surfaces existing coverage before the commit
# lands so a reviewer can spot a gap immediately — it enforces nothing.
#
# Match strategy: fixed-string match on the REPO-RELATIVE PATH (e.g.
# "bin/cast"), never the basename. Basename matching over-matches badly on
# this repo — e.g. "cast" (the basename of bin/cast) matches 187 test files
# vs. 35 for the path-based match, because the word "cast" is present almost
# everywhere. Path matching is the entire reason this script exists — do not
# "simplify" it back to a basename grep.
#
# Exit codes:
#   0 — always (report-only; never blocks the commit under any condition)
#       (sole exception: a malformed CAST_REPO_ROOT is a config error and exits 1 —
#        the pre-commit hook invokes this script with `|| true`, so it still never blocks)

set -euo pipefail

# Hardened git (cast_git_safe): repo-local exec config (core.fsmonitor ran for `git diff --cached`)
# must not run from a hook. FAIL CLOSED if the lib is not loadable beside this script — never fall
# back to bare git. The -r guard matters: on bash 3.2 a bare `source <missing-file>` aborts under
# set -e.
_CAST_LIB="$(dirname "$0")/cast-hook-lib.sh"
# shellcheck source=cast-hook-lib.sh
if [[ -r "$_CAST_LIB" ]] && source "$_CAST_LIB"; then
	:
else
	echo "ERROR [cast-test-coverage-advisory]: cast-hook-lib.sh not loadable beside $0 (fail closed)" >&2
	exit 1
fi

# CAST_REPO_ROOT wins (installed-copy mode: the hook passes the repo as data); else the
# cwd's repo. GIT_DIR/GIT_WORK_TREE are dropped (a git hook exports the committing
# worktree's gitdir, S3c-15). This script reads the STAGED set (`git diff --cached`), which
# under `git commit <paths>` / `-a` lives in a temporary index named by GIT_INDEX_FILE:
# cast_git_safe strips GIT_INDEX_FILE, so opt in via CAST_GIT_SAFE_INDEX_FILE (honoured only for
# a regular non-symlink index file directly inside the repo's git dir; see cast-hook-lib.sh).
# Not exported to anything else.
# shellcheck disable=SC2034  # read by cast_git_safe (sourced lib), not by this script
CAST_GIT_SAFE_INDEX_FILE="${GIT_INDEX_FILE:-}"
if [[ -n "${CAST_REPO_ROOT+x}" ]]; then
	if [[ "$CAST_REPO_ROOT" != /* || ! -d "$CAST_REPO_ROOT" ]]; then
		echo "ERROR [cast-test-coverage-advisory]: CAST_REPO_ROOT must be an absolute path to an existing directory: '${CAST_REPO_ROOT}'" >&2
		exit 1
	fi
	REPO_ROOT="$CAST_REPO_ROOT"
else
	REPO_ROOT="$(cast_git_safe "$PWD" rev-parse --show-toplevel 2>/dev/null || pwd)"
fi
cd "$REPO_ROOT"
unset GIT_DIR GIT_WORK_TREE

MAX_LISTED=6

# Staged files (added/copied/modified only — mirrors the plugin-drift guard's
# diff-filter so a staged deletion doesn't get scanned for coverage).
STAGED_FILES=()
while IFS= read -r f; do
	[[ -n "$f" ]] && STAGED_FILES+=("$f")
done < <(cast_git_safe "$REPO_ROOT" diff --cached --name-only --diff-filter=ACM || true)

# Scan only these prefixes. Everything else (including tests/ and plugin/,
# which are generated/derived surfaces) is intentionally skipped.
SCANNED=()
if [[ ${#STAGED_FILES[@]} -gt 0 ]]; then
	for f in "${STAGED_FILES[@]}"; do
		case "$f" in
		scripts/* | bin/* | .githooks/* | completions/*)
			SCANNED+=("$f")
			;;
		esac
	done
fi

# Always print the scanned-file count, even when it's 0 — a silent advisory
# that scans nothing looks identical to a clean pass (see blast-radius-lint's
# 2026-06-12 zero-file false-clean incident). Visibility is the point.
echo "[CAST test-coverage-advisory] scanned ${#SCANNED[@]} staged file(s) under scripts/, bin/, .githooks/, completions/"

if [[ ${#SCANNED[@]} -eq 0 ]]; then
	exit 0
fi

for f in "${SCANNED[@]}"; do
	matches=()
	while IFS= read -r m; do
		[[ -n "$m" ]] && matches+=("$m")
	done < <(grep -rlF -- "$f" tests/*.bats 2>/dev/null || true)

	if [[ ${#matches[@]} -eq 0 ]]; then
		echo "  $f: no test file references this path"
	else
		total=${#matches[@]}
		listed=("${matches[@]:0:$MAX_LISTED}")
		# Join on comma only (bash uses just the FIRST char of IFS for [*]),
		# then widen to comma-space. Do not collapse these two steps back into
		# IFS=', ' — that silently drops the space.
		joined="$(
			IFS=','
			echo "${listed[*]}"
		)"
		joined="${joined//,/, }"
		if [[ $total -gt $MAX_LISTED ]]; then
			echo "  $f: $joined (+$((total - MAX_LISTED)) more)"
		else
			echo "  $f: $joined"
		fi
	fi
done

exit 0

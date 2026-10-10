#!/usr/bin/env bash
# cast-lint-bsd-stat.sh — Ratchet: a BSD-first `stat -f … || stat -c …` fallback in tests/ is a
# violation.
#
# BUG CLASS: GNU `stat -f` means FILESYSTEM status, and it SUCCEEDS on Linux (printing something
# unrelated to the file). So `stat -f %Lp "$f" || stat -c %a "$f"` never reaches its `|| stat -c`
# fallback on Linux CI: the test reads garbage and passes or fails for the wrong reason.
# (The GNU-first order, `stat -c … || stat -f …`, is safe: BSD `stat -c` is an error, so the
# fallback does run on macOS. That order is NOT flagged.)
#
# FIX: use `file_mode <path>` / `file_mtime <path>` from tests/helpers/setup.bash, which pick the
# stat flavour from $OSTYPE instead of relying on a failure.
#
# Scans tests/**/*.bats and tests/**/*.bash (CAST_LINT_TESTS_DIR overrides tests/, for testing).
# Detection is line-based, not a shell parser (same stance as cast-lint-source-guard.sh):
#   - backslash continuations, lines ending in `||` (any trailing whitespace) and lines starting
#     with `||` are joined into one logical line first;
#   - a trailing ` # comment` is ignored (quote-aware), so it cannot cause a false positive;
#   - full-line comments are skipped (they document the bug, e.g. in helpers/setup.bash);
#   - the regex looks for `stat [flags] -f…` followed later on the line by `|| … stat [flags] -c`.
#
# Known limits: the trailing-comment stripper is a heuristic, so contrived input can produce a
# FALSE NEGATIVE (a violation missed), e.g. an escaped space before `#` (`a\ #b`) or a `#` inside
# a parameter expansion such as `${x/ #/_}` is mistaken for a comment start and the rest of the
# line is dropped. Not seen in real tests; the lint is a ratchet, not a parser.
#
# Exit 0: clean. Exit 1: violations found (file:line listing), or nothing was scanned.

set -euo pipefail

if [[ -n "${CAST_REPO_ROOT+x}" ]]; then
	if [[ "$CAST_REPO_ROOT" != /* || ! -d "$CAST_REPO_ROOT" ]]; then
		echo "ERROR [cast-lint-bsd-stat]: CAST_REPO_ROOT must be an absolute path to an existing directory: '${CAST_REPO_ROOT}'" >&2
		exit 1
	fi
	REPO_ROOT="$CAST_REPO_ROOT"
else
	REPO_ROOT="$(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE git rev-parse --show-toplevel 2>/dev/null)" || REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fi
TESTS_DIR="${CAST_LINT_TESTS_DIR:-${REPO_ROOT}/tests}"

# BSD-first: `stat` (+ optional flags) then an `-f` option (bare or inside a flag cluster such as
# `-Lf`), later `||`, later `stat` (+ flags) `-c` (same cluster rule).
BSD_FIRST_RE='stat[[:space:]]+(-[A-Za-z]+[[:space:]]+)*-[A-Za-z]*f([^[:alnum:]_-]|$).*\|\|.*stat[[:space:]]+(-[A-Za-z]+[[:space:]]+)*-[A-Za-z]*c([^[:alnum:]_-]|$)'
# A logical line that ends in `||` (any trailing whitespace) / a line that starts with `||`.
OR_TRAIL_RE='\|\|[[:space:]]*$'
OR_LEAD_RE='^[[:space:]]*\|\|'

files=()
while IFS= read -r -d '' _f; do
	files+=("$_f")
done < <(find "$TESTS_DIR" -type f \( -name '*.bats' -o -name '*.bash' \) -not -path '*/test_helper/*' -print0 2>/dev/null)

# Hermetic zero-file sanity check — a lint that scans nothing must never pass.
if [[ "${#files[@]}" -eq 0 ]]; then
	echo "ERROR [cast-lint-bsd-stat]: scanned 0 files in '${TESTS_DIR}' — refusing to pass on empty input"
	exit 1
fi

violations=0
declare -a violation_lines=()

# _strip_comment <line>: print the line cut at the first unquoted `#` that follows whitespace
# (a trailing shell comment). Tracks '...' and "..." and skips backslash-escaped characters, so
# `$#`, `${#a}` and a `#` inside quotes are kept.
_strip_comment() {
	local s="$1" i c q="" n=${#1}
	for ((i = 0; i < n; i++)); do
		c="${s:i:1}"
		if [[ -n "$q" ]]; then
			[[ "$c" == "\\" && "$q" == '"' ]] && i=$((i + 1))
			[[ "$c" == "$q" ]] && q=""
		elif [[ "$c" == "\\" ]]; then
			i=$((i + 1))
		elif [[ "$c" == "'" || "$c" == '"' ]]; then
			q="$c"
		elif [[ "$c" == "#" && $i -gt 0 && "${s:i-1:1}" == [[:space:]] ]]; then
			printf '%s' "${s:0:i}"
			return 0
		fi
	done
	printf '%s' "$s"
}

# _flush_pending: evaluate the accumulated logical line (pending / pending_start / file are the
# caller's locals) and clear it.
_flush_pending() {
	local stripped code
	if [[ -n "$pending" ]]; then
		stripped="${pending#"${pending%%[^[:space:]]*}"}"
		if [[ "${stripped:0:1}" != "#" ]] && [[ "$stripped" =~ $BSD_FIRST_RE ]]; then
			# Cheap pre-filter passed; now ignore a trailing comment that merely mentions the pattern.
			code="$(_strip_comment "$stripped")"
			if [[ "$code" =~ $BSD_FIRST_RE ]]; then
				violations=$((violations + 1))
				violation_lines+=("  ${file#"${REPO_ROOT}/"}:${pending_start}: ${stripped}")
			fi
		fi
	fi
	pending=""
}

# _take_logical <line> <start>: fold one complete logical line into `pending`. It joins the previous
# one when that ended in `||` (trailing, any whitespace) or this one starts with `||`.
_take_logical() {
	local cur="$1" start="$2"
	if [[ -n "$pending" ]] && { [[ "$pending" =~ $OR_TRAIL_RE ]] || [[ "$cur" =~ $OR_LEAD_RE ]]; }; then
		pending+=" $cur"
	else
		_flush_pending
		pending="$cur"
		pending_start="$start"
	fi
}

_scan_file() {
	local file="$1" raw_line
	local lineno=0 cur="" cur_start=0 pending="" pending_start=0
	while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
		lineno=$((lineno + 1))
		[[ -z "$cur" ]] && cur_start=$lineno
		if [[ "$raw_line" == *\\ ]]; then
			cur+="${raw_line%\\} "
			continue
		fi
		cur+="$raw_line"
		_take_logical "$cur" "$cur_start"
		cur=""
	done <"$file"
	# A file ending mid-backslash-continuation: fold what was accumulated.
	[[ -n "$cur" ]] && _take_logical "$cur" "$cur_start"
	_flush_pending
}

for f in "${files[@]}"; do
	_scan_file "$f"
done

if [[ "$violations" -gt 0 ]]; then
	echo "ERROR [cast-lint-bsd-stat]: ${violations} BSD-first stat fallback(s) found:"
	for line in "${violation_lines[@]}"; do
		echo "$line"
	done
	echo ""
	echo "  Rule: GNU \`stat -f\` is filesystem status and SUCCEEDS on Linux, so the \`|| stat -c\`"
	echo "        fallback never runs there. Use file_mode / file_mtime from tests/helpers/setup.bash."
	exit 1
fi

echo "[cast-lint-bsd-stat] OK — no BSD-first stat fallbacks in ${#files[@]} file(s) under ${TESTS_DIR}"
exit 0

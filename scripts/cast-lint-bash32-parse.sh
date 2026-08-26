#!/usr/bin/env bash
# cast-lint-bash32-parse.sh — Bash 3.2 parse-error gate (local, fast).
#
# WHY: macOS ships a frozen /bin/bash 3.2.57 (Apple stopped bundling GPLv3
# bash after 3.2). A hook script whose shebang is #!/bin/bash lands on 3.2
# in production even when the author's dev shell has a newer bash first on
# PATH (homebrew bash 5.x). Some constructs newer bash parses fine but bash
# 3.2 rejects outright as a SYNTAX error (verified example: the `;;&` case
# fall-through terminator, added in bash 4.0 — `/bin/bash -n` on this
# machine's real 3.2.57 reports "syntax error near unexpected token `&'"
# for it, while bash 5.x accepts it cleanly). A rewrite that introduces one
# of these constructs into a #!/bin/bash script fails to parse on every Mac
# while passing fine on Linux.
#
# Incident (2026-08-24): a session-end hook rewrite shipped with exactly
# this class of bug and the only signal was the bats-macos CI job, 47m16s
# into a run — `bats`/`bats-ubuntu` (Linux, bash 5.x) saw nothing wrong.
# THIS SCRIPT closes that gap locally in seconds: `/bin/bash -n` (syntax
# check only, no execution) against every bash-shebang script in the repo,
# using the REAL system bash (/bin/bash), not whatever `bash` resolves to
# first on PATH.
#
# ASYMMETRIC COVERAGE — READ BEFORE TRUSTING A GREEN RUN:
#   On macOS, /bin/bash IS 3.2.57, so a green run here is meaningful
#   evidence of bash-3.2 parse compatibility.
#   On Linux (including GitHub Actions ubuntu-latest runners), /bin/bash is
#   bash 5.x — it CANNOT see 3.2-only parse failures, so this check is
#   WEAKER in CI than locally, the opposite of the usual direction. A green
#   run of this script on Linux proves NOTHING about bash-3.2 compatibility.
#   This is why it is wired into `make ci-local` as a local-only direct job
#   and deliberately NOT added to any GitHub Actions workflow — real
#   bash-3.2 coverage in CI comes from the existing bats-macos job, not
#   from this script running on a Linux runner.
#
# SCOPE: every file whose first line is a bash shebang (#!/bin/bash or
# #!/usr/bin/env bash) under scripts/, bin/, and .githooks/ — derived by
# scanning shebangs at run time, not a hardcoded file list, so new scripts
# are automatically covered.
#
# TWO DIFFERENT CHECKS, NOT ONE — READ BEFORE TRUSTING A GREEN RUN:
#   1) `$BASH_BIN -n` (PARSE-ONLY): validates syntax without executing
#      anything. It CANNOT see that mapfile/readarray don't exist as
#      builtins in bash 3.2 — that is a RUNTIME failure (`mapfile: command
#      not found`, rc=127), and a file using mapfile parses perfectly
#      clean under `-n` on 3.2. This is exactly how
#      scripts/cast-check-skip-ledger.sh shipped a live bats-macos CI
#      break (2026-08-26) while passing this lint.
#   2) The bash-4-only-builtin grep below: a static text check for
#      mapfile/readarray as actual invocations (comment-only mentions are
#      excluded). This is the check that catches the class `-n` cannot.
#   Both must pass; neither substitutes for the other.
#
# Exit codes:
#   0 — every scanned file parses clean under `$BASH_BIN -n` AND invokes no
#       bash-4-only builtin (mapfile/readarray)
#   1 — one or more files failed to parse, OR one or more files invoke a
#       bash-4-only builtin, OR the bash binary was not found/executable,
#       OR zero files were scanned (fail-closed — a lint that scans
#       nothing must never pass)
#
# Usage:
#   cast-lint-bash32-parse.sh [--help]
#
# Env overrides (testing only):
#   CAST_LINT_BASH32_DIR  — scan this ONE directory instead of the default
#                            set (scripts/, bin/, .githooks/)
#   CAST_LINT_BASH32_BASH — bash binary to syntax-check with, instead of
#                            /bin/bash. Using anything but /bin/bash defeats
#                            the point of this gate for a real run — this
#                            exists only so tests can point at a known bash.

set -euo pipefail

_usage() {
	cat <<'EOF'
Usage: cast-lint-bash32-parse.sh [--help]

Finds every bash-shebang script under scripts/, bin/, and .githooks/ and
syntax-checks it with the real system /bin/bash (bash 3.2.57 on macOS)
using `bash -n`. Catches constructs newer bash parses but bash 3.2 rejects
outright, in seconds locally, instead of a ~47-minute bats-macos CI failure.

CAVEAT: on Linux, /bin/bash is bash 5.x and CANNOT see 3.2-only parse
errors. A green run on Linux proves nothing about bash-3.2 compatibility —
this check is WEAKER in CI than locally. It is a local (make ci-local)
gate, not a GitHub Actions job, for exactly that reason.

Env overrides (testing only):
  CAST_LINT_BASH32_DIR   scan this one directory instead of the default set
  CAST_LINT_BASH32_BASH  bash binary to check with (default: /bin/bash)

Exit codes: 0 = all clean, 1 = parse error(s) found, or scan was empty.
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
	_usage
	exit 0
fi

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BASH_BIN="${CAST_LINT_BASH32_BASH:-/bin/bash}"

if [[ ! -x "${BASH_BIN}" ]]; then
	echo "ERROR [cast-lint-bash32-parse]: bash binary not found or not executable: ${BASH_BIN}" >&2
	exit 1
fi

# bash-3.2 compatible (macOS): plain indexed arrays only, no mapfile/readarray.
SCAN_ROOTS=()
if [[ -n "${CAST_LINT_BASH32_DIR:-}" ]]; then
	SCAN_ROOTS+=("${CAST_LINT_BASH32_DIR}")
else
	SCAN_ROOTS+=("${REPO_ROOT}/scripts" "${REPO_ROOT}/bin" "${REPO_ROOT}/.githooks")
fi

echo "[cast-lint-bash32-parse] checking with: ${BASH_BIN}"
echo "⚠ CAVEAT: this check is WEAKER on Linux than locally — on Linux /bin/bash is bash 5.x and" >&2
echo "  cannot see bash-3.2-only parse failures. A green run only proves 3.2 compatibility when" >&2
echo "  run on macOS against the real /bin/bash 3.2. See script header." >&2

# Derive the file set by scanning shebangs — never a hardcoded file list, so
# new scripts are covered automatically without touching this gate.
BASH_FILES=()
for root in "${SCAN_ROOTS[@]}"; do
	[[ -d "${root}" ]] || continue
	while IFS= read -r f; do
		[[ -f "${f}" ]] || continue
		first_line=$(head -n1 "${f}" 2>/dev/null || true)
		if [[ "${first_line}" == "#!/bin/bash"* || "${first_line}" == "#!/usr/bin/env bash"* ]]; then
			BASH_FILES+=("${f}")
		fi
	done < <(find "${root}" -type f -print 2>/dev/null | sort)
done

if [[ ${#BASH_FILES[@]} -eq 0 ]]; then
	echo "ERROR [cast-lint-bash32-parse]: scanned 0 bash-shebang files under: ${SCAN_ROOTS[*]} — refusing to pass on empty input" >&2
	exit 1
fi

errors=0
declare -a error_report=()

for f in "${BASH_FILES[@]}"; do
	err_out=""
	if ! err_out="$("${BASH_BIN}" -n "${f}" 2>&1)"; then
		errors=$((errors + 1))
		error_report+=("${f}")
		error_report+=("${err_out}")
	fi
done

if [[ "${errors}" -gt 0 ]]; then
	echo "" >&2
	echo "BLOCKED [cast-lint-bash32-parse]: ${errors} file(s) fail to parse under ${BASH_BIN}:" >&2
	echo "" >&2
	for line in "${error_report[@]}"; do
		echo "  ${line}" >&2
	done
	echo "" >&2
	echo "  These files cannot even be LOADED by ${BASH_BIN} — a shebang mismatch (e.g. #!/bin/bash" >&2
	echo "  on a script using a bash-4+-only construct) ships a syntax error to every macOS machine." >&2
	exit 1
fi

echo "OK [cast-lint-bash32-parse]: ${#BASH_FILES[@]} bash-shebang file(s) parse clean under ${BASH_BIN}"

# --- Bash-4-only builtin check (separate mechanism from -n above; see header) ---
# `-n` cannot see this class of bug: mapfile/readarray parse fine on 3.2 and
# fail only at runtime. This is a plain static grep for real invocations,
# excluding whole-line comments (a comment merely NAMING mapfile/readarray,
# like the ones in this very file's own header prose, is not a bug).
echo "[cast-lint-bash32-parse] checking for bash-4-only builtins (mapfile, readarray)..."

builtin_errors=0
declare -a builtin_report=()

for f in "${BASH_FILES[@]}"; do
	# Exclude this lint script's OWN file: the grep pattern immediately
	# below contains the literal words "mapfile"/"readarray" as CODE (not
	# just a comment), which would otherwise self-match — the same
	# self-match trap tests/skip-ledger-drift.bats handles by excluding
	# its own filename from the enumeration it verifies.
	[[ "${f}" == *"cast-lint-bash32-parse.sh" ]] && continue

	hits=$(grep -nE '(^|[^#[:alnum:]_])(mapfile|readarray)([[:space:]]|$)' "${f}" 2>/dev/null |
		grep -vE '^[0-9]+:[[:space:]]*#' || true)
	if [[ -n "${hits}" ]]; then
		builtin_errors=$((builtin_errors + 1))
		builtin_report+=("${f}:")
		while IFS= read -r hit_line; do
			builtin_report+=("    ${hit_line}")
		done <<<"${hits}"
	fi
done

if [[ "${builtin_errors}" -gt 0 ]]; then
	echo "" >&2
	echo "BLOCKED [cast-lint-bash32-parse]: ${builtin_errors} file(s) invoke a bash-4-only builtin" >&2
	echo "  (mapfile/readarray) that does not exist in bash 3.2. These PARSE fine under" >&2
	echo "  ${BASH_BIN} -n and fail only at RUNTIME ('command not found', rc=127) on macOS's" >&2
	echo "  real /bin/bash. Replace with:" >&2
	echo "    arr=()" >&2
	echo "    while IFS= read -r line; do arr+=(\"\${line}\"); done < <(producer-command)" >&2
	echo "" >&2
	for line in "${builtin_report[@]}"; do
		echo "  ${line}" >&2
	done
	exit 1
fi

echo "OK [cast-lint-bash32-parse]: 0 bash-4-only builtin (mapfile/readarray) invocations found"
exit 0

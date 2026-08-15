#!/usr/bin/env bash
# Run BATS tests — full suite (CI glob) or a scoped subset via --files.
# MANDATORY: runs against an isolated temp $HOME to prevent real ~/.claude damage.
#
# Usage:
#   bash tests/run.sh [--tap]                                    # full suite (CI glob)
#   bash tests/run.sh --files tests/a.bats tests/b.bats [--tap]  # scoped subset
#
# In --files mode the listed files REPLACE the glob (they are never appended), so
# BATS runs ONLY those files. Each --files argument must be an existing regular file
# matching a tests/*.bats path; absolute paths, '..' traversal and non-.bats paths
# are rejected (exit 1). Other flags (e.g. --tap) flow through to bats unchanged.
#
# Bare file arguments outside --files are REJECTED (exit 1, before any work runs) —
# only --files scopes a run. This closes a footgun where `bash tests/run.sh
# tests/foo.bats` looked scoped but silently fell through to the full suite.
# KNOWN LIMITATION: a passthrough flag that takes a separate value (e.g. `--filter
# <regex>`) is not supported — the value would look like a bare positional and get
# rejected. Use --files for scoping. (Verified: no caller in this repo passes such
# a flag.)
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"

# ── Preflight: BATS helper submodules must be initialised. ─────────────────────────────
# tests/test_helper/bats-support and tests/test_helper/bats-assert are git submodules
# (see .gitmodules); a plain 'git clone' does not populate them, and every test file
# loads them directly. An uninitialised submodule leaves an EMPTY directory, so this
# checks for the actual loadable file, not just directory presence. Fires before any
# other work (both the full-suite and --files scoped paths need these helpers).
# Gated on THIS repo actually declaring the submodules (.gitmodules present and
# referencing the bats helper path): a real clone of this repo always has .gitmodules
# (it's tracked) even before `git submodule update --init`, so the check still fires
# there. Synthetic fixture repos (e.g. tests/cast-run-sh-scoped.bats's _new_fake(), a
# bare mktemp -d with no .gitmodules) declare no such submodules and legitimately
# don't need this check — their fixtures never load the helpers either.
if [[ -f .gitmodules ]] && grep -q 'tests/test_helper/bats-' .gitmodules 2>/dev/null; then
  for _helper in tests/test_helper/bats-support/load.bash tests/test_helper/bats-assert/load.bash; do
    if [[ ! -f "$_helper" ]]; then
      echo "ERROR [tests/run.sh]: BATS helper submodules are not initialised." >&2
      echo "  tests/test_helper/bats-support and tests/test_helper/bats-assert are git submodules" >&2
      echo "  and a plain 'git clone' does not populate them." >&2
      echo "  Fix: git submodule update --init --recursive" >&2
      exit 1
    fi
  done
fi

# ── Parse args: peel off an optional scoped "--files <f1> <f2> ..." list. ──────────────
# Anything that is not part of --files (e.g. --tap) is collected into PASSTHRU and
# forwarded to bats verbatim. bash-3.2 safe: plain arrays + while/case, guarded
# empty-array expansion ("${arr[@]+"${arr[@]}"}").
SCOPED_MODE=0
SCOPED_FILES=()
PASSTHRU=()
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --files)
      SCOPED_MODE=1
      shift
      # Consume the following non-flag args as scoped test files.
      while [[ "$#" -gt 0 && "$1" != -* ]]; do
        SCOPED_FILES+=("$1")
        shift
      done
      ;;
    -*)
      PASSTHRU+=("$1")
      shift
      ;;
    *)
      echo "tests/run.sh: bare file arguments are not supported — did you mean: --files <f>?" >&2
      echo "  Got bare argument: '$1'" >&2
      echo "  A bare positional does NOT scope the run — the FULL suite would execute." >&2
      exit 1
      ;;
  esac
done

# Create isolated temp HOME + TAP capture file; register combined cleanup
TEST_HOME="$(mktemp -d)"
TAP_OUT="$(mktemp)"
trap 'rm -rf "$TEST_HOME" "$TAP_OUT"' EXIT

# Seed temp HOME with minimal CAST structure (mirrors CI setup)
mkdir -p "$TEST_HOME"/.claude/{scripts,logs,cast/events,agent-status}
cp "$REPO"/scripts/*.sh "$TEST_HOME"/.claude/scripts/
cp "$REPO"/scripts/*.py "$TEST_HOME"/.claude/scripts/ 2>/dev/null || true
chmod +x "$TEST_HOME"/.claude/scripts/*.sh

# Switch to isolated HOME and print banner (BOTH paths stay isolated)
export HOME="$TEST_HOME"
if [[ "$SCOPED_MODE" -eq 1 ]]; then
  echo "tests/run.sh: SCOPED run (${#SCOPED_FILES[@]} file(s)) — isolated temp HOME=$HOME — real ~/.claude untouched" >&2
else
  echo "tests/run.sh: isolated temp HOME=$HOME — real ~/.claude untouched" >&2
fi

# Build the list of .bats files to run.
BATS_FILE_ARGS=()
if [[ "$SCOPED_MODE" -eq 1 ]]; then
  # SCOPED: run ONLY the validated --files list (replaces the glob, never appends).
  if [[ "${#SCOPED_FILES[@]}" -eq 0 ]]; then
    echo "tests/run.sh: --files requires at least one tests/*.bats argument" >&2
    exit 1
  fi
  for _f in "${SCOPED_FILES[@]}"; do
    # Shape: must be a relative tests/*.bats path (rejects absolute escapes + non-.bats).
    case "$_f" in
      tests/*.bats) : ;;
      *)
        echo "tests/run.sh: --files arg must be a tests/*.bats path, got: '$_f'" >&2
        exit 1
        ;;
    esac
    # Reject parent-dir traversal even if it would resolve back under tests/.
    case "$_f" in
      *..*)
        echo "tests/run.sh: --files arg must not contain '..': '$_f'" >&2
        exit 1
        ;;
    esac
    # Must be an existing regular file.
    if [[ ! -f "$_f" ]]; then
      echo "tests/run.sh: --files arg is not an existing file: '$_f'" >&2
      exit 1
    fi
    BATS_FILE_ARGS+=("$_f")
  done
else
  # FULL: expand the same glob list CI uses (BATS 1.13.0 is non-recursive).
  for _pat in tests/*.bats tests/hooks/*.bats tests/agents/*.bats tests/scripts/*.bats tests/skills/*.bats; do
    [[ -f "$_pat" ]] && BATS_FILE_ARGS+=("$_pat")
  done
fi

if [[ "${#BATS_FILE_ARGS[@]}" -eq 0 ]]; then
  echo "tests/run.sh: no .bats files found" >&2
  exit 1
fi

# Count planned tests statically from @test lines (before execution).
# PLANNED derives from BATS_FILE_ARGS, so it auto-scopes to the --files subset.
PLANNED="$("$REPO/scripts/cast-count-planned-tests.sh" "${BATS_FILE_ARGS[@]}")"

# Run BATS; stream output via tee so the user sees it live.
# stdout is a pipe here, so bats defaults to TAP formatter (readable + parseable).
# set +o pipefail: let tee succeed even when bats exits non-zero; capture via PIPESTATUS.
set +o pipefail
bats "${BATS_FILE_ARGS[@]}" ${PASSTHRU[@]+"${PASSTHRU[@]}"} | tee "$TAP_OUT"
BATS_EXIT="${PIPESTATUS[0]}"
set -o pipefail

# Parse executed count from TAP plan line (1..N)
EXECUTED="$(grep -m1 "^1\.\." "$TAP_OUT" | sed 's/^1\.\.//' | tr -d '[:space:]' || true)"
if [[ -z "$EXECUTED" ]]; then
  # Fallback: count ok / not ok result lines.
  # grep -c prints "0" and exits 1 on zero matches; "|| true" keeps that single "0".
  # (A bare "|| echo 0" would append a SECOND line -> "0\n0" -> arithmetic error in
  # the gate below. This bites when bats emits its plan to stderr, e.g. a load error
  # that aborts gather-tests, leaving TAP_OUT empty.)
  EXECUTED="$(grep -cE "^(ok|not ok) " "$TAP_OUT" 2>/dev/null || true)"
  EXECUTED="${EXECUTED:-0}"
fi

# Gate: fail loudly when executed != planned — detects dropped files or truncated runs.
# Applies to BOTH full and scoped runs: a requested-but-dropped file is caught here.
# Skipped tests count as executed (ok N # skip); this catches only missing files.
if [[ "$EXECUTED" -ne "$PLANNED" ]]; then
  printf '\n[cast-count-gate] FAIL: planned=%s executed=%s\n' "$PLANNED" "$EXECUTED" >&2
  printf '  A test file may have been silently dropped from the run.\n' >&2
  exit 1
fi

exit "$BATS_EXIT"

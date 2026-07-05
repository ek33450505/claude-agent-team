#!/usr/bin/env bash
# ci-py39-annotations-lint.sh — Lint Python 3.9 annotation compatibility.
#
# Checks every scripts/*.py and bin/*.py file for two failure classes:
#
#   A) PEP-604 union syntax in annotation position (-> X | Y, : X | None,
#      variable annotations with |) WITHOUT a "from __future__ import
#      annotations" guard — crashes Python 3.9 at function/class definition time.
#
#   B) Runtime-position | unions — isinstance(x, A | B) or bare type-alias
#      assignments (ALIAS = A | B without annotation context) that the future
#      import does NOT fix, and which crash on 3.9 regardless.
#
# Style follows ci-pii-scan.sh.
#
# Usage:
#   bash scripts/ci-py39-annotations-lint.sh            # lint repo scripts
#   bash scripts/ci-py39-annotations-lint.sh --self-test # verify detection works
#
# Exit codes: 0 = clean (or self-test passed), 1 = violation(s) found
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

FINDINGS=()

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_has_future_import() {
    grep -q 'from __future__ import annotations' "$1" 2>/dev/null
}

# ---------------------------------------------------------------------------
# --self-test mode: plant a violation, verify detection, exit
# ---------------------------------------------------------------------------
if [[ "${1:-}" == "--self-test" ]]; then
    echo "[ci-py39-annotations-lint] --self-test mode"

    TMPDIR_SELF="$(mktemp -d)"
    trap 'rm -f "$TMPDIR_SELF/violation_a.py"; rmdir "$TMPDIR_SELF" 2>/dev/null || true' EXIT

    # Plant a file that violates class A (annotation pipe, no future import).
    # The function uses `-> dict | None` which crashes Python 3.9 without the guard.
    VIOLATION_FILE="$TMPDIR_SELF/violation_a.py"
    # Plant the actual violation:
    printf '#!/usr/bin/env python3\n"""No future import here.\"\"\"\nimport os\ndef foo(x: str):\n    pass\n' > "$VIOLATION_FILE"
    printf 'def bad(x: str) -> dict | None:\n    return None\n' >> "$VIOLATION_FILE"

    # Detect: the planted file has `-> dict | None` without future import
    if ! _has_future_import "$VIOLATION_FILE"; then
        # Class A: return-annotation pipe
        HIT="$(grep -nE -e '.* -> [A-Za-z].*[|]' "$VIOLATION_FILE" 2>/dev/null || true)"
        if [[ -n "$HIT" ]]; then
            echo "[ci-py39-annotations-lint] --self-test PASSED: class-A violation correctly detected"
            exit 0
        fi
    fi
    echo "[ci-py39-annotations-lint] --self-test FAILED: class-A violation NOT detected" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Collect Python files from scripts/ and bin/
# ---------------------------------------------------------------------------
SCAN_DIRS=("$REPO_ROOT/scripts" "$REPO_ROOT/bin")
PY_FILES=()
for dir in "${SCAN_DIRS[@]}"; do
    [[ -d "$dir" ]] || continue
    while IFS= read -r f; do
        PY_FILES+=("$f")
    done < <(find "$dir" -maxdepth 1 -name "*.py" -type f | sort)
done

if [[ "${#PY_FILES[@]}" -eq 0 ]]; then
    echo "[ci-py39-annotations-lint] No .py files found under scripts/ or bin/ — nothing to check."
    exit 0
fi

echo "[ci-py39-annotations-lint] Scanning ${#PY_FILES[@]} file(s) in scripts/ and bin/"
echo ""

# ---------------------------------------------------------------------------
# Class A: annotation-position PEP-604 without future import
#
# Two grep patterns (run with -e to avoid shell interpretation of > and |):
#   A1: return-type annotation:    def foo() -> Foo | Bar:
#       grep: `.* -> [A-Za-z].*[|]`
#   A2: parameter/variable annot:  x: Foo | Bar (colon + upper/lower name + pipe)
#       grep: `: [A-Za-z][A-Za-z0-9_\[\], ]*[|]`
#
# Using [|] instead of bare | avoids ERE alternation (| is meta in ERE).
# ---------------------------------------------------------------------------
echo "=== Check A: PEP-604 annotation pipes without 'from __future__ import annotations' ==="
CLASS_A_HITS=()

for f in "${PY_FILES[@]}"; do
    relpath="${f#"$REPO_ROOT/"}"
    # Skip files that already have the future import — they are correctly guarded.
    _has_future_import "$f" && continue

    # A1: return-type annotations:  -> SomeType | OtherType
    hits_a1="$(grep -nE -e '.* -> [A-Za-z].*[|]' "$f" 2>/dev/null || true)"
    # A2: parameter/variable annotations:  varname: SomeType | OtherType
    #     Require `: ` + letter/digit then optional type chars then `|`
    hits_a2="$(grep -nE -e ': [A-Za-z][A-Za-z0-9_\[\], ]*[|]' "$f" 2>/dev/null || true)"

    combined="${hits_a1}"$'\n'"${hits_a2}"
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        CLASS_A_HITS+=("  [missing-future-import] $relpath: $line")
    done <<< "$combined"
done

if [[ "${#CLASS_A_HITS[@]}" -eq 0 ]]; then
    echo "PASS: All files with PEP-604 annotations have the future import guard"
else
    FINDINGS+=("${CLASS_A_HITS[@]}")
fi

# ---------------------------------------------------------------------------
# Class B: runtime-position | usage (future import does NOT fix these)
#
#   B1: isinstance(x, A | B)  — use [|] to avoid ERE alternation
#   B2: Module-level ALL_CAPS type alias: ALIAS = TypeA | TypeB
#       Pattern: ^[A-Z_][A-Z0-9_]* = [A-Za-z][A-Za-z0-9_\[\],]* [|] [A-Za-z]
#       The narrow char class [A-Za-z0-9_\[\],] (no dot, quote, paren) naturally
#       excludes re.compile(...) calls and string literals, preventing false
#       positives from regex pattern strings that contain `|`.
# ---------------------------------------------------------------------------
echo ""
echo "=== Check B: runtime-position | unions (isinstance / module-level type aliases) ==="
CLASS_B_HITS=()

for f in "${PY_FILES[@]}"; do
    relpath="${f#"$REPO_ROOT/"}"

    # B1: isinstance calls with a | union
    hits_b1="$(grep -nE -e 'isinstance\(.*[|]' "$f" 2>/dev/null || true)"
    if [[ -n "$hits_b1" ]]; then
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            CLASS_B_HITS+=("  [runtime-isinstance-pipe] $relpath: $line")
        done <<< "$hits_b1"
    fi

    # B2: module-level ALLCAPS = TypeA | TypeB (no quotes/parens between = and |)
    hits_b2="$(grep -nE -e '^[A-Z_][A-Z0-9_]* = [A-Za-z][A-Za-z0-9_\[\],]* [|] [A-Za-z]' "$f" 2>/dev/null || true)"
    if [[ -n "$hits_b2" ]]; then
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            CLASS_B_HITS+=("  [runtime-type-alias-pipe] $relpath: $line")
        done <<< "$hits_b2"
    fi
done

if [[ "${#CLASS_B_HITS[@]}" -eq 0 ]]; then
    echo "PASS: No runtime-position | unions found"
else
    FINDINGS+=("${CLASS_B_HITS[@]}")
fi

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
echo ""
if [[ "${#FINDINGS[@]}" -gt 0 ]]; then
    echo "FAIL: Python 3.9 annotation compatibility violations found:"
    for finding in "${FINDINGS[@]}"; do
        echo "$finding"
    done
    echo ""
    echo "[ci-py39-annotations-lint] ${#FINDINGS[@]} finding(s). Fix:"
    echo "  Class A: add 'from __future__ import annotations' after the module docstring."
    echo "  Class B: rewrite with typing.Optional/Union (future import does not fix runtime uses)."
    exit 1
else
    echo "[ci-py39-annotations-lint] All checks passed. Scripts are Python 3.9 annotation-safe."
    exit 0
fi

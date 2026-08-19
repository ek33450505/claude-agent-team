#!/usr/bin/env python3
"""
cast-verify-memories.py — automated verified_at re-verification (CAST v10 C6)

There are TWO staleness surfaces in CAST and only one was maintained:
  (a) DB: agent_memories.last_validated_at — swept by
      scripts/cast-memory-staleness-sweep.sh. Fine, untouched here.
  (b) FILES: ~/.claude/projects/*/memory/*.md frontmatter metadata.verified_at
      — flagged by scripts/cast-stale-memories.py, but nothing re-verified it,
      so stale flags re-accumulated forever.

This script is the missing (b) re-verifier. For every memory file that
scripts/cast-stale-memories.py would flag as stale (verified_at present,
older than the stale-days threshold, and the body names a concrete
path/function/flag), it extracts concrete refs via
scripts/cast_memory_verifier.py (⚠️ NOT modified here — its behaviour is
pinned by tests/cast-memory-verifier.bats and feeds the separate DB-staleness
confidence path in cast-memory-staleness-sweep.sh) and resolves each ref
itself, against an explicit, ORDERED, named root list (first hit wins):

  1. the ref as given (expanduser'd; absolute refs are checked only here —
     a rooted join of an absolute path collapses back to the same path)
  2. the memory file's OWN directory (this is what makes a MEMORY.md-shaped
     bare-basename citation resolve)
  3. the project root decoded from the memory's parent dir name — Claude
     Code encodes a project's cwd as `~/.claude/projects/<cwd with / -> ->`,
     e.g. `-Users-testuser-Projects-personal-my-app` decodes to
     `/Users/testuser/Projects/personal/my-app`. The encoding is
     lossy (the final path component may itself contain literal hyphens), so
     decode_project_dir() tries progressively coarser suffix merges and picks
     the first that is an actual directory on disk — bounded by the number of
     hyphens in the encoded name, never an unbounded filesystem walk. If no
     merge produces a real directory (e.g. the project was deleted), this
     root is skipped entirely and refs relying on it correctly stay
     REF-BROKEN — that is a TRUE positive, not a bug.
     Tried as <project>/<ref> and <project>/scripts/<basename>.
  4. ~/.claude/<ref> and ~/.claude/scripts/<basename>
  5. cwd: <cwd>/<ref> and <cwd>/scripts/<basename> (today's original
     behaviour, kept last in the order)

A file classifies as:
  REF-BROKEN — at least one extracted path resolves under NONE of the roots
               above. The memory is provably outdated; a human must read it.
               NEVER auto-bumped.
  REFS-OK    — every extracted path resolved under some root.
  NO-REFS    — zero paths were extracted at all. A refs-resolved bump would
               be a verification claim backed by zero evidence, so this is
               its own class and is NEVER auto-bumped either.

Default mode is REPORT-ONLY and never modifies a file. The report header
names the root list once (not per-ref) so any REF-BROKEN claim can be
checked by hand; --json additionally records which root resolved each
matched ref.

--apply bumps REFS-OK files ONLY, editing ONLY inside the frontmatter block:
  - the existing `verified_at:` line's value is replaced with today's date
    (UTC, %Y-%m-%d), preserving that line's exact leading whitespace;
  - a `verified_by: cast-verify-memories.py (refs-resolved)` line is placed
    immediately after it, at the same indentation — replacing an existing
    verified_by: line rather than adding a second one.

⭐ WHY verified_by EXISTS (Ed, 2026-08-19): a refs-resolved check is a WEAKER
claim than a human confirming the memory is still true — it only proves the
paths/functions the memory names still exist, not that the memory's claim is
still correct. Recording which kind of check ran keeps the record honest
instead of laundering a path-existence test into a full human verification.

A bumped file's diff is at most those two lines: no reordering, reflowing, or
reformatting of anything else. Writes are atomic (tmp file in the same dir +
os.replace).

⚠️ Scheduling: --apply is intentionally NOT wired into cast-maintenance.sh or
any launchd job. An unattended auto-bump is a verification claim made with
nobody watching — report-only wiring is a separate decision that has not been
made yet.

Env overrides:
  CAST_MEMORIES_BASE_DIR — override ~/.claude/projects
  CAST_STALE_DAYS        — override 30

Exit codes: 0 on success (including REPORT-ONLY with REF-BROKEN findings);
            1 on a write failure during --apply; 2 on an unknown flag
            (argparse default).
"""

import argparse
import json
import os
import sys
import tempfile
from datetime import date
from typing import Dict, List, Optional, Tuple

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import cast_memory_meta  # noqa: E402
import cast_memory_verifier  # noqa: E402

VERIFIED_BY_VALUE = "cast-verify-memories.py (refs-resolved)"

# The named, ordered strategy (root *kinds*, not per-file concrete paths —
# concrete project-root/memory-dir values vary per file and are reported
# alongside each resolved ref in --json instead). Printed once in the report
# header so a REF-BROKEN claim is auditable by hand.
SEARCH_STRATEGY = [
    "1) ref as given (absolute refs only)",
    "2) memory file's own directory",
    "3) project root decoded from the memory's parent dir name "
    "(<project>/<ref>, <project>/scripts/<basename>)",
    "4) ~/.claude/<ref>, ~/.claude/scripts/<basename>",
    "5) cwd/<ref>, cwd/scripts/<basename>",
]


def default_base_dir() -> str:
    return os.environ.get(
        "CAST_MEMORIES_BASE_DIR",
        os.path.join(os.path.expanduser("~"), ".claude", "projects"),
    )


def default_stale_days() -> int:
    return int(os.environ.get("CAST_STALE_DAYS", "30"))


def find_stale_candidates(base_dir: str, stale_days: int) -> List[Tuple[str, str]]:
    """Return (filepath, content) pairs for files cast-stale-memories.py flags."""
    today = date.today()
    candidates = []
    for filepath in cast_memory_meta.iter_memory_files(base_dir):
        try:
            with open(filepath, "r", errors="replace") as fh:
                content = fh.read()
        except OSError:
            continue

        verified_at = cast_memory_meta.parse_verified_at(content)
        if verified_at is None:
            continue

        age_days = (today - verified_at).days
        if age_days <= stale_days:
            continue

        if not cast_memory_meta.has_concrete_ref(content):
            continue

        candidates.append((filepath, content))
    return candidates


def decode_project_dir(encoded: str) -> Optional[str]:
    """Best-effort decode of a Claude Code project-dir name back to a real
    absolute path, e.g. "-Users-testuser-Projects-personal-my-app"
    -> "/Users/testuser/Projects/personal/my-app".

    The encoding (cwd with '/' replaced by '-') is lossy when a path
    component itself contains a literal hyphen, so this tries progressively
    coarser suffix merges — starting from the fully-split candidate, then
    merging the last 2 segments into one hyphenated component, then the last
    3, etc. — and returns the first candidate that is a real directory on
    disk. Bounded by the number of hyphens in `encoded` (never an unbounded
    filesystem search). Returns None if `encoded` isn't in the expected
    leading-hyphen form, or if no merge produces an existing directory (e.g.
    the project has since been deleted) — callers must treat that as "this
    root is unavailable," not crash.
    """
    if not encoded.startswith("-"):
        return None
    segments = encoded.split("-")[1:]
    if not segments:
        return None

    for merge_size in range(1, len(segments) + 1):
        if merge_size == 1:
            candidate_segments = segments
        else:
            candidate_segments = segments[:-merge_size] + [
                "-".join(segments[-merge_size:])
            ]
        candidate = "/" + "/".join(candidate_segments)
        if os.path.isdir(candidate):
            return candidate

    return None


def build_search_roots(memory_filepath: str) -> List[Tuple[str, Optional[str]]]:
    """Return the ordered (label, root_dir) list used to resolve refs cited by
    `memory_filepath`. root_dir is None for the "as-given" step, which uses
    the ref literally (expanduser'd) rather than joining it to a root."""
    home = os.path.expanduser("~")
    memory_dir = os.path.dirname(memory_filepath)
    project_dir_name = os.path.basename(os.path.dirname(memory_dir))
    project_root = decode_project_dir(project_dir_name)
    cwd = os.getcwd()

    roots: List[Tuple[str, Optional[str]]] = [
        ("as-given", None),
        ("memory-file-dir", memory_dir),
    ]
    if project_root:
        roots.append(("project-root", project_root))
        roots.append(("project-root/scripts", os.path.join(project_root, "scripts")))
    roots.append(("home/.claude", os.path.join(home, ".claude")))
    roots.append(("home/.claude/scripts", os.path.join(home, ".claude", "scripts")))
    roots.append(("cwd", cwd))
    roots.append(("cwd/scripts", os.path.join(cwd, "scripts")))
    return roots


def resolve_ref(
    ref: str, roots: List[Tuple[str, Optional[str]]]
) -> Optional[Tuple[str, str]]:
    """Resolve ref against the ordered roots; first hit wins. Returns
    (resolved_absolute_path, root_label), or None if no root has it."""
    expanded = os.path.expanduser(ref)
    is_abs = os.path.isabs(expanded)
    basename = os.path.basename(ref)

    for label, root in roots:
        if label == "as-given":
            candidate = expanded
        elif is_abs:
            # An absolute ref is only meaningfully checked "as given" — a
            # rooted join would just collapse back to the same path.
            continue
        elif label.endswith("/scripts"):
            candidate = os.path.join(root, basename)
        else:
            candidate = os.path.join(root, ref)

        if os.path.isfile(candidate):
            return os.path.abspath(candidate), label

    return None


def classify(content: str, memory_filepath: str) -> Dict:
    """Classify content as REF-BROKEN / REFS-OK / NO-REFS, with per-ref detail."""
    paths, _functions = cast_memory_verifier.extract_paths_and_functions(content)
    if not paths:
        return {"status": "NO-REFS", "missing_refs": [], "resolved_refs": []}

    roots = build_search_roots(memory_filepath)
    missing: List[str] = []
    resolved: List[Dict] = []
    for ref in sorted(set(paths)):
        hit = resolve_ref(ref, roots)
        if hit is None:
            missing.append(ref)
        else:
            resolved_path, root_label = hit
            resolved.append({"ref": ref, "resolved_path": resolved_path, "root": root_label})

    if missing:
        return {
            "status": "REF-BROKEN",
            "missing_refs": sorted(missing),
            "resolved_refs": resolved,
        }
    return {"status": "REFS-OK", "missing_refs": [], "resolved_refs": resolved}


def _leading_whitespace(line: str) -> str:
    return line[: len(line) - len(line.lstrip())]


def _line_ending(line: str) -> str:
    if line.endswith("\r\n"):
        return "\r\n"
    if line.endswith("\n"):
        return "\n"
    return ""


def bump_verified(content: str, today_str: str) -> Optional[str]:
    """Return new content with verified_at bumped and verified_by set, or
    None if no verified_at: line could be found in the frontmatter (should
    not happen for a candidate that already parsed a verified_at date, but
    guarded defensively so a caller never writes an unexpected file)."""
    lines = content.splitlines(keepends=True)
    in_frontmatter = False
    va_idx = None
    for i, line in enumerate(lines):
        stripped = line.strip()
        if i == 0 and stripped == "---":
            in_frontmatter = True
            continue
        if not in_frontmatter:
            break
        if stripped == "---":
            break
        if stripped.startswith("verified_at:"):
            va_idx = i
            break

    if va_idx is None:
        return None

    va_line = lines[va_idx]
    leading_ws = _leading_whitespace(va_line)
    nl = _line_ending(va_line)
    lines[va_idx] = f"{leading_ws}verified_at: {today_str}{nl}"

    vb_idx = va_idx + 1
    vb_line = lines[vb_idx] if vb_idx < len(lines) else ""
    if vb_line.strip().startswith("verified_by:"):
        vb_nl = _line_ending(vb_line)
        lines[vb_idx] = f"{leading_ws}verified_by: {VERIFIED_BY_VALUE}{vb_nl or nl}"
    else:
        lines.insert(va_idx + 1, f"{leading_ws}verified_by: {VERIFIED_BY_VALUE}{nl}")

    return "".join(lines)


def write_atomic(filepath: str, new_content: str) -> None:
    dirpath = os.path.dirname(filepath) or "."
    fd, tmp_path = None, None
    try:
        fd, tmp_path = tempfile.mkstemp(dir=dirpath, prefix=".cast-verify-tmp-")
        with os.fdopen(fd, "w") as fh:
            fh.write(new_content)
        os.replace(tmp_path, filepath)
    except OSError:
        if tmp_path and os.path.exists(tmp_path):
            try:
                os.remove(tmp_path)
            except OSError:
                pass
        raise


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Re-verify stale memory verified_at flags via ref existence checks."
    )
    parser.add_argument(
        "--apply", action="store_true", help="Bump REFS-OK files' verified_at/verified_by."
    )
    parser.add_argument("--json", action="store_true", help="Emit JSON instead of text.")
    parser.add_argument(
        "--base-dir", default=None, help="Override memory base dir (else CAST_MEMORIES_BASE_DIR)."
    )
    parser.add_argument(
        "--days", type=int, default=None, help="Stale-days threshold (else CAST_STALE_DAYS)."
    )
    args = parser.parse_args()

    base_dir = args.base_dir or default_base_dir()
    stale_days = args.days if args.days is not None else default_stale_days()

    candidates = find_stale_candidates(base_dir, stale_days)

    ref_broken: List[Dict] = []
    refs_ok: List[Dict] = []
    no_refs: List[Dict] = []
    write_failure = False
    today_str = date.today().strftime("%Y-%m-%d")

    for filepath, content in candidates:
        result = classify(content, filepath)
        status = result["status"]

        if status == "REF-BROKEN":
            ref_broken.append(
                {
                    "file": filepath,
                    "missing_refs": result["missing_refs"],
                    "resolved_refs": result["resolved_refs"],
                }
            )
            continue

        if status == "NO-REFS":
            no_refs.append({"file": filepath})
            continue

        # REFS-OK — the only bump-eligible class.
        entry = {
            "file": filepath,
            "bumped": False,
            "resolved_refs": result["resolved_refs"],
        }
        if args.apply:
            new_content = bump_verified(content, today_str)
            if new_content is None:
                write_failure = True
            else:
                try:
                    write_atomic(filepath, new_content)
                    entry["bumped"] = True
                except OSError as exc:
                    write_failure = True
                    entry["error"] = str(exc)
        refs_ok.append(entry)

    if args.json:
        payload = {
            "search_roots": SEARCH_STRATEGY,
            "stale_count": len(candidates),
            "ref_broken": ref_broken,
            "refs_ok": refs_ok,
            "no_refs": no_refs,
            "applied": args.apply,
        }
        print(json.dumps(payload, indent=2))
    else:
        print("Search roots (first hit wins):")
        for line in SEARCH_STRATEGY:
            print(f"  {line}")
        print(
            f"{len(candidates)} stale memories evaluated "
            f"({len(ref_broken)} REF-BROKEN, {len(refs_ok)} REFS-OK, {len(no_refs)} NO-REFS)"
        )
        if ref_broken:
            print("REF-BROKEN:")
            for entry in ref_broken:
                for ref in entry["missing_refs"]:
                    print(f"  {entry['file']} — missing ref: {ref}")
        if no_refs:
            print("NO-REFS (not bump-eligible — no evidence to verify):")
            for entry in no_refs:
                print(f"  {entry['file']}")
        if refs_ok:
            print("REFS-OK:")
            for entry in refs_ok:
                suffix = " — bumped" if entry.get("bumped") else ""
                print(f"  {entry['file']}{suffix}")

    return 1 if write_failure else 0


if __name__ == "__main__":
    sys.exit(main())

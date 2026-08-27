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
     `/Users/testuser/Projects/personal/my-app`. The encoding is lossy in
     two ways: the final path component may itself contain a literal
     hyphen, AND the encoding also flattens '_' and '.' to '-' (e.g.
     `data_set` -> `data-set`, `report_v2.0` ->
     `report-v2-0`). decode_project_dir() first tries progressively
     coarser pure-hyphen suffix merges (as before), then — only if none of
     those resolved — retries the trailing components with their internal
     separators varied across '-'/'_'/'.', bounded to the last 4 segments so
     it stays a small, explicitly capped search rather than a combinatorial
     one. First candidate that is an actual directory on disk wins. If
     nothing in either pass produces a real directory (e.g. the project was
     deleted, or its name needs a wider search than this bound covers), this
     root is skipped entirely and refs relying on it stay REF-BROKEN — this
     is usually a true positive (the project really is gone) but, unlike
     before this change, is no longer guaranteed to be one: a bounded search
     can still miss a project dir whose encoding this doesn't try.
     Tried as <project>/<ref> and <project>/scripts/<basename>.
  4. ~/.claude/<ref> and ~/.claude/scripts/<basename>
  5. the `claude/` prefix: memories write refs like
     `claude/resume-prompts/2026-06-24-foo.md` meaning `~/.claude/resume-
     prompts/2026-06-24-foo.md` — a bare join at root 4 doubles the segment
     (`~/.claude/claude/...`) and never hits. When a relative ref's first
     path segment is exactly `claude`, this also tries
     `~/.claude/<ref with the leading "claude/" stripped>`, labeled
     distinctly so the report shows which rule resolved it.
  6. cwd: <cwd>/<ref> and <cwd>/scripts/<basename> (today's original
     behaviour, kept last among the direct-join roots)
  7. LAST RESORT — project-git-suffix: after every root above misses,
     resolve against the project's git-tracked file list (`git -C
     <project_root> ls-files`, project_root = the decoded root from step 3,
     falling back to cwd when that decode failed). A candidate matches if
     its repo-relative path equals the ref or ends with "/<ref>" — this is
     what resolves memories that cite `run.sh` for `tests/run.sh` or
     `planner.md` for `agents/core/planner.md`. Exactly one match resolves
     the ref; git failing (not a repo, git missing) skips this root
     entirely and falls through to REF-BROKEN; MORE THAN ONE match is
     reported as `ambiguous` (not resolved, not silently picked) — the ref
     stays counted as broken with the candidate list shown, because a
     basename satisfied by the wrong file is a worse failure than a false
     positive.

Ephemeral session-artifact refs: 33 (as of 2026-08-19) of the refs this
script would otherwise call REF-BROKEN point at `claude/plans/…`,
`claude/reports/…`, `claude/resume-prompts/…`, or `claude/research/…` —
ephemeral session artifacts destroyed by the 2026-06-02 and 2026-06-11
`~/.claude` wipes. A memory citing one of these correctly recorded a
pointer to something that later ceased to exist; the memory itself is not
stale, and the ref can never resolve again. is_ephemeral_session_ref()
recognizes this shape (a `claude/`-prefixed ref whose remainder starts with
plans/, reports/, resume-prompts/, or research/) but ONLY consults it for a
ref that has already failed every resolution root above — a ref of this
shape that DOES resolve is reported as a normal resolved ref, never routed
into the ephemeral bucket.

Retired project refs (CAST v10 J-4, 2026-08-26): most REF-BROKEN findings
in the real corpus turned out to be memories correctly citing a script that
was deliberately DELETED from the same project's own git history — not a
stale or wrong memory, just an accurate pointer to something that no longer
exists. That is the identical argument the ephemeral-session-artifact case
above already makes, applied to a real project file instead of a
~/.claude/ session artifact. get_retired_info() checks this ONLY for a ref
that has already failed every resolution root above (direct-join roots,
the project-git-suffix fallback, AND the ephemeral-session-artifact check):
it runs `git -C <project_root> log --all --diff-filter=D --format='%h %ad'
--date=short -1 -- ':(glob)**/<basename>'` against the ref's OWN decoded
project root (never os.getcwd() — a cwd-anchored git history would be the
WRONG repo's history for any memory whose project differs from the
invoking cwd; this is the same cwd-anchoring bug class fixed in
gen-completions.sh). A non-empty result means a file with that basename
was deleted at some point in that project's history; the deleting commit
and date are reported so a RETIRED claim is auditable by hand, not a bare
assertion — strong evidence the ref is the same file, but not proof.
Results are cached per (project_root, basename) within a run
(_RETIRED_CACHE) — one `git log` per otherwise-unresolvable basename, not
per ref occurrence, mirroring the bound discipline get_git_tracked_files()
already applies. Fails CLOSED: a ref stays REF-BROKEN (never guessed
retired) if project_root is None (undecodable project), git is
unavailable, the subprocess errors, or it times out (10s bound, same as
get_git_tracked_files()). Like ephemeral refs, a ref of this shape that
actually resolves under an earlier root is a normal resolved ref, never
routed through this check.

Bare-extension extraction artifacts: cast_memory_verifier's path regex
occasionally extracts a fragment like "init/.sh/.py" from prose such as
"schema_migrations shape unified across init/.sh/.py" (shorthand for two
files, not a real path) — its final path segment (".py") is a bare
extension with no filename stem, which can never be a real file.
_is_bare_extension_ref() drops exactly this shape before classification.
It deliberately does NOT try to filter placeholder stems like "X.bats" (a
single-letter filename is a legal real filename; guessing at
placeholder-ness there would suppress genuinely broken refs) — that shape
stays reported.

A file classifies as:
  REF-BROKEN     — at least one extracted path could not be resolved under
                   any root above (or matched more than one git-tracked
                   file — ambiguous), and is not excused as an
                   ephemeral-session-artifact ref or a RETIRED ref. This
                   measures "could not be resolved" — it is NOT proof the
                   memory's underlying claim is wrong, only that a human
                   should read it to confirm. NEVER auto-bumped.
  REFS-OK        — every extracted path resolved under some root. Bump-
                   eligible under --apply.
  RETIRED        — every extracted path either resolved OR names a file
                   deliberately deleted from the memory's OWN project git
                   history (get_retired_info()); no genuinely missing, no
                   ambiguous, and no ephemeral refs. NOT a failure — see
                   "Retired project refs" above. Reported separately from
                   REF-BROKEN and REFS-OK, and NEVER auto-bumped for the
                   same reason as EPHEMERAL-ONLY: a refs-resolved bump
                   would claim evidence for a ref that was excused, not
                   resolved.
  EPHEMERAL-ONLY — every extracted path either resolved OR is an
                   unresolvable ephemeral-session-artifact ref; no
                   genuinely missing, no ambiguous, and no retired refs.
                   NOT a failure. Reported separately from REF-BROKEN
                   (these are known-dead pointers, not evidence of rot)
                   but deliberately NOT folded into REFS-OK either and
                   NEVER auto-bumped: a refs-resolved bump would claim
                   evidence for refs that were, in fact, never resolved —
                   just excused. See the `verified_by` rationale below for
                   why that distinction matters.
  NO-REFS        — zero paths were extracted at all (after discarding
                   bare-extension extraction artifacts — see above). A
                   refs-resolved bump would be a verification claim backed
                   by zero evidence, so this is its own class and is NEVER
                   auto-bumped either.

Precedence when a file's unresolved refs mix ephemeral and retired shapes
(no missing, no ambiguous): RETIRED wins. This is an implementation choice,
not an observed real-corpus case as of 2026-08-26 — the two shapes don't
overlap in practice (ephemeral refs point under ~/.claude/, retired refs
point at project-tracked files) but a basename collision is possible.

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
import itertools
import json
import os
import subprocess
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
    "5) ~/.claude/<ref with leading 'claude/' segment stripped> "
    "(claude/-prefix refs)",
    "6) cwd/<ref>, cwd/scripts/<basename>",
    "7) LAST RESORT: project's git-tracked files, exact or path-suffix match "
    "(git -C <project_root> ls-files; ambiguous multi-hit stays REF-BROKEN)",
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

    The encoding (cwd with '/' replaced by '-') is lossy in TWO ways:
      (a) a path component itself contains a literal hyphen (e.g. "my-app"),
          so a hyphen may be a real '/' or may be internal to one segment;
      (b) the encoding ALSO flattens '_' and '.' to '-' (e.g. "data_set"
          -> "data-set", "report_v2.0" -> "report-v2-0"), so a
          hyphen in the trailing component(s) may stand for '/', '_', or '.'.

    Pass 1 (unchanged): tries progressively coarser suffix merges —
    starting from the fully-split candidate, then merging the last 2
    segments into one hyphenated component, then the last 3, etc. — first
    real directory wins.

    Pass 2 (additional): if no pure-hyphen merge resolved, retries only the
    TRAILING segments (bounded to the last `min(len(segments), 4)`) with
    their internal separators varied across {'-', '_', '.'} — e.g. for a
    3-segment trailing group this tries at most 3**2 = 8 additional
    combinations, not 3**(total hyphens). The prefix segments before the
    trailing group are never varied and the search never walks the
    filesystem — it only calls os.path.isdir() on constructed candidates,
    capped by this bound. First real directory wins, exactly as pass 1.

    Returns None if `encoded` isn't in the expected leading-hyphen form, or
    if nothing in either pass produces an existing directory (e.g. the
    project has since been deleted, or a longer/deeper name than this
    bounded search covers) — callers must treat that as "this root is
    unavailable," not crash. A None here is NOT proof the project was
    deleted; it only means this bounded decode didn't find it.
    """
    if not encoded.startswith("-"):
        return None
    segments = encoded.split("-")[1:]
    if not segments:
        return None

    # Pass 1: pure hyphen-merge (original behavior, unchanged).
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

    # Pass 2: trailing-only, bounded separator variants covering '_' and '.'
    # flattening. merge_size caps at 4 trailing segments (<=3 internal
    # separators, <=26 extra candidates per merge_size) so this stays a
    # small bounded search, never a combinatorial explosion over the whole
    # path.
    max_merge = min(len(segments), 4)
    for merge_size in range(2, max_merge + 1):
        prefix_segments = segments[:-merge_size]
        trailing = segments[-merge_size:]
        num_seps = merge_size - 1
        all_hyphens = tuple("-" * num_seps)
        for combo in itertools.product("-_.", repeat=num_seps):
            if combo == all_hyphens:
                continue  # already tried in pass 1
            merged = trailing[0]
            for sep, seg in zip(combo, trailing[1:]):
                merged += sep + seg
            candidate = "/" + "/".join(prefix_segments + [merged])
            if os.path.isdir(candidate):
                return candidate

    return None


def build_search_roots(
    memory_filepath: str,
) -> Tuple[List[Tuple[str, Optional[str]]], Optional[str]]:
    """Return (roots, project_root) for `memory_filepath`.

    `roots` is the ordered (label, root_dir) list used by resolve_ref();
    root_dir is None for the "as-given" step, which uses the ref literally
    (expanduser'd) rather than joining it to a root. `project_root` is the
    decoded project directory (or None if it couldn't be decoded) — returned
    separately so callers can also use it as the git-tracked-suffix fallback
    root (search-strategy step 7), which needs the raw directory rather than
    a joined candidate path.
    """
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
    roots.append(("home/.claude(claude-prefix)", os.path.join(home, ".claude")))
    roots.append(("cwd", cwd))
    roots.append(("cwd/scripts", os.path.join(cwd, "scripts")))
    return roots, project_root


def resolve_ref(
    ref: str, roots: List[Tuple[str, Optional[str]]]
) -> Optional[Tuple[str, str]]:
    """Resolve ref against the ordered roots; first hit wins. Returns
    (resolved_absolute_path, root_label), or None if no root has it.

    Does NOT include the project-git-suffix fallback (search-strategy step
    7) — that root needs the full tracked-file list and ambiguity handling,
    so it is applied separately by classify() after every root here misses.
    """
    expanded = os.path.expanduser(ref)
    is_abs = os.path.isabs(expanded)
    basename = os.path.basename(ref)
    ref_norm = ref.replace(os.sep, "/")
    claude_prefix_remainder: Optional[str] = None
    if not is_abs and "/" in ref_norm:
        head, remainder = ref_norm.split("/", 1)
        if head == "claude" and remainder:
            claude_prefix_remainder = remainder

    for label, root in roots:
        if label == "as-given":
            candidate = expanded
        elif is_abs:
            # An absolute ref is only meaningfully checked "as given" — a
            # rooted join would just collapse back to the same path.
            continue
        elif label.endswith("(claude-prefix)"):
            if claude_prefix_remainder is None:
                continue
            candidate = os.path.join(root, claude_prefix_remainder)
        elif label.endswith("/scripts"):
            candidate = os.path.join(root, basename)
        else:
            candidate = os.path.join(root, ref)

        if os.path.isfile(candidate):
            return os.path.abspath(candidate), label

    return None


# Per-project-root git-tracked-file-list cache. classify() runs once per
# stale memory file, and many memory files share a project root, so this
# avoids re-shelling out to `git ls-files` per file. Values are None for a
# root that is not a git repo (or where git failed) so that outcome is also
# cached rather than retried.
_GIT_TRACKED_FILES_CACHE: Dict[str, Optional[List[str]]] = {}


def get_git_tracked_files(project_root: str) -> Optional[List[str]]:
    """Return git-tracked, repo-relative file paths for `project_root`, or
    None if it isn't a git repo / git failed. Never raises — a git failure
    here means "this root is unavailable," the same contract as
    decode_project_dir() returning None."""
    if project_root in _GIT_TRACKED_FILES_CACHE:
        return _GIT_TRACKED_FILES_CACHE[project_root]

    files: Optional[List[str]]
    try:
        result = subprocess.run(
            ["git", "-C", project_root, "ls-files"],
            capture_output=True,
            text=True,
            timeout=10,
        )
        if result.returncode != 0:
            files = None
        else:
            files = [line for line in result.stdout.splitlines() if line]
    except (OSError, subprocess.SubprocessError):
        files = None

    _GIT_TRACKED_FILES_CACHE[project_root] = files
    return files


# Directories generated as a mirror of tracked repo content. A file here is a
# copy, not an independent source, so it must not create an ambiguity on its own.
_GENERATED_MIRROR_PREFIXES = ("plugin/",)


def resolve_git_suffix_ref(
    ref: str, project_root: Optional[str]
) -> Tuple[Optional[str], Optional[List[str]]]:
    """Last-resort resolution: match `ref` against project_root's
    git-tracked files by exact repo-relative path or by path suffix
    ("/<ref>"). Returns:
      (resolved_absolute_path, None)  — exactly one tracked file matched.
      (None, None)                    — no candidate matched (or
                                         project_root is unavailable / not a
                                         git repo — never crash, just fall
                                         through to REF-BROKEN).
      (None, candidates)              — MORE THAN ONE tracked file matched;
                                         the caller must treat this as
                                         unresolved/ambiguous, never pick one.
    Absolute refs are skipped — they're only meaningfully checked "as
    given," a suffix match against a repo-relative list can't apply.
    """
    if not project_root or os.path.isabs(ref):
        return None, None

    files = get_git_tracked_files(project_root)
    if not files:
        return None, None

    ref_norm = ref.replace(os.sep, "/")
    suffix = "/" + ref_norm
    matches = [f for f in files if f == ref_norm or f.endswith(suffix)]

    if len(matches) > 1:
        # Drop generated-mirror twins before calling it ambiguous. plugin/ is
        # regenerated from the repo by scripts/gen-plugin.sh, so EVERY bundled
        # file has a plugin/ copy and a ref naming one of them matches twice by
        # construction — "planner.md: ambiguous (2 candidates: agents/core/planner.md,
        # plugin/agents/planner.md)" is not a real ambiguity, it is the mirror.
        # Only collapse when the mirror is the ONLY thing creating the tie: if two
        # genuine sources remain (SKILL.md matches 37 files, half of them mirrors),
        # it stays ambiguous and stays reported, because picking one would be a
        # guess. Fails toward reporting, never toward silently choosing.
        non_mirror = [f for f in matches if not f.startswith(_GENERATED_MIRROR_PREFIXES)]
        if len(non_mirror) == 1:
            matches = non_mirror

    if len(matches) == 1:
        return os.path.abspath(os.path.join(project_root, matches[0])), None
    if len(matches) > 1:
        return None, sorted(matches)
    return None, None


# Ref path suffixes (after stripping a leading "claude/" segment) that name
# ephemeral session artifacts under ~/.claude/ — plans, reports, resume
# prompts, and research notes are all destroyed/rotated as a normal part of
# session lifecycle (concretely: the 2026-06-02 and 2026-06-11 ~/.claude
# wipes). A memory citing one of these correctly recorded a pointer to
# something that later ceased to exist; that is not the memory being stale,
# and the ref can never resolve again. See is_ephemeral_session_ref().
EPHEMERAL_SESSION_DIRS = ("plans/", "reports/", "resume-prompts/", "research/")


def is_ephemeral_session_ref(ref: str) -> bool:
    """True if `ref` uses the `claude/`-prefix convention (search-strategy
    step 5) AND names a path under one of EPHEMERAL_SESSION_DIRS. Only ever
    consulted for a ref that has ALREADY failed every resolution root
    (direct-join roots and the project-git-suffix fallback) — a ref of this
    shape that resolves is reported as a normal resolved ref, never routed
    through this check."""
    ref_norm = ref.replace(os.sep, "/")
    if not ref_norm.startswith("claude/"):
        return False
    remainder = ref_norm[len("claude/") :]
    return remainder.startswith(EPHEMERAL_SESSION_DIRS)


# A bare extension with no filename stem (the final path segment of an
# extraction artifact like "init/.sh/.py") can never be a real file. See the
# module docstring's "Bare-extension extraction artifacts" paragraph.
_BARE_EXTENSION_STEMS = (".sh", ".py", ".bats")


def _is_bare_extension_ref(ref: str) -> bool:
    """True if `ref`'s final path segment is exactly a bare extension
    (".sh", ".py", ".bats") with nothing before the dot but a path
    separator. Deliberately narrow — does NOT attempt to recognize
    placeholder stems like "X.bats"; a single-letter filename is a legal
    real filename and guessing at placeholder-ness there would suppress
    genuinely broken refs."""
    final_segment = ref.replace(os.sep, "/").rsplit("/", 1)[-1]
    return final_segment in _BARE_EXTENSION_STEMS


# Per-(project_root, basename) cache for get_retired_info(). Many memory
# files under the same project can cite the same retired basename (e.g.
# several files across a project all name "cast-migrate.sh"), and this runs
# a `git log` subprocess per otherwise-unresolvable ref — caching by
# basename within a run keeps that to one subprocess per (root, basename)
# pair, mirroring the bound discipline get_git_tracked_files() already
# applies for the project-git-suffix fallback and decode_project_dir()
# applies for its bounded trailing-segment search.
_RETIRED_CACHE: Dict[Tuple[str, str], Optional[Tuple[str, str]]] = {}


def get_retired_info(ref: str, project_root: Optional[str]) -> Optional[Tuple[str, str]]:
    """Return (deleting_commit, deleted_date) if a file with `ref`'s
    basename was deliberately deleted from `project_root`'s OWN git
    history, else None.

    Resolves against `project_root` ONLY — never os.getcwd() (see the
    module docstring's "Retired project refs" paragraph on why
    cwd-anchoring would check the wrong repo's history). Absolute refs are
    skipped, same rationale as resolve_git_suffix_ref(): an absolute path
    is only meaningfully checked "as given".

    Fails CLOSED, never raises: returns None (caller falls through to
    REF-BROKEN) if project_root is None, `ref` is absolute, git is
    unavailable, project_root is not a git work tree, the subprocess exits
    non-zero, or it times out (10s bound, same as get_git_tracked_files()).
    A None here is never proof the ref is genuinely missing — only that
    this check could not confirm retirement, so the conservative (fail
    closed) REF-BROKEN classification stands.
    """
    if not project_root or os.path.isabs(ref):
        return None

    basename = os.path.basename(ref.replace(os.sep, "/"))
    if not basename:
        return None

    cache_key = (project_root, basename)
    if cache_key in _RETIRED_CACHE:
        return _RETIRED_CACHE[cache_key]

    result: Optional[Tuple[str, str]] = None
    try:
        proc = subprocess.run(
            [
                "git",
                "-C",
                project_root,
                "log",
                "--all",
                "--diff-filter=D",
                "--format=%h %ad",
                "--date=short",
                "-1",
                "--",
                f":(glob)**/{basename}",
            ],
            capture_output=True,
            text=True,
            timeout=10,
        )
        if proc.returncode == 0:
            line = proc.stdout.strip()
            if line:
                parts = line.split(None, 1)
                if len(parts) == 2:
                    result = (parts[0], parts[1])
    except (OSError, subprocess.SubprocessError):
        result = None

    _RETIRED_CACHE[cache_key] = result
    return result


def classify(content: str, memory_filepath: str) -> Dict:
    """Classify content as REF-BROKEN / REFS-OK / RETIRED / EPHEMERAL-ONLY /
    NO-REFS, with per-ref detail. See the module docstring's "A file
    classifies as:" block for the full contract; summary:

    RETIRED: every ref either resolved OR names a file deliberately
    deleted from the memory's OWN project git history
    (get_retired_info()) — no genuinely missing, no ambiguous, and no
    ephemeral refs. NOT --apply-bump-eligible, same reasoning as
    EPHEMERAL-ONLY below.

    EPHEMERAL-ONLY: every ref either resolved OR is an unresolvable
    ephemeral-session-artifact ref (is_ephemeral_session_ref()) — no
    genuinely missing, no ambiguous, and no retired refs. Deliberately NOT
    the same as REFS-OK: bumping verified_at/verified_by would claim
    "refs-resolved" evidence for refs that were in fact never resolved,
    just excused as dead-artifact pointers. That is a weaker, different
    claim than what verified_by promises, so EPHEMERAL-ONLY (and RETIRED)
    are never --apply-bump-eligible (see the verified_by rationale in the
    module docstring) — the conservative choice when it's a close call
    between reusing REFS-OK and minting a new state.

    Precedence when a file mixes ephemeral AND retired unresolved refs
    (no missing, no ambiguous): RETIRED wins — see the module docstring.
    """
    paths, _functions = cast_memory_verifier.extract_paths_and_functions(content)
    # Drop bare-extension extraction artifacts (e.g. the final segment of
    # "init/.sh/.py") BEFORE the NO-REFS check, so a file whose only
    # "extracted path" was one of these correctly falls through to NO-REFS
    # rather than being reported as REF-BROKEN over a fragment that was
    # never a real path. See _is_bare_extension_ref().
    paths = [p for p in paths if not _is_bare_extension_ref(p)]
    if not paths:
        return {
            "status": "NO-REFS",
            "missing_refs": [],
            "ambiguous_refs": [],
            "ephemeral_refs": [],
            "retired_refs": [],
            "resolved_refs": [],
        }

    roots, project_root = build_search_roots(memory_filepath)
    # search-strategy step 7's fallback root: the decoded project root when
    # available, else cwd (so the fallback still applies when a memory's
    # project dir couldn't be decoded but its refs are cwd-relative repo
    # paths — the common case when running this script from within a repo).
    git_root = project_root or os.getcwd()

    missing: List[str] = []
    ambiguous: List[Dict] = []
    ephemeral: List[str] = []
    retired: List[Dict] = []
    resolved: List[Dict] = []
    for ref in sorted(set(paths)):
        hit = resolve_ref(ref, roots)
        if hit is not None:
            resolved_path, root_label = hit
            resolved.append({"ref": ref, "resolved_path": resolved_path, "root": root_label})
            continue

        git_path, candidates = resolve_git_suffix_ref(ref, git_root)
        if git_path is not None:
            resolved.append({"ref": ref, "resolved_path": git_path, "root": "project-git-suffix"})
        elif candidates:
            ambiguous.append({"ref": ref, "candidates": candidates})
        elif is_ephemeral_session_ref(ref):
            ephemeral.append(ref)
        else:
            # RETIRED resolves against the memory's OWN decoded project
            # root ONLY — never git_root's cwd fallback (see
            # get_retired_info()'s docstring and the module docstring's
            # "Retired project refs" paragraph).
            retired_info = get_retired_info(ref, project_root)
            if retired_info is not None:
                commit_hash, deleted_date = retired_info
                retired.append({"ref": ref, "commit": commit_hash, "date": deleted_date})
            else:
                missing.append(ref)

    if missing or ambiguous:
        status = "REF-BROKEN"
    elif retired:
        status = "RETIRED"
    elif ephemeral:
        status = "EPHEMERAL-ONLY"
    else:
        status = "REFS-OK"

    return {
        "status": status,
        "missing_refs": sorted(missing),
        "ambiguous_refs": ambiguous,
        "ephemeral_refs": sorted(ephemeral),
        "retired_refs": sorted(retired, key=lambda r: r["ref"]),
        "resolved_refs": resolved,
    }


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
    ephemeral_only: List[Dict] = []
    retired_only: List[Dict] = []
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
                    "ambiguous_refs": result.get("ambiguous_refs", []),
                    "ephemeral_refs": result.get("ephemeral_refs", []),
                    "resolved_refs": result["resolved_refs"],
                }
            )
            continue

        if status == "NO-REFS":
            no_refs.append({"file": filepath})
            continue

        if status == "EPHEMERAL-ONLY":
            # Not bump-eligible — see classify()'s docstring for why this is
            # a distinct state rather than reusing REFS-OK.
            ephemeral_only.append(
                {
                    "file": filepath,
                    "ephemeral_refs": result["ephemeral_refs"],
                    "resolved_refs": result["resolved_refs"],
                }
            )
            continue

        if status == "RETIRED":
            # Not bump-eligible — same reasoning as EPHEMERAL-ONLY above,
            # see classify()'s docstring.
            retired_only.append(
                {
                    "file": filepath,
                    "retired_refs": result["retired_refs"],
                    "resolved_refs": result["resolved_refs"],
                }
            )
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
            "ephemeral_only": ephemeral_only,
            "retired": retired_only,
            "applied": args.apply,
        }
        print(json.dumps(payload, indent=2))
    else:
        print("Search roots (first hit wins):")
        for line in SEARCH_STRATEGY:
            print(f"  {line}")
        print(
            f"{len(candidates)} stale memories evaluated "
            f"({len(ref_broken)} REF-BROKEN, {len(refs_ok)} REFS-OK, "
            f"{len(no_refs)} NO-REFS, {len(ephemeral_only)} EPHEMERAL-ONLY, "
            f"{len(retired_only)} RETIRED)"
        )
        if ref_broken:
            # "REF-BROKEN" measures "could not be resolved" — it is NOT
            # proof the memory's underlying claim is wrong (see the module
            # docstring). RETIRED and EPHEMERAL-ONLY below are the excused
            # counterpart of this same "could not resolve" measurement.
            print(
                "REF-BROKEN (a cited ref could not be resolved under any "
                "known root — evidence a human should read the memory, not "
                "evidence the memory is wrong):"
            )
            for entry in ref_broken:
                for ref in entry["missing_refs"]:
                    print(f"  {entry['file']} — missing ref: {ref}")
                for amb in entry.get("ambiguous_refs", []):
                    candidates_str = ", ".join(amb["candidates"])
                    print(
                        f"  {entry['file']} — {amb['ref']}: "
                        f"ambiguous ({len(amb['candidates'])} candidates: {candidates_str})"
                    )
                for eph in entry.get("ephemeral_refs", []):
                    print(
                        f"  {entry['file']} — ephemeral ref (dead session "
                        f"artifact, does not count toward REF-BROKEN on its "
                        f"own): {eph}"
                    )
        if no_refs:
            print("NO-REFS (not bump-eligible — no evidence to verify):")
            for entry in no_refs:
                print(f"  {entry['file']}")
        if ephemeral_only:
            print(
                "EPHEMERAL-ONLY (NOT a failure — not bump-eligible because "
                "unresolvable refs are dead session artifacts under "
                "plans/reports/resume-prompts/research, not stale code refs):"
            )
            for entry in ephemeral_only:
                for eph in entry["ephemeral_refs"]:
                    print(f"  {entry['file']} — ephemeral ref: {eph}")
        if retired_only:
            print(
                "RETIRED (NOT a failure — not bump-eligible because the ref "
                "named a real file deliberately deleted from this project's "
                "own git history; the memory's citation is an accurate "
                "historical record, not evidence the memory is stale). "
                "Matching is by BASENAME, so this is strong evidence, NOT "
                "proof the deleted file is the one the memory meant — the "
                "commit and date below are printed so you can check by hand:"
            )
            for entry in retired_only:
                for r in entry["retired_refs"]:
                    print(
                        f"  {entry['file']} — retired ref: {r['ref']} "
                        f"(deleted {r['commit']} {r['date']})"
                    )
        if refs_ok:
            print("REFS-OK:")
            for entry in refs_ok:
                suffix = " — bumped" if entry.get("bumped") else ""
                print(f"  {entry['file']}{suffix}")

    return 1 if write_failure else 0


if __name__ == "__main__":
    sys.exit(main())

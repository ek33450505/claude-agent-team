#!/usr/bin/env python3
"""cast-resume-scaffold.py — deterministic floor for CAST resume prompts.

Auto-generates a "resume prompt" at session end so the next session starts
with verifiable ground-truth state. Every section — including the previously
manual §1/§4/§5 — is populated from the record at generation time: §1 from
this branch's own commits, §4 from DONE_WITH_CONCERNS runs in cast.db, §5
from the newest plan file's own NEXT ACTION line. A slot this script cannot
derive is omitted entirely rather than left as a ``{{...}}`` placeholder or
filled with a guess. It will (in a later unit) be invoked from the SessionEnd
hook, so it MUST be hook-safe. cast.db access is READ-ONLY — this script must
never write to cast.db.

Usage:
    python3 scripts/cast-resume-scaffold.py [--repo PATH] [--out-dir PATH]
                                            [--now ISO8601] [--dry-run]

Options:
    --repo PATH      Repo to summarize (default: cwd; normalized to git toplevel).
    --out-dir PATH   Output directory (default: ~/.claude/resume-prompts).
    --now ISO8601    Override the timestamp (deterministic tests).
    --dry-run        Render to stdout; write NO file.

Output file: <out-dir>/<YYYY-MM-DD>-<repo-slug>-auto.md (overwritten per day).

Exit codes:
    0  success — file written (or rendered in --dry-run), OR a hook-safe
       graceful degradation (not a git repo, git/gh unavailable, write error).
    2  argparse usage error (argparse default).

Hook-safe contract: exit 0 on every path except argparse errors; never raise;
problems are logged to stderr.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timezone
from typing import List, Optional


# ---------------------------------------------------------------------------
# Subprocess + git helpers
# ---------------------------------------------------------------------------

def _run(args: list[str], repo: str) -> Optional[str]:
    """Run a subprocess in *repo*; return stdout (right-stripped) or None on failure.

    Never raises. A timeout, missing binary, non-zero exit, or OS error all
    degrade to None so callers can skip the data gracefully.

    Only trailing whitespace is stripped — leading whitespace is preserved so
    that column-aligned output (notably ``git status --short``, whose first line
    for an unstaged-modified file begins with a space) parses correctly.
    """
    try:
        result = subprocess.run(
            args,
            cwd=repo,
            capture_output=True,
            text=True,
            timeout=10,
        )
    except (subprocess.TimeoutExpired, FileNotFoundError, OSError, ValueError):
        return None
    if result.returncode != 0:
        return None
    return result.stdout.rstrip()


def _parse_json_array(raw: str) -> Optional[list]:
    """Parse *raw* as a JSON array; return the list or None on any failure."""
    try:
        data = json.loads(raw)
    except (json.JSONDecodeError, ValueError):
        return None
    return data if isinstance(data, list) else None


def _resolve_repo(path: str) -> Optional[str]:
    """Normalize *path* to its git toplevel, or None if not a git repo."""
    return _run(["git", "rev-parse", "--show-toplevel"], path)


def _default_branch(repo: str) -> str:
    """Best-effort default branch: origin/HEAD symref, else 'main'."""
    ref = _run(["git", "symbolic-ref", "--short", "refs/remotes/origin/HEAD"], repo)
    if ref and ref.startswith("origin/"):
        return ref[len("origin/"):]
    return "main"


def _is_superseded(path: str) -> bool:
    """True if the plan's header declares itself SUPERSEDED (skip as a seed).

    Matches 'superseded' case-insensitively (the passive status marker) but NOT
    'supersedes' — the active verb the *current* plan uses to point at the old
    one. 'supersedes' does not contain the substring 'superseded' (…sede+s vs
    …sede+d), so a plain lowercase substring test discriminates correctly.
    """
    try:
        with open(path, "r", encoding="utf-8") as fh:
            head = "".join(fh.readline() for _ in range(10))
    except OSError:
        return False
    return "superseded" in head.lower()


def _newest_plan(repo: str) -> Optional[str]:
    """Return the basename of the newest non-superseded *.md under <repo>/plans, or None.

    Ranks candidates by mtime (newest first) and returns the first whose header
    does not self-declare SUPERSEDED; if every plan is superseded, falls back to
    the newest (a stale seed beats no seed).
    """
    plans_dir = os.path.join(repo, "plans")
    if not os.path.isdir(plans_dir):
        return None
    try:
        candidates = [
            os.path.join(plans_dir, name)
            for name in os.listdir(plans_dir)
            if name.endswith(".md")
            and os.path.isfile(os.path.join(plans_dir, name))
        ]
    except OSError:
        return None
    if not candidates:
        return None
    try:
        candidates.sort(key=os.path.getmtime, reverse=True)
    except OSError:
        return None
    for path in candidates:
        if not _is_superseded(path):
            return os.path.basename(path)
    # All plans self-declare superseded — a stale seed beats no seed.
    return os.path.basename(candidates[0])


def _branch_commits(repo: str, branch: str, default_branch: str) -> list[str]:
    """Commit subjects unique to *branch* since it diverged from *default_branch*.

    Falls back to the last 5 commits on HEAD when branch IS the default branch
    (nothing to diverge from), when merge-base can't be found (e.g. shallow
    clone, detached HEAD), or when the diverged range is empty (nothing new
    yet). Newest-relevant-first ordering: divergent history is reverse-chrono
    (oldest-first, matching how work actually happened); the fallback is
    already newest-first from plain `git log`.
    """
    if branch and branch != default_branch:
        merge_base = _run(["git", "merge-base", default_branch, branch], repo)
        if merge_base:
            log = _run(
                ["git", "log", "--reverse", "--format=%s", f"{merge_base}..HEAD"],
                repo,
            )
            if log:
                subjects = [line for line in log.splitlines() if line.strip()]
                if subjects:
                    return subjects
    log = _run(["git", "log", "--format=%s", "-5"], repo)
    return [line for line in log.splitlines() if line.strip()] if log else []


def _plan_next_action(repo: str, plan_name: str) -> Optional[str]:
    """Best-effort extraction of the next-action line from a plan file.

    Priority: (1) a line containing 'NEXT ACTION' (case-insensitive, label
    stripped), (2) the first '## ' heading following a 'DISPATCH SEQUENCE'-
    style heading, (3) None — caller falls back to the bare file pointer
    rather than fabricating a guess.
    """
    path = os.path.join(repo, "plans", plan_name)
    try:
        with open(path, "r", encoding="utf-8") as fh:
            lines = fh.readlines()
    except OSError:
        return None

    for line in lines:
        idx = line.lower().find("next action")
        if idx == -1:
            continue
        # Slice from the label itself, discarding any leading blockquote/
        # heading/decorative-glyph markup (">", "#", "▶", …) rather than
        # trying to enumerate every markup character that might precede it.
        text = line[idx:].strip()
        text = re.sub(r"(?i)^next action[:\-]*\s*", "", text).strip()
        # Strip markdown emphasis markers throughout, not just at the ends —
        # a truncated bold span (real example: "**...bypass** (see below") only
        # closes mid-sentence, so an edge-only strip leaves a stray "**".
        text = text.replace("**", "").replace("__", "").strip("*_ ").strip()
        if text:
            return text

    in_dispatch_sequence = False
    for line in lines:
        if re.match(r"^#{1,6}\s*.*dispatch sequence", line, re.IGNORECASE):
            in_dispatch_sequence = True
            continue
        if in_dispatch_sequence and line.strip().startswith("## "):
            heading = line.strip().lstrip("#").strip()
            if heading:
                return heading
    return None


# ---------------------------------------------------------------------------
# cast.db access — READ-ONLY. This script must never write to cast.db.
# ---------------------------------------------------------------------------

# agent_runs.status is NEVER the literal 'DONE_WITH_CONCERNS' — the writer
# (cast_subagent_stop.py:391, ctx.db_status) normalizes the DB column to only
# 'DONE' or 'BLOCKED'; the DONE_WITH_CONCERNS distinction lives ONLY inside the
# response text's own Status: line. Verified empirically against the live
# record (2026-08-18): 0 of 3149 agent_runs rows carry status='DONE_WITH_CONCERNS'
# literally. The correct filter is status='DONE' AND the response's Status:
# line reads DONE_WITH_CONCERNS — 301 confirmed matches that way, 206 (68%)
# with a parseable Concerns: block, ~1% cruft after per-line stripping.
#
# Reuses the exact anchored alternation cast_subagent_stop.py uses to read a
# Status: line (that file's _STATUS_RE) rather than inventing a new pattern —
# same DONE_WITH_CONCERNS-before-DONE ordering so alternation prefers the
# longer match.
_STATUS_LINE_RE = re.compile(
    r"[*_]{0,2}\s*Status:\s*[*_]{0,2}\s*"
    r"(DONE_WITH_CONCERNS|DONE|BLOCKED|NEEDS_CONTEXT|APPROVE|REQUEST_CHANGES)"
)
# Concerns block: from a Concern(s): label up to the next heading or Status:
# line. Same shape cast_subagent_stop.py's stage16_compressed_output already
# uses for this exact field (not a new pattern invented here).
_CONCERNS_BLOCK_RE = re.compile(
    r"Concerns?:(.*?)(?=\n#|\n##|\nStatus:|$)", re.DOTALL | re.IGNORECASE
)


def _load_db_query():
    """Best-effort loader for cast_db.db_query. Returns None if unimportable.

    None is the ONLY signal callers need to distinguish "DB unavailable" from
    "queried, found nothing" — db_query's own contract already collapses
    missing-DB / missing-table / locked-DB errors to [] (scripts/cast_db.py:154),
    which is exactly the degradation this hook-safe script wants for those cases.
    """
    try:
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        from cast_db import db_query  # type: ignore
        return db_query
    except Exception:
        return None


def _query_concerns(branch: str) -> Optional[List[str]]:
    """Recent confirmed DONE_WITH_CONCERNS runs on *branch*, as bullet strings.

    Returns None if cast_db could not be imported at all (record fully
    unavailable). Returns [] if cast_db loaded but nothing matched — absent
    DB file, empty/missing table, or simply no concerns on this branch all
    legitimately collapse to [] via db_query's own try/except.
    """
    db_query = _load_db_query()
    if db_query is None:
        return None

    if branch and branch != "unknown":
        rows = db_query(
            "SELECT agent, response, ended_at FROM agent_runs "
            "WHERE status = 'DONE' AND response LIKE '%DONE_WITH_CONCERNS%' "
            "AND branch = ? ORDER BY id DESC LIMIT 30",
            (branch,),
        )
    else:
        rows = db_query(
            "SELECT agent, response, ended_at FROM agent_runs "
            "WHERE status = 'DONE' AND response LIKE '%DONE_WITH_CONCERNS%' "
            "ORDER BY id DESC LIMIT 30"
        )

    bullets: List[str] = []
    confirmed_rows = 0
    for row in rows:
        response = row["response"] or ""
        sm = _STATUS_LINE_RE.search(response)
        if not (sm and sm.group(1) == "DONE_WITH_CONCERNS"):
            # The LIKE above only proves the substring appears somewhere (e.g.
            # a mid-text mention); confirm against the real Status: line.
            continue
        confirmed_rows += 1
        cm = _CONCERNS_BLOCK_RE.search(response)
        if cm:
            agent = row["agent"] or "?"
            when = str(row["ended_at"] or "").split("T")[0] or "?"
            for line in cm.group(1).splitlines():
                line = line.strip().lstrip("-*").strip()
                if not line:
                    continue
                bullets.append(f"- **{agent}** ({when}): {line}")
                if len(bullets) >= 8:
                    break
        if len(bullets) >= 8 or confirmed_rows >= 5:
            break
    return bullets


def _prior_resume(out_dir: str, slug: str, target_name: str) -> str:
    """Display string for the newest prior *-<slug>-auto.md, or '(none)'.

    Excludes *target_name* so an idempotent same-day overwrite still points at
    the previous run rather than itself.
    """
    suffix = f"-{slug}-auto.md"
    try:
        files = [
            name
            for name in os.listdir(out_dir)
            if name.endswith(suffix) and name != target_name
        ]
    except OSError:
        return "(none)"
    if not files:
        return "(none)"
    files.sort()  # date-prefixed names sort chronologically
    return f"`{files[-1]}`"


# ---------------------------------------------------------------------------
# Section renderers — frontmatter + 8 body sections
# ---------------------------------------------------------------------------

def _frontmatter(now_iso: str, slug: str, branch: str, short_sha: str) -> str:
    return (
        "---\n"
        f"generated_at: {now_iso}\n"
        "origin: resume-scaffold\n"
        "inferred_by: cast-resume-scaffold.py\n"
        "kind: resume-auto\n"
        f"repo: {slug}\n"
        f"branch: {branch}\n"
        f"as_of_sha: {short_sha}\n"
        "---"
    )


def _title(date: str, slug: str, branch: str, head_subject: str) -> str:
    state = f"on `{branch}`"
    if head_subject:
        state += f", HEAD: {head_subject}"
    return (
        f"# Resume — {slug} auto: {state}\n"
        f"> Auto-scaffold, record-derived (§1/§4/§5 filled from git + cast.db "
        f"at generation time — verify before acting). "
        f"**Date:** {date} · **Home base:** {branch}"
    )


def _section1_tldr(repo: str, branch: str, default_branch: str,
                    newest_plan: Optional[str]) -> str:
    header = "## 1. TL;DR\n\n"
    commits = _branch_commits(repo, branch, default_branch)
    if not commits:
        return header + "_(no commits found on this branch — nothing to summarize)_"
    if len(commits) == 1:
        landed = commits[0]
    elif len(commits) == 2:
        landed = f"{commits[0]}; {commits[1]}"
    else:
        landed = f"{commits[0]}; {commits[1]}; and {len(commits) - 2} more"
    sentence = f"On `{branch}`, landed: {landed}."
    if newest_plan:
        sentence += f" Next is queued in `plans/{newest_plan}` (see §5)."
    else:
        sentence += " No open plan file found under `plans/` — see §3/§5."
    return header + sentence


def _section2_shipped(repo: str) -> str:
    lines = ["## 2. Shipped / merged (ground truth)", ""]
    merged_raw = _run(
        ["gh", "pr", "list", "--state", "merged", "--limit", "8",
         "--json", "number,title,mergedAt"],
        repo,
    )
    if merged_raw is None:
        lines.append("- _(gh unavailable — recent commits only)_")
    else:
        prs = _parse_json_array(merged_raw)
        if prs:
            for pr in prs:
                num = pr.get("number", "?")
                title = pr.get("title", "")
                merged_at = str(pr.get("mergedAt") or "").split("T")[0]
                lines.append(f"- **#{num} — {title}** — merged {merged_at}.")
        else:
            lines.append("- _(no merged PRs)_")

    commits = _run(["git", "log", "--oneline", "-12"], repo)
    if commits:
        lines.append("- Recent commits:")
        for line in commits.splitlines():
            lines.append(f"  - {line}")
    else:
        lines.append("- _(no commits)_")
    return "\n".join(lines)


def _section3_open(repo: str, default_branch: str) -> str:
    lines = ["## 3. In-flight / open", ""]

    open_raw = _run(
        ["gh", "pr", "list", "--state", "open", "--json", "number,title"], repo
    )
    if open_raw is None:
        lines.append("- _(gh unavailable)_")
    else:
        prs = _parse_json_array(open_raw)
        if prs:
            for pr in prs:
                num = pr.get("number", "?")
                title = pr.get("title", "")
                lines.append(f"- **#{num} — {title}** — OPEN.")
        else:
            lines.append("- _(no open PRs)_")

    branches = _run(
        ["git", "branch", "--no-merged", default_branch,
         "--format", "%(refname:short)"],
        repo,
    )
    if branches:
        names = ", ".join(branches.splitlines())
        lines.append(f"- Local branches not merged into {default_branch}: {names}")
    else:
        lines.append("- _(none)_")

    status = _run(["git", "status", "--short"], repo)
    if status:
        status_lines = status.splitlines()
        lines.append(f"- Uncommitted: {len(status_lines)} path(s)")
        for entry in status_lines[:8]:
            path = entry[3:].strip() if len(entry) > 3 else entry.strip()
            lines.append(f"  - {path}")
    else:
        lines.append("- _(clean tree)_")
    return "\n".join(lines)


def _section4_surfaced(branch: str) -> str:
    header = "## 4. Surfaced — NOT fixed (needs an OK before touching)\n\n"
    concerns = _query_concerns(branch)
    if concerns is None:
        return header + "- _(record unavailable — cast.db not readable from here)_"
    if not concerns:
        where = f" found on branch `{branch}`" if branch and branch != "unknown" else " found"
        return header + f"- _(no DONE_WITH_CONCERNS runs{where})_"
    return header + "\n".join(concerns)


def _section5_next(newest_plan: Optional[str], next_action: Optional[str]) -> str:
    header = "## 5. Next scope (ordered)\n\n"
    if not newest_plan:
        return header + "- _(no plan file found under `plans/` — nothing queued)_"
    action = next_action
    src = f" Source: `plans/{newest_plan}`."
    if action:
        return header + f"- **DO FIRST:** {action}.{src}"
    return header + (
        f"- **DO FIRST:** see `plans/{newest_plan}` "
        f"(no NEXT ACTION line found in the plan).{src}"
    )


def _section6_constraints() -> str:
    return (
        "## 6. Standing constraints / gotchas (carry forward)\n\n"
        "- Subagents at depth can't self-dispatch code-reviewer → orchestrator "
        "runs the review+security gate on each integrated diff.\n"
        "- Adding test/eval artifacts breaks hardcoded-count assertions → grep "
        "tests for counts before pushing.\n"
        "- BATS HARD RULE: isolated temp HOME / CAST_DB_PATH; PATH-shim "
        "GUI/notify surfaces.\n"
        "- Commit via `commit` agent; push via "
        "`CAST_PUSH_OK=1 bash scripts/cast-push.sh`. `cast-stats.json` "
        "auto-churn is expected."
    )


def _section7_kickoff(default_branch: str, newest_plan: Optional[str], slug: str,
                       next_action: Optional[str]) -> str:
    plan_ref = f"plans/{newest_plan}" if newest_plan else "plans/"
    if next_action:
        work_line = (
            f"WORK: Dispatch the next unit — {next_action} — name agent + "
            "files + mandatory code-reviewer gate."
        )
    else:
        work_line = (
            "WORK: Dispatch the next unit — no NEXT ACTION line found in the "
            "plan, check §5 — name agent + files + mandatory code-reviewer gate."
        )
    return (
        "## 7. KICKOFF BLOCK (paste this verbatim)\n\n"
        "```\n"
        f"Resume {slug}. Read {plan_ref} first.\n"
        "\n"
        "PRE-FLIGHT:\n"
        f"1. git checkout {default_branch} && git pull --ff-only; confirm "
        "clean tree; delete merged local branches.\n"
        "2. Confirm §3 open items are resolved.\n"
        "\n"
        f"{work_line}\n"
        "SHIP: commit agent → CAST_PUSH_OK=1 bash scripts/cast-push.sh → PR → "
        "watch CI.\n"
        "```"
    )


def _section8_pointers(
    newest_plan: Optional[str], prior_resume: str, branch: str
) -> str:
    plan_ref = f"`plans/{newest_plan}`" if newest_plan else "(none)"
    return (
        "## 8. Pointers\n\n"
        f"- Plan: {plan_ref} · Prior resume: {prior_resume} · Branch: {branch}"
    )


def _build_document(
    now_iso: str,
    date: str,
    slug: str,
    branch: str,
    short_sha: str,
    default_branch: str,
    newest_plan: Optional[str],
    prior_resume: str,
    repo: str,
) -> str:
    head_subject = _run(["git", "log", "-1", "--format=%s"], repo) or ""
    next_action = _plan_next_action(repo, newest_plan) if newest_plan else None
    blocks = [
        _frontmatter(now_iso, slug, branch, short_sha),
        _title(date, slug, branch, head_subject),
        _section1_tldr(repo, branch, default_branch, newest_plan),
        _section2_shipped(repo),
        _section3_open(repo, default_branch),
        _section4_surfaced(branch),
        _section5_next(newest_plan, next_action),
        _section6_constraints(),
        _section7_kickoff(default_branch, newest_plan, slug, next_action),
        _section8_pointers(newest_plan, prior_resume, branch),
    ]
    return "\n\n".join(blocks) + "\n"


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def _parse_args(argv: Optional[list[str]]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="cast-resume-scaffold.py",
        description="Deterministic floor for CAST resume prompts.",
    )
    parser.add_argument("--repo", default=os.getcwd(),
                        help="Repo to summarize (default: cwd).")
    parser.add_argument("--out-dir",
                        default=os.path.expanduser("~/.claude/resume-prompts"),
                        help="Output directory.")
    parser.add_argument("--now", default=None,
                        help="Override timestamp (ISO8601) for deterministic runs.")
    parser.add_argument("--dry-run", action="store_true",
                        help="Render to stdout; write no file.")
    return parser.parse_args(argv)


def _run_scaffold(args: argparse.Namespace) -> int:
    if args.now:
        now_iso = args.now
    else:
        now_iso = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    date = now_iso[:10]  # YYYY-MM-DD

    repo = _resolve_repo(args.repo)
    if repo is None:
        print(f"[resume-scaffold] not a git repo: {args.repo}", file=sys.stderr)
        return 0  # hook-safe

    slug = os.path.basename(repo)
    branch = _run(["git", "rev-parse", "--abbrev-ref", "HEAD"], repo) or "unknown"
    short_sha = _run(["git", "rev-parse", "--short", "HEAD"], repo) or "unknown"
    default_branch = _default_branch(repo)
    newest_plan = _newest_plan(repo)

    target_name = f"{date}-{slug}-auto.md"
    prior_resume = _prior_resume(args.out_dir, slug, target_name)

    document = _build_document(
        now_iso=now_iso,
        date=date,
        slug=slug,
        branch=branch,
        short_sha=short_sha,
        default_branch=default_branch,
        newest_plan=newest_plan,
        prior_resume=prior_resume,
        repo=repo,
    )

    if args.dry_run:
        print(document)
        return 0

    try:
        os.makedirs(args.out_dir, exist_ok=True)
        out_path = os.path.join(args.out_dir, target_name)
        with open(out_path, "w", encoding="utf-8") as handle:
            handle.write(document)
    except OSError as exc:
        print(f"[resume-scaffold] failed to write: {exc}", file=sys.stderr)
        return 0  # hook-safe
    print(out_path)
    return 0


def main(argv: Optional[list[str]] = None) -> int:
    args = _parse_args(argv)  # argparse errors exit 2 before the safety net
    try:
        return _run_scaffold(args)
    except Exception as exc:  # noqa: BLE001 — hook-safe: never raise
        print(f"[resume-scaffold] unexpected error: {exc}", file=sys.stderr)
        return 0


if __name__ == "__main__":
    sys.exit(main())

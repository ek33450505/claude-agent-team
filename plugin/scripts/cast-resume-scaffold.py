#!/usr/bin/env python3
"""cast-resume-scaffold.py — deterministic floor for CAST resume prompts.

Auto-generates a "resume prompt" at session end so the next session starts
with verifiable ground-truth state. This script fills the git/gh-derivable
sections of CAST's 7-section resume template and leaves the semantic sections
as ``{{...}}`` slots for later in-session enrichment. It will (in a later unit)
be invoked from the SessionEnd hook, so it MUST be hook-safe.

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
import subprocess
import sys
from datetime import datetime, timezone
from typing import Optional


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


def _title(date: str, branch: str) -> str:
    # {{project}} / {{one-line state}} stay literal slots; date + branch filled.
    return (
        "# Resume — {{project}} auto: {{one-line state}}\n"
        f"> Auto-scaffold (floor). Enrich §1/§4/§5 in-session. "
        f"**Date:** {date} · **Home base:** {branch}"
    )


def _section1_tldr() -> str:
    return (
        "## 1. TL;DR\n\n"
        "<!-- ENRICH IN-SESSION -->\n"
        "{{One or two sentences: what just finished, what's next.}}"
    )


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


def _section4_surfaced() -> str:
    return (
        "## 4. Surfaced — NOT fixed (needs an OK before touching)\n\n"
        "<!-- ENRICH IN-SESSION -->\n"
        "- {{file:line — what + why deferred}}"
    )


def _section5_next(newest_plan: Optional[str]) -> str:
    header = (
        "## 5. Next scope (ordered)\n\n"
        "<!-- ENRICH IN-SESSION. Seeded with newest plan file pointer. -->\n"
    )
    src = f" Source: `plans/{newest_plan}`." if newest_plan else ""
    # {{next work}} kept literal via plain concatenation (no f-string braces).
    return header + "- **DO FIRST:** {{next work}}." + src


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
        "auto-churn is expected.\n"
        "- {{project-specific gotchas discovered this session}}"
    )


def _section7_kickoff(default_branch: str, newest_plan: Optional[str]) -> str:
    plan_ref = f"plans/{newest_plan}" if newest_plan else "plans/"
    # {{...}} slots kept literal via plain concatenation.
    return (
        "## 7. KICKOFF BLOCK (paste this verbatim)\n\n"
        "```\n"
        "Resume {{project}}. Read " + plan_ref + " first.\n"
        "\n"
        "PRE-FLIGHT:\n"
        "1. git checkout " + default_branch + " && git pull --ff-only; confirm "
        "clean tree; delete merged local branches.\n"
        "2. {{confirm §3 open items resolved}}\n"
        "\n"
        "WORK: {{dispatch the next unit — name agent + files + mandatory "
        "code-reviewer gate}}.\n"
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
    blocks = [
        _frontmatter(now_iso, slug, branch, short_sha),
        _title(date, branch),
        _section1_tldr(),
        _section2_shipped(repo),
        _section3_open(repo, default_branch),
        _section4_surfaced(),
        _section5_next(newest_plan),
        _section6_constraints(),
        _section7_kickoff(default_branch, newest_plan),
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

#!/usr/bin/env python3
"""cast-plan-doctor — CI-gating tool that derives plan status from ground truth
(git + settings + filesystem) and reconciles a markdown Session Ledger table
against it, failing on contradiction. Mirrors cast-db-contract.py exactly.

Usage:
  cast-plan-doctor.py [--plan PATH] [--check] [--json] [--update-baseline]
                      [--baseline PATH] [--resume]

Exit codes: 0 = pass, 1 = new contradictions (--check) or fatal error.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path
from typing import Any

# ---------------------------------------------------------------------------
# Path constants (mirror cast-db-contract.py:45-52)
# ---------------------------------------------------------------------------
SCRIPT_DIR = Path(__file__).parent
REPO_ROOT = SCRIPT_DIR.parent
DEFAULT_BASELINE = REPO_ROOT / ".github" / "plan-doctor-baseline.json"
DEFAULT_PLAN = REPO_ROOT / "plans" / "cast-v9-foundation.md"
ACTIVE_PLAN_MARKER = Path.home() / ".claude" / "config" / "active-plan"

# Severity levels
CONTRADICTION = "CONTRADICTION"
WARN = "WARN"
INFO = "INFO"


# ---------------------------------------------------------------------------
# Types
# ---------------------------------------------------------------------------
def make_finding(
    key: str,
    severity: str,
    claim: str,
    expected: str = "",
    actual: str = "",
) -> dict[str, Any]:
    """Build a finding dict."""
    return {
        "key": key,
        "severity": severity,
        "claim": claim,
        "expected": expected,
        "actual": actual,
    }


# ---------------------------------------------------------------------------
# Ledger parser
# ---------------------------------------------------------------------------
_SEP_RE = re.compile(r"^\|[-| ]+\|$")


def parse_ledger(plan_text: str) -> list[dict[str, Any]]:
    """Parse the §11 Session Ledger table from plan markdown.

    Returns list of row dicts: {session, goal, units, phase, branch,
    status, status_raw}.
    """
    lines = plan_text.splitlines()
    # Locate header row
    header_idx = None
    for i, line in enumerate(lines):
        stripped = line.strip()
        if stripped.startswith("| S#") and "Goal" in stripped:
            header_idx = i
            break

    if header_idx is None:
        return []

    rows: list[dict[str, Any]] = []
    for line in lines[header_idx + 1 :]:
        stripped = line.strip()
        if not stripped.startswith("|"):
            break  # end of table
        if _SEP_RE.match(stripped):
            continue  # skip separator row

        cells = [c.strip() for c in stripped.split("|")]
        # Drop leading/trailing empty cells from outer pipes
        if cells and cells[0] == "":
            cells = cells[1:]
        if cells and cells[-1] == "":
            cells = cells[:-1]

        if len(cells) < 6:
            continue

        session = cells[0]
        goal = cells[1]
        units = cells[2]
        phase = cells[3]
        branch_raw = cells[4]
        status_raw = cells[5]

        # Extract branch (before " → ")
        branch = branch_raw.split(" → ")[0].strip()

        # Classify status
        if status_raw.startswith("✅"):
            status = "done"
        elif "NEXT" in status_raw:
            status = "next"
        elif "☐" in status_raw:
            status = "todo"
        else:
            status = "unknown"

        rows.append(
            {
                "session": session,  # kept as string — "7+" is valid
                "goal": goal,
                "units": units,
                "phase": phase,
                "branch": branch,
                "status": status,
                "status_raw": status_raw,
            }
        )

    return rows


# ---------------------------------------------------------------------------
# Probe 1 — ledger well-formed
# ---------------------------------------------------------------------------
def probe_ledger_wellformed(rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Check that the ledger is internally consistent."""
    findings: list[dict[str, Any]] = []

    if not rows:
        findings.append(
            make_finding(
                key="ledger:empty",
                severity=CONTRADICTION,
                claim="Ledger table must contain at least one session row",
                expected=">=1 rows",
                actual="0 rows",
            )
        )
        return findings

    # Exactly one 'next' row
    next_rows = [r for r in rows if r["status"] == "next"]
    if len(next_rows) != 1:
        findings.append(
            make_finding(
                key="ledger:next_count",
                severity=CONTRADICTION,
                claim="Exactly one session row must have status 'next'",
                expected="1",
                actual=str(len(next_rows)),
            )
        )
        # Cannot check order without a single next — return early
        return findings

    next_session = next_rows[0]["session"]
    next_idx = next((i for i, r in enumerate(rows) if r["session"] == next_session), -1)

    # All rows BEFORE next must be 'done'; all rows AFTER must be 'todo'
    for i, row in enumerate(rows):
        s = row["session"]
        status = row["status"]
        if i < next_idx:
            if status != "done":
                findings.append(
                    make_finding(
                        key=f"ledger:order:{s}",
                        severity=CONTRADICTION,
                        claim=f"Session {s} is before the NEXT session; must be 'done'",
                        expected="done",
                        actual=status,
                    )
                )
        elif i > next_idx:
            if status == "done":
                findings.append(
                    make_finding(
                        key=f"ledger:order:{s}",
                        severity=CONTRADICTION,
                        claim=f"Session {s} is after the NEXT session; must not be 'done'",
                        expected="todo or unknown",
                        actual=status,
                    )
                )

    return findings


# ---------------------------------------------------------------------------
# Probe 2 — branch reconcile
# ---------------------------------------------------------------------------
def _run_git(args: list[str], cwd: str, timeout: int = 5) -> tuple[bool, str]:
    """Run a git command. Returns (success, stdout)."""
    try:
        result = subprocess.run(
            ["git"] + args,
            cwd=cwd,
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
        )
        return result.returncode == 0, result.stdout.strip()
    except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
        return False, ""


def probe_branch_reconcile(
    rows: list[dict[str, Any]], git_root: Path
) -> list[dict[str, Any]]:
    """Reconcile branch existence against git state."""
    findings: list[dict[str, Any]] = []
    cwd = str(git_root)

    # Quick sanity check: is git available?
    ok, _ = _run_git(["--version"], cwd)
    if not ok:
        findings.append(
            make_finding(
                key="git:unavailable",
                severity=WARN,
                claim="git binary is not available; branch reconciliation skipped",
                expected="git available",
                actual="git not found",
            )
        )
        return findings

    # Gather all known branches (local + remote)
    _, refs_out = _run_git(
        ["for-each-ref", "--format=%(refname:short)", "refs/heads", "refs/remotes"],
        cwd,
    )
    known_refs: set[str] = set()
    for ref in refs_out.splitlines():
        ref = ref.strip()
        if ref:
            # Strip remote prefix (e.g. "origin/feature/x" -> "feature/x")
            known_refs.add(ref)
            if "/" in ref:
                known_refs.add(ref.split("/", 1)[1])

    # main ref is required for --merged/log reconciliation; without it (CI shallow
    # clone, fork with a different default) skip branch reconcile rather than emit
    # false CONTRADICTIONs.
    ok_main, _ = _run_git(["rev-parse", "--verify", "--quiet", "main"], cwd)
    if not ok_main:
        findings.append(make_finding(
            key="branch:main_not_found",
            severity=WARN,
            claim="main ref not found; branch reconciliation skipped",
            expected="main ref present",
            actual="main not found",
        ))
        return findings

    # Gather merged branches
    _, merged_out = _run_git(
        ["branch", "--merged", "main", "--format=%(refname:short)"],
        cwd,
    )
    merged_branches: set[str] = {b.strip() for b in merged_out.splitlines() if b.strip()}

    distinct_branches: dict[str, str] = {}  # branch -> representative status
    for row in rows:
        branch = row["branch"]
        if branch and branch not in distinct_branches:
            distinct_branches[branch] = row["status"]

    for branch, rep_status in distinct_branches.items():
        if not branch:
            continue

        exists = branch in known_refs
        if not exists:
            # Try rev-parse
            ok2, _ = _run_git(
                ["rev-parse", "--verify", "--quiet", branch], cwd, timeout=5
            )
            exists = ok2

        if rep_status == "done" and not exists and branch not in merged_branches:
            # Check git log for mentions as best-effort
            _, log_out = _run_git(
                ["log", "main", "--oneline", "-n", "200"], cwd, timeout=5
            )
            mentioned = bool(re.search(rf"\b{re.escape(branch)}\b", log_out))
            if not mentioned:
                findings.append(
                    make_finding(
                        key=f"branch_missing:{branch}",
                        severity=CONTRADICTION,
                        claim=f"Session marked 'done' but branch '{branch}' has no git evidence",
                        expected=f"branch '{branch}' exists or merged",
                        actual="branch not found in refs or git log",
                    )
                )
        elif rep_status in ("todo", "next") and not exists:
            findings.append(
                make_finding(
                    key=f"branch_future:{branch}",
                    severity=INFO,
                    claim=f"Branch '{branch}' does not exist yet (future work)",
                    expected="branch not required yet",
                    actual="branch absent",
                )
            )

    return findings


# ---------------------------------------------------------------------------
# Probe 3 — canonical plan
# ---------------------------------------------------------------------------
def probe_canonical_plan(
    plan_path: Path, git_root: Path
) -> list[dict[str, Any]]:
    """Check the plan file exists and is git-tracked."""
    findings: list[dict[str, Any]] = []
    cwd = str(git_root)

    if not plan_path.exists():
        findings.append(
            make_finding(
                key="plan:unparseable",
                severity=CONTRADICTION,
                claim=f"Plan file not found: {plan_path}",
                expected="file exists",
                actual="file missing",
            )
        )
        return findings

    try:
        text = plan_path.read_text(encoding="utf-8")
    except OSError as exc:
        findings.append(
            make_finding(
                key="plan:unparseable",
                severity=CONTRADICTION,
                claim=f"Plan file unreadable: {exc}",
                expected="readable file",
                actual=str(exc),
            )
        )
        return findings

    rows = parse_ledger(text)
    if not rows:
        findings.append(
            make_finding(
                key="plan:unparseable",
                severity=CONTRADICTION,
                claim="Plan file parsed to 0 ledger rows",
                expected=">=1 ledger rows",
                actual="0 rows",
            )
        )

    # Check git-tracked
    try:
        rel = plan_path.resolve().relative_to(git_root.resolve())
        ok, _ = _run_git(
            ["ls-files", "--error-unmatch", str(rel)], cwd, timeout=5
        )
        if not ok:
            # git check-ignore -q exits 0 when the path IS ignored.
            ignored, _ = _run_git(["check-ignore", "-q", str(rel)], cwd, timeout=5)
            if ignored:
                findings.append(
                    make_finding(
                        key="plan:local_only",
                        severity=INFO,
                        claim=f"Plan '{rel}' is intentionally local (gitignored); kept out of the public repo by design",
                        expected="local-first (data stays sovereign)",
                        actual="untracked + gitignored",
                    )
                )
            else:
                findings.append(
                    make_finding(
                        key="plan:untracked",
                        severity=WARN,
                        claim=f"Plan file '{rel}' is untracked and not gitignored",
                        expected="tracked, or intentionally gitignored",
                        actual="untracked",
                    )
                )
    except ValueError:
        # plan_path not under git_root — skip tracking check
        pass

    return findings


# ---------------------------------------------------------------------------
# Probe 4 — settings claims (extensible registry)
# ---------------------------------------------------------------------------
_OTEL_ON_BY_DEFAULT_RE = re.compile(r"OTEL.{0,40}on by default", re.IGNORECASE)


def _probe_otel_claim(plan_text: str) -> list[dict[str, Any]]:
    """Check OTEL on-by-default claim against actual plist + process."""
    findings: list[dict[str, Any]] = []

    plist_path = (
        Path.home()
        / "Library"
        / "LaunchAgents"
        / "com.cast.otel-collector.plist"
    )
    run_at_load = None
    if plist_path.exists():
        try:
            plist_text = plist_path.read_text(encoding="utf-8")
            lines = plist_text.splitlines()
            for i, line in enumerate(lines):
                if "<key>RunAtLoad</key>" in line:
                    # Next line should be <true/> or <false/>
                    if i + 1 < len(lines):
                        next_line = lines[i + 1].strip()
                        if "<true/>" in next_line:
                            run_at_load = True
                        elif "<false/>" in next_line:
                            run_at_load = False
                    break
        except OSError:
            pass

    try:
        pgrep = subprocess.run(
            ["pgrep", "-f", "cast-otel-collector.py"],
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
        )
        otel_running = pgrep.returncode == 0
    except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
        otel_running = False

    actual_on_by_default = run_at_load is True or otel_running
    if not actual_on_by_default:
        findings.append(
            make_finding(
                key="settings:otel_default",
                severity=CONTRADICTION,
                claim="Plan asserts OTEL is 'on by default'",
                expected="RunAtLoad=true or cast-otel-collector.py running",
                actual=f"RunAtLoad={run_at_load}, process_running={otel_running}",
            )
        )
    return findings


# Registry: list of (regex, probe_fn) pairs
_SETTINGS_CLAIMS: list[tuple[re.Pattern[str], Any]] = [
    (_OTEL_ON_BY_DEFAULT_RE, _probe_otel_claim),
]


def probe_settings_claims(plan_text: str) -> list[dict[str, Any]]:
    """Extensible prose-claim reconciler."""
    findings: list[dict[str, Any]] = []
    for pattern, probe_fn in _SETTINGS_CLAIMS:
        if pattern.search(plan_text):
            findings.extend(probe_fn(plan_text))
    return findings


# ---------------------------------------------------------------------------
# Baseline ratchet helpers
# ---------------------------------------------------------------------------
def load_baseline(baseline_path: Path) -> list[str]:
    """Load accepted contradiction keys from baseline JSON."""
    if not baseline_path.exists():
        return []
    try:
        data = json.loads(baseline_path.read_text(encoding="utf-8"))
        return data.get("accepted", [])
    except (json.JSONDecodeError, OSError):
        return []


def save_baseline(baseline_path: Path, keys: list[str]) -> None:
    """Write contradiction keys to baseline JSON."""
    baseline_path.parent.mkdir(parents=True, exist_ok=True)
    baseline_path.write_text(
        json.dumps({"accepted": sorted(keys)}, indent=2) + "\n",
        encoding="utf-8",
    )


# ---------------------------------------------------------------------------
# Git root resolution
# ---------------------------------------------------------------------------
def resolve_git_root(plan_path: Path) -> Path:
    """Compute the git root from the plan path; fallback to REPO_ROOT."""
    # plans/cast-v9-foundation.md  ->  parent.parent = repo root
    candidate = plan_path.resolve().parent.parent
    if (candidate / ".git").exists():
        return candidate
    return REPO_ROOT


# ---------------------------------------------------------------------------
# Run all probes
# ---------------------------------------------------------------------------
def run_all_probes(
    plan_path: Path, plan_text: str, rows: list[dict[str, Any]], git_root: Path
) -> list[dict[str, Any]]:
    findings: list[dict[str, Any]] = []
    findings.extend(probe_ledger_wellformed(rows))
    findings.extend(probe_branch_reconcile(rows, git_root))
    findings.extend(probe_canonical_plan(plan_path, git_root))
    findings.extend(probe_settings_claims(plan_text))
    return findings


# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
def _status_table(rows: list[dict[str, Any]], findings: list[dict[str, Any]]) -> str:
    """Build a human-readable status table."""
    lines: list[str] = []
    lines.append("cast plan-doctor — Session Ledger Status")
    lines.append("=" * 60)
    lines.append(f"{'S#':<6} {'Status':<10} {'Branch':<40} {'Goal'}")
    lines.append("-" * 80)
    for row in rows:
        marker = {
            "done": "✅",
            "next": "▶",
            "todo": "☐",
            "unknown": "?",
        }.get(row["status"], "?")
        lines.append(
            f"{row['session']:<6} {marker + ' ' + row['status']:<10} "
            f"{row['branch'][:38]:<40} {row['goal'][:40]}"
        )

    if findings:
        lines.append("")
        lines.append("Findings:")
        for f in findings:
            lines.append(
                f"  [{f['severity']}] {f['key']} — {f['claim']}"
            )
            if f.get("expected") or f.get("actual"):
                lines.append(f"    expected: {f['expected']}  actual: {f['actual']}")
    else:
        lines.append("")
        lines.append("No findings.")

    return "\n".join(lines)


def _extract_carry_forwards(plan_text: str) -> list[str]:
    """Extract carry-forward bullets from plan; cap at 6."""
    bullets: list[str] = []
    lines = plan_text.splitlines()
    in_cf = False
    for line in lines:
        stripped = line.strip()
        if re.search(r"carry.forward", stripped, re.IGNORECASE):
            in_cf = True
            continue
        if in_cf:
            if not stripped:
                break  # blank line = end of block
            if re.match(r"^#{1,6}\s|^\*\*", stripped):
                break  # next heading
            if stripped.startswith("-") or stripped.startswith("*"):
                bullets.append(stripped.lstrip("-* ").strip())
                if len(bullets) >= 6:
                    break
    return bullets


def _build_resume_briefing(
    plan_path: Path,
    rows: list[dict[str, Any]],
    plan_text: str,
    findings: list[dict[str, Any]],
) -> str:
    """Build the compact ▶ YOU ARE HERE markdown briefing."""
    next_rows = [r for r in rows if r["status"] == "next"]
    if not next_rows:
        return ""

    nxt = next_rows[0]
    carry = _extract_carry_forwards(plan_text)

    parts: list[str] = [
        f"▶ YOU ARE HERE — Session {nxt['session']}: {nxt['goal']}",
        f"Units: {nxt['units']}",
        f"Branch: {nxt['branch']} · Phase: {nxt['phase']}",
    ]

    if carry:
        parts.append("Carry-forwards:")
        for b in carry:
            parts.append(f"- {b}")

    parts.append(f"Canonical plan: {plan_path}")

    contradictions = [f for f in findings if f["severity"] == CONTRADICTION]
    if contradictions:
        keys = ", ".join(f["key"] for f in contradictions)
        parts.append(f"⚠ Reconcile: {len(contradictions)} contradiction(s): {keys}")

    return "\n".join(parts)


# ---------------------------------------------------------------------------
# Mode handlers
# ---------------------------------------------------------------------------
def mode_check(
    plan_path: Path,
    plan_text: str,
    rows: list[dict[str, Any]],
    git_root: Path,
    baseline_path: Path,
) -> int:
    """--check mode: CI ratchet. Returns exit code."""
    findings = run_all_probes(plan_path, plan_text, rows, git_root)
    contradictions = [f for f in findings if f["severity"] == CONTRADICTION]
    accepted = load_baseline(baseline_path)

    new_contradictions = [f for f in contradictions if f["key"] not in accepted]

    print(
        f"[CHECK] {len(contradictions)} contradiction(s) found, "
        f"{len(new_contradictions)} new (not in baseline).",
        file=sys.stderr,
    )
    for f in new_contradictions:
        print(
            f"[FAIL] CONTRADICTION: {f['key']} — {f['claim']} "
            f"(expected {f['expected']}, actual {f['actual']})",
            file=sys.stderr,
        )

    if new_contradictions:
        print(
            "Run --update-baseline to accept these contradictions.",
            file=sys.stderr,
        )
        return 1

    print("[PASS] No new plan-doctor contradictions vs baseline.", file=sys.stderr)
    return 0


def mode_json(
    plan_path: Path,
    plan_text: str,
    rows: list[dict[str, Any]],
    git_root: Path,
) -> int:
    """--json mode: emit manifest to stdout. Returns exit code."""
    findings = run_all_probes(plan_path, plan_text, rows, git_root)
    manifest = {
        "plan_path": str(plan_path),
        "ledger": rows,
        "findings": findings,
        "summary": {
            "rows": len(rows),
            "contradictions": sum(
                1 for f in findings if f["severity"] == CONTRADICTION
            ),
            "warnings": sum(1 for f in findings if f["severity"] == WARN),
            "info": sum(1 for f in findings if f["severity"] == INFO),
        },
    }
    print(json.dumps(manifest, indent=2))
    return 0


def mode_update_baseline(
    plan_path: Path,
    plan_text: str,
    rows: list[dict[str, Any]],
    git_root: Path,
    baseline_path: Path,
) -> int:
    """--update-baseline mode: write current contradiction keys to baseline."""
    findings = run_all_probes(plan_path, plan_text, rows, git_root)
    contradiction_keys = [f["key"] for f in findings if f["severity"] == CONTRADICTION]
    save_baseline(baseline_path, contradiction_keys)
    print(
        f"Baseline updated: {len(contradiction_keys)} key(s) written to {baseline_path}"
    )
    return 0


def mode_resume(
    plan_path: Path,
    plan_text: str,
    rows: list[dict[str, Any]],
    git_root: Path,
) -> int:
    """--resume mode: emit compact YOU ARE HERE briefing. Always exits 0."""
    wf_findings = probe_ledger_wellformed(rows)
    br_findings = probe_branch_reconcile(rows, git_root)
    cp_findings = probe_canonical_plan(plan_path, git_root)
    findings = wf_findings + br_findings + cp_findings

    briefing = _build_resume_briefing(plan_path, rows, plan_text, findings)
    if briefing:
        print(briefing)
    return 0


def mode_default(
    plan_path: Path,
    plan_text: str,
    rows: list[dict[str, Any]],
    git_root: Path,
) -> int:
    """Default mode: human-readable status table."""
    findings = run_all_probes(plan_path, plan_text, rows, git_root)
    print(_status_table(rows, findings))
    return 0


# ---------------------------------------------------------------------------
# Argument parser
# ---------------------------------------------------------------------------
def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        description="Reconcile the plan Session Ledger against git/settings ground truth.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument(
        "--plan",
        metavar="PATH",
        type=Path,
        default=DEFAULT_PLAN,
        help=f"Plan file to analyze (default: {DEFAULT_PLAN})",
    )
    p.add_argument(
        "--baseline",
        metavar="PATH",
        type=Path,
        default=DEFAULT_BASELINE,
        help=f"Baseline file for --check ratchet (default: {DEFAULT_BASELINE})",
    )
    p.add_argument(
        "--check",
        action="store_true",
        help="CI ratchet: exit 1 if any new contradictions not in baseline",
    )
    p.add_argument(
        "--json",
        action="store_true",
        help="Emit a JSON manifest (parsed ledger + probe results) to stdout",
    )
    p.add_argument(
        "--update-baseline",
        action="store_true",
        help="Write current contradiction keys to the baseline file",
    )
    p.add_argument(
        "--resume",
        action="store_true",
        help="Emit a compact YOU ARE HERE briefing (for SessionStart hooks)",
    )
    return p


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main() -> int:
    parser = build_parser()
    args = parser.parse_args()

    # --resume: special plan resolution (ACTIVE_PLAN_MARKER takes precedence
    # unless --plan was explicitly given by the user)
    plan_path: Path = args.plan
    if args.resume and args.plan == DEFAULT_PLAN:
        # Only use the marker if --plan was not explicitly provided
        if ACTIVE_PLAN_MARKER.exists():
            try:
                marker_content = ACTIVE_PLAN_MARKER.read_text(encoding="utf-8").strip()
                first_line = marker_content.splitlines()[0] if marker_content else ""
                if first_line:
                    candidate = Path(first_line)
                    if candidate.exists():
                        plan_path = candidate
                    else:
                        # Marker path doesn't exist — silent exit
                        return 0
                else:
                    return 0
            except OSError:
                return 0
        else:
            # No active-plan marker and no explicit --plan: a session with no active
            # plan gets no briefing. Do NOT fall back to DEFAULT_PLAN.
            return 0

    # Read plan file
    if not plan_path.exists():
        if args.resume:
            return 0  # silent exit for resume mode
        msg = f"Plan file not found: {plan_path}"
        if args.json:
            print(json.dumps({"error": msg}))
        else:
            print(f"ERROR: {msg}", file=sys.stderr)
        return 1

    try:
        plan_text = plan_path.read_text(encoding="utf-8")
    except OSError as exc:
        msg = f"Cannot read plan file: {exc}"
        if args.json:
            print(json.dumps({"error": msg}))
        else:
            print(f"ERROR: {msg}", file=sys.stderr)
        return 1

    rows = parse_ledger(plan_text)
    git_root = resolve_git_root(plan_path)

    if args.resume:
        return mode_resume(plan_path, plan_text, rows, git_root)
    if args.update_baseline:
        return mode_update_baseline(plan_path, plan_text, rows, git_root, args.baseline)
    if args.check:
        return mode_check(plan_path, plan_text, rows, git_root, args.baseline)
    if args.json:
        return mode_json(plan_path, plan_text, rows, git_root)

    return mode_default(plan_path, plan_text, rows, git_root)


# ---------------------------------------------------------------------------
# Entry point (mirror cast-db-contract.py:1185-1193)
# ---------------------------------------------------------------------------
if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(1)
    except Exception as exc:
        print(json.dumps({"error": str(exc), "type": type(exc).__name__}))
        sys.exit(1)

#!/usr/bin/env python3
"""
cast-record-review.py — B5 weekly record-review loop for CAST.

Mines cast.db (+ audit.jsonl + agent def frontmatter + eval cases) for a weekly
(and, on the first Sunday of the month, folded-in monthly deep pass) markdown
report of proposals: measure→tune, mine→propose, friction mining, trend→alert.

Read-only by design: every DB connection is opened in SQLite URI mode=ro so the
script structurally cannot write to cast.db. Output is a single markdown file —
no new DB table, no new agent, no approval UI.

Usage:
  cast-record-review.py [--db PATH] [--out-dir DIR] [--agents-dir DIR]
                         [--evals-dir DIR] [--audit-log PATH] [--projects-dir DIR]

Weekly cron (Sunday 07:00, after memory-consolidate 05:30 and branch-groomer 06:00):
  see macos/cast-record-review.plist
"""

import argparse
import glob
import json
import os
import re
import sqlite3
import subprocess
import sys
from datetime import date, datetime, timedelta, timezone

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
try:
    from cast_db import log_hook_failure
except Exception:
    log_hook_failure = None

LOG_PATH = os.path.expanduser('~/.claude/logs/record-review.log')


def _log_error(msg: str) -> None:
    """Log an error to ~/.claude/logs/record-review.log — never raises."""
    try:
        os.makedirs(os.path.dirname(LOG_PATH), exist_ok=True)
        with open(LOG_PATH, 'a') as f:
            f.write(f"{datetime.now(timezone.utc).isoformat()} ERROR {msg}\n")
    except OSError:
        pass
    if log_hook_failure:
        try:
            log_hook_failure('cast-record-review', 1, msg)
        except Exception:
            pass


def get_db_path(cli_db: str = '') -> str:
    """Resolve cast.db path: --db > CAST_DB_URL(sqlite:///) > CAST_DB_PATH > default."""
    if cli_db:
        return cli_db
    url = os.environ.get('CAST_DB_URL', '')
    if url.startswith('sqlite:///'):
        return url[len('sqlite:///'):]
    return os.environ.get('CAST_DB_PATH', os.path.expanduser('~/.claude/cast.db'))


def get_repo_root() -> str:
    """Get the repository root — git toplevel, else cwd. Mirrors cast-lint-agent-roster.py."""
    try:
        result = subprocess.run(
            ['git', 'rev-parse', '--show-toplevel'],
            capture_output=True, text=True, timeout=5
        )
        if result.returncode == 0 and result.stdout.strip():
            return result.stdout.strip()
    except Exception:
        pass
    return os.getcwd()


def connect_ro(db_path: str):
    """Open cast.db strictly read-only via SQLite URI mode=ro. Never writes."""
    return sqlite3.connect(f"file:{db_path}?mode=ro", uri=True, timeout=10)


def table_exists(conn, table_name: str) -> bool:
    row = conn.execute(
        "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
        (table_name,)
    ).fetchone()
    return row is not None


def safe_query(conn, sql: str, params=()) -> list:
    """Run a query, returning [] on any sqlite3 error (missing table/column, etc)."""
    try:
        cur = conn.execute(sql, params)
        cols = [d[0] for d in cur.description] if cur.description else []
        return [dict(zip(cols, row)) for row in cur.fetchall()]
    except sqlite3.Error as e:
        _log_error(f"query failed: {sql[:80]!r}: {e}")
        return []


# ---------------------------------------------------------------------------
# Proposal accumulator
# ---------------------------------------------------------------------------

class Proposal:
    def __init__(self, section: str, title: str, evidence: str, recommendation: str,
                 target_file: str = '', strength: str = 'Medium'):
        self.section = section
        self.title = title
        self.evidence = evidence
        self.recommendation = recommendation
        self.target_file = target_file
        self.strength = strength

    def to_markdown(self) -> str:
        lines = [f"### Proposal: {self.title}", f"- Evidence: {self.evidence}",
                  f"- Recommendation: {self.recommendation}"]
        if self.target_file:
            lines.append(f"- Target file: {self.target_file}")
        return "\n".join(lines)


# ---------------------------------------------------------------------------
# Section 1: Measure -> Tune
# ---------------------------------------------------------------------------

def parse_agent_max_turns(agents_dir: str, agent_name: str):
    """Parse maxTurns: N from an agent def's YAML frontmatter. Returns int or None."""
    path = os.path.join(agents_dir, f"{agent_name}.md")
    if not os.path.exists(path):
        return None
    try:
        with open(path) as f:
            text = f.read()
    except OSError:
        return None
    parts = text.split('---')
    if len(parts) < 2:
        return None
    frontmatter = parts[1]
    m = re.search(r'^maxTurns:\s*(\d+)', frontmatter, re.MULTILINE)
    return int(m.group(1)) if m else None


def section_measure_tune(conn, agents_dir: str, lookback_days: int = 7) -> tuple:
    proposals = []
    lines = ["## 1. Measure→Tune"]

    # --- Model-tier cost_per_success comparison ---
    rows = safe_query(conn, """
        SELECT agent, model, COUNT(*) n,
               SUM(CASE WHEN status IN ('DONE','completed') THEN 1 ELSE 0 END) success,
               ROUND(SUM(cost_usd),2) total_cost,
               ROUND(SUM(cost_usd) / NULLIF(SUM(CASE WHEN status IN ('DONE','completed') THEN 1 ELSE 0 END),0), 4) cost_per_success
        FROM agent_runs
        WHERE started_at >= datetime('now', ?) AND model IS NOT NULL AND model != ''
        GROUP BY agent, model
        HAVING n >= 5
        ORDER BY total_cost DESC
    """, (f'-{lookback_days} days',))

    by_agent = {}
    for r in rows:
        by_agent.setdefault(r['agent'], []).append(r)

    model_tier_found = False
    for agent, variants in by_agent.items():
        if len(variants) < 2:
            continue
        priced = [v for v in variants if v['cost_per_success'] is not None]
        if len(priced) < 2:
            continue
        priced.sort(key=lambda v: v['cost_per_success'])
        cheapest, priciest = priced[0], priced[-1]
        if cheapest['cost_per_success'] <= 0:
            continue
        ratio = priciest['cost_per_success'] / cheapest['cost_per_success']
        if ratio > 2.0:
            model_tier_found = True
            proposals.append(Proposal(
                section="1. Measure→Tune",
                title=f"Model-tier suggestion for `{agent}`",
                evidence=(f"`{agent}` on `{cheapest['model']}` costs "
                          f"${cheapest['cost_per_success']}/success (n={cheapest['n']}) vs "
                          f"`{priciest['model']}` at ${priciest['cost_per_success']}/success "
                          f"(n={priciest['n']}) — {ratio:.1f}x difference over the last {lookback_days}d"),
                recommendation=f"Favor `{cheapest['model']}` for `{agent}` where behavior parity holds.",
                strength="High" if ratio > 3 else "Medium",
            ))

    if rows:
        lines.append(f"Cost/success by agent+model ({lookback_days}d, n>=5):")
        for r in rows:
            lines.append(f"- `{r['agent']}` / `{r['model']}`: n={r['n']}, success={r['success']}, "
                          f"total_cost=${r['total_cost']}, cost_per_success=${r['cost_per_success']}")
    else:
        lines.append(f"No agent/model pairs with n>=5 runs in the last {lookback_days}d.")

    if not model_tier_found:
        lines.append("- No model-tier cost_per_success divergence >2x this window.")

    # --- Truncation cross-reference against maxTurns ---
    trunc_rows = safe_query(conn, """
        SELECT agent_type, COUNT(*) truncations
        FROM agent_truncations
        WHERE timestamp >= datetime('now', ?)
        GROUP BY agent_type ORDER BY 2 DESC
    """, (f'-{lookback_days} days',))

    if trunc_rows:
        lines.append(f"\nTruncations by agent_type ({lookback_days}d):")
        for tr in trunc_rows:
            agent_type = tr['agent_type']
            truncations = tr['truncations']
            total_rows = safe_query(conn, """
                SELECT COUNT(*) n FROM agent_runs
                WHERE agent = ? AND started_at >= datetime('now', ?)
            """, (agent_type, f'-{lookback_days} days'))
            total_runs = total_rows[0]['n'] if total_rows else 0
            frac = (truncations / total_runs) if total_runs else 0.0
            lines.append(f"- `{agent_type}`: {truncations} truncations / {total_runs} runs "
                         f"({frac:.0%})")
            if truncations > 0 and total_runs >= 5 and frac >= 0.1:
                current_max = parse_agent_max_turns(agents_dir, agent_type)
                max_str = str(current_max) if current_max is not None else "unknown"
                proposals.append(Proposal(
                    section="1. Measure→Tune",
                    title=f"maxTurns increase for `{agent_type}`",
                    evidence=(f"{truncations} truncations / {total_runs} runs "
                              f"({frac:.0%}) in the last {lookback_days}d; current maxTurns={max_str}"),
                    recommendation=f"Raise maxTurns above {max_str} for `{agent_type}` or split its dispatches.",
                    target_file=f"agents/core/{agent_type}.md",
                    strength="High" if frac >= 0.25 else "Medium",
                ))
    else:
        lines.append(f"\nNo agent_truncations rows in the last {lookback_days}d.")

    # --- Ceremony-tier drift (quality_gates gate_type share, this week vs prior week) ---
    this_week = safe_query(conn, """
        SELECT gate_type, COUNT(*) n FROM quality_gates
        WHERE created_at >= datetime('now', ?) GROUP BY gate_type
    """, (f'-{lookback_days} days',))
    prior_week = safe_query(conn, """
        SELECT gate_type, COUNT(*) n FROM quality_gates
        WHERE created_at >= datetime('now', ?) AND created_at < datetime('now', ?)
        GROUP BY gate_type
    """, (f'-{lookback_days * 2} days', f'-{lookback_days} days'))

    def _shares(rows):
        total = sum(r['n'] for r in rows) or 1
        # gate_type may be NULL in the DB — coerce to a sortable label rather than
        # crashing sorted() on a str/None comparison.
        return {(r['gate_type'] if r['gate_type'] is not None else '(none)'): r['n'] / total
                for r in rows}

    this_shares = _shares(this_week)
    prior_shares = _shares(prior_week)

    drift_found = False
    if this_week or prior_week:
        lines.append("\nCeremony mix (gate_type share, this week vs prior week):")
        all_types = sorted(set(this_shares) | set(prior_shares))
        for gt in all_types:
            cur = this_shares.get(gt, 0.0)
            prev = prior_shares.get(gt, 0.0)
            delta_pp = (cur - prev) * 100
            lines.append(f"- `{gt}`: {prev:.0%} -> {cur:.0%} ({delta_pp:+.0f}pp)")
            if abs(delta_pp) > 20:
                drift_found = True
                proposals.append(Proposal(
                    section="1. Measure→Tune",
                    title=f"Ceremony mix drifted for `{gt}`",
                    evidence=f"gate_type `{gt}` share {prev:.0%} -> {cur:.0%} ({delta_pp:+.0f}pp) week-over-week",
                    recommendation="Investigate whether the ceremony tier for this gate_type still matches actual usage.",
                    strength="Medium",
                ))
        if not drift_found:
            lines.append("- No gate_type share shifted >20pp week-over-week.")
    else:
        lines.append("\nNo quality_gates rows in this or prior window — no findings.")

    return "\n".join(lines), proposals


# ---------------------------------------------------------------------------
# Section 2: Mine -> Propose
# ---------------------------------------------------------------------------

def _find_matching_eval_case(evals_dir: str, agent_name: str, pattern: str):
    """Glob evals/cases/<agent_name>/*.yaml and grep tags:/failure_type: for pattern.

    Normalizes '_' <-> '-' since claim_type/violation strings use underscores while
    eval tags commonly use hyphens (e.g. claim_type 'file_write' vs tag 'file-write').
    Returns the matching file path, or None.
    """
    agent_dir = os.path.join(evals_dir, agent_name)
    if not os.path.isdir(agent_dir):
        return None
    needles = {pattern, pattern.replace('_', '-'), pattern.replace('-', '_')}
    for path in sorted(glob.glob(os.path.join(agent_dir, '*.yaml'))):
        try:
            with open(path) as f:
                content = f.read()
        except OSError:
            continue
        # Only scan tags:/failure_type: fields per evals/cases/README.md schema.
        field_text = ''
        for m in re.finditer(r'^(tags|failure_type):.*(?:\n(?:  .*)?)*', content, re.MULTILINE):
            field_text += m.group(0) + '\n'
        if any(n in field_text for n in needles):
            return path
    return None


def section_mine_propose(conn, evals_dir: str, lookback_days: int = 7) -> tuple:
    proposals = []
    lines = ["## 2. Mine→Propose"]
    any_findings = False

    halluc = safe_query(conn, """
        SELECT agent_name, claim_type, COUNT(*) n FROM agent_hallucinations
        WHERE timestamp >= datetime('now', ?) GROUP BY agent_name, claim_type ORDER BY n DESC LIMIT 10
    """, (f'-{lookback_days} days',))
    violations = safe_query(conn, """
        SELECT agent_type, violation, COUNT(*) n FROM agent_protocol_violations
        WHERE timestamp >= datetime('now', ?) GROUP BY agent_type, violation ORDER BY n DESC LIMIT 10
    """, (f'-{lookback_days} days',))
    incidents = safe_query(conn, """
        SELECT id, occurred_at, problem_summary FROM incidents
        WHERE occurred_at >= datetime('now', ?) ORDER BY occurred_at DESC
    """, (f'-{lookback_days} days',))

    if halluc:
        any_findings = True
        lines.append(f"\nHallucinations by agent+claim_type ({lookback_days}d, top 10):")
        for h in halluc:
            lines.append(f"- `{h['agent_name']}` / `{h['claim_type']}`: n={h['n']}")
            if h['n'] >= 5:
                match = _find_matching_eval_case(evals_dir, h['agent_name'], h['claim_type'])
                if match:
                    proposals.append(Proposal(
                        section="2. Mine→Propose",
                        title=f"Patch `{h['agent_name']}` definition — recurring `{h['claim_type']}` hallucination",
                        evidence=f"{h['n']}/week hallucinations of claim_type `{h['claim_type']}` for `{h['agent_name']}`",
                        recommendation=(f"existing case {match} already covers this, still firing at "
                                        f"{h['n']}/week — patch the agent definition, not another eval"),
                        target_file=f"agents/core/{h['agent_name']}.md",
                        strength="High",
                    ))
                else:
                    grader_note = ("Grader: `scripts/eval-graders/check-honesty-table.py --table "
                                    "agent_hallucinations --match-value <agent_name>`")
                    yaml_block = (
                        f"```yaml\n"
                        f"id: {h['agent_name']}-{h['claim_type']}-recurring\n"
                        f"version: \"1\"\n"
                        f"agent: {h['agent_name']}\n"
                        f"description: \"{h['agent_name']} recurring {h['claim_type']} hallucination "
                        f"({h['n']}/week, record-review B5 draft)\"\n"
                        f"corpus_source: honesty_tables\n"
                        f"failure_type: hallucination\n"
                        f"cost_tier: cheap\n"
                        f"tags: [honesty, {h['agent_name']}, {h['claim_type'].replace('_', '-')}, phase-a]\n"
                        f"trigger: |\n"
                        f"  <fill in a trigger reproducing the {h['claim_type']} claim pattern>\n"
                        f"expected_behaviors:\n"
                        f"  - \"Response does not claim {h['claim_type']} without verification\"\n"
                        f"forbidden_behaviors:\n"
                        f"  - \"Response claims {h['claim_type']} that did not occur\"\n"
                        f"graders:\n"
                        f"  - id: {h['claim_type']}-honesty-check\n"
                        f"    type: programmatic\n"
                        f"    command: \"python3 scripts/eval-graders/check-honesty-table.py "
                        f"--table agent_hallucinations --match-value {h['agent_name']}\"\n"
                        f"    pass_criteria: exit_code_0\n"
                        f"    on_error: skip\n"
                        f"```"
                    )
                    proposals.append(Proposal(
                        section="2. Mine→Propose",
                        title=f"New eval case draft — `{h['agent_name']}` `{h['claim_type']}` hallucination",
                        evidence=f"{h['n']}/week hallucinations, no existing eval case matched. {grader_note}",
                        recommendation=f"Add draft below to evals/cases/{h['agent_name']}/.\n\n{yaml_block}",
                        strength="Medium",
                    ))

    if violations:
        any_findings = True
        lines.append(f"\nProtocol violations by agent+violation ({lookback_days}d, top 10):")
        for v in violations:
            lines.append(f"- `{v['agent_type']}` / `{v['violation']}`: n={v['n']}")
            if v['n'] >= 5:
                match = _find_matching_eval_case(evals_dir, v['agent_type'], v['violation'])
                if match:
                    proposals.append(Proposal(
                        section="2. Mine→Propose",
                        title=f"Patch `{v['agent_type']}` definition — recurring `{v['violation']}`",
                        evidence=f"{v['n']}/week protocol violations of `{v['violation']}` for `{v['agent_type']}`",
                        recommendation=(f"existing case {match} already covers this, still firing at "
                                        f"{v['n']}/week — patch the agent definition, not another eval"),
                        target_file=f"agents/core/{v['agent_type']}.md",
                        strength="High",
                    ))
                else:
                    grader_note = ("Grader: `scripts/eval-graders/check-honesty-table.py --table "
                                    "agent_protocol_violations --match-value <agent_id>`")
                    yaml_block = (
                        f"```yaml\n"
                        f"id: {v['agent_type']}-{v['violation']}-recurring\n"
                        f"version: \"1\"\n"
                        f"agent: {v['agent_type']}\n"
                        f"description: \"{v['agent_type']} recurring {v['violation']} "
                        f"({v['n']}/week, record-review B5 draft)\"\n"
                        f"corpus_source: manual\n"
                        f"failure_type: {v['violation']}\n"
                        f"cost_tier: cheap\n"
                        f"tags: [protocol, {v['agent_type']}, {v['violation'].replace('_', '-')}, phase-a]\n"
                        f"trigger: |\n"
                        f"  <fill in a trigger reproducing the {v['violation']} pattern>\n"
                        f"expected_behaviors:\n"
                        f"  - \"Response does not exhibit {v['violation']}\"\n"
                        f"forbidden_behaviors:\n"
                        f"  - \"Response exhibits {v['violation']}\"\n"
                        f"graders:\n"
                        f"  - id: {v['violation']}-check\n"
                        f"    type: programmatic\n"
                        f"    command: \"python3 scripts/eval-graders/check-honesty-table.py "
                        f"--table agent_protocol_violations --match-value <agent_id>\"\n"
                        f"    pass_criteria: exit_code_0\n"
                        f"    on_error: skip\n"
                        f"```"
                    )
                    proposals.append(Proposal(
                        section="2. Mine→Propose",
                        title=f"New eval case draft — `{v['agent_type']}` `{v['violation']}` violation",
                        evidence=f"{v['n']}/week violations, no existing eval case matched. {grader_note}",
                        recommendation=f"Add draft below to evals/cases/{v['agent_type']}/.\n\n{yaml_block}",
                        strength="Medium",
                    ))

    if incidents:
        any_findings = True
        lines.append(f"\nIncidents ({lookback_days}d):")
        for inc in incidents:
            lines.append(f"- `{inc['id']}` ({inc['occurred_at']}): {inc['problem_summary']}")

    if not any_findings:
        lines.append(f"\nNo findings this window (0 hallucinations, 0 protocol violations, "
                      f"0 incidents in the last {lookback_days}d).")

    return "\n".join(lines), proposals


# ---------------------------------------------------------------------------
# Section 3: Friction Mining
# ---------------------------------------------------------------------------

_BLOCK_SUBSTRINGS = [
    "Raw `git commit` blocked",
    "Raw `git push` blocked",
    "Raw `git stash` blocked",
    "blocks this edit",
]


def _read_audit_events(audit_log: str, lookback_days: int) -> list:
    """Read audit.jsonl, return COMMIT_HATCH_USED/POLICY_OVERRIDE events within lookback.

    Skips malformed lines. Timestamp field is 'timestamp' (ISO8601 'Z'-suffixed, per
    cast-git-guard.py's _audit_commit_hatch/_audit_policy_override writers).
    """
    if not os.path.exists(audit_log):
        return []
    cutoff = datetime.now(timezone.utc) - timedelta(days=lookback_days)
    events = []
    try:
        with open(audit_log) as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    obj = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if obj.get('event') not in ('COMMIT_HATCH_USED', 'POLICY_OVERRIDE'):
                    continue
                ts_raw = obj.get('timestamp', '')
                try:
                    ts = datetime.fromisoformat(ts_raw.replace('Z', '+00:00'))
                except (ValueError, AttributeError):
                    continue
                if ts >= cutoff:
                    events.append(obj)
    except OSError as e:
        _log_error(f"failed reading audit log {audit_log}: {e}")
    return events


def _find_transcript_evidence(projects_dir: str, session_id: str, hatch_ts: str):
    """Search transcript(s) matching session_id for block-message substrings before hatch_ts.

    Best-effort: if a line has no parseable 'timestamp' field it is still searched
    (transcripts don't uniformly stamp every line). Returns the matched substring, or None.
    """
    if not session_id or session_id == 'unknown':
        return None
    pattern = os.path.join(projects_dir, '**', f'*{session_id}*.jsonl')
    matches = glob.glob(pattern, recursive=True)
    if not matches:
        return None
    try:
        hatch_dt = datetime.fromisoformat(hatch_ts.replace('Z', '+00:00'))
    except (ValueError, AttributeError):
        hatch_dt = None
    for path in matches:
        try:
            with open(path, errors='replace') as f:
                for line in f:
                    line_dt = None
                    try:
                        obj = json.loads(line)
                        ts_raw = obj.get('timestamp')
                        if ts_raw:
                            line_dt = datetime.fromisoformat(str(ts_raw).replace('Z', '+00:00'))
                    except Exception:
                        pass
                    if hatch_dt and line_dt and line_dt >= hatch_dt:
                        continue
                    for sub in _BLOCK_SUBSTRINGS:
                        if sub in line:
                            return sub
        except OSError:
            continue
    return None


def _check_push_hatch_audit_gap(repo_root: str):
    """Verify cast-git-guard.py's push-allow branch still has no audit call (static finding)."""
    path = os.path.join(repo_root, 'scripts', 'cast-git-guard.py')
    if not os.path.exists(path):
        return None
    try:
        with open(path) as f:
            content = f.read()
    except OSError:
        return None
    m = re.search(r'if _PUSH_ALLOW\.search\(first_line\):\s*\n(.*?)\n\s*if _PUSH_BLOCK',
                  content, re.DOTALL)
    if not m:
        return None
    branch_body = m.group(1)
    if '_audit' in branch_body:
        return None  # an audit call already exists — proposal is stale, drop it
    return path


def section_friction(conn, audit_log: str, projects_dir: str, repo_root: str,
                      lookback_days: int = 7) -> tuple:
    proposals = []
    lines = ["## 3. Friction Mining"]

    events = _read_audit_events(audit_log, lookback_days)
    confirmed = []
    proactive_count = 0

    for ev in events:
        session_id = ev.get('session_id', '')
        ts = ev.get('timestamp', '')
        match = _find_transcript_evidence(projects_dir, session_id, ts)
        if match:
            confirmed.append((ev, match))
        else:
            proactive_count += 1

    if events:
        lines.append(f"\n{len(events)} hatch/override events in the last {lookback_days}d: "
                      f"{len(confirmed)} confirmed friction, {proactive_count} proactive/expected "
                      f"(no preceding block found in transcript, or transcript unavailable).")
        if confirmed:
            # Group by (event, git_op/policy_id) for recurrence counts.
            groups = {}
            for ev, match in confirmed:
                key = (ev.get('event'), ev.get('git_op') or ev.get('policy_id') or '')
                groups.setdefault(key, []).append((ev, match))
            for (event_type, op), items in sorted(groups.items(), key=lambda kv: -len(kv[1])):
                lines.append(f"- `{event_type}` / `{op}`: {len(items)} confirmed occurrence(s) "
                              f"across {len({i[0].get('session_id') for i in items})} session(s)")
                sample_ev, sample_match = items[0]
                lines.append(f"  - Evidence: session_id={sample_ev.get('session_id')}, "
                              f"timestamp={sample_ev.get('timestamp')}, matched=\"{sample_match}\"")
                if len(items) >= 3:
                    proposals.append(Proposal(
                        section="3. Friction Mining",
                        title=f"Recurring block→hatch pair: `{event_type}` / `{op}`",
                        evidence=f"{len(items)} confirmed friction events in the last {lookback_days}d "
                                  f"(sample: session_id={sample_ev.get('session_id')}, "
                                  f"timestamp={sample_ev.get('timestamp')})",
                        recommendation=f"Review whether the policy/guard producing `{op}` blocks is "
                                        f"miscalibrated for its actual usage pattern.",
                        strength="Medium",
                    ))
    else:
        lines.append(f"\nNo findings this window (0 COMMIT_HATCH_USED/POLICY_OVERRIDE events "
                      f"in the last {lookback_days}d).")

    # Static finding — CAST_PUSH_OK push-hatch has zero audit logging.
    gap_target = _check_push_hatch_audit_gap(repo_root)
    if gap_target:
        proposals.append(Proposal(
            section="3. Friction Mining",
            title="Push-hatch (`CAST_PUSH_OK`) has zero audit logging",
            evidence=(f"Verified in {gap_target}: `_git_evaluate`'s `_PUSH_ALLOW` branch returns "
                      f"`(0, None)` directly, unlike the commit hatch which calls `_audit_commit_hatch()`."),
            recommendation="Add a one-line audit call (mirroring `_audit_commit_hatch()`) in the "
                            "`_PUSH_ALLOW` branch of `_git_evaluate` — do not implement here, just propose.",
            target_file=f"{gap_target} (`_git_evaluate`, `_PUSH_ALLOW` branch)",
            strength="Medium",
        ))
        lines.append("\n- Push-hatch (`CAST_PUSH_OK`) audit-logging gap confirmed still present "
                     "(see Proposal above).")

    return "\n".join(lines), proposals


# ---------------------------------------------------------------------------
# Section 4: Trend -> Alert
# ---------------------------------------------------------------------------

def _count_log_hook_failure_sites(repo_root: str) -> str:
    """Grep scripts/ for log_hook_failure( call sites, excluding its own definition."""
    scripts_dir = os.path.join(repo_root, 'scripts')
    if not os.path.isdir(scripts_dir):
        return "unknown"
    try:
        result = subprocess.run(
            ['grep', '-rl', 'log_hook_failure(', scripts_dir],
            capture_output=True, text=True, timeout=10
        )
        files = [f for f in result.stdout.splitlines() if not f.endswith('cast_db.py')
                 and '__pycache__' not in f]
        return str(len(files))
    except Exception:
        return "unknown"


# table -> (timestamp_column, expected_cadence_days, silent_threshold_days)
_SILENT_PRODUCER_TABLES = {
    'hook_failures': ('timestamp', 'irregular', 30),
    'worktree_anomalies': ('detected_at', 'irregular', 30),
    'stop_failure_events': ('timestamp', 'irregular', 30),
    'dispatch_events': ('triggered_at', 'daily', 14),
    'injection_log': ('injected_at', 'daily', 14),
    'agent_truncations': ('timestamp', 'irregular', 30),
    'memory_consolidation_runs': ('completed_at', 'weekly', 30),
}


def section_trend_alert(conn, repo_root: str, lookback_days: int = 7) -> tuple:
    proposals = []
    lines = ["## 4. Trend→Alert"]

    # --- hook_failures ---
    hf_rows = safe_query(conn, """
        SELECT hook_name, COUNT(*) n FROM hook_failures
        WHERE timestamp >= datetime('now', ?) GROUP BY hook_name
    """, (f'-{lookback_days} days',))
    if hf_rows:
        total = sum(r['n'] for r in hf_rows)
        lines.append("### hook_failures: WATCH")
        lines.append(f"- This week vs last week: N/A (see per-hook counts) — {total} failures "
                      f"across {len(hf_rows)} hook(s) in the last {lookback_days}d")
        for r in hf_rows:
            lines.append(f"  - `{r['hook_name']}`: {r['n']}")
    else:
        site_count = _count_log_hook_failure_sites(repo_root)
        lines.append("### hook_failures: INFO")
        lines.append(f"- hook_failures has 0 rows in this window — verify this is genuine (no "
                      f"failures) not a dead producer; {site_count} documented "
                      f"`log_hook_failure` writer call sites exist in scripts/")

    # --- stale agent_run reaped trend (14d) ---
    stale_rows = safe_query(conn, """
        SELECT DATE(occurred_at) d, COUNT(*) n FROM incidents
        WHERE problem_summary LIKE 'Stale agent_run reaped:%' AND occurred_at >= datetime('now','-14 days')
        GROUP BY d ORDER BY d
    """)
    lines.append("\n### Stale agent_run reaped trend (14d): " + ("WATCH" if stale_rows else "OK"))
    if stale_rows:
        for r in stale_rows:
            lines.append(f"- {r['d']}: {r['n']}")
    else:
        lines.append("- 0 reaped stale-run incidents in the last 14d.")

    # --- Silent-producer registry ---
    lines.append("\n### Silent-producer registry")
    for table, (ts_col, cadence, threshold_days) in _SILENT_PRODUCER_TABLES.items():
        if not table_exists(conn, table):
            lines.append(f"- `{table}`: WATCH — table not present in schema")
            continue
        rows = safe_query(conn, f"SELECT MAX({ts_col}) mx FROM {table}")
        mx = rows[0]['mx'] if rows else None
        if not mx:
            lines.append(f"- `{table}` ({cadence} cadence): INFO — zero rows ever")
            continue
        try:
            mx_dt = datetime.fromisoformat(str(mx).replace('Z', '+00:00').replace(' ', 'T'))
            if mx_dt.tzinfo is None:
                mx_dt = mx_dt.replace(tzinfo=timezone.utc)
            age_days = (datetime.now(timezone.utc) - mx_dt).days
        except Exception:
            lines.append(f"- `{table}` ({cadence} cadence): last row at {mx} (age unparseable)")
            continue
        if age_days > threshold_days:
            lines.append(f"- `{table}` ({cadence} cadence): WATCH — last row {age_days}d ago "
                         f"(threshold {threshold_days}d)")
            proposals.append(Proposal(
                section="4. Trend→Alert",
                title=f"Silent producer: `{table}`",
                evidence=f"Last row {age_days}d ago; expected {cadence} cadence, threshold {threshold_days}d",
                recommendation=f"Verify the writer(s) for `{table}` are still wired and firing.",
                strength="Medium",
            ))
        else:
            lines.append(f"- `{table}` ({cadence} cadence): OK — last row {age_days}d ago")

    # --- cost per session weekly trend ---
    cost_rows = safe_query(conn, """
        SELECT strftime('%Y-W%W', started_at) wk, ROUND(SUM(cost_usd)/COUNT(DISTINCT session_id),4) cost_per_session
        FROM agent_runs WHERE started_at >= datetime('now','-21 days')
        GROUP BY wk ORDER BY wk
    """)
    lines.append("\n### Cost per session (21d trend)")
    if cost_rows:
        for r in cost_rows:
            lines.append(f"- {r['wk']}: ${r['cost_per_session']}")
    else:
        lines.append("- No agent_runs rows in the last 21d.")

    return "\n".join(lines), proposals


# ---------------------------------------------------------------------------
# Report assembly
# ---------------------------------------------------------------------------

def build_report(conn, agents_dir: str, evals_dir: str, audit_log: str, projects_dir: str,
                  repo_root: str, today: date) -> str:
    all_proposals = []

    s1_text, s1_props = section_measure_tune(conn, agents_dir, lookback_days=7)
    s2_text, s2_props = section_mine_propose(conn, evals_dir, lookback_days=7)
    s3_text, s3_props = section_friction(conn, audit_log, projects_dir, repo_root, lookback_days=7)
    s4_text, s4_props = section_trend_alert(conn, repo_root, lookback_days=7)
    all_proposals += s1_props + s2_props + s3_props + s4_props

    deep_pass = today.day <= 7
    deep_text = ""
    if deep_pass:
        d2_text, d2_props = section_mine_propose(conn, evals_dir, lookback_days=90)
        d3_text, d3_props = section_friction(conn, audit_log, projects_dir, repo_root, lookback_days=90)
        d4_text, d4_props = section_trend_alert(conn, repo_root, lookback_days=90)
        all_proposals += d2_props + d3_props + d4_props
        deep_text = (
            "\n## Deep Pass (Monthly)\n\n" +
            d2_text.replace("## 2. Mine→Propose", "### Deep Pass — Mine→Propose (90d)") + "\n\n" +
            d3_text.replace("## 3. Friction Mining", "### Deep Pass — Friction Mining (90d)") + "\n\n" +
            d4_text.replace("## 4. Trend→Alert", "### Deep Pass — Trend→Alert (90d)")
        )

    counts = {
        "1. Measure→Tune": len(s1_props),
        "2. Mine→Propose": len([p for p in all_proposals if p.section.startswith("2.")]),
        "3. Friction Mining": len([p for p in all_proposals if p.section.startswith("3.")]),
        "4. Trend→Alert": len([p for p in all_proposals if p.section.startswith("4.")]),
    }
    total = sum(counts.values())

    header = f"# CAST Record Review — {today.isoformat()}\n"
    lookback_line = "Lookback: 7d (weekly)"
    if deep_pass:
        lookback_line += ", Deep Pass: 90d monthly — only if deep-pass triggered"
    header += lookback_line + "\n"

    summary = (
        "\n## Summary\n"
        f"- {total} proposals ({counts['1. Measure→Tune']} measure→tune, "
        f"{counts['2. Mine→Propose']} mine→propose, {counts['3. Friction Mining']} friction, "
        f"{counts['4. Trend→Alert']} trend)\n"
    )

    # Build proposal detail sections (### Proposal blocks) grouped under their section headers.
    def section_with_proposals(section_text, section_props):
        blocks = [p.to_markdown() for p in section_props]
        return section_text + ("\n\n" + "\n\n".join(blocks) if blocks else "")

    body = "\n\n".join([
        section_with_proposals(s1_text, s1_props),
        section_with_proposals(s2_text, s2_props),
        section_with_proposals(s3_text, s3_props),
        section_with_proposals(s4_text, s4_props),
    ])

    table_rows = []
    for i, p in enumerate(all_proposals, start=1):
        title = p.title.replace('|', '\\|')
        table_rows.append(f"| {i} | {p.section} | {title} | {p.strength} | |")
    table = (
        "\n\n## Proposals Requiring Decision\n\n"
        "| # | Section | Proposal | Evidence strength | Accept/Reject |\n"
        "|---|---|---|---|---|\n" +
        ("\n".join(table_rows) if table_rows else "| - | - | No proposals this window | - | - |")
    )

    return header + summary + "\n" + body + deep_text + table + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description='CAST weekly record-review proposals report.')
    parser.add_argument('--db', default='', help='Path to cast.db (overrides CAST_DB_PATH)')
    parser.add_argument('--out-dir', default=os.path.expanduser('~/.claude/reports/'),
                         help='Output directory for the markdown report')
    parser.add_argument('--agents-dir', default='', help='Override agents/core dir')
    parser.add_argument('--evals-dir', default='', help='Override evals/cases dir')
    parser.add_argument('--audit-log', default=os.path.expanduser('~/.claude/logs/audit.jsonl'),
                         help='Path to audit.jsonl')
    parser.add_argument('--projects-dir', default=os.path.expanduser('~/.claude/projects/'),
                         help='Path to session transcript projects dir')
    args = parser.parse_args()

    db_path = get_db_path(args.db)
    if not os.path.exists(db_path):
        print(f"ERROR: cast.db not found at {db_path}", file=sys.stderr)
        _log_error(f"cast.db not found at {db_path}")
        sys.exit(1)

    repo_root = get_repo_root()
    agents_dir = args.agents_dir or os.path.join(repo_root, 'agents', 'core')
    evals_dir = args.evals_dir or os.path.join(repo_root, 'evals', 'cases')

    try:
        conn = connect_ro(db_path)
    except sqlite3.Error as e:
        print(f"ERROR: Cannot connect to {db_path}: {e}", file=sys.stderr)
        _log_error(f"cannot connect to {db_path}: {e}")
        sys.exit(1)

    try:
        today = date.today()
        report = build_report(conn, agents_dir, evals_dir, args.audit_log,
                               args.projects_dir, repo_root, today)
    except Exception as e:
        print(f"ERROR: report generation failed: {e}", file=sys.stderr)
        _log_error(f"report generation failed: {e}")
        try:
            conn.close()
        except Exception:
            pass
        sys.exit(1)

    try:
        conn.close()
    except Exception:
        pass

    try:
        os.makedirs(args.out_dir, exist_ok=True)
        out_path = os.path.join(args.out_dir, f"cast-record-review-{today.isoformat()}.md")
        with open(out_path, 'w') as f:
            f.write(report)
    except OSError as e:
        print(f"ERROR: failed writing report: {e}", file=sys.stderr)
        _log_error(f"failed writing report: {e}")
        sys.exit(1)

    print(out_path)
    return 0


if __name__ == '__main__':
    sys.exit(main())

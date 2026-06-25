#!/usr/bin/env python3
"""cast-git-guard.py — CAST PreToolUse git + policy guard (logic module).

CAST v9 P0 hot-path consolidation: the git commit/push/stash blocks and the
Write/Edit policy engine — formerly inline bash + python in pre-tool-guard.sh —
now live here as ONE importable module. `pre-tool-guard.sh` is a thin wrapper
that execs this file (so tests/pre-tool-guard.bats + tests/test_push_agent_stash_guard.bats
continue to prove this logic), and cast-pretool-dispatch.py imports `evaluate()`
to run the same checks in-process — single source of truth, no duplication.

GUARANTEES PRESERVED (Subtraction Safety Gate, master_v9.md §0.2):
  - Raw `git commit` blocked → use the commit agent (escape: CAST_COMMIT_AGENT=1).
  - Raw `git push` blocked → code-reviewer first (escape: CAST_PUSH_OK=1).
  - Raw `git stash` blocked (2026-05-19 push-agent stash-resurrection incident;
    escape: CAST_STASH_OK=1).
  - Write/Edit path policy engine (config/policies.json → requires_agent gate,
    CAST_POLICY_OVERRIDE=1 escape with audit-log).
  - agent-status TTL sweep (files older than 120 min) on Write/Edit.

SECURITY (unchanged from the bash original):
  - The escape hatch MUST appear as a leading env-var assignment BEFORE the git
    command (tolerating leading `cd &&` chains and git global options). It can
    NEVER take effect from inside a commit message / comment / echo — only the
    command's FIRST LINE is scanned, so a multiline escape-hatch on line 2 can't
    bypass the first-line git command.

CONTRACT: exit 2 + stderr message = block; exit 0 = allow. FAIL-OPEN — any
internal error allows the tool (a guard crash must never block all work).
CLAUDE_SUBPROCESS=1 (managed/headless sub-claude) is skipped in the .sh wrapper.
"""
import datetime
import json
import os
import re
import sys

# --- git global-option tolerance (shared by every git pattern) --------------
# Matches: -C <path>, --no-pager, -c <cfg>, --git-dir=<d>, --work-tree=<w>
_GIT_OPTS = r'(\s+(-C\s+\S+|--no-pager|-c\s+\S+|--git-dir=\S+|--work-tree=\S+))*'

# --- git commit block -------------------------------------------------------
_COMMIT_ALLOW = re.compile(r'(^|&&\s*)CAST_COMMIT_AGENT=1\s+git' + _GIT_OPTS + r'\s+commit')
_COMMIT_BLOCK = re.compile(r'(^|\s)git' + _GIT_OPTS + r'\s+commit')

# --- git push block ---------------------------------------------------------
# Tolerates extra VAR=value assignments between CAST_PUSH_OK=1 and git
# (e.g. CAST_PUSH_OK=1 CAST_SKIP_BATS_PUSH=1 git push ...).
_PUSH_ALLOW = re.compile(
    r'(^|&&\s*)CAST_PUSH_OK=1\s+([A-Za-z_][A-Za-z0-9_]*=\S+\s+)*git' + _GIT_OPTS + r'\s+push'
)
_PUSH_BLOCK = re.compile(r'(^|\s)git' + _GIT_OPTS + r'\s+push')

# --- git stash block --------------------------------------------------------
_STASH_ALLOW = re.compile(r'(^|&&\s*)CAST_STASH_OK=1\s+git' + _GIT_OPTS + r'\s+stash')
_STASH_BLOCK = re.compile(r'(^|\s)git' + _GIT_OPTS + r'\s+stash(\s|$)')

_COMMIT_MSG = (
    "**[CAST]** Raw `git commit` blocked. Dispatch the `commit` agent instead "
    "(Agent tool, subagent_type: 'commit')."
)
_PUSH_MSG = (
    "**[CAST]** Raw `git push` blocked. Ensure code-reviewer has run, then use "
    "`CAST_PUSH_OK=1 git push` or dispatch via the commit agent workflow."
)
_STASH_MSG = (
    "**[CAST]** Raw `git stash` blocked. Stash operations are prohibited for agents "
    "— they risk resurrecting abandoned stashes from other sessions. If you genuinely "
    "need stash, use `CAST_STASH_OK=1 git stash` (document your reason). "
    "See: 2026-05-19 push-agent stash incident."
)

SESSION_TIMEOUT = 7200  # 2 hours, matches the agent-status TTL


def _claude_dir() -> str:
    return os.environ.get('CLAUDE_DIR', os.path.join(os.path.expanduser('~'), '.claude'))


# --------------------------------------------------------------------------
# Write/Edit: agent-status TTL sweep + policy engine
# --------------------------------------------------------------------------
def _ttl_sweep_agent_status() -> None:
    """Delete agent-status/*.json older than 120 min (mirrors `find -mmin +120 -delete`)."""
    try:
        status_dir = os.path.join(_claude_dir(), 'agent-status')
        if not os.path.isdir(status_dir):
            return
        now = datetime.datetime.now(datetime.timezone.utc).timestamp()
        for fname in os.listdir(status_dir):
            if not fname.endswith('.json'):
                continue
            fpath = os.path.join(status_dir, fname)
            try:
                age_min = int((now - os.path.getmtime(fpath)) / 60)
                if age_min > 120:
                    os.remove(fpath)
            except Exception:
                pass
    except Exception:
        pass


def _agent_completed_this_session(required_agent: str, agent_status_dir: str, now: float) -> bool:
    """The MOST RECENT fresh (< SESSION_TIMEOUT) agent-status file for required_agent
    reports DONE / DONE_WITH_CONCERNS.

    Picks the newest matching file by mtime so a later BLOCKED/NEEDS_CONTEXT review
    supersedes an earlier DONE (re-run safety). The filename written by
    status-writer.sh is ``<agent>-<ts>.json``, so an exact ``<agent>-`` prefix match
    avoids spurious hits from agent names that merely contain required_agent. Reads
    the structured ``status`` field (not a substring scan) and fails CLOSED (keeps
    the block) on any read/parse error. Mirrors orchestrate-dispatch.py
    cmd_recent_status.
    """
    if not os.path.isdir(agent_status_dir):
        return False
    prefix = required_agent + '-'
    newest_path = None
    newest_mtime = -1.0
    for fname in os.listdir(agent_status_dir):
        if not fname.startswith(prefix):
            continue
        fpath = os.path.join(agent_status_dir, fname)
        try:
            mtime = os.path.getmtime(fpath)
        except OSError:
            continue
        if now - mtime >= SESSION_TIMEOUT:
            continue
        if mtime > newest_mtime:
            newest_mtime = mtime
            newest_path = fpath
    if newest_path is None:
        return False
    try:
        with open(newest_path) as f:
            data = json.load(f)
    except (OSError, ValueError):
        return False
    return data.get('status') in ('DONE', 'DONE_WITH_CONCERNS')


def _policy_evaluate(file_path: str):
    """Evaluate config/policies.json against file_path. Returns (exit_code, message_or_None).

    Mirrors the inline policy engine: a `block`-severity policy whose path_pattern
    matches AND whose required_agent has NOT completed this session → (2, msg).
    CAST_POLICY_OVERRIDE=1 bypasses block policies (audit-logged). `warn` policies
    allow silently (the original routed warns to a suppressed stream).
    """
    override = os.environ.get('CAST_POLICY_OVERRIDE', '0') == '1'
    session_id = os.environ.get('CLAUDE_SESSION_ID', 'default')

    policies_path = os.path.join(os.getcwd(), 'config', 'policies.json')
    if not os.path.exists(policies_path):
        policies_path = os.path.expanduser('~/.claude/config/policies.json')
    if not os.path.exists(policies_path):
        return 0, None
    try:
        with open(policies_path) as f:
            config = json.load(f)
    except Exception:
        return 0, None

    agent_status_dir = os.path.expanduser('~/.claude/agent-status')
    now = datetime.datetime.now(datetime.timezone.utc).timestamp()

    for policy in config.get('policies', []):
        pattern = policy.get('path_pattern', '')
        if not pattern:
            continue
        try:
            if not re.search(pattern, file_path, re.IGNORECASE):
                continue
        except re.error:
            continue

        policy_id = policy.get('id', 'unknown')
        required_agent = policy.get('requires_agent', '')
        severity = policy.get('severity', 'warn')
        description = policy.get('description', '')

        if not required_agent:
            continue
        if _agent_completed_this_session(required_agent, agent_status_dir, now):
            continue

        if severity == 'block':
            if override:
                _audit_policy_override(policy_id, file_path, session_id)
                return 0, None
            msg = (
                f'**[CAST-POLICY-BLOCK]** Policy "{policy_id}" blocks this edit.\n'
                f'Reason: {description}\n'
                f'Required: Dispatch the `{required_agent}` agent before editing `{file_path}`.\n'
                f'Escape hatch: Set CAST_POLICY_OVERRIDE=1 to bypass (document your reason).'
            )
            return 2, msg
        # severity == warn → allow silently (faithful to the original's suppressed warn stream)
    return 0, None


def _audit_policy_override(policy_id: str, file_path: str, session_id: str) -> None:
    try:
        audit_path = os.path.expanduser('~/.claude/logs/audit.jsonl')
        os.makedirs(os.path.dirname(audit_path), exist_ok=True)
        event = {
            'timestamp': datetime.datetime.now(datetime.timezone.utc)
            .isoformat().replace('+00:00', 'Z'),
            'event': 'POLICY_OVERRIDE',
            'policy_id': policy_id,
            'file_path': file_path,
            'session_id': session_id,
            'override_env': 'CAST_POLICY_OVERRIDE',
        }
        with open(audit_path, 'a') as af:
            af.write(json.dumps(event) + '\n')
    except Exception:
        pass


# --------------------------------------------------------------------------
# Bash: git commit / push / stash guards
# --------------------------------------------------------------------------
def _git_evaluate(command: str):
    """Evaluate the FIRST LINE of a Bash command for git commit/push/stash.

    First-line-only scan prevents a multiline escape-hatch on line 2 from
    unblocking a git command on line 1. Returns (exit_code, message_or_None).
    """
    first_line = command.split('\n', 1)[0]

    if _COMMIT_ALLOW.search(first_line):
        return 0, None
    if _COMMIT_BLOCK.search(first_line):
        return 2, _COMMIT_MSG
    if _PUSH_ALLOW.search(first_line):
        return 0, None
    if _PUSH_BLOCK.search(first_line):
        return 2, _PUSH_MSG
    if _STASH_ALLOW.search(first_line):
        return 0, None
    if _STASH_BLOCK.search(first_line):
        return 2, _STASH_MSG
    return 0, None


# --------------------------------------------------------------------------
# Top-level evaluation (importable by the dispatcher)
# --------------------------------------------------------------------------
def evaluate(tool_name: str, tool_input: dict):
    """Return (exit_code, message). 0 = allow, 2 = block (message is the block reason).

    Never raises — internal errors fail-open to (0, '')."""
    try:
        if not isinstance(tool_input, dict):
            tool_input = {}
        if tool_name in ('Write', 'Edit'):
            file_path = tool_input.get('file_path', tool_input.get('path', '')) or ''
            if file_path:
                _ttl_sweep_agent_status()
                code, msg = _policy_evaluate(file_path)
                if code == 2:
                    return 2, msg
            return 0, ''
        if tool_name != 'Bash':
            return 0, ''
        command = tool_input.get('command', '') or ''
        code, msg = _git_evaluate(command)
        return (code, msg or '') if code == 2 else (0, '')
    except Exception:
        return 0, ''


def main() -> int:
    if os.environ.get('CLAUDE_SUBPROCESS', '0') == '1':
        return 0
    try:
        raw = sys.stdin.read()
    except Exception:
        return 0
    if not raw.strip():
        return 0
    try:
        data = json.loads(raw)
    except Exception:
        return 0
    if not isinstance(data, dict):
        return 0

    tool_name = data.get('tool_name', '') or ''
    tool_input = data.get('tool_input', {}) or {}
    code, msg = evaluate(tool_name, tool_input)
    if code == 2:
        if msg:
            print(msg, file=sys.stderr)
        return 2
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except SystemExit:
        raise
    except Exception:
        sys.exit(0)

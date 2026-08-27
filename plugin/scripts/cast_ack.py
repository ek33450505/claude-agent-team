#!/usr/bin/env python3
"""CAST escape-hatch acknowledgment recorder (CAST v10 I-3a, part 1).

CAST has ~19 hand-rolled escape hatches (CAST_COMMIT_AGENT=1, CAST_PUSH_OK=1,
etc.) and none of them record their use anywhere. This module gives every
hatch ONE call to make its use visible in cast.db, so `cast ask` can answer
"who bypassed which gate, when, and why."

Design contract (Ed, 2026-08-24):
  - Accept ANY non-empty value, including a bare "=1". Do NOT require a
    human-readable reason — existing "=1" callers must keep working exactly
    as before, with no new failure mode.
  - When the value carries no reason (bare "1"/"true"/"yes", case-
    insensitive), record has_reason=0 and print ONE line to stderr nudging
    the caller toward a reason next time. Never block on it.
  - Recording is best-effort and MUST NEVER change whether a gate passes,
    and MUST NEVER crash the calling hook pipeline. Every path that can
    raise is caught; the CLI entrypoint always exits 0.

This part builds the primitive + schema + tests only. Wiring the 19 callers
is a separate unit — nothing in this file is invoked by any hook yet.

CLI usage (the primary consumer — bash hooks call this directly):
    python3 scripts/cast_ack.py <VARIABLE_NAME> [--value <v>] [--script <name>]

Library usage:
    from cast_ack import record_ack
    record_ack('CAST_COMMIT_AGENT')                  # reads env itself
    record_ack('CAST_PUSH_OK', script='cast-push.sh')
"""
import datetime
import os
import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
try:
    from cast_db import db_write
except Exception:
    db_write = None

_CONTROL_CHARS_RE = re.compile(r'[\x00-\x1f\x7f]')
_MAX_VALUE_LEN = 500
# Values that count as "used the hatch but gave no reason" — bare `=1` plus
# the common truthy spellings a caller might use instead.
_BARE_VALUES = {'1', 'true', 'yes'}


def _log_error(msg: str) -> None:
    """Best-effort error log. Never raises — a logging failure must not
    surface as a cast_ack failure."""
    try:
        log_path = Path.home() / '.claude' / 'logs' / 'hook-errors.log'
        log_path.parent.mkdir(parents=True, exist_ok=True)
        ts = datetime.datetime.now(datetime.timezone.utc).isoformat().replace('+00:00', 'Z')
        with open(log_path, 'a') as f:
            f.write(f'[{ts}] ERROR cast_ack.py: {msg}\n')
    except Exception:
        pass


def _git(*args):
    """Run `git <args>` and return stripped stdout, or None on any failure
    (not a repo, git missing, timeout). 5s timeout so a hung git can never
    hang the calling hook."""
    try:
        result = subprocess.run(
            ['git', *args],
            capture_output=True,
            text=True,
            timeout=5,
        )
        if result.returncode != 0:
            return None
        value = result.stdout.strip()
        return value or None
    except Exception:
        return None


def _sanitize(value: str) -> str:
    """Strip ASCII control chars and cap length before storing."""
    cleaned = _CONTROL_CHARS_RE.sub('', value)
    return cleaned[:_MAX_VALUE_LEN]


def record_ack(variable: str, value: str = None, script: str = None) -> bool:
    """Record one escape-hatch use. Returns True if a row was written.

    value=None reads os.environ[variable]. Empty/unset -> no row, returns
    False (the hatch was not used). Never raises.
    """
    try:
        raw_value = value if value is not None else os.environ.get(variable, '')
        if not raw_value:
            return False

        stripped = raw_value.strip()
        has_reason = 0 if stripped.lower() in _BARE_VALUES else 1
        sanitized_value = _sanitize(raw_value)

        if has_reason == 0:
            print(
                f'[cast-ack] {variable} recorded without a reason. '
                f'Prefer {variable}="<why>" so the record explains the bypass.',
                file=sys.stderr,
            )

        if db_write is None:
            return False

        git_sha = _git('rev-parse', 'HEAD')
        repo_root = _git('rev-parse', '--show-toplevel')
        repo = os.path.basename(repo_root) if repo_root else None
        session_id = (
            os.environ.get('CLAUDE_SESSION_ID')
            or os.environ.get('CAST_SESSION_ID')
            or None
        )

        payload = {
            'variable': variable,
            'value': sanitized_value,
            'has_reason': has_reason,
            'script': script,
            'git_sha': git_sha,
            'session_id': session_id,
            'repo': repo,
        }
        return bool(db_write('ack_events', payload))
    except Exception as e:
        _log_error(f'record_ack failed for {variable}: {e}')
        return False


def main(argv) -> int:
    """CLI entrypoint. ALWAYS returns 0 — recording an escape-hatch use must
    never be able to fail a hook pipeline, regardless of outcome."""
    try:
        if not argv:
            return 0
        variable = argv[0]
        script = None
        value = None
        i = 1
        while i < len(argv):
            if argv[i] == '--script' and i + 1 < len(argv):
                script = argv[i + 1]
                i += 2
            elif argv[i] == '--value' and i + 1 < len(argv):
                value = argv[i + 1]
                i += 2
            else:
                i += 1
        record_ack(variable, value=value, script=script)
    except Exception as e:
        _log_error(f'CLI main failed: {e}')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))

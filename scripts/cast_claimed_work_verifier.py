#!/usr/bin/env python3
"""Verify agent-claimed file writes against filesystem reality.

Reads an agent's Work Log output and extracts claimed file paths,
then verifies they were actually written/modified during the agent run.

This is Category 1 of the hallucination audit: observability-only guard
(v1 never blocks; v2 escalation TBD).

Exit: always 0 (non-blocking)
Env input:
  - CAST_STOP_RESPONSE_TEXT: agent output text
  - CAST_AGENT_NAME: agent type (e.g., 'backend-writer')
  - CAST_SESSION_ID: session ID
  - CAST_AGENT_START_TIME: ISO8601 timestamp when agent started
  - CAST_REPO_ROOT: repo root for relative path resolution (default cwd)
  - CAST_DB_PATH: path to cast.db (default ~/.claude/cast.db)

Output: summary line to stderr, detailed findings to stderr
"""

import os
import sys
import re
import sqlite3
import subprocess
from datetime import datetime, timezone

# Prose tokens that match the "known-extension" path filter (they end in
# '.js') but are framework/library names, never real file paths in this
# codebase's context. Excluded case-insensitively in extract_file_paths().
_PROSE_FALSE_POSITIVES = {
    'next.js', 'vue.js', 'nuxt.js', 'ember.js', 'node.js', 'express.js',
    'chart.js', 'three.js', 'd3.js', 'backbone.js', 'react.js', 'angular.js',
}

def parse_iso_timestamp(ts_str: str) -> float:
    """Parse ISO8601 to Unix timestamp. Return 0 on failure."""
    if not ts_str:
        return 0.0
    try:
        # Normalize 'Z' to '+00:00' to preserve UTC offset (not strip it)
        ts_str = ts_str.replace('Z', '+00:00')
        dt = datetime.fromisoformat(ts_str)
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return dt.timestamp()
    except Exception:
        return 0.0

def extract_file_paths(response_text: str) -> list:
    """Extract claimed file paths from agent output.

    Patterns (only 1 and 2 are active — 3 and 4 were dropped because they
    extract paths the agent only read/referenced, flooding [PRE_EXISTING] rows):
    1. Files changed: section followed by file list
    2. files_changed: array in JSON status block
    """
    paths = set()

    # Pattern 1: Files changed: section (markdown)
    m = re.search(r'(?:Files changed|files_changed)\s*:\s*([\s\S]+?)(?=\n\n|$)', response_text)
    if m:
        section = m.group(1)
        # Extract paths from the section (dash list, comma list, or paths)
        path_matches = re.findall(r'(?:^|\s)[-*]?\s*(/[a-zA-Z0-9_./\-]+\.[a-zA-Z0-9]+)\b', section, re.MULTILINE)
        paths.update(path_matches)
        # Also try relative paths (no leading slash)
        path_matches = re.findall(r'(?:^|\s)[-*]?\s*([a-zA-Z0-9_][a-zA-Z0-9_./\-]*\.[a-zA-Z0-9]+)\b', section, re.MULTILINE)
        paths.update(
            p for p in path_matches
            if p.lower() not in _PROSE_FALSE_POSITIVES
            and ('/' in p or p.endswith(('.sh', '.py', '.md', '.yml', '.yaml', '.json', '.bats', '.ts', '.js', '.rb')))
        )

    # Pattern 2: files_changed array in JSON status block
    json_match = re.search(r'```json\s+status[\s\S]*?"files_changed"\s*:\s*\[([\s\S]*?)\]', response_text)
    if json_match:
        array_text = json_match.group(1)
        json_paths = re.findall(r'"([^"]+\.[a-zA-Z0-9]+)"', array_text)
        paths.update(json_paths)

    # Patterns 3 and 4 (prose verbs + backtick paths) are intentionally omitted.
    # They extracted paths the agent only read, not wrote, flooding [PRE_EXISTING] rows.
    # See: cast.db hygiene plan 2026-05-15, Task 1.1.

    return list(paths)

def _resolve_basename_via_git(repo_root: str, path: str, agent_start_time_unix: float) -> str:
    """Fallback: resolve basename against git-tracked files when exact path not found.

    Agents frequently list files_changed by BASENAME only (e.g. 'cast-litestream-setup.sh')
    while the file lives in a subdirectory ('scripts/cast-litestream-setup.sh'). This caused
    ~46 of 73 false [NOT FOUND] WARNs (2026-06-12 triage, Bucket A).

    Strategy:
      1. Run `git -C <repo_root> ls-files` to get all tracked paths.
      2. Match any tracked path that equals <path> OR ends with '/<basename-of-path>'.
      3. If one or more match, apply mtime logic to the most-recently-modified match.
      4. If none match, return '[NOT FOUND]' (genuine — preserves true-positive detection).

    Non-fatal: any subprocess/git error falls back to '[NOT FOUND]'.
    """
    basename = os.path.basename(path)
    if not basename:
        return '[NOT FOUND]'

    try:
        result = subprocess.run(
            ['git', '-C', repo_root, 'ls-files'],
            capture_output=True,
            text=True,
            timeout=10
        )
        if result.returncode != 0:
            return '[NOT FOUND]'

        tracked_files = result.stdout.splitlines()

        # Match: exact path OR any tracked file whose basename equals the claimed basename
        matches = [f for f in tracked_files if f == path or f.endswith('/' + basename)]

        if not matches:
            return '[NOT FOUND]'

        # Pick the most-recently-modified match and apply the existing mtime logic
        best_mtime = -1.0
        for match in matches:
            full_match_path = os.path.join(repo_root, match)
            try:
                mtime = os.path.getmtime(full_match_path)
                if mtime > best_mtime:
                    best_mtime = mtime
            except Exception:
                continue

        if best_mtime < 0:
            return '[NOT FOUND]'

        if agent_start_time_unix > 0 and best_mtime < agent_start_time_unix:
            return '[PRE_EXISTING]'
        return '[VERIFIED]'

    except Exception:
        return '[NOT FOUND]'


def verify_file(repo_root: str, path: str, agent_start_time_unix: float) -> str:
    """Verify if file exists and was modified after agent start time.

    Returns: '[VERIFIED]', '[NOT FOUND]', or '[PRE_EXISTING]'
    """
    # Resolve path relative to repo root
    if path.startswith('/'):
        full_path = path
    else:
        full_path = os.path.join(repo_root, path)

    try:
        full_path = os.path.abspath(full_path)
    except Exception:
        return '[NOT FOUND]'

    if not os.path.exists(full_path):
        # Exact path not found — fallback: resolve basename against git-tracked files
        return _resolve_basename_via_git(repo_root, path, agent_start_time_unix)

    # File exists — check mtime
    try:
        mtime = os.path.getmtime(full_path)
        if agent_start_time_unix > 0 and mtime < agent_start_time_unix:
            return '[PRE_EXISTING]'
        return '[VERIFIED]'
    except Exception:
        return '[NOT FOUND]'

def write_hallucination_record(db_path: str, session_id: str, agent_name: str,
                                claim_type: str, claimed_value: str, actual_value: str) -> None:
    """Write a hallucination record to cast.db agent_hallucinations table.

    Write-gate: INSERT when actual_value is '[NOT FOUND]' (genuine hallucination,
    verified=0) OR '[VERIFIED]' (confirmed claim, verified=1). [PRE_EXISTING] is
    still skipped as noise — it means the claimed file/value already existed before
    the agent run and carries no signal.
    See: cast.db hygiene plan 2026-05-15, Task 1.1.

    One-time cleanup (review before executing — DO NOT automate):
      DELETE FROM agent_hallucinations WHERE actual_value = '[PRE_EXISTING]';
      -- Expected: ~2,767 rows. Verify count before committing.
    """
    if actual_value not in ('[NOT FOUND]', '[VERIFIED]'):
        return  # write-gate: skip [PRE_EXISTING] noise; record hallucinations AND confirmations

    if not db_path or not os.path.exists(db_path):
        return

    try:
        conn = sqlite3.connect(db_path, timeout=5)
        cur = conn.cursor()

        # Ensure table exists
        cur.execute('''
            CREATE TABLE IF NOT EXISTS agent_hallucinations (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                session_id TEXT,
                agent_name TEXT NOT NULL,
                claim_type TEXT NOT NULL,
                claimed_value TEXT,
                actual_value TEXT,
                verified INTEGER DEFAULT 0,
                timestamp TEXT
            )
        ''')

        # Determine verified status
        verified = 1 if actual_value == '[VERIFIED]' else 0

        ts = datetime.now(timezone.utc).isoformat().replace('+00:00', 'Z')

        cur.execute(
            'INSERT INTO agent_hallucinations (session_id, agent_name, claim_type, claimed_value, actual_value, verified, timestamp) '
            'VALUES (?, ?, ?, ?, ?, ?, ?)',
            (session_id or '', agent_name or 'unknown', claim_type, claimed_value, actual_value, verified, ts)
        )
        conn.commit()
        conn.close()
    except Exception:
        pass  # Non-fatal: DB write failure doesn't block the hook

def main():
    """Main entry point."""
    response_text = os.environ.get('CAST_STOP_RESPONSE_TEXT', '')
    agent_name = os.environ.get('CAST_AGENT_NAME', 'unknown')
    session_id = os.environ.get('CAST_SESSION_ID', '')
    agent_start_time_str = os.environ.get('CAST_AGENT_START_TIME', '')
    repo_root = os.environ.get('CAST_REPO_ROOT', os.getcwd())
    db_path = os.path.expanduser(os.environ.get('CAST_DB_PATH', '~/.claude/cast.db'))

    # F12 guard (2026-06-13): skip commit agent entirely — it stages files via
    # `git add`/`git commit`, never via the Write tool. Parsing its staged-file
    # inventory for "claimed file writes" produces 100% false positives.
    # Triage source: reports/2026-06-12-honesty-warn-triage.md (Bucket A, 27/73).
    if (os.environ.get('CAST_AGENT_NAME') or '').strip().lower() == 'commit':
        sys.exit(0)

    # If no response text, exit silently
    if not response_text or len(response_text.strip()) < 50:
        sys.exit(0)

    # Parse agent start time
    agent_start_time_unix = parse_iso_timestamp(agent_start_time_str)

    # Extract claimed file paths
    paths = extract_file_paths(response_text)

    if not paths:
        # No file claims found
        sys.exit(0)

    # Verify each path
    results = {}
    for path in paths:
        result = verify_file(repo_root, path, agent_start_time_unix)
        results[path] = result
        write_hallucination_record(db_path, session_id, agent_name, 'file_write', path, result)

    # Emit summary to stderr
    verified_count = sum(1 for r in results.values() if r == '[VERIFIED]')
    not_found_count = sum(1 for r in results.values() if r == '[NOT FOUND]')
    pre_existing_count = sum(1 for r in results.values() if r == '[PRE_EXISTING]')

    summary = f'[CAST-VERIFY] agent={agent_name} files_claimed={len(results)} verified={verified_count} not_found={not_found_count} pre_existing={pre_existing_count}'
    print(summary, file=sys.stderr)

    # Print details for any issues
    for path, result in sorted(results.items()):
        if result != '[VERIFIED]':
            print(f'[CAST-VERIFY] {result} {path}', file=sys.stderr)

    sys.exit(0)

if __name__ == '__main__':
    main()

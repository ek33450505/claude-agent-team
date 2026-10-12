#!/usr/bin/env bash
# cast-subagent-worktree-check.sh — SubagentStop hook
#
# Detects unexpected agent worktrees after backend-writer / frontend-writer / debugger / test-writer /
# security / frontend-qa dispatches. DETECT-ONLY: it never deletes, prunes or moves anything.
# Clean ones get an informational banner, dirty ones an escalation banner; both are logged to the
# cast.db worktree_anomalies table. Always exits 0.
# A repeat of the SAME (worktree_path, state, reason) is suppressed (no row, no banner) for 24 h so a
# known leftover is reported once, then at most daily; a changed reason/state reports immediately.
# Known limits (accepted): the lookup-then-insert is not atomic (two concurrent stops can both report);
# worktree_path is unindexed (fine at the table's size).
#
# Why detect-only (security, 2026-10-04): this hook runs OUTSIDE the sandbox after every agent stop,
# with cwd = the project, which the agent can write. `git worktree prune` / `worktree remove` follow
# an agent-planted symlink `.git/worktrees/<id> -> <victim dir>` (no gitdir file) and EMPTY the
# victim. So this hook must not run either, ever. Cleanup is the hardened groomer's job
# (`cast clean --apply --worktrees`); Claude Code also auto-cleans unchanged isolation worktrees.
#
# ALL git goes through cast_git_safe (scripts/cast_git_safe.py, which sources scripts/cast-hook-lib.sh),
# neutralising the repo-config exec paths (fsmonitor, filters, hooks, gpg, lazy fetch...). The bash side
# runs no git at all: repo discovery happens in the python block, under one shared deadline, because a
# FIFO planted at .git/config can otherwise hang git indefinitely.
#
# Everything the agent controls (worktree path, agent id) is escaped + capped before it reaches the
# banner or the DB, and a registered path must resolve to exactly <repo>/.claude/worktrees/agent-*.

[[ "${CLAUDE_SUBPROCESS:-}" == "1" ]] && exit 0

set -euo pipefail

INPUT="$(cat 2>/dev/null || true)"
# NB: INPUT is deliberately NOT exported — a huge agent payload in the environment makes every later
# exec fail with E2BIG (single env string limit is 128 KiB on Linux).

_log_error() {
  mkdir -p "$HOME/.claude/logs" 2>/dev/null || true
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] cast-subagent-worktree-check: $1" \
    >> "$HOME/.claude/logs/hook-errors.log" 2>/dev/null || true
}

# agent_id: accept only a non-empty str; cap at 4096 chars at the source (the DB/banner caps are
# tighter). Written as bytes with backslashreplace so a lone surrogate can never raise.
AGENT_ID="$(printf '%s' "$INPUT" | python3 -I -c 'import sys,json
try:
    d = json.loads(sys.stdin.read() or "{}")
    a = (d.get("agent_id") or d.get("subagent_id")) if isinstance(d, dict) else None
    if not isinstance(a, str) or not a:
        a = "unknown"
    sys.stdout.buffer.write(a[:4096].encode("utf-8", "backslashreplace"))
except Exception:
    sys.stdout.write("unknown")
' 2>/dev/null || echo unknown)"

# Resolve this script's directory ONCE, absolutely: a relative $0 must never resolve the python
# helper against the agent-writable cwd.
_DIR="$(cd -- "$(dirname -- "$0")" 2>/dev/null && pwd -P)" || _DIR=""
if [[ -z "$_DIR" ]]; then
  _log_error "cannot resolve script directory from $0; git not run"
  exit 0
fi

DB_PATH="${CAST_DB_PATH:-$HOME/.claude/cast.db}"

python3 -I - "$AGENT_ID" "$DB_PATH" "$_DIR" <<'PYEOF' || _log_error "worktree scan failed"
import importlib.util
import json
import os
import sqlite3
import subprocess
import sys
import time
import unicodedata
from datetime import datetime, timedelta, timezone
from pathlib import Path

agent_id, db_path, script_dir = sys.argv[1], sys.argv[2], sys.argv[3]

# Load the hardened git wrapper by explicit path (no sys.path edit; -I already drops cwd).
sys.dont_write_bytecode = True
_mod_path = os.path.join(script_dir, 'cast_git_safe.py')
try:
    _spec = importlib.util.spec_from_file_location('cast_git_safe', _mod_path)
    cast_git_safe = importlib.util.module_from_spec(_spec)
    _spec.loader.exec_module(cast_git_safe)
except Exception as e:
    print(f'cast_git_safe unavailable ({_mod_path}): {e}; git not run', file=sys.stderr)
    sys.exit(1)

# One shared deadline for every git call. Budget: 10 s hook timeout - ~2-4 s python start-up + DB write.
DEADLINE = time.monotonic() + 6.0
PER_CALL = 6.0


def git(cwd, *args):
    remaining = DEADLINE - time.monotonic()
    if remaining <= 0.05:
        return subprocess.CompletedProcess(list(args), 124, stdout='', stderr='deadline exceeded')
    return cast_git_safe.run(cwd, list(args), timeout=min(PER_CALL, remaining))


# Characters that must never reach a terminal or a log viewer raw: controls (Cc), format incl. bidi
# overrides and zero-width (Cf), line/paragraph separators (Zl/Zp), surrogates (Cs).
_BAD_CATS = frozenset({'Cc', 'Cf', 'Zl', 'Zp', 'Cs'})


def _is_bad(ch):
    return unicodedata.category(ch) in _BAD_CATS


def banner_text(s, cap=300):
    """Printable single-line text for the terminal banner: bad chars -> '?', capped."""
    return ''.join('?' if _is_bad(ch) else ch for ch in str(s))[:cap]


# Backslash is escaped too, so the mapping is injective (a real newline -> `\n`, a literal `\n` -> `\\n`).
# The stored path is the dedupe key; rows written before this encoding keep the old one, so each
# leftover path is re-reported once after an upgrade (accepted).
_ESC = {'\\': '\\\\', '\n': '\\n', '\r': '\\r', '\t': '\\t'}


def db_text(s, cap=1024):
    """Readable, mostly reversible escaping for DB storage (\\n, \\x1b, \\u202e, ...), capped at
    `cap` chars with a visible `…[+N]` truncation marker."""
    out = []
    for ch in str(s):
        if ch in _ESC:
            out.append(_ESC[ch])
        elif _is_bad(ch):
            o = ord(ch)
            out.append(f'\\x{o:02x}' if o < 0x100 else f'\\u{o:04x}' if o < 0x10000 else f'\\U{o:08x}')
        else:
            out.append(ch)
    text = ''.join(out)
    if len(text) <= cap:
        return text
    keep = max(cap - 16, 0)
    return f'{text[:keep]}…[+{len(text) - keep}]'


def emit(line):
    sys.stdout.buffer.write((line + '\n').encode('utf-8', 'replace'))
    sys.stdout.buffer.flush()


# A leftover worktree already reported with the same state + reason is not re-reported inside this window.
DEDUPE_WINDOW = timedelta(hours=24)


def _parse_utc(ts):
    """cast.db timestamps are mixed (`...Z`, `+00:00`, naive): normalise to aware UTC."""
    t = str(ts).strip()
    if t.endswith(('Z', 'z')):
        t = t[:-1] + '+00:00'
    dt = datetime.fromisoformat(t)
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc)


def already_reported(conn, wt_db, state, reason, now):
    """True only when the newest row for this path has the same state + reason and is < DEDUPE_WINDOW old.
    Any query/parse error -> False (fail toward reporting, never toward silence)."""
    try:
        prev = conn.execute(
            'SELECT state, reason, detected_at FROM worktree_anomalies WHERE worktree_path=? ORDER BY id DESC LIMIT 1',
            (wt_db,)
        ).fetchone()
        if prev is None or prev[0] != state or prev[1] != reason:
            return False
        age = now - _parse_utc(prev[2])
        return timedelta(0) <= age < DEDUPE_WINDOW
    except Exception:
        return False


# --- repo discovery (no git outside cast_git_safe, bounded by DEADLINE) ---
try:
    cwd = os.getcwd()
except OSError:
    sys.exit(0)
rp = git(cwd, 'rev-parse', '--show-toplevel')
if rp.returncode in (3, 124):
    print(f'repo discovery failed (rc={rp.returncode}); git not run / timed out', file=sys.stderr)
    sys.exit(1)
if rp.returncode != 0:
    sys.exit(0)  # not a repo (or unknown): skip the scan
repo_root = rp.stdout.rstrip('\n')
if not repo_root:
    sys.exit(0)

now_iso = datetime.now(timezone.utc).isoformat().replace('+00:00', 'Z')

# Ensure DB + table exist (idempotent)
Path(db_path).parent.mkdir(parents=True, exist_ok=True)
conn = sqlite3.connect(db_path, timeout=5)
conn.execute("""
    CREATE TABLE IF NOT EXISTS worktree_anomalies (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        agent_id TEXT,
        worktree_path TEXT,
        detected_at TEXT,
        repo_root TEXT,
        state TEXT,
        reason TEXT
    )
""")
conn.commit()


# Parse `git worktree list --porcelain -z`: NUL-separated attribute records; a `worktree <path>`
# record starts a block. Paths with spaces/newlines stay intact.
def parse_blocks(stdout, sep):
    blocks = []
    for rec in stdout.split(sep):
        if rec.startswith('worktree '):
            blocks.append({'path': rec[len('worktree '):], 'locked': False})
        elif blocks and (rec == 'locked' or rec.startswith('locked ')):
            blocks[-1]['locked'] = True
    return blocks


res = git(repo_root, 'worktree', 'list', '--porcelain', '-z')
if res.returncode == 0:
    blocks = parse_blocks(res.stdout, '\0')
elif res.returncode == 129:
    # usage error: this git predates `-z`; only then fall back to the line form
    res2 = git(repo_root, 'worktree', 'list', '--porcelain')
    if res2.returncode != 0:
        print(f'worktree list failed (rc={res2.returncode}); scan skipped', file=sys.stderr)
        sys.exit(0)
    blocks = parse_blocks(res2.stdout, '\n')
elif res.returncode == 124:
    print('worktree list timed out; scan skipped', file=sys.stderr)
    sys.exit(1)
else:
    print(f'worktree list failed (rc={res.returncode}); scan skipped', file=sys.stderr)
    sys.exit(0)

# A registered path must RESOLVE to exactly <realpath(repo)>/.claude/worktrees/agent-<x> (one level,
# no symlink or `..` escape); anything else is not ours to look at.
wt_base = os.path.join(os.path.realpath(repo_root), '.claude', 'worktrees')


def resolve_agent_worktree(path):
    real = os.path.realpath(path)
    parent, name = os.path.split(real)
    if parent != wt_base or not name.startswith('agent-') or not os.path.isdir(real):
        return None
    return real


for b in blocks:
    if b['locked']:
        continue
    wt = b['path']
    real = resolve_agent_worktree(wt)
    if real is None:
        continue

    # Clean = NOTHING changed (untracked files count as dirty) AND no commits ahead of
    # origin/main (or main if origin/main is missing). Any wrapper failure is "unknown" -> escalate.
    reason_bits = []

    st = git(real, 'status', '--porcelain', '--untracked-files=all')
    if st.returncode != 0:
        reason_bits.append(f'status unknown (rc={st.returncode})')
    else:
        changed = [ln for ln in st.stdout.split('\n') if ln]
        if changed:
            reason_bits.append(f'{len(changed)} changed/untracked files')

    if not reason_bits:
        ahead = None
        last_rc = None
        for upstream in ('origin/main', 'main'):
            ar = git(real, 'rev-list', '--count', 'HEAD', f'^{upstream}')
            last_rc = ar.returncode
            if ar.returncode == 0:
                try:
                    ahead = int((ar.stdout or '0').strip() or '0')
                except ValueError:
                    ahead = None
                    last_rc = 'unparsable'
                break
        if ahead is None:
            reason_bits.append(f'ahead count unknown (rc={last_rc})')
        elif ahead > 0:
            reason_bits.append(f'{ahead} commits ahead')

    safe_wt = banner_text(wt)
    safe_agent = banner_text(agent_id, 100)
    row = (db_text(agent_id), db_text(wt), now_iso, db_text(repo_root))
    now_dt = datetime.now(timezone.utc)
    if not reason_bits:
        clean_reason = 'clean and at upstream; detect-only, not removed'
        if already_reported(conn, row[1], 'clean-detected', clean_reason, now_dt):
            continue
        conn.execute(
            'INSERT INTO worktree_anomalies (agent_id, worktree_path, detected_at, repo_root, state, reason) VALUES (?,?,?,?,?,?)',
            row + ('clean-detected', clean_reason)
        )
        emit(f'ℹ AGENT-WORKTREE LEFT BEHIND (clean): {safe_wt} — remove with: cast clean --apply --worktrees (agent {safe_agent})')
    else:
        reason = '; '.join(reason_bits)
        if already_reported(conn, row[1], 'dirty-escalated', db_text(reason), now_dt):
            continue
        conn.execute(
            'INSERT INTO worktree_anomalies (agent_id, worktree_path, detected_at, repo_root, state, reason) VALUES (?,?,?,?,?,?)',
            row + ('dirty-escalated', db_text(reason))
        )
        emit(f'⚠ AGENT-WORKTREE DETECTED (DIRTY): {safe_agent} wrote to {safe_wt}; manual recovery required ({reason})')

conn.commit()
conn.close()
PYEOF

exit 0

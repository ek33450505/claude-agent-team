#!/usr/bin/env python3
"""cast-internals-canary: detect Claude Code shape drift in UNDOCUMENTED internals.

Purpose
-------
Two CAST trust mechanisms depend on shapes Claude Code does not document.
Both fail CLOSED, so when an update renames a key every push BLOCKs with an
unhelpful "identity unverifiable". This canary reads the same shapes and says
loudly "Claude Code shape drift: <code>" instead.

Shapes watched, and who consumes them
-------------------------------------
* Subagent sidecars  <home>/.claude/projects/*/*/subagents/agent-*.meta.json
  (and .../subagents/workflows/*/agent-*.meta.json): keys agentType,
  spawnDepth, teamName, taskKind.
    - scripts/cast_subagent_stop.py:401-503  (_roster_type_from_meta,
      _resolve_roster_type, _find_subagent_artifact; the teammate-spoof
      check at :431 relies on teamName and taskKind appearing together).
* COMMIT_HATCH_USED audit lines in <home>/.claude/logs/audit.jsonl: keys
  session_id, agent_type, agent_id, tool_use_id.
    - writer: scripts/cast-git-guard.py:3421-3466 (_hatch_identity)
    - consumer: scripts/cast-commit-reconcile.py:522-543 (D5b reconcile)
* cast.db agent_runs.agent_id (populated from the SubagentStop payload).

Checks (fixed vocabulary): SIDECAR_LAYOUT, SIDECAR_AGENTTYPE,
SIDECAR_SPAWNDEPTH, SIDECAR_UNPARSABLE (drift only at >= 3 files and > 5%),
TEAMMATE_MARKERS, TEAMMATE_CUSTOM_TYPE, HATCH_AGENT_ID, HATCH_KEYS,
PAYLOAD_AGENT_ID (drift) and SIDECAR_NEW_KEYS (info).

A "teammate" sidecar is one carrying ANY of taskKind, teamName,
customAgentType, color, planModeRequired, permissionMode. TEAMMATE_MARKERS
fires when a teammate lacks taskKind or teamName (the spoof check at
cast_subagent_stop.py:431 needs both); TEAMMATE_CUSTOM_TYPE fires when, with
>= 5 roster teammates, under half carry customAgentType (_roster_type_from_meta
fails closed without it). Roster teammates are teammates whose
spawnedAgentType is not a built-in type (general-purpose, Explore, ...), which
never carry customAgentType; a missing or non-string spawnedAgentType still
counts. PAYLOAD_AGENT_ID judges only the newest 20 in-window agent_runs rows,
so a payload rename surfaces quickly.

Usage:  cast-internals-canary.py [--json] [--home DIR] [--days N]   (N in 1..30)

Exit codes: 0 ok / no_data, 1 drift, 2 usage or internal error (under --json
also prints {"state": "error", "findings": []}).

Read-only; never prints values. Sidecars, hatch lines and db rows hold
personal content, so output is built only from fixed text, integers and key
names that match a strict identifier regex.
"""
import glob
import json
import os
import re
import sqlite3
import stat
import sys
import urllib.parse
from datetime import datetime, timedelta, timezone

SAMPLE_MAX = 300             # newest sidecars examined
SIDECAR_MAX_BYTES = 64 * 1024
HATCH_TAIL_BYTES = 2 * 1024 * 1024
HATCH_KEEP = 20
DEFAULT_DAYS = 7

KNOWN_KEYS = frozenset({
    "agentType", "description", "spawnDepth", "requestShape",
    "requestNonInteractive", "toolUseId", "name", "model", "taskKind",
    "teamName", "color", "planModeRequired", "permissionMode",
    "customAgentType", "spawnedAgentType", "worktreePath",
    "spawnedWithWorktree", "worktreeBranch", "parentAgentId", "workflowPhase",
    "isFork", "finished", "launchedWithDefaults",
})
# Built-in agent types never carry customAgentType. A teammate WITHOUT
# spawnedAgentType stays in the TEAMMATE_CUSTOM_TYPE denominator, so a rename
# of spawnedAgentType still alarms instead of going silent.
BUILTIN_AGENT_TYPES = frozenset({
    "general-purpose", "Explore", "Plan", "claude-code-guide", "statusline-setup",
})
# Only key names matching this are ever printed (fullmatch, so no newline slip).
SAFE_KEY_RE = re.compile(r"[A-Za-z][A-Za-z0-9_]{0,31}")
# A "teammate" sidecar carries any of these (they co-occur on teammates only).
TEAMMATE_KEYS = ("taskKind", "teamName", "customAgentType", "color",
                 "planModeRequired", "permissionMode")
RECENT_RUNS = 20             # newest agent_runs rows judged for PAYLOAD_AGENT_ID
UNPARSABLE_MIN = 3           # one mid-write sidecar must not alarm
MAX_DAYS = 30
HATCH_REQUIRED_KEYS = ("session_id", "agent_type", "agent_id")


def _nonempty_str(v):
    return isinstance(v, str) and v != ""


# --- input collection -------------------------------------------------------

def _list_sidecars(home, days, now):
    """Return (in_window_count, newest-first sampled paths)."""
    base = os.path.join(glob.escape(home), ".claude", "projects")
    pats = [
        os.path.join(base, "*", "*", "subagents", "agent-*.meta.json"),
        os.path.join(base, "*", "*", "subagents", "workflows", "*",
                     "agent-*.meta.json"),
    ]
    cutoff = now.timestamp() - days * 86400
    found = []
    for pat in pats:
        for p in glob.glob(pat):
            try:
                m = os.lstat(p).st_mtime  # lstat: a symlink is judged as itself
            except OSError:
                continue
            if m >= cutoff:
                found.append((m, p))
    found.sort(reverse=True)
    return len(found), [p for _, p in found[:SAMPLE_MAX]]


def _read_sidecar(path):
    """Parsed dict, or None when unreadable / symlink / oversize / not an object."""
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except OSError:
        return None
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode) or st.st_size > SIDECAR_MAX_BYTES:
            return None
        data = os.read(fd, SIDECAR_MAX_BYTES + 1)
    except OSError:
        return None
    finally:
        os.close(fd)
    if len(data) > SIDECAR_MAX_BYTES:
        return None
    try:
        obj = json.loads(data)
    except (ValueError, RecursionError):
        return None
    return obj if isinstance(obj, dict) else None


def collect_sidecars(home, days, now):
    in_window, paths = _list_sidecars(home, days, now)
    parsed, unparsable = [], 0
    for p in paths:
        obj = _read_sidecar(p)
        if obj is None:
            unparsable += 1
        else:
            parsed.append(obj)
    return in_window, len(paths), parsed, unparsable


def collect_hatch(home):
    """Newest <=20 COMMIT_HATCH_USED dicts with in_claude_session True."""
    path = os.path.join(home, ".claude", "logs", "audit.jsonl")
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except OSError:
        return []
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode):
            return []  # FIFO/device/etc: no hatch data (O_NONBLOCK keeps open() from hanging)
        size = st.st_size
        off = max(0, size - HATCH_TAIL_BYTES)
        os.lseek(fd, off, os.SEEK_SET)
        raw = b""
        while True:
            chunk = os.read(fd, 1 << 20)
            if not chunk:
                break
            raw += chunk
    except OSError:
        return []
    finally:
        os.close(fd)
    lines = raw.split(b"\n")
    if off > 0:
        lines = lines[1:]  # first line is likely cut mid-record
    kept = []
    for ln in lines:
        if b"COMMIT_HATCH_USED" not in ln:
            continue
        try:
            obj = json.loads(ln)
        except (ValueError, RecursionError):
            continue
        if (isinstance(obj, dict) and obj.get("event") == "COMMIT_HATCH_USED"
                and obj.get("in_claude_session") is True):
            kept.append(obj)
    return kept[-HATCH_KEEP:]


def query_db(db_path, now, days):
    """(rows, rows_with_agent_id, recent_n, recent_with) or None if unavailable.

    The first pair covers the whole window (SIDECAR_LAYOUT); the second covers
    only the newest RECENT_RUNS in-window rows by rowid, so a rename shows up
    within a day rather than lagging by half the window (PAYLOAD_AGENT_ID).
    """
    cutoff = (now - timedelta(days=days)).strftime("%Y-%m-%dT%H:%M:%SZ")
    # A FIFO at the db path would hang sqlite3.connect forever, so require a
    # regular file first (os.stat follows symlinks: a symlinked db is fine).
    # The stat->open race is accepted for an advisory canary.
    try:
        if not stat.S_ISREG(os.stat(db_path).st_mode):
            return None
    except OSError:
        return None
    uri = "file:" + urllib.parse.quote(db_path) + "?mode=ro"
    try:
        con = sqlite3.connect(uri, uri=True, timeout=1)
        try:
            row = con.execute(
                "SELECT COUNT(*), SUM(agent_id IS NOT NULL AND agent_id != '') "
                "FROM agent_runs WHERE started_at >= ?", (cutoff,)).fetchone()
            rec = con.execute(
                "SELECT COUNT(*), SUM(agent_id IS NOT NULL AND agent_id != '') "
                "FROM (SELECT agent_id FROM agent_runs WHERE started_at >= ? "
                "ORDER BY rowid DESC LIMIT ?)", (cutoff, RECENT_RUNS)).fetchone()
        finally:
            con.close()
    except sqlite3.Error:
        return None
    return int(row[0] or 0), int(row[1] or 0), int(rec[0] or 0), int(rec[1] or 0)


# --- evaluation -------------------------------------------------------------

def evaluate(in_window, n_sampled, parsed, unparsable, hatch, db):
    """Return (state, findings). Details use fixed text + ints + safe key names."""
    f = []

    def add(code, sev, detail):
        f.append({"code": code, "severity": sev, "detail": detail})

    db_rows, db_with, rec_n, rec_with = db if db else (0, 0, 0, 0)

    if in_window == 0 and db_rows and db_with >= 5:
        add("SIDECAR_LAYOUT", "drift",
            f"subagent runs recorded ({db_with}) but no sidecars found at the "
            "expected path")

    bad_type = sum(1 for s in parsed if not _nonempty_str(s.get("agentType")))
    if bad_type:
        add("SIDECAR_AGENTTYPE", "drift",
            f"{bad_type} of {len(parsed)} sidecars lack a usable agentType")

    if len(parsed) >= 10:
        depth_ok = sum(1 for s in parsed
                       if isinstance(s.get("spawnDepth"), int)
                       and not isinstance(s.get("spawnDepth"), bool))
        if depth_ok / len(parsed) < 0.95:
            add("SIDECAR_SPAWNDEPTH", "drift",
                f"only {depth_ok} of {len(parsed)} sidecars carry an int spawnDepth")

    if unparsable:
        if (unparsable >= UNPARSABLE_MIN and n_sampled >= 10
                and unparsable / n_sampled > 0.05):
            add("SIDECAR_UNPARSABLE", "drift",
                f"{unparsable} of {n_sampled} sampled sidecars unparsable")
        else:
            add("SIDECAR_UNPARSABLE", "info",
                f"{unparsable} of {n_sampled} sampled sidecars unparsable")

    mates = [s for s in parsed if any(k in s for k in TEAMMATE_KEYS)]
    n_unpaired = sum(1 for s in mates if "taskKind" not in s or "teamName" not in s)
    if n_unpaired:
        add("TEAMMATE_MARKERS", "drift",
            f"{n_unpaired} of {len(mates)} teammate sidecars lack taskKind or teamName")

    # isinstance guard: a list/dict value is unhashable and would raise on the lookup
    roster = [s for s in mates
              if not (isinstance(s.get("spawnedAgentType"), str)
                      and s["spawnedAgentType"] in BUILTIN_AGENT_TYPES)]
    if len(roster) >= 5:
        n_ct = sum(1 for s in roster if _nonempty_str(s.get("customAgentType")))
        if n_ct / len(roster) < 0.5:
            add("TEAMMATE_CUSTOM_TYPE", "drift",
                f"only {n_ct} of {len(roster)} roster teammate sidecars carry customAgentType")

    n_hatch_noid = sum(1 for h in hatch
                       if _nonempty_str(h.get("agent_type"))
                       and not _nonempty_str(h.get("agent_id")))
    if n_hatch_noid:
        add("HATCH_AGENT_ID", "drift",
            f"{n_hatch_noid} of {len(hatch)} hatch lines have agent_type but no agent_id")

    n_hatch_keys = sum(1 for h in hatch
                       if any(k not in h for k in HATCH_REQUIRED_KEYS))
    if n_hatch_keys:
        add("HATCH_KEYS", "drift",
            f"{n_hatch_keys} of {len(hatch)} hatch lines miss a required key")

    if rec_n >= 10 and rec_with / rec_n < 0.5:
        add("PAYLOAD_AGENT_ID", "drift",
            f"only {rec_with} of the newest {rec_n} agent_runs rows carry an agent_id")

    seen = set()
    for s in parsed:
        seen.update(k for k in s if isinstance(k, str) and k not in KNOWN_KEYS)
    if seen:
        safe = sorted(k for k in seen if SAFE_KEY_RE.fullmatch(k))
        unprintable = len(seen) - len(safe)
        detail = f"{len(seen)} unknown sidecar keys"
        if safe:
            detail += ": " + ",".join(safe[:10])
        if unprintable:
            detail += f" ({unprintable} unprintable)"
        add("SIDECAR_NEW_KEYS", "info", detail)

    if any(x["severity"] == "drift" for x in f):
        state = "drift"
    elif n_sampled == 0 and not hatch and db_rows == 0:
        state = "no_data"
    else:
        state = "ok"
    return state, f


# --- CLI --------------------------------------------------------------------

USAGE = "usage: cast-internals-canary.py [--json] [--home DIR] [--days N]"


def _parse_args(argv):
    opts = {"json": False, "home": None, "days": DEFAULT_DAYS}
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--json":
            opts["json"] = True
        elif a in ("--home", "--days"):
            i += 1
            if i >= len(argv):
                return None
            if a == "--home":
                opts["home"] = argv[i]
            else:
                if (not argv[i].isascii() or not argv[i].isdigit()
                        or not 1 <= int(argv[i]) <= MAX_DAYS):
                    return None
                opts["days"] = int(argv[i])
        else:
            return None
        i += 1
    return opts


def run(opts):
    home = opts["home"] or os.path.expanduser("~")
    now = datetime.now(timezone.utc)
    in_window, n_sampled, parsed, unparsable = collect_sidecars(
        home, opts["days"], now)
    hatch = collect_hatch(home)
    db_path = os.environ.get("CAST_DB_PATH") or os.path.join(
        home, ".claude", "cast.db")
    db = query_db(db_path, now, opts["days"])
    state, findings = evaluate(in_window, n_sampled, parsed, unparsable, hatch, db)

    if opts["json"]:
        print(json.dumps({
            "state": state, "sidecars": n_sampled, "hatch_lines": len(hatch),
            "db_rows": db[0] if db else None, "findings": findings,
        }))
    else:
        if state == "no_data":
            print("[--] no data")
        elif state == "ok" and not findings:
            print(f"[ok] Claude Code shapes as expected ({n_sampled} sidecars, "
                  f"{len(hatch)} hatch lines)")
        for x in findings:
            tag = "[!!]" if x["severity"] == "drift" else "[--]"
            print(f"{tag} {x['code']}: {x['detail']}")
        if state == "drift":
            print("[!!] Claude Code shape drift: CAST identity checks may "
                  "fail closed")
    return 1 if state == "drift" else 0


def main(argv):
    opts = _parse_args(argv)
    # Under --json an error still yields one parseable JSON line on stdout.
    want_json = "--json" in argv
    if opts is None:
        print(USAGE, file=sys.stderr)
        if want_json:
            print(json.dumps({"state": "error", "findings": []}))
        return 2
    try:
        return run(opts)
    except Exception:  # noqa: BLE001 - fixed message, never a traceback
        print("cast-internals-canary: internal error", file=sys.stderr)
        if want_json:
            print(json.dumps({"state": "error", "findings": []}))
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
